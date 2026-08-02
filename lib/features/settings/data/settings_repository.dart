import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/services/app_directories.dart';
import '../../updater/domain/app_update_config.dart';
import '../domain/app_settings.dart';

class SettingsRepository {
  const SettingsRepository(
    this._database,
    this._directories, {
    String? visionDefaultsText,
    String? imageGenerationDefaultsText,
  }) : _visionDefaultsText = visionDefaultsText,
       _imageGenerationDefaultsText = imageGenerationDefaultsText;

  final AppDatabase _database;
  final AppDirectories _directories;
  final String? _visionDefaultsText;
  final String? _imageGenerationDefaultsText;

  static const _exportDirectoryKey = 'exportDirectory';
  static const _themePreferenceKey = 'themePreference';
  static const _navigationPositionKey = 'navigationPosition';
  static const _ffmpegExecutableKey = 'ffmpegExecutable';
  static const _ffprobeExecutableKey = 'ffprobeExecutable';
  static const _videoFrameExtractionStrategyKey =
      'videoFrameExtractionStrategy';
  static const _videoFrameIntervalSecondsKey = 'videoFrameIntervalSeconds';
  static const _videoSceneThresholdKey = 'videoSceneThreshold';
  static const _videoMinimumSharpnessKey = 'videoMinimumSharpness';
  static const _videoAnalysisThinkingEnabledKey =
      'videoAnalysisThinkingEnabled';
  static const _replicateDefaultGlobalStyleKey = 'replicateDefaultGlobalStyle';
  static const _replicateDefaultConstraintsKey = 'replicateDefaultConstraints';
  static const _cutImageNumberEnabledKey = 'cutImageNumberEnabled';
  static const _cutImageNumberPositionKey = 'cutImageNumberPosition';
  static const _cutImageNumberBackgroundOpacityKey =
      'cutImageNumberBackgroundOpacity';
  static const _cutImageNumberTextScaleKey = 'cutImageNumberTextScale';
  static const _storyboardCaptionNumberEnabledKey =
      'storyboardCaptionNumberEnabled';
  static const _storyboardSummaryPageEnabledKey =
      'storyboardSummaryPageEnabled';
  static const _visionApiBaseUrlKey = 'visionApiBaseUrl';
  static const _visionApiKeyKey = 'visionApiKey';
  static const _visionModelKey = 'visionModel';
  static const _imageGenerationApiBaseUrlKey = 'imageGenerationApiBaseUrl';
  static const _imageGenerationApiKeyKey = 'imageGenerationApiKey';
  static const _imageGenerationGeminiApiBaseUrlKey =
      'imageGenerationGeminiApiBaseUrl';
  static const _imageGenerationGeminiApiKeyKey = 'imageGenerationGeminiApiKey';
  static const _imageGenerationApiMartApiBaseUrlKey =
      'imageGenerationApiMartApiBaseUrl';
  static const _imageGenerationApiMartApiKeyKey =
      'imageGenerationApiMartApiKey';
  static const _imageGenerationModelKey = 'imageGenerationModel';
  static const _updateReleaseApiUrlKey = 'updateReleaseApiUrl';
  static const _autoInstallUpdatesKey = 'autoInstallUpdates';
  static const _updateDownloadModeKey = 'updateDownloadMode';
  static const _updateManualProxyUrlKey = 'updateManualProxyUrl';
  static const _downloadedUpdateVersionKey = 'downloadedUpdateVersion';
  static const _pendingUpdateVersionKey = 'pendingUpdateVersion';
  static const _pendingUpdateInstallerPathKey = 'pendingUpdateInstallerPath';
  static const _dismissedUpdatePromptVersionKey =
      'dismissedUpdatePromptVersion';

