import '../../video_analysis/domain/video_analysis_models.dart';
import 'replicate_asset_preparation_models.dart';
import 'line_art_color_style_preset.dart';

export 'replicate_asset_preparation_models.dart';
export 'line_art_color_style_preset.dart';

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
    this.inheritSourceAspectRatio = true,
    this.multiViewEnhancementEnabled = false,
    this.generationImageSize = '',
    this.generationQuality = '',
    this.sourceFrameMode = ReplicateSourceFrameMode.colorReference,
    this.colorStylePresetId = '',
    this.colorStyleSnapshot,
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
  final bool inheritSourceAspectRatio;
  final bool multiViewEnhancementEnabled;
  final String generationImageSize;
  final String generationQuality;
  final ReplicateSourceFrameMode sourceFrameMode;
  final String colorStylePresetId;
  final LineArtColorStyleSelectionSnapshot? colorStyleSnapshot;
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
    bool? inheritSourceAspectRatio,
    bool? multiViewEnhancementEnabled,
    String? generationImageSize,
    String? generationQuality,
    ReplicateSourceFrameMode? sourceFrameMode,
    String? colorStylePresetId,
    LineArtColorStyleSelectionSnapshot? colorStyleSnapshot,
    bool clearColorStyleSnapshot = false,
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
    inheritSourceAspectRatio:
        inheritSourceAspectRatio ?? this.inheritSourceAspectRatio,
    multiViewEnhancementEnabled:
        multiViewEnhancementEnabled ?? this.multiViewEnhancementEnabled,
    generationImageSize: generationImageSize ?? this.generationImageSize,
    generationQuality: generationQuality ?? this.generationQuality,
    sourceFrameMode: sourceFrameMode ?? this.sourceFrameMode,
    colorStylePresetId: colorStylePresetId ?? this.colorStylePresetId,
    colorStyleSnapshot: clearColorStyleSnapshot
        ? null
        : colorStyleSnapshot ?? this.colorStyleSnapshot,
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

enum ReplicatedShotRecoveryStage {
  none,
  awaitingProductDetailRefill,
  productDetailRefillInFlight,
  awaitingInitialReview,
  awaitingCorrection,
  correctionInFlight,
  awaitingCorrectedReview,
}

enum ReplicatedShotContinuationTransport { none, interactions, generateContent }

class ReplicatedShotGenerationRecovery {
  const ReplicatedShotGenerationRecovery({
    this.stage = ReplicatedShotRecoveryStage.none,
    this.orderedReferencePaths = const [],
    this.aspectRatio = '',
    this.imageSize = '',
    this.quality = '',
    this.reviewAttempts = const [],
    this.continuationTransport = ReplicatedShotContinuationTransport.none,
    this.continuationApiModel = '',
    this.previousInteractionId = '',
    this.continuationResumable = false,
    this.continuationDiagnostic = '',
    this.productDetailRefillPrompt = '',
    this.poseProtectionRequired = false,
  });

  static const schemaVersion = 3;
  static const empty = ReplicatedShotGenerationRecovery();

  final ReplicatedShotRecoveryStage stage;
  final List<String> orderedReferencePaths;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final List<Map<String, Object?>> reviewAttempts;
  final ReplicatedShotContinuationTransport continuationTransport;
  final String continuationApiModel;
  final String previousInteractionId;
  final bool continuationResumable;
  final String continuationDiagnostic;
  final String productDetailRefillPrompt;
  final bool poseProtectionRequired;

  bool get isEmpty => stage == ReplicatedShotRecoveryStage.none;

  bool get hasResumableContinuation =>
      continuationTransport ==
          ReplicatedShotContinuationTransport.interactions &&
      continuationResumable &&
      continuationApiModel.trim().isNotEmpty &&
      previousInteractionId.trim().isNotEmpty;

