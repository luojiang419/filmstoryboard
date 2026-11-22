class RemoteSettingsOption {
  const RemoteSettingsOption({
    required this.id,
    required this.name,
    required this.detail,
  });

  final String id;
  final String name;
  final String detail;
}

class RemoteSettingsSnapshot {
  const RemoteSettingsSnapshot({
    required this.extractionStrategies,
    required this.selectedExtractionStrategy,
    required this.visionModels,
    required this.selectedVisionModelId,
    required this.imageGenerationModels,
    required this.selectedImageGenerationModelId,
    required this.videoGenerationModels,
    required this.selectedVideoGenerationModelId,
  });

  final List<RemoteSettingsOption> extractionStrategies;
  final String selectedExtractionStrategy;
  final List<RemoteSettingsOption> visionModels;
  final String selectedVisionModelId;
  final List<RemoteSettingsOption> imageGenerationModels;
  final String selectedImageGenerationModelId;
  final List<RemoteSettingsOption> videoGenerationModels;
  final String selectedVideoGenerationModelId;
}

class RemoteSettingsSelectionCommand {
  const RemoteSettingsSelectionCommand({
    this.extractionStrategy,
    this.visionModelId,
    this.imageGenerationModelId,
    this.videoGenerationModelId,
  });

  final String? extractionStrategy;
  final String? visionModelId;
  final String? imageGenerationModelId;
  final String? videoGenerationModelId;

  bool get isEmpty =>
      extractionStrategy == null &&
      visionModelId == null &&
      imageGenerationModelId == null &&
      videoGenerationModelId == null;
}

abstract interface class RemoteSettingsSource {
  RemoteSettingsSnapshot get snapshot;
  Stream<void> get changes;

  Future<void> applySelection(RemoteSettingsSelectionCommand command);
}
