import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../settings/application/settings_controller.dart';
import '../../shooting_script/domain/shooting_asset_library_models.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/data/shooting_script_workflow_repository.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../../storyboard/domain/image_generation_provider_resolver.dart';
import '../../story_design/domain/gemini_storyboard_prompt.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
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
  bool _replicationBatchActive = false;

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

  void refresh() => _restoreFromShootingScript();

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
    if (step.index >= ReplicateStep.composePrompts.index &&
        !_hasPromptAssets()) {
      value = value.copyWith(errorMessage: '请先添加至少一个可用参考素材', message: '');
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
      final result = await _generateReferenceImage(prompt, run.id);
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
        run.id,
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

  Future<bool> replicateShot(String shotId) async {
    if (_replicationBatchActive || value.isBusy) return false;
    final shot = _shotById(shotId);
    if (shot == null) return false;
    value = value.copyWith(
      isBusy: true,
      message: '正在提交镜头 ${shot.shotNumber} 的复刻任务…',
      errorMessage: '',
    );
    final succeeded = await _generateReplicatedShot(shot);
    if (!_disposed) {
      final error = _replicatedImageForShot(shot.id)?.errorMessage ?? '';
      value = value.copyWith(
        isBusy: false,
        message: succeeded ? '镜头 ${shot.shotNumber} 复刻完成' : '',
        errorMessage: succeeded ? '' : error,
      );
    }
    return succeeded;
  }

  Future<void> replicateAllShots({
    Duration stagger = const Duration(milliseconds: 450),
    int maxConcurrent = 3,
  }) async {
    if (_replicationBatchActive || value.isBusy) return;
    final shots = [...value.confirmedShots]
      ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
    if (shots.isEmpty) {
      value = value.copyWith(errorMessage: '当前脚本暂无可复刻的镜头', message: '');
      return;
    }
    _replicationBatchActive = true;
    value = value.copyWith(
      isBusy: true,
      message: '准备错峰提交 ${shots.length} 个复刻任务…',
      errorMessage: '',
    );
    final active = <Future<bool>>[];
    var completed = 0;
    var succeeded = 0;
    Future<bool> tracked(ScriptShot shot) async {
      final result = await _generateReplicatedShot(shot);
      completed++;
      if (result) succeeded++;
      if (!_disposed) {
        value = value.copyWith(
          message: '复刻进度 $completed/${shots.length}，成功 $succeeded 个',
        );
      }
      return result;
    }

    try {
      final concurrency = maxConcurrent.clamp(1, 6);
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
      _replicationBatchActive = false;
      if (!_disposed) {
        final failed = shots.length - succeeded;
        value = value.copyWith(
          isBusy: false,
          message: failed == 0 ? '已完成 ${shots.length} 个镜头复刻' : '',
          errorMessage: failed == 0 ? '' : '$failed 个镜头复刻失败，可单独重试',
        );
      }
    }
  }

  Future<bool> _generateReplicatedShot(ScriptShot shot) async {
    final run = value.run;
    if (run == null) return false;
    final original = File(shot.framePath);
    final references = _replacementReferences(shot.id);
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
        value = value.copyWith(
          message: '正在用视觉模型解析镜头 ${shot.shotNumber} 的画面维度…',
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
      return _generationPrompt(shot, references, model, analysis: analysis);
    } catch (_) {
      // 视觉模型不可用、超时或返回格式异常时，保留原有一键生成能力。
      return _generationPrompt(shot, references, model);
    }
  }

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

  Future<void> composeAllPrompts() async {
    final run = value.run;
    final shots = value.confirmedShots;
    final assets = _readyAssets(value.assets);
    if (run == null || shots.isEmpty || !_hasPromptAssets(shots: shots)) {
      value = value.copyWith(errorMessage: '需要可用镜头和参考素材', message: '');
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
      message: '正在生成 0/${shots.length} 个提示词…',
      errorMessage: '',
    );
    final prompts = <ShotPrompt>[];
    var completed = 0;
    for (var index = 0; index < shots.length; index++) {
      final shot = shots[index];
      final prompt = _composePrompt(
        run: running,
        shot: shot,
        assets: assets,
        previousShot: index > 0 ? shots[index - 1] : null,
        nextShot: index + 1 < shots.length ? shots[index + 1] : null,
      );
      prompts.add(prompt);
      if (prompt.status == ProcessingStatus.completed) {
        completed++;
      }
      if (!_disposed) {
        value = value.copyWith(
          prompts: [...prompts],
          message: '正在生成 ${prompts.length}/${shots.length} 个提示词…',
        );
      }
    }
    _repository.replacePrompts(run.id, prompts);
    final failed = prompts.length - completed;
    final finished = running.copyWith(
      status: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      composePromptsStatus: failed == 0
          ? ProcessingStatus.completed
          : ProcessingStatus.partial,
      completedCount: completed,
      totalCount: prompts.length,
      errorMessage: failed == 0 ? '' : '$failed 个镜头提示词生成失败',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertRun(finished);
    _syncScriptPromptFields(prompts);
    if (!_disposed) {
      value = value.copyWith(
        run: finished,
        prompts: prompts,
        isBusy: false,
        message: failed == 0 ? '已生成 ${prompts.length} 个 Seedance 2 提示词' : '',
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
      previousShot: shotIndex > 0 ? orderedShots[shotIndex - 1] : null,
      nextShot: shotIndex >= 0 && shotIndex + 1 < orderedShots.length
          ? orderedShots[shotIndex + 1]
          : null,
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
    final updated = value.prompts[index].copyWith(
      prompt: text.trim(),
      status: ProcessingStatus.completed,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertPrompt(updated);
    final prompts = [...value.prompts]..[index] = updated;
    _updatePromptProgress(run, prompts, message: '提示词已保存');
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
      final base = '${_safeFileName(script.name)}-Seedance2提示词';
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
    final prompts = _repository.listPrompts(run.id);
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
    }
    value = value.copyWith(
      scripts: scripts,
      shots: shooting.shots,
      selectedScriptId: scriptId,
      run: run,
      assets: assets,
      replicatedImages: replicatedImages,
      prompts: prompts,
      isBusy: false,
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
      isBusy: false,
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
    ScriptShot? previousShot,
    ScriptShot? nextShot,
  }) {
    try {
      final linkedAssets = _confirmedScriptAssets(shot.id);
      final result = linkedAssets.isNotEmpty
          ? _promptService.generateFromScriptAssets(
              shot: shot,
              assets: linkedAssets,
              globalStyle: run.globalStyle,
              constraints: run.constraints,
              previousShot: previousShot,
              nextShot: nextShot,
            )
          : _promptService.generate(
              shot: shot,
              assets: assets,
              globalStyle: run.globalStyle,
              constraints: run.constraints,
              previousShot: previousShot,
              nextShot: nextShot,
            );
      return ShotPrompt(
        id: _promptId(run.id, shot.id),
        runId: run.id,
        shotNumber: shot.shotNumber,
        scriptShotId: shot.id,
        assetIds: result.assetIds,
        prompt: result.prompt,
        model: promptModel,
        rawResponse: jsonEncode({
          'warnings': result.warnings,
          'shotFingerprint': _shotFingerprint(shot),
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

  void _saveReplicatedImage(ReplicatedShotImage image) {
    _repository.upsertReplicatedShotImage(image);
    if (_disposed) return;
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

  List<_ReplacementReference> _replacementReferences(String shotId) {
    final linked = _confirmedScriptAssets(shotId);
    if (_workflowRepository != null) {
      return [
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
    }
    return [
      for (final asset in _readyAssets(value.assets))
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
          '产品必须使用$imageLabel 中“${reference.name}”的真实结构、包装、图案、纹理、材质、反光、比例和品牌特征；'
              '产品主体必须清晰可辨，边缘、表面细节和包装信息不得模糊、变形或被不合理遮挡；'
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
      '图片1是原视频镜头 ${shot.shotNumber} 的语义蓝图，只用于分析画面元素、镜头语言、动作和空间关系；禁止把图片1当作底图、像素来源或纹理来源。',
      ...definitions,
      ...assetRequirements,
      '绑定资产硬约束：图片2起的每一张图片都是当前镜头明确绑定的指定素材，必须按其人物、产品、场景或道具角色使用；禁止遗漏任一绑定素材，也禁止以图片1中的同类人物、产品、场景或道具替代。',
      '从零开始生成新的高质量画面：重新渲染全部人物、服装、产品、背景、光影和细节。输出必须清晰锐利、细节完整、主体边缘干净、没有压缩噪点、运动模糊或低清纹理。',
      '严格复现图片1的画幅、景别、机位、构图、透视、主体数量、动作、表情、视线、遮挡、光源方向、色温、景深和叙事时刻。若同时提供人物、产品和场景参考，必须让该人物在该场景中穿着或使用该产品，并做出图片1相同动作。',
      '色彩硬约束：以图片1的色彩风格、色温、明暗关系、对比度、光影层次和电影调色为唯一基准；新人物、产品、场景和道具必须融入该原帧色彩风格，任何通用风格描述都不得覆盖这一要求。',
      '绝对不要：超分辨率、锐化、去噪、修复、放大、以图生图描摹、保留原帧像素、复制原帧的模糊或瑕疵；不要生成字幕、水印、额外 Logo 或无关文字。',
      if (shot.content.trim().isNotEmpty) '镜头内容：${shot.content.trim()}。',
      if (shot.shotSize.trim().isNotEmpty) '景别：${shot.shotSize.trim()}。',
      if (shot.composition.trim().isNotEmpty) '构图：${shot.composition.trim()}。',
      if (shot.cameraAngle.trim().isNotEmpty) '机位：${shot.cameraAngle.trim()}。',
      if (shot.lightingMood.trim().isNotEmpty)
        '光影与氛围：${shot.lightingMood.trim()}。',
      if (shot.colorPalette.trim().isNotEmpty)
        '色彩：${shot.colorPalette.trim()}。',
      if (shot.visualFocus.trim().isNotEmpty)
        '视觉焦点：${shot.visualFocus.trim()}。',
      if (shot.transitionHint.trim().isNotEmpty)
        '剪辑衔接：${shot.transitionHint.trim()}。',
      if (shot.cameraNotes.trim().isNotEmpty)
        '摄影备注：${shot.cameraNotes.trim()}。',
      if (analysis != null) ..._visualAnalysisInstructions(analysis),
      '最终交付：一张自然真实、专业清晰、与原视频帧叙事和镜头语言一致，但从头新生成的复刻分镜图。',
    ].join('\n');
  }

  List<String> _visualAnalysisInstructions(VisionImageAnalysis analysis) => [
    '【视觉模型对原帧的关键维度解析】以下内容是对图片1可见事实的补充，必须用于锁定新分镜的镜头语言和画面关系，不要擅自改变。',
    _visionInstruction('叙事画面', analysis.caption),
    _visionInstruction('画面细节', analysis.detail),
    _visionInstruction(
      '场景与空间',
      _joinVisionValues([analysis.scene, analysis.spatialRelation]),
    ),
    _visionInstruction(
      '人物、神态与动作',
      _joinVisionValues([
        analysis.people,
        analysis.expression,
        analysis.bodyAction,
        analysis.actionStage,
        analysis.movementTrend,
      ]),
    ),
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
      '视觉焦点与道具',
      _joinVisionValues([analysis.visualFocus, analysis.props]),
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
    String runId,
  ) async {
    final settings = _settingsController.value;
    final model = settings.imageGenerationModel;
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    if (descriptor == null) {
      throw FormatException('不支持的图片生成模型：$model');
    }
    final aspectRatio = descriptor.aspectRatios.contains('1:1')
        ? '1:1'
        : descriptor.aspectRatios.first;
    final resolutions = ImageGenerationCatalog.resolutionsFor(
      model,
      aspectRatio,
    );
    final imageSize = resolutions.firstWhere(
      (item) => item != 'auto',
      orElse: () => resolutions.first,
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
        quality: descriptor.qualities.first,
        referenceImagePaths: const [],
        outputDirectory: await _assetDirectory(runId),
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
        if (raw is! Map || raw['shotFingerprint'] != _shotFingerprint(shot)) {
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

  bool _hasPromptAssets({List<ScriptShot>? shots}) {
    if (_hasReadyAssets(value.assets)) return true;
    final targetShots = shots ?? value.confirmedShots;
    return targetShots.any(
      (shot) => _confirmedScriptAssets(shot.id).isNotEmpty,
    );
  }

  bool _hasWorkflowPromptAssets() {
    final targetShots = value.confirmedShots;
    return targetShots.any(
      (shot) => _confirmedScriptAssets(shot.id).isNotEmpty,
    );
  }

  List<ScriptAsset> _confirmedScriptAssets(String shotId) {
    final repository = _workflowRepository;
    final scriptId = value.selectedScriptId;
    if (repository == null || scriptId.isEmpty) return const [];
    final assetsById = {
      for (final asset in repository.listScriptAssets(scriptId))
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

  static String _replicatedImageId(String runId, String shotId) =>
      '$runId-replicated-$shotId';

  static String _stepLabel(ReplicateStep step) => switch (step) {
    ReplicateStep.confirmShots => '步骤 1：确认脚本',
    ReplicateStep.prepareAssets => '步骤 2：准备素材',
    ReplicateStep.composePrompts => '步骤 3：生成提示词',
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