  ReplicatedShotGenerationRecovery copyWith({
    ReplicatedShotRecoveryStage? stage,
    List<String>? orderedReferencePaths,
    String? aspectRatio,
    String? imageSize,
    String? quality,
    List<Map<String, Object?>>? reviewAttempts,
    ReplicatedShotContinuationTransport? continuationTransport,
    String? continuationApiModel,
    String? previousInteractionId,
    bool? continuationResumable,
    String? continuationDiagnostic,
    String? productDetailRefillPrompt,
    bool? poseProtectionRequired,
  }) => ReplicatedShotGenerationRecovery(
    stage: stage ?? this.stage,
    orderedReferencePaths: orderedReferencePaths ?? this.orderedReferencePaths,
    aspectRatio: aspectRatio ?? this.aspectRatio,
    imageSize: imageSize ?? this.imageSize,
    quality: quality ?? this.quality,
    reviewAttempts: reviewAttempts ?? this.reviewAttempts,
    continuationTransport: continuationTransport ?? this.continuationTransport,
    continuationApiModel: continuationApiModel ?? this.continuationApiModel,
    previousInteractionId: previousInteractionId ?? this.previousInteractionId,
    continuationResumable: continuationResumable ?? this.continuationResumable,
    continuationDiagnostic:
        continuationDiagnostic ?? this.continuationDiagnostic,
    productDetailRefillPrompt:
        productDetailRefillPrompt ?? this.productDetailRefillPrompt,
    poseProtectionRequired:
        poseProtectionRequired ?? this.poseProtectionRequired,
  );

  Map<String, Object?> toJson() {
    if (isEmpty) return const {};
    return {
      'schemaVersion': schemaVersion,
      'stage': stage.name,
      'orderedReferencePaths': orderedReferencePaths,
      'aspectRatio': aspectRatio,
      'imageSize': imageSize,
      'quality': quality,
      'reviewAttempts': reviewAttempts,
      if (productDetailRefillPrompt.isNotEmpty)
        'productDetailRefillPrompt': productDetailRefillPrompt,
      'poseProtectionRequired': poseProtectionRequired,
      'continuation': {
        'transport': continuationTransport.name,
        'apiModel': continuationApiModel,
        'resumable': continuationResumable,
        if (previousInteractionId.isNotEmpty)
          'previousInteractionId': previousInteractionId,
        if (continuationDiagnostic.isNotEmpty)
          'diagnostic': continuationDiagnostic,
      },
    };
  }

