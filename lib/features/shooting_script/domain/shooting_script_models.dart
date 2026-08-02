import '../../video_analysis/domain/video_analysis_models.dart';

enum ShootingScriptStatus { draft, active, archived }

class ShootingScript {
  const ShootingScript({
    required this.id,
    required this.name,
    required this.sourceStoryboardId,
    required this.sourceVideoId,
    required this.status,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? sourceStoryboardId;
  final String? sourceVideoId;
  final ShootingScriptStatus status;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  ShootingScript copyWith({
    String? name,
    String? sourceStoryboardId,
    String? sourceVideoId,
    ShootingScriptStatus? status,
    int? version,
    DateTime? updatedAt,
  }) => ShootingScript(
    id: id,
    name: name ?? this.name,
    sourceStoryboardId: sourceStoryboardId ?? this.sourceStoryboardId,
    sourceVideoId: sourceVideoId ?? this.sourceVideoId,
    status: status ?? this.status,
    version: version ?? this.version,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class ScriptShot {
  const ScriptShot({
    required this.id,
    required this.scriptId,
    required this.shotNumber,
    required this.durationSeconds,
    required this.framePath,
    required this.visual,
    required this.content,
    required this.shotSize,
    required this.cameraMovement,
    required this.cameraNotes,
    required this.scene,
    required this.productCode,
    required this.productStyling,
    required this.dialogue,
    required this.sound,
    required this.prompt,
    required this.status,
    required this.updatedAt,
  });

  final String id;
  final String scriptId;
  final int shotNumber;
  final double durationSeconds;
  final String framePath;
  final String visual;
  final String content;
  final String shotSize;
  final String cameraMovement;
  final String cameraNotes;
  final String scene;
  final String productCode;
  final String productStyling;
  final String dialogue;
  final String sound;
  final String prompt;
  final ProcessingStatus status;
  final DateTime updatedAt;

  ScriptShot copyWith({
    String? scriptId,
    int? shotNumber,
    double? durationSeconds,
    String? framePath,
    String? visual,
    String? content,
    String? shotSize,
    String? cameraMovement,
    String? cameraNotes,
    String? scene,
    String? productCode,
    String? productStyling,
    String? dialogue,
    String? sound,
    String? prompt,
    ProcessingStatus? status,
    DateTime? updatedAt,
  }) => ScriptShot(
    id: id,
    scriptId: scriptId ?? this.scriptId,
    shotNumber: shotNumber ?? this.shotNumber,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    framePath: framePath ?? this.framePath,
    visual: visual ?? this.visual,
    content: content ?? this.content,
    shotSize: shotSize ?? this.shotSize,
    cameraMovement: cameraMovement ?? this.cameraMovement,
    cameraNotes: cameraNotes ?? this.cameraNotes,
    scene: scene ?? this.scene,
    productCode: productCode ?? this.productCode,
    productStyling: productStyling ?? this.productStyling,
    dialogue: dialogue ?? this.dialogue,
    sound: sound ?? this.sound,
    prompt: prompt ?? this.prompt,
    status: status ?? this.status,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
