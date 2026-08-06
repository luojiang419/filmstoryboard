import '../../shooting_script/domain/shooting_script_models.dart';

class H3VideoPromptAdapter {
  const H3VideoPromptAdapter();

  String adapt(
    ScriptShot shot, {
    String sourcePrompt = '',
    List<ScriptShot> actionSequence = const [],
    int availableImageReferences = 0,
    int availableVideoReferences = 0,
    int availableAudioReferences = 0,
    String globalStyle = '',
    String constraints = '',
    List<String> referenceDefinitions = const [],
  }) {
    final sequence = actionSequence.isEmpty
        ? <ScriptShot>[shot]
        : actionSequence;
    final references = _referenceText(
      sequence: sequence,
      availableImageReferences: availableImageReferences,
      availableVideoReferences: availableVideoReferences,
      availableAudioReferences: availableAudioReferences,
      hasTailFrame: sequence.length > 1 && availableImageReferences >= 2,
      referenceDefinitions: referenceDefinitions,
    );
    final creative = _joinUnique([
      '${_durationText(_sequenceDuration(sequence))}视频',
      globalStyle,
      shot.lightingMood,
      shot.colorPalette,
      shot.visualFocus,
      _sourceCreativeText(sourcePrompt),
    ]);
    final visualProcess = sequence.length > 1
        ? _sequenceProcess(sequence)
        : _singleShotProcess(shot);
    final requirements = _joinUnique([
      '画面具体可见，少用抽象比喻',
      '主体外观、空间关系、动作方向、光源方向和镜头距离保持稳定',
      if (sequence.length > 1 && availableImageReferences >= 2)
        '只补足@图片1到@图片2之间的动作、光影和声音变化，不主动新增切镜',
      shot.replicationInstructions,
      constraints,
      '不要字幕、不要水印、不要乱码文字、不要无关Logo',
    ]);
    return [
      '【参考素材说明】',
      references,
      '',
      '【核心创意】',
      creative.isEmpty ? _fallbackCreative(shot) : creative,
      '',
      '【画面过程描述】',
      visualProcess,
      '',
      '【整体要求补充】',
      requirements,
      '',
      '【声音设计】',
      _soundDesign(sequence),
      '',
      '非叙事性音乐：${_musicText(sequence)}',
    ].join('\n');
  }

  static String _referenceText({
    required List<ScriptShot> sequence,
    required int availableImageReferences,
    required int availableVideoReferences,
    required int availableAudioReferences,
    required bool hasTailFrame,
    required List<String> referenceDefinitions,
  }) {
    final lines = <String>[];
    if (sequence.length > 2 && availableImageReferences >= sequence.length) {
      lines.add('@图片1 是首帧参考图，锁定视频开头画面、主体外观、构图和光影。');
      for (var index = 1; index < sequence.length - 1; index++) {
        lines.add(
          '@图片${index + 1} 是镜头${sequence[index].shotNumber}中间动作参考帧，锁定组内动作阶段、主体位置、构图和光影变化。',
        );
      }
      lines.add('@图片${sequence.length} 是尾帧参考图，锁定视频结尾画面、动作结果、构图和光影。');
    } else if (hasTailFrame) {
      lines.add('@图片1 是首帧参考图，锁定视频开头画面、主体外观、构图和光影。');
      lines.add('@图片2 是尾帧参考图，锁定视频结尾画面、动作结果、构图和光影。');
    } else if (availableImageReferences > 0) {
      lines.add('@图片1 是画面参考图，用于锁定主体外观、场景空间、构图、光影和整体视觉质感。');
    }
    for (var index = 1; index <= availableVideoReferences; index++) {
      lines.add('@视频$index 是动作、运镜和剪辑节奏参考。');
    }
    for (var index = 1; index <= availableAudioReferences; index++) {
      lines.add('@音频$index 是声音节奏、情绪和氛围参考。');
    }
    lines.addAll(referenceDefinitions);
    if (lines.isEmpty) return '无参考素材（纯文字生成视频）。';
    return lines.join('\n');
  }

