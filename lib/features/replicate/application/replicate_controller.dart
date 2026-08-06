import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../settings/application/settings_controller.dart';
import '../../shooting_script/domain/shooting_asset_library_models.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/data/script_multimodal_analysis_service.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/data/shooting_script_workflow_repository.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../../storyboard/domain/image_generation_provider_resolver.dart';
import '../../story_design/domain/gemini_storyboard_prompt.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/domain/video_action_sequence.dart';
import '../../video_generation/domain/h3_video_prompt_adapter.dart';
import '../../video_generation/domain/kling_video_prompt_adapter.dart';
import '../data/replicate_repository.dart';
import '../data/replicate_prompt_export_service.dart';
import '../data/seedance_prompt_generation_service.dart';
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
    this.isBusy = false,
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
  final bool isBusy;
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
    bool? isBusy,
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
    isBusy: isBusy ?? this.isBusy,
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
       _uuid = uuid,
       super(const ReplicateState()) {
    _shootingScriptController.addListener(_handleShootingScriptChanged);
    _assetBindingController?.addListener(_handleWorkflowChanged);
    _restoreFromShootingScript();
  }

  static const promptModel = 'Seedance 2';
  static const _promptRulesVersion = 3;
  static const _visionPromptImageMaxBytes = 3 * 1024 * 1024;
  static const _visionPromptImageMaxDimension = 1280;
  static const defaultComposePromptConcurrency = 4;
  static const klingComposePromptConcurrency = 2;
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
  final Uuid _uuid;
  bool _disposed = false;
  String? _pendingStartFrameShotId;
  final _activeReplicationScriptIds = <String>{};
  final _replicationMessagesByScriptId = <String, String>{};

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleShootingScriptChanged);
    _assetBindingController?.removeListener(_handleWorkflowChanged);
    if (_ownsImageGenerationService) {
      _imageGenerationService.close();
    }
    if (_ownsVisionService) {
      _visionService.close();
    }
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
        generationImageSize: selectedImageSize,
        generationQuality: selectedQuality,
        updatedAt: DateTime.now().toUtc(),
      ),
      message: '已保存一键复刻默认生成参数',
    );
  }

  String get composePromptModelLabel => _composePromptModelRule.label;

  int get composePromptConcurrency => _composePromptModelRule.maxConcurrent;

  void refresh() => _restoreFromShootingScript();

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
    if (step.index >= ReplicateStep.prepareAssets.index &&
        value.shots.isEmpty) {
      value = value.copyWith(errorMessage: '当前脚本暂无可用镜头', message: '');
      return false;
    }
    if (step.index >= ReplicateStep.generateVideos.index &&
        value.prompts.isEmpty) {
      value = value.copyWith(errorMessage: '请先完成步骤 3 生成提示词', message: '');
      return false;
    }
    final updated = run.copyWith(
      currentStep: step,
      prepareAssetsStatus:
          step.index >= ReplicateStep.composePrompts.index &&
              _hasWorkflowPromptAssets()
          ? ProcessingStatus.completed
          : run.prepareAssetsStatus,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _persistRun(updated, message: '已进入${_stepLabel(step)}');
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
    final updated = run.copyWith(
      globalStyle: globalStyle.trim().isEmpty
          ? _settingsController.value.replicateDefaultGlobalStyle
          : globalStyle.trim(),
      constraints: constraints.trim().isEmpty
          ? _settingsController.value.replicateDefaultConstraints
          : constraints.trim(),
      composePromptsStatus: value.prompts.isEmpty
          ? run.composePromptsStatus
          : ProcessingStatus.pending,
      status: value.prompts.isEmpty ? run.status : ProcessingStatus.pending,
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

  void updateShot(ScriptShot shot) {
    if (shot.scriptId != value.selectedScriptId) {
      return;
    }
    final run = value.run;
    if (run != null && value.prompts.isNotEmpty) {
      final pending = run.copyWith(
        status: ProcessingStatus.pending,
        composePromptsStatus: ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(pending);
      value = value.copyWith(run: pending);
    }
    _shootingScriptController.updateShot(shot);
  }

  void deleteShot(String shotId) {
    _shootingScriptController.deleteShot(shotId);
  }

  bool get startEndFrameModeEnabled =>
      _settingsController.value.videoStartEndFrameModeEnabled;

  String? get pendingStartFrameShotId => _pendingStartFrameShotId;

  List<VideoActionSequence> startEndSequencesFor(List<ScriptShot> shots) {
    final run = value.run;
    if (run == null || !startEndFrameModeEnabled) {
      return [
        for (final shot in shots) VideoActionSequence([shot]),
      ];
    }
    return const VideoActionSequenceResolver().resolveManual(
      shots,
      run.startEndPairs,
    );
  }

  List<ScriptShot> get startEndRows {
    if (!startEndFrameModeEnabled) return [...value.shots];
    return startEndSequencesFor(
      value.shots,
    ).map((sequence) => sequence.head).toList(growable: false);
  }

  ScriptShot? tailShotForDisplay(ScriptShot shot) {
    if (!startEndFrameModeEnabled) return null;
    final sequence = const VideoActionSequenceResolver().manualSequenceFor(
      value.shots,
      value.run?.startEndPairs ?? const [],
      shot.id,
    );
    return sequence.head.id == shot.id && sequence.hasDistinctTail
        ? sequence.tail
        : null;
  }

  bool canSelectStartFrame(String shotId) {
    if (!startEndFrameModeEnabled) return false;
    return _shotById(shotId) != null && _pairContainingShot(shotId) == null;
  }

  bool canSelectTailFrame(String shotId) {
    if (!startEndFrameModeEnabled) return false;
    final startId = _pendingStartFrameShotId;
    if (startId == null || startId == shotId) return false;
    final start = _shotById(startId);
    final tail = _shotById(shotId);
    if (start == null || tail == null || tail.shotNumber <= start.shotNumber) {
      return false;
    }
    final candidates = _normalizedStartEndPairs([
      ...?value.run?.startEndPairs,
      StartEndFramePair(startShotId: startId, tailShotId: shotId),
    ], value.shots);
    return candidates.any(
      (pair) => pair.startShotId == startId && pair.tailShotId == shotId,
    );
  }

  void selectStartFrame(String shotId) {
    if (!canSelectStartFrame(shotId)) return;
    _pendingStartFrameShotId = shotId;
    final shot = _shotById(shotId);
    value = value.copyWith(
      message: shot == null
          ? '请选择尾帧'
          : '已选择镜头 ${shot.shotNumber} 为首帧，请右键后续镜头设为尾帧',
      errorMessage: '',
    );
  }

  void setTailFrame(String tailShotId) {
    final run = value.run;
    final startId = _pendingStartFrameShotId;
    if (run == null || startId == null || !canSelectTailFrame(tailShotId)) {
      value = value.copyWith(errorMessage: '请选择首帧之后未被占用的镜头作为尾帧', message: '');
      return;
    }
    _pendingStartFrameShotId = null;
    _persistStartEndPairs([
      ...run.startEndPairs,
      StartEndFramePair(startShotId: startId, tailShotId: tailShotId),
    ], message: '已设置首尾帧配对');
  }

  void clearStartEndPair(String shotId) {
    final run = value.run;
    if (run == null) return;
    final pair = _pairContainingShot(shotId);
    if (pair == null) return;
    if (_pendingStartFrameShotId == pair.startShotId) {
      _pendingStartFrameShotId = null;
    }
    _persistStartEndPairs([
      for (final item in run.startEndPairs)
        if (item.startShotId != pair.startShotId ||
            item.tailShotId != pair.tailShotId)
          item,
    ], message: '已取消首尾帧配对');
  }

  Future<bool> replicateShot(String shotId) async {
    final context = _replicationContext();
    if (context == null ||
        _activeReplicationScriptIds.contains(context.scriptId)) {
      return false;
    }
    final shot = _shotById(shotId);
    if (shot == null) return false;
    final shots = _replicationEndpointsForShot(shot);
    _activeReplicationScriptIds.add(context.scriptId);
    value = value.copyWith(
      isBusy: true,
      message: startEndFrameModeEnabled && shots.length > 1
          ? '正在提交镜头 ${shot.shotNumber} 的首尾帧复刻任务…'
          : '正在提交镜头 ${shot.shotNumber} 的复刻任务…',
      errorMessage: '',
    );
    _replicationMessagesByScriptId[context.scriptId] = value.message;
    var succeededCount = 0;
    for (final target in shots) {
      final succeeded = await _generateReplicatedShot(target, context);
      if (succeeded) succeededCount++;
    }
    final succeeded = succeededCount == shots.length;
    _activeReplicationScriptIds.remove(context.scriptId);
    if (!_disposed) {
      final errors = [
        for (final target in shots)
          _replicatedImageError(context.run.id, target.id).trim(),
      ].where((item) => item.isNotEmpty).toSet().join('；');
      final message = succeeded
          ? startEndFrameModeEnabled && shots.length > 1
                ? '镜头 ${shot.shotNumber} 首尾帧复刻完成'
                : '镜头 ${shot.shotNumber} 复刻完成'
          : '';
      _replicationMessagesByScriptId[context.scriptId] = message;
      if (value.selectedScriptId == context.scriptId) {
        value = value.copyWith(
          isBusy: false,
          message: message,
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
        _activeReplicationScriptIds.contains(context.scriptId)) {
      return;
    }
    final shots = _replicationTargetsForAll();
    if (shots.isEmpty) {
      value = value.copyWith(errorMessage: '当前脚本暂无可复刻的镜头', message: '');
      return;
    }
    _activeReplicationScriptIds.add(context.scriptId);
    value = value.copyWith(
      isBusy: true,
      message: startEndFrameModeEnabled
          ? '准备高并发提交 ${shots.length} 张首尾帧复刻任务…'
          : '准备高并发提交 ${shots.length} 个复刻任务…',
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
        startEndFrameModeEnabled
            ? '首尾帧复刻进度 $completed/${shots.length}，成功 $succeeded 张'
            : '复刻进度 $completed/${shots.length}，成功 $succeeded 个',
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
      _activeReplicationScriptIds.remove(context.scriptId);
      if (!_disposed) {
        final failed = shots.length - succeeded;
        final message = failed == 0
            ? startEndFrameModeEnabled
                  ? '已完成 ${shots.length} 张首尾帧复刻'
                  : '已完成 ${shots.length} 个镜头复刻'
            : '';
        final error = failed == 0
            ? ''
            : startEndFrameModeEnabled
            ? '$failed 张首尾帧复刻失败，可单独重试'
            : '$failed 个镜头复刻失败，可单独重试';
        _replicationMessagesByScriptId[context.scriptId] = message;
        if (value.selectedScriptId == context.scriptId) {
          value = value.copyWith(
            isBusy: false,
            message: message,
            errorMessage: error,
          );
        }
      }
    }
  }

  List<ScriptShot> _replicationTargetsForAll() {
    final shots = [...value.confirmedShots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    if (!startEndFrameModeEnabled) return shots;
    return startEndSequencesFor(shots)
        .expand(
          (sequence) => [
            sequence.head,
            if (sequence.hasDistinctTail) sequence.tail,
          ],
        )
        .toSet()
        .toList(growable: false);
  }

  List<ScriptShot> _replicationEndpointsForShot(ScriptShot shot) {
    if (!startEndFrameModeEnabled) return [shot];
    final sequence = const VideoActionSequenceResolver().manualSequenceFor(
      value.shots,
      value.run?.startEndPairs ?? const [],
      shot.id,
    );
    if (!sequence.hasDistinctTail) return [shot];
    return [
      sequence.head,
      if (sequence.tail.id != sequence.head.id) sequence.tail,
    ];
  }

  Future<bool> _generateReplicatedShot(
    ScriptShot shot,
    _ReplicationContext context,
  ) async {
    final run = context.run;
    final original = File(shot.framePath);
    final fallbackReferenceShotId = _fallbackReferenceShotIdFor(shot, run);
    final references = _replacementReferences(
      shot.id,
      scriptId: context.scriptId,
      stepAssets: context.assets,
      fallbackShotId: fallbackReferenceShotId,
    );
    final now = DateTime.now().toUtc();
    final existing = _replicatedImageForShot(shot.id);
    final model = _resolvedGenerationModel(run);
    var record = ReplicatedShotImage(
      id: existing?.id ?? _replicatedImageId(run.id, shot.id),
      runId: run.id,
      scriptShotId: shot.id,
      shotNumber: shot.shotNumber,
      originalFramePath: shot.framePath,
      generatedFramePath: existing?.generatedFramePath ?? '',
      assetIds: [for (final reference in references) reference.id],
      prompt: _generationPrompt(shot, references, model),
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
      record = record.copyWith(
        status: ProcessingStatus.failed,
        errorMessage: '当前镜头没有已绑定且可用的图片资产',
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      return false;
    }
    _saveReplicatedImage(record);
    try {
      if (!_disposed) {
        _setReplicationMessage(
          context.scriptId,
          '正在用视觉模型解析镜头 ${shot.shotNumber} 的画面维度…',
        );
      }
      final prompt = await _buildVisionEnhancedGenerationPrompt(
        shot: shot,
        references: references,
        model: model,
        original: original,
      );
      record = record.copyWith(
        prompt: prompt,
        updatedAt: DateTime.now().toUtc(),
      );
      _saveReplicatedImage(record);
      final descriptor = ImageGenerationCatalog.descriptorFor(model);
      if (descriptor == null) {
        throw FormatException('不支持的图片生成模型：$model');
      }
      final aspectRatio = _catalogOption(
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
      final result = await _imageGenerationService.generateEditedImage(
        ImageGenerationRequest(
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
            for (final reference in references) reference.path,
          ],
          outputDirectory: outputDirectory,
        ),
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

  Future<String> _buildVisionEnhancedGenerationPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required String model,
    required File original,
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
      final prompt = await _resolveUserPriorityGenerationPrompt(
        shot: shot,
        references: references,
        original: original,
        automaticPrompt: _generationPrompt(
          shot,
          references,
          model,
          analysis: analysis,
        ),
      );
      return _appendFinalTextSafetyCheck(prompt);
    } catch (_) {
      // 视觉模型不可用、超时或返回格式异常时，保留原有一键生成能力。
      final prompt = await _resolveUserPriorityGenerationPrompt(
        shot: shot,
        references: references,
        original: original,
        automaticPrompt: _generationPrompt(shot, references, model),
      );
      return _appendFinalTextSafetyCheck(prompt);
    }
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
      return normalized.isEmpty ? fallback : normalized;
    } catch (_) {
      // 解析服务异常时仍把用户要求明确置于末尾最高优先级，避免静默丢失。
      return fallback;
    }
  }

  static String _userPriorityFallbackPrompt({
    required String automaticPrompt,
    required String instructions,
  }) =>
      '$automaticPrompt\n\n'
      '【用户补充说明：最高优先级】$instructions\n'
      '冲突处理：若以上自动解析、原帧描述、资产描述或固定约束与用户补充说明冲突，必须删除或改写冲突内容，始终按用户补充说明生成；不得保留原人物的服装、首饰、眼镜、帽子、包、手表或其他配饰，除非用户明确要求保留。\n'
      '文字例外判定：只有用户补充说明明确要求画面出现文本并给出需要逐字呈现的具体内容时，才可开放该段指定文本；其他情况仍必须执行无文字、无 Logo 硬约束。';

  static String _userPriorityResolutionPrompt({
    required ScriptShot shot,
    required List<_ReplacementReference> references,
    required String automaticPrompt,
    required String instructions,
  }) =>
      '''
你是图像生成提示词编辑器。请根据图片1和以下文本，输出一份可直接提交给图片生成 API 的中文最终提示词。

最高优先级规则：用户补充说明高于自动解析、原视频帧、镜头脚本和任何固定复刻规则。若两者冲突，必须删除或改写自动提示词中的冲突描述，绝不能把彼此矛盾的要求同时保留。

镜头：${shot.shotNumber}
当前绑定素材：${references.map((item) => '${_replacementTypeLabel(item.type)}「${item.name}」').join('、')}

用户补充说明（最高优先级）：
$instructions

自动解析的提示词（仅作待清理草稿）：
$automaticPrompt

编辑要求：
1. 保留与用户说明不冲突的镜头叙事、构图、动作、光影和已绑定素材要求。
2. 用户要求替换、移除或不要出现的元素，必须明确写为“不出现/替换为”并移除原有相反表述；人物配饰包括首饰、眼镜、帽子、包、手表、发饰等。
3. 不得复刻图片1原人物的身份、脸部、服装或配饰，除非用户明确要求保留；已绑定的新人物或产品始终优先使用。
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
  }) {
    final base = _replacementPrompt(shot, references, analysis: analysis);
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

  Future<void> composeAllPrompts({int? maxConcurrent}) async {
    final run = value.run;
    final shots = startEndFrameModeEnabled
        ? startEndRows
        : value.confirmedShots;
    final assets = _readyAssets(value.assets);
    final modelRule = _composePromptModelRule;
    if (run == null || shots.isEmpty) {
      value = value.copyWith(errorMessage: '需要至少一个可用镜头', message: '');
      return;
    }
    final running = run.copyWith(
      currentStep: ReplicateStep.composePrompts,
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
      prompts: const [],
      message: '正在按${modelRule.label}规则并发合成 0/${shots.length} 个提示词…',
      errorMessage: '',
    );
    final prompts = List<ShotPrompt?>.filled(shots.length, null);
    var completed = 0;
    var succeeded = 0;
    var nextIndex = 0;
    final sequences = startEndFrameModeEnabled
        ? startEndSequencesFor(value.confirmedShots)
        : const <VideoActionSequence>[];
    final requestedConcurrency = maxConcurrent ?? modelRule.maxConcurrent;
    final concurrency = requestedConcurrency.clamp(1, shots.length).toInt();

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= shots.length) return;
        nextIndex++;
        final shot = shots[index];
        final actionSequence = _actionSequenceForPrompt(shot, sequences);
        var prompt = _composePrompt(
          run: running,
          shot: shot,
          assets: assets,
          actionSequence: actionSequence,
          previousShot: index > 0 ? shots[index - 1] : null,
          nextShot: index + 1 < shots.length ? shots[index + 1] : null,
          selectedFormat: modelRule.format,
        );
        prompt = await _refineSelectedPromptWithVision(
          prompt: prompt,
          shot: shot,
          assets: assets,
          actionSequence: actionSequence,
        );
        prompts[index] = prompt;
        completed++;
        if (prompt.status == ProcessingStatus.completed) {
          succeeded++;
        }
        if (!_disposed) {
          value = value.copyWith(
            prompts: [for (final item in prompts) ?item],
            message:
                '正在按${modelRule.label}规则并发合成提示词 '
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
    _syncScriptPromptFields(finishedPrompts);
    if (!_disposed) {
      value = value.copyWith(
        run: finished,
        prompts: finishedPrompts,
        isBusy: false,
        message: failed == 0
            ? '已按${modelRule.label}规则并发生成 ${finishedPrompts.length} 个提示词'
            : '',
        errorMessage: finished.errorMessage,
      );
    }
  }

  void regeneratePrompt(String promptId) {
    final run = value.run;
    final index = value.prompts.indexWhere((prompt) => prompt.id == promptId);
    if (run == null || index < 0) {
      return;
    }
    final existing = value.prompts[index];
    final shot = _shotById(existing.scriptShotId ?? '');
    if (shot == null) {
      return;
    }
    final orderedShots = [...value.confirmedShots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    final shotIndex = orderedShots.indexWhere((item) => item.id == shot.id);
    final updated = _composePrompt(
      run: run,
      shot: shot,
      assets: _readyAssets(value.assets),
      actionSequence: startEndFrameModeEnabled
          ? const VideoActionSequenceResolver()
                .manualSequenceFor(orderedShots, run.startEndPairs, shot.id)
                .shots
          : const [],
      previousShot: shotIndex > 0 ? orderedShots[shotIndex - 1] : null,
      nextShot: shotIndex >= 0 && shotIndex + 1 < orderedShots.length
          ? orderedShots[shotIndex + 1]
          : null,
      selectedFormat: _composePromptModelRule.format,
    );
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(run, prompts, message: '镜头 ${shot.shotNumber} 已重新生成');
    _syncScriptPromptFields(prompts);
  }

  void retryFailedPrompts() {
    final failed = [
      for (final prompt in value.prompts)
        if (prompt.status == ProcessingStatus.failed) prompt.id,
    ];
    for (final id in failed) {
      regeneratePrompt(id);
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
      status: ProcessingStatus.completed,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(run, prompts, message: '提示词已保存');
    _syncScriptPromptFields(prompts);
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
    final selectedText = '${raw[_promptKey(format)] ?? ''}'.trim();
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
    _syncScriptPromptFields(prompts);
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
        isBusy: _activeReplicationScriptIds.contains(value.selectedScriptId),
        message: missing == 0
            ? '已导出 $copied 张复刻分镜图到 ${directory.path}'
            : '已导出 $copied 张复刻分镜图，另有 $missing 个镜头缺图',
        errorMessage: '',
      );
      return result;
    } catch (error) {
      value = value.copyWith(
        isBusy: _activeReplicationScriptIds.contains(value.selectedScriptId),
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
        currentStep: ReplicateStep.confirmShots,
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
    final normalizedPairs = _normalizedStartEndPairs(
      run.startEndPairs,
      shooting.shots,
    );
    if (!_sameStartEndPairs(normalizedPairs, run.startEndPairs)) {
      run = run.copyWith(
        startEndPairs: normalizedPairs,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    if (_pendingStartFrameShotId != null &&
        !shooting.shots.any((shot) => shot.id == _pendingStartFrameShotId)) {
      _pendingStartFrameShotId = null;
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
        _promptsAreStale(
          prompts: prompts,
          shots: shooting.shots,
          confirmedShotIds: confirmedIds,
          assets: assets,
          workflowAssetIdsByShot: workflowAssetIdsByShot,
        )) {
      run = run.copyWith(
        status: ProcessingStatus.pending,
        composePromptsStatus: ProcessingStatus.pending,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
      _repository.deletePrompts(run.id);
      prompts = const [];
    }
    final isReplicating = _activeReplicationScriptIds.contains(scriptId);
    value = value.copyWith(
      scripts: scripts,
      shots: shooting.shots,
      selectedScriptId: scriptId,
      run: run,
      assets: assets,
      replicatedImages: replicatedImages,
      prompts: prompts,
      isBusy: isReplicating,
      message: isReplicating
          ? (_replicationMessagesByScriptId[scriptId] ?? '')
          : '',
      errorMessage: '',
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
      isBusy: _activeReplicationScriptIds.contains(value.selectedScriptId),
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
      final promptShot = _shotWithoutSourceVisualContent(shot);
      final promptActionSequence = actionSequence
          .map(_shotWithoutSourceVisualContent)
          .toList(growable: false);
      final promptPreviousShot = previousShot == null
          ? null
          : _shotWithoutSourceVisualContent(previousShot);
      final promptNextShot = nextShot == null
          ? null
          : _shotWithoutSourceVisualContent(nextShot);
      final linkedAssets = _confirmedScriptAssets(shot.id);
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
        availableImageReferences: promptActionSequence.length > 1 ? 2 : 1,
        globalStyle: run.globalStyle,
        constraints: run.constraints,
      );
      final h3Prompt = const H3VideoPromptAdapter().adapt(
        promptShot,
        sourcePrompt: '',
        actionSequence: promptActionSequence,
        availableImageReferences: promptActionSequence.length > 1 ? 2 : 1,
        globalStyle: run.globalStyle,
        constraints: run.constraints,
        referenceDefinitions: linkedAssets.isNotEmpty
            ? _h3ReferenceDefinitionsFromScriptAssets(linkedAssets)
            : _h3ReferenceDefinitionsFromReplicateAssets(assets),
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
          'shotFingerprint': _shotFingerprint(shot),
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

  Future<ShotPrompt> _refineSelectedPromptWithVision({
    required ShotPrompt prompt,
    required ScriptShot shot,
    required List<ReplicateAsset> assets,
    required List<ScriptShot> actionSequence,
  }) async {
    if (prompt.status != ProcessingStatus.completed) return prompt;
    final storyboardImageFiles = _replicatedPromptImageFiles(
      shot: shot,
      actionSequence: actionSequence,
    );
    final assetReferences = _visionPromptAssetReferences(
      shot.id,
      fallbackAssets: assets,
      selectedAssetIds: prompt.assetIds.toSet(),
    );
    final imageFiles = [
      ...storyboardImageFiles,
      for (final reference in assetReferences) File(reference.path),
    ];
    if (imageFiles.isEmpty) return prompt;
    final format = promptFormatFor(prompt);
    final raw = _promptRaw(prompt);
    final draft = '${raw[_promptKey(format)] ?? prompt.prompt}'.trim();
    if (draft.isEmpty) return prompt;
    final preparedDirectory = _visionPromptImageDirectory(prompt.id);
    try {
      final preparedImageFiles = await _prepareVisionPromptImages(
        imageFiles,
        preparedDirectory,
      );
      final refined = await _visionService.complete(
        settings: _settingsController.value,
        imageFiles: preparedImageFiles,
        maxTokens: 2200,
        allowThinking: false,
        prompt: _visionPromptSynthesisPrompt(
          format: format,
          shot: shot,
          draft: draft,
          storyboardImageCount: storyboardImageFiles.length,
          assetReferences: assetReferences,
        ),
      );
      final normalized = _normalizeVisionPromptResult(refined);
      if (normalized.isEmpty) return prompt;
      raw[_promptKey(format)] = normalized;
      raw['selectedPromptFormat'] = format.name;
      raw['visionPromptSynthesis'] = {
        'format': format.name,
        'imageCount': imageFiles.length,
        'storyboardImageCount': storyboardImageFiles.length,
        'assetImageCount': assetReferences.length,
        'preparedImageCount': preparedImageFiles.length,
        'source': 'replicatedStoryboardAndAssets',
      };
      return prompt.copyWith(
        prompt: normalized,
        rawResponse: jsonEncode(raw),
        updatedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      raw['visionPromptSynthesisError'] = '$error';
      return prompt.copyWith(rawResponse: jsonEncode(raw));
    } finally {
      await _deleteVisionPromptImageDirectory(preparedDirectory);
    }
  }

  Future<List<File>> _prepareVisionPromptImages(
    List<File> imageFiles,
    Directory directory,
  ) async {
    final prepared = <File>[];
    for (var index = 0; index < imageFiles.length; index++) {
      prepared.add(
        await _prepareVisionPromptImage(
          imageFiles[index],
          directory: directory,
          index: index,
        ),
      );
    }
    return prepared;
  }

  Directory _visionPromptImageDirectory(String promptId) => Directory(
    p.join(
      _directories.temp.path,
      'vision_prompt_synthesis',
      _safeFileName(promptId),
    ),
  );

  Future<void> _deleteVisionPromptImageDirectory(Directory directory) async {
    if (!directory.existsSync()) return;
    final tempRoot = p.canonicalize(_directories.temp.absolute.path);
    final target = p.canonicalize(directory.absolute.path);
    if (!p.isWithin(tempRoot, target)) return;
    await directory.delete(recursive: true);
  }

  Future<File> _prepareVisionPromptImage(
    File file, {
    required Directory directory,
    required int index,
  }) async {
    if (!file.existsSync()) return file;
    final length = await file.length();
    if (length <= _visionPromptImageMaxBytes) return file;
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return file;
    var image = decoded;
    final maxSide = image.width > image.height ? image.width : image.height;
    if (maxSide > _visionPromptImageMaxDimension) {
      final scale = _visionPromptImageMaxDimension / maxSide;
      image = img.copyResize(
        image,
        width: (image.width * scale).round().clamp(1, image.width),
        height: (image.height * scale).round().clamp(1, image.height),
        interpolation: img.Interpolation.average,
      );
    }
    var quality = 84;
    var encoded = img.encodeJpg(image, quality: quality);
    while (encoded.length > _visionPromptImageMaxBytes && quality > 58) {
      quality -= 8;
      encoded = img.encodeJpg(image, quality: quality);
    }
    await directory.create(recursive: true);
    final output = File(p.join(directory.path, 'image-${index + 1}.jpg'));
    await output.writeAsBytes(encoded, flush: true);
    return output;
  }

  List<_VisionAssetReference> _visionPromptAssetReferences(
    String shotId, {
    required List<ReplicateAsset> fallbackAssets,
    required Set<String> selectedAssetIds,
  }) {
    final linked = _confirmedScriptAssets(shotId);
    final linkedReferences = [
      for (final asset in linked)
        if (_mediaKindForType(asset.type) == ReplicateMediaKind.image &&
            asset.path.trim().isNotEmpty &&
            File(asset.path).existsSync())
          _VisionAssetReference(
            type: asset.type,
            name: asset.name,
            description: asset.description,
            path: asset.path,
          ),
    ];
    if (linkedReferences.isNotEmpty) return linkedReferences;
    return [
      for (final asset in _readyAssets(fallbackAssets))
        if ((selectedAssetIds.isEmpty || selectedAssetIds.contains(asset.id)) &&
            _mediaKindForType(asset.type) == ReplicateMediaKind.image &&
            asset.path.trim().isNotEmpty &&
            File(asset.path).existsSync())
          _VisionAssetReference(
            type: asset.type,
            name: asset.name,
            description: asset.description,
            path: asset.path,
          ),
    ];
  }

  List<File> _replicatedPromptImageFiles({
    required ScriptShot shot,
    required List<ScriptShot> actionSequence,
  }) {
    final orderedShots = actionSequence.isEmpty ? [shot] : actionSequence;
    final files = <File>[];
    final seen = <String>{};
    for (final item in orderedShots) {
      final image = _replicatedImageForShot(item.id);
      if (image == null || image.status != ProcessingStatus.completed) {
        continue;
      }
      final path = image.generatedFramePath.trim();
      if (path.isEmpty || !seen.add(path)) continue;
      final file = File(path);
      if (file.existsSync()) files.add(file);
    }
    return files;
  }

  static String _visionPromptSynthesisPrompt({
    required ShotPromptFormat format,
    required ScriptShot shot,
    required String draft,
    required int storyboardImageCount,
    required List<_VisionAssetReference> assetReferences,
  }) {
    final storyboardRole = storyboardImageCount > 1
        ? '图片1-图片$storyboardImageCount 是复刻分镜图的首帧到尾帧'
        : '图片1 是本镜头的复刻分镜图';
    final assetStartIndex = storyboardImageCount + 1;
    final assetDefinitions = [
      for (var index = 0; index < assetReferences.length; index++)
        '图片${assetStartIndex + index} 是${_h3AssetRole(assetReferences[index].type)}：'
            '${_joinNonEmpty([assetReferences[index].name, assetReferences[index].description])}。',
    ];
    final assetRole = assetDefinitions.isEmpty
        ? '未提供额外绑定资产图；只允许使用复刻分镜图中真实可见且与草稿结构一致的主体/产品。'
        : '''
 绑定资产图：
 ${assetDefinitions.join('\n')}

 资产优先级硬规则：
 - 复刻分镜图只负责锁定镜头语言、姿态、动作阶段、空间关系、构图、光影和色彩氛围。
 - 人物身份、脸、发型、体型、服装轮廓、产品外观、材质、比例和使用关系，以绑定资产图为最高事实来源。
 - 若复刻分镜图里存在未绑定的包、首饰、帽子、眼镜、旧衣服、品牌字、Logo 或其他旧道具，且它们没有出现在绑定资产图定义中，必须删除，不得写入最终提示词。
 ''';
    return '''
你是视频生成提示词总编。请只基于当前附图和下方目标模型规则，把本地草稿归纳成一条可直接提交的视频生成提示词。

最高优先级视觉依据：
$storyboardRole。
$assetRole

目标视频模型：${_promptFormatLabel(format)}
目标格式模板：
${_promptFormatTemplate(format, shot)}

本地草稿（只作为素材编号、时长、声音和基础结构参考；其中可能混有原视频帧残留，必须清理）：
$draft

整理要求：
1. 严格按目标格式模板输出，不要混入其他模型的章节结构。
2. 删除草稿里未在绑定资产图出现的具体服装、手提包、首饰、眼镜、帽子、品牌字、Logo、字幕、包装文字和原视频道具描述；不要把复刻分镜图中未绑定的旧穿搭/旧道具写入提示词。
3. 若草稿存在重复章节、重复段落或多个完整提示词嵌套，只保留一套目标格式。
4. 保留复刻分镜图中的动作、构图、光影、色彩和空间关系；人物/产品/服装/道具外观以绑定资产图为准。
5. 保留必要的时长、镜号、音效和无字幕/无Logo/无水印约束。
6. 只输出最终提示词正文，不要解释、标题、Markdown、JSON 或分析过程。
''';
  }

  static String _promptFormatLabel(ShotPromptFormat format) => switch (format) {
    ShotPromptFormat.h3 => 'MiniMax H3',
    ShotPromptFormat.kling => '可灵',
    ShotPromptFormat.sd2 => '即梦',
  };

  static String _promptFormatTemplate(
    ShotPromptFormat format,
    ScriptShot shot,
  ) {
    final shotNumber = shot.shotNumber <= 0 ? 'N' : '${shot.shotNumber}';
    return switch (format) {
      ShotPromptFormat.h3 =>
        '''
【参考素材说明】
@图片1 是画面参考图，用于锁定复刻分镜图中的主体外观、产品、场景空间、构图、光影和整体视觉质感。

【核心创意】
一句话概括视频目标，只写当前复刻分镜图真实可见内容和整体风格。

【画面过程描述】
0-X秒：按时间描述主体动作、镜头运动、构图变化和产品展示。

【整体要求补充】
稳定主体外观、产品结构、动作方向、光源方向；不要字幕、不要水印、不要乱码文字、不要无关Logo。

【声音设计】
与画面动作同步的自然声或指定音效。

非叙事性音乐：N/A 或指定音乐。
''',
      ShotPromptFormat.kling =>
        '''
以图片1作为首帧和主体外观参考；主体与动作：只描述复刻分镜图中的主体、产品和动作；背景与运动：描述场景空间和运动趋势；镜头语言：景别、机位、运镜和构图；光影氛围：光线、色彩和质感；声音：必要音效；整体风格：广告质感；约束：不要字幕、不要Logo、不要水印、不要重复人物。
''',
      ShotPromptFormat.sd2 =>
        '''
主体与素材定义：用图片编号定义当前附图和绑定资产。

镜头$shotNumber：景别、运镜、时长、主体动作、产品展示、场景、构图、光影、色彩、声音。

全局风格：广告质感、细节丰富、色彩自然、光影层次清晰。

整体约束：保持主体外观、产品结构与场景连续稳定；保持无字幕，避免生成任何文字或字幕，不要生成 Logo，不要生成水印。
''',
    };
  }

  static String _normalizeVisionPromptResult(String value) {
    return value
        .trim()
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'^```(?:text|markdown)?\s*', multiLine: true), '')
        .replaceFirst(RegExp(r'\s*```$', multiLine: true), '')
        .trim();
  }

  ScriptShot _shotWithoutSourceVisualContent(ScriptShot shot) {
    String clean(String value) =>
        SeedancePromptGenerationService.stripSpecificWardrobeAndObjectDetails(
          value,
        );
    return shot.copyWith(
      visual: '',
      content: clean(shot.content),
      scene: clean(shot.scene),
      cameraNotes: clean(shot.cameraNotes),
      composition: clean(shot.composition),
      cameraAngle: clean(shot.cameraAngle),
      lightingMood: clean(shot.lightingMood),
      colorPalette: ScriptMultimodalAnalysisService.colorStyleFromPaletteText(
        shot.colorPalette,
      ),
      visualFocus: clean(shot.visualFocus),
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

  void _syncScriptPromptFields(List<ShotPrompt> prompts) {
    final promptsByShotId = <String, String>{
      for (final prompt in prompts)
        if ((prompt.scriptShotId ?? '').isNotEmpty &&
            prompt.status == ProcessingStatus.completed &&
            prompt.prompt.trim().isNotEmpty)
          prompt.scriptShotId!: prompt.prompt,
    };
    _shootingScriptController.updateShotPrompts(promptsByShotId);
  }

  void _persistStartEndPairs(
    List<StartEndFramePair> pairs, {
    required String message,
  }) {
    final run = value.run;
    if (run == null) return;
    final normalized = _normalizedStartEndPairs(pairs, value.shots);
    final updated = run.copyWith(
      startEndPairs: normalized,
      status: value.prompts.isEmpty ? run.status : ProcessingStatus.pending,
      composePromptsStatus: value.prompts.isEmpty
          ? run.composePromptsStatus
          : ProcessingStatus.pending,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(updated);
    if (value.prompts.isNotEmpty) {
      _repository.deletePrompts(run.id);
    }
    value = value.copyWith(
      run: updated,
      prompts: const [],
      message: message,
      errorMessage: '',
    );
  }

  StartEndFramePair? _pairContainingShot(String shotId) {
    final pairs = value.run?.startEndPairs ?? const <StartEndFramePair>[];
    final indexById = <String, int>{
      for (var index = 0; index < value.shots.length; index++)
        value.shots[index].id: index,
    };
    final targetIndex = indexById[shotId];
    if (targetIndex == null) return null;
    for (final pair in pairs) {
      final startIndex = indexById[pair.startShotId];
      final tailIndex = indexById[pair.tailShotId];
      if (startIndex == null || tailIndex == null) continue;
      if (targetIndex >= startIndex && targetIndex <= tailIndex) return pair;
    }
    return null;
  }

  List<StartEndFramePair> _normalizedStartEndPairs(
    List<StartEndFramePair> pairs,
    List<ScriptShot> shots,
  ) {
    final ordered = [...shots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final indexById = <String, int>{
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index,
    };
    final occupied = <int>{};
    final result = <StartEndFramePair>[];
    final sortedPairs = [...pairs]
      ..sort((first, second) {
        final firstIndex = indexById[first.startShotId] ?? 1 << 30;
        final secondIndex = indexById[second.startShotId] ?? 1 << 30;
        return firstIndex.compareTo(secondIndex);
      });
    for (final pair in sortedPairs) {
      final startIndex = indexById[pair.startShotId];
      final tailIndex = indexById[pair.tailShotId];
      if (startIndex == null || tailIndex == null || tailIndex <= startIndex) {
        continue;
      }
      var overlaps = false;
      for (var index = startIndex; index <= tailIndex; index++) {
        if (occupied.contains(index)) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) continue;
      result.add(pair);
      for (var index = startIndex; index <= tailIndex; index++) {
        occupied.add(index);
      }
    }
    return List.unmodifiable(result);
  }

  bool _sameStartEndPairs(
    List<StartEndFramePair> first,
    List<StartEndFramePair> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index].startShotId != second[index].startShotId ||
          first[index].tailShotId != second[index].tailShotId) {
        return false;
      }
    }
    return true;
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
    final images = _repository.listReplicatedShotImages(runId);
    final generatedRoot = _directories.generatedImages;
    if (!generatedRoot.existsSync()) {
      return images;
    }
    final filesByName = <String, File>{};
    for (final entity in generatedRoot.listSync(recursive: true)) {
      if (entity is File) {
        filesByName[p.basename(entity.path)] = entity;
      }
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
    final linked = _confirmedScriptAssets(shotId, scriptId: scriptId);
    if (_workflowRepository != null) {
      final references = [
        for (final asset in linked)
          if (_mediaKindForType(asset.type) == ReplicateMediaKind.image &&
              asset.path.trim().isNotEmpty &&
              File(asset.path).existsSync())
            _ReplacementReference(
              id: asset.id,
              type: asset.type,
              name: asset.name,
              description: asset.description,
              path: asset.path,
            ),
      ];
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
          ),
    ];
  }

  String? _fallbackReferenceShotIdFor(ScriptShot shot, ReplicateRun run) {
    if (!startEndFrameModeEnabled) return null;
    final sequence = const VideoActionSequenceResolver().manualSequenceFor(
      value.shots,
      run.startEndPairs,
      shot.id,
    );
    if (sequence.head.id == shot.id || !sequence.hasDistinctTail) return null;
    return sequence.head.id;
  }

  String _replacementPrompt(
    ScriptShot shot,
    List<_ReplacementReference> references, {
    VisionImageAnalysis? analysis,
  }) {
    final definitions = <String>[];
    final assetRequirements = <String>[];
    for (var index = 0; index < references.length; index++) {
      final reference = references[index];
      final imageLabel = '图片${index + 2}';
      final description = reference.description.trim().isEmpty
          ? ''
          : '，特征：${reference.description.trim()}';
      definitions.add(
        '$imageLabel 是${_replacementTypeLabel(reference.type)}“${reference.name}”$description。',
      );
      assetRequirements.add(switch (reference.type) {
        ReplicateAssetType.character =>
          '人物必须使用$imageLabel 中“${reference.name}”的身份、脸部、发型、体型、服装和外观；'
              '图片1中的原人物只可作为姿态、表情、视线和动作阶段基准，严禁复用其身份或外观。',
        ReplicateAssetType.product =>
          '产品必须使用$imageLabel 中“${reference.name}”的真实结构、无字包装造型、非标识性色块、纹理、材质、反光和比例；'
              '产品主体必须清晰可辨，边缘、表面材质和无字包装细节不得模糊、变形或被不合理遮挡；所有文字、Logo、商标及可识别品牌标记必须移除并自然重建；'
              '图片1中的原产品只可作为穿着方式、手部接触或摆放关系基准，严禁复用其外观。',
        ReplicateAssetType.scene =>
          '场景必须使用$imageLabel 中“${reference.name}”的环境元素；以图片1相同的镜位、透视、主体位置和空间层次重新搭建场景。',
        ReplicateAssetType.prop =>
          '道具必须使用$imageLabel 中“${reference.name}”的外观；保持图片1里的尺寸、朝向、遮挡和交互关系。',
        _ => '将$imageLabel 中“${reference.name}”作为新分镜的指定视觉元素使用。',
      });
    }
    return [
      '任务类型：基于参考重新创作一张清晰、可拍摄的全新分镜图，不是图片修复或高清重绘。',
      '图片1是原视频镜头 ${shot.shotNumber} 的结构蓝图，只用于分析镜头语言、画幅、机位、构图、透视、光影、色彩氛围和空间方向；禁止从图片1复用人物身份、服装款式、产品款式、道具外观、品牌包装或具体画面描述。',
      ...definitions,
      ...assetRequirements,
      '绑定资产硬约束：图片2起的每一张图片都是当前镜头明确绑定的指定素材，必须按其人物、产品、场景或道具角色使用；禁止遗漏任一绑定素材，也禁止以图片1中的同类人物、产品、场景或道具替代。',
      '从零开始生成新的高质量画面：重新渲染全部人物、服装、产品、背景、光影和细节。输出必须清晰锐利、细节完整、主体边缘干净、没有压缩噪点、运动模糊或低清纹理。',
      '严格复现图片1的画幅、景别、机位、构图、透视、主体数量、空间方向、视线方向、遮挡关系、光源方向、色温、景深和镜头承接。若同时提供人物、产品和场景参考，必须让该人物在该场景中穿着或使用该产品；人物服装、产品外观和道具样式始终以图片2起绑定资产为准。',
      '屏幕方向硬约束：以查看图片1时的画面左/右为唯一坐标系，不是人物自身左右，也不随图片2起素材的朝向变化。必须保持主体在画面内的左右位置、脸部/身体/视线朝向、身体倾斜、肢体动作、道具朝向及相对位置；严禁水平镜像、左右颠倒、反向朝向或交换左右侧构图。若任何素材描述与此冲突，始终以图片1为准。',
      '色彩硬约束：以图片1的色彩风格、色温、明暗关系、对比度、光影层次和电影调色为唯一基准；新人物、产品、场景和道具必须融入该原帧色彩风格，任何通用风格描述都不得覆盖这一要求。',
      '绝对不要：超分辨率、锐化、去噪、修复、放大、以图生图描摹、保留原帧像素、复制原帧的模糊或瑕疵。',
      _textAndLogoExclusionConstraint,
      ..._shotStructureInstructions(shot),
      if (analysis != null) ..._visualStructureInstructions(analysis),
      '最终交付：一张自然真实、专业清晰、与原视频帧叙事和镜头语言一致，但从头新生成的复刻分镜图。',
    ].join('\n');
  }

  List<String> _shotStructureInstructions(ScriptShot shot) => [
    _visionInstruction('景别', shot.shotSize),
    _visionInstruction('构图', shot.composition),
    _visionInstruction('机位', shot.cameraAngle),
    _visionInstruction('运镜', shot.cameraMovement),
    _visionInstruction('光影与氛围', shot.lightingMood),
    _visionInstruction('色彩风格', shot.colorPalette),
    _visionInstruction('剪辑衔接', shot.transitionHint),
    _visionInstruction('摄影备注', shot.cameraNotes),
  ].where((instruction) => instruction.isNotEmpty).toList(growable: false);

  List<String> _visualStructureInstructions(VisionImageAnalysis analysis) => [
    '【视觉模型对原帧的结构维度解析】以下内容只用于锁定镜头语言、空间关系和运动趋势；不得把其中的原人物服装、产品款式、道具外观或品牌包装带入成图。',
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
    _visionInstruction(
      '光影与色彩',
      _joinVisionValues([analysis.lightingMood, analysis.colorPalette]),
    ),
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

  static bool _promptsAreStale({
    required List<ShotPrompt> prompts,
    required List<ScriptShot> shots,
    required List<String> confirmedShotIds,
    required List<ReplicateAsset> assets,
    Map<String, Set<String>> workflowAssetIdsByShot = const {},
  }) {
    if (prompts.length != confirmedShotIds.length) {
      return true;
    }
    final shotById = {for (final shot in shots) shot.id: shot};
    final readyAssetIds = {for (final asset in _readyAssets(assets)) asset.id};
    for (final prompt in prompts) {
      final shot = shotById[prompt.scriptShotId];
      if (shot == null || !confirmedShotIds.contains(shot.id)) {
        return true;
      }
      final expectedAssetIds = workflowAssetIdsByShot[shot.id] ?? readyAssetIds;
      if (prompt.shotNumber != shot.shotNumber ||
          prompt.assetIds.toSet().difference(expectedAssetIds).isNotEmpty ||
          expectedAssetIds.difference(prompt.assetIds.toSet()).isNotEmpty) {
        return true;
      }
      try {
        final raw = jsonDecode(prompt.rawResponse);
        if (raw is! Map ||
            raw['promptRulesVersion'] != _promptRulesVersion ||
            raw['shotFingerprint'] != _shotFingerprint(shot)) {
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
    'scene': shot.scene,
    'dialogue': shot.dialogue,
    'sound': shot.sound,
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
    return targetShots.any(
      (shot) => _confirmedScriptAssets(shot.id).isNotEmpty,
    );
  }

  List<ScriptAsset> _confirmedScriptAssets(String shotId, {String? scriptId}) {
    final repository = _workflowRepository;
    final selectedScriptId = scriptId ?? value.selectedScriptId;
    if (repository == null || selectedScriptId.isEmpty) return const [];
    final assetsById = {
      for (final asset in repository.listScriptAssets(selectedScriptId))
        asset.id: asset,
    };
    return [
      for (final link in repository.listLinksForShot(shotId))
        if (link.confirmed) ..._assetIfPresent(assetsById[link.scriptAssetId]),
    ];
  }

  static Iterable<ScriptAsset> _assetIfPresent(ScriptAsset? asset) {
    if (asset == null) return const [];
    return [asset];
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
    final result = <String, Set<String>>{};
    for (final shot in shots) {
      final ids = {
        for (final link in repository.listLinksForShot(shot.id))
          if (link.confirmed && validAssetIds.contains(link.scriptAssetId))
            link.scriptAssetId,
      };
      if (ids.isNotEmpty) result[shot.id] = ids;
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

  static String _promptId(String runId, String shotId) =>
      '$runId-prompt-$shotId';

  static String _promptKey(ShotPromptFormat format) => switch (format) {
    ShotPromptFormat.sd2 => 'sd2Prompt',
    ShotPromptFormat.kling => 'klingPrompt',
    ShotPromptFormat.h3 => 'h3Prompt',
  };

  _ComposePromptModelRule get _composePromptModelRule {
    final config = _settingsController.value.activeVideoGenerationApiConfig;
    if (config?.isHttpApi == true) {
      return const _ComposePromptModelRule(
        format: ShotPromptFormat.h3,
        label: 'MiniMax H3',
        maxConcurrent: defaultComposePromptConcurrency,
      );
    }
    return const _ComposePromptModelRule(
      format: ShotPromptFormat.kling,
      label: '可灵',
      maxConcurrent: klingComposePromptConcurrency,
    );
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
    List<ReplicateAsset> assets,
  ) {
    var imageNumber = 2;
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
    List<ScriptAsset> assets,
  ) {
    var imageNumber = 2;
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
    ReplicateStep.confirmShots => '步骤 1：确认脚本',
    ReplicateStep.prepareAssets => '步骤 2：准备素材',
    ReplicateStep.composePrompts => '步骤 3：生成提示词',
    ReplicateStep.generateVideos => '步骤 4：生成视频',
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
  });

  final String id;
  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
}

class _VisionAssetReference {
  const _VisionAssetReference({
    required this.type,
    required this.name,
    required this.description,
    required this.path,
  });

  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
}
