import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/desktop_file_dialog_service.dart';
import '../../../core/services/workspace_directories.dart';
import '../../grid_cut/application/grid_cut_controller.dart';
import '../../projects/application/project_aspect_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/data/image_generation_diagnostic_logger.dart';
import '../../storyboard/domain/image_generation_provider_resolver.dart';
import '../data/story_design_preferences_repository.dart';
import '../data/story_design_result_repository.dart';
import '../domain/gemini_storyboard_prompt.dart';
import '../domain/story_design_grid_prompt.dart';
import '../domain/story_design_models.dart';

final storyDesignControllerProvider = Provider<StoryDesignController>(
  (ref) {
    final controller = StoryDesignController(
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      loadGridCutController: () => ref.read(gridCutControllerProvider),
      fileDialogService: ref.watch(desktopFileDialogServiceProvider),
      preferencesRepository: StoryDesignPreferencesRepository(
        ref.watch(appDatabaseProvider),
      ),
      projectAspectController: ref.watch(projectAspectControllerProvider),
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    projectDirectoriesProvider,
    gridCutControllerProvider,
    appDatabaseProvider,
    desktopFileDialogServiceProvider,
    projectAspectControllerProvider,
  ],
);

class StoryDesignController extends ValueNotifier<StoryDesignState> {
  StoryDesignController({
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    GridCutController? gridCutController,
    GridCutController Function()? loadGridCutController,
    DesktopFileDialogService? fileDialogService,
    StoryDesignPreferencesRepository? preferencesRepository,
    ProjectAspectController? projectAspectController,
    StoryDesignResultRepository? resultRepository,
    ImageGenerationService? imageGenerationService,
  }) : _directories = directories,
       _settingsController = settingsController,
       _loadGridCutController =
           loadGridCutController ?? (() => gridCutController!),
       _fileDialogService =
           fileDialogService ??
           DesktopFileDialogService(defaultDirectory: directories.imports),
       _ownsFileDialogService = fileDialogService == null,
       _preferencesRepository = preferencesRepository,
       _projectAspectController = projectAspectController,
       _resultRepository =
           resultRepository ?? StoryDesignResultRepository(directories),
       _imageGenerationService =
           imageGenerationService ??
           ImageGenerationService(
             diagnosticLogger: ImageGenerationDiagnosticLogger(
               directories.logs,
             ),
           ),
       _ownsImageGenerationService = imageGenerationService == null,
       super(
         _initialState(
           preferencesRepository: preferencesRepository,
           fallbackModel: settingsController.value.imageGenerationModel,
           projectAspectRatio:
               projectAspectController?.state.effectiveRatio.label ?? '16:9',
         ),
       ) {
    _projectAspectController?.addListener(_handleProjectAspectChanged);
    ready = _loadResults();
  }

  static const _imageTypes = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
  );
  static const _fallbackModel = 'nano-banana-fast';
  static const _batchOptions = [1, 2, 4, 6, 8];

  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final GridCutController Function() _loadGridCutController;
  late final Future<void> ready;
  bool _resultsLoaded = false;

  Future<void> _loadResults() async {
    try {
      final results = await _resultRepository.loadAsync(
        fallbackModel: value.model,
      );
      if (_disposed) return;
      _resultsLoaded = true;
      value = value.copyWith(
        results: results,
        message: results.isEmpty
            ? '输入提示词后生成设计分镜图'
            : '已恢复 ${results.length} 张设计分镜图',
      );
    } catch (error) {
      if (!_disposed) value = value.copyWith(message: '设计分镜图加载失败：$error');
    }
  }

  final DesktopFileDialogService _fileDialogService;
  final bool _ownsFileDialogService;
  final StoryDesignPreferencesRepository? _preferencesRepository;
  final ProjectAspectController? _projectAspectController;
  final StoryDesignResultRepository _resultRepository;
  final ImageGenerationService _imageGenerationService;
  final bool _ownsImageGenerationService;
  final _uuid = const Uuid();
  var _disposed = false;

  static List<int> get batchOptions => _batchOptions;
  static List<int> get gridOptions => storyDesignGridOptions;

  static List<String> aspectRatioOptionsFor(String model) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    if (descriptor?.isApiMart ?? false) {
      return descriptor!.aspectRatios;
    }
    if (GptImageGenerationPreset.isModel(model)) {
      return GptImageGenerationPreset.getAspectRatioOptions(model);
    }
    return ImageGenerationModelCatalog.defaultAspectRatios;
  }

  static List<String> imageSizeOptionsFor(String model, String aspectRatio) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    if (descriptor?.isApiMart ?? false) {
      return ImageGenerationModelCatalog.resolutionsFor(model, aspectRatio);
    }
    if (GptImageGenerationPreset.usesResolutionDropdown(model)) {
      return GptImageGenerationPreset.getImageSizeOptions(model, aspectRatio);
    }
    return ImageGenerationModelCatalog.defaultImageSizes;
  }

  static Map<String, String>? imageSizeLabelsFor(
    String model,
    String aspectRatio,
  ) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    if (descriptor?.isApiMart ?? false) {
      return {
        for (final resolution in imageSizeOptionsFor(model, aspectRatio))
          resolution: resolution == 'auto' ? '自动' : resolution,
      };
    }
    if (!GptImageGenerationPreset.usesResolutionDropdown(model)) {
      return null;
    }
    return GptImageGenerationPreset.getResolutionLabels(model, aspectRatio);
  }

  static bool supportsQuality(String model) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    return (descriptor?.isApiMart ?? false)
        ? descriptor!.supportsQuality
        : GptImageGenerationPreset.supportsQuality(model);
  }

  static List<String> qualityOptionsFor(String model) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    if (descriptor?.isApiMart ?? false) {
      return descriptor!.qualities;
    }
    return GptImageGenerationPreset.qualityOptions;
  }

  @override
  void dispose() {
    _disposed = true;
    _projectAspectController?.removeListener(_handleProjectAspectChanged);
    if (_ownsImageGenerationService) {
      _imageGenerationService.close();
    }
    if (_ownsFileDialogService) {
      _fileDialogService.dispose();
    }
    super.dispose();
  }

  void _handleProjectAspectChanged() {
    final projectAspectRatio =
        _projectAspectController?.state.effectiveRatio.label ?? '16:9';
    final normalized = _normalizeGenerationParams(
      model: value.model,
      aspectRatio: projectAspectRatio,
      imageSize: value.imageSize,
      quality: value.quality,
    );
    _setGenerationParameters(
      value.copyWith(
        aspectRatio: normalized.aspectRatio,
        imageSize: normalized.imageSize,
        quality: normalized.quality,
        message: '项目画幅已切换为 $projectAspectRatio',
      ),
    );
  }

  void setPrompt(String prompt) {
    value = value.copyWith(prompt: prompt);
  }

  void setModel(String model) {
    final normalizedModel = _normalizeModel(model);
    final normalized = _normalizeGenerationParams(
      model: normalizedModel,
      aspectRatio: value.aspectRatio,
      imageSize: value.imageSize,
      quality: value.quality,
    );
    _setGenerationParameters(
      value.copyWith(
        model: normalizedModel,
        aspectRatio: normalized.aspectRatio,
        imageSize: normalized.imageSize,
        quality: normalized.quality,
      ),
    );
  }

  void setAspectRatio(String aspectRatio) {
    final normalized = _normalizeGenerationParams(
      model: value.model,
      aspectRatio: aspectRatio,
      imageSize: value.imageSize,
      quality: value.quality,
    );
    _setGenerationParameters(
      value.copyWith(
        aspectRatio: normalized.aspectRatio,
        imageSize: normalized.imageSize,
        quality: normalized.quality,
      ),
    );
  }

  void setImageSize(String imageSize) {
    final normalized = _normalizeGenerationParams(
      model: value.model,
      aspectRatio: value.aspectRatio,
      imageSize: imageSize,
      quality: value.quality,
    );
    _setGenerationParameters(
      value.copyWith(
        aspectRatio: normalized.aspectRatio,
        imageSize: normalized.imageSize,
        quality: normalized.quality,
      ),
    );
  }

  void setQuality(String quality) {
    final normalized = _normalizeGenerationParams(
      model: value.model,
      aspectRatio: value.aspectRatio,
      imageSize: value.imageSize,
      quality: quality,
    );
    _setGenerationParameters(value.copyWith(quality: normalized.quality));
  }

  void setBatchCount(int count) {
    if (!_batchOptions.contains(count)) {
      return;
    }
    _setGenerationParameters(value.copyWith(batchCount: count));
  }

  void setGridCount(int count) {
    if (!storyDesignGridOptions.contains(count)) {
      return;
    }
    _setGenerationParameters(
      value.copyWith(
        gridCount: count,
        portraitGrid: count == storyDesignNoGridCount
            ? false
            : value.portraitGrid,
      ),
    );
  }

  void setPortraitGrid(bool enabled) {
    if (value.gridCount == storyDesignNoGridCount) {
      return;
    }
    _setGenerationParameters(value.copyWith(portraitGrid: enabled));
  }

  void _setGenerationParameters(StoryDesignState next) {
    value = next;
    _preferencesRepository?.save(
      StoryDesignGenerationPreferences(
        model: next.model,
        aspectRatio: next.aspectRatio,
        imageSize: next.imageSize,
        quality: next.quality,
        batchCount: next.batchCount,
        gridCount: next.gridCount,
        portraitGrid: next.portraitGrid,
      ),
    );
  }

  Future<void> pickReferenceImages() async {
    final files = await _fileDialogService.openFiles(
      source: 'story_design.pick_reference_images',
      acceptedTypeGroups: [_imageTypes],
      initialDirectory: _directories.imports.path,
      confirmButtonText: '添加参考图',
    );
    addReferencePaths(files.map((file) => file.path));
  }

  void addReferencePaths(Iterable<String> paths) {
    final existing = value.referenceImagePaths.toSet();
    final next = [...value.referenceImagePaths];
    var added = 0;
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || existing.contains(path) || !_isSupportedImage(path)) {
        continue;
      }
      if (!File(path).existsSync()) {
        continue;
      }
      existing.add(path);
      next.add(path);
      added++;
    }
    value = value.copyWith(
      referenceImagePaths: next,
      message: added == 0 ? '没有新增参考图' : '已添加 $added 张参考图',
    );
  }

  void removeReferencePath(String path) {
    value = value.copyWith(
      referenceImagePaths: [
        for (final item in value.referenceImagePaths)
          if (item != path) item,
      ],
      message: '已移除参考图',
    );
  }

  void clearReferencePaths() {
    if (value.referenceImagePaths.isEmpty) {
      return;
    }
    value = value.copyWith(referenceImagePaths: const [], message: '已清空参考图');
  }

  Future<void> generate() async {
    if (_disposed) return;
    final prompt = value.prompt.trim();
    if (prompt.isEmpty) {
      value = value.copyWith(message: '请先输入生成提示词');
      return;
    }

    final settings = _settingsController.value;
    final model = value.model;
    final provider = ImageGenerationProviderResolver.resolve(
      settings: settings,
      model: model,
    );
    final request = ImageGenerationRequest(
      provider: provider,
      model: model,
      prompt: usesGemini3ImagePrompting(model)
          ? buildGeminiStoryboardPrompt(
              buildGridPrompt(
                prompt,
                value.gridCount,
                portraitGrid: value.portraitGrid,
              ),
              hasReferenceImages: value.referenceImagePaths.isNotEmpty,
            )
          : buildGridPrompt(
              prompt,
              value.gridCount,
              portraitGrid: value.portraitGrid,
            ),
      aspectRatio: value.aspectRatio,
      imageSize: value.imageSize,
      quality: value.quality,
      referenceImagePaths: [...value.referenceImagePaths],
      outputDirectory: Directory(
        p.join(_directories.generatedImages.path, 'design'),
      ),
    );
    final total = value.batchCount;
    if (!_resultsLoaded) await ready;
    if (_disposed || !_resultsLoaded) return;
    final tasks = <StoryDesignGenerationTask>[
      for (var index = 0; index < total; index++)
        StoryDesignGenerationTask(
          id: _uuid.v4(),
          prompt: prompt,
          model: model,
          aspectRatio: request.aspectRatio,
          imageSize: request.imageSize,
          quality: request.quality,
          startedAt: DateTime.now(),
        ),
    ];
    value = value.copyWith(
      generationTasks: [...tasks.reversed, ...value.generationTasks],
      message: total == 1 ? '已提交 1 个生成任务' : '已提交 $total 个生成任务，将并发处理',
    );
    await Future.wait([
      for (final task in tasks) _runGenerationTask(task, request),
    ]);
  }

  Future<void> _runGenerationTask(
    StoryDesignGenerationTask task,
    ImageGenerationRequest request,
  ) async {
    try {
      final result = await _imageGenerationService.generateTextToImage(request);
      if (_disposed) {
        return;
      }
      final completedAt = DateTime.now();
      final item = StoryDesignResult(
        id: task.id,
        path: result.localPath,
        remoteUrl: result.remoteUrl,
        prompt: task.prompt,
        model: task.model,
        aspectRatio: task.aspectRatio,
        imageSize: task.imageSize,
        quality: task.quality,
        createdAt: completedAt,
        generationDuration: completedAt.difference(task.startedAt),
      );
      final nextTasks = [
        for (final current in value.generationTasks)
          if (current.id == task.id)
            current.copyWith(
              status: StoryDesignGenerationTaskStatus.succeeded,
              completedAt: completedAt,
              resultId: item.id,
            )
          else
            current,
      ];
      value = value.copyWith(
        generationTasks: nextTasks,
        results: [item, ...value.results],
        message: _taskProgressMessage(nextTasks),
      );
      _persistResults();
    } catch (error) {
      if (_disposed) {
        return;
      }
      final completedAt = DateTime.now();
      final errorMessage = _generationErrorMessage(error);
      final nextTasks = [
        for (final current in value.generationTasks)
          if (current.id == task.id)
            current.copyWith(
              status: StoryDesignGenerationTaskStatus.failed,
              completedAt: completedAt,
              errorMessage: errorMessage,
            )
          else
            current,
      ];
      value = value.copyWith(
        generationTasks: nextTasks,
        message: _taskProgressMessage(nextTasks, recentError: errorMessage),
      );
    }
  }

  static String buildGridPrompt(
    String prompt,
    int gridCount, {
    bool portraitGrid = false,
  }) {
    return buildStoryDesignGridPrompt(
      prompt,
      gridCount,
      portraitGrid: portraitGrid,
    );
  }

  void toggleResultSelection(String id, bool selected) {
    value = value.copyWith(
      results: [
        for (final result in value.results)
          if (result.id == id) result.copyWith(selected: selected) else result,
      ],
    );
    _persistResults();
  }

  void selectAllResults() {
    value = value.copyWith(
      results: [
        for (final result in value.results) result.copyWith(selected: true),
      ],
      message: '已全选生成结果',
    );
    _persistResults();
  }

  void clearResultSelection() {
    value = value.copyWith(
      results: [
        for (final result in value.results) result.copyWith(selected: false),
      ],
      message: '已取消选择',
    );
    _persistResults();
  }

  void removeResult(String id) {
    value = value.copyWith(
      results: [
        for (final result in value.results)
          if (result.id != id) result,
      ],
      generationTasks: [
        for (final task in value.generationTasks)
          if (task.resultId != id) task,
      ],
      message: '已移除生成结果',
    );
    _persistResults();
  }

  void dismissGenerationTask(String id) {
    StoryDesignGenerationTask? task;
    for (final item in value.generationTasks) {
      if (item.id == id) {
        task = item;
        break;
      }
    }
    if (task == null || task.isRunning) {
      return;
    }
    value = value.copyWith(
      generationTasks: [
        for (final item in value.generationTasks)
          if (item.id != id) item,
      ],
      message: '已移除任务记录',
    );
  }

  void clearResults() {
    if (value.results.isEmpty) {
      return;
    }
    final resultIds = value.results.map((result) => result.id).toSet();
    value = value.copyWith(
      results: const [],
      generationTasks: [
        for (final task in value.generationTasks)
          if (!resultIds.contains(task.resultId)) task,
      ],
      message: '已清空生成结果',
    );
    _persistResults();
  }

  void _persistResults() {
    _resultRepository.save(value.results);
  }

  Future<int> addSelectedToCutPage() async {
    final paths = value.selectedResultPaths
        .where((path) => File(path).existsSync())
        .toList();
    if (paths.isEmpty) {
      value = value.copyWith(message: '请先勾选要添加的生成图');
      return 0;
    }
    await _loadGridCutController().importPaths(paths);
    value = value.copyWith(message: '已添加 ${paths.length} 张图片到多宫格裁切页');
    return paths.length;
  }

  Future<void> openGeneratedDirectory() async {
    final directory = Directory(
      p.join(_directories.generatedImages.path, 'design'),
    );
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    await Process.start('explorer.exe', [directory.path]);
  }

  static String _normalizeModel(String model) {
    final trimmed = model.trim();
    if (ImageGenerationModelCatalog.values.contains(trimmed)) {
      return trimmed;
    }
    if (ImageGenerationModelCatalog.values.contains(_fallbackModel)) {
      return _fallbackModel;
    }
    return ImageGenerationModelCatalog.values.first;
  }

  static StoryDesignState _initialState({
    required StoryDesignPreferencesRepository? preferencesRepository,
    required String fallbackModel,
    required String projectAspectRatio,
  }) {
    final defaultModel = _normalizeModel(fallbackModel);
    final preferences =
        preferencesRepository?.load(fallbackModel: defaultModel) ??
        StoryDesignGenerationPreferences.defaults(model: defaultModel);
    final model = _normalizeModel(preferences.model);
    final normalized = _normalizeGenerationParams(
      model: model,
      aspectRatio: preferences.aspectRatio == 'auto'
          ? projectAspectRatio
          : preferences.aspectRatio,
      imageSize: preferences.imageSize,
      quality: preferences.quality,
    );
    final batchCount = _batchOptions.contains(preferences.batchCount)
        ? preferences.batchCount
        : _batchOptions.first;
    final gridCount = storyDesignGridOptions.contains(preferences.gridCount)
        ? preferences.gridCount
        : storyDesignNoGridCount;
    return StoryDesignState.initial(model: model).copyWith(
      aspectRatio: normalized.aspectRatio,
      imageSize: normalized.imageSize,
      quality: normalized.quality,
      batchCount: batchCount,
      gridCount: gridCount,
      portraitGrid:
          gridCount != storyDesignNoGridCount && preferences.portraitGrid,
      message: '正在加载设计分镜图...',
    );
  }

  static ({String aspectRatio, String imageSize, String quality})
  _normalizeGenerationParams({
    required String model,
    required String aspectRatio,
    required String imageSize,
    required String quality,
  }) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(model);
    if (descriptor?.isApiMart ?? false) {
      final normalizedAspectRatio = _normalizeCatalogOption(
        aspectRatio,
        descriptor!.aspectRatios,
      );
      return (
        aspectRatio: normalizedAspectRatio,
        imageSize: _normalizeCatalogOption(
          imageSize,
          ImageGenerationModelCatalog.resolutionsFor(
            model,
            normalizedAspectRatio,
          ),
        ),
        quality: descriptor.supportsQuality
            ? _normalizeCatalogOption(quality, descriptor.qualities)
            : 'auto',
      );
    }
    final normalizedQuality = GptImageGenerationPreset.normalizeQuality(
      quality,
    );
    if (GptImageGenerationPreset.isModel(model)) {
      final normalizedRatio = GptImageGenerationPreset.normalizeAspectRatio(
        aspectRatio,
      );
      return (
        aspectRatio: normalizedRatio,
        imageSize: GptImageGenerationPreset.normalizeImageSize(
          model: model,
          aspectRatio: normalizedRatio,
          value: imageSize,
        ),
        quality: normalizedQuality,
      );
    }

    final normalizedRatio =
        ImageGenerationModelCatalog.defaultAspectRatios.contains(aspectRatio)
        ? aspectRatio
        : 'auto';
    final normalizedSize = imageSize.trim().toUpperCase();
    return (
      aspectRatio: normalizedRatio,
      imageSize:
          ImageGenerationModelCatalog.defaultImageSizes.contains(normalizedSize)
          ? normalizedSize
          : ImageGenerationModelCatalog.defaultImageSizes.first,
      quality: normalizedQuality,
    );
  }

  static String _normalizeCatalogOption(String value, List<String> options) {
    final normalized = value.trim().toLowerCase();
    for (final option in options) {
      if (option.toLowerCase() == normalized) {
        return option;
      }
    }
    return options.first;
  }

  String _generationErrorMessage(Object error) {
    if (error is HttpException) {
      return error.message;
    }
    if (error is FormatException) {
      return error.message;
    }
    if (error is FileSystemException) {
      return error.message;
    }
    final text = error.toString().trim();
    return text.isEmpty ? '未知错误' : text;
  }

  String _taskProgressMessage(
    List<StoryDesignGenerationTask> tasks, {
    String recentError = '',
  }) {
    final active = tasks.where((task) => task.isRunning).length;
    if (active > 0) {
      return recentError.isEmpty
          ? '已完成 1 个任务，仍有 $active 个生成中'
          : '1 个任务失败，仍有 $active 个生成中：$recentError';
    }
    final succeeded = tasks.where((task) => task.isSucceeded).length;
    final failedTasks = tasks.where((task) => task.isFailed).toList();
    if (failedTasks.isEmpty) {
      return '生成任务已全部完成';
    }
    final error = recentError.isNotEmpty
        ? recentError
        : failedTasks.first.errorMessage;
    return '生成完成：成功 $succeeded 个，失败 ${failedTasks.length} 个；$error';
  }

  bool _isSupportedImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return const {'.png', '.jpg', '.jpeg', '.webp', '.bmp'}.contains(ext);
  }
}
