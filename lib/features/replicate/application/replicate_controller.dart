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
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/domain/image_generation_provider_resolver.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/replicate_repository.dart';
import '../data/seedance_prompt_generation_service.dart';
import '../domain/replicate_models.dart';

final replicateControllerProvider = Provider<ReplicateController>(
  (ref) {
    final controller = ReplicateController(
      repository: ReplicateRepository(ref.watch(appDatabaseProvider)),
      shootingScriptController: ref.watch(shootingScriptControllerProvider),
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
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
    final ids = run?.confirmedShotIds.toSet() ?? const <String>{};
    return [
      for (final shot in shots)
        if (ids.contains(shot.id)) shot,
    ];
  }

  ReplicateState copyWith({
    List<ShootingScript>? scripts,
    List<ScriptShot>? shots,
    String? selectedScriptId,
    ReplicateRun? run,
    List<ReplicateAsset>? assets,
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
    prompts: prompts ?? this.prompts,
    isBusy: isBusy ?? this.isBusy,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class ReplicateExportResult {
  const ReplicateExportResult({required this.textFile, required this.jsonFile});

  final File textFile;
  final File jsonFile;
}

class ReplicateController extends ValueNotifier<ReplicateState> {
  ReplicateController({
    required ReplicateRepository repository,
    required ShootingScriptController shootingScriptController,
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    SeedancePromptGenerationService promptService =
        const SeedancePromptGenerationService(),
    ImageGenerationService? imageGenerationService,
    Uuid uuid = const Uuid(),
  }) : _repository = repository,
       _shootingScriptController = shootingScriptController,
       _directories = directories,
       _settingsController = settingsController,
       _promptService = promptService,
       _imageGenerationService =
           imageGenerationService ?? ImageGenerationService(),
       _ownsImageGenerationService = imageGenerationService == null,
       _uuid = uuid,
       super(const ReplicateState()) {
    _shootingScriptController.addListener(_handleShootingScriptChanged);
    _restoreFromShootingScript();
  }

  static const promptModel = 'Seedance 2';

  final ReplicateRepository _repository;
  final ShootingScriptController _shootingScriptController;
  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final SeedancePromptGenerationService _promptService;
  final ImageGenerationService _imageGenerationService;
  final bool _ownsImageGenerationService;
  final Uuid _uuid;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleShootingScriptChanged);
    if (_ownsImageGenerationService) {
      _imageGenerationService.close();
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
        value.confirmedShots.isEmpty) {
      value = value.copyWith(errorMessage: '请先确认至少一个脚本镜头', message: '');
      return false;
    }
    if (step.index >= ReplicateStep.composePrompts.index &&
        !_hasReadyAssets(value.assets)) {
      value = value.copyWith(errorMessage: '请先添加至少一个可用参考素材', message: '');
      return false;
    }
    final updated = run.copyWith(
      currentStep: step,
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

  Future<void> composeAllPrompts() async {
    final run = value.run;
    final shots = value.confirmedShots;
    final assets = _readyAssets(value.assets);
    if (run == null || shots.isEmpty || assets.isEmpty) {
      value = value.copyWith(errorMessage: '需要已确认镜头和可用参考素材', message: '');
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
    for (final shot in shots) {
      final prompt = _composePrompt(run: running, shot: shot, assets: assets);
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
    final updated = _composePrompt(
      run: run,
      shot: shot,
      assets: _readyAssets(value.assets),
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
      final textFile = _uniqueFile(_directories.prompts, '$base.txt');
      final jsonFile = File(p.setExtension(textFile.path, '.json'));
      final sorted = [
        ...value.prompts,
      ]..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
      await textFile.writeAsString(
        sorted
            .map((item) => '镜头 ${item.shotNumber}\n${item.prompt}')
            .join(
              '\n\n------------------------------------------------------------------------\n\n',
            ),
        flush: true,
      );
      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'script': {'id': script.id, 'name': script.name},
          'runId': run.id,
          'model': promptModel,
          'globalStyle': run.globalStyle,
          'constraints': run.constraints,
          'assets': [for (final asset in value.assets) _assetJson(asset)],
          'prompts': [for (final prompt in sorted) _promptJson(prompt)],
        }),
        flush: true,
      );
      value = value.copyWith(
        message: '已导出 TXT 与 JSON 到 ${_directories.prompts.path}',
        errorMessage: '',
      );
      return ReplicateExportResult(textFile: textFile, jsonFile: jsonFile);
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

  void _restoreFromShootingScript({String? selectScriptId}) {
    final shooting = _shootingScriptController.value;
    final scripts = shooting.scripts;
    if (scripts.isEmpty) {
      value = const ReplicateState();
      return;
    }
    final requested = selectScriptId ?? value.selectedScriptId;
    final scriptId = scripts.any((script) => script.id == requested)
        ? requested
        : shooting.selectedScriptId;
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
    final validIds = {for (final shot in shooting.shots) shot.id};
    final confirmedIds = [
      for (final id in run.confirmedShotIds)
        if (validIds.contains(id)) id,
    ];
    if (confirmedIds.length != run.confirmedShotIds.length) {
      run = run.copyWith(
        confirmedShotIds: confirmedIds,
        confirmShotsStatus: confirmedIds.isEmpty
            ? ProcessingStatus.pending
            : ProcessingStatus.completed,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertRun(run);
    }
    final assets = _repository.listAssets(run.id);
    final prompts = _repository.listPrompts(run.id);
    final normalizedRun = _normalizeReferenceCounts(run, assets);
    if (normalizedRun != run) {
      run = normalizedRun;
      _repository.upsertRun(run);
    }
    if (prompts.isNotEmpty &&
        _promptsAreStale(
          prompts: prompts,
          shots: shooting.shots,
          confirmedShotIds: confirmedIds,
          assets: assets,
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
  }) {
    try {
      final result = _promptService.generate(
        shot: shot,
        assets: assets,
        globalStyle: run.globalStyle,
        constraints: run.constraints,
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
      if (prompt.shotNumber != shot.shotNumber ||
          prompt.assetIds.toSet().difference(readyAssetIds).isNotEmpty ||
          readyAssetIds.difference(prompt.assetIds.toSet()).isNotEmpty) {
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

  static Map<String, Object?> _assetJson(ReplicateAsset asset) => {
    'id': asset.id,
    'type': asset.type.name,
    'reference': SeedancePromptGenerationService.referenceLabel(asset),
    'name': asset.name,
    'description': asset.description,
    'path': asset.path,
    'status': asset.status.name,
  };

  static Map<String, Object?> _promptJson(ShotPrompt prompt) => {
    'shotNumber': prompt.shotNumber,
    'scriptShotId': prompt.scriptShotId,
    'assetIds': prompt.assetIds,
    'prompt': prompt.prompt,
    'model': prompt.model,
    'status': prompt.status.name,
    'errorMessage': prompt.errorMessage,
  };
}
