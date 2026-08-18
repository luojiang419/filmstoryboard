import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/video_generation_api_config.dart';
import '../../shooting_script/domain/shooting_asset_library_models.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/data/script_multimodal_analysis_service.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/script_asset_slot_policy.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/data/shooting_script_workflow_repository.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../shooting_script/domain/structured_prompt_shot_adapter.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../../storyboard/domain/cinematic_motion_policy.dart';
import '../../storyboard/domain/image_generation_provider_resolver.dart';
import '../../story_design/domain/gemini_storyboard_prompt.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/domain/video_action_sequence.dart';
import '../../video_generation/domain/h3_video_prompt_adapter.dart';
import '../../video_generation/domain/kling_video_prompt_adapter.dart';
import '../data/bundled_video_skill_library.dart';
import '../data/dwpose_model_manager.dart';
import '../data/dwpose_service.dart';
import '../data/replicate_repository.dart';
import '../data/replicate_prompt_export_service.dart';
import '../data/replication_asset_view_selection_service.dart';
import '../data/replication_frame_analysis_service.dart';
import '../data/replication_generation_review_service.dart';
import '../data/seedance_prompt_generation_service.dart';
import '../data/free_creation_video_prompt_writing_service.dart';
import '../data/h3_prompt_writing_service.dart';
import '../data/h3_skill_library.dart';
import '../data/video_skill_router.dart';
import '../domain/h3_prompt_style.dart';
import '../domain/nano_banana_asset_manifest.dart';
import '../domain/nano_banana_replication_prompt_compiler.dart';
import '../domain/replicate_models.dart';