  AppSettings load() {
    final visionDefaults = _loadVisionDefaults();
    final imageGenerationDefaults = _loadImageGenerationDefaults();
    return AppSettings(
      exportDirectory:
          _database.getSetting(_exportDirectoryKey) ??
          _directories.exports.path,
      themePreference: AppThemePreference.fromName(
        _database.getSetting(_themePreferenceKey),
      ),
      navigationPosition: AppNavigationPosition.fromName(
        _database.getSetting(_navigationPositionKey),
      ),
      ffmpegExecutable:
          _database.getSetting(_ffmpegExecutableKey)?.trim().isNotEmpty == true
          ? _database.getSetting(_ffmpegExecutableKey)!.trim()
          : 'ffmpeg',
      ffprobeExecutable:
          _database.getSetting(_ffprobeExecutableKey)?.trim().isNotEmpty == true
          ? _database.getSetting(_ffprobeExecutableKey)!.trim()
          : 'ffprobe',
      videoFrameExtractionStrategy: VideoFrameExtractionStrategy.fromName(
        _database.getSetting(_videoFrameExtractionStrategyKey),
      ),
      videoFrameIntervalSeconds: _getDoubleSetting(
        _videoFrameIntervalSecondsKey,
        1,
        min: 0.1,
        max: 60,
      ),
      videoSceneThreshold: _getDoubleSetting(
        _videoSceneThresholdKey,
        0.3,
        min: 0.05,
        max: 0.95,
      ),
      videoMinimumSharpness: _getDoubleSetting(
        _videoMinimumSharpnessKey,
        0.08,
        min: 0,
        max: 1,
      ),
      videoAnalysisThinkingEnabled:
          _database.getSetting(_videoAnalysisThinkingEnabledKey) == 'true',
      replicateDefaultGlobalStyle:
          _database.getSetting(_replicateDefaultGlobalStyleKey) ??
          AppSettings.defaultReplicateGlobalStyle,
      replicateDefaultConstraints:
          _database.getSetting(_replicateDefaultConstraintsKey) ??
          AppSettings.defaultReplicateConstraints,
      cutImageNumberEnabled:
          _database.getSetting(_cutImageNumberEnabledKey) == 'true',
      cutImageNumberPosition: CutImageNumberPosition.fromName(
        _database.getSetting(_cutImageNumberPositionKey),
      ),
      cutImageNumberBackgroundOpacity: _getDoubleSetting(
        _cutImageNumberBackgroundOpacityKey,
        AppSettings.defaultCutImageNumberBackgroundOpacity,
      ),
      cutImageNumberTextScale: _getDoubleSetting(
        _cutImageNumberTextScaleKey,
        AppSettings.defaultCutImageNumberTextScale,
        min: 0.7,
        max: 1.6,
      ),
      storyboardCaptionNumberEnabled:
          _database.getSetting(_storyboardCaptionNumberEnabledKey) != 'false',
      storyboardSummaryPageEnabled:
          _database.getSetting(_storyboardSummaryPageEnabledKey) != 'false',
      visionApiBaseUrl: _getSettingWithImportedDefault(
        _visionApiBaseUrlKey,
        visionDefaults.baseUrl,
      ),
      visionApiKey: _getSettingWithImportedDefault(
        _visionApiKeyKey,
        visionDefaults.apiKey,
      ),
      visionModel: _getSettingWithImportedDefault(
        _visionModelKey,
        visionDefaults.model,
      ),
      imageGenerationApiBaseUrl: _getSettingWithImportedDefault(
        _imageGenerationApiBaseUrlKey,
        imageGenerationDefaults.baseUrl,
      ),
      imageGenerationApiKey: _getSettingWithImportedDefault(
        _imageGenerationApiKeyKey,
        imageGenerationDefaults.apiKey,
      ),
      imageGenerationGeminiApiBaseUrl:
          _database.getSetting(_imageGenerationGeminiApiBaseUrlKey) ??
          AppSettings.defaultImageGenerationGeminiApiBaseUrl,
      imageGenerationGeminiApiKey:
          _database.getSetting(_imageGenerationGeminiApiKeyKey) ?? '',
      imageGenerationApiMartApiBaseUrl:
          _database.getSetting(_imageGenerationApiMartApiBaseUrlKey) ??
          AppSettings.defaultImageGenerationApiMartApiBaseUrl,
      imageGenerationApiMartApiKey:
          _database.getSetting(_imageGenerationApiMartApiKeyKey) ?? '',
      imageGenerationModel: _getSettingWithImportedDefault(
        _imageGenerationModelKey,
        imageGenerationDefaults.model,
      ),
      updateReleaseApiUrl:
          _database.getSetting(_updateReleaseApiUrlKey) ??
          AppUpdateConfig.defaultReleaseRepositoryUrl,
      autoInstallUpdates:
          _database.getSetting(_autoInstallUpdatesKey) == 'true',
      updateDownloadMode: UpdateDownloadMode.fromName(
        _database.getSetting(_updateDownloadModeKey),
      ),
      updateManualProxyUrl:
          _database.getSetting(_updateManualProxyUrlKey) ??
          'http://127.0.0.1:7890',
    );
  }

