import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../domain/api_endpoint_normalizer.dart';
import '../domain/app_settings.dart';
import '../domain/image_generation_api_config.dart';
import '../domain/video_generation_api_config.dart';
import '../domain/vision_api_config.dart';
import '../../storyboard/domain/image_generation_model_catalog.dart';

class SettingsController extends ValueNotifier<AppSettings> {
  SettingsController({
    required SettingsRepository repository,
    required AppSettings initialSettings,
  }) : _repository = repository,
       super(initialSettings);

  final SettingsRepository _repository;

  Future<void> setExportDirectory(String path) async {
    final next = value.copyWith(exportDirectory: path);
    _repository.save(next);
    value = next;
  }

  Future<void> setThemePreference(AppThemePreference preference) async {
    final next = value.copyWith(themePreference: preference);
    _repository.save(next);
    value = next;
  }

  Future<void> setNavigationPosition(AppNavigationPosition position) async {
    final next = value.copyWith(navigationPosition: position);
    _repository.save(next);
    value = next;
  }

  Future<void> setVideoAnalysisSettings({
    required String ffmpegExecutable,
    required String ffprobeExecutable,
    required VideoFrameExtractionStrategy extractionStrategy,
    required double frameIntervalSeconds,
    required double sceneThreshold,
    required double minimumSharpness,
    required double previewPaddingSeconds,
    required bool thinkingEnabled,
  }) async {
    final next = value.copyWith(
      ffmpegExecutable: ffmpegExecutable.trim().isEmpty
          ? 'ffmpeg'
          : ffmpegExecutable.trim(),
      ffprobeExecutable: ffprobeExecutable.trim().isEmpty
          ? 'ffprobe'
          : ffprobeExecutable.trim(),
      videoFrameExtractionStrategy: extractionStrategy,
      videoFrameIntervalSeconds: frameIntervalSeconds.clamp(0.1, 60).toDouble(),
      videoSceneThreshold: sceneThreshold.clamp(0.05, 0.95).toDouble(),
      videoMinimumSharpness: minimumSharpness.clamp(0, 1).toDouble(),
      videoPreviewPaddingSeconds: previewPaddingSeconds
          .clamp(0.1, 30)
          .toDouble(),
      videoAnalysisThinkingEnabled: thinkingEnabled,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setVideoAnalysisThinkingEnabled(bool enabled) async {
    final next = value.copyWith(videoAnalysisThinkingEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setVideoAnalysisMultiDimensionEnabled(bool enabled) async {
    final next = value.copyWith(videoAnalysisMultiDimensionEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setVideoAnalysisShotDetailsEnabled(bool enabled) async {
    final next = value.copyWith(videoAnalysisShotDetailsEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setReplicatePromptDefaults({
    required String globalStyle,
    required String constraints,
  }) async {
    final next = value.copyWith(
      replicateDefaultGlobalStyle: globalStyle.trim().isEmpty
          ? AppSettings.defaultReplicateGlobalStyle
          : globalStyle.trim(),
      replicateDefaultConstraints: constraints.trim().isEmpty
          ? AppSettings.defaultReplicateConstraints
          : constraints.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setH3PromptStyleId(String styleId) async {
    final normalized = styleId.trim().isEmpty
        ? AppSettings.defaultH3PromptStyleId
        : styleId.trim();
    final next = value.copyWith(h3PromptStyleId: normalized);
    _repository.save(next);
    value = next;
  }

  Future<void> setCutImageNumberEnabled(bool enabled) async {
    final next = value.copyWith(cutImageNumberEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setCutImageNumberPosition(
    CutImageNumberPosition position,
  ) async {
    final next = value.copyWith(cutImageNumberPosition: position);
    _repository.save(next);
    value = next;
  }

  Future<void> setCutImageNumberBackgroundOpacity(double opacity) async {
    final next = value.copyWith(cutImageNumberBackgroundOpacity: opacity);
    _repository.save(next);
    value = next;
  }

  void previewCutImageNumberBackgroundOpacity(double opacity) {
    value = value.copyWith(cutImageNumberBackgroundOpacity: opacity);
  }

  Future<void> setCutImageNumberTextScale(double scale) async {
    final next = value.copyWith(cutImageNumberTextScale: scale);
    _repository.save(next);
    value = next;
  }

  void previewCutImageNumberTextScale(double scale) {
    value = value.copyWith(cutImageNumberTextScale: scale);
  }

  Future<void> setStoryboardCaptionNumberEnabled(bool enabled) async {
    final next = value.copyWith(storyboardCaptionNumberEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setStoryboardSummaryPageEnabled(bool enabled) async {
    final next = value.copyWith(storyboardSummaryPageEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setVisionApiBaseUrl(String baseUrl) async {
    await setVisionSettings(
      baseUrl: baseUrl,
      apiKey: value.visionApiKey,
      model: value.visionModel,
    );
  }

  Future<void> setVisionApiKey(String apiKey) async {
    await setVisionSettings(
      baseUrl: value.visionApiBaseUrl,
      apiKey: apiKey,
      model: value.visionModel,
    );
  }

  Future<void> setVisionModel(String model) async {
    await setVisionSettings(
      baseUrl: value.visionApiBaseUrl,
      apiKey: value.visionApiKey,
      model: model,
    );
  }

  Future<void> setVisionSettings({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final activeId = value.activeVisionApiConfigId;
    final configs = [
      for (final config in value.visionApiConfigs)
        if (config.id == activeId)
          config.copyWith(
            baseUrl: baseUrl.trim(),
            apiKey: apiKey.trim(),
            model: model.trim(),
          )
        else
          config,
    ];
    final active = configs.firstWhere(
      (config) => config.id == activeId,
      orElse: () => VisionApiConfig(
        id: 'vision-${DateTime.now().microsecondsSinceEpoch}',
        name: '当前视觉模型',
        baseUrl: baseUrl.trim(),
        apiKey: apiKey.trim(),
        model: model.trim(),
      ),
    );
    final next = value.copyWith(
      visionApiBaseUrl: active.baseUrl,
      visionApiKey: active.apiKey,
      visionModel: active.model,
      visionApiConfigs: configs.isEmpty ? [active] : configs,
      activeVisionApiConfigId: active.id,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> saveVisionApiConfig(VisionApiConfig config) async {
    final existing = value.visionApiConfigs.any((item) => item.id == config.id);
    final configs = [
      for (final item in value.visionApiConfigs)
        if (item.id == config.id) config else item,
      if (!existing) config,
    ];
    final isActive =
        value.activeVisionApiConfigId.isEmpty ||
        value.activeVisionApiConfigId == config.id;
    final next = value.copyWith(
      visionApiConfigs: configs,
      activeVisionApiConfigId: isActive
          ? config.id
          : value.activeVisionApiConfigId,
      visionApiBaseUrl: isActive
          ? config.baseUrl.trim()
          : value.visionApiBaseUrl,
      visionApiKey: isActive ? config.apiKey.trim() : value.visionApiKey,
      visionModel: isActive ? config.model.trim() : value.visionModel,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setActiveVisionApiConfig(String configId) async {
    final config = value.visionApiConfigs.firstWhere(
      (item) => item.id == configId,
      orElse: () => throw ArgumentError.value(configId, 'configId'),
    );
    final next = value.copyWith(
      activeVisionApiConfigId: config.id,
      visionApiBaseUrl: config.baseUrl.trim(),
      visionApiKey: config.apiKey.trim(),
      visionModel: config.model.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setFullAutomationEnabled(bool enabled) async {
    final next = value.copyWith(fullAutomationEnabled: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setVisionApiConfigMaxRequestsPerMinute(
    String configId,
    int maxRequestsPerMinute,
  ) async {
    final normalized = maxRequestsPerMinute.clamp(1, 200);
    final configs = [
      for (final config in value.visionApiConfigs)
        if (config.id == configId)
          config.copyWith(maxRequestsPerMinute: normalized)
        else
          config,
    ];
    if (configs.length == value.visionApiConfigs.length &&
        !configs.any((config) => config.id == configId)) {
      return;
    }
    final active = configs.firstWhere(
      (config) => config.id == value.activeVisionApiConfigId,
      orElse: () => configs.first,
    );
    final next = value.copyWith(
      visionApiConfigs: configs,
      visionApiBaseUrl: active.baseUrl.trim(),
      visionApiKey: active.apiKey.trim(),
      visionModel: active.model.trim(),
      activeVisionApiConfigId: active.id,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> deleteVisionApiConfig(String configId) async {
    if (value.visionApiConfigs.length <= 1) {
      return;
    }
    final configs = value.visionApiConfigs
        .where((item) => item.id != configId)
        .toList();
    final active = configs.firstWhere(
      (item) => item.id == value.activeVisionApiConfigId,
      orElse: () => configs.first,
    );
    final next = value.copyWith(
      visionApiConfigs: configs,
      activeVisionApiConfigId: active.id,
      visionApiBaseUrl: active.baseUrl.trim(),
      visionApiKey: active.apiKey.trim(),
      visionModel: active.model.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> saveImageGenerationApiConfig(
    ImageGenerationApiConfig config,
  ) async {
    final descriptor = ImageGenerationCatalog.descriptorFor(config.model);
    if (descriptor == null) {
      throw FormatException('请选择支持的图片生成模型');
    }
    final normalized = config.copyWith(
      name: config.name.trim().isEmpty ? '未命名图片生成 API' : config.name.trim(),
      baseUrl: descriptor.protocol == ImageGenerationProviderProtocol.apiMart
          ? ApiEndpointNormalizer.normalizeApiMartBaseUrl(config.baseUrl)
          : config.baseUrl.trim(),
      apiKey: config.apiKey.trim(),
      model: config.model.trim(),
    );
    final exists = value.imageGenerationApiConfigs.any(
      (item) => item.id == normalized.id,
    );
    final configs = [
      for (final item in value.imageGenerationApiConfigs)
        if (item.id == normalized.id) normalized else item,
      if (!exists) normalized,
    ];
    final activeId = exists
        ? value.activeImageGenerationApiConfigId
        : normalized.id;
    final active = configs.firstWhere(
      (item) => item.id == activeId,
      orElse: () => configs.first,
    );
    final next = _withActiveImageGenerationConfig(
      value.copyWith(imageGenerationApiConfigs: configs),
      active,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setActiveImageGenerationApiConfig(String configId) async {
    final config = value.imageGenerationApiConfigs.firstWhere(
      (item) => item.id == configId,
      orElse: () => throw ArgumentError.value(configId, 'configId'),
    );
    final next = _withActiveImageGenerationConfig(value, config);
    _repository.save(next);
    value = next;
  }

  Future<void> deleteImageGenerationApiConfig(String configId) async {
    if (value.imageGenerationApiConfigs.length <= 1) return;
    final configs = value.imageGenerationApiConfigs
        .where((item) => item.id != configId)
        .toList();
    final active = configs.firstWhere(
      (item) => item.id == value.activeImageGenerationApiConfigId,
      orElse: () => configs.first,
    );
    final next = _withActiveImageGenerationConfig(
      value.copyWith(imageGenerationApiConfigs: configs),
      active,
    );
    _repository.save(next);
    value = next;
  }

  AppSettings _withActiveImageGenerationConfig(
    AppSettings settings,
    ImageGenerationApiConfig config,
  ) {
    return switch (config.protocol) {
      ImageGenerationProviderProtocol.grsai => settings.copyWith(
        activeImageGenerationApiConfigId: config.id,
        imageGenerationModel: config.model,
        imageGenerationApiBaseUrl: config.baseUrl,
        imageGenerationApiKey: config.apiKey,
      ),
      ImageGenerationProviderProtocol.gemini => settings.copyWith(
        activeImageGenerationApiConfigId: config.id,
        imageGenerationModel: config.model,
        imageGenerationGeminiApiBaseUrl: config.baseUrl,
        imageGenerationGeminiApiKey: config.apiKey,
      ),
      ImageGenerationProviderProtocol.apiMart => settings.copyWith(
        activeImageGenerationApiConfigId: config.id,
        imageGenerationModel: config.model,
        imageGenerationApiMartApiBaseUrl: config.baseUrl,
        imageGenerationApiMartApiKey: config.apiKey,
      ),
      null => throw FormatException('图片生成 API 卡片的模型不受支持'),
    };
  }

  Future<void> setImageGenerationApiBaseUrl(String baseUrl) async {
    final next = value.copyWith(imageGenerationApiBaseUrl: baseUrl.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationApiKey(String apiKey) async {
    final next = value.copyWith(imageGenerationApiKey: apiKey.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationGeminiApiKey(String apiKey) async {
    final next = value.copyWith(imageGenerationGeminiApiKey: apiKey.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationGeminiApiBaseUrl(String baseUrl) async {
    final next = value.copyWith(
      imageGenerationGeminiApiBaseUrl: baseUrl.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationApiMartApiKey(String apiKey) async {
    final next = value.copyWith(imageGenerationApiMartApiKey: apiKey.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationApiMartApiBaseUrl(String baseUrl) async {
    final next = value.copyWith(
      imageGenerationApiMartApiBaseUrl:
          ApiEndpointNormalizer.normalizeApiMartBaseUrl(baseUrl),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationGrsaiSettings({
    required String baseUrl,
    required String apiKey,
  }) async {
    final next = value.copyWith(
      imageGenerationApiBaseUrl: baseUrl.trim(),
      imageGenerationApiKey: apiKey.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationGeminiSettings({
    required String baseUrl,
    required String apiKey,
  }) async {
    final next = value.copyWith(
      imageGenerationGeminiApiBaseUrl: baseUrl.trim(),
      imageGenerationGeminiApiKey: apiKey.trim(),
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationApiMartSettings({
    required String baseUrl,
    required String apiKey,
  }) async {
    final normalizedBaseUrl = ApiEndpointNormalizer.normalizeApiMartBaseUrl(
      baseUrl,
    );
    final next = value.copyWith(
      imageGenerationApiMartApiBaseUrl: normalizedBaseUrl,
      imageGenerationApiMartApiKey: apiKey.trim(),
      imageGenerationApiConfigs: [
        for (final config in value.imageGenerationApiConfigs)
          if (config.protocol == ImageGenerationProviderProtocol.apiMart)
            config.copyWith(baseUrl: normalizedBaseUrl, apiKey: apiKey.trim())
          else
            config,
      ],
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationModel(String model) async {
    final next = value.copyWith(imageGenerationModel: model.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setImageGenerationSettings({
    required String baseUrl,
    required String grsaiApiKey,
    String? geminiBaseUrl,
    required String geminiApiKey,
    String? apiMartBaseUrl,
    String? apiMartApiKey,
    required String model,
  }) async {
    final normalizedModel = model.trim();
    final descriptor = ImageGenerationCatalog.descriptorFor(normalizedModel);
    final matchingConfigIndex = descriptor == null
        ? -1
        : value.imageGenerationApiConfigs.indexWhere(
            (config) => config.protocol == descriptor.protocol,
          );
    final configs = [...value.imageGenerationApiConfigs];
    for (var index = 0; index < configs.length; index++) {
      final current = configs[index];
      configs[index] = switch (current.protocol) {
        ImageGenerationProviderProtocol.gemini => current.copyWith(
          baseUrl: geminiBaseUrl?.trim() ?? current.baseUrl,
          apiKey: geminiApiKey.trim(),
          model: descriptor?.protocol == ImageGenerationProviderProtocol.gemini
              ? normalizedModel
              : current.model,
        ),
        ImageGenerationProviderProtocol.apiMart => current.copyWith(
          baseUrl: apiMartBaseUrl == null
              ? current.baseUrl
              : ApiEndpointNormalizer.normalizeApiMartBaseUrl(apiMartBaseUrl),
          apiKey: apiMartApiKey?.trim() ?? current.apiKey,
          model: descriptor?.protocol == ImageGenerationProviderProtocol.apiMart
              ? normalizedModel
              : current.model,
        ),
        ImageGenerationProviderProtocol.grsai => current.copyWith(
          baseUrl: baseUrl.trim(),
          apiKey: grsaiApiKey.trim(),
          model: descriptor?.protocol == ImageGenerationProviderProtocol.grsai
              ? normalizedModel
              : current.model,
        ),
        null => current,
      };
    }
    var next = value.copyWith(
      imageGenerationApiBaseUrl: baseUrl.trim(),
      imageGenerationApiKey: grsaiApiKey.trim(),
      imageGenerationGeminiApiBaseUrl: geminiBaseUrl?.trim(),
      imageGenerationGeminiApiKey: geminiApiKey.trim(),
      imageGenerationApiMartApiBaseUrl: apiMartBaseUrl == null
          ? null
          : ApiEndpointNormalizer.normalizeApiMartBaseUrl(apiMartBaseUrl),
      imageGenerationApiMartApiKey: apiMartApiKey?.trim(),
      imageGenerationModel: normalizedModel,
      imageGenerationApiConfigs: configs,
    );
    if (matchingConfigIndex >= 0) {
      next = _withActiveImageGenerationConfig(
        next,
        configs[matchingConfigIndex],
      );
    }
    _repository.save(next);
    value = next;
  }

  Future<void> saveVideoGenerationApiConfig(
    VideoGenerationApiConfig config,
  ) async {
    final normalized = switch (config.kind) {
      VideoGenerationApiConfigKind.klingCli => config.copyWith(
        name: config.name.trim().isEmpty ? '可灵 CLI' : config.name.trim(),
        kind: VideoGenerationApiConfigKind.klingCli,
        baseUrl: '',
        apiKey: '',
        model: AppSettings.defaultKlingCliVideoGenerationModel,
      ),
      VideoGenerationApiConfigKind.libTvCli => config.copyWith(
        name: config.name.trim().isEmpty
            ? 'LibTV CLI · 即梦 2.0'
            : config.name.trim(),
        kind: VideoGenerationApiConfigKind.libTvCli,
        baseUrl: '',
        apiKey: '',
        model: AppSettings.defaultLibTvCliVideoGenerationModel,
      ),
      VideoGenerationApiConfigKind.httpApi => config.copyWith(
        name: config.name.trim().isEmpty ? '未命名视频生成 API' : config.name.trim(),
        kind: VideoGenerationApiConfigKind.httpApi,
        baseUrl: config.baseUrl.trim(),
        apiKey: config.apiKey.trim(),
        model: config.model.trim().isEmpty
            ? AppSettings.defaultVideoGenerationModel
            : config.model.trim(),
      ),
    };
    final exists = value.videoGenerationApiConfigs.any(
      (item) => item.id == normalized.id,
    );
    final configs = [
      for (final item in value.videoGenerationApiConfigs)
        if (item.id == normalized.id) normalized else item,
      if (!exists) normalized,
    ];
    final activeId = exists
        ? value.activeVideoGenerationApiConfigId
        : normalized.id;
    final active = configs.firstWhere(
      (item) => item.id == activeId,
      orElse: () => configs.first,
    );
    final next = value.copyWith(
      videoGenerationApiConfigs: configs,
      activeVideoGenerationApiConfigId: active.id,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setActiveVideoGenerationApiConfig(String configId) async {
    final config = value.videoGenerationApiConfigs.firstWhere(
      (item) => item.id == configId,
      orElse: () => throw ArgumentError.value(configId, 'configId'),
    );
    final next = value.copyWith(activeVideoGenerationApiConfigId: config.id);
    _repository.save(next);
    value = next;
  }

  Future<void> setActiveKlingCliRegion(String region) async {
    final normalized = switch (region.trim()) {
      'china' => 'china',
      'global' => 'global',
      _ => '',
    };
    final active = value.activeVideoGenerationApiConfig;
    if (active == null || !active.isKlingCli) return;
    await saveVideoGenerationApiConfig(
      active.copyWith(klingCliRegion: normalized),
    );
  }

  Future<void> deleteVideoGenerationApiConfig(String configId) async {
    if (value.videoGenerationApiConfigs.length <= 1) return;
    if (configId == AppSettings.defaultKlingCliVideoGenerationConfigId ||
        configId == AppSettings.defaultLibTvCliVideoGenerationConfigId) {
      return;
    }
    final configs = value.videoGenerationApiConfigs
        .where((item) => item.id != configId)
        .toList();
    final active = configs.firstWhere(
      (item) => item.id == value.activeVideoGenerationApiConfigId,
      orElse: () => configs.first,
    );
    final next = value.copyWith(
      videoGenerationApiConfigs: configs,
      activeVideoGenerationApiConfigId: active.id,
    );
    _repository.save(next);
    value = next;
  }

  Future<void> setUpdateReleaseApiUrl(String apiUrl) async {
    final next = value.copyWith(updateReleaseApiUrl: apiUrl.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setAutoInstallUpdates(bool enabled) async {
    final next = value.copyWith(autoInstallUpdates: enabled);
    _repository.save(next);
    value = next;
  }

  Future<void> setUpdateDownloadMode(UpdateDownloadMode mode) async {
    final next = value.copyWith(updateDownloadMode: mode);
    _repository.save(next);
    value = next;
  }

  Future<void> setUpdateManualProxyUrl(String proxyUrl) async {
    final next = value.copyWith(updateManualProxyUrl: proxyUrl.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> resetToDefaults() async {
    final next = _repository.defaults();
    _repository.save(next);
    value = next;
  }
}
