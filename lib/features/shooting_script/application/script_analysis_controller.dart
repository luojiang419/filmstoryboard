import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/vision_request_rate_limiter.dart';
import '../../replicate/data/bundled_video_skill_library.dart';
import '../../replicate/data/h3_skill_library.dart';
import '../../replicate/data/video_skill_router.dart';
import '../../replicate/data/seedance_prompt_generation_service.dart';
import '../../replicate/domain/h3_prompt_style.dart';
import '../../settings/application/settings_controller.dart';
import '../../storyboard/domain/cinematic_motion_policy.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/script_multimodal_analysis_service.dart';
import '../data/shooting_script_workflow_repository.dart';
import '../domain/script_shot_group.dart';
import '../domain/shooting_script_models.dart';
import '../domain/shooting_script_workflow_models.dart';
import 'shooting_script_controller.dart';

final scriptAnalysisControllerProvider =
    Provider<ShootingScriptAnalysisController>(
      (ref) {
        final controller = ShootingScriptAnalysisController(
          shootingScriptController: ref.watch(shootingScriptControllerProvider),
          repository: ShootingScriptWorkflowRepository(
            ref.watch(appDatabaseProvider),
          ),
          settingsController: ref.watch(settingsControllerProvider),
        );
        ref.onDispose(controller.dispose);
        return controller;
      },
      dependencies: [
        appDatabaseProvider,
        settingsControllerProvider,
        shootingScriptControllerProvider,
      ],
    );

class ScriptAnalysisState {
  const ScriptAnalysisState({
    this.scriptId = '',
    this.analyses = const [],
    this.isBusy = false,
    this.completedCount = 0,
    this.failedCount = 0,
    this.totalCount = 0,
    this.message = '',
    this.errorMessage = '',
  });

  final String scriptId;
  final List<ScriptShotAnalysisRecord> analyses;
  final bool isBusy;
  final int completedCount;
  final int failedCount;
  final int totalCount;
  final String message;
  final String errorMessage;

