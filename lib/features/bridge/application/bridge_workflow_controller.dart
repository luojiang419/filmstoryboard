import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import '../../../core/services/workspace_directories.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/application/script_analysis_controller.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/application/shooting_asset_library_controller.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../storyboard/domain/storyboard_models.dart';
import '../../storyboard/domain/image_generation_model_catalog.dart';
import '../../video_generation/application/video_generation_controller.dart';
import 'package:path/path.dart' as p;
import '../data/bridge_workflow_server.dart';
import '../../remote_access/application/remote_access_facade.dart';
import '../../video_generation/application/video_generation_remote_source.dart';
import '../../video_generation/domain/generated_video_trim_range.dart';

/// 节点只做展示与连线，所有生成、资产绑定和参数保存复用桌面控制器。
class BridgeWorkflowController {
  BridgeWorkflowController({
    required this.scripts,
    required this.storyboards,
    required this.replicate,
    required this.analysis,
    required this.binding,
    required this.library,
    required this.video,
    required this.directories,
    required this.server,
    this.remote,
    this.remoteVideo,
  });
  final ShootingScriptController scripts;
  final StoryboardController storyboards;
  final ReplicateController replicate;
  final ShootingScriptAnalysisController analysis;
  final ShootingScriptAssetBindingController binding;
  final ShootingAssetLibraryController library;
  final VideoGenerationController video;
  final WorkspaceDirectories directories;
  final BridgeWorkflowServer server;
  final RemoteAccessFacade? remote;
  final VideoGenerationRemoteSource? remoteVideo;
  final Map<String, Map<String, Object?>> _jobs = {};
  String _activeScript = '';
  bool _busy = false;

  Future<Map<String, Object?>> handle(Map<String, Object?> body) async {
    final action = '${body['action'] ?? 'snapshot'}';
    final scriptId = '${body['script_id'] ?? ''}';
    final requestId = '${body['request_id'] ?? ''}';
    if (action == 'cancel-task' && _activeScript == scriptId) {
      final task = video.value.tasks.firstWhere(
        (t) => t.id == body['task_id'] && t.scriptId == scriptId,
      );
      await video.cancelTask(task);
      return {'snapshot': _snapshot(scriptId)};
    }
    if (action == 'job') {
      final job = _jobs['${body['job_id']}'];
      if (job == null) throw StateError('任务已失效，请刷新节点并检查 film 生成记录');
      if (job['script_id'] != scriptId) {
        throw const FormatException('任务不属于当前脚本');
      }
      return {
        'job': job,
        if (_activeScript == scriptId || !_busy)
          'snapshot': _snapshot(scriptId),
      };
    }
    if (requestId.isNotEmpty && _jobs.containsKey(requestId)) {
      final job = _jobs[requestId]!;
      if (job['script_id'] != scriptId || job['action'] != action) {
        throw const FormatException('重复请求 ID 不属于当前操作');
      }
      return {'job': job};
    }
    if (_busy) {
      if (action == 'snapshot' && scriptId == _activeScript) {
        return {'snapshot': _snapshot(scriptId)};
      }
      throw StateError('film 正在执行镜头任务，请完成后再修改或切换脚本');
    }
    if (action == 'sync') {
      _busy = true;
      try {
        final id = await _sync(body);
        return {'snapshot': _snapshot(id)};
      } finally {
        _busy = false;
      }
    }
    _select(scriptId);
    if (action == 'snapshot') return {'snapshot': _snapshot(scriptId)};
    if (requestId.isNotEmpty && _jobs.containsKey(requestId)) {
      return {'job': _jobs[requestId]};
    }
    const longActions = {
      'analyze',
      'depth',
      'match',
      'replicate',
      'build-prompts',
      'generate',
      'import-asset',
      'bind-asset',
      'export-timeline',
      'export-video',
    };
    if (longActions.contains(action)) {
      if (requestId.isEmpty) throw const FormatException('操作缺少唯一请求 ID');
      final job = <String, Object?>{
        'id': requestId,
        'status': 'running',
        'script_id': scriptId,
        'action': action,
      };
      _jobs[requestId] = job;
      if (_jobs.length > 100) _jobs.remove(_jobs.keys.first);
      _busy = true;
      _activeScript = scriptId;
      unawaited(() async {
        try {
          await _execute(action, body);
          job['status'] = 'completed';
        } catch (error) {
          job['status'] = 'failed';
          job['error'] = '$error';
        } finally {
          _busy = false;
        }
      }());
      return {'job': job};
    }
    await _execute(action, body);
    return {'snapshot': _snapshot(scriptId)};
  }

