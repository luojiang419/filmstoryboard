import '../../video_analysis/domain/video_analysis_models.dart';

enum ReplicateStep {
  confirmShots,
  prepareAssets,
  composePrompts,
  generateVideos,
}

enum ShotPromptFormat { sd2, kling, h3 }

enum ReplicateAssetType {
  character,
  product,
  scene,
  prop,
  video,
  audio,
  reference,
  other,
}

class ReplicateRun {
  const ReplicateRun({
    required this.id,
    required this.videoId,
    this.scriptId,
    this.globalStyle = '',
    this.constraints = '',
    this.replicationInstructions = '',
    this.freeCreationEnabled = false,
    this.freeCreationStoryOverride = '',
    this.generationModel = '',
    this.generationAspectRatio = '16:9',
    this.generationImageSize = '',
    this.generationQuality = '',
    this.confirmedShotIds = const [],
    this.imageReferenceCount = 0,
    this.videoReferenceCount = 0,
    this.audioReferenceCount = 0,
    required this.currentStep,
    required this.status,
    required this.confirmShotsStatus,
    required this.prepareAssetsStatus,
    required this.composePromptsStatus,
    this.generateVideosStatus = ProcessingStatus.pending,
    required this.completedCount,
    required this.totalCount,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String? videoId;
  final String? scriptId;
  final String globalStyle;
  final String constraints;

  /// 用户对当前复刻任务的补充要求；生成前会覆盖自动解析中冲突的内容。
  final String replicationInstructions;
  final bool freeCreationEnabled;
  final String freeCreationStoryOverride;

  /// 复刻任务专属的默认出图参数，不影响应用的全局图片生成设置。
  final String generationModel;
  final String generationAspectRatio;
  final String generationImageSize;
  final String generationQuality;
  final List<String> confirmedShotIds;
  final int imageReferenceCount;
  final int videoReferenceCount;
  final int audioReferenceCount;
  final ReplicateStep currentStep;
  final ProcessingStatus status;
  final ProcessingStatus confirmShotsStatus;
  final ProcessingStatus prepareAssetsStatus;
  final ProcessingStatus composePromptsStatus;
  final ProcessingStatus generateVideosStatus;
  final int completedCount;
  final int totalCount;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  ReplicateRun copyWith({
    String? videoId,
    String? scriptId,
    String? globalStyle,
    String? constraints,
    String? replicationInstructions,
    bool? freeCreationEnabled,
    String? freeCreationStoryOverride,
    String? generationModel,
    String? generationAspectRatio,
    String? generationImageSize,
    String? generationQuality,
    List<String>? confirmedShotIds,
    int? imageReferenceCount,
    int? videoReferenceCount,
    int? audioReferenceCount,
    ReplicateStep? currentStep,
    ProcessingStatus? status,
    ProcessingStatus? confirmShotsStatus,
    ProcessingStatus? prepareAssetsStatus,
    ProcessingStatus? composePromptsStatus,
    ProcessingStatus? generateVideosStatus,
    int? completedCount,
    int? totalCount,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ReplicateRun(
    id: id,
    videoId: videoId ?? this.videoId,
    scriptId: scriptId ?? this.scriptId,
    globalStyle: globalStyle ?? this.globalStyle,
    constraints: constraints ?? this.constraints,
    replicationInstructions:
        replicationInstructions ?? this.replicationInstructions,
    freeCreationEnabled: freeCreationEnabled ?? this.freeCreationEnabled,
    freeCreationStoryOverride:
        freeCreationStoryOverride ?? this.freeCreationStoryOverride,
    generationModel: generationModel ?? this.generationModel,
    generationAspectRatio: generationAspectRatio ?? this.generationAspectRatio,
    generationImageSize: generationImageSize ?? this.generationImageSize,
    generationQuality: generationQuality ?? this.generationQuality,
    confirmedShotIds: confirmedShotIds ?? this.confirmedShotIds,
    imageReferenceCount: imageReferenceCount ?? this.imageReferenceCount,
    videoReferenceCount: videoReferenceCount ?? this.videoReferenceCount,
    audioReferenceCount: audioReferenceCount ?? this.audioReferenceCount,
    currentStep: currentStep ?? this.currentStep,
    status: status ?? this.status,
    confirmShotsStatus: confirmShotsStatus ?? this.confirmShotsStatus,
    prepareAssetsStatus: prepareAssetsStatus ?? this.prepareAssetsStatus,
    composePromptsStatus: composePromptsStatus ?? this.composePromptsStatus,
    generateVideosStatus: generateVideosStatus ?? this.generateVideosStatus,
    completedCount: completedCount ?? this.completedCount,
    totalCount: totalCount ?? this.totalCount,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ReplicateAsset {
  const ReplicateAsset({
    required this.id,
    required this.runId,
    required this.type,
    required this.name,
    required this.description,
    required this.path,
    required this.referenceNumber,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String runId;
  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
  final int referenceNumber;
  final ProcessingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  ReplicateAsset copyWith({
    ReplicateAssetType? type,
    String? name,
    String? description,
    String? path,
    int? referenceNumber,
    ProcessingStatus? status,
    DateTime? updatedAt,
  }) => ReplicateAsset(
    id: id,
    runId: runId,
    type: type ?? this.type,
    name: name ?? this.name,
    description: description ?? this.description,
    path: path ?? this.path,
    referenceNumber: referenceNumber ?? this.referenceNumber,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ShotPrompt {
  const ShotPrompt({
    required this.id,
    required this.runId,
    required this.shotNumber,
    required this.scriptShotId,
    required this.assetIds,
    required this.prompt,
    required this.model,
    required this.rawResponse,
    this.isUserEdited = false,
    required this.status,
    required this.errorMessage,
    required this.updatedAt,
  });

  final String id;
  final String runId;
  final int shotNumber;
  final String? scriptShotId;
  final List<String> assetIds;
  final String prompt;
  final String model;
  final String rawResponse;
  final bool isUserEdited;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime updatedAt;

  ShotPrompt copyWith({
    int? shotNumber,
    String? scriptShotId,
    List<String>? assetIds,
    String? prompt,
    String? model,
    String? rawResponse,
    bool? isUserEdited,
    ProcessingStatus? status,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ShotPrompt(
    id: id,
    runId: runId,
    shotNumber: shotNumber ?? this.shotNumber,
    scriptShotId: scriptShotId ?? this.scriptShotId,
    assetIds: assetIds ?? this.assetIds,
    prompt: prompt ?? this.prompt,
    model: model ?? this.model,
    rawResponse: rawResponse ?? this.rawResponse,
    isUserEdited: isUserEdited ?? this.isUserEdited,
    status: status ?? this.status,
    errorMessage: errorMessage ?? this.errorMessage,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ReplicatedShotImage {
  const ReplicatedShotImage({
    required this.id,
    required this.runId,
    required this.scriptShotId,
    required this.shotNumber,
    required this.originalFramePath,
    required this.generatedFramePath,
    required this.assetIds,
    required this.prompt,
    required this.model,
    required this.rawResponse,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String runId;
  final String scriptShotId;
  final int shotNumber;
  final String originalFramePath;
  final String generatedFramePath;
  final List<String> assetIds;
  final String prompt;
  final String model;
  final String rawResponse;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  ReplicatedShotImage copyWith({
    String? originalFramePath,
    String? generatedFramePath,
    List<String>? assetIds,
    String? prompt,
    String? model,
    String? rawResponse,
    ProcessingStatus? status,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ReplicatedShotImage(
    id: id,
    runId: runId,
    scriptShotId: scriptShotId,
    shotNumber: shotNumber,
    originalFramePath: originalFramePath ?? this.originalFramePath,
    generatedFramePath: generatedFramePath ?? this.generatedFramePath,
    assetIds: assetIds ?? this.assetIds,
    prompt: prompt ?? this.prompt,
    model: model ?? this.model,
    rawResponse: rawResponse ?? this.rawResponse,
    status: status ?? this.status,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
