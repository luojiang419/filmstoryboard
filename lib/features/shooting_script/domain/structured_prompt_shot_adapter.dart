import 'shooting_script_models.dart';
import 'shooting_script_workflow_models.dart';

class StructuredPromptShotAdapter {
  const StructuredPromptShotAdapter();

  ScriptShot apply(ScriptShot shot, ScriptShotPromptContext context) {
    if (context.isEmpty) return shot;
    final bodyAction = (context.action['bodyAction'] ?? '').trim();
    final subjectAndAction = _joinUnique([
      context.subject['people'] ?? '',
      bodyAction.isEmpty ? context.continuity['caption'] ?? '' : bodyAction,
      context.subject['expression'] ?? '',
      context.scene['subjectDirection'] ?? '',
      context.scene['gazeDirection'] ?? '',
      context.scene['spatialRelation'] ?? '',
    ]);
    final structuredNotes = _joinUnique([
      _labeled('主体朝向', context.scene['subjectDirection']),
      _labeled('视线', context.scene['gazeDirection']),
      _labeled('空间关系', context.scene['spatialRelation']),
      _labeled('动作阶段', context.action['actionStage']),
      _labeled('时间进度', context.continuity['chronologyCue']),
      _labeled('叙事功能', context.continuity['narrativeFunction']),
    ]);
    return shot.copyWith(
      content: _joinUnique([shot.content, subjectAndAction]),
      shotSize: _prefer(shot.shotSize, context.camera['shotSize']),
      cameraMovement: _prefer(
        shot.cameraMovement,
        context.camera['cameraMovement'],
      ),
      cameraNotes: _joinUnique([shot.cameraNotes, structuredNotes]),
      composition: _prefer(shot.composition, context.camera['composition']),
      cameraAngle: _prefer(shot.cameraAngle, context.camera['cameraAngle']),
      lightingMood: _prefer(
        shot.lightingMood,
        context.visualStyle['lightingMood'],
      ),
      colorPalette: _prefer(
        shot.colorPalette,
        context.visualStyle['colorPalette'],
      ),
      visualFocus: _prefer(shot.visualFocus, context.camera['visualFocus']),
      transitionHint: _prefer(
        shot.transitionHint,
        context.continuity['transitionHint'],
      ),
      movementTrend: _prefer(
        shot.movementTrend,
        context.action['movementTrend'],
      ),
      actionStage: _prefer(shot.actionStage, context.action['actionStage']),
      scene: _prefer(shot.scene, context.scene['location']),
      sound: _prefer(shot.sound, context.audio['sound']),
    );
  }

  static String _prefer(String existing, String? fallback) =>
      existing.trim().isNotEmpty ? existing.trim() : (fallback ?? '').trim();

  static String _labeled(String label, String? value) {
    final normalized = (value ?? '').trim();
    return normalized.isEmpty ? '' : '$label：$normalized';
  }

  static String _joinUnique(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      result.add(normalized);
    }
    return result.join('；');
  }
}
