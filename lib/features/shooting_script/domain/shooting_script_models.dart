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
    this.sourceStoryboardAssetId,
    this.sourceVideoFrameId,
    required this.shotNumber,
    required this.durationSeconds,
    required this.framePath,
    required this.visual,
    required this.content,
    required this.shotSize,
    required this.cameraMovement,
    required this.cameraNotes,
    this.composition = '',
    this.cameraAngle = '',
    this.lightingMood = '',
    this.colorPalette = '',
    this.visualFocus = '',
    this.transitionHint = '',
    this.movementTrend = '',
    this.actionStage = '',
    this.continuesFromPrevious = false,
    this.continuesToNext = false,
    required this.scene,
    required this.productCode,
    required this.productStyling,
    required this.dialogue,
    required this.sound,
    required this.prompt,
    this.replicationInstructions = '',
    required this.status,
    required this.updatedAt,
  });

  final String id;
  final String scriptId;
  final String? sourceStoryboardAssetId;
  final String? sourceVideoFrameId;
  final int shotNumber;
  final double durationSeconds;
  final String framePath;
  final String visual;
  final String content;
  final String shotSize;
  final String cameraMovement;
  final String cameraNotes;
  final String composition;
  final String cameraAngle;
  final String lightingMood;
  final String colorPalette;
  final String visualFocus;
  final String transitionHint;
  final String movementTrend;
  final String actionStage;
  final bool continuesFromPrevious;
  final bool continuesToNext;
  final String scene;
  final String productCode;
  final String productStyling;
  final String dialogue;
  final String sound;
  final String prompt;
  final String replicationInstructions;
  final ProcessingStatus status;
  final DateTime updatedAt;

  ScriptShot copyWith({
    String? scriptId,
    Object? sourceStoryboardAssetId = _copyWithSentinel,
    Object? sourceVideoFrameId = _copyWithSentinel,
    int? shotNumber,
    double? durationSeconds,
    String? framePath,
    String? visual,
    String? content,
    String? shotSize,
    String? cameraMovement,
    String? cameraNotes,
    String? composition,
    String? cameraAngle,
    String? lightingMood,
    String? colorPalette,
    String? visualFocus,
    String? transitionHint,
    String? movementTrend,
    String? actionStage,
    bool? continuesFromPrevious,
    bool? continuesToNext,
    String? scene,
    String? productCode,
    String? productStyling,
    String? dialogue,
    String? sound,
    String? prompt,
    String? replicationInstructions,
    ProcessingStatus? status,
    DateTime? updatedAt,
  }) => ScriptShot(
    id: id,
    scriptId: scriptId ?? this.scriptId,
    sourceStoryboardAssetId:
        identical(sourceStoryboardAssetId, _copyWithSentinel)
        ? this.sourceStoryboardAssetId
        : sourceStoryboardAssetId as String?,
    sourceVideoFrameId: identical(sourceVideoFrameId, _copyWithSentinel)
        ? this.sourceVideoFrameId
        : sourceVideoFrameId as String?,
    shotNumber: shotNumber ?? this.shotNumber,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    framePath: framePath ?? this.framePath,
    visual: visual ?? this.visual,
    content: content ?? this.content,
    shotSize: shotSize ?? this.shotSize,
    cameraMovement: cameraMovement ?? this.cameraMovement,
    cameraNotes: cameraNotes ?? this.cameraNotes,
    composition: composition ?? this.composition,
    cameraAngle: cameraAngle ?? this.cameraAngle,
    lightingMood: lightingMood ?? this.lightingMood,
    colorPalette: colorPalette ?? this.colorPalette,
    visualFocus: visualFocus ?? this.visualFocus,
    transitionHint: transitionHint ?? this.transitionHint,
    movementTrend: movementTrend ?? this.movementTrend,
    actionStage: actionStage ?? this.actionStage,
    continuesFromPrevious: continuesFromPrevious ?? this.continuesFromPrevious,
    continuesToNext: continuesToNext ?? this.continuesToNext,
    scene: scene ?? this.scene,
    productCode: productCode ?? this.productCode,
    productStyling: productStyling ?? this.productStyling,
    dialogue: dialogue ?? this.dialogue,
    sound: sound ?? this.sound,
    prompt: prompt ?? this.prompt,
    replicationInstructions:
        replicationInstructions ?? this.replicationInstructions,
    status: status ?? this.status,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

const _copyWithSentinel = Object();

/// Parses the old composite camera-notes value written by script analysis.
///
/// Older scripts stored several visual dimensions as one string such as
/// "构图：…；机位：…；光影：…". New records keep these dimensions separately,
/// but reading old records through this parser prevents the legacy value from
/// polluting the light/mood column.
class ScriptShotVisualFields {
  const ScriptShotVisualFields({
    this.cameraNotes = '',
    this.composition = '',
    this.cameraAngle = '',
    this.lightingMood = '',
    this.colorPalette = '',
    this.visualFocus = '',
    this.transitionHint = '',
  });

  final String cameraNotes;
  final String composition;
  final String cameraAngle;
  final String lightingMood;
  final String colorPalette;
  final String visualFocus;
  final String transitionHint;

  factory ScriptShotVisualFields.fromLegacyCameraNotes(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return const ScriptShotVisualFields();
    }
    final matches =
        RegExp(
          r'构图|机位(?:角度)?|光影(?:/氛围)?|光线情绪|色彩(?:调性)?|视觉焦点|衔接|剪辑承接',
        ).allMatches(normalized).where((match) {
          final after = normalized.substring(match.end);
          return RegExp(r'^\s*[:：]').hasMatch(after);
        }).toList();
    if (matches.isEmpty) {
      return ScriptShotVisualFields(cameraNotes: normalized);
    }

    var composition = '';
    var cameraAngle = '';
    var lightingMood = '';
    var colorPalette = '';
    var visualFocus = '';
    var transitionHint = '';
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final nextStart = index + 1 < matches.length
          ? matches[index + 1].start
          : normalized.length;
      final content = normalized
          .substring(match.end, nextStart)
          .replaceFirst(RegExp(r'^\s*[:：]\s*'), '')
          .replaceFirst(RegExp(r'[；;]\s*$'), '')
          .trim();
      if (content.isEmpty) continue;
      switch (match.group(0)) {
        case '构图':
          composition = content;
          break;
        case '机位':
        case '机位角度':
          cameraAngle = content;
          break;
        case '光影':
        case '光影/氛围':
        case '光线情绪':
          lightingMood = content;
          break;
        case '色彩':
        case '色彩调性':
          colorPalette = content;
          break;
        case '视觉焦点':
          visualFocus = content;
          break;
        case '衔接':
        case '剪辑承接':
          transitionHint = content;
          break;
      }
    }
    return ScriptShotVisualFields(
      composition: composition,
      cameraAngle: cameraAngle,
      lightingMood: lightingMood,
      colorPalette: colorPalette,
      visualFocus: visualFocus,
      transitionHint: transitionHint,
    );
  }
}
