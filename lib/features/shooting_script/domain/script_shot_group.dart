import 'shooting_script_models.dart';

class ScriptShotGroup {
  const ScriptShotGroup(this.shots);

  final List<ScriptShot> shots;

  int get startNumber => shots.first.shotNumber;
  int get endNumber => shots.last.shotNumber;
  String get sourceRangeLabel =>
      startNumber == endNumber ? '$startNumber' : '$startNumber-$endNumber';
  String get rangeLabel => '镜头 $sourceRangeLabel';
  String sequentialRangeLabel(int sequenceNumber) =>
      '$sequenceNumber（$sourceRangeLabel）';
  String get frameRangeLabel => startNumber == endNumber
      ? '第 $startNumber 帧'
      : '第 $startNumber-$endNumber 帧';
  double get durationSeconds => shots.last.durationSeconds;
  String get scriptText =>
      mergeText(shots.expand((shot) => [shot.content, shot.visual]));
  String get cameraMovement => _summarizeCameraMovement(shots);
  String get cameraDesignText =>
      mergeText(shots.map((shot) => shot.cameraMovement));
  String get compositionAndAngleText => mergeText(
    shots.map(
      (shot) => [
        if (shot.composition.trim().isNotEmpty) '构图：${shot.composition.trim()}',
        if (shot.cameraAngle.trim().isNotEmpty) '机位：${shot.cameraAngle.trim()}',
      ].join('；'),
    ),
  );
  String get focusAndTransitionText => mergeText(
    shots.map(
      (shot) => [
        if (shot.visualFocus.trim().isNotEmpty) '焦点：${shot.visualFocus.trim()}',
        if (shot.transitionHint.trim().isNotEmpty)
          '衔接：${shot.transitionHint.trim()}',
      ].join('；'),
    ),
  );
  String get cameraNotesText =>
      mergeText(shots.map((shot) => shot.cameraNotes));
  String get storyText => _storyTextForGroup(shots);
  String get sceneText => mergeInlineText(shots.map((shot) => shot.scene));
  String get focusText =>
      mergeInlineText(shots.map((shot) => shot.visualFocus));

  static List<ScriptShotGroup> group(List<ScriptShot> shots) {
    if (shots.isEmpty) return const [];
    final ordered = [...shots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final groups = <ScriptShotGroup>[];
    var current = <ScriptShot>[];
    for (var index = 0; index < ordered.length; index++) {
      final shot = ordered[index];
      current.add(shot);
      final next = index + 1 < ordered.length ? ordered[index + 1] : null;
      final continues =
          next != null && shot.continuesToNext && next.continuesFromPrevious;
      if (!continues) {
        groups.add(ScriptShotGroup(List.unmodifiable(current)));
        current = <ScriptShot>[];
      }
    }
    return groups;
  }

  static String mergeText(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .join('\n');

  static String mergeInlineText(Iterable<String> values, {int maxItems = 3}) {
    final items = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(maxItems)
        .toList(growable: false);
    return items.join(' / ');
  }

  static String globalStoryText(List<ScriptShotGroup> groups) {
    if (groups.isEmpty) return '暂无可核对的分镜故事。';
    final first = groups.first.storyText;
    final last = groups.last.storyText;
    final sceneText = mergeInlineText(
      groups.expand((group) => group.shots).map((shot) => shot.scene),
      maxItems: 4,
    );
    final movements = mergeInlineText(
      groups.map((group) => group.cameraMovement),
      maxItems: 4,
    );
    if (groups.length == 1) {
      return '全局故事围绕$first展开，场景${sceneText.isEmpty ? '待补充' : sceneText}，运镜以${movements.isEmpty ? '待补充' : movements}为主。';
    }
    return '全局故事从$first开始，按 ${groups.length} 个连续镜头组推进，最终落到$last。场景${sceneText.isEmpty ? '待补充' : sceneText}，运镜以${movements.isEmpty ? '待补充' : movements}为主。';
  }

  static String _storyTextForGroup(List<ScriptShot> shots) {
    final content = mergeInlineText(shots.map((shot) => shot.content));
    if (content.isNotEmpty) return content;
    final visual = mergeInlineText(shots.map((shot) => shot.visual));
    if (visual.isNotEmpty) return visual;
    final focus = mergeInlineText(shots.map((shot) => shot.visualFocus));
    return focus.isEmpty ? '暂无分镜故事内容' : focus;
  }

  static String _summarizeCameraMovement(List<ScriptShot> shots) {
    final movementText = shots
        .map(
          (shot) => [
            shot.cameraMovement,
            shot.movementTrend,
            shot.cameraNotes,
            shot.visual,
            shot.content,
          ].join(' '),
        )
        .join(' ');
    final hasLowerBodyToFace =
        shots.isNotEmpty &&
        (shots.first.visual.contains('下半身') ||
            shots.first.content.contains('下半身')) &&
        shots
            .skip(1)
            .any(
              (shot) => shot.visual.contains('脸') || shot.content.contains('脸'),
            );
    final rises =
        _containsMovementTerm(movementText, const [
          '上升',
          '上移',
          '向上',
          '抬升',
          '升起',
          '由下至上',
          '从下到上',
        ]) ||
        hasLowerBodyToFace;
    final pushes =
        _containsMovementTerm(movementText, const [
          '推进',
          '推近',
          '靠近',
          '接近',
          '向前',
          '拉近',
        ]) ||
        hasLowerBodyToFace ||
        _getsCloser(shots);
    final pulls = _containsMovementTerm(movementText, const [
      '拉远',
      '远离',
      '后退',
      '向后',
    ]);
    final pans = _containsMovementTerm(movementText, const [
      '横移',
      '平移',
      '左移',
      '右移',
      '向左',
      '向右',
    ]);
    final follows = _containsMovementTerm(movementText, const ['跟拍', '跟随']);
    final orbits = _containsMovementTerm(movementText, const ['环绕', '绕行']);

    if (rises && pushes) return '升降推进镜头';
    if (rises && pulls) return '升降拉远镜头';
    final movements = <String>[
      if (rises) '升降镜头',
      if (pushes) '推进镜头',
      if (pulls) '拉远镜头',
      if (pans) '横移镜头',
      if (follows) '跟拍镜头',
      if (orbits) '环绕镜头',
    ];
    if (movements.isNotEmpty) return movements.join(' + ');
    final explicit = mergeText(shots.map((shot) => shot.cameraMovement));
    return explicit.isEmpty ? '固定镜头' : explicit;
  }

  static bool _containsMovementTerm(String value, List<String> terms) =>
      terms.any(value.contains);

  static bool _getsCloser(List<ScriptShot> shots) {
    if (shots.length < 2) return false;
    return _shotSizeRank(shots.last.shotSize) >
        _shotSizeRank(shots.first.shotSize);
  }

  static int _shotSizeRank(String value) {
    if (value.contains('特写') || value.contains('大特')) return 5;
    if (value.contains('近景')) return 4;
    if (value.contains('中近')) return 3;
    if (value.contains('中景')) return 2;
    if (value.contains('全景') || value.contains('中全')) return 1;
    return 0;
  }
}