  void save(AppSettings settings) {
    _database
      ..setSetting(_exportDirectoryKey, settings.exportDirectory)
      ..setSetting(_themePreferenceKey, settings.themePreference.name)
      ..setSetting(_navigationPositionKey, settings.navigationPosition.name)
      ..setSetting(_ffmpegExecutableKey, settings.ffmpegExecutable)
      ..setSetting(_ffprobeExecutableKey, settings.ffprobeExecutable)
      ..setSetting(
        _videoFrameExtractionStrategyKey,
        settings.videoFrameExtractionStrategy.name,
      )
      ..setSetting(
        _videoFrameIntervalSecondsKey,
        settings.videoFrameIntervalSeconds.toStringAsFixed(2),
      )
      ..setSetting(
        _videoSceneThresholdKey,
        settings.videoSceneThreshold.toStringAsFixed(2),
      )
      ..setSetting(
        _videoMinimumSharpnessKey,
        settings.videoMinimumSharpness.toStringAsFixed(2),
      )
      ..setSetting(
        _videoAnalysisThinkingEnabledKey,
        settings.videoAnalysisThinkingEnabled.toString(),
      )
      ..setSetting(
        _replicateDefaultGlobalStyleKey,
        settings.replicateDefaultGlobalStyle,
      )
      ..setSetting(
        _replicateDefaultConstraintsKey,
        settings.replicateDefaultConstraints,
      )
      ..setSetting(
        _cutImageNumberEnabledKey,
        settings.cutImageNumberEnabled.toString(),
      )
      ..setSetting(
        _cutImageNumberPositionKey,
        settings.cutImageNumberPosition.name,
      )
      ..setSetting(
        _cutImageNumberBackgroundOpacityKey,
        settings.cutImageNumberBackgroundOpacity.toStringAsFixed(2),
      )
      ..setSetting(
        _cutImageNumberTextScaleKey,
        settings.cutImageNumberTextScale.toStringAsFixed(2),
      )
      ..setSetting(
        _storyboardCaptionNumberEnabledKey,
        settings.storyboardCaptionNumberEnabled.toString(),
      )
      ..setSetting(
        _storyboardSummaryPageEnabledKey,
        settings.storyboardSummaryPageEnabled.toString(),
      )
      ..setSetting(_visionApiBaseUrlKey, settings.visionApiBaseUrl)
      ..setSetting(_visionApiKeyKey, settings.visionApiKey)
      ..setSetting(_visionModelKey, settings.visionModel)
      ..setSetting(
        _imageGenerationApiBaseUrlKey,
        settings.imageGenerationApiBaseUrl,
      )
      ..setSetting(_imageGenerationApiKeyKey, settings.imageGenerationApiKey)
      ..setSetting(
        _imageGenerationGeminiApiBaseUrlKey,
        settings.imageGenerationGeminiApiBaseUrl,
      )
      ..setSetting(
        _imageGenerationGeminiApiKeyKey,
        settings.imageGenerationGeminiApiKey,
      )
      ..setSetting(
        _imageGenerationApiMartApiBaseUrlKey,
        settings.imageGenerationApiMartApiBaseUrl,
      )
      ..setSetting(
        _imageGenerationApiMartApiKeyKey,
        settings.imageGenerationApiMartApiKey,
      )
      ..setSetting(_imageGenerationModelKey, settings.imageGenerationModel)
      ..setSetting(_updateReleaseApiUrlKey, settings.updateReleaseApiUrl)
      ..setSetting(
        _autoInstallUpdatesKey,
        settings.autoInstallUpdates.toString(),
      )
      ..setSetting(_updateDownloadModeKey, settings.updateDownloadMode.name)
      ..setSetting(_updateManualProxyUrlKey, settings.updateManualProxyUrl);
  }

