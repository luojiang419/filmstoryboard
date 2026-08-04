import 'shooting_script_models.dart';

class ScriptShotContinuityRefiner {
  const ScriptShotContinuityRefiner();

  List<ScriptShot> refine(List<ScriptShot> shots) {
    if (shots.length < 2) return shots;
    final ordered = [...shots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final result = <ScriptShot>[...ordered];
    for (var index = 0; index + 1 < result.length; index++) {
      final previous = result[index];
      final next = result[index + 1];
      final connected = _shouldConnect(previous, next);
      result[index] = previous.copyWith(continuesToNext: connected);
      result[index + 1] = next.copyWith(continuesFromPrevious: connected);
    }
    return result;
  }

  bool _shouldConnect(ScriptShot previous, ScriptShot next) {
    if (!_sameScene(previous.scene, next.scene)) return false;
    if (previous.continuesToNext && next.continuesFromPrevious) return true;
    if (_oneSideConfirmed(previous, next) &&
        _hasMotionEvidence(previous, next)) {
      return true;
    }
    return _hasProgressiveStage(previous, next) &&
        _hasSharedAction(previous, next);
  }

  bool _oneSideConfirmed(ScriptShot previous, ScriptShot next) =>
      previous.continuesToNext || next.continuesFromPrevious;

  bool _sameScene(String first, String second) {
    final a = _normalizeScene(first);
    final b = _normalizeScene(second);
    return a.isEmpty || b.isEmpty || a == b;
  }

  bool _hasMotionEvidence(ScriptShot previous, ScriptShot next) {
    final text = [
      previous.content,
      previous.visual,
      previous.movementTrend,
      previous.actionStage,
      next.content,
      next.visual,
      next.movementTrend,
      next.actionStage,
    ].join(' ');
    return !_containsAny(text, const ['静止不明显', '静态展示', '不明显']) &&
        _containsAny(text, const [
          '走',
          '跑',
          '举',
          '伸',
          '转',
          '靠近',
          '远离',
          '起身',
          '坐下',
          '推进',
          '完成',
          '动作',
        ]);
  }

  bool _hasProgressiveStage(ScriptShot previous, ScriptShot next) {
    final from = _stageRank(previous.actionStage);
    final to = _stageRank(next.actionStage);
    return from != null && to != null && to >= from && to - from <= 3;
  }

  bool _hasSharedAction(ScriptShot previous, ScriptShot next) {
    final first = _actionTokens(previous).toSet();
    final second = _actionTokens(next).toSet();
    return first.intersection(second).isNotEmpty;
  }

  Iterable<String> _actionTokens(ScriptShot shot) sync* {
    final text = [
      shot.content,
      shot.visual,
      shot.movementTrend,
      shot.visualFocus,
    ].join(' ');
    for (final match in RegExp(r'[\u4e00-\u9fa5]{2,}').allMatches(text)) {
      final value = match.group(0)!;
      if (_ignoredToken(value)) continue;
      yield value.length > 4 ? value.substring(0, 4) : value;
    }
  }

  int? _stageRank(String value) {
    final normalized = value.trim();
    if (normalized.contains('建立')) return 0;
    if (normalized.contains('准备')) return 1;
    if (normalized.contains('进行')) return 2;
    if (normalized.contains('结果') || normalized.contains('完成')) return 3;
    if (normalized.contains('收束')) return 4;
    return null;
  }

  bool _ignoredToken(String value) =>
      value == '人物' ||
      value == '女模特' ||
      value == '男模特' ||
      value == '画面' ||
      value == '镜头' ||
      value == '主体';

  bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);

  String _normalizeScene(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s，,。；;、]+'), '');
}