  ScriptAnalysisState copyWith({
    String? scriptId,
    List<ScriptShotAnalysisRecord>? analyses,
    bool? isBusy,
    int? completedCount,
    int? failedCount,
    int? totalCount,
    String? message,
    String? errorMessage,
  }) => ScriptAnalysisState(
    scriptId: scriptId ?? this.scriptId,
    analyses: analyses ?? this.analyses,
    isBusy: isBusy ?? this.isBusy,
    completedCount: completedCount ?? this.completedCount,
    failedCount: failedCount ?? this.failedCount,
    totalCount: totalCount ?? this.totalCount,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  ScriptShotAnalysisRecord? forShot(String shotId) {
    for (final item in analyses) {
      if (item.shotId == shotId) return item;
    }
    return null;
  }
}

class ShootingScriptAnalysisController
    extends ValueNotifier<ScriptAnalysisState> {
  static const _analysisRuleVersion = 9;
  static const _maximumLegacyAutoDurationSeconds = 5.0;

  ShootingScriptAnalysisController({
    required ShootingScriptController shootingScriptController,
    required ShootingScriptWorkflowRepository repository,
    required SettingsController settingsController,
    ScriptMultimodalAnalysisService? analysisService,
    H3SkillLibrary? skillLibrary,
    VideoSkillLibrary? videoSkillLibrary,
    SeedancePromptGenerationService promptService =
        const SeedancePromptGenerationService(),
    Uuid uuid = const Uuid(),
  }) : _shootingScriptController = shootingScriptController,
       _repository = repository,
       _settingsController = settingsController,
       _analysisService = analysisService ?? ScriptMultimodalAnalysisService(),
       _ownsAnalysisService = analysisService == null,
       _skillLibrary = skillLibrary ?? BundledH3SkillLibrary(),
       _videoSkillLibrary = videoSkillLibrary ?? BundledVideoSkillLibrary(),
       _promptService = promptService,
       _uuid = uuid,
       super(const ScriptAnalysisState()) {
    _shootingScriptController.addListener(_handleScriptChanged);
    refresh();
  }

  final ShootingScriptController _shootingScriptController;
  final ShootingScriptWorkflowRepository _repository;
  final SettingsController _settingsController;
  final ScriptMultimodalAnalysisService _analysisService;
  final bool _ownsAnalysisService;
  final H3SkillLibrary _skillLibrary;
  final VideoSkillLibrary _videoSkillLibrary;
  final SeedancePromptGenerationService _promptService;
  final Uuid _uuid;
  bool _disposed = false;
  bool _cancelRequested = false;

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleScriptChanged);
    if (_ownsAnalysisService) {
      _analysisService.close();
    }
    super.dispose();
  }

  void refresh({bool preserveBusy = false}) {
    final script = _shootingScriptController.value.selectedScript;
    if (script == null) {
      value = const ScriptAnalysisState();
      return;
    }
    final analyses = _repository.listAnalyses(script.id);
    final wasBusy = value.isBusy;
    value = value.copyWith(
      scriptId: script.id,
      analyses: analyses,
      totalCount: _shootingScriptController.value.shots.length,
      completedCount: analyses
          .where((item) => item.status == ProcessingStatus.completed)
          .length,
      failedCount: analyses
          .where((item) => item.status == ProcessingStatus.failed)
          .length,
      isBusy: preserveBusy ? wasBusy : false,
    );
  }

  Future<void> analyzeAll({
    bool overwriteExisting = false,
    bool onlyFailed = false,
    Map<String, String> imagePathOverrides = const {},
    bool requireImageOverrides = false,
  }) async {
    _cancelRequested = false;
    final script = _shootingScriptController.value.selectedScript;
    final shots = _shootingScriptController.value.shots;
    if (script == null || shots.isEmpty) {
      value = value.copyWith(message: '', errorMessage: '当前脚本没有可解析的镜头');
      return;
    }
    final failedShotIds = onlyFailed
        ? _repository
              .listAnalyses(script.id)
              .where((item) => item.status == ProcessingStatus.failed)
              .map((item) => item.shotId)
              .toSet()
        : const <String>{};
    final targets = onlyFailed
        ? shots.where((shot) => failedShotIds.contains(shot.id)).toList()
        : shots;
    if (targets.isEmpty) {
      value = value.copyWith(
        message: onlyFailed ? '没有需要重试的失败镜头' : '',
        errorMessage: '',
      );
      return;
    }
    value = value.copyWith(
      scriptId: script.id,
      analyses: const [],
      isBusy: true,
      completedCount: 0,
      failedCount: 0,
      totalCount: targets.length,
      message: '正在解析 0/${targets.length} 个镜头…',
      errorMessage: '',
    );
    var nextIndex = 0;
    var processed = 0;
    Future<void> processTargets() async {
      while (!_disposed && !_cancelRequested && nextIndex < targets.length) {
        final shot = targets[nextIndex++];
        await _analyzeOne(
          script: script,
          shot: shot,
          overwriteExisting: overwriteExisting,
          imagePathOverrides: imagePathOverrides,
          requireImageOverrides: requireImageOverrides,
        );
        processed++;
        if (!_disposed) {
          value = value.copyWith(
            message: '正在解析 $processed/${targets.length} 个镜头…',
          );
        }
      }
    }

    final workers = VisionRequestRateLimiter.maxConcurrentRequestsFor(
      _settingsController.value,
    ).clamp(1, targets.length);
    await Future.wait([
      for (var index = 0; index < workers; index++) processTargets(),
    ]);
    if (_cancelRequested) {
      if (!_disposed) {
        value = value.copyWith(isBusy: false, message: '已取消脚本构建');
      }
      return;
    }
    final failed = value.failedCount;
    if (!_disposed) {
      value = value.copyWith(
        isBusy: false,
        message: failed == 0 ? '脚本自动解析完成' : '解析完成，但有 $failed 个镜头失败',
        errorMessage: failed == 0 ? '' : '$failed 个镜头解析失败',
      );
    }
  }

  Future<bool> buildScript({
    Map<String, String> imagePathOverrides = const {},
    bool requireImageOverrides = false,
    bool onlyFeedbackGroups = false,
  }) => buildScriptFromShotGroups(
    overwriteExisting: true,
    imagePathOverrides: imagePathOverrides,
    requireImageOverrides: requireImageOverrides,
    onlyFeedbackGroups: onlyFeedbackGroups,
  );

  void updateGenerationFeedback(String shotId, String feedback) {
    final shot = _shootingScriptController.value.shots
        .where((item) => item.id == shotId)
        .firstOrNull;
    if (shot == null || shot.generationFeedback == feedback) return;
    _shootingScriptController.updateShot(
      shot.copyWith(
        generationFeedback: feedback,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> analyzeShot(
    String shotId, {
    bool overwriteExisting = false,
    Map<String, String> imagePathOverrides = const {},
    bool requireImageOverrides = false,
  }) async {
    final script = _shootingScriptController.value.selectedScript;
    final shot = _shootingScriptController.value.shots
        .where((item) => item.id == shotId)
        .firstOrNull;
    if (script == null || shot == null) return;
    value = value.copyWith(
      isBusy: true,
      message: '正在解析镜头 ${shot.shotNumber}…',
      errorMessage: '',
    );
    await _analyzeOne(
      script: script,
      shot: shot,
      overwriteExisting: overwriteExisting,
      imagePathOverrides: imagePathOverrides,
      requireImageOverrides: requireImageOverrides,
    );
    if (!_disposed) {
      value = value.copyWith(
        isBusy: false,
        message: '镜头 ${shot.shotNumber} 解析完成',
      );
    }
  }

  Future<bool> buildScriptFromShotGroups({
    bool overwriteExisting = true,
    Map<String, String> imagePathOverrides = const {},
    bool requireImageOverrides = false,
    bool onlyFeedbackGroups = false,
  }) async {
    _cancelRequested = false;
    final script = _shootingScriptController.value.selectedScript;
    final shots = _shootingScriptController.value.shots;
    if (script == null || shots.isEmpty) {
      value = value.copyWith(message: '', errorMessage: '当前脚本没有可构建的镜头');
      return false;
    }
    final allGroups = _groupShots(shots);
    final groups = onlyFeedbackGroups
        ? allGroups
              .where(
                (group) => group.first.generationFeedback.trim().isNotEmpty,
              )
              .toList(growable: false)
        : allGroups;
    if (groups.isEmpty) {
      value = value.copyWith(
        message: onlyFeedbackGroups ? '没有需要根据反馈重构的镜头组' : '',
        errorMessage: '',
      );
      return false;
    }
    value = value.copyWith(
      scriptId: script.id,
      isBusy: true,
      completedCount: 0,
      failedCount: 0,
      totalCount: groups.length,
      message: '正在构建 0/${groups.length} 个镜头组…',
      errorMessage: '',
    );
    final workers = VisionRequestRateLimiter.maxConcurrentRequestsFor(
      _settingsController.value,
    ).clamp(1, groups.length);
    var nextIndex = 0;
    var completed = 0;
    var failed = 0;
    Future<void> processGroups() async {
      while (!_disposed &&
          !_cancelRequested &&
          value.isBusy &&
          nextIndex < groups.length) {
        final group = groups[nextIndex++];
        final success = await _analyzeGroup(
          script: script,
          shots: group,
          overwriteExisting: overwriteExisting,
          imagePathOverrides: imagePathOverrides,
          requireImageOverrides: requireImageOverrides,
        );
        if (success) {
          completed++;
        } else {
          failed++;
        }
        if (!_disposed) {
          value = value.copyWith(
            completedCount: completed,
            failedCount: failed,
            message:
                '${workers > 1 ? '正在并发构建' : '正在构建'} ${completed + failed}/${groups.length} 个镜头组…',
          );
        }
      }
    }

    await Future.wait([
      for (var index = 0; index < workers; index++) processGroups(),
    ]);
    if (_cancelRequested) {
      if (!_disposed) {
        value = value.copyWith(isBusy: false, message: '已取消脚本构建');
      }
      return false;
    }
    final buildCompleted =
        !_disposed && completed == groups.length && failed == 0;
    if (!_disposed) {
      value = value.copyWith(
        isBusy: false,
        message: buildCompleted
            ? '构建脚本完成'
            : failed > 0
            ? '构建完成，但有 $failed 个镜头组失败'
            : '脚本构建未完成',
        errorMessage: buildCompleted
            ? ''
            : failed > 0
            ? '$failed 个镜头组构建失败'
            : '脚本构建未完成',
      );
    }
    return buildCompleted;
  }

  void cancel() {
    _cancelRequested = true;
    _analysisService.cancelActiveRequests();
    value = value.copyWith(isBusy: false, message: '已取消脚本构建');
  }

  Future<void> _analyzeOne({
    required ShootingScript script,
    required ScriptShot shot,
    required bool overwriteExisting,
    required Map<String, String> imagePathOverrides,
    required bool requireImageOverrides,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = _repository.getAnalysis(shot.id);
    final imageFile = _analysisImageFileForShot(
      shot,
      imagePathOverrides: imagePathOverrides,
      requireImageOverrides: requireImageOverrides,
    );
    if (imageFile == null) {
      _saveFailure(
        shot: shot,
        existing: existing,
        message: requireImageOverrides
            ? '缺少复刻分镜图，无法执行分镜解析'
            : '缺少镜头画面，无法执行多模态解析',
        now: now,
      );
      return;
    }
    try {
      final creativeBrief = await _creativeBrief([shot]);
      final orderedShots = _shootingScriptController.value.shots;
      final shotIndex = orderedShots.indexWhere((item) => item.id == shot.id);
      File? adjacentFile(int index) {
        if (index < 0 || index >= orderedShots.length) return null;
        return _analysisImageFileForShot(
          orderedShots[index],
          imagePathOverrides: imagePathOverrides,
          requireImageOverrides: requireImageOverrides,
        );
      }

      final patch = await _analysisService.analyzeShot(
        settings: _settingsController.value,
        shot: _shotForDurationAnalysis(shot, existing),
        imageFile: imageFile,
        previousImageFile: adjacentFile(shotIndex - 1),
        nextImageFile: adjacentFile(shotIndex + 1),
        creativeBrief: creativeBrief,
        storyContext: _storyContextForRange(
          script: script,
          startShotNumber: shot.shotNumber,
          endShotNumber: shot.shotNumber,
        ),
      );
      var updatedShot = _applyPatch(
        shot,
        patch.values,
        overwriteExisting: overwriteExisting,
      );
      if (overwriteExisting || updatedShot.prompt.trim().isEmpty) {
        final generatedPrompt = _promptService
            .generate(
              shot: updatedShot,
              assets: const [],
              globalStyle:
                  _settingsController.value.replicateDefaultGlobalStyle,
              constraints:
                  _settingsController.value.replicateDefaultConstraints,
              videoReferenceInstruction: script.sourceVideoId == null
                  ? null
                  : '参考视频1中的主体动作、镜头语言、节奏与视觉风格，按以下分镜复刻；保持角色、产品和场景在镜头间连续一致。',
            )
            .prompt;
        updatedShot = updatedShot.copyWith(
          prompt:
              CinematicMotionPolicy.hasExplicitSlowMotionIntent(
                shot.freeCreationDescription,
              )
              ? generatedPrompt
              : CinematicMotionPolicy.enforceRealtimePlayback(generatedPrompt),
        );
      }
      _shootingScriptController.updateShot(updatedShot);
      final sources = <String, String>{
        for (final field in _analysisFields)
          field: _sourceForField(
            field: field,
            original: shot,
            updated: updatedShot,
            patch: patch,
            overwriteExisting: overwriteExisting,
          ),
      };
      _repository.upsertAnalysis(
        ScriptShotAnalysisRecord(
          id: existing?.id ?? _uuid.v4(),
          shotId: shot.id,
          model: _settingsController.value.visionModel,
          status: ProcessingStatus.completed,
          fieldSources: sources,
          fieldConfidence: patch.fieldConfidence,
          promptContext: patch.promptContext,
          promptContextSchemaVersion:
              ScriptShotPromptContext.currentSchemaVersion,
          sourceImageFingerprint: await _sourceImageFingerprint([imageFile]),
          analysisRuleVersion: _analysisRuleVersion,
          rawResponse: patch.rawResponse,
          errorMessage: '',
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      _refreshProgress(script.id);
    } catch (error) {
      _saveFailure(shot: shot, existing: existing, message: '$error', now: now);
    }
  }

  Future<bool> _analyzeGroup({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required bool overwriteExisting,
    required Map<String, String> imagePathOverrides,
    required bool requireImageOverrides,
  }) async {
    final head = shots.first;
    final now = DateTime.now().toUtc();
    final existing = _repository.getAnalysis(head.id);
    final replicaFiles = _completeImageFileGroup(
      shots.map((shot) => imagePathOverrides[shot.id] ?? ''),
    );
    final originalFiles = requireImageOverrides
        ? null
        : _completeImageFileGroup(shots.map((shot) => shot.framePath));
    final files = replicaFiles ?? originalFiles;
    if (files == null) {
      _saveFailure(
        shot: head,
        existing: existing,
        message: requireImageOverrides
            ? '脚本条目缺少完整复刻分镜图组，无法构建'
            : '脚本条目既无完整复刻分镜图组，也无完整原视频帧组，无法构建',
        now: now,
      );
      return false;
    }
    try {
      final creativeBrief = await _creativeBrief(shots);
      final patch = await _analysisService.analyzeShotGroup(
        settings: _settingsController.value,
        shots: _shotsForDurationAnalysis(shots, existing),
        imageFiles: files,
        creativeBrief: _creativeBriefForRevision(head, creativeBrief),
        storyContext: _storyContextForRange(
          script: script,
          startShotNumber: shots.first.shotNumber,
          endShotNumber: shots.last.shotNumber,
        ),
        neighboringCameraPlan: _neighboringCameraPlan(
          startShotNumber: shots.first.shotNumber,
          endShotNumber: shots.last.shotNumber,
        ),
      );
      final durationText = patch.values['durationSeconds'];
      final nonDurationValues = Map<String, String>.of(patch.values)
        ..remove('durationSeconds');
      var updatedHead = _applyPatch(
        head,
        nonDurationValues,
        overwriteExisting: overwriteExisting,
      );
      final durationSeconds = double.tryParse(durationText?.trim() ?? '');
      final durationTarget = shots.last;
      final updatedDurationTarget =
          durationSeconds != null &&
              durationSeconds.isFinite &&
              durationSeconds > 0
          ? durationTarget.copyWith(durationSeconds: durationSeconds)
          : durationTarget;
      if (shots.length == 1) {
        updatedHead = updatedHead.copyWith(
          durationSeconds: updatedDurationTarget.durationSeconds,
        );
      }
      if (head.generationFeedback.trim().isNotEmpty) {
        updatedHead = updatedHead.copyWith(generationFeedback: '');
      }
      if (overwriteExisting || updatedHead.prompt.trim().isEmpty) {
        final generatedPrompt = _promptService
            .generate(
              shot: shots.length == 1
                  ? updatedHead
                  : updatedHead.copyWith(
                      durationSeconds: updatedDurationTarget.durationSeconds,
                    ),
              assets: const [],
              globalStyle:
                  _settingsController.value.replicateDefaultGlobalStyle,
              constraints:
                  _settingsController.value.replicateDefaultConstraints,
              videoReferenceInstruction: script.sourceVideoId == null
                  ? null
                  : '参考视频1中的主体动作、镜头语言、节奏与视觉风格，按以下分镜复刻；保持角色、产品和场景在镜头间连续一致。',
            )
            .prompt;
        updatedHead = updatedHead.copyWith(
          prompt:
              CinematicMotionPolicy.hasExplicitSlowMotionIntent(
                head.freeCreationDescription,
              )
              ? generatedPrompt
              : CinematicMotionPolicy.enforceRealtimePlayback(generatedPrompt),
        );
      }
      _shootingScriptController.updateShot(updatedHead);
      if (durationTarget.id != head.id &&
          updatedDurationTarget.durationSeconds !=
              durationTarget.durationSeconds) {
        _shootingScriptController.updateShot(updatedDurationTarget);
      }
      _repository.upsertAnalysis(
        ScriptShotAnalysisRecord(
          id: existing?.id ?? _uuid.v4(),
          shotId: head.id,
          model: _settingsController.value.visionModel,
          status: ProcessingStatus.completed,
          fieldSources: {
            for (final field in _analysisFields)
              field: _sourceForField(
                field: field,
                original: field == 'durationSeconds' ? durationTarget : head,
                updated: field == 'durationSeconds'
                    ? updatedDurationTarget
                    : updatedHead,
                patch: patch,
                overwriteExisting: overwriteExisting,
              ),
          },
          fieldConfidence: patch.fieldConfidence,
          promptContext: patch.promptContext,
          promptContextSchemaVersion:
              ScriptShotPromptContext.currentSchemaVersion,
          sourceImageFingerprint: await _sourceImageFingerprint(files),
          analysisRuleVersion: _analysisRuleVersion,
          rawResponse: patch.rawResponse,
          errorMessage: '',
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      return true;
    } catch (error) {
      _saveFailure(shot: head, existing: existing, message: '$error', now: now);
      return false;
    }
  }

  static List<List<ScriptShot>> _groupShots(List<ScriptShot> shots) {
    return ScriptShotGroup.group(
      shots,
    ).map((group) => group.shots).toList(growable: false);
  }

  Future<String> _creativeBrief(Iterable<ScriptShot> shots) async {
    final shotList = shots.toList(growable: false);
    final settings = _settingsController.value;
    final preferredStyle = H3PromptStyle.resolve(settings.h3PromptStyleId);
    final route = const VideoSkillRouter().resolve(
      config: settings.activeVideoGenerationApiConfig,
      narrativeText: _skillRoutingText(shotList),
      preferredStyle: preferredStyle,
    );
    final style = route.promptStyle;
    final videoSkillDocument = await _videoSkillLibrary.loadForConfig(
      settings.activeVideoGenerationApiConfig,
    );
    final allowSlowMotion =
        shotList.isNotEmpty &&
        CinematicMotionPolicy.hasExplicitSlowMotionIntent(
          shotList.first.freeCreationDescription,
        );
    return [
      if (shotList.isNotEmpty &&
          shotList.first.freeCreationDescription.trim().isNotEmpty)
        '当前镜头剧情描述（用户原文，剧情与播放速度授权的唯一来源）：${shotList.first.freeCreationDescription.trim()}',
      if (route.supportsH3NarrativeSkill)
        '内容类型：${style.label}。${style.description}${route.automaticallySelected ? '（已按当前剧情自动匹配）' : ''}',
      if (settings.replicateDefaultGlobalStyle.trim().isNotEmpty)
        '全局影像风格：${settings.replicateDefaultGlobalStyle.trim()}',
      if (route.supportsH3NarrativeSkill && !style.isGeneral)
        (await _skillLibrary.loadForStyle(style)).toVisionModelContext(),
      if (videoSkillDocument != null) videoSkillDocument.toVisionModelContext(),
      if (style.visualPromptInstruction.trim().isNotEmpty)
        '逐镜头快速核对契约（不得替代上方完整 Skill）：\n${style.visualPromptInstruction.trim()}',
      if (settings.replicateDefaultConstraints.trim().isNotEmpty)
        '制作边界：${settings.replicateDefaultConstraints.trim()}',
      allowSlowMotion
          ? '播放速度授权：用户已在当前镜头“剧情描述”中明确要求慢动作/升格，仅按原文指定阶段使用。'
          : '播放速度边界（最高优先级）：用户未在当前镜头“剧情描述”中明确要求慢动作/升格。所有动作、表情、环境和声音按正常时间速度推进，禁止任何 Skill、风格惯例或模型自由发挥引入慢动作、慢镜头、慢放、升格、高帧率慢放、speed ramp 或时间拉伸；缓慢运镜只表示摄影机移动速度。',
      '''本次构建的时长与节拍规则（用户要求，优先于上方 Skill 中的每秒指令或固定时间段）：
根据当前画面中的动作阶段、状态变化、运镜幅度和信息量设计自然节奏；不要在画面描述、动作阶段、运镜、声音或转场字段中写“第 N 秒”“0-N 秒”或逐秒任务表。只描述自然的先后关系和完整动作，让视频模型在最终总时长内自行适配。''',
    ].join('\n');
  }

  static String _skillRoutingText(Iterable<ScriptShot> shots) => shots
      .expand(
        (shot) => [
          shot.freeCreationDescription,
          shot.content,
          shot.replicationInstructions,
          shot.generationFeedback,
          shot.cameraNotes,
        ],
      )
      .where((part) => part.trim().isNotEmpty)
      .join('\n');

  String _creativeBriefForRevision(ScriptShot shot, String creativeBrief) {
    final feedback = shot.generationFeedback.trim();
    if (feedback.isEmpty) return creativeBrief;
    return [
      creativeBrief,
      '用户对上一稿的生成反馈（必须优先纠正）：$feedback',
      '上一稿画面描述：${shot.content.trim().isEmpty ? '未填写' : shot.content.trim()}',
      '上一稿导演运镜：${shot.cameraMovement.trim().isEmpty ? '未填写' : shot.cameraMovement.trim()}',
      '请保留与反馈不冲突的正确信息，针对反馈重新设计该镜头的动作、表情、节奏、构图和运镜，不得忽略、改写或弱化用户反馈。',
    ].join('\n');
  }

  String _storyContextForRange({
    required ShootingScript script,
    required int startShotNumber,
    required int endShotNumber,
  }) {
    final shots = [..._shootingScriptController.value.shots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    final currentIndex = shots.indexWhere(
      (shot) => shot.shotNumber == startShotNumber,
    );
    final rangeLabel = startShotNumber == endShotNumber
        ? '镜头 $startShotNumber'
        : '镜头 $startShotNumber-$endShotNumber';
    final sequence = shots
        .map((shot) {
          final analysis = _repository.getAnalysis(shot.id);
          final narrativeFunction =
              analysis?.promptContext.continuity['narrativeFunction']?.trim() ??
              '';
          final story = _firstNonEmpty([
            shot.content,
            shot.visual,
            shot.visualFocus,
          ]);
          final functionText = narrativeFunction.isEmpty
              ? ''
              : '［$narrativeFunction］';
          return '${shot.shotNumber}$functionText：${story.isEmpty ? '待分析' : story}';
        })
        .join(' | ');
    return [
      '脚本《${script.name}》，共 ${shots.length} 个分镜，当前处理 $rangeLabel（第 ${currentIndex < 0 ? startShotNumber : currentIndex + 1}/${shots.length} 个位置）。',
      '故事顺序：$sequence',
      '请判断当前镜头承担建立、推进、揭示、证明、反应、转折、产品记忆点、结果或收束中的哪一项，并让运镜只服务该功能。',
    ].join('\n');
  }

  String _neighboringCameraPlan({
    required int startShotNumber,
    required int endShotNumber,
  }) {
    final shots = [..._shootingScriptController.value.shots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    final previous = shots
        .where((shot) => shot.shotNumber < startShotNumber)
        .lastOrNull;
    final next = shots
        .where((shot) => shot.shotNumber > endShotNumber)
        .firstOrNull;
    return [
      if (previous != null && previous.cameraMovement.trim().isNotEmpty)
        '上一镜头 ${previous.shotNumber}：${previous.cameraMovement.trim()}',
      if (next != null && next.cameraMovement.trim().isNotEmpty)
        '下一镜头 ${next.shotNumber}（待最终构建）：${next.cameraMovement.trim()}',
    ].join('；');
  }

  static String _firstNonEmpty(Iterable<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  static File? _analysisImageFileForShot(
    ScriptShot shot, {
    required Map<String, String> imagePathOverrides,
    required bool requireImageOverrides,
  }) {
    final overridePath = imagePathOverrides[shot.id]?.trim() ?? '';
    final path = overridePath.isNotEmpty
        ? overridePath
        : requireImageOverrides
        ? ''
        : shot.framePath.trim();
    if (path.isEmpty) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  static List<File>? _completeImageFileGroup(Iterable<String> paths) {
    final files = <File>[];
    for (final path in paths) {
      final normalized = path.trim();
      if (normalized.isEmpty) return null;
      final file = File(normalized);
      if (!file.existsSync()) return null;
      files.add(file);
    }
    return files.isEmpty ? null : List.unmodifiable(files);
  }

  void _saveFailure({
    required ScriptShot shot,
    required ScriptShotAnalysisRecord? existing,
    required String message,
    required DateTime now,
  }) {
    _repository.upsertAnalysis(
      ScriptShotAnalysisRecord(
        id: existing?.id ?? _uuid.v4(),
        shotId: shot.id,
        model: _settingsController.value.visionModel,
        status: ProcessingStatus.failed,
        fieldSources: const {},
        fieldConfidence: const {},
        rawResponse: '',
        errorMessage: message,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    _refreshProgress(shot.scriptId);
  }

  void _refreshProgress(String scriptId) {
    final analyses = _repository.listAnalyses(scriptId);
    final completed = analyses
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    final failed = analyses
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    if (!_disposed) {
      value = value.copyWith(
        scriptId: scriptId,
        analyses: analyses,
        completedCount: completed,
        failedCount: failed,
      );
    }
  }

  void _handleScriptChanged() {
    if (!_disposed) refresh(preserveBusy: true);
  }

  static const _analysisFields = [
    'durationSeconds',
    'visual',
    'content',
    'shotSize',
    'cameraMovement',
    'composition',
    'cameraAngle',
    'lightingMood',
    'colorPalette',
    'visualFocus',
    'transitionHint',
    'movementTrend',
    'actionStage',
    'cameraNotes',
    'scene',
    'productCode',
    'productStyling',
    'sound',
  ];

  static Future<String> _sourceImageFingerprint(List<File> files) async {
    if (files.isEmpty) return '';
    if (files.length == 1) {
      return 'sha256:${sha256.convert(await files.single.readAsBytes())}';
    }
    final componentDigests = <String>[];
    for (final file in files) {
      componentDigests.add(sha256.convert(await file.readAsBytes()).toString());
    }
    return 'sha256:${sha256.convert(utf8.encode(componentDigests.join('|')))}';
  }

  static ScriptShot _shotForDurationAnalysis(
    ScriptShot shot,
    ScriptShotAnalysisRecord? existing,
  ) {
    if (!_shouldRecalculateLegacyAutoDuration(shot, existing)) return shot;
    return shot.copyWith(durationSeconds: 0);
  }

  static List<ScriptShot> _shotsForDurationAnalysis(
    List<ScriptShot> shots,
    ScriptShotAnalysisRecord? existing,
  ) {
    if (shots.isEmpty) return shots;
    final durationTarget = shots.last;
    if (!_shouldRecalculateLegacyAutoDuration(durationTarget, existing)) {
      return shots;
    }
    return [
      ...shots.take(shots.length - 1),
      durationTarget.copyWith(durationSeconds: 0),
    ];
  }

  static bool _shouldRecalculateLegacyAutoDuration(
    ScriptShot shot,
    ScriptShotAnalysisRecord? existing,
  ) =>
      shot.durationSeconds > _maximumLegacyAutoDurationSeconds &&
      existing != null &&
      existing.analysisRuleVersion < _analysisRuleVersion &&
      existing.fieldSources['durationSeconds'] == 'model';

  static String _sourceForField({
    required String field,
    required ScriptShot original,
    required ScriptShot updated,
    required ScriptShotAnalysisPatch patch,
    required bool overwriteExisting,
  }) {
    final originalValue = _fieldValue(original, field).trim();
    final updatedValue = _fieldValue(updated, field).trim();
    final modelValueApplied =
        patch.values.containsKey(field) &&
        (overwriteExisting ||
            _shouldApplyWithoutOverwrite(
              field,
              originalValue,
              patch.values[field] ?? '',
            ));
    if (modelValueApplied) return 'model';
    if (originalValue.isNotEmpty && updatedValue.isNotEmpty) return 'preserved';
    return 'unavailable';
  }

  static ScriptShot _applyPatch(
    ScriptShot shot,
    Map<String, String> values, {
    required bool overwriteExisting,
  }) {
    var updated = shot;
    for (final entry in values.entries) {
      if (_manualShotGroupFields.contains(entry.key)) continue;
      final current = _fieldValue(updated, entry.key);
      if (!overwriteExisting &&
          !_shouldApplyWithoutOverwrite(entry.key, current, entry.value)) {
        continue;
      }
      updated = _copyField(updated, entry.key, entry.value);
    }
    return updated;
  }

  static bool _shouldApplyWithoutOverwrite(
    String field,
    String current,
    String incoming,
  ) {
    if (field == 'colorPalette') {
      return _shouldApplyColorPaletteWithoutOverwrite(current, incoming);
    }
    return current.trim().isEmpty;
  }

  static bool _shouldApplyColorPaletteWithoutOverwrite(
    String current,
    String incoming,
  ) {
    final currentText = current.trim();
    final incomingStyle =
        ScriptMultimodalAnalysisService.colorStyleFromPaletteText(
          incoming,
        ).trim();
    if (currentText.isEmpty) {
      return incomingStyle.isNotEmpty;
    }
    if (incomingStyle.isEmpty) {
      return false;
    }
    final currentStyle =
        ScriptMultimodalAnalysisService.colorStyleFromPaletteText(
          currentText,
        ).trim();
    return currentStyle.isNotEmpty && currentStyle != currentText;
  }

  static String _fieldValue(ScriptShot shot, String field) => switch (field) {
    'visual' => shot.visual,
    'durationSeconds' =>
      shot.durationSeconds <= 0 ? '' : '${shot.durationSeconds}',
    'content' => shot.content,
    'shotSize' => shot.shotSize,
    'cameraMovement' => shot.cameraMovement,
    'composition' => shot.composition,
    'cameraAngle' => shot.cameraAngle,
    'lightingMood' => shot.lightingMood,
    'colorPalette' => shot.colorPalette,
    'visualFocus' => shot.visualFocus,
    'transitionHint' => shot.transitionHint,
    'movementTrend' => shot.movementTrend,
    'actionStage' => shot.actionStage,
    'cameraNotes' => shot.cameraNotes,
    'scene' => shot.scene,
    'productCode' => shot.productCode,
    'productStyling' => shot.productStyling,
    'dialogue' => shot.dialogue,
    'sound' => shot.sound,
    _ => '',
  };

  static ScriptShot _copyField(ScriptShot shot, String field, String value) =>
      switch (field) {
        'durationSeconds' => shot.copyWith(
          durationSeconds:
              double.tryParse(value.trim()) ?? shot.durationSeconds,
        ),
        'visual' => shot.copyWith(visual: value),
        'content' => shot.copyWith(content: value),
        'shotSize' => shot.copyWith(shotSize: value),
        'cameraMovement' => shot.copyWith(cameraMovement: value),
        'composition' => shot.copyWith(composition: value),
        'cameraAngle' => shot.copyWith(cameraAngle: value),
        'lightingMood' => shot.copyWith(lightingMood: value),
        'colorPalette' => shot.copyWith(colorPalette: value),
        'visualFocus' => shot.copyWith(visualFocus: value),
        'transitionHint' => shot.copyWith(transitionHint: value),
        'movementTrend' => shot.copyWith(movementTrend: value),
        'actionStage' => shot.copyWith(actionStage: value),
        'cameraNotes' => shot.copyWith(cameraNotes: value),
        'scene' => shot.copyWith(scene: value),
        'productCode' => shot.copyWith(productCode: value),
        'productStyling' => shot.copyWith(productStyling: value),
        'sound' => shot.copyWith(sound: value),
        _ => shot,
      };

  static const _manualShotGroupFields = {
    'continuesFromPrevious',
    'continuesToNext',
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