  AppSettings defaults() {
    final visionDefaults = _loadVisionDefaults();
    final imageGenerationDefaults = _loadImageGenerationDefaults();
    return AppSettings(
      exportDirectory: _directories.exports.path,
      themePreference: AppThemePreference.system,
      navigationPosition: AppNavigationPosition.bottom,
      ffmpegExecutable: 'ffmpeg',
      ffprobeExecutable: 'ffprobe',
      videoFrameExtractionStrategy:
          VideoFrameExtractionStrategy.sceneAndInterval,
      videoFrameIntervalSeconds: 1,
      videoSceneThreshold: 0.3,
      videoMinimumSharpness: 0.08,
      videoAnalysisThinkingEnabled: false,
      replicateDefaultGlobalStyle: AppSettings.defaultReplicateGlobalStyle,
      replicateDefaultConstraints: AppSettings.defaultReplicateConstraints,
      cutImageNumberEnabled: false,
      cutImageNumberPosition: CutImageNumberPosition.topLeft,
      cutImageNumberBackgroundOpacity:
          AppSettings.defaultCutImageNumberBackgroundOpacity,
      cutImageNumberTextScale: AppSettings.defaultCutImageNumberTextScale,
      storyboardCaptionNumberEnabled: true,
      storyboardSummaryPageEnabled: true,
      visionApiBaseUrl: visionDefaults.baseUrl,
      visionApiKey: visionDefaults.apiKey,
      visionModel: visionDefaults.model,
      imageGenerationApiBaseUrl: imageGenerationDefaults.baseUrl,
      imageGenerationApiKey: imageGenerationDefaults.apiKey,
      imageGenerationGeminiApiBaseUrl:
          AppSettings.defaultImageGenerationGeminiApiBaseUrl,
      imageGenerationGeminiApiKey: '',
      imageGenerationApiMartApiBaseUrl:
          AppSettings.defaultImageGenerationApiMartApiBaseUrl,
      imageGenerationApiMartApiKey: '',
      imageGenerationModel: imageGenerationDefaults.model,
      updateReleaseApiUrl: AppUpdateConfig.defaultReleaseRepositoryUrl,
      autoInstallUpdates: false,
      updateDownloadMode: UpdateDownloadMode.automatic,
      updateManualProxyUrl: 'http://127.0.0.1:7890',
    );
  }

  String? downloadedUpdateVersion() {
    return _database.getSetting(_downloadedUpdateVersionKey);
  }

  String? pendingUpdateVersion() {
    return _database.getSetting(_pendingUpdateVersionKey);
  }

  String? pendingUpdateInstallerPath() {
    return _database.getSetting(_pendingUpdateInstallerPathKey);
  }

  String? dismissedUpdatePromptVersion() {
    return _database.getSetting(_dismissedUpdatePromptVersionKey);
  }

  void setDownloadedUpdateVersion(String versionTag) {
    _database.setSetting(_downloadedUpdateVersionKey, versionTag);
  }

  void setPendingUpdate({
    required String versionTag,
    required String installerPath,
  }) {
    _database
      ..setSetting(_pendingUpdateVersionKey, versionTag)
      ..setSetting(_pendingUpdateInstallerPathKey, installerPath);
  }

  void clearPendingUpdate() {
    _database
      ..setSetting(_pendingUpdateVersionKey, '')
      ..setSetting(_pendingUpdateInstallerPathKey, '');
  }

  void setDismissedUpdatePromptVersion(String versionTag) {
    _database.setSetting(_dismissedUpdatePromptVersionKey, versionTag);
  }

  void clearDismissedUpdatePromptVersion() {
    _database.setSetting(_dismissedUpdatePromptVersionKey, '');
  }

  String _getSettingWithImportedDefault(String key, String defaultValue) {
    final value = _database.getSetting(key);
    if (value != null) {
      return value;
    }
    if (defaultValue.isNotEmpty) {
      _database.setSetting(key, defaultValue);
    }
    return defaultValue;
  }

  double _getDoubleSetting(
    String key,
    double defaultValue, {
    double min = 0,
    double max = 1,
  }) {
    final value = double.tryParse(_database.getSetting(key) ?? '');
    return (value ?? defaultValue).clamp(min, max).toDouble();
  }

