import '../../replicate/domain/replicate_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';

/// A copy of an asset that is available to one shooting script.
///
/// The library item is the reusable source; this script-scoped record owns
/// the stable reference number used by prompt generation.
class ScriptAsset {
  const ScriptAsset({
    required this.id,
    required this.scriptId,
    this.libraryAssetId,
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
  final String scriptId;
  final String? libraryAssetId;
  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
  final int referenceNumber;
  final ProcessingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScriptAsset copyWith({
    String? libraryAssetId,
    ReplicateAssetType? type,
    String? name,
    String? description,
    String? path,
    int? referenceNumber,
    ProcessingStatus? status,
    DateTime? updatedAt,
  }) => ScriptAsset(
    id: id,
    scriptId: scriptId,
    libraryAssetId: libraryAssetId ?? this.libraryAssetId,
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

enum ScriptAssetMatchSource { manual, rule, model }

class ScriptShotAssetLink {
  const ScriptShotAssetLink({
    required this.shotId,
    required this.scriptAssetId,
    required this.matchSource,
    required this.confidence,
    required this.matchReason,
    required this.confirmed,
    required this.locked,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  final String shotId;
  final String scriptAssetId;
  final ScriptAssetMatchSource matchSource;
  final double confidence;
  final String matchReason;
  final bool confirmed;
  final bool locked;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScriptShotAssetLink copyWith({
    ScriptAssetMatchSource? matchSource,
    double? confidence,
    String? matchReason,
    bool? confirmed,
    bool? locked,
    int? sortOrder,
    DateTime? updatedAt,
  }) => ScriptShotAssetLink(
    shotId: shotId,
    scriptAssetId: scriptAssetId,
    matchSource: matchSource ?? this.matchSource,
    confidence: confidence ?? this.confidence,
    matchReason: matchReason ?? this.matchReason,
    confirmed: confirmed ?? this.confirmed,
    locked: locked ?? this.locked,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ScriptShotPromptContext {
  static const currentSchemaVersion = 2;

  const ScriptShotPromptContext({
    this.subject = const {},
    this.action = const {},
    this.scene = const {},
    this.camera = const {},
    this.visualStyle = const {},
    this.continuity = const {},
    this.audio = const {},
  });

  final Map<String, String> subject;
  final Map<String, String> action;
  final Map<String, String> scene;
  final Map<String, String> camera;
  final Map<String, String> visualStyle;
  final Map<String, String> continuity;
  final Map<String, String> audio;

  bool get isEmpty =>
      subject.isEmpty &&
      action.isEmpty &&
      scene.isEmpty &&
      camera.isEmpty &&
      visualStyle.isEmpty &&
      continuity.isEmpty &&
      audio.isEmpty;

  Map<String, Object> toJson() => {
    'subject': subject,
    'action': action,
    'scene': scene,
    'camera': camera,
    'visualStyle': visualStyle,
    'continuity': continuity,
    'audio': audio,
  };

  factory ScriptShotPromptContext.fromJson(Map<dynamic, dynamic> json) =>
      ScriptShotPromptContext(
        subject: _stringMap(json['subject']),
        action: _stringMap(json['action']),
        scene: _stringMap(json['scene']),
        camera: _stringMap(json['camera']),
        visualStyle: _stringMap(json['visualStyle']),
        continuity: _stringMap(json['continuity']),
        audio: _stringMap(json['audio']),
      );

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return Map.unmodifiable(
      value.map((key, item) => MapEntry('$key', item == null ? '' : '$item')),
    );
  }
}

class ScriptShotAnalysisRecord {
  const ScriptShotAnalysisRecord({
    required this.id,
    required this.shotId,
    required this.model,
    required this.status,
    required this.fieldSources,
    required this.fieldConfidence,
    this.promptContext = const ScriptShotPromptContext(),
    this.promptContextSchemaVersion = 0,
    this.sourceImageFingerprint = '',
    this.analysisRuleVersion = 0,
    required this.rawResponse,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String shotId;
  final String model;
  final ProcessingStatus status;
  final Map<String, String> fieldSources;
  final Map<String, double> fieldConfidence;
  final ScriptShotPromptContext promptContext;
  final int promptContextSchemaVersion;
  final String sourceImageFingerprint;
  final int analysisRuleVersion;
  final String rawResponse;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScriptShotAnalysisRecord copyWith({
    String? model,
    ProcessingStatus? status,
    Map<String, String>? fieldSources,
    Map<String, double>? fieldConfidence,
    ScriptShotPromptContext? promptContext,
    int? promptContextSchemaVersion,
    String? sourceImageFingerprint,
    int? analysisRuleVersion,
    String? rawResponse,
    String? errorMessage,
    DateTime? updatedAt,
  }) => ScriptShotAnalysisRecord(
    id: id,
    shotId: shotId,
    model: model ?? this.model,
    status: status ?? this.status,
    fieldSources: fieldSources ?? this.fieldSources,
    fieldConfidence: fieldConfidence ?? this.fieldConfidence,
    promptContext: promptContext ?? this.promptContext,
    promptContextSchemaVersion:
        promptContextSchemaVersion ?? this.promptContextSchemaVersion,
    sourceImageFingerprint:
        sourceImageFingerprint ?? this.sourceImageFingerprint,
    analysisRuleVersion: analysisRuleVersion ?? this.analysisRuleVersion,
    rawResponse: rawResponse ?? this.rawResponse,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
