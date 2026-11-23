import '../../shooting_script/data/shooting_script_repository.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../data/remote_storyboard_review_repository.dart';
import '../domain/remote_events.dart';
import '../domain/remote_export_models.dart';
import '../domain/remote_project_models.dart';
import '../domain/remote_settings_models.dart';
import '../domain/remote_shooting_workflow_models.dart';
import '../domain/remote_storyboard_models.dart';
import '../domain/remote_video_analysis_models.dart';
import '../domain/remote_video_generation_models.dart';
import 'remote_media_registry.dart';
import 'remote_export_registry.dart';
import 'remote_project_registry.dart';
import 'remote_settings_registry.dart';
import 'remote_shooting_workflow_registry.dart';
import 'remote_storyboard_registry.dart';
import 'remote_task_registry.dart';
import 'remote_video_analysis_registry.dart';
import 'remote_video_generation_registry.dart';
import 'remote_workspace_registry.dart';

class RemoteOperationException implements Exception {
  const RemoteOperationException(
    this.code,
    this.message, [
    this.details = const {},
  ]);

  final String code;
  final String message;
  final Map<String, Object?> details;
}

class RemoteAccessFacade {
  const RemoteAccessFacade({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    RemoteMediaRegistry? mediaRegistry,
    RemoteStoryboardRegistry? storyboardRegistry,
    RemoteShootingWorkflowRegistry? shootingWorkflowRegistry,
    RemoteProjectRegistry? projectRegistry,
    RemoteTaskRegistry? taskRegistry,
    RemoteExportRegistry? exportRegistry,
    RemoteVideoAnalysisRegistry? videoAnalysisRegistry,
    RemoteVideoGenerationRegistry? videoGenerationRegistry,
    RemoteSettingsRegistry? settingsRegistry,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _storyboardRegistry = storyboardRegistry,
       _shootingWorkflowRegistry = shootingWorkflowRegistry,
       _projectRegistry = projectRegistry,
       _taskRegistry = taskRegistry,
       _exportRegistry = exportRegistry,
       _videoAnalysisRegistry = videoAnalysisRegistry,
       _videoGenerationRegistry = videoGenerationRegistry,
       _settingsRegistry = settingsRegistry;

  static const editableShotFields = {
    'durationSeconds',
    'visual',
    'content',
    'freeCreationDescription',
    'shotSize',
    'cameraMovement',
    'cameraNotes',
    'composition',
    'cameraAngle',
    'lightingMood',
    'colorPalette',
    'visualFocus',
    'transitionHint',
    'movementTrend',
    'actionStage',
    'scene',
    'productCode',
    'productStyling',
    'dialogue',
    'sound',
    'prompt',
    'replicationInstructions',
    'generationFeedback',
  };

  static const editableStoryboardFields = {
    'name',
    'summary',
    'itemCaptions',
    'rowCaptions',
  };

  static const editableAnnotationFields = {'body', 'resolved'};

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final RemoteMediaRegistry? _mediaRegistry;
  final RemoteStoryboardRegistry? _storyboardRegistry;
  final RemoteShootingWorkflowRegistry? _shootingWorkflowRegistry;
  final RemoteProjectRegistry? _projectRegistry;
  final RemoteTaskRegistry? _taskRegistry;
  final RemoteExportRegistry? _exportRegistry;
  final RemoteVideoAnalysisRegistry? _videoAnalysisRegistry;
  final RemoteVideoGenerationRegistry? _videoGenerationRegistry;
  final RemoteSettingsRegistry? _settingsRegistry;

  Map<String, Object?> settingsOptions() =>
      _settingsJson(_requireSettingsRegistry().read());

  Future<Map<String, Object?>> updateSettingsSelection(
    Map<String, Object?> body,
  ) async {
    const allowed = {
      'extractionStrategy',
      'visionModelId',
      'imageGenerationModelId',
      'videoGenerationModelId',
    };
    final unknown = body.keys.toSet().difference(allowed);
    if (unknown.isNotEmpty) {
      throw FormatException('设置请求包含未知字段：${unknown.join('、')}');
    }
    String? optionalText(String key) {
      if (!body.containsKey(key)) return null;
      final value = body[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key 必须是非空文本');
      }
      return value.trim();
    }

    final command = RemoteSettingsSelectionCommand(
      extractionStrategy: optionalText('extractionStrategy'),
      visionModelId: optionalText('visionModelId'),
      imageGenerationModelId: optionalText('imageGenerationModelId'),
      videoGenerationModelId: optionalText('videoGenerationModelId'),
    );
    if (command.isEmpty) throw const FormatException('至少选择一项设置');
    try {
      return _settingsJson(await _requireSettingsRegistry().update(command));
    } on ArgumentError catch (error) {
      throw RemoteOperationException('invalid_selection', '${error.message}');
    }
  }

  Map<String, Object?> exportOptions() =>
      _runExportOperation(() => _requireExportRegistry().options());

  Map<String, Object?> startExport(Map<String, Object?> body) =>
      _runExportOperation(
        () => _requireExportRegistry().start(_exportCommand(body)).toJson(),
      );

  Map<String, Object?> retryExport(String taskId) => _runExportOperation(
    () => _requireExportRegistry().retry(taskId).toJson(),
  );

  Map<String, Object?> videoGenerationOptions() => _runVideoGenerationOperation(
    () => _requireVideoGenerationRegistry().options(),
  );

  Map<String, Object?> videoGenerationGroups() => _runVideoGenerationOperation(
    () => _requireVideoGenerationRegistry().groups(),
  );

  Map<String, Object?> videoGenerationTasks() => _runVideoGenerationOperation(
    () => _requireVideoGenerationRegistry().tasks(),
  );

  Map<String, Object?> videoGenerationWorks() => _runVideoGenerationOperation(
    () => _requireVideoGenerationRegistry().works(),
  );

  Map<String, Object?> selectVideoGenerationScript(String scriptId) =>
      _runVideoGenerationOperation(
        () => _requireVideoGenerationRegistry().selectScript(scriptId),
      );

  Map<String, Object?> startVideoGeneration(Map<String, Object?> body) =>
      _runVideoGenerationOperation(
        () => _requireVideoGenerationRegistry()
            .start(_videoGenerationCommand(body))
            .toJson(),
      );

  Map<String, Object?> retryVideoGenerationTask(String taskId) =>
      _runVideoGenerationOperation(
        () => _requireVideoGenerationRegistry().retry(taskId).toJson(),
      );

  Future<Map<String, Object?>> cancelVideoGenerationTask(String taskId) async {
    try {
      return await _requireVideoGenerationRegistry().cancelTask(taskId);
    } on RemoteVideoGenerationSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  Map<String, Object?> listVideos() =>
      _runVideoOperation(() => _requireVideoAnalysisRegistry().collection());

  Map<String, Object?> videoDetail(String videoId) =>
      _runVideoOperation(() => _requireVideoAnalysisRegistry().detail(videoId));

  Map<String, Object?> importVideoUpload(String uploadId) => _runVideoOperation(
    () => _requireVideoAnalysisRegistry().importUpload(uploadId).toJson(),
  );

  Map<String, Object?> startVideoAnalysis(
    String videoId, {
    bool retryFailedOnly = false,
  }) => _runVideoOperation(
    () => _requireVideoAnalysisRegistry()
        .startAnalysis(videoId, retryFailedOnly: retryFailedOnly)
        .toJson(),
  );

  Map<String, Object?> pauseVideoAnalysis(String videoId) => _runVideoOperation(
    () => _requireVideoAnalysisRegistry().pauseAnalysis(videoId),
  );

  Map<String, Object?> removeVideoFrame(String videoId, String frameId) =>
      _runVideoOperation(
        () => _requireVideoAnalysisRegistry().removeFrame(videoId, frameId),
      );

  Map<String, Object?> undoVideoFrameRemoval(String videoId) =>
      _runVideoOperation(
        () => _requireVideoAnalysisRegistry().undoFrameRemoval(videoId),
      );

  Map<String, Object?> redoVideoFrameRemoval(String videoId) =>
      _runVideoOperation(
        () => _requireVideoAnalysisRegistry().redoFrameRemoval(videoId),
      );

  Future<Map<String, Object?>> cancelVideoAnalysis(String videoId) async {
    try {
      return await _requireVideoAnalysisRegistry().cancelAnalysis(videoId);
    } on RemoteVideoAnalysisSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  Map<String, Object?> generateVideoStoryboard(String videoId) =>
      _runVideoOperation(
        () => _requireVideoAnalysisRegistry()
            .generateStoryboard(videoId)
            .toJson(),
      );

  Map<String, Object?> listTasks() => {
    'items': [
      for (final task in _requireTaskRegistry().listCurrentProject())
        task.toJson(),
    ],
  };

  Map<String, Object?> taskDetail(String taskId) {
    final task = _requireTaskRegistry().getCurrentProject(taskId);
    if (task == null) {
      throw const RemoteOperationException('not_found', '任务不存在');
    }
    return task.toJson();
  }

  Future<Map<String, Object?>> cancelTask(String taskId) async {
    final task = await _requireTaskRegistry().cancelCurrentProject(taskId);
    if (task == null) {
      throw const RemoteOperationException('not_found', '任务不存在');
    }
    return task.toJson();
  }

  Map<String, Object?> listProjects() {
    final registry = _projectRegistry;
    if (registry == null) {
      throw const RemoteOperationException(
        'feature_unavailable',
        '工程项目选择功能尚未启用',
      );
    }
    try {
      return registry.collection();
    } on RemoteProjectSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  Future<Map<String, Object?>> openProject(String projectId) async {
    final registry = _projectRegistry;
    if (registry == null) {
      throw const RemoteOperationException(
        'feature_unavailable',
        '工程项目选择功能尚未启用',
      );
    }
    try {
      return await registry.openProject(projectId);
    } on RemoteProjectSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  Map<String, Object?> workspaceOverview() {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      return const {'phase': 'home', 'project': null};
    }
    final repository = ShootingScriptRepository(workspace.database);
    final scripts = repository.listScripts();
    var shotCount = 0;
    for (final script in scripts) {
      shotCount += repository.listShots(script.id).length;
    }
    final storyboardSource = _storyboardRegistry?.source;
    return {
      'phase': 'editor',
      'project': {
        'id': workspace.projectId,
        'name': workspace.projectName,
        'statistics': {
          'shootingScriptCount': scripts.length,
          'shotCount': shotCount,
          'storyboardCount': storyboardSource?.boards.length ?? 0,
        },
      },
      'eventSequence': _changeBus.lastSequence,
    };
  }

  Map<String, Object?> listScripts() {
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    return {
      'projectId': workspace.projectId,
      'items': [
        for (final script in repository.listScripts())
          _scriptSummary(
            script,
            shotCount: repository.listShots(script.id).length,
          ),
      ],
    };
  }

  Map<String, Object?> scriptDetail(String scriptId) {
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    final script = repository.getScript(scriptId);
    if (script == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本不存在');
    }
    return _scriptDetail(repository, script);
  }

  Map<String, Object?> shootingWorkflow(String scriptId) {
    _requireWorkspace();
    final workflow = _requireShootingWorkflowSource().workflowFor(scriptId);
    if (workflow == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本工作流不存在');
    }
    return _shootingWorkflowJson(workflow);
  }

  Map<String, Object?> confirmShootingWorkflowShots(String scriptId) {
    _requireScript(scriptId);
    final source = _requireShootingWorkflowSource();
    source.confirmShots(scriptId);
    return shootingWorkflow(scriptId);
  }

  Map<String, Object?> startShootingWorkflowAction({
    required String scriptId,
    required String action,
    String? shotId,
  }) {
    final script = _requireScript(scriptId);
    if (shotId != null && !script.shots.any((shot) => shot.id == shotId)) {
      throw const RemoteOperationException('not_found', '脚本镜头不存在');
    }
    final source = _requireShootingWorkflowSource();
    if (source.workflowFor(scriptId) == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本工作流不存在');
    }
    final taskKind = switch (action) {
      'matchAssets' => 'shootingAssetMatch',
      'buildScript' => 'shootingScriptBuild',
      'replicateStoryboards' => 'storyboardReplication',
      _ => throw const RemoteOperationException(
        'invalid_request',
        '不支持的拍摄脚本工作流操作',
      ),
    };
    final task = _requireTaskRegistry().start(
      kind: taskKind,
      message: switch (action) {
        'matchAssets' => '等待本机匹配资产',
        'buildScript' => '等待本机构建脚本',
        _ => shotId == null ? '等待本机复刻全部分镜' : '等待本机复刻当前分镜',
      },
      onCancel: switch (action) {
        'matchAssets' => source.cancelMatching,
        'buildScript' => source.cancelBuild,
        _ => null,
      },
      runner: (execution) async {
        execution.report(current: 0, total: 1);
        switch (action) {
          case 'matchAssets':
            await source.matchAssets(scriptId);
          case 'buildScript':
            await source.buildScript(scriptId);
          case 'replicateStoryboards':
            await source.replicateStoryboards(scriptId, shotId: shotId);
        }
        execution.throwIfCancellationRequested();
        execution.report(current: 1, total: 1, message: '本机操作已完成');
        return {'scriptId': scriptId, 'action': action, 'shotId': ?shotId};
      },
    );
    return task.toJson();
  }

  Map<String, Object?> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的镜头字段');
    }
    final unknown = changes.keys.toSet().difference(editableShotFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许远程修改的镜头字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    final script = repository.getScript(scriptId);
    if (script == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本不存在');
    }
    if (script.version != expectedVersion) {
      throw RemoteOperationException('revision_conflict', '拍摄脚本已在其他位置更新', {
        'currentVersion': script.version,
      });
    }
    final shot = repository.getShot(scriptId, shotId);
    if (shot == null) {
      throw const RemoteOperationException('not_found', '脚本镜头不存在');
    }
    final now = DateTime.now().toUtc();
    final updatedShot = _applyShotChanges(shot, changes, now);
    final updatedScript = script.copyWith(
      version: script.version + 1,
      updatedAt: now,
    );
    final saved = repository.updateShotIfScriptVersion(
      updatedScript: updatedScript,
      updatedShot: updatedShot,
      expectedVersion: expectedVersion,
    );
    if (!saved) {
      final currentVersion = repository.getScript(scriptId)?.version;
      throw RemoteOperationException('revision_conflict', '拍摄脚本已在其他位置更新', {
        'currentVersion': ?currentVersion,
      });
    }
    _changeBus.publish(
      type: 'shootingScript.changed',
      projectId: workspace.projectId,
      resourceId: scriptId,
      revision: updatedScript.version,
      data: {'shotId': shotId, 'source': 'remote'},
    );
    return _scriptDetail(repository, updatedScript);
  }

  Map<String, Object?> listStoryboards() {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    _pruneAnnotations(repository, source);
    return {
      'projectId': workspace.projectId,
      'groups': [
        for (final group in source.boardGroups)
          {'id': group.id, 'name': group.name},
      ],
      'items': [
        for (final board in source.boards)
          _storyboardSummary(
            board,
            revision: _storyboardRegistry!.revisionFor(board.id),
            annotations: repository.listForBoard(board.id),
          ),
      ],
    };
  }

  Map<String, Object?> storyboardDetail(String boardId) {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    _pruneAnnotations(repository, source);
    return _storyboardDetail(
      board,
      revision: _storyboardRegistry!.revisionFor(board.id),
      annotations: repository.listForBoard(board.id),
    );
  }

  Map<String, Object?> storyboardAssets(String boardId) {
    _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    final usedIds = board.items.map((item) => item.assetId).toSet();
    return {
      'boardId': boardId,
      'revision': _storyboardRegistry!.revisionFor(boardId),
      'items': [
        for (final asset in source.assets)
          _storyboardAssetJson(asset, used: usedIds.contains(asset.id)),
      ],
    };
  }

  Map<String, Object?> updateStoryboardLayout({
    required String boardId,
    required int expectedRevision,
    required String action,
    required String assetId,
    int? slotIndex,
  }) {
    _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final normalizedAssetId = assetId.trim();
    if (normalizedAssetId.isEmpty || normalizedAssetId.length > 500) {
      throw const RemoteOperationException(
        'invalid_request',
        'assetId 必须是有效的资源 ID',
      );
    }
    final layoutAction = switch (action) {
      'add' => RemoteStoryboardLayoutAction.add,
      'move' => RemoteStoryboardLayoutAction.move,
      'remove' => RemoteStoryboardLayoutAction.remove,
      _ => throw const RemoteOperationException(
        'invalid_request',
        'action 仅支持 add、move 或 remove',
      ),
    };
    if (layoutAction == RemoteStoryboardLayoutAction.move &&
        (slotIndex == null ||
            slotIndex < 0 ||
            slotIndex >= board.items.length)) {
      throw const RemoteOperationException(
        'invalid_request',
        '移动操作必须提供画板范围内的 slotIndex',
      );
    }
    if (layoutAction == RemoteStoryboardLayoutAction.add &&
        slotIndex != null &&
        (slotIndex < 0 || slotIndex >= board.rows * board.columns)) {
      throw const RemoteOperationException('invalid_request', '加入位置超出当前画板范围');
    }
    final outcome = _storyboardRegistry!.performRemoteMutation(
      (currentSource) => currentSource.applyLayout(
        RemoteStoryboardLayoutCommand(
          boardId: boardId,
          action: layoutAction,
          assetId: normalizedAssetId,
          slotIndex: slotIndex,
        ),
      ),
    );
    switch (outcome) {
      case RemoteStoryboardEditOutcome.updated:
      case RemoteStoryboardEditOutcome.unchanged:
        return storyboardDetail(boardId);
      case RemoteStoryboardEditOutcome.locked:
        throw const RemoteOperationException(
          'storyboard_locked',
          '故事板已锁定，请先在桌面端解锁',
        );
      case RemoteStoryboardEditOutcome.notFound:
        throw const RemoteOperationException('not_found', '故事板或图片资源不存在');
    }
  }

  Map<String, Object?> updateStoryboard({
    required String boardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的故事板字段');
    }
    final unknown = changes.keys.toSet().difference(editableStoryboardFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许远程修改的故事板字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final command = _storyboardEditCommand(board, changes);
    final outcome = _storyboardRegistry!.performRemoteMutation(
      (currentSource) => currentSource.applyEdit(command),
    );
    switch (outcome) {
      case RemoteStoryboardEditOutcome.updated:
      case RemoteStoryboardEditOutcome.unchanged:
        return storyboardDetail(boardId);
      case RemoteStoryboardEditOutcome.locked:
        throw const RemoteOperationException(
          'storyboard_locked',
          '故事板已锁定，请先在桌面端解锁',
        );
      case RemoteStoryboardEditOutcome.notFound:
        throw const RemoteOperationException('not_found', '故事板不存在');
    }
  }

  Map<String, Object?> addStoryboardAnnotation({
    required String boardId,
    required int expectedRevision,
    required String body,
    required String authorSessionId,
    required String authorName,
    String? assetId,
  }) {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final normalizedAssetId = assetId?.trim();
    if (normalizedAssetId != null &&
        normalizedAssetId.isNotEmpty &&
        !board.items.any((item) => item.assetId == normalizedAssetId)) {
      throw const RemoteOperationException('not_found', '批注目标镜头不存在');
    }
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    try {
      repository.create(
        boardId: boardId,
        assetId: normalizedAssetId?.isEmpty == true ? null : normalizedAssetId,
        body: body,
        authorSessionId: authorSessionId,
        authorName: authorName,
      );
    } on ArgumentError catch (error) {
      throw RemoteOperationException('invalid_changes', '${error.message}');
    }
    _storyboardRegistry!.publishAnnotationChanged(boardId, action: 'created');
    return storyboardDetail(boardId);
  }

  Map<String, Object?> updateStoryboardAnnotation({
    required String boardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的批注字段');
    }
    final unknown = changes.keys.toSet().difference(editableAnnotationFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许修改的批注字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    if (source.boardById(boardId) == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    final current = repository.getById(annotationId);
    if (current == null || current.boardId != boardId) {
      throw const RemoteOperationException('not_found', '故事板批注不存在');
    }
    final body = changes.containsKey('body') ? changes['body'] : null;
    final resolved = changes.containsKey('resolved')
        ? changes['resolved']
        : null;
    if (changes.containsKey('body') && body is! String) {
      throw const RemoteOperationException('invalid_changes', 'body 必须是文本');
    }
    if (changes.containsKey('resolved') && resolved is! bool) {
      throw const RemoteOperationException(
        'invalid_changes',
        'resolved 必须是布尔值',
      );
    }
    try {
      repository.update(
        annotationId: annotationId,
        body: body as String?,
        resolved: resolved as bool?,
      );
    } on ArgumentError catch (error) {
      throw RemoteOperationException('invalid_changes', '${error.message}');
    }
    _storyboardRegistry!.publishAnnotationChanged(boardId, action: 'updated');
    return storyboardDetail(boardId);
  }

  RemoteWorkspaceContext _requireWorkspace() {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      throw const RemoteOperationException(
        'workspace_unavailable',
        '桌面端当前没有打开工程',
      );
    }
    return workspace;
  }

  ({ShootingScript script, List<ScriptShot> shots}) _requireScript(
    String scriptId,
  ) {
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    final script = repository.getScript(scriptId);
    if (script == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本不存在');
    }
    return (script: script, shots: repository.listShots(scriptId));
  }

  RemoteShootingWorkflowSource _requireShootingWorkflowSource() {
    final source = _shootingWorkflowRegistry?.source;
    if (source == null) {
      throw const RemoteOperationException(
        'feature_unavailable',
        '拍摄脚本工作流远程功能尚未启用',
      );
    }
    return source;
  }

  RemoteTaskRegistry _requireTaskRegistry() {
    final registry = _taskRegistry;
    if (registry == null) {
      throw const RemoteOperationException('feature_unavailable', '后台任务功能尚未启用');
    }
    return registry;
  }

  RemoteExportRegistry _requireExportRegistry() {
    final registry = _exportRegistry;
    if (registry == null) {
      throw const RemoteOperationException('feature_unavailable', '导出远程功能尚未启用');
    }
    return registry;
  }

  RemoteVideoAnalysisRegistry _requireVideoAnalysisRegistry() {
    final registry = _videoAnalysisRegistry;
    if (registry == null) {
      throw const RemoteOperationException(
        'feature_unavailable',
        '视频解析远程功能尚未启用',
      );
    }
    return registry;
  }

  RemoteVideoGenerationRegistry _requireVideoGenerationRegistry() {
    final registry = _videoGenerationRegistry;
    if (registry == null) {
      throw const RemoteOperationException(
        'feature_unavailable',
        '视频生成远程功能尚未启用',
      );
    }
    return registry;
  }

  RemoteSettingsRegistry _requireSettingsRegistry() {
    final registry = _settingsRegistry;
    if (registry == null || !registry.isAvailable) {
      throw const RemoteOperationException('feature_unavailable', '设置远程功能尚未启用');
    }
    return registry;
  }

  T _runVideoOperation<T>(T Function() operation) {
    try {
      return operation();
    } on RemoteVideoAnalysisSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  T _runVideoGenerationOperation<T>(T Function() operation) {
    try {
      return operation();
    } on RemoteVideoGenerationSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  T _runExportOperation<T>(T Function() operation) {
    try {
      return operation();
    } on RemoteExportSourceException catch (error) {
      throw RemoteOperationException(error.code, error.message);
    }
  }

  RemoteExportCommand _exportCommand(Map<String, Object?> body) {
    const allowed = {
      'kind',
      'boardIds',
      'videoId',
      'scriptId',
      'format',
      'resolution',
      'includeSummaryPage',
      'includeMultiDimensionAnalysis',
      'includeShotDetails',
    };
    final unknown = body.keys.toSet().difference(allowed);
    if (unknown.isNotEmpty) {
      throw FormatException('导出请求包含未知字段：${unknown.join('、')}');
    }

    String requiredText(String key) {
      final value = body[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key 必须是非空文本');
      }
      return value.trim();
    }

    String optionalText(String key) {
      final value = body[key];
      if (value == null) return '';
      if (value is! String) throw FormatException('$key 必须是文本');
      return value.trim();
    }

    bool? optionalBool(String key) {
      final value = body[key];
      if (value == null) return null;
      if (value is! bool) throw FormatException('$key 必须是布尔值');
      return value;
    }

    final kind = requiredText('kind');
    if (!const {
      'storyboardDocument',
      'boardImages',
      'shootingScript',
      'analysisReport',
      'timelineXml',
    }.contains(kind)) {
      throw const FormatException('kind 不是允许的导出类型');
    }

    final boardIds = <String>[];
    final rawBoardIds = body['boardIds'];
    if (rawBoardIds != null) {
      if (rawBoardIds is! List) {
        throw const FormatException('boardIds 必须是文本数组');
      }
      for (final value in rawBoardIds) {
        if (value is! String || value.trim().isEmpty) {
          throw const FormatException('boardIds 只能包含非空文本');
        }
        final id = value.trim();
        if (!boardIds.contains(id)) boardIds.add(id);
      }
    }
    if (const {
          'storyboardDocument',
          'boardImages',
          'shootingScript',
        }.contains(kind) &&
        boardIds.isEmpty) {
      throw const FormatException('该导出类型必须选择至少一个故事板');
    }

    final videoId = optionalText('videoId');
    final scriptId = optionalText('scriptId');
    if (kind == 'analysisReport' && videoId.isEmpty) {
      throw const FormatException('解析报告导出必须提供 videoId');
    }
    if (kind == 'timelineXml' && scriptId.isEmpty) {
      throw const FormatException('时间线导出必须提供 scriptId');
    }

    final format = optionalText('format');
    final resolution = optionalText('resolution');
    if (kind == 'storyboardDocument' &&
        (!const {'png', 'jpg', 'pdf'}.contains(format) ||
            !const {'standard', 'sourceDetail'}.contains(resolution))) {
      throw const FormatException('故事板导出格式或分辨率无效');
    }
    if (kind == 'analysisReport' &&
        !const {'xlsx', 'pdf', 'png', 'jpg'}.contains(format)) {
      throw const FormatException('解析报告导出格式无效');
    }

    return RemoteExportCommand(
      kind: kind,
      boardIds: List.unmodifiable(boardIds),
      videoId: videoId,
      scriptId: scriptId,
      format: format,
      resolution: resolution,
      includeSummaryPage: optionalBool('includeSummaryPage'),
      includeMultiDimensionAnalysis: optionalBool(
        'includeMultiDimensionAnalysis',
      ),
      includeShotDetails: optionalBool('includeShotDetails'),
    );
  }

  RemoteVideoGenerationCommand _videoGenerationCommand(
    Map<String, Object?> body,
  ) {
    String? optionalText(String key) {
      if (!body.containsKey(key) || body[key] == null) return null;
      final value = body[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key 必须是非空文本');
      }
      return value.trim();
    }

    final rawShotIds = body['shotIds'];
    final shotIds = <String>[];
    if (rawShotIds != null) {
      if (rawShotIds is! List) {
        throw const FormatException('shotIds 必须是文本数组');
      }
      for (final value in rawShotIds) {
        if (value is! String || value.trim().isEmpty) {
          throw const FormatException('shotIds 只能包含非空文本');
        }
        final normalized = value.trim();
        if (!shotIds.contains(normalized)) shotIds.add(normalized);
      }
    }

    final parameters = <String, String>{};
    final rawParameters = body['parameters'];
    if (rawParameters != null) {
      if (rawParameters is! Map) {
        throw const FormatException('parameters 必须是对象');
      }
      for (final entry in rawParameters.entries) {
        final key = '${entry.key}'.trim();
        final value = entry.value;
        if (key.isEmpty ||
            (value is! String && value is! num && value is! bool)) {
          throw const FormatException('parameters 只能包含文本键和标量值');
        }
        parameters[key] = '$value'.trim();
      }
    }

    final overrides = <String, RemoteVideoGenerationShotOverride>{};
    final rawOverrides = body['shotOverrides'];
    if (rawOverrides != null) {
      if (rawOverrides is! Map) {
        throw const FormatException('shotOverrides 必须是对象');
      }
      for (final entry in rawOverrides.entries) {
        final shotId = '${entry.key}'.trim();
        final value = entry.value;
        if (shotId.isEmpty || value is! Map) {
          throw const FormatException('shotOverrides 的镜头和配置必须有效');
        }
        final map = value.map((key, value) => MapEntry('$key', value));
        final unknown = map.keys.toSet().difference(const {
          'prompt',
          'promptMode',
          'durationSeconds',
        });
        if (unknown.isNotEmpty) {
          throw FormatException('shotOverrides 包含未知字段：${unknown.join('、')}');
        }
        String? optionalOverrideText(String key) {
          final raw = map[key];
          if (raw == null) return null;
          if (raw is! String) throw FormatException('$key 必须是文本');
          return raw.trim();
        }

        final duration = map['durationSeconds'];
        if (duration != null && duration is! num) {
          throw const FormatException('durationSeconds 必须是数字');
        }
        overrides[shotId] = RemoteVideoGenerationShotOverride(
          prompt: optionalOverrideText('prompt'),
          promptMode: optionalOverrideText('promptMode'),
          durationSeconds: duration?.toDouble(),
        );
      }
    }

    return RemoteVideoGenerationCommand(
      scriptId: optionalText('scriptId'),
      shotIds: List.unmodifiable(shotIds),
      model: optionalText('model'),
      parameters: Map.unmodifiable(parameters),
      shotOverrides: Map.unmodifiable(overrides),
    );
  }

  RemoteStoryboardSource _requireStoryboardSource() {
    final source = _storyboardRegistry?.source;
    if (source == null) {
      throw const RemoteOperationException(
        'workspace_unavailable',
        '桌面端故事板工作区尚未就绪',
      );
    }
    return source;
  }

  void _requireStoryboardRevision(String boardId, int expectedRevision) {
    final currentRevision = _storyboardRegistry!.revisionFor(boardId);
    if (currentRevision != expectedRevision) {
      throw RemoteOperationException('revision_conflict', '故事板已在其他位置更新', {
        'currentRevision': currentRevision,
      });
    }
  }

  RemoteStoryboardEditCommand _storyboardEditCommand(
    RemoteStoryboardBoardRecord board,
    Map<String, Object?> changes,
  ) {
    String? name;
    if (changes.containsKey('name')) {
      final value = changes['name'];
      if (value is! String ||
          value.trim().isEmpty ||
          value.trim().length > 200) {
        throw const RemoteOperationException(
          'invalid_changes',
          'name 必须是 1 到 200 个字符',
        );
      }
      name = value.trim();
    }

    var itemCaptions = const <String, String>{};
    if (changes.containsKey('itemCaptions')) {
      final value = changes['itemCaptions'];
      if (value is! Map) {
        throw const RemoteOperationException(
          'invalid_changes',
          'itemCaptions 必须是对象',
        );
      }
      final validAssetIds = board.items.map((item) => item.assetId).toSet();
      final parsed = <String, String>{};
      for (final entry in value.entries) {
        final assetId = '${entry.key}'.trim();
        final caption = entry.value;
        if (!validAssetIds.contains(assetId)) {
          throw RemoteOperationException(
            'invalid_changes',
            '故事板中不存在镜头 $assetId',
          );
        }
        if (caption is! String || caption.length > 60000) {
          throw const RemoteOperationException(
            'invalid_changes',
            '镜头描述必须是最多 60000 个字符的文本',
          );
        }
        parsed[assetId] = caption;
      }
      itemCaptions = parsed;
    }

    List<String>? rowCaptions;
    if (changes.containsKey('rowCaptions')) {
      final value = changes['rowCaptions'];
      if (value is! List || value.length != board.rows) {
        throw RemoteOperationException(
          'invalid_changes',
          'rowCaptions 必须包含 ${board.rows} 行文本',
        );
      }
      final parsed = <String>[];
      for (final caption in value) {
        if (caption is! String || caption.length > 60000) {
          throw const RemoteOperationException(
            'invalid_changes',
            '逐行描述必须是最多 60000 个字符的文本',
          );
        }
        parsed.add(caption);
      }
      rowCaptions = parsed;
    }

    RemoteStoryboardSummaryRecord? summary;
    var clearSummary = false;
    if (changes.containsKey('summary')) {
      final value = changes['summary'];
      if (value is! Map) {
        throw const RemoteOperationException(
          'invalid_changes',
          'summary 必须是对象',
        );
      }
      const fields = {'outline', 'content', 'scenes', 'props'};
      final unknown = value.keys
          .map((key) => '$key')
          .toSet()
          .difference(fields);
      if (unknown.isNotEmpty) {
        throw RemoteOperationException('invalid_changes', 'summary 包含未知字段', {
          'fields': unknown.toList()..sort(),
        });
      }
      String summaryText(String key) {
        final current = switch (key) {
          'outline' => board.summary?.outline ?? '',
          'content' => board.summary?.content ?? '',
          'scenes' => board.summary?.scenes ?? '',
          _ => board.summary?.props ?? '',
        };
        if (!value.containsKey(key)) return current;
        final next = value[key];
        if (next is! String || next.length > 60000) {
          throw RemoteOperationException(
            'invalid_changes',
            '$key 必须是最多 60000 个字符的文本',
          );
        }
        return next;
      }

      summary = RemoteStoryboardSummaryRecord(
        outline: summaryText('outline'),
        content: summaryText('content'),
        scenes: summaryText('scenes'),
        props: summaryText('props'),
      );
      clearSummary =
          summary.outline.trim().isEmpty &&
          summary.content.trim().isEmpty &&
          summary.scenes.trim().isEmpty &&
          summary.props.trim().isEmpty;
    }
    return RemoteStoryboardEditCommand(
      boardId: board.id,
      name: name,
      itemCaptions: itemCaptions,
      rowCaptions: rowCaptions,
      summary: clearSummary ? null : summary,
      clearSummary: clearSummary,
    );
  }

  void _pruneAnnotations(
    RemoteStoryboardReviewRepository repository,
    RemoteStoryboardSource source,
  ) {
    repository.prune(
      boardIds: source.boards.map((board) => board.id).toSet(),
      assetIdsByBoard: {
        for (final board in source.boards)
          board.id: board.items.map((item) => item.assetId).toSet(),
      },
    );
  }

  Map<String, Object?> _shootingWorkflowJson(
    RemoteShootingWorkflowRecord workflow,
  ) => {
    'scriptId': workflow.scriptId,
    'currentStep': workflow.currentStep,
    'statuses': {
      'confirmShots': workflow.confirmShotsStatus,
      'prepareAssets': workflow.prepareAssetsStatus,
      'composePrompts': workflow.composePromptsStatus,
    },
    'shotCount': workflow.shotCount,
    'confirmedShotCount': workflow.confirmedShotCount,
    'promptCount': workflow.promptCount,
    'analysisProgress': {
      'completed': workflow.analysisCompletedCount,
      'failed': workflow.analysisFailedCount,
      'total': workflow.analysisTotalCount,
    },
    'isBusy': workflow.isBusy,
    'message': workflow.message,
    'errorMessage': workflow.errorMessage,
    'assets': [
      for (final asset in workflow.assets)
        {
          'id': asset.id,
          'name': asset.name,
          'type': asset.type,
          'description': asset.description,
          'referenceNumber': asset.referenceNumber,
          'mediaId': ?_mediaRegistry?.registerProjectFile(asset.localPath),
        },
    ],
    'links': [
      for (final link in workflow.links)
        {
          'shotId': link.shotId,
          'assetId': link.assetId,
          'matchSource': link.matchSource,
          'confidence': link.confidence,
          'matchReason': link.matchReason,
          'confirmed': link.confirmed,
          'locked': link.locked,
        },
    ],
    'replicas': [
      for (final replica in workflow.replicas)
        {
          'shotId': replica.shotId,
          'status': replica.status,
          'errorMessage': replica.errorMessage,
          'mediaId': ?_mediaRegistry?.registerProjectFile(replica.localPath),
        },
    ],
  };

  Map<String, Object?> _storyboardSummary(
    RemoteStoryboardBoardRecord board, {
    required int revision,
    required List<RemoteStoryboardAnnotation> annotations,
  }) => {
    'id': board.id,
    'name': board.name,
    'groupId': board.groupId,
    'revision': revision,
    'locked': board.locked,
    'rows': board.rows,
    'columns': board.columns,
    'itemCount': board.items.length,
    'annotationCount': annotations.length,
    'unresolvedAnnotationCount': annotations
        .where((annotation) => !annotation.resolved)
        .length,
  };

  Map<String, Object?> _storyboardDetail(
    RemoteStoryboardBoardRecord board, {
    required int revision,
    required List<RemoteStoryboardAnnotation> annotations,
  }) => {
    ..._storyboardSummary(board, revision: revision, annotations: annotations),
    'width': board.width,
    'height': board.height,
    'gap': board.gap,
    'storyDescriptionEnabled': board.storyDescriptionEnabled,
    'rowDescriptionEnabled': board.rowDescriptionEnabled,
    'rowCaptions': board.rowCaptions,
    'rowDividerEnabled': board.rowDividerEnabled,
    'rowDividerStyle': board.rowDividerStyle,
    'rowDividerOpacity': board.rowDividerOpacity,
    'titleAlignment': board.titleAlignment,
    'portraitMode': board.portraitMode,
    'summary': board.summary == null
        ? null
        : {
            'outline': board.summary!.outline,
            'content': board.summary!.content,
            'scenes': board.summary!.scenes,
            'props': board.summary!.props,
          },
    'items': [for (final item in board.items) _storyboardItemJson(item)],
    'annotations': [
      for (final annotation in annotations) _annotationJson(annotation),
    ],
  };

  Map<String, Object?> _storyboardItemJson(RemoteStoryboardItemRecord item) {
    final mediaId = _mediaRegistry?.registerProjectFile(item.localPath);
    return {
      'assetId': item.assetId,
      'sourceName': item.sourceName,
      'indexNo': item.indexNo,
      'caption': item.caption,
      'slotIndex': item.slotIndex,
      'flipHorizontal': item.flipHorizontal,
      'flipVertical': item.flipVertical,
      'resourceRemoved': item.resourceRemoved,
      'imageRemotelyAvailable': mediaId != null,
      'imageMediaId': ?mediaId,
    };
  }

  Map<String, Object?> _storyboardAssetJson(
    RemoteStoryboardAssetRecord asset, {
    required bool used,
  }) {
    final mediaId = _mediaRegistry?.registerProjectFile(asset.localPath);
    return {
      'id': asset.id,
      'sourceName': asset.sourceName,
      'indexNo': asset.indexNo,
      'used': used,
      'imageRemotelyAvailable': mediaId != null,
      'imageMediaId': ?mediaId,
    };
  }

  Map<String, Object?> _annotationJson(RemoteStoryboardAnnotation annotation) =>
      {
        'id': annotation.id,
        'assetId': annotation.assetId,
        'body': annotation.body,
        'authorName': annotation.authorName,
        'createdAt': annotation.createdAt.toUtc().toIso8601String(),
        'updatedAt': annotation.updatedAt.toUtc().toIso8601String(),
        'resolved': annotation.resolved,
      };

  ScriptShot _applyShotChanges(
    ScriptShot shot,
    Map<String, Object?> changes,
    DateTime now,
  ) {
    String text(String key, String current) {
      if (!changes.containsKey(key)) return current;
      final value = changes[key];
      if (value is! String) {
        throw RemoteOperationException('invalid_changes', '$key 必须是文本');
      }
      if (value.length > 60000) {
        throw RemoteOperationException('invalid_changes', '$key 超过 60000 个字符');
      }
      return value;
    }

    double duration() {
      if (!changes.containsKey('durationSeconds')) return shot.durationSeconds;
      final value = changes['durationSeconds'];
      if (value is! num || !value.isFinite || value < 0 || value > 3600) {
        throw const RemoteOperationException(
          'invalid_changes',
          'durationSeconds 必须是 0 到 3600 之间的数字',
        );
      }
      return value.toDouble();
    }

    return shot.copyWith(
      durationSeconds: duration(),
      visual: text('visual', shot.visual),
      content: text('content', shot.content),
      freeCreationDescription: text(
        'freeCreationDescription',
        shot.freeCreationDescription,
      ),
      shotSize: text('shotSize', shot.shotSize),
      cameraMovement: text('cameraMovement', shot.cameraMovement),
      cameraNotes: text('cameraNotes', shot.cameraNotes),
      composition: text('composition', shot.composition),
      cameraAngle: text('cameraAngle', shot.cameraAngle),
      lightingMood: text('lightingMood', shot.lightingMood),
      colorPalette: text('colorPalette', shot.colorPalette),
      visualFocus: text('visualFocus', shot.visualFocus),
      transitionHint: text('transitionHint', shot.transitionHint),
      movementTrend: text('movementTrend', shot.movementTrend),
      actionStage: text('actionStage', shot.actionStage),
      scene: text('scene', shot.scene),
      productCode: text('productCode', shot.productCode),
      productStyling: text('productStyling', shot.productStyling),
      dialogue: text('dialogue', shot.dialogue),
      sound: text('sound', shot.sound),
      prompt: text('prompt', shot.prompt),
      replicationInstructions: text(
        'replicationInstructions',
        shot.replicationInstructions,
      ),
      generationFeedback: text('generationFeedback', shot.generationFeedback),
      updatedAt: now,
    );
  }

  Map<String, Object?> _scriptDetail(
    ShootingScriptRepository repository,
    ShootingScript script,
  ) => {
    ..._scriptSummary(
      script,
      shotCount: repository.listShots(script.id).length,
    ),
    'shots': [
      for (final shot in repository.listShots(script.id)) _shotJson(shot),
    ],
  };

  Map<String, Object?> _settingsJson(RemoteSettingsSnapshot settings) => {
    'extractionStrategies': [
      for (final option in settings.extractionStrategies)
        _settingsOptionJson(option),
    ],
    'selectedExtractionStrategy': settings.selectedExtractionStrategy,
    'visionModels': [
      for (final option in settings.visionModels) _settingsOptionJson(option),
    ],
    'selectedVisionModelId': settings.selectedVisionModelId,
    'imageGenerationModels': [
      for (final option in settings.imageGenerationModels)
        _settingsOptionJson(option),
    ],
    'selectedImageGenerationModelId': settings.selectedImageGenerationModelId,
    'videoGenerationModels': [
      for (final option in settings.videoGenerationModels)
        _settingsOptionJson(option),
    ],
    'selectedVideoGenerationModelId': settings.selectedVideoGenerationModelId,
  };

  Map<String, Object?> _settingsOptionJson(RemoteSettingsOption option) => {
    'id': option.id,
    'name': option.name,
    'detail': option.detail,
  };

  Map<String, Object?> _scriptSummary(
    ShootingScript script, {
    required int shotCount,
  }) => {
    'id': script.id,
    'name': script.name,
    'status': script.status.name,
    'version': script.version,
    'shotCount': shotCount,
    'updatedAt': script.updatedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> _shotJson(ScriptShot shot) {
    final mediaId = _mediaRegistry?.registerProjectFile(shot.framePath);
    return {
      'id': shot.id,
      'shotNumber': shot.shotNumber,
      'durationSeconds': shot.durationSeconds,
      'frameAvailable': shot.framePath.trim().isNotEmpty,
      'frameRemotelyAvailable': mediaId != null,
      'frameMediaId': ?mediaId,
      'visual': shot.visual,
      'content': shot.content,
      'freeCreationDescription': shot.freeCreationDescription,
      'shotSize': shot.shotSize,
      'cameraMovement': shot.cameraMovement,
      'cameraNotes': shot.cameraNotes,
      'composition': shot.composition,
      'cameraAngle': shot.cameraAngle,
      'lightingMood': shot.lightingMood,
      'colorPalette': shot.colorPalette,
      'visualFocus': shot.visualFocus,
      'transitionHint': shot.transitionHint,
      'movementTrend': shot.movementTrend,
      'actionStage': shot.actionStage,
      'continuesFromPrevious': shot.continuesFromPrevious,
      'continuesToNext': shot.continuesToNext,
      'scene': shot.scene,
      'productCode': shot.productCode,
      'productStyling': shot.productStyling,
      'dialogue': shot.dialogue,
      'sound': shot.sound,
      'prompt': shot.prompt,
      'replicationInstructions': shot.replicationInstructions,
      'generationFeedback': shot.generationFeedback,
      'status': shot.status.name,
      'updatedAt': shot.updatedAt.toUtc().toIso8601String(),
    };
  }
}