  void _select(String id) {
    if (id.isEmpty || !scripts.value.scripts.any((s) => s.id == id)) {
      throw StateError('请先连接图片组，建立拍摄脚本');
    }
    if (scripts.value.selectedScriptId != id) scripts.selectScript(id);
    if (replicate.value.selectedScriptId != id) replicate.selectScript(id);
    if (video.value.selectedScriptId != id) video.selectScript(id);
    _activeScript = id;
  }

  Future<String> _sync(Map<String, Object?> body) async {
    final key = '${body['group_key'] ?? ''}';
    final frames = body['frames'];
    if (key.isEmpty ||
        frames is! List ||
        frames.isEmpty ||
        frames.length > 10000) {
      throw const FormatException('图片组为空或数量无效');
    }
    final original = storyboards.value.boards
        .where((b) => b.id == body['source_board_id'])
        .firstOrNull;
    if (original != null && original.items.length == frames.length) {
      final ordered = original.items.toList()
        ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
      var matches = true;
      for (var index = 0; index < frames.length; index++) {
        final frame = frames[index] as Map;
        final file = File(ordered[index].asset.path);
        if (frame['source_asset_id'] != ordered[index].asset.id ||
            !await file.exists() ||
            sha256.convert(await file.readAsBytes()).toString() !=
                sha256.convert(base64Decode('${frame['data']}')).toString()) {
          matches = false;
          break;
        }
      }
      if (matches) {
        final script =
            scripts.value.scripts
                .where((s) => s.sourceStoryboardId == original.id)
                .firstOrNull ??
            scripts.createForStoryboard(original);
        _select(script.id);
        return script.id;
      }
    }
    final existingScript = scripts.value.scripts
        .where(
          (s) => s.sourceStoryboardId == 'external-board:canvas-workflow:$key',
        )
        .firstOrNull;
    if (existingScript != null) scripts.selectScript(existingScript.id);
    final preservedContent = <String, String>{
      if (existingScript != null)
        for (final shot in scripts.value.shots) shot.id: shot.content,
    };
    final images = <StoryboardExternalImage>[];
    for (final value in frames) {
      final frame = (value as Map).cast<String, Object?>();
      final file = await _receiveImage(frame);
      final decoded = img.decodeImage(await file.readAsBytes())!;
      images.add(
        StoryboardExternalImage(
          stableId: 'canvas:${sha256.convert(utf8.encode(key))}:${frame['id']}',
          sourceName: '${frame['name'] ?? '画布图片'}',
          path: file.path,
          width: decoded.width,
          height: decoded.height,
          caption: '${frame['caption'] ?? ''}',
        ),
      );
    }
    final boardId = await storyboards.createOrReplaceBoardFromExternalImages(
      sourceId: 'canvas-workflow:$key',
      boardName: '${body['name'] ?? '无限画布'}',
      images: images,
      selectBoard: false,
      preserveExistingCaptions: true,
    );
    if (boardId == null) throw StateError(storyboards.value.message);
    final board = storyboards.value.boards.firstWhere((b) => b.id == boardId);
    final script = scripts.createForStoryboard(board);
    _select(script.id);
    for (final shot in scripts.value.shots.toList()) {
      if (preservedContent.containsKey(shot.id) &&
          shot.content != preservedContent[shot.id]) {
        scripts.updateShot(shot.copyWith(content: preservedContent[shot.id]));
      }
    }
    return script.id;
  }

