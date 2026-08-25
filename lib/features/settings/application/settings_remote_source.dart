import 'dart:async';

import '../../remote_access/domain/remote_settings_models.dart';
import '../domain/app_settings.dart';
import 'settings_controller.dart';

class SettingsRemoteSource implements RemoteSettingsSource {
  SettingsRemoteSource(this._controller) {
    _controller.addListener(_handleChanged);
  }

  final SettingsController _controller;
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  @override
  RemoteSettingsSnapshot get snapshot {
    final settings = _controller.value;
    return RemoteSettingsSnapshot(
      extractionStrategies: [
        for (final strategy in VideoFrameExtractionStrategy.values)
          RemoteSettingsOption(
            id: strategy.name,
            name: strategy.label,
            detail: _strategyDetail(strategy),
          ),
      ],
      selectedExtractionStrategy: settings.videoFrameExtractionStrategy.name,
      visionModels: [
        for (final config in settings.visionApiConfigs)
          RemoteSettingsOption(
            id: config.id,
            name: config.name,
            detail: [
              config.requestProtocol.label,
              config.model,
            ].where((value) => value.trim().isNotEmpty).join(' · '),
          ),
      ],
      selectedVisionModelId: settings.activeVisionApiConfig?.id ?? '',
      imageGenerationModels: [
        for (final config in settings.imageGenerationApiConfigs)
          RemoteSettingsOption(
            id: config.id,
            name: config.name,
            detail: [
              config.providerLabel,
              config.model,
            ].where((value) => value.trim().isNotEmpty).join(' · '),
          ),
      ],
      selectedImageGenerationModelId:
          settings.activeImageGenerationApiConfig?.id ?? '',
      videoGenerationModels: [
        for (final config in settings.videoGenerationApiConfigs)
          RemoteSettingsOption(
            id: config.id,
            name: config.name,
            detail: [
              config.kind.label,
              config.model,
            ].where((value) => value.trim().isNotEmpty).join(' · '),
          ),
      ],
      selectedVideoGenerationModelId:
          settings.activeVideoGenerationApiConfig?.id ?? '',
    );
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> applySelection(RemoteSettingsSelectionCommand command) async {
    if (command.extractionStrategy case final strategyName?) {
      final strategy = VideoFrameExtractionStrategy.values.firstWhere(
        (item) => item.name == strategyName,
        orElse: () =>
            throw ArgumentError.value(strategyName, 'extractionStrategy'),
      );
      final settings = _controller.value;
      await _controller.setVideoAnalysisSettings(
        ffmpegExecutable: settings.ffmpegExecutable,
        ffprobeExecutable: settings.ffprobeExecutable,
        extractionStrategy: strategy,
        frameIntervalSeconds: settings.videoFrameIntervalSeconds,
        sceneThreshold: settings.videoSceneThreshold,
        minimumSharpness: settings.videoMinimumSharpness,
        previewPaddingSeconds: settings.videoPreviewPaddingSeconds,
        thinkingEnabled: settings.videoAnalysisThinkingEnabled,
      );
    }
    if (command.visionModelId case final configId?) {
      await _controller.setActiveVisionApiConfig(configId);
    }
    if (command.imageGenerationModelId case final configId?) {
      await _controller.setActiveImageGenerationApiConfig(configId);
    }
    if (command.videoGenerationModelId case final configId?) {
      await _controller.setActiveVideoGenerationApiConfig(configId);
    }
  }

  void _handleChanged() {
    if (!_disposed) _changes.add(null);
  }

  static String _strategyDetail(VideoFrameExtractionStrategy strategy) =>
      switch (strategy) {
        VideoFrameExtractionStrategy.perFrame => '保留视频的每一帧，适合短素材精细检查',
        VideoFrameExtractionStrategy.sceneAndInterval => '场景切换优先，并按间隔补充候选帧',
        VideoFrameExtractionStrategy.intervalOnly => '按固定时间间隔提取候选帧',
        VideoFrameExtractionStrategy.highFidelity => '提高采样密度并保留更多动作变化',
      };

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_handleChanged);
    unawaited(_changes.close());
  }
}
