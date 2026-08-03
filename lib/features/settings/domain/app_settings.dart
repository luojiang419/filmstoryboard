import 'image_generation_api_config.dart';
import 'vision_api_config.dart';

enum AppThemePreference {
  system('跟随系统'),
  light('浅色'),
  dark('暗黑');

  const AppThemePreference(this.label);

  final String label;

  static AppThemePreference fromName(String? value) {
    return AppThemePreference.values.firstWhere(
      (preference) => preference.name == value,
      orElse: () => AppThemePreference.system,
    );
  }
}

enum AppNavigationPosition {
  bottom('底部'),
  left('左侧');

  const AppNavigationPosition(this.label);

  final String label;

  static AppNavigationPosition fromName(String? value) {
    return AppNavigationPosition.values.firstWhere(
      (position) => position.name == value,
      orElse: () => AppNavigationPosition.bottom,
    );
  }
}

enum VideoFrameExtractionStrategy {
  perFrame('逐帧'),
  sceneAndInterval('场景变化 + 间隔补帧'),
  intervalOnly('固定间隔'),
  highFidelity('高保真采样');

  const VideoFrameExtractionStrategy(this.label);

  final String label;

  static VideoFrameExtractionStrategy fromName(String? value) {
    return VideoFrameExtractionStrategy.values.firstWhere(
      (strategy) => strategy.name == value,
      orElse: () => VideoFrameExtractionStrategy.sceneAndInterval,
    );
  }
}

enum CutImageNumberPosition {
  topLeft('左上'),
  bottomLeft('左下'),
  topRight('右上'),
  bottomRight('右下'),
  center('中间');

  const CutImageNumberPosition(this.label);

  final String label;

  static CutImageNumberPosition fromName(String? value) {
    return CutImageNumberPosition.values.firstWhere(
      (position) => position.name == value,
      orElse: () => CutImageNumberPosition.topLeft,
    );
  }
}

enum UpdateDownloadMode {
  automatic('自动检测代理'),
  manual('手动代理'),
  direct('直连');

  const UpdateDownloadMode(this.label);

  final String label;