  Future<File> _receiveImage(Map<String, Object?> frame) async {
    final bytes = base64Decode('${frame['data'] ?? ''}');
    if (bytes.isEmpty || bytes.length > 100 * 1024 * 1024) {
      throw const FormatException('图片大小无效');
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('无法解码传入图片');
    final directory = Directory(
      '${directories.workspaceRoot.path}/canvas-workflow/media',
    );
    await directory.create(recursive: true);
    // 内容寻址 + PNG 规范化，图片变更不覆盖旧帧；原始镜头和恢复记录仍可引用旧版本。
    final file = File('${directory.path}/${sha256.convert(bytes)}.png');
    if (!await file.exists()) await file.writeAsBytes(img.encodePng(decoded));
    return file;
  }

  Future<void> _execute(String action, Map<String, Object?> body) async {
    final shotId = '${body['shot_id'] ?? ''}';
    if (shotId.isNotEmpty &&
        !replicate.value.shots.any((s) => s.id == shotId)) {
      throw const FormatException('镜头不属于当前脚本');
    }
    final params = ((body['parameters'] as Map?) ?? {}).cast<String, Object?>();
    switch (action) {
      case 'parameters':
        _parameters(params);
      case 'settings':
        if (remote == null) throw StateError('设置服务尚未就绪');
        await remote!.updateSettingsSelection(
          (body['selection'] as Map).cast<String, Object?>(),
        );
        await video.refreshVideoApiConfig();
      case 'video-parameters':
        if (remoteVideo == null) throw StateError('视频参数服务尚未就绪');
        await remoteVideo!.configure(
          model: body['model'] as String?,
          parameters: params.map((key, value) => MapEntry(key, '$value')),
        );
      case 'confirm':
        if (shotId.isEmpty) {
          replicate.confirmAllShots();
        } else {
          replicate.toggleShotConfirmed(shotId, body['confirmed'] != false);
        }
      case 'edit-shot':
        final shot = scripts.value.shots.firstWhere((s) => s.id == shotId);
        if (!scripts.updateShot(
          shot.copyWith(
            content: params['content'] as String?,
            visual: params['visual'] as String?,
            prompt: params['prompt'] as String?,
            cameraMovement: params['cameraMovement'] as String?,
            shotSize: params['shotSize'] as String?,
            sound: params['sound'] as String?,
            dialogue: params['dialogue'] as String?,
            durationSeconds: (params['durationSeconds'] as num?)?.toDouble(),
            freeCreationDescription:
                params['freeCreationDescription'] as String?,
            updatedAt: DateTime.now().toUtc(),
          ),
        )) {
          throw StateError('镜头已被修改，请刷新重试');
        }
      case 'analyze':
        if (replicate.value.generationMode == ReplicationGenerationMode.quick) {
          if (shotId.isEmpty) {
            await replicate.analyzeAllQuickReplicationFrames();
          } else {
            await replicate.analyzeQuickReplicationFrame(shotId);
          }
        } else {
          if (shotId.isEmpty) {
            await replicate.analyzeAllReplicationFrames();
          } else {
            await replicate.analyzeReplicationFrame(shotId);
          }
        }
      case 'depth':
        if (shotId.isEmpty) {
          await replicate.extractDepthForAllShots();
        } else {
          await replicate.extractDepthForShot(shotId);
        }
      case 'match':
        if (shotId.isEmpty) {
          await binding.autoMatchAll(preferredAssets: replicate.value.assets);
        } else {
          await binding.autoMatchShot(
            shotId,
            preferredAssets: replicate.value.assets,
          );
        }
      case 'replicate':
        final quick =
            replicate.value.generationMode == ReplicationGenerationMode.quick;
        if (shotId.isEmpty) {
          if (quick) {
            await replicate.replicateAllShotsQuick();
          } else {
            await replicate.replicateAllShots();
          }
        } else {
          final success = quick
              ? await replicate.replicateShotQuick(shotId)
              : await replicate.replicateShot(shotId);
          if (!success) {
            throw StateError(
              replicate.value.errorMessage.isEmpty
                  ? '镜头复刻失败'
                  : replicate.value.errorMessage,
            );
          }
        }
      case 'build-prompts':
        if (replicate.value.run?.freeCreationEnabled == true) {
          if (!await replicate.buildFreeCreationPrompts()) {
            throw StateError(replicate.value.errorMessage);
          }
        } else {
          final overrides = {
            for (final image in replicate.value.replicatedImages)
              if (image.generatedFramePath.isNotEmpty)
                image.scriptShotId: image.generatedFramePath,
          };
          if (!await analysis.buildScript(imagePathOverrides: overrides)) {
            throw StateError(analysis.value.errorMessage);
          }
          await replicate.composeAllPrompts(navigateToComposeStep: false);
        }
      case 'generate':
        // 调用与桌面列表相同的控制器，传明确镜头范围，禁止含混的全项目生成。
        final confirmed =
            replicate.value.run?.confirmedShotIds.toSet() ?? <String>{};
        final shots = video.value.shots
            .where(
              (s) =>
                  confirmed.contains(s.id) &&
                  (shotId.isEmpty || s.id == shotId),
            )
            .toList();
        if (shots.isEmpty) throw StateError('请先确认需要生成的镜头');
        final before = video.value.tasks.map((t) => t.id).toSet();
        await video.generateSelection(shots);
        final submitted = video.value.tasks
            .where((t) => !before.contains(t.id))
            .toList();
        if (submitted.isEmpty) {
          throw StateError(
            video.value.errorMessage.isNotEmpty
                ? video.value.errorMessage
                : '没有提交新任务，请检查提示词、参考图或镜头是否已在生成中',
          );
        }
        final failed = submitted
            .where((t) => t.errorMessage.isNotEmpty)
            .toList();
        if (failed.isNotEmpty) {
          throw StateError(failed.map((t) => t.errorMessage).join('；'));
        }
      case 'import-asset':
        final file = await _receiveImage(
          (body['asset'] as Map).cast<String, Object?>(),
        );
        final item = await library.importItem(
          sourcePath: file.path,
          type: ReplicateAssetType.values.byName(
            '${body['asset_type'] ?? 'reference'}',
          ),
          name: '${body['name'] ?? '画布资产'}',
        );
        if (item == null) throw StateError(library.value.errorMessage);
        if (shotId.isNotEmpty) {
          await binding.addLibraryAssetToShot(item, shotId);
        }
      case 'bind-asset':
        final item = library.value.items.firstWhere(
          (a) => a.id == body['asset_id'],
        );
        await binding.addLibraryAssetToShot(
          item,
          shotId,
          slotSortOrder: (body['slot'] as num?)?.toInt(),
        );
      case 'unbind-asset':
        binding.removeAssetFromShot(shotId, '${body['asset_id']}');
      case 'edit-asset':
        final asset = library.value.items.firstWhere(
          (a) => a.id == body['asset_id'],
        );
        library.updateItem(
          asset.copyWith(
            name: params['name'] as String?,
            description: params['description'] as String?,
          ),
        );
      case 'delete-asset':
        await library.deleteItem('${body['asset_id']}');
      case 'open-assets':
        await library.openLibraryDirectory();
      case 'delete-task':
        final task = video.value.tasks.firstWhere(
          (t) => t.id == body['task_id'] && t.scriptId == _activeScript,
        );
        await video.deleteTask(task);
      case 'trim-task':
        final task = video.value.tasks.firstWhere(
          (t) => t.id == body['task_id'] && t.scriptId == _activeScript,
        );
        video.updateTaskTrimRange(
          task,
          GeneratedVideoTrimRange.fromMilliseconds(
            sourceDurationMs: task.sourceDurationMs,
            trimInMs: (params['inMs'] as num).toInt(),
            trimOutMs: (params['outMs'] as num).toInt(),
            fallbackDurationMs: task.durationSeconds * 1000,
          ),
        );
      case 'export-timeline':
        await video.exportTimelineXml();
      case 'export-video':
        await video.exportVideo();
      case 'open-output':
        await video.openOutputDirectory();
      case 'subject':
        replicate.setDetectedSubjectDecision(
          shotId,
          '${body['subject_id']}',
          ReplicateSubjectDecision.values.byName('${body['decision']}'),
        );
      case 'preserved-element':
        replicate.setPreservedElementSelected(
          shotId,
          '${body['element_id']}',
          body['selected'] == true,
        );
      case 'add-element':
        replicate.addManualPreservedElement(shotId, '${body['name']}');
      case 'remove-subject':
        replicate.removeDetectedSubject(shotId, '${body['subject_id']}');
      case 'group-start':
        replicate.selectManualShotGroupStart(shotId);
      case 'group-end':
        replicate.setManualShotGroupEnd(shotId);
      case 'group-clear':
        replicate.clearManualShotGroup(shotId);
      case 'video-prompt':
        video.updateEditedPrompt(shotId, '${body['prompt'] ?? ''}');
      case 'prompt-format':
        replicate.selectPromptFormatForAll(
          ShotPromptFormat.values.byName('${body['format']}'),
        );
      default:
        throw FormatException('不支持的影视工作流动作：$action');
    }
    final error = action == 'match'
        ? binding.value.errorMessage
        : {'analyze', 'depth', 'replicate', 'build-prompts'}.contains(action)
        ? replicate.value.errorMessage
        : {'export-timeline', 'export-video'}.contains(action)
        ? video.value.errorMessage
        : '';
    if (error.isNotEmpty) throw StateError(error);
  }

  void _parameters(Map<String, Object?> p) {
    final run = replicate.value.run!;
    if (p.containsKey('generationMode')) {
      replicate.updateGenerationMode(
        ReplicationGenerationMode.values.byName('${p['generationMode']}'),
      );
    }
    if (p.keys.any(
      (k) => {
        'model',
        'aspectRatio',
        'imageSize',
        'quality',
        'sourceFrameMode',
        'inheritSourceAspectRatio',
        'multiViewEnhancementEnabled',
        'colorStylePresetId',
      }.contains(k),
    )) {
      replicate.updateGenerationDefaults(
        model: p['model'] as String?,
        aspectRatio: p['aspectRatio'] as String?,
        imageSize: p['imageSize'] as String?,
        quality: p['quality'] as String?,
        sourceFrameMode: p.containsKey('sourceFrameMode')
            ? ReplicateSourceFrameMode.values.byName('${p['sourceFrameMode']}')
            : null,
        inheritSourceAspectRatio: p['inheritSourceAspectRatio'] as bool?,
        multiViewEnhancementEnabled: p['multiViewEnhancementEnabled'] as bool?,
        colorStylePresetId: p['colorStylePresetId'] as String?,
      );
    }
    if (p.containsKey('replicationInstructions')) {
      replicate.updateReplicationInstructions(
        '${p['replicationInstructions']}',
      );
    }
    if (p.containsKey('globalStyle') || p.containsKey('constraints')) {
      replicate.updatePromptRules(
        globalStyle: '${p['globalStyle'] ?? run.globalStyle}',
        constraints: '${p['constraints'] ?? run.constraints}',
      );
    }
    if (p.containsKey('freeCreationEnabled')) {
      replicate.setFreeCreationEnabled(p['freeCreationEnabled'] == true);
    }
    if (p.containsKey('freeCreationStoryOverride')) {
      replicate.updateFreeCreationStoryOverride(
        '${p['freeCreationStoryOverride']}',
      );
    }
    if (p.containsKey('videoAspectRatio')) {
      video.updateVideoApiAspectRatio('${p['videoAspectRatio']}');
    }
    if (p.containsKey('videoResolution')) {
      video.updateVideoApiResolution('${p['videoResolution']}');
    }
    if (p.containsKey('videoSteps')) {
      video.updateVideoApiSteps((p['videoSteps'] as num).toInt());
    }
    if (p.containsKey('videoModel')) video.selectModel('${p['videoModel']}');
    if (p['videoParameters'] is Map) {
      for (final entry in (p['videoParameters'] as Map).entries) {
        video.updateParameter('${entry.key}', '${entry.value}');
      }
    }
  }

  String _media(String path) {
    if (path.isNotEmpty && !p.isAbsolute(path)) {
      path = p.join(directories.workspaceRoot.path, path);
    }
    if (path.isEmpty || !File(path).existsSync()) return '';
    final id = sha256
        .convert(
          utf8.encode(
            '$path:${File(path).lastModifiedSync().millisecondsSinceEpoch}',
          ),
        )
        .toString();
    final key = '$id${p.extension(path).toLowerCase()}';
    server.media[key] = File(path);
    return '/media/$key';
  }

  Map<String, Object?> _snapshot(String scriptId) {
    _select(scriptId);
    final state = replicate.value;
    final run = state.run!;
    final descriptor = ImageGenerationCatalog.descriptorFor(
      replicate.resolvedGenerationModel,
    );
    return {
      'scriptId': scriptId,
      'name': scripts.value.selectedScript?.name ?? '',
      'busy': _busy,
      'message': state.message,
      'error': state.errorMessage,
      'parameters': {
        'generationMode': state.generationMode.name,
        'model': replicate.resolvedGenerationModel,
        'aspectRatio': run.generationAspectRatio,
        'imageSize': run.generationImageSize,
        'quality': run.generationQuality,
        'sourceFrameMode': run.sourceFrameMode.name,
        'inheritSourceAspectRatio': run.inheritSourceAspectRatio,
        'multiViewEnhancementEnabled': run.multiViewEnhancementEnabled,
        'colorStylePresetId': run.colorStylePresetId,
        'replicationInstructions': run.replicationInstructions,
        'globalStyle': run.globalStyle,
        'constraints': run.constraints,
        'freeCreationEnabled': run.freeCreationEnabled,
        'freeCreationStoryOverride': run.freeCreationStoryOverride,
        'videoModel': video.value.profile?.model ?? '',
        'videoParameters': video.value.profile?.parameters ?? {},
        'videoAspectRatio': video.selectedVideoApiAspectRatio,
        'videoResolution': video.selectedVideoApiResolution,
        'videoSteps': video.selectedVideoApiSteps,
      },
      'options': {
        if (remote != null) 'settings': remote!.settingsOptions(),
        if (remote != null) 'video': remote!.videoGenerationOptions(),
        'models': [
          for (final model in ImageGenerationCatalog.models)
            {'id': model.id, 'label': model.label},
        ],
        'aspectRatios': descriptor?.aspectRatios ?? [],
        'imageSizes': ImageGenerationCatalog.resolutionsFor(
          replicate.resolvedGenerationModel,
          run.generationAspectRatio,
        ),
        'qualities': descriptor?.qualities ?? [],
        'colorStyles': [
          for (final preset in state.colorStylePresets)
            {'id': preset.id, 'label': preset.name},
        ],
        'videoBackend': video.activeVideoBackendName,
        'videoSummary': video.videoApiParameterSummary,
      },
      'story': replicate.effectiveFreeCreationStory,
      'groups': [
        for (final group in ScriptShotGroup.group(state.shots))
          {
            'id': group.shots.first.id,
            'shotIds': group.shots.map((s) => s.id).toList(),
          },
      ],
      'shots': [
        for (final shot in state.shots)
          {
            'id': shot.id,
            'number': shot.shotNumber,
            'frame': _media(shot.framePath),
            'content': shot.content,
            'visual': shot.visual,
            'durationSeconds': shot.durationSeconds,
            'shotSize': shot.shotSize,
            'cameraMovement': shot.cameraMovement,
            'sound': shot.sound,
            'dialogue': shot.dialogue,
            'prompt': shot.prompt,
            'freeCreationDescription': shot.freeCreationDescription,
            'confirmed': run.confirmedShotIds.contains(shot.id),
            'replica': _media(
              state.replicatedImages
                      .where((r) => r.scriptShotId == shot.id)
                      .firstOrNull
                      ?.generatedFramePath ??
                  '',
            ),
            'replicaStatus':
                state.replicatedImages
                    .where((r) => r.scriptShotId == shot.id)
                    .firstOrNull
                    ?.status
                    .name ??
                '',
            'replicaError':
                state.replicatedImages
                    .where((r) => r.scriptShotId == shot.id)
                    .firstOrNull
                    ?.errorMessage ??
                '',
            'draft': video.value.drafts[shot.id]?.editedPrompt ?? '',
          },
      ],
      'assets': [
        for (final item in library.value.items)
          {
            'id': item.id,
            'name': item.name,
            'type': item.type.name,
            'description': item.description,
            'url': _media(item.path),
          },
      ],
      'bindings': [
        for (final link in binding.value.links)
          {
            'shotId': link.shotId,
            'assetId': link.scriptAssetId,
            'confirmed': link.confirmed,
            'locked': link.locked,
          },
      ],
      'boundAssets': [
        for (final asset in binding.value.assets)
          {'id': asset.id, 'name': asset.name, 'url': _media(asset.path)},
      ],
      'guides': [
        for (final guide in state.shotGuides)
          {
            'shotId': guide.shotId,
            'depth': _media(guide.depthPath),
            'status': guide.analysisStatus.name,
            'error': guide.errorMessage,
            'elements': [
              for (final element in guide.elements) element.toJson(),
            ],
            'subjects': [
              for (final subject in guide.subjects) subject.toJson(),
            ],
          },
      ],
      'tasks': [
        for (final task in video.value.tasks)
          if (task.scriptId == scriptId)
            {
              'id': task.id,
              'shotId': task.shotId,
              'status': task.status.name,
              'error': task.errorMessage,
              'url': _media(task.localPath),
              'prompt': task.prompt,
              'duration': task.durationSeconds,
              'inMs': task.trimInMs,
              'outMs': task.trimOutMs,
              'sourceDurationMs': task.sourceDurationMs,
            },
      ],
    };
  }
}