  static String _singleShotProcess(ScriptShot shot) {
    final seconds = shot.durationSeconds <= 0 ? 4 : shot.durationSeconds;
    final parts = _joinUnique([
      shot.shotSize,
      shot.content,
      if (shot.scene.trim().isNotEmpty) '场景：${shot.scene.trim()}',
      if (shot.composition.trim().isNotEmpty) '构图：${shot.composition.trim()}',
      if (shot.cameraAngle.trim().isNotEmpty) '机位：${shot.cameraAngle.trim()}',
      if (shot.cameraMovement.trim().isNotEmpty)
        '运镜：${shot.cameraMovement.trim()}',
      if (shot.cameraNotes.trim().isNotEmpty) '摄影备注：${shot.cameraNotes.trim()}',
      if (shot.dialogue.trim().isNotEmpty) '台词：${_dialogueText(shot.dialogue)}',
      if (shot.sound.trim().isNotEmpty) '音效：${shot.sound.trim()}',
    ]);
    return '0-${_durationText(seconds)}：$parts';
  }

  static String _sequenceProcess(List<ScriptShot> sequence) {
    final lines = <String>[];
    var elapsed = 0.0;
    for (final shot in sequence) {
      final duration = shot.durationSeconds <= 0 ? 1.0 : shot.durationSeconds;
      final next = elapsed + duration;
      final parts = _joinUnique([
        shot.shotSize,
        shot.actionStage,
        shot.content,
        shot.visual,
        shot.movementTrend,
        if (shot.scene.trim().isNotEmpty) '场景：${shot.scene.trim()}',
        if (shot.cameraMovement.trim().isNotEmpty)
          '运镜：${shot.cameraMovement.trim()}',
        if (shot.dialogue.trim().isNotEmpty)
          '台词：${_dialogueText(shot.dialogue)}',
        if (shot.sound.trim().isNotEmpty) '音效：${shot.sound.trim()}',
      ]);
      lines.add('${_durationText(elapsed)}-${_durationText(next)}：$parts');
      elapsed = next;
    }
    return lines.join('\n');
  }

  static String _soundDesign(List<ScriptShot> sequence) {
    final sound = _joinUnique(sequence.map((shot) => shot.sound));
    if (sound.isEmpty) {
      return '使用与画面动作同步的自然环境声、轻微物理运动声和空间氛围声。';
    }
    return sound;
  }

  static String _musicText(List<ScriptShot> sequence) {
    final sound = _joinUnique(sequence.map((shot) => shot.sound));
    if (sound.isEmpty) return 'N/A';
    return RegExp(r'配乐|音乐|BGM|bgm|鼓点|旋律|节奏|弦乐|钢琴').hasMatch(sound)
        ? sound
        : 'N/A';
  }

  static String _fallbackCreative(ScriptShot shot) =>
      _joinUnique([shot.content, shot.scene, shot.shotSize]);

  static String _dialogueText(String value) =>
      value.replaceAll(RegExp(r'[{}<>【】]'), '').trim();

  static String _sourceCreativeText(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || _isStructuredPrompt(normalized)) {
      return '';
    }
    return normalized.replaceAll(RegExp(r'\s+'), ' ');
  }

  static bool _isStructuredPrompt(String value) {
    const markers = [
      '【参考素材说明】',
      '【核心创意】',
      '【画面过程描述】',
      '【整体要求补充】',
      '【声音设计】',
      '非叙事性音乐：',
      '主体与素材定义：',
      '全局风格：',
      '整体约束：',
    ];
    if (markers.any(value.contains)) {
      return true;
    }
    return RegExp(r'(^|\n)\s*镜头\d+[：:]').hasMatch(value);
  }

  static double _sequenceDuration(List<ScriptShot> sequence) {
    final total = sequence.fold<double>(
      0,
      (sum, shot) =>
          sum + (shot.durationSeconds <= 0 ? 1 : shot.durationSeconds),
    );
    return total <= 0 ? 4 : total;
  }

  static String _durationText(num seconds) {
    final rounded = seconds.roundToDouble();
    return seconds == rounded
        ? '${rounded.toInt()}秒'
        : '${seconds.toStringAsFixed(1)}秒';
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
}
