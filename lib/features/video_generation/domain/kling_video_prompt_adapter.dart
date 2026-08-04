import '../../shooting_script/domain/shooting_script_models.dart';

class KlingVideoPromptAdapter {
  const KlingVideoPromptAdapter();

  String adapt(
    ScriptShot shot, {
    String? sourcePrompt,
    List<ScriptShot> actionSequence = const [],
    int availableImageReferences = 0,
    int availableVideoReferences = 0,
    String globalStyle = '',
    String constraints = '',
  }) {
    final providedPrompt = sourcePrompt?.trim() ?? '';
    final sequence = actionSequence.isEmpty
        ? <ScriptShot>[shot]
        : actionSequence;
    final hasTailReference =
        sequence.length > 1 && availableImageReferences >= 2;
    final normalizedProvided = _normalizeKlingImageLead(providedPrompt);
    if (_isKlingPrompt(normalizedProvided) &&
        (!hasTailReference || _mentionsTailReference(normalizedProvided))) {
      return normalizedProvided;
    }
    final original = removeUnavailableReferences(
      sourcePrompt ?? shot.prompt,
      availableImageReferences: availableImageReferences,
      availableVideoReferences: availableVideoReferences,
    );
    final subjectAndMotion = _joinUnique([
      shot.content,
      shot.visual,
      _sequenceMotion(sequence),
      original,
    ]);
    final background = _joinUnique([shot.scene]);
    final camera = _joinUnique([
      shot.shotSize,
      shot.cameraMovement,
      shot.composition,
      shot.cameraAngle,
      shot.cameraNotes,
    ]);
    final lighting = _joinUnique([
      shot.lightingMood,
      shot.colorPalette,
      shot.visualFocus,
    ]);
    final constraintText = _joinUnique([
      shot.replicationInstructions,
      shot.transitionHint,
      constraints,
    ]);
    return [
      if (availableImageReferences > 0) '以图片1作为首帧和主体外观参考',
      if (hasTailReference) '以图片2作为尾帧和动作结果参考',
      if (hasTailReference) '从图片1自然过渡到图片2，按完整动作过程连贯生成',
      if (subjectAndMotion.isNotEmpty) '主体与动作：$subjectAndMotion',
      if (background.isNotEmpty) '背景与运动：$background',
      if (camera.isNotEmpty) '镜头语言：$camera',
      if (lighting.isNotEmpty) '光影氛围：$lighting',
      if (shot.dialogue.trim().isNotEmpty) '对白：${shot.dialogue.trim()}',
      if (shot.sound.trim().isNotEmpty) '声音：${shot.sound.trim()}',
      if (globalStyle.trim().isNotEmpty) '整体风格：${globalStyle.trim()}',
      if (constraintText.isNotEmpty) '约束：$constraintText',
    ].join('；');
  }

  String removeUnavailableReferences(
    String prompt, {
    int availableImageReferences = 0,
    int availableVideoReferences = 0,
  }) {
    var result = prompt;
    result = result.replaceAllMapped(
      RegExp(r'@?(?:参考)?(?:图片|图)\s*(\d+)', caseSensitive: false),
      (match) => _keepReference(match, availableImageReferences),
    );
    result = result.replaceAllMapped(
      RegExp(r'@?(?:参考)?视频\s*(\d+)', caseSensitive: false),
      (match) => _keepReference(match, availableVideoReferences),
    );
    result = result
        .replaceAll(RegExp(r'\s*[,，、;；]\s*[,，、;；]+'), '，')
        .replaceAll(RegExp(r'^[\s,，、;；:：]+|[\s,，、;；:：]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return result;
  }

  static String _keepReference(Match match, int availableCount) {
    final number = int.tryParse(match.group(1) ?? '') ?? 0;
    return number > 0 && number <= availableCount ? match.group(0)! : '';
  }

  static String _joinUnique(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      result.add(normalized);
    }
    return result.join('，');
  }

  static String _sequenceMotion(List<ScriptShot> sequence) {
    if (sequence.length < 2) return '';
    final parts = <String>[];
    for (var index = 0; index < sequence.length; index++) {
      final shot = sequence[index];
      final role = index == 0
          ? '首帧'
          : index == sequence.length - 1
          ? '尾帧'
          : '中间动作';
      final description = _joinUnique([
        shot.actionStage,
        shot.content,
        shot.visual,
        shot.movementTrend,
      ]);
      if (description.isEmpty) continue;
      parts.add(
        '镜头${index + 1}，${_durationText(shot.durationSeconds)}，'
        '$role（原镜头${shot.shotNumber}）：$description',
      );
    }
    return parts.isEmpty ? '' : '镜头时序：${parts.join('；')}';
  }

  static String _normalizeKlingImageLead(String prompt) => prompt
      .replaceFirst('以输入图片作为首帧和主体外观参考', '以图片1作为首帧和主体外观参考')
      .replaceFirst('以@图片1作为首帧和主体外观参考', '以图片1作为首帧和主体外观参考');

  static bool _isKlingPrompt(String prompt) =>
      prompt.startsWith('以图片1作为首帧和主体外观参考');

  static bool _mentionsTailReference(String prompt) =>
      prompt.contains('图片2') || prompt.contains('尾帧');

  static String _durationText(num seconds) {
    final rounded = seconds.roundToDouble();
    return seconds == rounded
        ? '${rounded.toInt()}s'
        : '${seconds.toStringAsFixed(1)}s';
  }
}