  _VisionApiDefaults _loadVisionDefaults() {
    final text = _visionDefaultsText ?? _readVisionDefaultsFile();
    if (text == null || text.trim().isEmpty) {
      return const _VisionApiDefaults.empty();
    }
    return _VisionApiDefaults.fromText(text);
  }

  _ImageGenerationApiDefaults _loadImageGenerationDefaults() {
    final text =
        _imageGenerationDefaultsText ?? _readImageGenerationDefaultsFile();
    if (text == null || text.trim().isEmpty) {
      return const _ImageGenerationApiDefaults.defaults();
    }
    return _ImageGenerationApiDefaults.fromText(text);
  }

  String? _readVisionDefaultsFile() {
    final candidates = [
      File(p.join(Directory.current.path, 'docs', '视觉模型api.md')),
      File(p.join(_directories.executableDirectory.path, 'docs', '视觉模型api.md')),
      File(
        p.join(
          _directories.executableDirectory.parent.path,
          'docs',
          '视觉模型api.md',
        ),
      ),
    ];
    for (final file in candidates) {
      if (file.existsSync()) {
        return file.readAsStringSync();
      }
    }
    return null;
  }

  String? _readImageGenerationDefaultsFile() {
    final candidates = [
      File(p.join(Directory.current.path, 'docs', 'api key.md')),
      File(p.join(_directories.executableDirectory.path, 'docs', 'api key.md')),
      File(
        p.join(
          _directories.executableDirectory.parent.path,
          'docs',
          'api key.md',
        ),
      ),
    ];
    for (final file in candidates) {
      if (file.existsSync()) {
        return file.readAsStringSync();
      }
    }
    return null;
  }
}

class _VisionApiDefaults {
  const _VisionApiDefaults({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  const _VisionApiDefaults.empty() : baseUrl = '', apiKey = '', model = '';

  final String baseUrl;
  final String apiKey;
  final String model;

  factory _VisionApiDefaults.fromText(String text) {
    return _VisionApiDefaults(
      baseUrl: _readValue(text, 'url'),
      apiKey: _readValue(text, 'key'),
      model: _readValue(text, '模型'),
    );
  }

  static String _readValue(String text, String key) {
    final pattern = RegExp(
      '^\\s*$key\\s*[:：]\\s*(.+?)\\s*\$',
      multiLine: true,
      caseSensitive: false,
    );
    final match = pattern.firstMatch(text);
    return match?.group(1)?.trim() ?? '';
  }
}

class _ImageGenerationApiDefaults {
  const _ImageGenerationApiDefaults({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  const _ImageGenerationApiDefaults.defaults()
    : baseUrl = 'https://grsai.dakka.com.cn',
      apiKey = '',
      model = 'nano-banana-fast';

  final String baseUrl;
  final String apiKey;
  final String model;

  factory _ImageGenerationApiDefaults.fromText(String text) {
    final defaults = const _ImageGenerationApiDefaults.defaults();
    final section = _builtinSection(text, 'builtin-grsai-image');
    if (section == null || section.trim().isEmpty) {
      return defaults;
    }
    final url =
        _readFirstValue(section, const ['请求地址', 'url', '地址']) ??
        defaults.baseUrl;
    final key = _VisionApiDefaults._readValue(section, 'key');
    final model =
        _readFirstValue(section, const ['模型', 'model']) ?? defaults.model;
    return _ImageGenerationApiDefaults(
      baseUrl: url.trim().isEmpty ? defaults.baseUrl : url.trim(),
      apiKey: key,
      model: model.trim().isEmpty ? defaults.model : model.trim(),
    );
  }

  static String? _builtinSection(String text, String id) {
    final start = text.indexOf('`$id`');
    if (start < 0) {
      return null;
    }
    final afterStart = text.substring(start);
    final next = RegExp(r'\n\s*\d+\.\s+`').firstMatch(afterStart);
    if (next == null || next.start == 0) {
      return afterStart;
    }
    return afterStart.substring(0, next.start);
  }

  static String? _readFirstValue(String text, List<String> keys) {
    for (final key in keys) {
      final value = _VisionApiDefaults._readValue(text, key);
      if (value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }
}