  static UpdateDownloadMode fromName(String? value) {
    return UpdateDownloadMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => UpdateDownloadMode.automatic,
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.exportDirectory,
    required this.themePreference,
    this.navigationPosition = AppNavigationPosition.bottom,
    this.ffmpegExecutable = 'ffmpeg',
    this.ffprobeExecutable = 'ffprobe',
    this.videoFrameExtractionStrategy =
        VideoFrameExtractionStrategy.sceneAndInterval,
    this.videoFrameIntervalSeconds = 1,
    this.videoSceneThreshold = 0.3,
    this.videoMinimumSharpness = 0.08,
    this.videoAnalysisThinkingEnabled = false,
    this.fullAutomationEnabled = false,
    this.replicateDefaultGlobalStyle = defaultReplicateGlobalStyle,
    this.replicateDefaultConstraints = defaultReplicateConstraints,
    required this.cutImageNumberEnabled,
    required this.cutImageNumberPosition,
    required this.cutImageNumberBackgroundOpacity,
    required this.cutImageNumberTextScale,
    this.storyboardCaptionNumberEnabled = true,
    required this.storyboardSummaryPageEnabled,
    required this.visionApiBaseUrl,
    required this.visionApiKey,
    required this.visionModel,
    this.visionApiConfigs = const [],
    this.activeVisionApiConfigId = '',
    required this.imageGenerationApiBaseUrl,
    required this.imageGenerationApiKey,
    this.imageGenerationGeminiApiBaseUrl =
        defaultImageGenerationGeminiApiBaseUrl,
    required this.imageGenerationGeminiApiKey,
    this.imageGenerationApiMartApiBaseUrl =
        defaultImageGenerationApiMartApiBaseUrl,
    this.imageGenerationApiMartApiKey = '',
    required this.imageGenerationModel,
    this.imageGenerationApiConfigs = const [],
    this.activeImageGenerationApiConfigId = '',
    required this.updateReleaseApiUrl,
    required this.autoInstallUpdates,
    required this.updateDownloadMode,
    required this.updateManualProxyUrl,
  });

  static const defaultCutImageNumberBackgroundOpacity = 0.5;
  static const defaultCutImageNumberTextScale = 1.0;
  static const defaultImageGenerationApiMartApiBaseUrl =
      'https://api.apimart.ai';
  static const defaultImageGenerationGeminiApiBaseUrl =
      'https://www.shiying-api.com';
  static const defaultReplicateGlobalStyle = '高清电影广告质感，细节丰富，色彩自然，光影层次清晰';
  static const defaultReplicateConstraints =
      '保持主体外观、服装、产品结构与场景连续稳定；人物面部和身体比例自然，动作连续，无卡顿、无闪烁、无穿模；保持无字幕，避免生成任何文字或字幕，不要生成 Logo，不要生成水印，不出现重复人物或同款分身';

  final String exportDirectory;
  final AppThemePreference themePreference;
  final AppNavigationPosition navigationPosition;
  final String ffmpegExecutable;
  final String ffprobeExecutable;
  final VideoFrameExtractionStrategy videoFrameExtractionStrategy;
  final double videoFrameIntervalSeconds;
  final double videoSceneThreshold;
  final double videoMinimumSharpness;
  final bool videoAnalysisThinkingEnabled;
  final bool fullAutomationEnabled;
  final String replicateDefaultGlobalStyle;
  final String replicateDefaultConstraints;
  final bool cutImageNumberEnabled;
  final CutImageNumberPosition cutImageNumberPosition;
  final double cutImageNumberBackgroundOpacity;
  final double cutImageNumberTextScale;
  final bool storyboardCaptionNumberEnabled;
  final bool storyboardSummaryPageEnabled;
  final String visionApiBaseUrl;
  final String visionApiKey;
  final String visionModel;
  final List<VisionApiConfig> visionApiConfigs;
  final String activeVisionApiConfigId;

  VisionApiConfig? get activeVisionApiConfig {
    for (final config in visionApiConfigs) {
      if (config.id == activeVisionApiConfigId) return config;
    }
    return visionApiConfigs.isEmpty ? null : visionApiConfigs.first;
  }

  int get visionMaxRequestsPerMinute =>
      activeVisionApiConfig?.maxRequestsPerMinute ?? 200;
  final String imageGenerationApiBaseUrl;
  final String imageGenerationApiKey;
  final String imageGenerationGeminiApiBaseUrl;
  final String imageGenerationGeminiApiKey;
  final String imageGenerationApiMartApiBaseUrl;
  final String imageGenerationApiMartApiKey;
  final String imageGenerationModel;
  final List<ImageGenerationApiConfig> imageGenerationApiConfigs;
  final String activeImageGenerationApiConfigId;

  ImageGenerationApiConfig? get activeImageGenerationApiConfig {
    for (final config in imageGenerationApiConfigs) {
      if (config.id == activeImageGenerationApiConfigId) return config;
    }
    return imageGenerationApiConfigs.isEmpty
        ? null
        : imageGenerationApiConfigs.first;
  }

  final String updateReleaseApiUrl;
  final bool autoInstallUpdates;
  final UpdateDownloadMode updateDownloadMode;
  final String updateManualProxyUrl;

  AppSettings copyWith({
    String? exportDirectory,
    AppThemePreference? themePreference,
    AppNavigationPosition? navigationPosition,
    String? ffmpegExecutable,
    String? ffprobeExecutable,
    VideoFrameExtractionStrategy? videoFrameExtractionStrategy,
    double? videoFrameIntervalSeconds,
    double? videoSceneThreshold,
    double? videoMinimumSharpness,
    bool? videoAnalysisThinkingEnabled,
    bool? fullAutomationEnabled,
    String? replicateDefaultGlobalStyle,
    String? replicateDefaultConstraints,
    bool? cutImageNumberEnabled,
    CutImageNumberPosition? cutImageNumberPosition,
    double? cutImageNumberBackgroundOpacity,
    double? cutImageNumberTextScale,
    bool? storyboardCaptionNumberEnabled,
    bool? storyboardSummaryPageEnabled,
    String? visionApiBaseUrl,
    String? visionApiKey,
    String? visionModel,
    List<VisionApiConfig>? visionApiConfigs,
    String? activeVisionApiConfigId,
    String? imageGenerationApiBaseUrl,
    String? imageGenerationApiKey,
    String? imageGenerationGeminiApiBaseUrl,
    String? imageGenerationGeminiApiKey,
    String? imageGenerationApiMartApiBaseUrl,
    String? imageGenerationApiMartApiKey,
    String? imageGenerationModel,
    List<ImageGenerationApiConfig>? imageGenerationApiConfigs,
    String? activeImageGenerationApiConfigId,
    String? updateReleaseApiUrl,
    bool? autoInstallUpdates,
    UpdateDownloadMode? updateDownloadMode,
    String? updateManualProxyUrl,
  }) {
    return AppSettings(
      exportDirectory: exportDirectory ?? this.exportDirectory,
      themePreference: themePreference ?? this.themePreference,
      navigationPosition: navigationPosition ?? this.navigationPosition,
      ffmpegExecutable: ffmpegExecutable ?? this.ffmpegExecutable,
      ffprobeExecutable: ffprobeExecutable ?? this.ffprobeExecutable,
      videoFrameExtractionStrategy:
          videoFrameExtractionStrategy ?? this.videoFrameExtractionStrategy,
      videoFrameIntervalSeconds:
          videoFrameIntervalSeconds ?? this.videoFrameIntervalSeconds,
      videoSceneThreshold: videoSceneThreshold ?? this.videoSceneThreshold,
      videoMinimumSharpness:
          videoMinimumSharpness ?? this.videoMinimumSharpness,
      videoAnalysisThinkingEnabled:
          videoAnalysisThinkingEnabled ?? this.videoAnalysisThinkingEnabled,
      fullAutomationEnabled:
          fullAutomationEnabled ?? this.fullAutomationEnabled,
      replicateDefaultGlobalStyle:
          replicateDefaultGlobalStyle ?? this.replicateDefaultGlobalStyle,
      replicateDefaultConstraints:
          replicateDefaultConstraints ?? this.replicateDefaultConstraints,
      cutImageNumberEnabled:
          cutImageNumberEnabled ?? this.cutImageNumberEnabled,
      cutImageNumberPosition:
          cutImageNumberPosition ?? this.cutImageNumberPosition,
      cutImageNumberBackgroundOpacity:
          cutImageNumberBackgroundOpacity ??
          this.cutImageNumberBackgroundOpacity,
      cutImageNumberTextScale:
          cutImageNumberTextScale ?? this.cutImageNumberTextScale,
      storyboardCaptionNumberEnabled:
          storyboardCaptionNumberEnabled ?? this.storyboardCaptionNumberEnabled,
      storyboardSummaryPageEnabled:
          storyboardSummaryPageEnabled ?? this.storyboardSummaryPageEnabled,
      visionApiBaseUrl: visionApiBaseUrl ?? this.visionApiBaseUrl,
      visionApiKey: visionApiKey ?? this.visionApiKey,
      visionModel: visionModel ?? this.visionModel,
      visionApiConfigs: visionApiConfigs ?? this.visionApiConfigs,
      activeVisionApiConfigId:
          activeVisionApiConfigId ?? this.activeVisionApiConfigId,
      imageGenerationApiBaseUrl:
          imageGenerationApiBaseUrl ?? this.imageGenerationApiBaseUrl,
      imageGenerationApiKey:
          imageGenerationApiKey ?? this.imageGenerationApiKey,
      imageGenerationGeminiApiBaseUrl:
          imageGenerationGeminiApiBaseUrl ??
          this.imageGenerationGeminiApiBaseUrl,
      imageGenerationGeminiApiKey:
          imageGenerationGeminiApiKey ?? this.imageGenerationGeminiApiKey,
      imageGenerationApiMartApiBaseUrl:
          imageGenerationApiMartApiBaseUrl ??
          this.imageGenerationApiMartApiBaseUrl,
      imageGenerationApiMartApiKey:
          imageGenerationApiMartApiKey ?? this.imageGenerationApiMartApiKey,
      imageGenerationModel: imageGenerationModel ?? this.imageGenerationModel,
      imageGenerationApiConfigs:
          imageGenerationApiConfigs ?? this.imageGenerationApiConfigs,
      activeImageGenerationApiConfigId:
          activeImageGenerationApiConfigId ??
          this.activeImageGenerationApiConfigId,
      updateReleaseApiUrl: updateReleaseApiUrl ?? this.updateReleaseApiUrl,
      autoInstallUpdates: autoInstallUpdates ?? this.autoInstallUpdates,
      updateDownloadMode: updateDownloadMode ?? this.updateDownloadMode,
      updateManualProxyUrl: updateManualProxyUrl ?? this.updateManualProxyUrl,
    );
  }
}
