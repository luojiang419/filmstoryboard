import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../domain/api_endpoint_normalizer.dart';
import '../domain/app_settings.dart';

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
    final next = value.copyWith(visionApiBaseUrl: baseUrl.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setVisionApiKey(String apiKey) async {
    final next = value.copyWith(visionApiKey: apiKey.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setVisionModel(String model) async {
    final next = value.copyWith(visionModel: model.trim());
    _repository.save(next);
    value = next;
  }

  Future<void> setVisionSettings({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final next = value.copyWith(
      visionApiBaseUrl: baseUrl.trim(),
      visionApiKey: apiKey.trim(),
      visionModel: model.trim(),
    );
    _repository.save(next);
    value = next;
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
    final next = value.copyWith(
      imageGenerationApiMartApiBaseUrl:
          ApiEndpointNormalizer.normalizeApiMartBaseUrl(baseUrl),
      imageGenerationApiMartApiKey: apiKey.trim(),
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
    final next = value.copyWith(
      imageGenerationApiBaseUrl: baseUrl.trim(),
      imageGenerationApiKey: grsaiApiKey.trim(),
      imageGenerationGeminiApiBaseUrl: geminiBaseUrl?.trim(),
      imageGenerationGeminiApiKey: geminiApiKey.trim(),
      imageGenerationApiMartApiBaseUrl: apiMartBaseUrl == null
          ? null
          : ApiEndpointNormalizer.normalizeApiMartBaseUrl(apiMartBaseUrl),
      imageGenerationApiMartApiKey: apiMartApiKey?.trim(),
      imageGenerationModel: model.trim(),
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