final replicateControllerProvider = Provider<ReplicateController>(
  (ref) {
    final controller = ReplicateController(
      repository: ReplicateRepository(ref.watch(appDatabaseProvider)),
      shootingScriptController: ref.watch(shootingScriptControllerProvider),
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      workflowRepository: ShootingScriptWorkflowRepository(
        ref.watch(appDatabaseProvider),
      ),
      assetBindingController: ref.watch(scriptAssetBindingControllerProvider),
      enforceFreeCreationMode: true,
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
    scriptAssetBindingControllerProvider,
    settingsControllerProvider,
    shootingScriptControllerProvider,
  ],
);

class ReplicateState {
  const ReplicateState({
    this.scripts = const [],
    this.shots = const [],
    this.selectedScriptId = '',
    this.run,
    this.assets = const [],
    this.replicatedImages = const [],
    this.prompts = const [],
    this.shotGuides = const [],
    this.isBusy = false,
    this.isAnalyzingFrames = false,
    this.message = '',
    this.errorMessage = '',
  });

  final List<ShootingScript> scripts;
  final List<ScriptShot> shots;
  final String selectedScriptId;
  final ReplicateRun? run;
  final List<ReplicateAsset> assets;
  final List<ReplicatedShotImage> replicatedImages;
  final List<ShotPrompt> prompts;
  final List<ReplicateShotGuide> shotGuides;
  final bool isBusy;
  final bool isAnalyzingFrames;
  final String message;
  final String errorMessage;

  ShootingScript? get selectedScript {
    for (final script in scripts) {
      if (script.id == selectedScriptId) {
        return script;
      }
    }
    return null;
  }

  List<ScriptShot> get confirmedShots {
    // 镜头步骤只负责查阅和编辑，不再要求用户逐条点击确认；进入后续
    // 步骤时，当前脚本中的全部镜头都视为可继续处理的镜头。
    return [...shots];
  }

  ReplicateState copyWith({
    List<ShootingScript>? scripts,
    List<ScriptShot>? shots,
    String? selectedScriptId,
    ReplicateRun? run,
    List<ReplicateAsset>? assets,
    List<ReplicatedShotImage>? replicatedImages,
    List<ShotPrompt>? prompts,
    List<ReplicateShotGuide>? shotGuides,
    bool? isBusy,
    bool? isAnalyzingFrames,
    String? message,
    String? errorMessage,
  }) => ReplicateState(
    scripts: scripts ?? this.scripts,
    shots: shots ?? this.shots,
    selectedScriptId: selectedScriptId ?? this.selectedScriptId,
    run: run ?? this.run,
    assets: assets ?? this.assets,
    replicatedImages: replicatedImages ?? this.replicatedImages,
    prompts: prompts ?? this.prompts,
    shotGuides: shotGuides ?? this.shotGuides,
    isBusy: isBusy ?? this.isBusy,
    isAnalyzingFrames: isAnalyzingFrames ?? this.isAnalyzingFrames,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class ReplicateExportResult {
  const ReplicateExportResult({required this.xlsxFile});

  final File xlsxFile;
}

class ReplicateImageExportResult {
  const ReplicateImageExportResult({
    required this.directory,
    required this.copiedCount,
    required this.missingCount,
  });

  final Directory directory;
  final int copiedCount;
  final int missingCount;
}

class _ComposePromptModelRule {
  const _ComposePromptModelRule({
    required this.format,
    required this.label,
    required this.maxConcurrent,
  });

  final ShotPromptFormat format;
  final String label;
  final int maxConcurrent;
}

class ReplicateController extends ValueNotifier<ReplicateState> {
  ReplicateController({
    required ReplicateRepository repository,
    required ShootingScriptController shootingScriptController,
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    ShootingScriptWorkflowRepository? workflowRepository,
    ShootingScriptAssetBindingController? assetBindingController,
    SeedancePromptGenerationService promptService =
        const SeedancePromptGenerationService(),
    ImageGenerationService? imageGenerationService,
    VisionStoryboardService? visionService,
    ReplicationFrameAnalysisService? frameAnalysisService,
    ReplicationGenerationReviewService? generationReviewService,
    ReplicationAssetViewSelectionService? assetViewSelectionService,
    DwPoseModelManager? dwPoseModelManager,
    DwPoseService? dwPoseService,
    H3PromptWritingService h3PromptWritingService =
        const H3PromptWritingService(),
    FreeCreationVideoPromptWritingService freeCreationPromptWritingService =
        const FreeCreationVideoPromptWritingService(),
    H3SkillLibrary? h3SkillLibrary,
    VideoSkillLibrary? videoSkillLibrary,
    bool enforceFreeCreationMode = false,
    Uuid uuid = const Uuid(),
  }) : _repository = repository,
       _shootingScriptController = shootingScriptController,
       _directories = directories,
       _settingsController = settingsController,
       _workflowRepository = workflowRepository,
       _assetBindingController = assetBindingController,
       _promptService = promptService,
       _imageGenerationService =
           imageGenerationService ?? ImageGenerationService(),
       _ownsImageGenerationService = imageGenerationService == null,
       _visionService = visionService ?? VisionStoryboardService(),
       _ownsVisionService = visionService == null,
       _h3PromptWritingService = h3PromptWritingService,
       _freeCreationPromptWritingService = freeCreationPromptWritingService,
       _h3SkillLibrary = h3SkillLibrary ?? BundledH3SkillLibrary(),
       _videoSkillLibrary = videoSkillLibrary ?? BundledVideoSkillLibrary(),
       _enforceFreeCreationMode = enforceFreeCreationMode,
       _uuid = uuid,
       super(const ReplicateState()) {
    _frameAnalysisService =
        frameAnalysisService ??
        ReplicationFrameAnalysisService(visionService: _visionService);
    _generationReviewService =
        generationReviewService ??
        ReplicationGenerationReviewService(visionService: _visionService);
    _assetViewSelectionService =
        assetViewSelectionService ??
        ReplicationAssetViewSelectionService(visionService: _visionService);
    _dwPoseModelManager = dwPoseModelManager ?? DwPoseModelManager();
    _dwPoseService = dwPoseService ?? DwPoseService();
    _ownsDwPoseService = dwPoseService == null;
    _shootingScriptController.addListener(_handleShootingScriptChanged);
    _assetBindingController?.addListener(_handleWorkflowChanged);
    _settingsController.addListener(_handleSettingsChanged);
    _restoreFromShootingScript();
  }

  static const promptModel = 'Seedance 2';
  static const _promptRulesVersion = 19;
  static const _freeCreationPromptRulesVersion = 27;
  static const defaultComposePromptConcurrency = 4;
  static const klingComposePromptConcurrency = 2;
  static const freeCreationVisionRequestTimeout = Duration(minutes: 10);
  static const defaultBatchReplicateConcurrency = 1000;
  static const defaultBatchReplicateStagger = Duration(milliseconds: 20);

  final ReplicateRepository _repository;
  final ShootingScriptController _shootingScriptController;
  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final ShootingScriptWorkflowRepository? _workflowRepository;
  final ShootingScriptAssetBindingController? _assetBindingController;
  final SeedancePromptGenerationService _promptService;
  final ImageGenerationService _imageGenerationService;
  final bool _ownsImageGenerationService;
  final VisionStoryboardService _visionService;
  final bool _ownsVisionService;
  late final ReplicationFrameAnalysisService _frameAnalysisService;
  late final ReplicationGenerationReviewService _generationReviewService;
  late final ReplicationAssetViewSelectionService _assetViewSelectionService;
  late final DwPoseModelManager _dwPoseModelManager;
  late final DwPoseService _dwPoseService;
  late final bool _ownsDwPoseService;
  final H3PromptWritingService _h3PromptWritingService;
  final FreeCreationVideoPromptWritingService _freeCreationPromptWritingService;
  final H3SkillLibrary _h3SkillLibrary;
  final VideoSkillLibrary _videoSkillLibrary;
  final bool _enforceFreeCreationMode;
  final Uuid _uuid;
  bool _disposed = false;
  String? _pendingManualShotGroupStartId;
  final _activeReplicationCountsByScriptId = <String, int>{};
  final _activeBatchReplicationScriptIds = <String>{};
  final _replicationMessagesByScriptId = <String, String>{};
  final _activeBuildCountsByScriptId = <String, int>{};
  final _buildMessagesByScriptId = <String, String>{};
  final _buildErrorsByScriptId = <String, String>{};
  final _activeFrameAnalysisCountsByScriptId = <String, int>{};
  var _replicatedImageRecoveryScanCount = 0;

  @visibleForTesting
  int get replicatedImageRecoveryScanCount => _replicatedImageRecoveryScanCount;

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleShootingScriptChanged);
    _assetBindingController?.removeListener(_handleWorkflowChanged);
    _settingsController.removeListener(_handleSettingsChanged);
    if (_ownsImageGenerationService) {
      _imageGenerationService.close();
    }
    if (_ownsVisionService) {
      _visionService.close();
    }
    if (_ownsDwPoseService) unawaited(_dwPoseService.close());
    super.dispose();
  }

  void selectScript(String scriptId) {
    if (!value.scripts.any((script) => script.id == scriptId)) {
      return;
    }
    _shootingScriptController.selectScript(scriptId);
    _restoreFromShootingScript(selectScriptId: scriptId);
  }

  /// 保存当前复刻任务的默认出图参数；一键复刻和一键替换产品共用。
  void updateGenerationDefaults({
    String? model,
    String? aspectRatio,
    bool? inheritSourceAspectRatio,
    bool? multiViewEnhancementEnabled,
    String? imageSize,
    String? quality,
  }) {
    final run = value.run;
    if (run == null) return;
    final requestedModel = (model ?? run.generationModel).trim();
    final selectedModel = requestedModel.isEmpty
        ? _settingsController.value.imageGenerationModel
        : requestedModel;
    final descriptor = ImageGenerationCatalog.descriptorFor(selectedModel);
    if (descriptor == null) return;
    final selectedAspectRatio = _catalogOption(
      aspectRatio ?? run.generationAspectRatio,
      descriptor.aspectRatios,
      preferred: '16:9',
    );
    final selectedImageSize = _catalogOption(
      imageSize ?? run.generationImageSize,
      ImageGenerationCatalog.resolutionsFor(selectedModel, selectedAspectRatio),
      preferred: '2K',
    );
    final selectedQuality = _catalogOption(
      quality ?? run.generationQuality,
      descriptor.qualities,
      preferred: 'high',
    );
    _persistRun(
      run.copyWith(
        generationModel: selectedModel,
        generationAspectRatio: selectedAspectRatio,
        inheritSourceAspectRatio:
            inheritSourceAspectRatio ?? run.inheritSourceAspectRatio,
        multiViewEnhancementEnabled:
            multiViewEnhancementEnabled ?? run.multiViewEnhancementEnabled,
        generationImageSize: selectedImageSize,
        generationQuality: selectedQuality,
        updatedAt: DateTime.now().toUtc(),
      ),
      message: '已保存一键复刻默认生成参数',
    );
  }

  String get resolvedGenerationModel {
    final run = value.run;
    return run == null
        ? _settingsController.value.imageGenerationModel
        : _resolvedGenerationModel(run);
  }

  String get composePromptModelLabel => _composePromptModelRule.label;

  bool get usesOfficialH3PromptWriting =>
      _composePromptModelRule.format == ShotPromptFormat.h3;

  bool get showsH3SkillRoutingPreference =>
      _settingsController
          .value
          .activeVideoGenerationApiConfig
          ?.supportsLocalH3SkillRouting ==
      true;

  H3PromptStyle get selectedH3PromptStyle =>
      H3PromptStyle.resolve(_settingsController.value.h3PromptStyleId);

  Future<void> selectH3PromptStyle(String styleId) async {
    if (!showsH3SkillRoutingPreference) return;
    final style = H3PromptStyle.resolve(styleId);
    if (_settingsController.value.h3PromptStyleId == style.id) return;
    await _settingsController.setH3PromptStyleId(style.id);
    if (!_disposed) _restoreFromShootingScript();
  }

  int get composePromptConcurrency => _composePromptModelRule.maxConcurrent;

  int get structuredPromptContextReadyCount => ScriptShotGroup.group(
    value.confirmedShots,
  ).where((group) => _hasUsablePromptContext(group.shots.first.id)).length;

  int get structuredPromptContextMissingCount =>
      ScriptShotGroup.group(value.confirmedShots).length -
      structuredPromptContextReadyCount;

  void refresh() => _restoreFromShootingScript();

  ReplicateShotGuide? shotGuideFor(String shotId) {
    for (final guide in value.shotGuides) {
      if (guide.shotId == shotId) return guide;
    }
    return null;
  }

  bool isShotGuideCurrent(String shotId) {
    final guide = shotGuideFor(shotId);
    final shot = _shotById(shotId);
    if (guide == null || shot == null) return false;
    return guide.sourceFrameFingerprint == _sourceFrameFingerprint(shot);
  }

  Future<void> analyzeReplicationFrame(String shotId) async {
    final shot = _shotById(shotId);
    final scriptId = value.selectedScriptId;
    if (shot == null || scriptId.isEmpty) return;
    final imageFile = File(shot.framePath.trim());
    if (shot.framePath.trim().isEmpty || !imageFile.existsSync()) {
      value = value.copyWith(
        errorMessage: '镜头 ${shot.shotNumber} 的原视频帧不存在，无法分析',
      );
      return;
    }
    final stored = _repository.getShotGuide(shot.id);
    final now = DateTime.now().toUtc();
    final fingerprint = _sourceFrameFingerprint(shot);
    final previous = stored?.sourceFrameFingerprint == fingerprint
        ? stored
        : null;
    final running = ReplicateShotGuide(
      shotId: shot.id,
      sourceFrameFingerprint: fingerprint,
      elements: previous?.elements ?? const [],
      subjects: previous?.subjects ?? const [],
      actionDescription: previous?.actionDescription ?? '',
      poseConstraints: previous?.poseConstraints ?? '',
      personCount: previous?.personCount ?? 0,
      skeletonPath: previous?.skeletonPath ?? '',
      analysisModel: _settingsController.value.visionModel.trim(),
      analysisStatus: ProcessingStatus.running,
      poseStatus: previous?.poseStatus ?? ProcessingStatus.pending,
      rawResponse: previous?.rawResponse ?? '',
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
    _beginFrameAnalysis(scriptId);
    _repository.upsertShotGuide(running);
    _reloadShotGuides(
      scriptId,
      message: '正在分析镜头 ${shot.shotNumber} 的配饰、关键道具与精确动作…',
    );
    try {
      final result = await _frameAnalysisService.analyze(
        settings: _settingsController.value,
        imageFile: imageFile,
        shotNumber: shot.shotNumber,
        previousElements: previous?.elements ?? const [],
        previousSubjects: previous?.subjects ?? const [],
      );
      _repository.upsertShotGuide(
        running.copyWith(
          elements: result.elements,
          subjects: result.subjects,
          actionDescription: result.actionDescription,
          poseConstraints: result.poseConstraints,
          personCount: math.max(running.personCount, result.personCount),
          analysisStatus: ProcessingStatus.completed,
          rawResponse: result.rawResponse,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      _reloadShotGuides(
        scriptId,
        message: '镜头 ${shot.shotNumber} 原帧分析完成，请选择主体替换/移除，并勾选唯一允许保留的配饰和道具',
      );
    } catch (error) {
      _repository.upsertShotGuide(
        running.copyWith(
          analysisStatus: ProcessingStatus.failed,
          errorMessage: '$error',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      _reloadShotGuides(
        scriptId,
        errorMessage: '镜头 ${shot.shotNumber} 原帧分析失败：$error',
      );
    } finally {
      _finishFrameAnalysis(scriptId);
      _reloadShotGuides(scriptId);
    }
  }

  Future<void> analyzeAllReplicationFrames() async {
    final shotIds = [for (final shot in value.confirmedShots) shot.id];
    for (var offset = 0; offset < shotIds.length; offset += 4) {
      final end = (offset + 4).clamp(0, shotIds.length).toInt();
      await Future.wait([
        for (final shotId in shotIds.sublist(offset, end))
          analyzeReplicationFrame(shotId),
      ]);
    }
  }

  Future<void> extractDwPoseForShot(String shotId) async {
    final shot = _shotById(shotId);
    final scriptId = value.selectedScriptId;
    if (shot == null || scriptId.isEmpty) return;
    final source = File(shot.framePath.trim());
    if (!source.existsSync()) {
      value = value.copyWith(errorMessage: '镜头 ${shot.shotNumber} 的原视频帧不存在');
      return;
    }
    if (kIsWeb || !Platform.isWindows) {
      value = value.copyWith(errorMessage: '当前版本仅支持在 Windows 桌面端提取 DWPose 骨架');
      return;
    }
    final stored = _repository.getShotGuide(shotId);
    final fingerprint = _sourceFrameFingerprint(shot);
    final previous = stored?.sourceFrameFingerprint == fingerprint
        ? stored
        : null;
    final now = DateTime.now().toUtc();
    final running =
        previous?.copyWith(
          sourceFrameFingerprint: fingerprint,
          poseStatus: ProcessingStatus.running,
          errorMessage: '',
          updatedAt: now,
        ) ??
        ReplicateShotGuide(
          shotId: shotId,
          sourceFrameFingerprint: fingerprint,
          poseStatus: ProcessingStatus.running,
          createdAt: now,
          updatedAt: now,
        );
    _repository.upsertShotGuide(running);
    _reloadShotGuides(
      scriptId,
      message: '正在提取镜头 ${shot.shotNumber} 的 DWPose 高精度姿势骨架…',
    );
    try {
      final models = await _dwPoseModelManager.loadBundledModels();
      final outputDirectory = Directory(
        p.join(_directories.analyses.path, 'dwpose', _safeFileName(scriptId)),
      );
      final result = await _dwPoseService.extract(
        imageFile: source,
        outputFile: DwPoseService.outputFileFor(
          directory: outputDirectory,
          shotId: shotId,
        ),
        models: models,
      );
      _repository.upsertShotGuide(
        running.copyWith(
          skeletonPath: result.skeletonFile.path,
          personCount: math.max(running.personCount, result.personCount),
          poseStatus: ProcessingStatus.completed,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      _reloadShotGuides(
        scriptId,
        message:
            '镜头 ${shot.shotNumber} 已提取 ${result.personCount} 个人物的 DWPose 骨架',
      );
    } catch (error) {
      _repository.upsertShotGuide(
        running.copyWith(
          poseStatus: ProcessingStatus.failed,
          errorMessage: '$error',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      _reloadShotGuides(
        scriptId,
        errorMessage: '镜头 ${shot.shotNumber} DWPose 提取失败：$error',
      );
    }
  }

  Future<void> extractDwPoseForAllShots() async {
    for (final shot in value.confirmedShots) {
      await extractDwPoseForShot(shot.id);
    }
  }

  Future<void> removeDwPoseForShot(String shotId) async {
    final guide = _repository.getShotGuide(shotId);
    final scriptId = value.selectedScriptId;
    if (guide == null || scriptId.isEmpty) return;
    final skeletonPath = guide.skeletonPath.trim();
    var cleanupWarning = '';
    if (skeletonPath.isNotEmpty) {
      final generatedRoot = p.normalize(
        p.absolute(p.join(_directories.analyses.path, 'dwpose')),
      );
      final candidate = p.normalize(p.absolute(skeletonPath));
      if (p.isWithin(generatedRoot, candidate)) {
        try {
          final file = File(candidate);
          if (await file.exists()) await file.delete();
        } on FileSystemException catch (error) {
          cleanupWarning = '；本地骨架缓存删除失败：${error.message}';
        }
      }
    }
    _repository.upsertShotGuide(
      guide.copyWith(
        skeletonPath: '',
        poseStatus: ProcessingStatus.pending,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    final shotNumber = _shotById(shotId)?.shotNumber;
    _reloadShotGuides(
      scriptId,
      message:
          '${shotNumber == null ? '当前镜头' : '镜头 $shotNumber'}的动作骨架已移除$cleanupWarning',
    );
  }

  void setPreservedElementSelected(
    String shotId,
    String elementId,
    bool selected,
  ) {
    final guide = _repository.getShotGuide(shotId);
    if (guide == null) return;
    final elements = [
      for (final element in guide.elements)
        element.id == elementId
            ? element.copyWith(selected: selected)
            : element,
    ];
    _repository.upsertShotGuide(
      guide.copyWith(elements: elements, updatedAt: DateTime.now().toUtc()),
    );
    _reloadShotGuides(value.selectedScriptId);
  }

  void setDetectedSubjectDecision(
    String shotId,
    String subjectId,
    ReplicateSubjectDecision decision,
  ) {
    final guide = _repository.getShotGuide(shotId);
    if (guide == null) return;
    final subjects = [
      for (final subject in guide.subjects)
        if (subject.id == subjectId)
          subject.copyWith(decision: decision)
        else
          subject,
    ];
    _repository.upsertShotGuide(
      guide.copyWith(subjects: subjects, updatedAt: DateTime.now().toUtc()),
    );
    _reloadShotGuides(value.selectedScriptId);
  }

  void removeDetectedSubject(String shotId, String subjectId) {
    final guide = _repository.getShotGuide(shotId);
    if (guide == null) return;
    final subjects = guide.subjects
        .where((subject) => subject.id != subjectId)
        .toList(growable: false);
    if (subjects.length == guide.subjects.length) return;
    _repository.upsertShotGuide(
      guide.copyWith(subjects: subjects, updatedAt: DateTime.now().toUtc()),
    );
    _reloadShotGuides(value.selectedScriptId);
  }

  void addManualPreservedElement(String shotId, String label) {
    final normalized = label.trim();
    if (normalized.isEmpty) return;
    final previous = _repository.getShotGuide(shotId);
    final shot = _shotById(shotId);
    if (shot == null) return;
    final now = DateTime.now().toUtc();
    final guide =
        previous ??
        ReplicateShotGuide(
          shotId: shotId,
          sourceFrameFingerprint: _sourceFrameFingerprint(shot),
          createdAt: now,
          updatedAt: now,
        );
    final duplicate = guide.elements.any(
      (element) =>
          element.label.trim().toLowerCase() == normalized.toLowerCase(),
    );
    if (duplicate) return;
    final element = ReplicatePreservedElement(
      id: 'manual:${_uuid.v4()}',
      category: '手动',
      label: normalized,
      selected: true,
      isManual: true,
    );
    _repository.upsertShotGuide(
      guide.copyWith(elements: [...guide.elements, element], updatedAt: now),
    );
    _reloadShotGuides(value.selectedScriptId);
  }

  void updateVideoGenerationStatus(
    ProcessingStatus status, {
    String message = '',
  }) {
    final run = value.run;
    if (run == null) return;
    final updated = run.copyWith(
      generateVideosStatus: status,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(updated);
    value = value.copyWith(
      run: updated,
      message: message,
      errorMessage: status == ProcessingStatus.failed ? message : '',
    );
  }

  void toggleShotConfirmed(String shotId, bool confirmed) {
    final run = value.run;
    if (run == null || !value.shots.any((shot) => shot.id == shotId)) {
      return;
    }
    final ids = run.confirmedShotIds.toSet();
    confirmed ? ids.add(shotId) : ids.remove(shotId);
    _saveConfirmation(run, ids);
  }

  void confirmAllShots() {
    final run = value.run;
    if (run == null) {
      return;
    }
    _saveConfirmation(run, {for (final shot in value.shots) shot.id});
  }

  void clearConfirmedShots() {
    final run = value.run;
    if (run != null) {
      _saveConfirmation(run, const <String>{});
    }
  }

  bool moveToStep(ReplicateStep step) {
    final run = value.run;
    if (run == null) {
      return false;
    }
    final targetStep = step == ReplicateStep.composePrompts
        ? ReplicateStep.confirmShots
        : step;
    if (targetStep.index >= ReplicateStep.prepareAssets.index &&
        value.shots.isEmpty) {
      value = value.copyWith(errorMessage: '当前脚本暂无可用镜头', message: '');
      return false;
    }
    if (targetStep.index >= ReplicateStep.generateVideos.index &&
        value.prompts.isEmpty) {
      value = value.copyWith(errorMessage: '请先在确认镜头页构建提示词', message: '');
      return false;
    }
    final updated = run.copyWith(
      currentStep: targetStep,
      prepareAssetsStatus:
          targetStep.index >= ReplicateStep.generateVideos.index &&
              _hasWorkflowPromptAssets()
          ? ProcessingStatus.completed
          : run.prepareAssetsStatus,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _persistRun(updated, message: '已进入${_stepLabel(targetStep)}');
    return true;
  }

  void updatePromptRules({
    required String globalStyle,
    required String constraints,
  }) {
    final run = value.run;
    if (run == null) {
      return;
    }
    final shouldInvalidatePrompts =
        value.prompts.isNotEmpty && !run.freeCreationEnabled;
    final updated = run.copyWith(
      globalStyle: globalStyle.trim().isEmpty
          ? _settingsController.value.replicateDefaultGlobalStyle
          : globalStyle.trim(),
      constraints: constraints.trim().isEmpty
          ? _settingsController.value.replicateDefaultConstraints
          : constraints.trim(),
      composePromptsStatus: shouldInvalidatePrompts
          ? ProcessingStatus.pending
          : run.composePromptsStatus,
      status: shouldInvalidatePrompts ? ProcessingStatus.pending : run.status,
      updatedAt: DateTime.now().toUtc(),
    );
    _persistRun(updated, message: '提示词规则已保存');
  }

  void updateReplicationInstructions(String instructions) {
    final run = value.run;
    if (run == null) return;
    final normalized = instructions.trim();
    if (normalized == run.replicationInstructions) return;
    _persistRun(
      run.copyWith(
        replicationInstructions: normalized,
        updatedAt: DateTime.now().toUtc(),
      ),
      message: normalized.isEmpty ? '已清除复刻补充说明' : '已保存复刻补充说明',
    );
  }

  void setFreeCreationEnabled(bool enabled) {
    final run = value.run;
    if (_enforceFreeCreationMode && !enabled) return;
    if (run == null || run.freeCreationEnabled == enabled) return;
    _persistRun(
      run.copyWith(
        freeCreationEnabled: enabled,
        composePromptsStatus: value.prompts.isEmpty
            ? run.composePromptsStatus
            : ProcessingStatus.pending,
        status: value.prompts.isEmpty ? run.status : ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      ),
      message: enabled ? '已开启自由创作' : '已关闭自由创作',
    );
  }

  void updateFreeCreationStoryOverride(String story) {
    final run = value.run;
    if (run == null) return;
    final normalized = story.trim();
    if (run.freeCreationStoryOverride == normalized) return;
    _persistRun(
      run.copyWith(
        freeCreationStoryOverride: normalized,
        updatedAt: DateTime.now().toUtc(),
      ),
      message: normalized.isEmpty ? '已恢复自动分镜故事' : '分镜故事已保存',
    );
  }

  String get automaticFreeCreationStory =>
      _repository.storyboardStory(value.selectedScript?.sourceStoryboardId);

  String get effectiveFreeCreationStory {
    final override = value.run?.freeCreationStoryOverride.trim() ?? '';
    return override.isNotEmpty ? override : automaticFreeCreationStory;
  }

  List<String> get missingFreeCreationDescriptionShotIds => [
    for (final group in ScriptShotGroup.group(value.shots))
      if (group.shots.first.freeCreationDescription.trim().isEmpty)
        group.shots.first.id,
  ];

  bool updateFreeCreationDescription(String groupHeadShotId, String text) {
    final shot = _shotById(groupHeadShotId);
    if (shot == null) return false;
    return updateShot(shot.copyWith(freeCreationDescription: text));
  }

  bool validateFreeCreationDescriptions() {
    return true;
  }

  void clearPromptsBeforeBuild() {
    final run = value.run;
    if (run == null) return;
    final updatedRun = run.copyWith(
      status: ProcessingStatus.pending,
      composePromptsStatus: ProcessingStatus.pending,
      completedCount: 0,
      totalCount: ScriptShotGroup.group(value.shots).length,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.deletePrompts(run.id);
    _repository.upsertRun(updatedRun);
    value = value.copyWith(
      run: updatedRun,
      prompts: const [],
      message: '已清理上一次提示词，正在重新构建…',
      errorMessage: '',
    );
    _shootingScriptController.updateGeneratedFieldsForScript(
      scriptId: _ownerScriptId(run),
      promptsByShotId: {for (final shot in value.shots) shot.id: ''},
    );
  }

  Future<ReplicateAsset?> importAsset({
    required String sourcePath,
    required ReplicateAssetType type,
    String name = '',
    String description = '',
  }) async {
    final run = value.run;
    final source = File(sourcePath);
    if (run == null || !source.existsSync()) {
      value = value.copyWith(errorMessage: '所选素材文件不存在', message: '');
      return null;
    }
    value = value.copyWith(isBusy: true, errorMessage: '', message: '正在导入素材…');
    try {
      final directory = await _assetDirectory(run.id);
      final target = _uniqueFile(directory, p.basename(source.path));
      await source.copy(target.path);
      final now = DateTime.now().toUtc();
      final referenceNumber = _nextReferenceNumber(type, run, value.assets);
      final referencedRun = _runWithReferenceCount(run, type, referenceNumber);
      final asset = ReplicateAsset(
        id: _uuid.v4(),
        runId: run.id,
        type: type,
        name: name.trim().isEmpty
            ? p.basenameWithoutExtension(source.path)
            : name.trim(),
        description: description.trim(),
        path: target.path,
        referenceNumber: referenceNumber,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      );
      _repository.upsertAsset(asset);
      _refreshRunData(
        run: _runWithAssetStatus(referencedRun, [...value.assets, asset]),
        message: '已导入 ${SeedancePromptGenerationService.referenceLabel(asset)}',
      );
      return asset;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '导入素材失败：$error',
      );
      return null;
    }
  }

  Future<ReplicateAsset?> importLibraryAsset(
    ShootingAssetLibraryItem item,
  ) async {
    return importAsset(
      sourcePath: item.path,
      type: item.type,
      name: item.name,
      description: item.description,
    );
  }

  Future<ReplicateAsset?> replaceAssetFile(
    String assetId,
    String sourcePath,
  ) async {
    final run = value.run;
    final source = File(sourcePath);
    final asset = _assetById(assetId);
    if (run == null || asset == null || !source.existsSync()) {
      value = value.copyWith(errorMessage: '替换素材文件不存在', message: '');
      return null;
    }
    value = value.copyWith(isBusy: true, errorMessage: '', message: '正在替换素材…');
    try {
      final directory = await _assetDirectory(run.id);
      final target = _uniqueFile(directory, p.basename(source.path));
      await source.copy(target.path);
      final updated = asset.copyWith(
        path: target.path,
        status: ProcessingStatus.completed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertAsset(updated);
      await _deleteManagedAssetFile(asset.path, excludingPath: updated.path);
      _refreshRunData(
        run: _runWithAssetStatus(run, [
          for (final item in value.assets)
            if (item.id == updated.id) updated else item,
        ]),
        message: '已替换 ${asset.name}',
      );
      return updated;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '替换素材失败：$error',
      );
      return null;
    }
  }

  void updateAsset(ReplicateAsset updated) {
    final existing = _assetById(updated.id);
    if (existing == null || updated.runId != value.run?.id) {
      return;
    }
    final saved = updated.copyWith(
      name: updated.name.trim().isEmpty ? existing.name : updated.name.trim(),
      description: updated.description.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertAsset(saved);
    _refreshRunData(
      run: _runWithAssetStatus(value.run!, [
        for (final item in value.assets)
          if (item.id == saved.id) saved else item,
      ]),
      message: '素材信息已保存',
    );
  }

  Future<void> deleteAsset(String assetId) async {
    final asset = _assetById(assetId);
    final run = value.run;
    if (asset == null || run == null) {
      return;
    }
    _repository.deleteAsset(asset.id);
    await _deleteManagedAssetFile(asset.path);
    final remaining = [
      for (final item in value.assets)
        if (item.id != asset.id) item,
    ];
    _refreshRunData(
      run: _runWithAssetStatus(run, remaining),
      message: '已删除 ${asset.name}；其他素材编号保持不变',
    );
  }

  Future<ReplicateAsset?> generateImageAsset({
    required ReplicateAssetType type,
    required String name,
    required String description,
  }) async {
    final run = value.run;
    final prompt = description.trim();
    if (run == null || prompt.isEmpty) {
      value = value.copyWith(errorMessage: '请先填写素材生成描述', message: '');
      return null;
    }
    final now = DateTime.now().toUtc();
    final referenceNumber = _nextReferenceNumber(type, run, value.assets);
    final referencedRun = _runWithReferenceCount(run, type, referenceNumber);
    var asset = ReplicateAsset(
      id: _uuid.v4(),
      runId: run.id,
      type: type,
      name: name.trim().isEmpty ? '${_assetTypeLabel(type)}素材' : name.trim(),
      description: prompt,
      path: '',
      referenceNumber: referenceNumber,
      status: ProcessingStatus.running,
      createdAt: now,
      updatedAt: now,
    );
    _repository.upsertAsset(asset);
    _refreshRunData(
      run: referencedRun,
      message: '正在生成 ${asset.name}…',
      isBusy: true,
    );
    try {
      final result = await _generateReferenceImage(prompt, run);
      if (_disposed) {
        return null;
      }
      asset = asset.copyWith(
        path: result.localPath,
        status: ProcessingStatus.completed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertAsset(asset);
      _refreshRunData(
        run: _runWithAssetStatus(referencedRun, [
          ...value.assets.where((item) => item.id != asset.id),
          asset,
        ]),
        message: '${asset.name} 生成完成',
      );
      return asset;
    } catch (error) {
      if (_disposed) {
        return null;
      }
      asset = asset.copyWith(
        status: ProcessingStatus.failed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertAsset(asset);
      _refreshRunData(run: referencedRun, errorMessage: '生成素材失败：$error');
      return null;
    }
  }

  Future<ReplicateAsset?> regenerateImageAsset(String assetId) async {
    final run = value.run;
    final original = _assetById(assetId);
    if (run == null ||
        original == null ||
        _mediaKindForType(original.type) != ReplicateMediaKind.image) {
      return null;
    }
    if (original.description.trim().isEmpty) {
      value = value.copyWith(errorMessage: '请先填写素材生成描述', message: '');
      return null;
    }
    var asset = original.copyWith(
      status: ProcessingStatus.running,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertAsset(asset);
    _refreshRunData(
      run: _runWithAssetStatus(run, [
        for (final item in value.assets)
          if (item.id == asset.id) asset else item,
      ]),
      message: '正在重新生成 ${asset.name}…',
      isBusy: true,
    );
    try {
      final result = await _generateReferenceImage(
        original.description.trim(),
        run,
      );
      if (_disposed) return null;
      asset = asset.copyWith(
        path: result.localPath,
        status: ProcessingStatus.completed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertAsset(asset);
      await _deleteManagedAssetFile(
        original.path,
        excludingPath: result.localPath,
      );
      _refreshRunData(
        run: _runWithAssetStatus(run, [
          for (final item in value.assets)
            if (item.id == asset.id) asset else item,
        ]),
        message: '${asset.name} 已重新生成，引用编号保持不变',
      );
      return asset;
    } catch (error) {
      if (_disposed) return null;
      final oldFileExists =
          original.path.isNotEmpty && File(original.path).existsSync();
      asset = original.copyWith(
        status: oldFileExists
            ? ProcessingStatus.completed
            : ProcessingStatus.failed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertAsset(asset);
      _refreshRunData(
        run: _runWithAssetStatus(run, [
          for (final item in value.assets)
            if (item.id == asset.id) asset else item,
        ]),
        errorMessage: '重新生成素材失败：$error',
      );
      return null;
    }
  }

  bool updateShot(ScriptShot shot) {
    if (shot.scriptId != value.selectedScriptId) {
      return false;
    }
    final saved = _shootingScriptController.updateShot(shot);
    if (!saved) return false;
    final run = value.run;
    if (run != null &&
        value.prompts.isNotEmpty &&
        (run.status != ProcessingStatus.pending ||
            run.composePromptsStatus != ProcessingStatus.pending)) {
      final pending = run.copyWith(
        status: ProcessingStatus.pending,
        composePromptsStatus: ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(pending);
      value = value.copyWith(run: pending);
    }
    return true;
  }

  void deleteShot(String shotId) {
    _shootingScriptController.deleteShot(shotId);
  }

  bool reorderShotGroups(int oldIndex, int newIndex) {
    _upgradeLegacyPromptShotLinks();
    if (!_shootingScriptController.reorderShotGroups(oldIndex, newIndex)) {
      return false;
    }
    _syncGeneratedItemsToShotOrder();
    value = value.copyWith(message: '已调整镜头组顺序', errorMessage: '');
    return true;
  }

  bool removeShotGroup(String shotId) {
    _upgradeLegacyPromptShotLinks();
    final groups = ScriptShotGroup.group(value.shots);
    final groupIndex = groups.indexWhere(
      (group) => group.shots.any((shot) => shot.id == shotId),
    );
    if (groupIndex < 0) return false;
    final group = groups[groupIndex];
    final removedIds = {for (final shot in group.shots) shot.id};
    final run = value.run;
    if (run != null) {
      _repository.deletePromptsForShotIds(run.id, removedIds);
    }
    if (_pendingManualShotGroupStartId != null &&
        removedIds.contains(_pendingManualShotGroupStartId)) {
      _pendingManualShotGroupStartId = null;
    }
    if (!_shootingScriptController.deleteShotGroup(group.shots.first.id)) {
      return false;
    }
    _syncGeneratedItemsToShotOrder();
    value = value.copyWith(
      message: group.shots.length == 1
          ? '已移除镜头条目'
          : '已移除包含 ${group.shots.length} 帧的镜头组',
      errorMessage: '',
    );
    return true;
  }

  void _syncGeneratedItemsToShotOrder() {
    final run = value.run;
    if (run == null) return;
    final shotNumberById = {
      for (final shot in value.shots) shot.id: shot.shotNumber,
    };
    final now = DateTime.now().toUtc();
    final prompts = [
      for (final prompt in value.prompts)
        if (shotNumberById[prompt.scriptShotId] case final shotNumber?)
          prompt.copyWith(shotNumber: shotNumber, updatedAt: now),
    ];
    _repository.replacePrompts(run.id, prompts);
    for (final image in value.replicatedImages) {
      final shotNumber = shotNumberById[image.scriptShotId];
      if (shotNumber == null) continue;
      _repository.upsertReplicatedShotImage(
        image.copyWith(shotNumber: shotNumber, updatedAt: now),
      );
    }
    _restoreFromShootingScript();
  }

  void _upgradeLegacyPromptShotLinks() {
    final run = value.run;
    if (run == null ||
        !value.prompts.any((prompt) => prompt.scriptShotId == null)) {
      return;
    }
    final shotIdByNumber = {
      for (final shot in value.shots) shot.shotNumber: shot.id,
    };
    final prompts = value.prompts
        .map((prompt) {
          if (prompt.scriptShotId != null) return prompt;
          final shotId = shotIdByNumber[prompt.shotNumber];
          return shotId == null
              ? prompt
              : prompt.copyWith(scriptShotId: shotId);
        })
        .toList(growable: false);
    _repository.replacePrompts(run.id, prompts);
    value = value.copyWith(prompts: prompts);
  }

  String? get pendingManualShotGroupStartId => _pendingManualShotGroupStartId;

  bool canSelectManualShotGroupStart(String shotId) {
    final shot = _shotById(shotId);
    return shot != null &&
        value.shots.any((item) => item.shotNumber > shot.shotNumber);
  }

  bool canSelectManualShotGroupEnd(String shotId) {
    final startId = _pendingManualShotGroupStartId;
    if (startId == null || startId == shotId) return false;
    final start = _shotById(startId);
    final end = _shotById(shotId);
    return start != null && end != null && end.shotNumber > start.shotNumber;
  }

  bool shotIsInManualGroup(String shotId) {
    final index = value.shots.indexWhere((shot) => shot.id == shotId);
    if (index < 0) return false;
    final previousConnected =
        index > 0 &&
        value.shots[index - 1].continuesToNext &&
        value.shots[index].continuesFromPrevious;
    final nextConnected =
        index + 1 < value.shots.length &&
        value.shots[index].continuesToNext &&
        value.shots[index + 1].continuesFromPrevious;
    return previousConnected || nextConnected;
  }

  void selectManualShotGroupStart(String shotId) {
    if (!canSelectManualShotGroupStart(shotId)) return;
    _pendingManualShotGroupStartId = shotId;
    final shot = _shotById(shotId);
    value = value.copyWith(
      message: shot == null
          ? '请选择结束帧'
          : '已选择镜头 ${shot.shotNumber} 为首帧，请右键后续镜头设为结束帧',
      errorMessage: '',
    );
  }

  void setManualShotGroupEnd(String endShotId) {
    final startId = _pendingManualShotGroupStartId;
    if (startId == null || !canSelectManualShotGroupEnd(endShotId)) {
      value = value.copyWith(errorMessage: '请选择首帧之后的镜头作为结束帧', message: '');
      return;
    }
    _pendingManualShotGroupStartId = null;
    _shootingScriptController.setContinuousShotRange(
      startShotId: startId,
      endShotId: endShotId,
    );
  }

  void clearManualShotGroup(String shotId) {
    if (_pendingManualShotGroupStartId == shotId) {
      _pendingManualShotGroupStartId = null;
    }
    _shootingScriptController.clearContinuousShotGroup(shotId);
  }

  List<VideoActionSequence> shotSequencesFor(List<ScriptShot> shots) {
    return const VideoActionSequenceResolver().resolve(shots);
  }

  List<ScriptShot> get groupHeadRows {
    return shotSequencesFor(
      value.shots,
    ).map((sequence) => sequence.head).toList(growable: false);
  }

  ScriptShot? tailShotForDisplay(ScriptShot shot) {
    final sequence = const VideoActionSequenceResolver().sequenceFor(
      value.shots,
      shot.id,
    );
    return sequence.head.id == shot.id && sequence.hasDistinctTail
        ? sequence.tail
        : null;
  }

  Future<bool> replicateShot(String shotId) async {
    final context = _replicationContext();
    if (context == null) return false;
    final shot = _shotById(shotId);
    if (shot == null) return false;
    final shots = _replicationEndpointsForShot(shot);
    _beginReplication(context.scriptId);
    value = value.copyWith(
      isBusy: true,
      message: '正在提交镜头 ${shot.shotNumber} 的复刻任务…',
      errorMessage: '',
    );
    _replicationMessagesByScriptId[context.scriptId] = value.message;
    var succeededCount = 0;
    try {
      for (final target in shots) {
        final succeeded = await _generateReplicatedShot(target, context);
        if (succeeded) succeededCount++;
      }
    } finally {
      _finishReplication(context.scriptId);
    }
    final succeeded = succeededCount == shots.length;
    if (!_disposed) {
      final errors = [
        for (final target in shots)
          _replicatedImageError(context.run.id, target.id).trim(),
      ].where((item) => item.isNotEmpty).toSet().join('；');
      final message = succeeded ? '镜头 ${shot.shotNumber} 复刻完成' : '';
      final remainingCount = _activeReplicationCount(context.scriptId);
      final visibleMessage = remainingCount > 0
          ? '仍有 $remainingCount 个复刻任务生成中…'
          : message;
      _replicationMessagesByScriptId[context.scriptId] = visibleMessage;
      if (value.selectedScriptId == context.scriptId) {
        value = value.copyWith(
          isBusy: remainingCount > 0,
          message: visibleMessage,
          errorMessage: succeeded ? '' : errors,
        );
      }
    }
    return succeeded;
  }

  Future<void> replicateAllShots({
    Duration stagger = defaultBatchReplicateStagger,
    int maxConcurrent = defaultBatchReplicateConcurrency,
  }) async {
    final context = _replicationContext();
    if (context == null ||
        _activeBatchReplicationScriptIds.contains(context.scriptId)) {
      return;
    }
    final shots = _replicationTargetsForAll();
    if (shots.isEmpty) {
      value = value.copyWith(errorMessage: '当前脚本暂无可复刻的镜头', message: '');
      return;
    }
    _activeBatchReplicationScriptIds.add(context.scriptId);
    _beginReplication(context.scriptId);
    value = value.copyWith(
      isBusy: true,
      message: '准备高并发提交 ${shots.length} 个复刻任务…',
      errorMessage: '',
    );
    _replicationMessagesByScriptId[context.scriptId] = value.message;
    final active = <Future<bool>>[];
    var completed = 0;
    var succeeded = 0;
    Future<bool> tracked(ScriptShot shot) async {
      final result = await _generateReplicatedShot(shot, context);
      completed++;
      if (result) succeeded++;
      _setReplicationMessage(
        context.scriptId,
        '复刻进度 $completed/${shots.length}，成功 $succeeded 个',
      );
      return result;
    }

    try {
      final concurrency = maxConcurrent
          .clamp(1, defaultBatchReplicateConcurrency)
          .toInt();
      for (var index = 0; index < shots.length; index++) {
        if (index > 0 && stagger > Duration.zero) {
          await Future<void>.delayed(stagger);
        }
        active.add(tracked(shots[index]));
        if (active.length >= concurrency) {
          await active.removeAt(0);
        }
      }
      await Future.wait(active);
    } finally {
      _activeBatchReplicationScriptIds.remove(context.scriptId);
      _finishReplication(context.scriptId);
      if (!_disposed) {
        final failed = shots.length - succeeded;
        final completedMessage = failed == 0 ? '已完成 ${shots.length} 个镜头复刻' : '';
        final error = failed == 0 ? '' : '$failed 个镜头复刻失败，可单独重试';
        final remainingCount = _activeReplicationCount(context.scriptId);
        final visibleMessage = remainingCount > 0
            ? '仍有 $remainingCount 个复刻任务生成中…'
            : completedMessage;
        _replicationMessagesByScriptId[context.scriptId] = visibleMessage;
        if (value.selectedScriptId == context.scriptId) {
          value = value.copyWith(
            isBusy: remainingCount > 0,
            message: visibleMessage,
            errorMessage: error,
          );
        }
      }
    }
  }

  List<ScriptShot> _replicationTargetsForAll() {
    final shots = [...value.confirmedShots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    return shots;
  }

  List<ScriptShot> _replicationEndpointsForShot(ScriptShot shot) => [shot];

  Future<bool> _generateReplicatedShot(
    ScriptShot shot,
    _ReplicationContext context,
  ) async {
    final run = context.run;
    final original = File(shot.framePath);
    const String? fallbackReferenceShotId = null;
    final references = _replacementReferences(
      shot.id,
      scriptId: context.scriptId,
      stepAssets: context.assets,
      fallbackShotId: fallbackReferenceShotId,
    );
    final guide = _currentShotGuide(shot);
    final skeletonPath = guide?.poseStatus == ProcessingStatus.completed
        ? guide!.skeletonPath.trim()
        : '';
    final skeleton = skeletonPath.isNotEmpty && File(skeletonPath).existsSync()
        ? File(skeletonPath)
        : null;
    final now = DateTime.now().toUtc();
    final existing = _replicatedImageForShot(shot.id);
    final model = _resolvedGenerationModel(run);
    if (existing != null &&
        existing.status == ProcessingStatus.running &&
        !existing.generationRecovery.isEmpty) {
      final generatedPath = existing.generatedFramePath.trim();
      if (generatedPath.isNotEmpty && File(generatedPath).existsSync()) {
        _saveReplicatedImage(
          existing.copyWith(
            generationRecovery: ReplicatedShotGenerationRecovery.empty,
            status: ProcessingStatus.completed,
            errorMessage: '',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        return true;
      }
      try {
        return await _resumeInterruptedReplicatedShot(
          shot: shot,
          context: context,
          original: original,
          record: existing,
        );
      } catch (error) {
        _saveReplicatedImage(
          existing.copyWith(
            status: ProcessingStatus.failed,
            errorMessage: '恢复中断的复刻任务失败，未发起新的首轮图片请求：$error',
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        return false;
      }
    }
    var record = ReplicatedShotImage(
      id: existing?.id ?? _replicatedImageId(run.id, shot.id),
      runId: run.id,
      scriptShotId: shot.id,
      shotNumber: shot.shotNumber,
      originalFramePath: shot.framePath,
      generatedFramePath: existing?.generatedFramePath ?? '',
      assetIds: [for (final reference in references) reference.id],
      prompt: _generationPrompt(
        shot,
        references,
        model,
        guide: guide,
        hasPoseSkeleton: skeleton != null,
      ),
      model: model,
      rawResponse: '',
      status: ProcessingStatus.running,
      errorMessage: '',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    if (!original.existsSync()) {
      record = record.copyWith(
        status: ProcessingStatus.failed,
        errorMessage: '原视频帧不存在',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return false;
    }
    if (references.isEmpty) {
      final hasExplicitSubjectDecision =
          guide != null &&
          guide.subjects.isNotEmpty &&
          guide.undecidedSubjects.isEmpty;
      if (hasExplicitSubjectDecision) {
        // 原帧本身仍会作为参考图；全部主体显式移除时无需额外资产。
      } else {
        record = record.copyWith(
          status: ProcessingStatus.failed,
          errorMessage: '当前镜头没有已绑定且可用的图片资产',
          updatedAt: DateTime.now().toUtc(),
        );
        _saveReplicatedImage(record);
        return false;
      }
    }
    final readinessError = _replicationInputReadinessError(
      shot: shot,
      guide: guide,
      references: references,
    );
    if (readinessError != null) {
      record = record.copyWith(
        status: ProcessingStatus.failed,
        errorMessage: readinessError,
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return false;
    }
    _saveReplicatedImage(record);
    try {
      final descriptor = ImageGenerationCatalog.descriptorFor(model);
      if (descriptor == null) {
        throw FormatException('不支持的图片生成模型：$model');
      }
      final decisionReferences = _referencesForSubjectDecisions(
        references,
        guide,
      );
      var preparedReferences = await _prepareSelectedAssetViews(
        shot: shot,
        run: run,
        original: original,
        references: decisionReferences,
        maximumReferenceCount:
            descriptor.maxReferenceImages - 1 - (skeleton == null ? 0 : 1),
      );
      if (NanoBananaProModelCapability.supports(model)) {
        preparedReferences = _referencesInNanoBananaManifestOrder(
          shot: shot,
          original: original,
          references: preparedReferences,
        );
      }
      if (!_disposed) {
        _setReplicationMessage(
          context.scriptId,
          '正在用视觉模型解析镜头 ${shot.shotNumber} 的画面维度…',
        );
      }
      final prompt = await _buildVisionEnhancedGenerationPrompt(
        shot: shot,
        references: preparedReferences,
        model: model,
        original: original,
        guide: guide,
        hasPoseSkeleton: skeleton != null,
      );
      record = record.copyWith(
        assetIds: preparedReferences
            .map((reference) => reference.id)
            .toSet()
            .toList(),
        prompt: prompt,
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      final referenceCount =
          1 + (skeleton == null ? 0 : 1) + preparedReferences.length;
      if (referenceCount > descriptor.maxReferenceImages) {
        throw FormatException(
          '${descriptor.label} 最多支持 ${descriptor.maxReferenceImages} 张参考图；'
          '当前为原视频帧 1 张、DWPose 骨架 ${skeleton == null ? 0 : 1} 张、绑定及裁切资产 ${preparedReferences.length} 张。请减少绑定资产后重试。',
        );
      }
      final aspectRatio = run.inheritSourceAspectRatio
          ? _closestSupportedSourceAspectRatio(
              original,
              descriptor.aspectRatios,
              fallback: run.generationAspectRatio,
            )
          : _catalogOption(
              run.generationAspectRatio,
              descriptor.aspectRatios,
              preferred: '16:9',
            );
      final imageSize = _catalogOption(
        run.generationImageSize,
        ImageGenerationCatalog.resolutionsFor(model, aspectRatio),
        preferred: '2K',
      );
      final quality = _catalogOption(
        run.generationQuality,
        descriptor.qualities,
        preferred: 'high',
      );
      final outputDirectory = Directory(
        p.join(
          _directories.generatedImages.path,
          'replicate',
          _safeFileName(run.id),
        ),
      );
      await outputDirectory.create(recursive: true);
      final generationRequest = ImageGenerationRequest(
        provider: ImageGenerationProviderResolver.resolve(
          settings: _settingsController.value,
          model: model,
        ),
        model: model,
        prompt: record.prompt,
        aspectRatio: aspectRatio,
        imageSize: imageSize,
        quality: quality,
        referenceImagePaths: [
          original.path,
          if (skeleton != null) skeleton.path,
          for (final reference in preparedReferences) reference.path,
        ],
        outputDirectory: outputDirectory,
      );
      final result = await _imageGenerationService.generateEditedImage(
        generationRequest,
      );
      final persistedPath = await _persistGeneratedFrame(
        sourcePath: result.localPath,
        outputDirectory: outputDirectory,
        shot: shot,
        previousPath: existing?.generatedFramePath ?? '',
      );
      record = record.copyWith(
        generatedFramePath: persistedPath,
        rawResponse: result.rawResponse,
        generationRecovery: ReplicatedShotGenerationRecovery.empty,
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return true;
    } catch (error) {
      record = record.copyWith(
        status: ProcessingStatus.failed,
        errorMessage: '$error',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return false;
    }
  }

  Future<bool> _reviewAndCorrectReplicatedShot({
    required ScriptShot shot,
    required _ReplicationContext context,
    required File original,
    required ImageGenerationRequest generationRequest,
    required ImageGenerationResult initialResult,
    required String initialPersistedPath,
    required Directory outputDirectory,
    required ReplicatedShotImage record,
  }) async {
    var recovery = record.generationRecovery;
    final reviews = _storedGenerationReviews(recovery.reviewAttempts);
    final restoredCorrectionRawResponse = _storedGenerationRawResponse(
      record,
      key: 'correctionGenerationRawResponse',
    );
    ImageGenerationResult? correctionResult =
        restoredCorrectionRawResponse.isEmpty
        ? null
        : ImageGenerationResult(
            localPath: initialPersistedPath,
            remoteUrl: '',
            rawResponse: restoredCorrectionRawResponse,
          );
    var correctionAttempted =
        recovery.stage == ReplicatedShotRecoveryStage.awaitingCorrectedReview;
    var persistedPath = initialPersistedPath;

    Future<ReplicationGenerationReviewResult> reviewCurrent() =>
        _generationReviewService.review(
          settings: _settingsController.value,
          input: ReplicationGenerationReviewInput(
            shotNumber: shot.shotNumber,
            originalFrame: original,
            orderedReferenceImages: [
              for (final path in generationRequest.referenceImagePaths)
                File(path),
            ],
            generatedImage: File(persistedPath),
            structuredConstraints: record.prompt,
          ),
          allowThinking: _settingsController.value.videoAnalysisThinkingEnabled,
        );

    Future<bool> fail({
      required String diagnostic,
      required String stoppedReason,
    }) async {
      record = record.copyWith(
        generatedFramePath: persistedPath,
        rawResponse: _replicationAuditRawResponse(
          initialRawResponse: initialResult.rawResponse,
          correctionRawResponse: correctionResult?.rawResponse,
          reviews: reviews,
          correctionAttempted: correctionAttempted,
          stoppedReason: stoppedReason,
        ),
        status: ProcessingStatus.failed,
        errorMessage: diagnostic,
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return false;
    }

    ReplicationGenerationReviewIssue? issue;
    if (recovery.stage == ReplicatedShotRecoveryStage.awaitingInitialReview) {
      if (!_disposed) {
        _setReplicationMessage(
          context.scriptId,
          '正在审核镜头 ${shot.shotNumber} 的复刻结果…',
        );
      }
      ReplicationGenerationReviewResult firstReview;
      try {
        firstReview = await reviewCurrent();
        reviews.add(firstReview);
      } catch (error) {
        return fail(
          diagnostic: '生成结果已保留，但生成后审核失败：$error',
          stoppedReason: 'initial_review_error',
        );
      }
      if (firstReview.passed) {
        record = record.copyWith(
          rawResponse: _replicationAuditRawResponse(
            initialRawResponse: initialResult.rawResponse,
            reviews: reviews,
            correctionAttempted: false,
            stoppedReason: 'passed_initial_review',
          ),
          generationRecovery: ReplicatedShotGenerationRecovery.empty,
          status: ProcessingStatus.completed,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
        );
        _saveReplicatedImage(record);
        return true;
      }
      issue = firstReview.issue;
      if (issue == null) {
        return fail(
          diagnostic: '生成结果已保留，但审核未返回可验证的单一问题',
          stoppedReason: 'missing_review_issue',
        );
      }
      recovery = recovery.copyWith(
        stage: ReplicatedShotRecoveryStage.awaitingCorrection,
        reviewAttempts: [for (final review in reviews) review.toJson()],
      );
      record = record.copyWith(
        rawResponse: _replicationAuditRawResponse(
          initialRawResponse: initialResult.rawResponse,
          reviews: reviews,
          correctionAttempted: false,
          stoppedReason: 'awaiting_correction',
        ),
        generationRecovery: recovery,
        status: ProcessingStatus.running,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
    } else if (recovery.stage ==
        ReplicatedShotRecoveryStage.awaitingCorrection) {
      issue = reviews.isEmpty ? null : reviews.first.issue;
      if (issue == null) {
        return fail(
          diagnostic: '生成结果已保留，但持久化的首审问题无效，无法安全续轮纠错。',
          stoppedReason: 'invalid_persisted_review_issue',
        );
      }
    }

    if (recovery.stage != ReplicatedShotRecoveryStage.awaitingCorrectedReview) {
      final continuation =
          initialResult.geminiContinuation ??
          _restoredGeminiContinuation(recovery);
      if (continuation == null) {
        final unavailableReason = recovery.continuationDiagnostic.trim();
        return fail(
          diagnostic:
              '生成后审核未通过：${_replicationReviewDiagnostic(issue!)}；${unavailableReason.isEmpty ? '当前 Gemini 响应没有可用续轮状态' : unavailableReason}，已停止付费纠错并保留生成结果。',
          stoppedReason:
              recovery.continuationTransport ==
                  ReplicatedShotContinuationTransport.generateContent
              ? 'generate_content_restart_continuation_unavailable'
              : 'missing_gemini_continuation',
        );
      }

      if (!_disposed) {
        _setReplicationMessage(
          context.scriptId,
          '镜头 ${shot.shotNumber} 审核发现一个问题，正在执行唯一一次续轮纠错…',
        );
      }
      recovery = recovery.copyWith(
        stage: ReplicatedShotRecoveryStage.correctionInFlight,
      );
      record = record.copyWith(
        rawResponse: _replicationAuditRawResponse(
          initialRawResponse: initialResult.rawResponse,
          reviews: reviews,
          correctionAttempted: true,
          stoppedReason: 'correction_in_flight',
        ),
        generationRecovery: recovery,
        status: ProcessingStatus.running,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      try {
        correctionAttempted = true;
        correctionResult = await _imageGenerationService.generateEditedImage(
          ImageGenerationRequest(
            provider: generationRequest.provider,
            model: generationRequest.model,
            prompt: ReplicationGenerationReviewService.buildCorrectionPrompt(
              issue!,
            ),
            aspectRatio: generationRequest.aspectRatio,
            imageSize: generationRequest.imageSize,
            quality: generationRequest.quality,
            referenceImagePaths: const [],
            outputDirectory: generationRequest.outputDirectory,
            geminiContinuation: continuation,
          ),
        );
        persistedPath = await _persistGeneratedFrame(
          sourcePath: correctionResult.localPath,
          outputDirectory: outputDirectory,
          shot: shot,
          previousPath: persistedPath,
        );
        recovery = recovery.copyWith(
          stage: ReplicatedShotRecoveryStage.awaitingCorrectedReview,
          reviewAttempts: [for (final review in reviews) review.toJson()],
        );
        record = record.copyWith(
          generatedFramePath: persistedPath,
          rawResponse: _replicationAuditRawResponse(
            initialRawResponse: initialResult.rawResponse,
            correctionRawResponse: correctionResult.rawResponse,
            reviews: reviews,
            correctionAttempted: true,
            stoppedReason: 'awaiting_corrected_review',
          ),
          generationRecovery: recovery,
          status: ProcessingStatus.running,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
        );
        _saveReplicatedImage(record);
      } catch (error) {
        return fail(
          diagnostic: '生成结果已保留；唯一一次 Gemini 续轮纠错失败，已停止付费循环：$error',
          stoppedReason: 'correction_error',
        );
      }
    }

    if (!_disposed) {
      _setReplicationMessage(
        context.scriptId,
        '正在复核镜头 ${shot.shotNumber} 的纠错结果…',
      );
    }
    ReplicationGenerationReviewResult secondReview;
    try {
      secondReview = await reviewCurrent();
      reviews.add(secondReview);
    } catch (error) {
      return fail(
        diagnostic: '纠错结果已保留，但第二次审核失败；已停止继续付费纠错：$error',
        stoppedReason: 'corrected_review_error',
      );
    }
    if (!secondReview.passed) {
      final remainingIssue = secondReview.issue;
      return fail(
        diagnostic: remainingIssue == null
            ? '纠错后审核仍未通过，且未返回可验证问题；已停止继续付费纠错并保留结果。'
            : '纠错后审核仍未通过：${_replicationReviewDiagnostic(remainingIssue)}；已停止继续付费纠错并保留结果。',
        stoppedReason: 'failed_after_single_correction',
      );
    }

    record = record.copyWith(
      generatedFramePath: persistedPath,
      rawResponse: _replicationAuditRawResponse(
        initialRawResponse: initialResult.rawResponse,
        correctionRawResponse:
            correctionResult?.rawResponse ?? restoredCorrectionRawResponse,
        reviews: reviews,
        correctionAttempted: true,
        stoppedReason: 'passed_after_single_correction',
      ),
      generationRecovery: ReplicatedShotGenerationRecovery.empty,
      status: ProcessingStatus.completed,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _saveReplicatedImage(record);
    return true;
  }

  static String _replicationReviewDiagnostic(
    ReplicationGenerationReviewIssue issue,
  ) => '${issue.summary}（证据：${issue.evidence}）';

  static GeminiImageContinuation? _restoredGeminiContinuation(
    ReplicatedShotGenerationRecovery recovery,
  ) {
    if (!recovery.canResumeCorrection) return null;
    return GeminiImageContinuation(
      transport: GeminiImageContinuationTransport.interactions,
      apiModel: recovery.continuationApiModel,
      previousInteractionId: recovery.previousInteractionId,
    );
  }

  static List<ReplicationGenerationReviewResult> _storedGenerationReviews(
    List<Map<String, Object?>> stored,
  ) {
    try {
      return [
        for (final review in stored)
          ReplicationGenerationReviewResult.fromJson(review),
      ];
    } on FormatException {
      return const [];
    }
  }

  static String _storedGenerationRawResponse(
    ReplicatedShotImage record, {
    required String key,
  }) {
    try {
      final decoded = jsonDecode(record.rawResponse);
      if (decoded is Map && decoded['postGenerationReview'] is Map) {
        return decoded[key]?.toString() ?? '';
      }
    } on FormatException {
      // 首次生成响应可能不是 JSON；awaitingInitialReview 直接使用原值。
    }
    return key == 'initialGenerationRawResponse' ? record.rawResponse : '';
  }

  Future<bool> _resumeInterruptedReplicatedShot({
    required ScriptShot shot,
    required _ReplicationContext context,
    required File original,
    required ReplicatedShotImage record,
  }) async {
    final recovery = record.generationRecovery;
    if (recovery.stage == ReplicatedShotRecoveryStage.correctionInFlight) {
      _saveReplicatedImage(
        record.copyWith(
          status: ProcessingStatus.failed,
          errorMessage:
              '应用在唯一一次 Gemini 纠错请求已开始、结果尚未安全落盘时中断；无法确认该请求是否已执行或计费，为避免重复付费纠错，未再次发送图片请求。',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return false;
    }
    final generated = File(record.generatedFramePath.trim());
    final references = recovery.orderedReferencePaths;
    final storedReviews = _storedGenerationReviews(recovery.reviewAttempts);
    final storedInitialRawResponse = _storedGenerationRawResponse(
      record,
      key: 'initialGenerationRawResponse',
    );
    final storedCorrectionRawResponse = _storedGenerationRawResponse(
      record,
      key: 'correctionGenerationRawResponse',
    );
    final needsStoredFirstReview =
        recovery.stage != ReplicatedShotRecoveryStage.awaitingInitialReview;
    final hasValidStoredFirstReview =
        storedReviews.length == 1 &&
        !storedReviews.single.passed &&
        storedReviews.single.issue != null;
    final invalidInput =
        !NanoBananaProModelCapability.supports(record.model) ||
        !original.existsSync() ||
        record.prompt.trim().isEmpty ||
        !generated.existsSync() ||
        references.isEmpty ||
        File(references.first).absolute.path != original.absolute.path ||
        references.any((path) => !File(path).existsSync()) ||
        recovery.aspectRatio.trim().isEmpty ||
        recovery.imageSize.trim().isEmpty ||
        recovery.quality.trim().isEmpty ||
        storedInitialRawResponse.trim().isEmpty ||
        (needsStoredFirstReview && !hasValidStoredFirstReview) ||
        (recovery.stage ==
                ReplicatedShotRecoveryStage.awaitingCorrectedReview &&
            storedCorrectionRawResponse.trim().isEmpty);
    if (invalidInput) {
      _saveReplicatedImage(
        record.copyWith(
          status: ProcessingStatus.failed,
          errorMessage:
              '检测到中断的复刻任务，但恢复所需的生成参数、原图、稳定顺序参考图或结果图已不完整；为避免错误续轮，未发起任何图片请求。',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return false;
    }
    final outputDirectory = Directory(
      p.join(
        _directories.generatedImages.path,
        'replicate',
        _safeFileName(context.run.id),
      ),
    );
    await outputDirectory.create(recursive: true);
    final generationRequest = ImageGenerationRequest(
      provider: ImageGenerationProviderResolver.resolve(
        settings: _settingsController.value,
        model: record.model,
      ),
      model: record.model,
      prompt: record.prompt,
      aspectRatio: recovery.aspectRatio,
      imageSize: recovery.imageSize,
      quality: recovery.quality,
      referenceImagePaths: [...references],
      outputDirectory: outputDirectory,
    );
    final initialResult = ImageGenerationResult(
      localPath: generated.path,
      remoteUrl: '',
      rawResponse: storedInitialRawResponse,
      geminiContinuation: _restoredGeminiContinuation(recovery),
    );
    return _reviewAndCorrectReplicatedShot(
      shot: shot,
      context: context,
      original: original,
      generationRequest: generationRequest,
      initialResult: initialResult,
      initialPersistedPath: generated.path,
      outputDirectory: outputDirectory,
      record: record,
    );
  }

  static String _replicationAuditRawResponse({
    required String initialRawResponse,
    String? correctionRawResponse,
    required List<ReplicationGenerationReviewResult> reviews,
    required bool correctionAttempted,
    required String stoppedReason,
  }) => jsonEncode({
    'initialGenerationRawResponse': initialRawResponse,
    'correctionGenerationRawResponse': ?correctionRawResponse,
    'postGenerationReview': {
      'attempts': [for (final review in reviews) review.toJson()],
      'correctionAttempted': correctionAttempted,
      'stoppedReason': stoppedReason,
    },
  });

  Future<String> _buildVisionEnhancedGenerationPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required String model,
    required File original,
    required ReplicateShotGuide? guide,
    required bool hasPoseSkeleton,
  }) async {
    try {
      final analysis = await _visionService.analyzeImage(
        settings: _settingsController.value,
        imageFile: original,
        sequenceNo: shot.shotNumber,
        rowIndex: 0,
        columnIndex: shot.shotNumber - 1,
        allowThinking: _settingsController.value.videoAnalysisThinkingEnabled,
      );
      return _finalizeGenerationPrompt(
        shot: shot,
        references: references,
        model: model,
        original: original,
        automaticPrompt: _generationPrompt(
          shot,
          references,
          model,
          analysis: analysis,
          guide: guide,
          hasPoseSkeleton: hasPoseSkeleton,
        ),
        hasPoseSkeleton: hasPoseSkeleton,
      );
    } catch (_) {
      // 视觉模型不可用、超时或返回格式异常时，保留原有一键生成能力。
      return _finalizeGenerationPrompt(
        shot: shot,
        references: references,
        model: model,
        original: original,
        automaticPrompt: _generationPrompt(
          shot,
          references,
          model,
          guide: guide,
          hasPoseSkeleton: hasPoseSkeleton,
        ),
        hasPoseSkeleton: hasPoseSkeleton,
      );
    }
  }

  Future<String> _finalizeGenerationPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required String model,
    required File original,
    required String automaticPrompt,
    required bool hasPoseSkeleton,
  }) async {
    if (NanoBananaProModelCapability.supports(model)) {
      return const NanoBananaReplicationPromptCompiler().compile(
        NanoBananaReplicationPromptInput(
          model: model,
          automaticPrompt: automaticPrompt,
          manifest: _nanoBananaAssetManifest(
            shot: shot,
            original: original,
            references: references,
          ),
          userInstructions: shot.replicationInstructions,
          structuralReferenceDescriptions: hasPoseSkeleton
              ? const ['DWPose 高精度人物姿势骨架，只锁定关节位置、肢体方向、身体重心和动作轮廓']
              : const [],
        ),
      );
    }
    final prompt = await _resolveUserPriorityGenerationPrompt(
      shot: shot,
      references: references,
      original: original,
      automaticPrompt: automaticPrompt,
    );
    return _appendFinalTextSafetyCheck(prompt);
  }

  Future<String> _resolveUserPriorityGenerationPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required File original,
    required String automaticPrompt,
  }) async {
    final instructions = shot.replicationInstructions.trim();
    if (instructions.isEmpty) return automaticPrompt;
    final fallback = _userPriorityFallbackPrompt(
      automaticPrompt: automaticPrompt,
      instructions: instructions,
    );
    try {
      final resolved = await _visionService.complete(
        settings: _settingsController.value,
        imageFiles: [original],
        maxTokens: 1800,
        allowThinking: _settingsController.value.videoAnalysisThinkingEnabled,
        prompt: _userPriorityResolutionPrompt(
          shot: shot,
          references: references,
          automaticPrompt: automaticPrompt,
          instructions: instructions,
        ),
      );
      final normalized = resolved
          .trim()
          .replaceFirst(
            RegExp(r'^```(?:text|markdown)?\s*', multiLine: true),
            '',
          )
          .replaceFirst(RegExp(r'\s*```$', multiLine: true), '')
          .trim();
      return normalized.isEmpty ||
              !_retainsAutomaticReplicationConstraints(
                automaticPrompt: automaticPrompt,
                resolvedPrompt: normalized,
              )
          ? fallback
          : normalized;
    } catch (_) {
      // 解析服务异常时仍把用户要求明确置于末尾最高优先级，避免静默丢失。
      return fallback;
    }
  }

  static bool _retainsAutomaticReplicationConstraints({
    required String automaticPrompt,
    required String resolvedPrompt,
  }) {
    const coreMarkers = ['图片1是原视频镜头', '绑定资产硬约束', '画面文字与标识零容忍硬约束'];
    const conditionalMarkers = [
      'Gemini 3 精确多图复刻执行协议',
      'DWPose 高精度人物姿势骨架图',
      '多模特身份与位置绑定硬约束',
      '多模特产品一一绑定硬约束',
      '用户已勾选保留元素',
      '未勾选元素：必须移除',
    ];
    for (final marker in [...coreMarkers, ...conditionalMarkers]) {
      if (automaticPrompt.contains(marker) &&
          !resolvedPrompt.contains(marker)) {
        return false;
      }
    }
    return true;
  }

  static String _userPriorityFallbackPrompt({
    required String automaticPrompt,
    required String instructions,
  }) =>
      '$automaticPrompt\n\n'
      '【用户补充说明：最高优先级】$instructions\n'
      '冲突处理：用户补充说明可覆盖自动解析和资产描述，但不得取消或改写“原帧主体处理计划”的逐项决策；只有计划中明确标记保留的原人物或原产品可以沿用，其他主体不得改为保留，也不得改变图片1的光线与调色。原帧配饰和道具只有用户已勾选的白名单元素可以继承；未勾选项即使在补充说明中被提及也必须移除。\n'
      '文字例外判定：只有用户补充说明明确要求画面出现文本并给出需要逐字呈现的具体内容时，才可开放该段指定文本；其他情况仍必须执行无文字、无 Logo 硬约束。';

  static String _userPriorityResolutionPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required String automaticPrompt,
    required String instructions,
  }) =>
      '''
你是图像生成提示词编辑器。请根据图片1和以下文本，输出一份可直接提交给图片生成 API 的中文最终提示词。

最高优先级规则：用户补充说明高于自动解析、镜头脚本和固定复刻规则；但图片1原视频帧的色彩风格、色温、明暗关系、对比度、光影层次和电影调色不可被任何文本覆盖。若用户说明涉及调色，只能将新实体融入图片1调色，不得另行换色或重调。

镜头：${shot.shotNumber}
当前绑定素材：${references.map((item) => '${_replacementTypeLabel(item.type)}「${item.name}」').join('、')}

用户补充说明（最高优先级）：
$instructions

自动解析的提示词（仅作待清理草稿）：
$automaticPrompt

编辑要求：
1. 保留与用户说明不冲突的镜头叙事、构图、动作、光影和已绑定素材要求；色彩与调色必须完整沿用图片1。
2. 用户要求替换、移除或不要出现的元素，必须明确写为“不出现/替换为”并移除原有相反表述；人物配饰包括首饰、眼镜、帽子、包、手表、发饰等。
3. 必须完整保留并逐项执行“原帧主体处理计划”。保留项完整沿用图片1中的对应主体；替换项不得继承图片1外观；移除项不得残留。不得改写任何一项处理方式。原帧配饰和道具只有“用户已勾选保留元素”可以继承；“未勾选元素：必须移除”中的每一项都必须消失并自然补全，即使用户补充说明提及也不得恢复。
4. 必须完整保留自动提示词中的“画面文字与标识零容忍硬约束”。只有用户补充说明明确要求画面出现文本并给出需要逐字呈现的具体内容时，才允许该段指定文本；不得把参考图中的其他文字或 Logo 带入成图。
5. 只输出最终提示词正文，不要解释、标题、Markdown、JSON 或分析过程。
''';

  static const _textAndLogoExclusionConstraint =
      '【画面文字与标识零容忍硬约束】默认输出必须是纯净无字画面。图片1及其他参考图中出现的所有文字、数字、字母、符号组合、底部字幕、标题、贴纸文字、界面文字、水印、品牌 Logo、商标、台标、角标、二维码和条形码，都只能用于理解画面，严禁复制、临摹、变体重绘、替换或新增；必须将相关区域重建为符合场景的自然无字纹理或无标识造型。即使镜头脚本、视觉解析、资产名称、资产描述或产品包装提到了这些内容，也不得出现在成图中。唯一例外：用户在“复刻补充说明”中明确要求画面出现文本，并给出需要逐字呈现的具体内容；此时只允许生成该段指定文本，仍禁止参考图中的其他任何文字或 Logo。';

  static String _appendFinalTextSafetyCheck(String prompt) =>
      '${prompt.trim()}\n\n'
      '【最终输出复核】若用户未在“复刻补充说明”中明确给出需要逐字出现的具体文本，成图必须完全不含任何文字、数字、字母、符号组合、字幕、水印、Logo、商标、台标、角标、二维码或条形码；若用户已明确给出，只允许该段指定文本，其他文字与标识一律禁止。';

  String _generationPrompt(
    ScriptShot shot,
    List<_ReplacementReference> references,
    String model, {
    VisionImageAnalysis? analysis,
    ReplicateShotGuide? guide,
    bool hasPoseSkeleton = false,
  }) {
    final base = _replacementPrompt(
      shot,
      references,
      analysis: analysis,
      guide: guide,
      hasPoseSkeleton: hasPoseSkeleton,
    );
    if (NanoBananaProModelCapability.supports(model)) {
      return base;
    }
    return usesGemini3ImagePrompting(model)
        ? buildGeminiStoryboardPrompt(
            base,
            hasReferenceImages: references.isNotEmpty,
            preserveReferenceComposition: true,
          )
        : base;
  }

  Future<String> _persistGeneratedFrame({
    required String sourcePath,
    required Directory outputDirectory,
    required ScriptShot shot,
    required String previousPath,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('图片生成成功但本地文件不存在', sourcePath);
    }
    await outputDirectory.create(recursive: true);
    final extension = p.extension(source.path).trim().toLowerCase();
    final target = File(
      p.join(
        outputDirectory.path,
        'shot-${shot.shotNumber.toString().padLeft(3, '0')}-'
        '${_safeFileName(shot.id)}${extension.isEmpty ? '.png' : extension}',
      ),
    );
    if (!p.equals(source.absolute.path, target.absolute.path)) {
      await source.copy(target.path);
    }
    final sourceMetadata = File('${source.path}.json');
    if (await sourceMetadata.exists()) {
      await sourceMetadata.copy('${target.path}.json');
    }
    if (previousPath.trim().isNotEmpty &&
        !p.equals(previousPath, target.path)) {
      await _deleteManagedGeneratedFrame(previousPath, outputDirectory);
    }
    return target.path;
  }

  Future<void> _deleteManagedGeneratedFrame(
    String path,
    Directory outputDirectory,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      return;
    }
    final root = p.canonicalize(outputDirectory.absolute.path);
    final candidate = p.canonicalize(file.absolute.path);
    if (!p.isWithin(root, candidate)) {
      return;
    }
    await file.delete();
    final metadata = File('${file.path}.json');
    if (await metadata.exists()) {
      await metadata.delete();
    }
  }

  Future<bool> buildFreeCreationPrompts({
    int? maxConcurrent,
    Set<String>? onlyShotIds,
    bool overwriteUserEdited = false,
  }) async {
    final scriptId = value.selectedScriptId;
    final run = value.run;
    final shots = List<ScriptShot>.unmodifiable(value.shots);
    final groups = ScriptShotGroup.group(shots);
    if (run == null || !run.freeCreationEnabled || groups.isEmpty) {
      value = value.copyWith(errorMessage: '当前没有可构建的自由创作镜头', message: '');
      return false;
    }
    final replicatedImages = List<ReplicatedShotImage>.unmodifiable(
      _restoreReplicatedImages(run.id),
    );
    if (isBuildActiveFor(scriptId)) {
      value = value.copyWith(errorMessage: '当前脚本已在构建中', message: '');
      return false;
    }
    final inputs = <String, _FreeCreationPromptInput>{};
    final overLimitLabels = <String>[];
    for (final group in groups) {
      final input = _freeCreationPromptInput(group, replicatedImages);
      inputs[group.shots.first.id] = input;
      if (input.references.length > 9) {
        overLimitLabels.add(
          '${group.rangeLabel}（${input.references.length} 张）',
        );
      }
    }
    if (overLimitLabels.isNotEmpty) {
      value = value.copyWith(
        message: '',
        errorMessage: '以下镜头的参考图超过 9 张：${overLimitLabels.join('、')}。请拆分镜头范围。',
      );
      return false;
    }

    final existingByShotId = <String, ShotPrompt>{
      for (final prompt in List<ShotPrompt>.unmodifiable(value.prompts))
        if ((prompt.scriptShotId ?? '').isNotEmpty)
          prompt.scriptShotId!: prompt,
    };
    final targetGroups = [
      for (final group in groups)
        if (onlyShotIds == null || onlyShotIds.contains(group.shots.first.id))
          group,
    ];
    if (targetGroups.isEmpty) {
      value = value.copyWith(errorMessage: '未找到需要重新生成的镜头', message: '');
      return false;
    }

    final running = run.copyWith(
      status: ProcessingStatus.running,
      composePromptsStatus: ProcessingStatus.running,
      completedCount: 0,
      totalCount: groups.length,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(running);
    _beginBuild(scriptId);
    _setBuildStatus(
      scriptId,
      message: '正在整体理解 0/${targetGroups.length} 个自由创作镜头…',
      errorMessage: '',
    );
    if (value.selectedScriptId == scriptId) {
      value = value.copyWith(run: running);
    }

    var finalMessage = '';
    var finalError = '';
    try {
      final generatedByShotId = <String, ShotPrompt>{};
      final durationByTailShotId = <String, int>{};
      var nextIndex = 0;
      var completed = 0;
      var succeeded = 0;
      final concurrency = (maxConcurrent ?? defaultComposePromptConcurrency)
          .clamp(1, targetGroups.length)
          .toInt();

      Future<void> worker() async {
        while (true) {
          final index = nextIndex++;
          if (index >= targetGroups.length) return;
          final group = targetGroups[index];
          final head = group.shots.first;
          final existing = existingByShotId[head.id];
          if (existing?.isUserEdited == true &&
              !overwriteUserEdited &&
              _freeCreationPromptMatchesInput(
                prompt: existing!,
                group: group,
                input: inputs[head.id]!,
              )) {
            generatedByShotId[head.id] = existing;
            completed++;
            succeeded++;
            continue;
          }
          final result = await _generateFreeCreationPrompt(
            run: running,
            group: group,
            input: inputs[head.id]!,
            existing: existing,
          );
          generatedByShotId[head.id] = result.prompt;
          if (result.durationSeconds != null) {
            durationByTailShotId[group.shots.last.id] = result.durationSeconds!;
          }
          completed++;
          if (result.prompt.status == ProcessingStatus.completed) succeeded++;
          _setBuildStatus(
            scriptId,
            message:
                '正在整体理解自由创作镜头 $completed/${targetGroups.length}，成功 $succeeded 个…',
          );
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
      final finalPrompts = <ShotPrompt>[];
      for (final group in groups) {
        final shotId = group.shots.first.id;
        final generated = generatedByShotId[shotId];
        final existing = existingByShotId[shotId];
        if (generated != null) {
          finalPrompts.add(generated);
        } else if (existing != null) {
          finalPrompts.add(existing);
        }
      }
      _repository.replacePrompts(run.id, finalPrompts);

      final failed = finalPrompts
          .where((prompt) => prompt.status == ProcessingStatus.failed)
          .length;
      final finished = running.copyWith(
        status: failed == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        composePromptsStatus: failed == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        completedCount: finalPrompts.length - failed,
        totalCount: groups.length,
        errorMessage: failed == 0 ? '' : '$failed 个镜头提示词生成失败',
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(finished);
      _shootingScriptController.updateGeneratedFieldsForScript(
        scriptId: scriptId,
        promptsByShotId: {
          for (final prompt in finalPrompts)
            if ((prompt.scriptShotId ?? '').isNotEmpty &&
                prompt.status == ProcessingStatus.completed &&
                prompt.prompt.trim().isNotEmpty)
              prompt.scriptShotId!: prompt.prompt,
        },
        durationSecondsByShotId: {
          for (final entry in durationByTailShotId.entries)
            entry.key: entry.value.toDouble(),
        },
      );
      finalMessage = failed == 0
          ? '已完成 ${finalPrompts.length} 个自由创作 H3 提示词'
          : '';
      finalError = finished.errorMessage;
      return failed == 0;
    } catch (error) {
      finalError = '构建脚本失败：$error';
      _repository.upsertRun(
        running.copyWith(
          status: ProcessingStatus.failed,
          composePromptsStatus: ProcessingStatus.failed,
          errorMessage: finalError,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return false;
    } finally {
      _finishBuild(scriptId);
      _buildMessagesByScriptId[scriptId] = finalMessage;
      _buildErrorsByScriptId[scriptId] = finalError;
      if (!_disposed && value.selectedScriptId == scriptId) {
        _restoreFromShootingScript(selectScriptId: scriptId);
        _setBuildStatus(
          scriptId,
          message: finalMessage,
          errorMessage: finalError,
        );
      }
    }
  }

  Future<_FreeCreationPromptResult> _generateFreeCreationPrompt({
    required ReplicateRun run,
    required ScriptShotGroup group,
    required _FreeCreationPromptInput input,
    required ShotPrompt? existing,
  }) async {
    final head = group.shots.first;
    if (input.references.isEmpty) {
      return _FreeCreationPromptResult(
        prompt: _failedFreeCreationPrompt(
          run: run,
          shot: head,
          existing: existing,
          assetIds: const [],
          error: '镜头组没有可用的复刻分镜或原始帧',
        ),
      );
    }
    final selectedFormat = _composePromptModelRule.format;
    String normalized = '';
    List<String> validationErrors = const [];
    var attempts = 0;
    try {
      final fullStyleSkillContext = await _videoSkillContextForInput(input);
      for (var attempt = 0; attempt < 2; attempt++) {
        attempts = attempt + 1;
        final instruction = selectedFormat == ShotPromptFormat.h3
            ? _h3PromptWritingService.buildRewriteInstruction(
                draft: _freeCreationIntentDraft(group: group, input: input),
                durationSeconds: group.durationSeconds,
                storyboardImageCount: input.storyboardImageCount,
                references: [
                  for (var index = 0; index < input.references.length; index++)
                    H3PromptReference(
                      pictureNumber: index + 1,
                      role: input.references[index].role,
                      name: input.references[index].name,
                    ),
                ],
                style: input.skillRoute.promptStyle,
                chooseDurationFromIntent: true,
                fullStyleSkillContext: fullStyleSkillContext,
                repairErrors: attempt == 0 ? const [] : validationErrors,
                previousInvalidPrompt: attempt == 0 ? '' : normalized,
                singleContinuousShot: input.singleContinuousShot,
                allowSlowMotion: input.allowSlowMotion,
              )
            : _freeCreationPromptWritingService.buildRewriteInstruction(
                format: selectedFormat,
                userDescription: group.shots.first.freeCreationDescription
                    .trim(),
                referenceRoles: [
                  for (final reference in input.references) reference.role,
                ],
                singleContinuousShot: input.singleContinuousShot,
                explicitMultiShotIntent: input.explicitMultiShotIntent,
                allowSlowMotion: input.allowSlowMotion,
                backendSkillContext: fullStyleSkillContext,
                repairErrors: attempt == 0 ? const [] : validationErrors,
                previousInvalidPrompt: attempt == 0 ? '' : normalized,
              );
        final response = await _visionService.complete(
          settings: _settingsController.value,
          prompt: instruction,
          imageFiles: [
            for (final reference in input.references) reference.file,
          ],
          maxTokens: selectedFormat == ShotPromptFormat.h3 ? 6500 : 2200,
          allowThinking: _settingsController.value.videoAnalysisThinkingEnabled,
          responseTimeout: freeCreationVisionRequestTimeout,
          compressOversizedImages: true,
        );
        if (selectedFormat == ShotPromptFormat.h3) {
          normalized = _h3PromptWritingService.normalize(response);
          validationErrors = _h3PromptWritingService.validationErrors(
            normalized,
            referenceImageCount: input.references.length,
            requireAiDuration: true,
            singleContinuousShot: input.singleContinuousShot,
            allowSlowMotion: input.allowSlowMotion,
          );
        } else {
          normalized = _freeCreationPromptWritingService.normalize(response);
          validationErrors = _freeCreationPromptWritingService.validationErrors(
            normalized,
            selectedFormat,
          );
        }
        if (validationErrors.isEmpty) break;
      }
      if (validationErrors.isNotEmpty) {
        return _FreeCreationPromptResult(
          prompt: _failedFreeCreationPrompt(
            run: run,
            shot: head,
            existing: existing,
            assetIds: const [],
            error: '格式自动修复后仍未通过：${validationErrors.join('；')}',
          ),
        );
      }
      final duration = selectedFormat == ShotPromptFormat.h3
          ? _h3PromptWritingService.extractDurationSeconds(normalized)
          : _freeCreationPromptWritingService.extractDurationSeconds(
              normalized,
            );
      final variants = <ShotPromptFormat, String>{
        ShotPromptFormat.sd2: '',
        ShotPromptFormat.kling: '',
        ShotPromptFormat.h3: '',
        selectedFormat: normalized,
      };
      final raw = <String, Object?>{
        'promptRulesVersion': _freeCreationPromptRulesVersion,
        'promptSource': 'freeCreationReferenceVision',
        'assemblyMode': 'modelNativeVisionRewrite',
        'visionModelCalls': attempts,
        'formatRepairCount': attempts - 1,
        'h3PromptStyleId': input.skillRoute.promptStyle.id,
        'videoSkillBackend': input.skillRoute.backendKind?.name ?? 'none',
        'videoSkillAutomaticallySelected':
            input.skillRoute.automaticallySelected,
        'referenceImagePaths': [
          for (final reference in input.references) reference.file.path,
        ],
        'referenceSource': input.referenceSource,
        'referenceImageCount': input.references.length,
        'shotStructureMode': input.singleContinuousShot
            ? 'singleContinuousShot'
            : input.explicitMultiShotIntent
            ? 'explicitMultiShot'
            : 'singleReference',
        'slowMotionAuthorized': input.allowSlowMotion,
        'freeCreationDescription': head.freeCreationDescription,
        'freeCreationContextMode':
            'referenceImagesOptionalUserDescriptionAndSkill',
        'storyContextIncluded': false,
        'linkedAssetImagesIncluded': false,
        'sd2Prompt': variants[ShotPromptFormat.sd2],
        'klingPrompt': variants[ShotPromptFormat.kling],
        'h3Prompt': variants[ShotPromptFormat.h3],
        'selectedPromptFormat': selectedFormat.name,
        'videoModelPromptRule': {
          'format': selectedFormat.name,
          'label': _promptFormatLabel(selectedFormat),
        },
        'aiDurationSeconds': duration,
        'freeCreationInputFingerprint': _freeCreationInputFingerprint(
          group: group,
          input: input,
        ),
      };
      return _FreeCreationPromptResult(
        prompt: ShotPrompt(
          id: existing?.id ?? _promptId(run.id, head.id),
          runId: run.id,
          shotNumber: head.shotNumber,
          scriptShotId: head.id,
          assetIds: const [],
          prompt: normalized,
          model: _promptFormatLabel(selectedFormat),
          rawResponse: jsonEncode(raw),
          isUserEdited: false,
          status: ProcessingStatus.completed,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
        ),
        durationSeconds: duration,
      );
    } catch (error) {
      return _FreeCreationPromptResult(
        prompt: _failedFreeCreationPrompt(
          run: run,
          shot: head,
          existing: existing,
          assetIds: const [],
          error: '整体多模态理解失败：$error',
        ),
      );
    }
  }

  ShotPrompt _failedFreeCreationPrompt({
    required ReplicateRun run,
    required ScriptShot shot,
    required ShotPrompt? existing,
    required List<String> assetIds,
    required String error,
  }) =>
      (existing ??
              ShotPrompt(
                id: _promptId(run.id, shot.id),
                runId: run.id,
                shotNumber: shot.shotNumber,
                scriptShotId: shot.id,
                assetIds: assetIds,
                prompt: '',
                model: _promptFormatLabel(_composePromptModelRule.format),
                rawResponse: '{}',
                status: ProcessingStatus.failed,
                errorMessage: error,
                updatedAt: DateTime.now().toUtc(),
              ))
          .copyWith(
            assetIds: assetIds,
            status: ProcessingStatus.failed,
            errorMessage: error,
            updatedAt: DateTime.now().toUtc(),
          );

  _FreeCreationPromptInput _freeCreationPromptInput(
    ScriptShotGroup group,
    List<ReplicatedShotImage> replicatedImages,
  ) {
    final references = <_FreeCreationImageReference>[];
    final usedPaths = <String>{};
    var storyboardImageCount = 0;
    final explicitMultiShotIntent =
        H3PromptWritingService.hasExplicitMultiShotIntent(
          group.shots.first.freeCreationDescription,
        );
    final replicatedByShotId = <String, ReplicatedShotImage>{
      for (final image in replicatedImages) image.scriptShotId: image,
    };
    final replicaFiles = <File>[];
    for (final shot in group.shots) {
      final replica = replicatedByShotId[shot.id];
      final path = replica?.status == ProcessingStatus.completed
          ? replica?.generatedFramePath.trim() ?? ''
          : '';
      final file = File(path);
      if (path.isEmpty || !file.existsSync()) {
        replicaFiles.clear();
        break;
      }
      replicaFiles.add(file);
    }
    final useReplicatedStoryboardGroup =
        replicaFiles.length == group.shots.length;
    for (var index = 0; index < group.shots.length; index++) {
      final shot = group.shots[index];
      final file = useReplicatedStoryboardGroup
          ? replicaFiles[index]
          : File(shot.framePath.trim());
      if (file.path.isEmpty || !file.existsSync()) continue;
      final normalized = p.normalize(file.absolute.path);
      if (!usedPaths.add(normalized)) continue;
      references.add(
        _FreeCreationImageReference(
          file: file,
          role: explicitMultiShotIntent
              ? '用户明确多镜头结构中的第 ${index + 1} 张顺序参考图，用于定义可见主体、构图与动作阶段；图片编号不自动等于镜头编号'
              : '同一物理连续镜头按时间顺序抽取的第 ${index + 1} 个动作阶段帧，用于定义可见主体、构图和阶段变化；不是新镜头首帧',
          name: useReplicatedStoryboardGroup ? '复刻分镜' : '原始故事板/视频帧',
        ),
      );
      storyboardImageCount++;
    }
    return _FreeCreationPromptInput(
      references: references,
      storyboardImageCount: storyboardImageCount,
      singleContinuousShot:
          H3PromptWritingService.shouldUseSingleContinuousShot(
            description: group.shots.first.freeCreationDescription,
            storyboardImageCount: storyboardImageCount,
          ),
      explicitMultiShotIntent: explicitMultiShotIntent,
      allowSlowMotion: CinematicMotionPolicy.hasExplicitSlowMotionIntent(
        group.shots.first.freeCreationDescription,
      ),
      referenceSource: useReplicatedStoryboardGroup
          ? 'replicatedStoryboardGroup'
          : 'originalFrameGroup',
      videoConfig: _settingsController.value.activeVideoGenerationApiConfig,
      skillRoute: const VideoSkillRouter().resolve(
        config: _settingsController.value.activeVideoGenerationApiConfig,
        narrativeText: _skillRoutingText(group.shots),
        preferredStyle: selectedH3PromptStyle,
      ),
    );
  }

  Future<String> _videoSkillContextForInput(
    _FreeCreationPromptInput input,
  ) async {
    final contexts = <String>[];
    final backendDocument = await _videoSkillLibrary.loadForConfig(
      input.videoConfig,
    );
    if (backendDocument != null) {
      contexts.add(backendDocument.toVisionModelContext());
    }
    final style = input.skillRoute.promptStyle;
    if (input.skillRoute.supportsH3NarrativeSkill && !style.isGeneral) {
      contexts.add(
        (await _h3SkillLibrary.loadForStyle(style)).toVisionModelContext(),
      );
    }
    if (input.skillRoute.automaticallySelected) {
      contexts.add('Skill 路由结果：已按当前镜头剧情自动选择“${style.label}”，不得套用其他专项 Skill。');
    }
    return contexts.join('\n\n');
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

  String _freeCreationIntentDraft({
    required ScriptShotGroup group,
    required _FreeCreationPromptInput input,
  }) {
    final head = group.shots.first;
    final description = head.freeCreationDescription.trim();
    final effectiveDescription = description.isEmpty
        ? '用户未提供文字描述。请仅根据参考图自动分析主体、动作、镜头节奏、运镜、声音与最合适的创作方向。'
        : description;
    final shotStructureBoundary = input.singleContinuousShot
        ? '''默认且强制按一个连续物理镜头生成：全部 Picture 是 [Shot 1] 的顺序阶段帧，只允许一个 [Shot 1]，不得产生切镜或 [Shot 2+]。'''
        : input.explicitMultiShotIntent
        ? '''用户文字已明确要求多镜头结构：按用户写出的切镜关系组织目标镜头，但不得把 Picture 数量机械等同于 Shot 数量。'''
        : '''当前只有一张画面参考；仅当用户文字明确要求切镜或多个目标镜头时才允许 [Shot 2+]。''';
    final playbackSpeedBoundary = input.allowSlowMotion
        ? '用户已在本镜头剧情描述中明确授权慢动作/升格；只按原文指定的动作和范围落实。'
        : '用户未在本镜头剧情描述中授权慢动作/升格；所有主体、表情、环境和声音按正常时间速度推进，任何 Skill、风格或参考图观感都不得引入慢动作、慢放、升格或变速慢放。缓慢运镜只表示摄影机移动速度。';
    final pictureLines = <String>[];
    for (var index = 0; index < input.references.length; index++) {
      final reference = input.references[index];
      pictureLines.add(
        '<Picture ${index + 1}>：${reference.role}；名称 ${reference.name.isEmpty ? '未命名' : reference.name}。',
      );
    }
    return '''
【当前镜头用户描述·唯一剧情文本】
$effectiveDescription

【附件顺序与作用·必须与上传顺序一致】
${pictureLines.join('\n')}

输入边界：只使用当前可选用户描述、以上参考图，以及外层提供的所选 Skill 与官方格式规则。
不得引入全局分镜故事、故事板字幕、相邻镜头描述、人物/产品/场景资产图、全局风格、制作边界、任务补充，或旧画面内容、景别、构图、机位、运镜、摄影备注等字段。
$shotStructureBoundary
$playbackSpeedBoundary
如果用户描述为空，请主动从参考图判断最合理的创作意图；否则综合用户描述与参考图。按所选 Skill 写成最终 Ref2VA 六字段提示词。
''';
  }

  String _freeCreationInputFingerprint({
    required ScriptShotGroup group,
    required _FreeCreationPromptInput input,
  }) => jsonEncode({
    'promptRulesVersion': _freeCreationPromptRulesVersion,
    'shotIds': [for (final shot in group.shots) shot.id],
    'shotNumbers': [for (final shot in group.shots) shot.shotNumber],
    'description': group.shots.first.freeCreationDescription.trim(),
    'h3PromptStyleId': input.skillRoute.promptStyle.id,
    'videoSkillBackend': input.skillRoute.backendKind?.name ?? 'none',
    'videoSkillAutomaticallySelected': input.skillRoute.automaticallySelected,
    'videoGenerationConfigId': input.videoConfig?.id ?? '',
    'videoGenerationModel': input.videoConfig?.model ?? '',
    'referenceSource': input.referenceSource,
    'shotStructureMode': input.singleContinuousShot
        ? 'singleContinuousShot'
        : input.explicitMultiShotIntent
        ? 'explicitMultiShot'
        : 'singleReference',
    'slowMotionAuthorized': input.allowSlowMotion,
    'references': [
      for (final reference in input.references)
        {
          'path': reference.file.path,
          'role': reference.role,
          'name': reference.name,
          'modifiedAt': reference.file.lastModifiedSync().toIso8601String(),
          'length': reference.file.lengthSync(),
        },
    ],
  });

  bool _freeCreationPromptMatchesInput({
    required ShotPrompt prompt,
    required ScriptShotGroup group,
    required _FreeCreationPromptInput input,
  }) {
    try {
      final raw = jsonDecode(prompt.rawResponse);
      return raw is Map &&
          raw['promptRulesVersion'] == _freeCreationPromptRulesVersion &&
          raw['promptSource'] == 'freeCreationReferenceVision' &&
          raw['freeCreationInputFingerprint'] ==
              _freeCreationInputFingerprint(group: group, input: input);
    } catch (_) {
      return false;
    }
  }

  Future<void> composeAllPrompts({
    int? maxConcurrent,
    bool navigateToComposeStep = false,
  }) async {
    final run = value.run;
    if (run?.freeCreationEnabled == true) {
      await buildFreeCreationPrompts(maxConcurrent: maxConcurrent);
      return;
    }
    final sequences = shotSequencesFor(value.confirmedShots);
    final shots = sequences
        .map((sequence) => sequence.head)
        .toList(growable: false);
    final assets = _readyAssets(value.assets);
    final modelRule = _composePromptModelRule;
    if (run == null || shots.isEmpty) {
      value = value.copyWith(errorMessage: '需要至少一个可用镜头', message: '');
      return;
    }
    final running = run.copyWith(
      currentStep: navigateToComposeStep
          ? ReplicateStep.composePrompts
          : run.currentStep,
      status: ProcessingStatus.running,
      composePromptsStatus: ProcessingStatus.running,
      completedCount: 0,
      totalCount: shots.length,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(running);
    value = value.copyWith(
      run: running,
      isBusy: true,
      message: '正在拼接 0/${shots.length} 个${modelRule.label}提示词…',
      errorMessage: '',
    );
    final prompts = List<ShotPrompt?>.filled(shots.length, null);
    var completed = 0;
    var succeeded = 0;
    var nextIndex = 0;
    final requestedConcurrency = maxConcurrent ?? modelRule.maxConcurrent;
    final concurrency = requestedConcurrency.clamp(1, shots.length).toInt();

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= shots.length) return;
        nextIndex++;
        final shot = shots[index];
        final actionSequence = _actionSequenceForPrompt(shot, sequences);
        final prompt = _composePrompt(
          run: running,
          shot: shot,
          assets: assets,
          actionSequence: actionSequence,
          previousShot: index > 0 ? shots[index - 1] : null,
          nextShot: index + 1 < shots.length ? shots[index + 1] : null,
          selectedFormat: modelRule.format,
        );
        prompts[index] = prompt;
        completed++;
        if (prompt.status == ProcessingStatus.completed) {
          succeeded++;
        }
        if (!_disposed) {
          value = value.copyWith(
            message:
                '正在拼接${modelRule.label}提示词 '
                '$completed/${shots.length}，成功 $succeeded 个…',
          );
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    final finishedPrompts = [for (final prompt in prompts) ?prompt];
    _repository.replacePrompts(run.id, finishedPrompts);
    final failed = finishedPrompts.length - succeeded;
    final finished = running.copyWith(
      status: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      composePromptsStatus: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      completedCount: succeeded,
      totalCount: finishedPrompts.length,
      errorMessage: failed == 0 ? '' : '$failed 个镜头提示词生成失败',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(finished);
    _syncScriptPromptFields(_ownerScriptId(run), finishedPrompts);
    if (!_disposed) {
      value = value.copyWith(
        run: finished,
        prompts: finishedPrompts,
        isBusy: false,
        message: failed == 0
            ? '已从构建脚本字段拼接 ${finishedPrompts.length} 个${modelRule.label}提示词（视觉模型 0 次）'
            : '',
        errorMessage: finished.errorMessage,
      );
    }
  }

  Future<void> regeneratePrompt(String promptId) async {
    final run = value.run;
    final index = value.prompts.indexWhere((prompt) => prompt.id == promptId);
    if (run == null || index < 0) {
      return;
    }
    final existing = value.prompts[index];
    if (run.freeCreationEnabled) {
      await buildFreeCreationPrompts(
        onlyShotIds: {existing.scriptShotId ?? ''},
        overwriteUserEdited: true,
      );
      return;
    }
    final shot = _shotById(existing.scriptShotId ?? '');
    if (shot == null) {
      return;
    }
    final orderedShots = [...value.confirmedShots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    final sequences = shotSequencesFor(orderedShots);
    final actionSequence = _actionSequenceForPrompt(shot, sequences);
    final promptShots = sequences
        .map((sequence) => sequence.head)
        .toList(growable: false);
    final shotIndex = promptShots.indexWhere((item) => item.id == shot.id);
    final updated = _composePrompt(
      run: run,
      shot: shot,
      assets: _readyAssets(value.assets),
      actionSequence: actionSequence,
      previousShot: shotIndex > 0 ? promptShots[shotIndex - 1] : null,
      nextShot: shotIndex >= 0 && shotIndex + 1 < promptShots.length
          ? promptShots[shotIndex + 1]
          : null,
      selectedFormat: _composePromptModelRule.format,
    );
    if (_disposed) return;
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(run, prompts, message: '镜头 ${shot.shotNumber} 已重新生成');
    _syncScriptPromptFields(_ownerScriptId(run), prompts);
  }

  Future<void> composePromptsForShotIds(Iterable<String> shotIds) async {
    final run = value.run;
    final targetIds = shotIds.toSet();
    final sequences = shotSequencesFor(value.confirmedShots);
    final shots = sequences
        .map((sequence) => sequence.head)
        .toList(growable: false);
    if (run == null || shots.isEmpty || targetIds.isEmpty) return;

    final existingByShotId = <String, ShotPrompt>{
      for (final prompt in value.prompts)
        if ((prompt.scriptShotId ?? '').isNotEmpty)
          prompt.scriptShotId!: prompt,
    };
    final assets = _readyAssets(value.assets);
    final modelRule = _composePromptModelRule;
    final prompts = <ShotPrompt>[];
    var rebuiltCount = 0;
    var repairedCount = 0;
    for (var index = 0; index < shots.length; index++) {
      final shot = shots[index];
      final existing = existingByShotId[shot.id];
      final isTarget = targetIds.contains(shot.id);
      final needsRepair =
          existing == null ||
          existing.status != ProcessingStatus.completed ||
          existing.prompt.trim().isEmpty;
      if (!isTarget && !needsRepair) {
        prompts.add(existing);
        continue;
      }
      final actionSequence = _actionSequenceForPrompt(shot, sequences);
      prompts.add(
        _composePrompt(
          run: run,
          shot: shot,
          assets: assets,
          actionSequence: actionSequence,
          previousShot: index > 0 ? shots[index - 1] : null,
          nextShot: index + 1 < shots.length ? shots[index + 1] : null,
          selectedFormat: modelRule.format,
        ),
      );
      if (isTarget) {
        rebuiltCount++;
      } else {
        repairedCount++;
      }
    }

    _repository.replacePrompts(run.id, prompts);
    final failed = prompts
        .where((prompt) => prompt.status == ProcessingStatus.failed)
        .length;
    final completed = prompts.length - failed;
    final finished = run.copyWith(
      status: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      composePromptsStatus: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      completedCount: completed,
      totalCount: prompts.length,
      errorMessage: failed == 0 ? '' : '$failed 个镜头提示词拼接失败',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(finished);
    _syncScriptPromptFields(_ownerScriptId(run), prompts);
    if (_disposed) return;
    value = value.copyWith(
      run: finished,
      prompts: prompts,
      isBusy: false,
      message: failed == 0
          ? '已根据反馈重拼 $rebuiltCount 个镜头提示词'
                '${repairedCount == 0 ? '' : '，并补齐 $repairedCount 个缺失结果'}'
          : '',
      errorMessage: finished.errorMessage,
    );
  }

  Future<void> retryFailedPrompts() async {
    final failed = [
      for (final prompt in value.prompts)
        if (prompt.status == ProcessingStatus.failed) prompt.id,
    ];
    for (final id in failed) {
      await regeneratePrompt(id);
    }
  }

  void updatePromptText(String promptId, String text) {
    final index = value.prompts.indexWhere((prompt) => prompt.id == promptId);
    final run = value.run;
    if (run == null || index < 0 || text.trim().isEmpty) {
      return;
    }
    final existing = value.prompts[index];
    final raw = _promptRaw(existing);
    final format = promptFormatFor(existing);
    raw[_promptKey(format)] = text.trim();
    raw['selectedPromptFormat'] = format.name;
    final updated = existing.copyWith(
      prompt: text.trim(),
      rawResponse: jsonEncode(raw),
      isUserEdited: true,
      status: ProcessingStatus.completed,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(run, prompts, message: '提示词已保存');
    _syncScriptPromptFields(_ownerScriptId(run), prompts);
  }

  bool synchronizeFreeCreationPromptDuration(
    String scriptShotId,
    double seconds,
  ) {
    if (value.run?.freeCreationEnabled != true || !seconds.isFinite) {
      return false;
    }
    final prompt = value.prompts
        .where((item) => item.scriptShotId == scriptShotId)
        .firstOrNull;
    if (prompt == null || prompt.status != ProcessingStatus.completed) {
      return false;
    }
    final rounded = seconds.roundToDouble();
    final duration = seconds == rounded
        ? '${rounded.toInt()}'
        : seconds.toStringAsFixed(1);
    final raw = _promptRaw(prompt);
    var changed = false;
    for (final format in ShotPromptFormat.values) {
      final key = _promptKey(format);
      final current = '${raw[key] ?? ''}';
      final synchronized = current.replaceAll(
        RegExp(r'\d+(?:\.\d+)?\s*秒视频'),
        '$duration秒视频',
      );
      if (synchronized != current) {
        raw[key] = synchronized;
        changed = true;
      }
    }
    if (!changed) return false;
    final selectedFormat = promptFormatFor(prompt);
    final updated = prompt.copyWith(
      prompt: '${raw[_promptKey(selectedFormat)]}',
      rawResponse: jsonEncode(raw),
      isUserEdited: true,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertPrompt(updated);
    final prompts = [
      for (final item in value.prompts)
        if (item.id == prompt.id) updated else item,
    ];
    _updatePromptProgress(value.run!, prompts, message: '提示词时长已同步');
    _syncScriptPromptFields(_ownerScriptId(value.run!), prompts);
    return true;
  }

  ShotPromptFormat promptFormatFor(ShotPrompt prompt) {
    final value = '${_promptRaw(prompt)['selectedPromptFormat']}';
    return ShotPromptFormat.values.firstWhere(
      (format) => format.name == value,
      orElse: () => ShotPromptFormat.sd2,
    );
  }

  String promptTextFor(ShotPrompt prompt, ShotPromptFormat format) {
    final text = '${_promptRaw(prompt)[_promptKey(format)] ?? ''}'.trim();
    return text.isEmpty ? prompt.prompt : text;
  }

  void selectPromptFormat(String promptId, ShotPromptFormat format) {
    final index = value.prompts.indexWhere((prompt) => prompt.id == promptId);
    final run = value.run;
    if (run == null || index < 0) return;
    final existing = value.prompts[index];
    final raw = _promptRaw(existing);
    var selectedText = '${raw[_promptKey(format)] ?? ''}'.trim();
    if (selectedText.isEmpty) return;
    raw['selectedPromptFormat'] = format.name;
    final updated = existing.copyWith(
      prompt: selectedText,
      rawResponse: jsonEncode(raw),
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(
      run,
      prompts,
      message: _promptFormatSelectedMessage(format),
    );
    _syncScriptPromptFields(_ownerScriptId(run), prompts);
  }

  void selectPromptFormatForAll(ShotPromptFormat format) {
    final run = value.run;
    if (run == null || value.prompts.isEmpty) return;
    var changed = false;
    final prompts = <ShotPrompt>[];
    for (final prompt in value.prompts) {
      final raw = _promptRaw(prompt);
      var selectedText = '${raw[_promptKey(format)] ?? ''}'.trim();
      if (selectedText.isEmpty || promptFormatFor(prompt) == format) {
        prompts.add(prompt);
        continue;
      }
      raw['selectedPromptFormat'] = format.name;
      final updated = prompt.copyWith(
        prompt: selectedText,
        rawResponse: jsonEncode(raw),
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertPrompt(updated);
      prompts.add(updated);
      changed = true;
    }
    if (!changed) return;
    _updatePromptProgress(
      run,
      prompts,
      message: '${_promptFormatSelectedMessage(format)}，已同步全部镜头',
    );
    _syncScriptPromptFields(_ownerScriptId(run), prompts);
  }

  Future<ReplicateExportResult?> exportPrompts() async {
    final script = value.selectedScript;
    final run = value.run;
    if (script == null || run == null || value.prompts.isEmpty) {
      value = value.copyWith(errorMessage: '当前没有可导出的提示词', message: '');
      return null;
    }
    try {
      await _directories.prompts.create(recursive: true);
      final base = '${_safeFileName(script.name)}-即梦2提示词';
      final xlsxFile = _uniqueFile(_directories.prompts, '$base.xlsx');
      final sorted = [
        ...value.prompts,
      ]..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
      await const ReplicatePromptExportService().export(
        script: script,
        shots: value.shots,
        prompts: sorted,
        replicatedImages: value.replicatedImages,
        outputPath: xlsxFile.path,
      );
      value = value.copyWith(
        message: '已导出合成提示词 XLSX：${xlsxFile.path}',
        errorMessage: '',
      );
      return ReplicateExportResult(xlsxFile: xlsxFile);
    } catch (error) {
      value = value.copyWith(message: '', errorMessage: '导出提示词失败：$error');
      return null;
    }
  }

  Future<ReplicateImageExportResult?> exportReplicatedImages() async {
    final script = value.selectedScript;
    if (script == null || value.isBusy) {
      return null;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在复制复刻分镜图…',
      errorMessage: '',
    );
    try {
      final directory = _uniqueDirectory(
        _directories.scripts,
        '${_safeFileName(script.name)}-复刻分镜图',
      );
      await directory.create(recursive: true);
      final replicatedByShotId = {
        for (final image in value.replicatedImages) image.scriptShotId: image,
      };
      var copied = 0;
      var missing = 0;
      for (final shot in value.shots) {
        final sourcePath =
            replicatedByShotId[shot.id]?.generatedFramePath.trim() ?? '';
        final source = File(sourcePath);
        if (sourcePath.isEmpty || !source.existsSync()) {
          missing++;
          continue;
        }
        final targetName =
            '${shot.shotNumber.toString().padLeft(3, '0')}-'
            '${_safeFileName(p.basenameWithoutExtension(source.path))}'
            '${p.extension(source.path)}';
        await source.copy(p.join(directory.path, targetName));
        copied++;
      }
      if (copied == 0) {
        await directory.delete(recursive: true);
        throw const FileSystemException('脚本中没有可导出的复刻分镜图');
      }
      final result = ReplicateImageExportResult(
        directory: directory,
        copiedCount: copied,
        missingCount: missing,
      );
      value = value.copyWith(
        isBusy: _isScriptBusy(value.selectedScriptId),
        message: missing == 0
            ? '已导出 $copied 张复刻分镜图到 ${directory.path}'
            : '已导出 $copied 张复刻分镜图，另有 $missing 个镜头缺图',
        errorMessage: '',
      );
      return result;
    } catch (error) {
      value = value.copyWith(
        isBusy: _isScriptBusy(value.selectedScriptId),
        message: '',
        errorMessage: '导出复刻分镜图失败：$error',
      );
      return null;
    }
  }

  Future<void> openPromptDirectory() async {
    await _directories.prompts.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [_directories.prompts.path]);
    }
  }

  void _handleShootingScriptChanged() {
    if (_disposed) {
      return;
    }
    _restoreFromShootingScript();
  }

  void _handleWorkflowChanged() {
    if (_disposed) {
      return;
    }
    _restoreFromShootingScript();
  }

  _ReplicationContext? _replicationContext() {
    final run = value.run;
    final scriptId = value.selectedScriptId;
    if (run == null || scriptId.isEmpty) {
      return null;
    }
    return _ReplicationContext(
      scriptId: scriptId,
      run: run,
      assets: [...value.assets],
    );
  }

  void _setReplicationMessage(String scriptId, String message) {
    if (_disposed) return;
    _replicationMessagesByScriptId[scriptId] = message;
    if (value.selectedScriptId != scriptId) {
      return;
    }
    value = value.copyWith(message: message);
  }

  int _activeReplicationCount(String scriptId) =>
      _activeReplicationCountsByScriptId[scriptId] ?? 0;

  bool _isReplicatingScript(String scriptId) =>
      _activeReplicationCount(scriptId) > 0;

  bool isBuildActiveFor(String scriptId) =>
      (_activeBuildCountsByScriptId[scriptId] ?? 0) > 0;

  bool _isScriptBusy(String scriptId) =>
      _isReplicatingScript(scriptId) || isBuildActiveFor(scriptId);

  bool _isAnalyzingFrames(String scriptId) =>
      (_activeFrameAnalysisCountsByScriptId[scriptId] ?? 0) > 0;

  void _beginFrameAnalysis(String scriptId) {
    _activeFrameAnalysisCountsByScriptId[scriptId] =
        (_activeFrameAnalysisCountsByScriptId[scriptId] ?? 0) + 1;
  }

  void _finishFrameAnalysis(String scriptId) {
    final remaining = (_activeFrameAnalysisCountsByScriptId[scriptId] ?? 0) - 1;
    if (remaining <= 0) {
      _activeFrameAnalysisCountsByScriptId.remove(scriptId);
    } else {
      _activeFrameAnalysisCountsByScriptId[scriptId] = remaining;
    }
  }

  void _reloadShotGuides(
    String scriptId, {
    String? message,
    String? errorMessage,
  }) {
    if (_disposed || scriptId.isEmpty || value.selectedScriptId != scriptId) {
      return;
    }
    value = value.copyWith(
      shotGuides: _repository.listShotGuidesForScript(scriptId),
      isAnalyzingFrames: _isAnalyzingFrames(scriptId),
      message: message,
      errorMessage: errorMessage,
    );
  }

  void _beginBuild(String scriptId) {
    _activeBuildCountsByScriptId[scriptId] =
        (_activeBuildCountsByScriptId[scriptId] ?? 0) + 1;
  }

  void _finishBuild(String scriptId) {
    final remaining = (_activeBuildCountsByScriptId[scriptId] ?? 0) - 1;
    if (remaining <= 0) {
      _activeBuildCountsByScriptId.remove(scriptId);
    } else {
      _activeBuildCountsByScriptId[scriptId] = remaining;
    }
  }

  void _setBuildStatus(
    String scriptId, {
    String? message,
    String? errorMessage,
  }) {
    if (message != null) _buildMessagesByScriptId[scriptId] = message;
    if (errorMessage != null) _buildErrorsByScriptId[scriptId] = errorMessage;
    if (_disposed || value.selectedScriptId != scriptId) return;
    value = value.copyWith(
      isBusy: _isScriptBusy(scriptId),
      message: message,
      errorMessage: errorMessage,
    );
  }

  void _beginReplication(String scriptId) {
    _activeReplicationCountsByScriptId[scriptId] =
        _activeReplicationCount(scriptId) + 1;
  }

  void _finishReplication(String scriptId) {
    final remaining = _activeReplicationCount(scriptId) - 1;
    if (remaining <= 0) {
      _activeReplicationCountsByScriptId.remove(scriptId);
    } else {
      _activeReplicationCountsByScriptId[scriptId] = remaining;
    }
  }

  void _restoreFromShootingScript({String? selectScriptId}) {
    final shooting = _shootingScriptController.value;
    final scripts = shooting.scripts;
    if (scripts.isEmpty) {
      value = const ReplicateState();
      return;
    }
    final requested = selectScriptId ?? shooting.selectedScriptId;
    final scriptId = scripts.any((script) => script.id == requested)
        ? requested
        : scripts.first.id;
    if (scriptId != shooting.selectedScriptId) {
      _shootingScriptController.selectScript(scriptId);
      return;
    }
    final runId = _runIdForScript(scriptId);
    var run = _repository.getRun(runId);
    if (run == null) {
      final now = DateTime.now().toUtc();
      final selectedScript = scripts.firstWhere(
        (script) => script.id == scriptId,
      );
      run = ReplicateRun(
        id: runId,
        videoId: selectedScript.sourceVideoId,
        scriptId: scriptId,
        globalStyle: _settingsController.value.replicateDefaultGlobalStyle,
        constraints: _settingsController.value.replicateDefaultConstraints,
        generationModel: _settingsController.value.imageGenerationModel,
        generationAspectRatio: _defaultAspectRatio(
          _settingsController.value.imageGenerationModel,
        ),
        generationImageSize: _defaultImageSize(
          _settingsController.value.imageGenerationModel,
        ),
        generationQuality: _defaultQuality(
          _settingsController.value.imageGenerationModel,
        ),
        currentStep: ReplicateStep.prepareAssets,
        status: ProcessingStatus.pending,
        confirmShotsStatus: ProcessingStatus.pending,
        prepareAssetsStatus: ProcessingStatus.pending,
        composePromptsStatus: ProcessingStatus.pending,
        completedCount: 0,
        totalCount: shooting.shots.length,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      );
      _repository.upsertRun(run);
    }
    if (run.currentStep == ReplicateStep.composePrompts) {
      run = run.copyWith(
        currentStep: ReplicateStep.confirmShots,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    if (_enforceFreeCreationMode && !run.freeCreationEnabled) {
      run = run.copyWith(
        freeCreationEnabled: true,
        composePromptsStatus: ProcessingStatus.pending,
        status: ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    final confirmedIds = [for (final shot in shooting.shots) shot.id];
    if (confirmedIds.length != run.confirmedShotIds.length ||
        !confirmedIds.every(run.confirmedShotIds.contains)) {
      run = run.copyWith(
        confirmedShotIds: confirmedIds,
        confirmShotsStatus: confirmedIds.isEmpty
            ? ProcessingStatus.pending
            : ProcessingStatus.completed,
        totalCount: shooting.shots.length,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    final assets = _repository.listAssets(run.id);
    final shotGuides = _repository.listShotGuidesForScript(scriptId);
    final replicatedImages = _restoreReplicatedImages(run.id);
    var prompts = _repository.listPrompts(run.id);
    final workflowAssetIdsByShot = _confirmedScriptAssetIdsByShot(
      scriptId,
      shooting.shots,
    );
    final normalizedRun = _normalizeReferenceCounts(run, assets);
    if (normalizedRun != run) {
      run = normalizedRun;
      _repository.upsertRun(run);
    }
    final hasWorkflowAssets = workflowAssetIdsByShot.isNotEmpty;
    final workflowPrepareStatus = hasWorkflowAssets
        ? ProcessingStatus.completed
        : (_hasReadyAssets(assets)
              ? ProcessingStatus.completed
              : ProcessingStatus.pending);
    if (run.prepareAssetsStatus != workflowPrepareStatus) {
      run = run.copyWith(
        prepareAssetsStatus: workflowPrepareStatus,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    if (prompts.isNotEmpty &&
        (run.status != ProcessingStatus.pending ||
            run.composePromptsStatus != ProcessingStatus.pending) &&
        _promptsAreStale(
          run: run,
          prompts: prompts,
          shots: shooting.shots,
          confirmedShotIds: confirmedIds,
          assets: assets,
          replicatedImages: replicatedImages,
          workflowAssetIdsByShot: workflowAssetIdsByShot,
        )) {
      run = run.copyWith(
        status: ProcessingStatus.pending,
        composePromptsStatus: ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    final isReplicating = _isReplicatingScript(scriptId);
    final isBuilding = isBuildActiveFor(scriptId);
    value = value.copyWith(
      scripts: scripts,
      shots: shooting.shots,
      selectedScriptId: scriptId,
      run: run,
      assets: assets,
      replicatedImages: replicatedImages,
      prompts: prompts,
      shotGuides: shotGuides,
      isBusy: isReplicating || isBuilding,
      isAnalyzingFrames: _isAnalyzingFrames(scriptId),
      message: isBuilding
          ? (_buildMessagesByScriptId[scriptId] ?? '')
          : isReplicating
          ? (_replicationMessagesByScriptId[scriptId] ?? '')
          : (_buildMessagesByScriptId[scriptId] ?? ''),
      errorMessage: _buildErrorsByScriptId[scriptId] ?? '',
    );
  }

  void _saveConfirmation(ReplicateRun run, Set<String> ids) {
    final ordered = [
      for (final shot in value.shots)
        if (ids.contains(shot.id)) shot.id,
    ];
    final hasConfirmed = ordered.isNotEmpty;
    final updated = run.copyWith(
      confirmedShotIds: ordered,
      confirmShotsStatus: hasConfirmed
          ? ProcessingStatus.completed
          : ProcessingStatus.pending,
      composePromptsStatus: value.prompts.isEmpty
          ? run.composePromptsStatus
          : ProcessingStatus.pending,
      status: value.prompts.isEmpty ? run.status : ProcessingStatus.pending,
      totalCount: ordered.length,
      updatedAt: DateTime.now().toUtc(),
    );
    _persistRun(
      updated,
      message: '已确认 ${ordered.length}/${value.shots.length} 个镜头',
    );
  }

  void _persistRun(
    ReplicateRun run, {
    String message = '',
    String errorMessage = '',
  }) {
    _repository.upsertRun(run);
    value = value.copyWith(
      run: run,
      message: message,
      errorMessage: errorMessage,
      isBusy: _isScriptBusy(value.selectedScriptId),
    );
  }

  void _refreshRunData({
    required ReplicateRun run,
    String message = '',
    String errorMessage = '',
    bool isBusy = false,
  }) {
    _repository.upsertRun(run);
    value = value.copyWith(
      run: run,
      assets: _repository.listAssets(run.id),
      replicatedImages: _repository.listReplicatedShotImages(run.id),
      prompts: _repository.listPrompts(run.id),
      isBusy: isBusy,
      message: message,
      errorMessage: errorMessage,
    );
  }

  ReplicateRun _runWithAssetStatus(
    ReplicateRun run,
    List<ReplicateAsset> assets,
  ) {
    final ready = _hasReadyAssets(assets);
    return run.copyWith(
      prepareAssetsStatus: ready
          ? ProcessingStatus.completed
          : ProcessingStatus.pending,
      composePromptsStatus: value.prompts.isEmpty
          ? run.composePromptsStatus
          : ProcessingStatus.pending,
      status: value.prompts.isEmpty ? run.status : ProcessingStatus.pending,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  ShotPrompt _composePrompt({
    required ReplicateRun run,
    required ScriptShot shot,
    required List<ReplicateAsset> assets,
    List<ScriptShot> actionSequence = const [],
    ScriptShot? previousShot,
    ScriptShot? nextShot,
    required ShotPromptFormat selectedFormat,
  }) {
    try {
      final promptShot = _structuredPromptShot(shot);
      final promptActionSequence = actionSequence
          .map(_structuredPromptShot)
          .toList(growable: false);
      final promptPreviousShot = previousShot == null
          ? null
          : _structuredPromptShot(previousShot);
      final promptNextShot = nextShot == null
          ? null
          : _structuredPromptShot(nextShot);
      final referenceShots = actionSequence.isEmpty
          ? <ScriptShot>[shot]
          : actionSequence;
      final linkedAssets = _confirmedScriptAssetsForShots(referenceShots);
      final result = linkedAssets.isNotEmpty
          ? _promptService.generateFromScriptAssets(
              shot: promptShot,
              assets: linkedAssets,
              globalStyle: run.globalStyle,
              constraints: run.constraints,
              previousShot: promptPreviousShot,
              nextShot: promptNextShot,
            )
          : _promptService.generate(
              shot: promptShot,
              assets: assets,
              globalStyle: run.globalStyle,
              constraints: run.constraints,
              previousShot: promptPreviousShot,
              nextShot: promptNextShot,
            );
      final klingPrompt = const KlingVideoPromptAdapter().adapt(
        promptShot,
        sourcePrompt: '',
        actionSequence: promptActionSequence,
        availableImageReferences: referenceShots.length,
        globalStyle: run.globalStyle,
        constraints: run.constraints,
      );
      final h3Prompt = const H3VideoPromptAdapter().adapt(
        promptShot,
        sourcePrompt: '',
        actionSequence: promptActionSequence,
        availableImageReferences: referenceShots.length,
        globalStyle: run.globalStyle,
        narrativeStyle: selectedFormat == ShotPromptFormat.h3
            ? selectedH3PromptStyle.videoPromptInstruction
            : '',
        constraints: run.constraints,
        referenceDefinitions: linkedAssets.isNotEmpty
            ? _h3ReferenceDefinitionsFromScriptAssets(
                linkedAssets,
                startImageNumber: referenceShots.length + 1,
              )
            : _h3ReferenceDefinitionsFromReplicateAssets(
                assets,
                startImageNumber: referenceShots.length + 1,
              ),
      );
      final selectedPrompt = switch (selectedFormat) {
        ShotPromptFormat.h3 => h3Prompt,
        ShotPromptFormat.kling => klingPrompt,
        ShotPromptFormat.sd2 => result.prompt,
      };
      return ShotPrompt(
        id: _promptId(run.id, shot.id),
        runId: run.id,
        shotNumber: shot.shotNumber,
        scriptShotId: shot.id,
        assetIds: result.assetIds,
        prompt: selectedPrompt,
        model: promptModel,
        rawResponse: jsonEncode({
          'warnings': result.warnings,
          'promptRulesVersion': _promptRulesVersion,
          'h3PromptStyleId': selectedFormat == ShotPromptFormat.h3
              ? selectedH3PromptStyle.id
              : H3PromptStyle.generalId,
          'shotFingerprint': _shotFingerprint(shot),
          'promptInputFingerprint': _promptInputFingerprint(
            run: run,
            shot: shot,
            assets: assets,
            actionSequence: actionSequence,
            previousShot: previousShot,
            nextShot: nextShot,
            selectedFormat: selectedFormat,
          ),
          'promptContextSchemaVersion':
              _workflowRepository
                  ?.getAnalysis(shot.id)
                  ?.promptContextSchemaVersion ??
              0,
          'promptSource': 'localStructuredAssembler',
          'assemblyMode': 'concatenateConfirmedScriptFields',
          'analysisStage': 'buildScript',
          'visionModelCalls': 0,
          'sd2Prompt': result.prompt,
          'klingPrompt': klingPrompt,
          'h3Prompt': h3Prompt,
          'selectedPromptFormat': selectedFormat.name,
          'videoModelPromptRule': {
            'format': selectedFormat.name,
            'label': _promptFormatLabel(selectedFormat),
          },
        }),
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      return ShotPrompt(
        id: _promptId(run.id, shot.id),
        runId: run.id,
        shotNumber: shot.shotNumber,
        scriptShotId: shot.id,
        assetIds: const [],
        prompt: '',
        model: promptModel,
        rawResponse: '',
        status: ProcessingStatus.failed,
        errorMessage: '$error',
        updatedAt: DateTime.now().toUtc(),
      );
    }
  }

  static String _promptFormatLabel(ShotPromptFormat format) => switch (format) {
    ShotPromptFormat.h3 => 'MiniMax H3',
    ShotPromptFormat.kling => '可灵',
    ShotPromptFormat.sd2 => '即梦',
  };

  ScriptShot _shotWithoutSourceVisualContent(ScriptShot shot) {
    String clean(String value) =>
        SeedancePromptGenerationService.stripSpecificWardrobeAndObjectDetails(
          value,
        );
    return shot.copyWith(
      visual: '',
      content: clean(shot.content),
      shotSize: clean(shot.shotSize),
      cameraMovement: clean(shot.cameraMovement),
      scene: clean(shot.scene),
      cameraNotes: clean(shot.cameraNotes),
      composition: clean(shot.composition),
      cameraAngle: clean(shot.cameraAngle),
      lightingMood: clean(shot.lightingMood),
      colorPalette: ScriptMultimodalAnalysisService.colorStyleFromPaletteText(
        shot.colorPalette,
      ),
      visualFocus: clean(shot.visualFocus),
      transitionHint: clean(shot.transitionHint),
      movementTrend: clean(shot.movementTrend),
      actionStage: clean(shot.actionStage),
      productCode: '',
      productStyling: '',
      sound: clean(shot.sound),
    );
  }

  void _updatePromptProgress(
    ReplicateRun run,
    List<ShotPrompt> prompts, {
    required String message,
  }) {
    final completed = prompts
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    final failed = prompts
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    final updatedRun = run.copyWith(
      completedCount: completed,
      totalCount: prompts.length,
      status: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      composePromptsStatus: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      errorMessage: failed == 0 ? '' : '$failed 个提示词生成失败',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(updatedRun);
    value = value.copyWith(
      run: updatedRun,
      prompts: prompts,
      message: message,
      errorMessage: updatedRun.errorMessage,
    );
  }

  void _syncScriptPromptFields(String scriptId, List<ShotPrompt> prompts) {
    final promptsByShotId = <String, String>{
      for (final prompt in prompts)
        if ((prompt.scriptShotId ?? '').isNotEmpty &&
            prompt.status == ProcessingStatus.completed &&
            prompt.prompt.trim().isNotEmpty)
          prompt.scriptShotId!: prompt.prompt,
    };
    _shootingScriptController.updateGeneratedFieldsForScript(
      scriptId: scriptId,
      promptsByShotId: promptsByShotId,
    );
  }

  List<ScriptShot> _actionSequenceForPrompt(
    ScriptShot shot,
    List<VideoActionSequence> sequences,
  ) {
    if (sequences.isEmpty) return const [];
    for (final sequence in sequences) {
      if (sequence.contains(shot.id)) return sequence.shots;
    }
    return const [];
  }

  ReplicateAsset? _assetById(String id) {
    for (final asset in value.assets) {
      if (asset.id == id) {
        return asset;
      }
    }
    return null;
  }

  ScriptShot? _shotById(String id) {
    for (final shot in value.shots) {
      if (shot.id == id) {
        return shot;
      }
    }
    return null;
  }

  ReplicateShotGuide? _currentShotGuide(ScriptShot shot) {
    final guide = _repository.getShotGuide(shot.id);
    if (guide == null ||
        guide.sourceFrameFingerprint != _sourceFrameFingerprint(shot)) {
      return null;
    }
    return guide;
  }

  String _sourceFrameFingerprint(ScriptShot shot) {
    final path = shot.framePath.trim();
    if (path.isEmpty) return '';
    final file = File(path);
    if (!file.existsSync()) return 'missing:${p.normalize(path)}';
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  ReplicatedShotImage? _replicatedImageForShot(String shotId) {
    for (final image in value.replicatedImages) {
      if (image.scriptShotId == shotId) return image;
    }
    return null;
  }

  String _replicatedImageError(String runId, String shotId) {
    for (final image in _repository.listReplicatedShotImages(runId)) {
      if (image.scriptShotId == shotId) return image.errorMessage;
    }
    return '';
  }

  void _saveReplicatedImage(ReplicatedShotImage image) {
    _repository.upsertReplicatedShotImage(image);
    if (_disposed) return;
    if (value.run?.id != image.runId) {
      return;
    }
    value = value.copyWith(
      replicatedImages: _repository.listReplicatedShotImages(image.runId),
    );
  }

  List<ReplicatedShotImage> _restoreReplicatedImages(String runId) {
    final migratedIds = <String>{};
    ReplicatedShotImage completeLegacyReviewRecord(ReplicatedShotImage image) {
      if (image.generationRecovery.isEmpty ||
          image.generatedFramePath.trim().isEmpty ||
          !File(image.generatedFramePath.trim()).existsSync()) {
        return image;
      }
      migratedIds.add(image.id);
      return image.copyWith(
        generationRecovery: ReplicatedShotGenerationRecovery.empty,
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
      );
    }

    final images = [
      for (final image in _repository.listReplicatedShotImages(runId))
        completeLegacyReviewRecord(image),
    ];
    for (final image in images) {
      if (migratedIds.contains(image.id)) {
        _repository.upsertReplicatedShotImage(image);
      }
    }
    final missingBasenames = <String>{
      for (final image in images)
        if (image.generatedFramePath.trim().isNotEmpty &&
            !File(image.generatedFramePath.trim()).existsSync())
          p.basename(image.generatedFramePath.trim()),
    }..removeWhere((basename) => basename.isEmpty);
    if (missingBasenames.isEmpty) return images;
    final generatedRoot = _directories.generatedImages;
    if (!generatedRoot.existsSync()) {
      return images;
    }
    _replicatedImageRecoveryScanCount++;
    final filesByName = <String, File>{};
    for (final entity in generatedRoot.listSync(recursive: true)) {
      if (entity is! File) continue;
      final basename = p.basename(entity.path);
      if (missingBasenames.contains(basename)) filesByName[basename] = entity;
    }
    final restored = <ReplicatedShotImage>[];
    for (final image in images) {
      final currentPath = image.generatedFramePath.trim();
      if (currentPath.isNotEmpty && File(currentPath).existsSync()) {
        restored.add(image);
        continue;
      }
      final basename = currentPath.isEmpty ? '' : p.basename(currentPath);
      final recovered = basename.isEmpty ? null : filesByName[basename];
      if (recovered == null) {
        restored.add(image);
        continue;
      }
      final updated = image.copyWith(
        generatedFramePath: recovered.path,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertReplicatedShotImage(updated);
      restored.add(updated);
    }
    return restored;
  }

  List<_ReplacementReference> _replacementReferences(
    String shotId, {
    String? scriptId,
    List<ReplicateAsset>? stepAssets,
    String? fallbackShotId,
  }) {
    if (_workflowRepository != null) {
      final references = _replacementReferencesFromScriptBindings(
        shotId,
        scriptId: scriptId,
      );
      if (references.isNotEmpty || fallbackShotId == null) {
        return references;
      }
      return _replacementReferences(
        fallbackShotId,
        scriptId: scriptId,
        stepAssets: stepAssets,
      );
    }
    return [
      for (final asset in _readyAssets(stepAssets ?? value.assets))
        if (_mediaKindForType(asset.type) == ReplicateMediaKind.image &&
            asset.path.trim().isNotEmpty &&
            File(asset.path).existsSync())
          _ReplacementReference(
            id: asset.id,
            type: asset.type,
            name: asset.name,
            description: asset.description,
            path: asset.path,
            slotLabel: '',
          ),
    ];
  }

  Future<List<_ReplacementReference>> _prepareSelectedAssetViews({
    required ScriptShot shot,
    required ReplicateRun run,
    required File original,
    required List<_ReplacementReference> references,
    required int maximumReferenceCount,
  }) async {
    if (!run.multiViewEnhancementEnabled ||
        references.isEmpty ||
        maximumReferenceCount <= references.length) {
      return references;
    }
    final outputDirectory = Directory(
      p.join(
        _directories.analyses.path,
        'replicate_asset_views',
        _safeFileName(run.id),
        _safeFileName(shot.id),
      ),
    );
    final result = <_ReplacementReference>[];
    for (var index = 0; index < references.length; index++) {
      final reference = references[index];
      final remainingAssets = references.length - index - 1;
      final remainingBudget = maximumReferenceCount - result.length;
      final maximumOutputCount = math.min(
        3,
        math.max(1, remainingBudget - remainingAssets),
      );
      if (maximumOutputCount <= 1 ||
          !const {
            ReplicateAssetType.character,
            ReplicateAssetType.product,
          }.contains(reference.type)) {
        result.add(reference);
        continue;
      }
      try {
        if (!_disposed) {
          _setReplicationMessage(
            run.scriptId ?? value.selectedScriptId,
            '正在为镜头 ${shot.shotNumber} 分析“${reference.name}”的多视图并选择最佳裁切…',
          );
        }
        final prepared = await _assetViewSelectionService.prepare(
          settings: _settingsController.value,
          originalFrame: original,
          assetImage: File(reference.path),
          outputDirectory: outputDirectory,
          shotNumber: shot.shotNumber,
          assetId: reference.id,
          assetName: reference.name,
          assetType: reference.type,
          slotLabel: reference.slotLabel,
          maximumOutputCount: maximumOutputCount,
        );
        for (var viewIndex = 0; viewIndex < prepared.length; viewIndex++) {
          final view = prepared[viewIndex];
          result.add(
            _ReplacementReference(
              id: viewIndex == 0
                  ? reference.id
                  : '${reference.id}:view:$viewIndex',
              type: reference.type,
              name: reference.name,
              description: [
                reference.description,
                if (view.description.isNotEmpty)
                  view.isDetail
                      ? '视觉模型选择的局部细节：${view.description}'
                      : '视觉模型选择的镜头匹配主视图：${view.description}',
              ].where((value) => value.trim().isNotEmpty).join('；'),
              path: view.path,
              slotLabel: reference.slotLabel,
              isDetailCrop: view.isDetail,
            ),
          );
        }
      } catch (_) {
        result.add(reference);
      }
    }
    return result;
  }

  List<_ReplacementReference> _referencesForSubjectDecisions(
    List<_ReplacementReference> references,
    ReplicateShotGuide? guide,
  ) {
    if (guide == null || guide.subjects.isEmpty) return references;
    final decisions = {
      for (final subject in guide.subjects)
        (subject.type, subject.slotIndex): subject.decision,
    };
    final hasReplacingProduct = guide.subjects.any(
      (subject) =>
          subject.type == ReplicateSubjectType.product &&
          subject.decision == ReplicateSubjectDecision.replace,
    );
    final result = <_ReplacementReference>[];
    for (final reference in references) {
      var include = true;
      final characterIndex = _characterSlotIndex(reference.slotLabel);
      if (characterIndex != null) {
        final decision =
            decisions[(ReplicateSubjectType.person, characterIndex)];
        include =
            decision == null || decision == ReplicateSubjectDecision.replace;
      } else {
        final productIndex = _productSlotIndex(reference.slotLabel);
        if (productIndex != null) {
          final decision =
              decisions[(ReplicateSubjectType.product, productIndex)];
          include =
              decision == null || decision == ReplicateSubjectDecision.replace;
        } else {
          final productDetailIndex = _productDetailSlotIndex(
            reference.slotLabel,
          );
          if (productDetailIndex != null) {
            final decision =
                decisions[(ReplicateSubjectType.product, productDetailIndex)];
            include = decision == null
                ? hasReplacingProduct
                : decision == ReplicateSubjectDecision.replace;
          }
        }
      }
      if (include) result.add(reference);
    }
    return result;
  }

  static NanoBananaAssetManifest _nanoBananaAssetManifest({
    required ScriptShot shot,
    required File original,
    required List<_ReplacementReference> references,
  }) {
    final modelAssets = <NanoBananaAssetInput>[];
    final productAssets = <NanoBananaAssetInput>[];
    final productDetailAssets = <NanoBananaAssetInput>[];
    final sceneAssets = <NanoBananaAssetInput>[];
    final modelSlotByAssetId = <String, int>{};
    final productSlotByAssetId = <String, int>{};
    var nextModelSlot = 0;
    var nextProductSlot = 0;

    for (final reference in references) {
      final characterSlot = _characterSlotIndex(reference.slotLabel);
      final productSlot = _productSlotIndex(reference.slotLabel);
      final detailSlot = _productDetailSlotIndex(reference.slotLabel);
      if (characterSlot != null) {
        nextModelSlot = math.max(nextModelSlot, characterSlot + 1);
      }
      if (productSlot != null) {
        nextProductSlot = math.max(nextProductSlot, productSlot + 1);
      }
      if (detailSlot != null) {
        nextProductSlot = math.max(nextProductSlot, detailSlot + 1);
      }
    }

    for (final reference in references) {
      final assetId = _logicalReferenceAssetId(reference.id);
      final viewOrder = _referenceViewOrder(reference.id);
      final characterSlot = _characterSlotIndex(reference.slotLabel);
      final productSlot = _productSlotIndex(reference.slotLabel);
      final detailSlot = _productDetailSlotIndex(reference.slotLabel);
      if (reference.type == ReplicateAssetType.character) {
        final slot =
            characterSlot ??
            modelSlotByAssetId.putIfAbsent(assetId, () => nextModelSlot++);
        modelAssets.add(
          NanoBananaAssetInput.model(
            assetId: assetId,
            path: reference.path,
            slotIndex: slot,
            viewOrder: viewOrder,
          ),
        );
        continue;
      }
      if (reference.type == ReplicateAssetType.scene) {
        sceneAssets.add(
          NanoBananaAssetInput.scene(
            assetId: assetId,
            path: reference.path,
            viewOrder: viewOrder,
          ),
        );
        continue;
      }
      if (detailSlot != null) {
        productDetailAssets.add(
          NanoBananaAssetInput.productDetail(
            assetId: assetId,
            path: reference.path,
            productSlotIndex: detailSlot,
            viewOrder: viewOrder,
          ),
        );
        continue;
      }
      final slot =
          productSlot ??
          productSlotByAssetId.putIfAbsent(assetId, () => nextProductSlot++);
      productAssets.add(
        NanoBananaAssetInput.product(
          assetId: assetId,
          path: reference.path,
          slotIndex: slot,
          viewOrder: viewOrder,
        ),
      );
    }

    return NanoBananaAssetManifest.build(
      sourceFrameId: '${shot.id}:source-frame',
      sourceFramePath: original.path,
      modelAssets: modelAssets,
      productAssets: productAssets,
      productDetailAssets: productDetailAssets,
      sceneAssets: sceneAssets,
    );
  }

  static List<_ReplacementReference> _referencesInNanoBananaManifestOrder({
    required ScriptShot shot,
    required File original,
    required List<_ReplacementReference> references,
  }) {
    if (references.length < 2) return references;
    final manifest = _nanoBananaAssetManifest(
      shot: shot,
      original: original,
      references: references,
    );
    final remaining = [...references];
    final ordered = <_ReplacementReference>[];
    for (final entry in manifest.entries.skip(1)) {
      final index = remaining.indexWhere(
        (reference) =>
            _logicalReferenceAssetId(reference.id) == entry.assetId &&
            reference.path == entry.path,
      );
      if (index < 0) {
        throw StateError('Nano Banana Pro 资产清单无法映射图片${entry.imageNumber}');
      }
      ordered.add(remaining.removeAt(index));
    }
    if (remaining.isNotEmpty) {
      throw StateError('Nano Banana Pro 资产清单遗漏 ${remaining.length} 张参考图');
    }
    return ordered;
  }

  static String _logicalReferenceAssetId(String id) =>
      id.replaceFirst(RegExp(r':view:\d+$'), '');

  static int _referenceViewOrder(String id) =>
      int.tryParse(RegExp(r':view:(\d+)$').firstMatch(id)?.group(1) ?? '') ?? 0;

  String? _replicationInputReadinessError({
    required ScriptShot shot,
    required ReplicateShotGuide? guide,
    required List<_ReplacementReference> references,
  }) {
    if (guide == null ||
        guide.sourceFrameFingerprint != _sourceFrameFingerprint(shot) ||
        guide.analysisStatus != ProcessingStatus.completed) {
      return '请先分析镜头 ${shot.shotNumber} 的原帧，再确认每个可见人物和产品的处理方式';
    }
    if (guide.undecidedSubjects.isNotEmpty) {
      final labels = guide.undecidedSubjects
          .map((subject) => subject.label)
          .join('、');
      return '请先为以下原帧主体选择“保留、替换或移除”：$labels';
    }
    for (final subject in guide.subjects) {
      if (subject.decision != ReplicateSubjectDecision.replace) continue;
      final hasReplacement = references.any((reference) {
        return switch (subject.type) {
          ReplicateSubjectType.person =>
            _characterSlotIndex(reference.slotLabel) == subject.slotIndex,
          ReplicateSubjectType.product =>
            _productSlotIndex(reference.slotLabel) == subject.slotIndex,
        };
      });
      if (!hasReplacement) {
        final subjectCount = guide.subjects
            .where((candidate) => candidate.type == subject.type)
            .length;
        final prefix = subject.type == ReplicateSubjectType.person
            ? '模特'
            : '产品';
        final slotLabel = subjectCount <= 1 && subject.slotIndex == 0
            ? prefix
            : '$prefix${ScriptAssetSlotPolicy.characterSuffix(subject.slotIndex)}';
        return '${subject.label} 已选择“替换”，请先为$slotLabel绑定对应资产';
      }
    }
    return null;
  }

  List<_ReplacementReference> _replacementReferencesFromScriptBindings(
    String shotId, {
    String? scriptId,
  }) {
    final repository = _workflowRepository;
    final selectedScriptId = scriptId ?? value.selectedScriptId;
    if (repository == null || selectedScriptId.isEmpty) return const [];
    final assetsById = {
      for (final asset in repository.listScriptAssets(selectedScriptId))
        asset.id: asset,
    };
    final bindings = <({ScriptShotAssetLink link, ScriptAsset asset})>[];
    for (final link in repository.listLinksForShot(shotId)) {
      final asset = assetsById[link.scriptAssetId];
      if (!link.confirmed ||
          asset == null ||
          _mediaKindForType(asset.type) != ReplicateMediaKind.image ||
          asset.path.trim().isEmpty ||
          !File(asset.path).existsSync()) {
        continue;
      }
      bindings.add((link: link, asset: asset));
    }
    if (bindings.isEmpty) return const [];

    final characterBindings = [
      for (final binding in bindings)
        if (binding.asset.type == ReplicateAssetType.character) binding,
    ];
    final participantCount = math.max(
      characterBindings.length,
      bindings.fold<int>(0, (count, binding) {
        final slot = ScriptAssetSlotPolicy.presetSlotForSortOrder(
          binding.link.sortOrder,
        );
        return switch (slot?.kind) {
          ScriptAssetPresetSlotKind.character => math.max(
            count,
            slot!.characterIndex + 1,
          ),
          ScriptAssetPresetSlotKind.product => math.max(
            count,
            slot!.productIndex + 1,
          ),
          ScriptAssetPresetSlotKind.productDetail => math.max(
            count,
            slot!.productIndex + 1,
          ),
          _ => count,
        };
      }),
    );
    final presetSlots = <ScriptAssetPresetSlot>[
      for (var index = 0; index < participantCount; index++) ...[
        ScriptAssetPresetSlot.character(index),
        ScriptAssetPresetSlot.product(index),
        ScriptAssetPresetSlot.productDetail(index),
      ],
      const ScriptAssetPresetSlot.scene(),
    ];
    final assignments =
        <String, ({ScriptShotAssetLink link, ScriptAsset asset})>{};
    final remainingBindings = [...bindings];
    for (final binding in bindings) {
      final slot = ScriptAssetSlotPolicy.presetSlotForSortOrder(
        binding.link.sortOrder,
      );
      if (slot == null ||
          !presetSlots.any((candidate) => candidate.key == slot.key) ||
          !slot.acceptsAsset(
            type: binding.asset.type,
            name: binding.asset.name,
            description: binding.asset.description,
          ) ||
          assignments.containsKey(slot.key)) {
        continue;
      }
      assignments[slot.key] = binding;
      remainingBindings.remove(binding);
    }
    for (final binding in [...remainingBindings]) {
      ScriptAssetPresetSlot? target;
      if (binding.asset.type == ReplicateAssetType.character) {
        target = presetSlots
            .where((slot) => slot.kind == ScriptAssetPresetSlotKind.character)
            .where((slot) => !assignments.containsKey(slot.key))
            .firstOrNull;
      } else if (binding.asset.type == ReplicateAssetType.product) {
        target = presetSlots
            .where(
              (slot) =>
                  slot.kind == ScriptAssetPresetSlotKind.product ||
                  slot.kind == ScriptAssetPresetSlotKind.productDetail,
            )
            .where((slot) => !assignments.containsKey(slot.key))
            .firstOrNull;
      } else if (binding.asset.type == ReplicateAssetType.scene) {
        target = presetSlots
            .where((slot) => slot.kind == ScriptAssetPresetSlotKind.scene)
            .where((slot) => !assignments.containsKey(slot.key))
            .firstOrNull;
      }
      if (target == null) continue;
      assignments[target.key] = binding;
      remainingBindings.remove(binding);
    }
    final usedAssetIds = <String>{};
    final references = <_ReplacementReference>[];

    void addBinding(
      ({ScriptShotAssetLink link, ScriptAsset asset}) binding,
      String slotLabel,
    ) {
      if (!usedAssetIds.add(binding.asset.id)) return;
      references.add(
        _ReplacementReference(
          id: binding.asset.id,
          type: binding.asset.type,
          name: binding.asset.name,
          description: binding.asset.description,
          path: binding.asset.path,
          slotLabel: slotLabel,
        ),
      );
    }

    for (final slot in presetSlots) {
      final binding = assignments[slot.key];
      if (binding == null) continue;
      addBinding(binding, slot.label(characterCount: participantCount));
    }

    for (final binding in remainingBindings) {
      addBinding(binding, '');
    }
    return references;
  }

  String _replacementPrompt(
    ScriptShot shot,
    List<_ReplacementReference> references, {
    VisionImageAnalysis? analysis,
    ReplicateShotGuide? guide,
    bool hasPoseSkeleton = false,
  }) {
    final definitions = <String>[];
    final assetRequirements = <String>[];
    final characterSlotLabelsByIndex = <int, String>{};
    final productSlotLabelsByIndex = <int, String>{};
    final characterImageBySlot = <int, String>{};
    final productImageBySlot = <int, String>{};
    for (final reference in references) {
      final characterIndex = _characterSlotIndex(reference.slotLabel);
      if (characterIndex != null) {
        characterSlotLabelsByIndex[characterIndex] = reference.slotLabel;
      }
      final productIndex = _productSlotIndex(reference.slotLabel);
      if (productIndex != null) {
        productSlotLabelsByIndex[productIndex] = reference.slotLabel;
      }
    }
    final characterSlotLabels = characterSlotLabelsByIndex.values.toList(
      growable: false,
    );
    final pairedSlotIndices =
        characterSlotLabelsByIndex.keys
            .where(productSlotLabelsByIndex.containsKey)
            .toList(growable: false)
          ..sort();
    final assetStartNumber = hasPoseSkeleton ? 3 : 2;
    for (var index = 0; index < references.length; index++) {
      final reference = references[index];
      final imageLabel = '图片${index + assetStartNumber}';
      final description = reference.description.trim().isEmpty
          ? ''
          : '，特征：${reference.description.trim()}';
      final roleLabel = reference.slotLabel.isNotEmpty
          ? reference.isDetailCrop
                ? '${reference.slotLabel}局部细节裁切'
                : _productDetailSlotIndex(reference.slotLabel) != null
                ? '产品细节参考'
                : '${reference.slotLabel}参考'
          : _replacementTypeLabel(reference.type);
      final characterSlotIndex = _characterSlotIndex(reference.slotLabel);
      final productSlotIndex = _productSlotIndex(reference.slotLabel);
      final productDetailSlotIndex = _productDetailSlotIndex(
        reference.slotLabel,
      );
      final pairedProductLabel = characterSlotIndex == null
          ? null
          : productSlotLabelsByIndex[characterSlotIndex];
      final pairedCharacterLabel = productSlotIndex == null
          ? null
          : characterSlotLabelsByIndex[productSlotIndex];
      if (!reference.isDetailCrop && characterSlotIndex != null) {
        characterImageBySlot.putIfAbsent(characterSlotIndex, () => imageLabel);
      }
      if (!reference.isDetailCrop && productSlotIndex != null) {
        productImageBySlot.putIfAbsent(productSlotIndex, () => imageLabel);
      }
      definitions.add(
        '$imageLabel 是$roleLabel“${reference.name}”$description。',
      );
      if (reference.isDetailCrop) {
        assetRequirements.add(
          '$imageLabel 是视觉模型根据当前镜头选择的局部细节裁切，只用于补充“${reference.name}”在主视图中不可见的结构、接缝、边缘、材质或五官；'
          '不得把局部裁切误当成完整主体，不得改变对应${reference.slotLabel.isEmpty ? '资产' : reference.slotLabel}主视图定义的整体轮廓、比例和朝向。',
        );
        continue;
      }
      assetRequirements.add(switch ((reference.type, reference.slotLabel)) {
        (_, _) when productDetailSlotIndex != null =>
          '$imageLabel 只补充“${reference.name}”的局部结构、接缝、边缘、材质和纹理；不得替代${productSlotLabelsByIndex[productDetailSlotIndex] ?? '对应产品主视图'}定义的整体外形与比例。',
        (_, final slotLabel)
            when characterSlotIndex != null && pairedProductLabel != null =>
          '$slotLabel 使用$imageLabel 的身份、脸部、发型和体型，对应图片1从左到右第${characterSlotIndex + 1}个人物槽位；身份不得与其他槽位交换。'
              '服装、鞋帽和配饰以$pairedProductLabel为准：可穿戴商品须完整穿着，非穿戴商品保持图片1的持拿或展示关系。',
        (_, final slotLabel) when characterSlotIndex != null =>
          '$slotLabel 使用$imageLabel 的身份、脸部、发型、体型和穿搭，对应图片1从左到右第${characterSlotIndex + 1}个人物槽位；不得继承原人物外观或与其他槽位交换。',
        (ReplicateAssetType.character, _) =>
          '人物使用$imageLabel 中“${reference.name}”的身份、脸部、发型、体型和穿搭；图片1只提供姿态与空间关系。',
        (ReplicateAssetType.product, final slotLabel)
            when productSlotIndex != null && pairedCharacterLabel != null =>
          '$slotLabel 使用$imageLabel 中“${reference.name}”的整体轮廓、比例、结构、接缝、边缘、纹理、材质和反光；'
              '$pairedCharacterLabel与$slotLabel一一绑定，可穿戴商品须完整穿着，手持商品保持图片1的接触关系。不得使用原产品外观、交叉分配或生成品牌文字。',
        (ReplicateAssetType.product, _) =>
          '产品使用$imageLabel 中“${reference.name}”的整体轮廓、比例、结构、接缝、边缘、纹理、材质和反光；图片1只提供位置、朝向和接触关系，不得继承原产品外观或品牌文字。',
        (ReplicateAssetType.scene, _) =>
          '场景使用$imageLabel 中“${reference.name}”的环境元素，并服从图片1的镜位、透视和主体位置。',
        (ReplicateAssetType.prop, _) =>
          '道具使用$imageLabel 中“${reference.name}”的外观，并保持图片1的尺寸、朝向和交互关系。',
        _ => '将$imageLabel 中“${reference.name}”作为新分镜的指定视觉元素使用。',
      });
    }
    final selectedElements = guide?.selectedElements ?? const [];
    final unselectedElements = guide?.unselectedElements ?? const [];
    final preservedElementRules = [
      for (final element in selectedElements)
        '${element.label}${element.description.trim().isEmpty ? '' : '（${element.description.trim()}）'}'
            '${element.location.trim().isEmpty ? '' : '，位置：${element.location.trim()}'}'
            '${element.relationship.trim().isEmpty ? '' : '，关系：${element.relationship.trim()}'}',
    ];
    final removedElementRules = [
      for (final element in unselectedElements)
        '${element.label}${element.description.trim().isEmpty ? '' : '（${element.description.trim()}）'}'
            '${element.location.trim().isEmpty ? '' : '，原位置：${element.location.trim()}'}'
            '${element.relationship.trim().isEmpty ? '' : '，原关系：${element.relationship.trim()}'}',
    ];
    final firstBoundImageLabel = '图片$assetStartNumber';
    final subjectDecisionRules = <String>[
      for (final subject
          in guide?.subjects ?? const <ReplicateDetectedSubject>[])
        switch (subject.decision) {
          ReplicateSubjectDecision.replace =>
            '${subject.label}（${subject.type == ReplicateSubjectType.person ? '人物' : '产品'}槽位${subject.slotIndex + 1}）：替换。'
                '保留图片1中的位置、尺度、朝向、动作、接触和遮挡关系，但禁止继承其身份或外观；'
                '外观只使用${subject.type == ReplicateSubjectType.person ? characterImageBySlot[subject.slotIndex] ?? '对应模特资产' : productImageBySlot[subject.slotIndex] ?? '对应产品资产'}。',
          ReplicateSubjectDecision.keep =>
            '${subject.label}（${subject.type == ReplicateSubjectType.person ? '人物' : '产品'}槽位${subject.slotIndex + 1}）：保留。'
                '${subject.type == ReplicateSubjectType.person ? '完整沿用图片1中该人物的身份、脸部、发型、体型、服装、配饰与可见外观' : '完整沿用图片1中该产品或服装的轮廓、结构、颜色、材质、细节与穿着/接触关系'}；不得使用绑定资产覆盖、混合或重绘该主体。',
          ReplicateSubjectDecision.remove =>
            '${subject.label}（${subject.type == ReplicateSubjectType.person ? '人物' : '产品'}槽位${subject.slotIndex + 1}）：移除。'
                '成图不得出现该主体或残影，并按周围透视、纹理与光影自然补全被遮挡区域。',
          ReplicateSubjectDecision.undecided => '',
        },
    ]..removeWhere((rule) => rule.isEmpty);
    return [
      '任务：生成镜头 ${shot.shotNumber} 的受控复刻分镜。',
      '图片1是原视频镜头的编辑底图与结构参考：锁定画幅、景别、机位、构图、透视、主体槽位、姿态、接触和遮挡。只有下方处理计划明确标记“保留”的主体，才允许继续使用图片1中的身份、服装或产品外观；替换与移除项不得继承对应原主体外观。',
      if (hasPoseSkeleton)
        '图片2是 DWPose 姿势骨架，只定义关节位置、肢体方向、身体重心和动作轮廓；不得从骨架的颜色、线条或背景推断任何外观。',
      ...definitions,
      if (subjectDecisionRules.isNotEmpty)
        '【原帧主体处理计划】每项必须独立执行，不得用模型自行判断覆盖：\n${subjectDecisionRules.join('\n')}',
      if (characterSlotLabels.length > 1)
        '多模特身份与位置绑定硬约束：按图片1人物中心点从左到右对应模特A、模特B……；${characterSlotLabels.join('、')}不得合并、互换位置或交叉套用身份。',
      if (pairedSlotIndices.length > 1)
        '多模特产品一一绑定硬约束：${pairedSlotIndices.map((index) => '${characterSlotLabelsByIndex[index]}→${productSlotLabelsByIndex[index]}').join('、')}；不得交叉套用、互换、串穿或混搭。',
      ...assetRequirements,
      '绑定资产硬约束：$firstBoundImageLabel 起的图片按上文角色使用。主视图定义完整身份或产品整体；标记为局部细节裁切的图片只补充局部证据。不得遗漏、平均融合或用图片1中的同类原主体替代。',
      if (preservedElementRules.isNotEmpty)
        '【用户已勾选保留元素】从图片1保留其结构、材质、位置和佩戴/接触关系：${preservedElementRules.join('；')}。',
      if (removedElementRules.isNotEmpty)
        '【未勾选元素：必须移除】以下原帧配饰或道具未获授权，成图不得出现本体、残影或可识别特征：${removedElementRules.join('；')}。逐项移除后，必须按周围透视、纹理、材质、遮挡关系和光影自然补全暴露区域，不得用相似物替代。',
      if (guide != null && guide.actionDescription.trim().isNotEmpty)
        '【原帧精确动作硬约束】${guide.actionDescription.trim()}。',
      if (guide != null && guide.poseConstraints.trim().isNotEmpty)
        '【逐关节姿态硬约束】${guide.poseConstraints.trim()}。',
      '构图执行：保持图片1的画幅、机位、透视、槽位位置、空间方向、视线、动作、接触和遮挡；仅按主体处理计划改变实体。屏幕左/右以查看图片1时为准，严禁镜像。',
      '调色执行：新实体必须融入图片1的光线方向、色温、曝光、阴影、高光和景深；资产图自身背景、构图、光照与调色不进入成图。',
      '质量执行：产品轮廓、比例、接缝、口袋、边缘、材质和反光应可辨；人物面部、手指与手物接触自然；不得出现新旧身份或产品特征融合、重复主体、残影和低清纹理。',
      _textAndLogoExclusionConstraint,
      ..._shotStructureInstructions(shot),
      if (analysis != null) ..._visualStructureInstructions(analysis),
      '最终交付：一张自然真实、专业清晰、严格执行主体处理计划的复刻分镜图。',
    ].join('\n');
  }

  List<String> _shotStructureInstructions(ScriptShot shot) => [
    _visionInstruction('景别', shot.shotSize),
    _visionInstruction('构图', shot.composition),
    _visionInstruction('机位', shot.cameraAngle),
    _visionInstruction('运镜', shot.cameraMovement),
    _visionInstruction('光影与氛围', shot.lightingMood),
    _visionInstruction('剪辑衔接', shot.transitionHint),
    _visionInstruction('摄影备注', shot.cameraNotes),
  ].where((instruction) => instruction.isNotEmpty).toList(growable: false);

  List<String> _visualStructureInstructions(VisionImageAnalysis analysis) => [
    '【视觉模型对原帧的结构维度解析】以下内容只用于锁定镜头语言、空间关系和运动趋势；主体外观是否沿用只服从“原帧主体处理计划”，不得根据解析文字额外恢复原人物服装、产品款式、道具外观或品牌包装。',
    _visionInstruction(
      '镜头与构图',
      _joinVisionValues([
        analysis.shotSize,
        analysis.cameraAngle,
        analysis.cameraMovement,
        analysis.composition,
      ]),
    ),
    _visionInstruction(
      '朝向、视线与遮挡关系',
      _joinVisionValues([
        analysis.subjectDirection,
        analysis.gazeDirection,
        analysis.spatialRelation,
      ]),
    ),
    _visionInstruction(
      '动作阶段与运动趋势',
      _joinVisionValues([analysis.actionStage, analysis.movementTrend]),
    ),
    _visionInstruction('光影（色彩以图片1实际画面为准）', analysis.lightingMood),
    _visionInstruction(
      '叙事时刻与镜头承接',
      _joinVisionValues([
        analysis.narrativeFunction,
        analysis.chronologyCue,
        analysis.transitionHint,
      ]),
    ),
  ].where((instruction) => instruction.isNotEmpty).toList(growable: false);

  static String _visionInstruction(String label, String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? '' : '$label：$normalized。';
  }

  static String _joinVisionValues(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .join('；');

  static String _replacementTypeLabel(ReplicateAssetType type) =>
      switch (type) {
        ReplicateAssetType.character => '人物参考',
        ReplicateAssetType.product => '产品参考',
        ReplicateAssetType.scene => '场景参考',
        ReplicateAssetType.prop => '道具参考',
        _ => '视觉参考',
      };

  static int? _characterSlotIndex(String label) {
    if (label == '模特') return 0;
    final match = RegExp(r'^模特([A-Z]+)$').firstMatch(label);
    if (match == null) return null;
    var value = 0;
    for (final codeUnit in match.group(1)!.codeUnits) {
      value = value * 26 + codeUnit - 64;
    }
    return value - 1;
  }

  static int? _productSlotIndex(String label) {
    if (label == '产品') return 0;
    final match = RegExp(r'^产品([A-Z]+)$').firstMatch(label);
    if (match == null) return null;
    var value = 0;
    for (final codeUnit in match.group(1)!.codeUnits) {
      value = value * 26 + codeUnit - 64;
    }
    return value - 1;
  }

  static int? _productDetailSlotIndex(String label) {
    if (label == '产品细节') return 0;
    final match = RegExp(r'^产品细节([A-Z]+)$').firstMatch(label);
    if (match == null) return null;
    var value = 0;
    for (final codeUnit in match.group(1)!.codeUnits) {
      value = value * 26 + codeUnit - 64;
    }
    return value - 1;
  }

  String _resolvedGenerationModel(ReplicateRun run) {
    final configured = run.generationModel.trim();
    return configured.isEmpty
        ? _settingsController.value.imageGenerationModel
        : configured;
  }

  static String _defaultAspectRatio(String model) {
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    if (descriptor == null || descriptor.aspectRatios.isEmpty) return '16:9';
    return _catalogOption(
      descriptor.aspectRatios.contains('16:9') ? '16:9' : '',
      descriptor.aspectRatios,
      preferred: '16:9',
    );
  }

  static String _closestSupportedSourceAspectRatio(
    File source,
    List<String> supported, {
    required String fallback,
  }) {
    try {
      final decoded = img.decodeImage(source.readAsBytesSync());
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        throw const FormatException('无法读取原帧尺寸');
      }
      final sourceRatio = decoded.width / decoded.height;
      String? best;
      var bestDistance = double.infinity;
      for (final option in supported) {
        final parts = option.split(':');
        if (parts.length != 2) continue;
        final width = double.tryParse(parts.first);
        final height = double.tryParse(parts.last);
        if (width == null || height == null || width <= 0 || height <= 0) {
          continue;
        }
        final distance = (math.log(sourceRatio / (width / height))).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = option;
        }
      }
      if (best != null) return best;
    } catch (_) {
      // 损坏或暂不支持的原帧格式使用任务内保存的兼容比例。
    }
    return _catalogOption(fallback, supported, preferred: '16:9');
  }

  static String _defaultImageSize(String model) {
    final aspectRatio = _defaultAspectRatio(model);
    return _catalogOption(
      '',
      ImageGenerationCatalog.resolutionsFor(model, aspectRatio),
      preferred: '2K',
    );
  }

  static String _defaultQuality(String model) {
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    return _catalogOption(
      '',
      descriptor?.qualities ?? const [],
      preferred: 'high',
    );
  }

  static String _catalogOption(
    String candidate,
    List<String> options, {
    required String preferred,
  }) {
    if (options.isEmpty) return '';
    if (options.contains(candidate)) return candidate;
    if (options.contains(preferred)) return preferred;
    return options.first;
  }

  Future<Directory> _assetDirectory(String runId) async {
    final directory = Directory(
      p.join(_directories.assets.path, _safeFileName(runId)),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<ImageGenerationResult> _generateReferenceImage(
    String prompt,
    ReplicateRun run,
  ) async {
    final settings = _settingsController.value;
    final model = _resolvedGenerationModel(run);
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    if (descriptor == null) {
      throw FormatException('不支持的图片生成模型：$model');
    }
    final aspectRatio = _catalogOption(
      run.generationAspectRatio,
      descriptor.aspectRatios,
      preferred: descriptor.aspectRatios.contains('1:1') ? '1:1' : '16:9',
    );
    final imageSize = _catalogOption(
      run.generationImageSize,
      ImageGenerationCatalog.resolutionsFor(model, aspectRatio),
      preferred: '2K',
    );
    final quality = _catalogOption(
      run.generationQuality,
      descriptor.qualities,
      preferred: 'high',
    );
    return _imageGenerationService.generateTextToImage(
      ImageGenerationRequest(
        provider: ImageGenerationProviderResolver.resolve(
          settings: settings,
          model: model,
        ),
        model: model,
        prompt: prompt,
        aspectRatio: aspectRatio,
        imageSize: imageSize,
        quality: quality,
        referenceImagePaths: const [],
        outputDirectory: await _assetDirectory(run.id),
      ),
    );
  }

  Future<void> _deleteManagedAssetFile(
    String path, {
    String excludingPath = '',
  }) async {
    if (path.trim().isEmpty || p.equals(path, excludingPath)) {
      return;
    }
    final file = File(path);
    final root = p.canonicalize(_directories.assets.absolute.path);
    final candidate = p.canonicalize(file.absolute.path);
    if ((p.isWithin(root, candidate) || p.equals(root, p.dirname(candidate))) &&
        file.existsSync()) {
      await file.delete();
    }
  }

  static int _nextReferenceNumber(
    ReplicateAssetType type,
    ReplicateRun run,
    List<ReplicateAsset> assets,
  ) {
    final kind = _mediaKindForType(type);
    var max = switch (kind) {
      ReplicateMediaKind.image => run.imageReferenceCount,
      ReplicateMediaKind.video => run.videoReferenceCount,
      ReplicateMediaKind.audio => run.audioReferenceCount,
    };
    for (final asset in assets) {
      if (SeedancePromptGenerationService.mediaKind(asset) == kind &&
          asset.referenceNumber > max) {
        max = asset.referenceNumber;
      }
    }
    return max + 1;
  }

  static ReplicateRun _runWithReferenceCount(
    ReplicateRun run,
    ReplicateAssetType type,
    int referenceNumber,
  ) {
    return switch (_mediaKindForType(type)) {
      ReplicateMediaKind.image => run.copyWith(
        imageReferenceCount: referenceNumber,
        updatedAt: DateTime.now().toUtc(),
      ),
      ReplicateMediaKind.video => run.copyWith(
        videoReferenceCount: referenceNumber,
        updatedAt: DateTime.now().toUtc(),
      ),
      ReplicateMediaKind.audio => run.copyWith(
        audioReferenceCount: referenceNumber,
        updatedAt: DateTime.now().toUtc(),
      ),
    };
  }

  static ReplicateRun _normalizeReferenceCounts(
    ReplicateRun run,
    List<ReplicateAsset> assets,
  ) {
    var image = run.imageReferenceCount;
    var video = run.videoReferenceCount;
    var audio = run.audioReferenceCount;
    for (final asset in assets) {
      switch (SeedancePromptGenerationService.mediaKind(asset)) {
        case ReplicateMediaKind.image:
          if (asset.referenceNumber > image) image = asset.referenceNumber;
          break;
        case ReplicateMediaKind.video:
          if (asset.referenceNumber > video) video = asset.referenceNumber;
          break;
        case ReplicateMediaKind.audio:
          if (asset.referenceNumber > audio) audio = asset.referenceNumber;
          break;
      }
    }
    if (image == run.imageReferenceCount &&
        video == run.videoReferenceCount &&
        audio == run.audioReferenceCount) {
      return run;
    }
    return run.copyWith(
      imageReferenceCount: image,
      videoReferenceCount: video,
      audioReferenceCount: audio,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  ScriptShot _structuredPromptShot(ScriptShot shot) {
    final analysis = _workflowRepository?.getAnalysis(shot.id);
    if (!_isUsablePromptContext(analysis)) {
      return _shotWithoutSourceVisualContent(shot);
    }
    final structured = const StructuredPromptShotAdapter().apply(
      shot,
      analysis!.promptContext,
    );
    return _shotWithoutSourceVisualContent(structured);
  }

  bool _hasUsablePromptContext(String shotId) =>
      _isUsablePromptContext(_workflowRepository?.getAnalysis(shotId));

  static bool _isUsablePromptContext(ScriptShotAnalysisRecord? analysis) =>
      analysis != null &&
      analysis.status == ProcessingStatus.completed &&
      analysis.promptContextSchemaVersion ==
          ScriptShotPromptContext.currentSchemaVersion &&
      !analysis.promptContext.isEmpty;

  String _promptInputFingerprint({
    required ReplicateRun run,
    required ScriptShot shot,
    required List<ReplicateAsset> assets,
    required List<ScriptShot> actionSequence,
    required ScriptShot? previousShot,
    required ScriptShot? nextShot,
    required ShotPromptFormat selectedFormat,
  }) {
    final relatedShots = <ScriptShot>[
      shot,
      ...actionSequence,
      ?previousShot,
      ?nextShot,
    ];
    return jsonEncode({
      'promptRulesVersion': _promptRulesVersion,
      'format': selectedFormat.name,
      'h3PromptStyleId': selectedFormat == ShotPromptFormat.h3
          ? selectedH3PromptStyle.id
          : H3PromptStyle.generalId,
      'globalStyle': run.globalStyle,
      'constraints': run.constraints,
      'shot': _shotFingerprint(shot),
      'actionSequence': actionSequence.map(_shotFingerprint).toList(),
      'previousShot': previousShot == null
          ? ''
          : _shotFingerprint(previousShot),
      'nextShot': nextShot == null ? '' : _shotFingerprint(nextShot),
      'promptContexts': {
        for (final item in relatedShots)
          item.id: _promptContextFingerprint(item.id),
      },
      'assets': _promptAssetFingerprint(
        actionSequence.isEmpty
            ? [shot.id]
            : actionSequence.map((item) => item.id),
        assets,
      ),
    });
  }

  String _promptContextFingerprint(String shotId) {
    final analysis = _workflowRepository?.getAnalysis(shotId);
    if (analysis == null || analysis.status != ProcessingStatus.completed) {
      return '';
    }
    return jsonEncode({
      'context': analysis.promptContext.toJson(),
      'schemaVersion': analysis.promptContextSchemaVersion,
      'sourceImageFingerprint': analysis.sourceImageFingerprint,
      'analysisRuleVersion': analysis.analysisRuleVersion,
    });
  }

  String _promptAssetFingerprint(
    Iterable<String> shotIds,
    List<ReplicateAsset> fallbackAssets,
  ) {
    final linked = [..._confirmedScriptAssetsForShotIds(shotIds)]
      ..sort((first, second) => first.id.compareTo(second.id));
    if (linked.isNotEmpty) {
      return jsonEncode([
        for (final asset in linked)
          {
            'id': asset.id,
            'type': asset.type.name,
            'name': asset.name,
            'description': asset.description,
            'path': asset.path,
            'referenceNumber': asset.referenceNumber,
            'status': asset.status.name,
          },
      ]);
    }
    final ready = _readyAssets(fallbackAssets)
      ..sort((first, second) => first.id.compareTo(second.id));
    return jsonEncode([
      for (final asset in ready)
        {
          'id': asset.id,
          'type': asset.type.name,
          'name': asset.name,
          'description': asset.description,
          'path': asset.path,
          'referenceNumber': asset.referenceNumber,
          'status': asset.status.name,
        },
    ]);
  }

  bool _promptsAreStale({
    required ReplicateRun run,
    required List<ShotPrompt> prompts,
    required List<ScriptShot> shots,
    required List<String> confirmedShotIds,
    required List<ReplicateAsset> assets,
    required List<ReplicatedShotImage> replicatedImages,
    Map<String, Set<String>> workflowAssetIdsByShot = const {},
  }) {
    final shotById = {for (final shot in shots) shot.id: shot};
    final readyAssetIds = {for (final asset in _readyAssets(assets)) asset.id};
    final sequences = shotSequencesFor(shots);
    final promptShots = sequences
        .map((sequence) => sequence.head)
        .where((shot) => confirmedShotIds.contains(shot.id))
        .toList(growable: false);
    if (prompts.length != promptShots.length) {
      return true;
    }
    final promptShotIds = promptShots.map((shot) => shot.id).toSet();
    for (final prompt in prompts) {
      final shot = shotById[prompt.scriptShotId];
      if (shot == null || !promptShotIds.contains(shot.id)) {
        return true;
      }
      final actionSequence = _actionSequenceForPrompt(shot, sequences);
      if (run.freeCreationEnabled) {
        if (prompt.shotNumber != shot.shotNumber) return true;
        final groupIndex = sequences.indexWhere(
          (sequence) => sequence.head.id == shot.id,
        );
        if (groupIndex < 0) return true;
        final group = ScriptShotGroup(sequences[groupIndex].shots);
        final input = _freeCreationPromptInput(group, replicatedImages);
        if (!_freeCreationPromptMatchesInput(
          prompt: prompt,
          group: group,
          input: input,
        )) {
          return true;
        }
        continue;
      }
      final linkedAssetIds = {
        for (final item in actionSequence) ...?workflowAssetIdsByShot[item.id],
      };
      final expectedAssetIds = linkedAssetIds.isEmpty
          ? readyAssetIds
          : linkedAssetIds;
      if (prompt.shotNumber != shot.shotNumber ||
          prompt.assetIds.toSet().difference(expectedAssetIds).isNotEmpty ||
          expectedAssetIds.difference(prompt.assetIds.toSet()).isNotEmpty) {
        return true;
      }
      try {
        final raw = jsonDecode(prompt.rawResponse);
        final index = promptShots.indexWhere((item) => item.id == shot.id);
        final expectedInputFingerprint = _promptInputFingerprint(
          run: run,
          shot: shot,
          assets: assets,
          actionSequence: actionSequence,
          previousShot: index > 0 ? promptShots[index - 1] : null,
          nextShot: index + 1 < promptShots.length
              ? promptShots[index + 1]
              : null,
          selectedFormat: _composePromptModelRule.format,
        );
        if (raw is! Map ||
            raw['promptRulesVersion'] != _promptRulesVersion ||
            raw['shotFingerprint'] != _shotFingerprint(shot) ||
            raw['promptInputFingerprint'] != expectedInputFingerprint) {
          return true;
        }
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  static String _shotFingerprint(ScriptShot shot) => jsonEncode({
    'shotNumber': shot.shotNumber,
    'durationSeconds': shot.durationSeconds,
    'content': shot.content,
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
    'dialogue': shot.dialogue,
    'sound': shot.sound,
    'replicationInstructions': shot.replicationInstructions,
  });

  static ReplicateMediaKind _mediaKindForType(ReplicateAssetType type) {
    return switch (type) {
      ReplicateAssetType.video => ReplicateMediaKind.video,
      ReplicateAssetType.audio => ReplicateMediaKind.audio,
      _ => ReplicateMediaKind.image,
    };
  }

  static bool _hasReadyAssets(List<ReplicateAsset> assets) =>
      _readyAssets(assets).isNotEmpty;

  bool _hasWorkflowPromptAssets() {
    final targetShots = value.confirmedShots;
    return _confirmedScriptAssetsForShots(targetShots).isNotEmpty;
  }

  List<ScriptAsset> _confirmedScriptAssetsForShots(Iterable<ScriptShot> shots) {
    final items = shots.toList(growable: false);
    return _confirmedScriptAssetsForShotIds(
      items.map((shot) => shot.id),
      scriptId: items.isEmpty ? null : items.first.scriptId,
    );
  }

  List<ScriptAsset> _confirmedScriptAssetsForShotIds(
    Iterable<String> shotIds, {
    String? scriptId,
  }) {
    final repository = _workflowRepository;
    final selectedScriptId = scriptId ?? value.selectedScriptId;
    final orderedShotIds = shotIds.toList(growable: false);
    final targetShotIds = orderedShotIds.toSet();
    if (repository == null ||
        selectedScriptId.isEmpty ||
        targetShotIds.isEmpty) {
      return const [];
    }
    final assetsById = {
      for (final asset in repository.listScriptAssets(selectedScriptId))
        asset.id: asset,
    };
    final assets = <ScriptAsset>[];
    final usedIds = <String>{};
    final linksByShotId = <String, List<ScriptShotAssetLink>>{};
    for (final link in repository.listLinksForScript(selectedScriptId)) {
      if (targetShotIds.contains(link.shotId) && link.confirmed) {
        (linksByShotId[link.shotId] ??= []).add(link);
      }
    }
    for (final shotId in orderedShotIds) {
      for (final link in linksByShotId[shotId] ?? const []) {
        if (!usedIds.add(link.scriptAssetId)) continue;
        final asset = assetsById[link.scriptAssetId];
        if (asset != null) assets.add(asset);
      }
    }
    return assets;
  }

  Map<String, Set<String>> _confirmedScriptAssetIdsByShot(
    String scriptId,
    List<ScriptShot> shots,
  ) {
    final repository = _workflowRepository;
    if (repository == null || scriptId.isEmpty) return const {};
    final validAssetIds = {
      for (final asset in repository.listScriptAssets(scriptId)) asset.id,
    };
    final validShotIds = {for (final shot in shots) shot.id};
    final result = <String, Set<String>>{};
    for (final link in repository.listLinksForScript(scriptId)) {
      if (!validShotIds.contains(link.shotId) ||
          !link.confirmed ||
          !validAssetIds.contains(link.scriptAssetId)) {
        continue;
      }
      (result[link.shotId] ??= <String>{}).add(link.scriptAssetId);
    }
    return result;
  }

  static List<ReplicateAsset> _readyAssets(List<ReplicateAsset> assets) => [
    for (final asset in assets)
      if (asset.status == ProcessingStatus.completed &&
          asset.path.trim().isNotEmpty &&
          File(asset.path).existsSync())
        asset,
  ];

  static String _runIdForScript(String scriptId) =>
      'replicate-script-$scriptId';

  String _ownerScriptId(ReplicateRun run) {
    final stored = run.scriptId?.trim() ?? '';
    if (stored.isNotEmpty) return stored;
    const prefix = 'replicate-script-';
    return run.id.startsWith(prefix)
        ? run.id.substring(prefix.length)
        : value.selectedScriptId;
  }

  static String _promptId(String runId, String shotId) =>
      '$runId-prompt-$shotId';

  static String _promptKey(ShotPromptFormat format) => switch (format) {
    ShotPromptFormat.sd2 => 'sd2Prompt',
    ShotPromptFormat.kling => 'klingPrompt',
    ShotPromptFormat.h3 => 'h3Prompt',
  };

  _ComposePromptModelRule get _composePromptModelRule {
    final config = _settingsController.value.activeVideoGenerationApiConfig;
    final format = _promptFormatForVideoModel(
      '${config?.name ?? ''} ${config?.model ?? ''}',
      httpFallback: config?.isHttpApi == true,
    );
    return _ComposePromptModelRule(
      format: format,
      label: _promptFormatLabel(format),
      maxConcurrent: format == ShotPromptFormat.kling
          ? klingComposePromptConcurrency
          : defaultComposePromptConcurrency,
    );
  }

  static ShotPromptFormat _promptFormatForVideoModel(
    String model, {
    required bool httpFallback,
  }) {
    final normalized = model.trim().toLowerCase();
    if (RegExp(r'即梦|jimeng|seedance|doubao').hasMatch(normalized)) {
      return ShotPromptFormat.sd2;
    }
    if (RegExp(r'\bh3\b|minimax|海螺').hasMatch(normalized)) {
      return ShotPromptFormat.h3;
    }
    if (RegExp(r'可灵|kling').hasMatch(normalized)) {
      return ShotPromptFormat.kling;
    }
    return httpFallback ? ShotPromptFormat.h3 : ShotPromptFormat.kling;
  }

  void _handleSettingsChanged() {
    if (_disposed) return;
    selectPromptFormatForAll(_composePromptModelRule.format);
    if (!_disposed) _restoreFromShootingScript();
  }

  static Map<String, Object?> _promptRaw(ShotPrompt prompt) {
    try {
      final decoded = jsonDecode(prompt.rawResponse);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {
      // 旧版单提示词记录在首次编辑或切换时自动升级为多版本结构。
    }
    return <String, Object?>{
      'sd2Prompt': prompt.prompt,
      'klingPrompt': prompt.prompt,
      'h3Prompt': prompt.prompt,
      'selectedPromptFormat': ShotPromptFormat.kling.name,
    };
  }

  static String _promptFormatSelectedMessage(ShotPromptFormat format) =>
      switch (format) {
        ShotPromptFormat.sd2 => '已选择即梦',
        ShotPromptFormat.kling => '已选择可灵',
        ShotPromptFormat.h3 => '已选择 H3',
      };

  static List<String> _h3ReferenceDefinitionsFromReplicateAssets(
    List<ReplicateAsset> assets, {
    int startImageNumber = 2,
  }) {
    var imageNumber = startImageNumber;
    final result = <String>[];
    for (final asset in assets) {
      if (asset.path.trim().isEmpty) continue;
      result.add(
        '图片${imageNumber++}：'
        '${_h3AssetRole(asset.type)}，${_joinNonEmpty([asset.name, asset.description])}。',
      );
    }
    return result;
  }

  static List<String> _h3ReferenceDefinitionsFromScriptAssets(
    List<ScriptAsset> assets, {
    int startImageNumber = 2,
  }) {
    var imageNumber = startImageNumber;
    final result = <String>[];
    for (final asset in assets) {
      if (asset.path.trim().isEmpty) continue;
      result.add(
        '图片${imageNumber++}：'
        '${_h3AssetRole(asset.type)}，${_joinNonEmpty([asset.name, asset.description])}。',
      );
    }
    return result;
  }

  static String _h3AssetRole(ReplicateAssetType type) => switch (type) {
    ReplicateAssetType.character => '人物参考，锁定脸、发型、服装轮廓和气质',
    ReplicateAssetType.product => '产品参考，锁定外观结构、材质、比例和使用关系',
    ReplicateAssetType.scene => '场景参考，锁定空间、透视、环境层次和光影氛围',
    ReplicateAssetType.prop => '道具参考，锁定外观、尺寸、朝向和交互关系',
    ReplicateAssetType.video => '动作、运镜和剪辑节奏参考',
    ReplicateAssetType.audio => '声音节奏、情绪和氛围参考',
    ReplicateAssetType.reference || ReplicateAssetType.other => '综合视觉参考',
  };

  static String _joinNonEmpty(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .join('，');

  static String _replicatedImageId(String runId, String shotId) =>
      '$runId-replicated-$shotId';

  static String _stepLabel(ReplicateStep step) => switch (step) {
    ReplicateStep.prepareAssets => '步骤 1：准备素材',
    ReplicateStep.confirmShots => '步骤 2：确认脚本',
    ReplicateStep.composePrompts => '步骤 2：确认脚本',
    ReplicateStep.generateVideos => '步骤 3：生成视频',
  };

  static String _assetTypeLabel(ReplicateAssetType type) => switch (type) {
    ReplicateAssetType.character => '人物',
    ReplicateAssetType.product => '产品',
    ReplicateAssetType.scene => '场景',
    ReplicateAssetType.prop => '道具',
    ReplicateAssetType.video => '视频',
    ReplicateAssetType.audio => '音频',
    ReplicateAssetType.reference => '参考',
    ReplicateAssetType.other => '其他',
  };

  static String _safeFileName(String value) {
    final safe = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return safe.isEmpty ? '复刻任务' : safe;
  }

  static File _uniqueFile(Directory directory, String name) {
    var file = File(p.join(directory.path, name));
    if (!file.existsSync()) {
      return file;
    }
    final extension = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    var suffix = 2;
    while (file.existsSync()) {
      file = File(p.join(directory.path, '$base ($suffix)$extension'));
      suffix++;
    }
    return file;
  }

  static Directory _uniqueDirectory(Directory parent, String name) {
    var directory = Directory(p.join(parent.path, name));
    var suffix = 2;
    while (directory.existsSync()) {
      directory = Directory(p.join(parent.path, '$name ($suffix)'));
      suffix++;
    }
    return directory;
  }
}

class _FreeCreationImageReference {
  const _FreeCreationImageReference({
    required this.file,
    required this.role,
    required this.name,
  });

  final File file;
  final String role;
  final String name;
}

class _FreeCreationPromptInput {
  const _FreeCreationPromptInput({
    required this.references,
    required this.storyboardImageCount,
    required this.singleContinuousShot,
    required this.explicitMultiShotIntent,
    required this.allowSlowMotion,
    required this.referenceSource,
    required this.videoConfig,
    required this.skillRoute,
  });

  final List<_FreeCreationImageReference> references;
  final int storyboardImageCount;
  final bool singleContinuousShot;
  final bool explicitMultiShotIntent;
  final bool allowSlowMotion;
  final String referenceSource;
  final VideoGenerationApiConfig? videoConfig;
  final VideoSkillRoute skillRoute;
}

class _FreeCreationPromptResult {
  const _FreeCreationPromptResult({required this.prompt, this.durationSeconds});

  final ShotPrompt prompt;
  final int? durationSeconds;
}

class _ReplicationContext {
  const _ReplicationContext({
    required this.scriptId,
    required this.run,
    required this.assets,
  });

  final String scriptId;
  final ReplicateRun run;
  final List<ReplicateAsset> assets;
}

class _ReplacementReference {
  const _ReplacementReference({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    required this.path,
    this.slotLabel = '',
    this.isDetailCrop = false,
  });

  final String id;
  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
  final String slotLabel;
  final bool isDetailCrop;
}