  factory ReplicatedShotGenerationRecovery.fromJson(Map<String, Object?> json) {
    final storedSchemaVersion = json['schemaVersion'];
    if (json.isEmpty ||
        (storedSchemaVersion != 2 && storedSchemaVersion != schemaVersion)) {
      return empty;
    }
    final stageName = json['stage']?.toString() ?? '';
    final stage = ReplicatedShotRecoveryStage.values
        .where((value) => value.name == stageName)
        .firstOrNull;
    if (stage == null || stage == ReplicatedShotRecoveryStage.none) {
      return empty;
    }
    final rawContinuation = json['continuation'];
    final continuation = rawContinuation is Map
        ? rawContinuation.map((key, value) => MapEntry('$key', value))
        : const <String, Object?>{};
    final transportName = continuation['transport']?.toString() ?? '';
    final transport = ReplicatedShotContinuationTransport.values
        .where((value) => value.name == transportName)
        .firstOrNull;
    final rawReferencePaths = json['orderedReferencePaths'];
    final rawReviewAttempts = json['reviewAttempts'];
    return ReplicatedShotGenerationRecovery(
      stage: stage,
      orderedReferencePaths: rawReferencePaths is List
          ? [
              for (final value in rawReferencePaths)
                if (value is String && value.trim().isNotEmpty) value,
            ]
          : const [],
      aspectRatio: json['aspectRatio']?.toString() ?? '',
      imageSize: json['imageSize']?.toString() ?? '',
      quality: json['quality']?.toString() ?? '',
      reviewAttempts: rawReviewAttempts is List
          ? [
              for (final value in rawReviewAttempts)
                if (value is Map)
                  value.map((key, item) => MapEntry('$key', item)),
            ]
          : const [],
      continuationTransport:
          transport ?? ReplicatedShotContinuationTransport.none,
      continuationApiModel: continuation['apiModel']?.toString() ?? '',
      previousInteractionId:
          continuation['previousInteractionId']?.toString() ?? '',
      continuationResumable: continuation['resumable'] == true,
      continuationDiagnostic: continuation['diagnostic']?.toString() ?? '',
      productDetailRefillPrompt:
          json['productDetailRefillPrompt']?.toString() ?? '',
      poseProtectionRequired: storedSchemaVersion == 2
          ? true
          : json['poseProtectionRequired'] == true,
    );
  }
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
    this.generationRecovery = ReplicatedShotGenerationRecovery.empty,
    this.colorStyleFingerprint = '',
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
  final ReplicatedShotGenerationRecovery generationRecovery;
  final String colorStyleFingerprint;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  ReplicatedShotImage copyWith({
    int? shotNumber,
    String? originalFramePath,
    String? generatedFramePath,
    List<String>? assetIds,
    String? prompt,
    String? model,
    String? rawResponse,
    ReplicatedShotGenerationRecovery? generationRecovery,
    String? colorStyleFingerprint,
    ProcessingStatus? status,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ReplicatedShotImage(
    id: id,
    runId: runId,
    scriptShotId: scriptShotId,
    shotNumber: shotNumber ?? this.shotNumber,
    originalFramePath: originalFramePath ?? this.originalFramePath,
    generatedFramePath: generatedFramePath ?? this.generatedFramePath,
    assetIds: assetIds ?? this.assetIds,
    prompt: prompt ?? this.prompt,
    model: model ?? this.model,
    rawResponse: rawResponse ?? this.rawResponse,
    generationRecovery: generationRecovery ?? this.generationRecovery,
    colorStyleFingerprint: colorStyleFingerprint ?? this.colorStyleFingerprint,
    status: status ?? this.status,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ReplicatePreservedElement {
  const ReplicatePreservedElement({
    required this.id,
    required this.category,
    required this.label,
    this.description = '',
    this.location = '',
    this.relationship = '',
    this.confidence = 0,
    this.selected = false,
    this.isManual = false,
  });

  final String id;
  final String category;
  final String label;
  final String description;
  final String location;
  final String relationship;
  final double confidence;
  final bool selected;
  final bool isManual;

  ReplicatePreservedElement copyWith({
    String? id,
    String? category,
    String? label,
    String? description,
    String? location,
    String? relationship,
    double? confidence,
    bool? selected,
    bool? isManual,
  }) => ReplicatePreservedElement(
    id: id ?? this.id,
    category: category ?? this.category,
    label: label ?? this.label,
    description: description ?? this.description,
    location: location ?? this.location,
    relationship: relationship ?? this.relationship,
    confidence: confidence ?? this.confidence,
    selected: selected ?? this.selected,
    isManual: isManual ?? this.isManual,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'category': category,
    'label': label,
    'description': description,
    'location': location,
    'relationship': relationship,
    'confidence': confidence,
    'selected': selected,
    'isManual': isManual,
  };

  factory ReplicatePreservedElement.fromJson(Map<String, Object?> json) {
    bool flag(String key) {
      final value = json[key];
      return value == true || value == 1 || '$value'.toLowerCase() == 'true';
    }

    final confidence = json['confidence'];
    return ReplicatePreservedElement(
      id: '${json['id'] ?? ''}'.trim(),
      category: '${json['category'] ?? ''}'.trim(),
      label: '${json['label'] ?? ''}'.trim(),
      description: '${json['description'] ?? ''}'.trim(),
      location: '${json['location'] ?? ''}'.trim(),
      relationship: '${json['relationship'] ?? ''}'.trim(),
      confidence: confidence is num
          ? confidence.toDouble()
          : double.tryParse('$confidence') ?? 0,
      selected: flag('selected'),
      isManual: flag('isManual'),
    );
  }
}

enum ReplicateSubjectType { person, product }

enum ReplicateSubjectDecision { undecided, keep, replace, remove }

class ReplicateDetectedSubject {
  const ReplicateDetectedSubject({
    required this.id,
    required this.type,
    required this.label,
    required this.slotIndex,
    this.description = '',
    this.location = '',
    this.relationship = '',
    this.confidence = 0,
    this.decision = ReplicateSubjectDecision.undecided,
  });

  final String id;
  final ReplicateSubjectType type;
  final String label;

  /// Zero-based target slot. People map to model slots and products map to
  /// product slots, so replacement assets can be validated deterministically.
  final int slotIndex;
  final String description;
  final String location;
  final String relationship;
  final double confidence;
  final ReplicateSubjectDecision decision;

  ReplicateDetectedSubject copyWith({
    String? id,
    ReplicateSubjectType? type,
    String? label,
    int? slotIndex,
    String? description,
    String? location,
    String? relationship,
    double? confidence,
    ReplicateSubjectDecision? decision,
  }) => ReplicateDetectedSubject(
    id: id ?? this.id,
    type: type ?? this.type,
    label: label ?? this.label,
    slotIndex: slotIndex ?? this.slotIndex,
    description: description ?? this.description,
    location: location ?? this.location,
    relationship: relationship ?? this.relationship,
    confidence: confidence ?? this.confidence,
    decision: decision ?? this.decision,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'label': label,
    'slotIndex': slotIndex,
    'description': description,
    'location': location,
    'relationship': relationship,
    'confidence': confidence,
    'decision': decision.name,
  };

  factory ReplicateDetectedSubject.fromJson(Map<String, Object?> json) {
    final typeName = '${json['type'] ?? ''}'.trim();
    final decisionName = '${json['decision'] ?? ''}'.trim();
    final rawSlotIndex = json['slotIndex'] ?? json['slot_index'];
    final rawConfidence = json['confidence'];
    return ReplicateDetectedSubject(
      id: '${json['id'] ?? ''}'.trim(),
      type: ReplicateSubjectType.values.firstWhere(
        (value) => value.name == typeName,
        orElse: () => ReplicateSubjectType.product,
      ),
      label: '${json['label'] ?? ''}'.trim(),
      slotIndex: rawSlotIndex is num
          ? rawSlotIndex.toInt()
          : int.tryParse('$rawSlotIndex') ?? 0,
      description: '${json['description'] ?? ''}'.trim(),
      location: '${json['location'] ?? ''}'.trim(),
      relationship: '${json['relationship'] ?? ''}'.trim(),
      confidence: rawConfidence is num
          ? rawConfidence.toDouble()
          : double.tryParse('$rawConfidence') ?? 0,
      decision: ReplicateSubjectDecision.values.firstWhere(
        (value) => value.name == decisionName,
        orElse: () => ReplicateSubjectDecision.undecided,
      ),
    );
  }
}

class ReplicateShotGuide {
  const ReplicateShotGuide({
    required this.shotId,
    this.sourceFrameFingerprint = '',
    this.elements = const [],
    this.subjects = const [],
    this.fullOutfitAssets = const [],
    this.wearableProductLinks = const [],
    this.productMarkAuthorizations = const [],
    this.actionDescription = '',
    this.poseConstraints = '',
    this.personCount = 0,
    this.depthPath = '',
    this.analysisModel = '',
    this.analysisStatus = ProcessingStatus.pending,
    this.depthStatus = ProcessingStatus.pending,
    this.rawResponse = '',
    this.errorMessage = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String shotId;
  final String sourceFrameFingerprint;
  final List<ReplicatePreservedElement> elements;
  final List<ReplicateDetectedSubject> subjects;
  final List<ReplicateFullOutfitAsset> fullOutfitAssets;
  final List<ReplicateWearableProductLink> wearableProductLinks;
  final List<ReplicateProductMarkAuthorization> productMarkAuthorizations;
  final String actionDescription;
  final String poseConstraints;
  final int personCount;
  final String depthPath;
  final String analysisModel;
  final ProcessingStatus analysisStatus;
  final ProcessingStatus depthStatus;
  final String rawResponse;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  List<ReplicatePreservedElement> get selectedElements =>
      elements.where((element) => element.selected).toList(growable: false);

  List<ReplicatePreservedElement> get unselectedElements =>
      elements.where((element) => !element.selected).toList(growable: false);

  List<ReplicateDetectedSubject> get undecidedSubjects => subjects
      .where(
        (subject) => subject.decision == ReplicateSubjectDecision.undecided,
      )
      .toList(growable: false);

  ReplicateShotGuide copyWith({
    String? sourceFrameFingerprint,
    List<ReplicatePreservedElement>? elements,
    List<ReplicateDetectedSubject>? subjects,
    List<ReplicateFullOutfitAsset>? fullOutfitAssets,
    List<ReplicateWearableProductLink>? wearableProductLinks,
    List<ReplicateProductMarkAuthorization>? productMarkAuthorizations,
    String? actionDescription,
    String? poseConstraints,
    int? personCount,
    String? depthPath,
    String? analysisModel,
    ProcessingStatus? analysisStatus,
    ProcessingStatus? depthStatus,
    String? rawResponse,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ReplicateShotGuide(
    shotId: shotId,
    sourceFrameFingerprint:
        sourceFrameFingerprint ?? this.sourceFrameFingerprint,
    elements: elements ?? this.elements,
    subjects: subjects ?? this.subjects,
    fullOutfitAssets: fullOutfitAssets ?? this.fullOutfitAssets,
    wearableProductLinks: wearableProductLinks ?? this.wearableProductLinks,
    productMarkAuthorizations:
        productMarkAuthorizations ?? this.productMarkAuthorizations,
    actionDescription: actionDescription ?? this.actionDescription,
    poseConstraints: poseConstraints ?? this.poseConstraints,
    personCount: personCount ?? this.personCount,
    depthPath: depthPath ?? this.depthPath,
    analysisModel: analysisModel ?? this.analysisModel,
    analysisStatus: analysisStatus ?? this.analysisStatus,
    depthStatus: depthStatus ?? this.depthStatus,
    rawResponse: rawResponse ?? this.rawResponse,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
