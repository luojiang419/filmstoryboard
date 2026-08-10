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
    String narrativeStyle = '',
    String constraints = '',
    List<String> referenceDefinitions = const [],
  }) {
    final normalizedSourcePrompt = sourcePrompt.trim();
    if (_isOfficialH3Prompt(normalizedSourcePrompt)) {
      return normalizedSourcePrompt;
    }
    final sequence = actionSequence.isEmpty
        ? <ScriptShot>[shot]
        : actionSequence;
    final sequenceDuration = _sequenceDuration(sequence);
    final references = _referenceText(
      sequence: sequence,
      availableImageReferences: availableImageReferences,
      availableVideoReferences: availableVideoReferences,
      availableAudioReferences: availableAudioReferences,
      referenceDefinitions: referenceDefinitions,
    );
    final creative = _creativeText(
      shot: shot,
      sequence: sequence,
      duration: sequenceDuration,
      globalStyle: globalStyle,
      sourcePrompt: sourcePrompt,
    );
    final process = sequence.length > 1
        ? _sequenceProcess(sequence)
        : _singleShotProcess(shot);
    final styleLock = _compactText(
      _withoutExactTimingDirectives(narrativeStyle),
      maxChars: 600,
    );
    final requirements = _requirements(shot: shot, constraints: constraints);
    final sections = <String>[
      if (references.isNotEmpty) ...['【参考素材说明】', references, ''],
      '【核心创意】',
      creative,
      '',
      if (styleLock.isNotEmpty) ...['【镜头叙事风格】', styleLock, ''],
      '【画面过程描述】',
      process,
      if (requirements.isNotEmpty) '全程要求：$requirements。',
      '声音：${_soundDesign(sequence)}。',
      '非叙事性音乐：${_musicText(sequence)}',
    ];
    return sections.join('\n').trim();
  }

  static String _referenceText({
    required List<ScriptShot> sequence,
    required int availableImageReferences,
    required int availableVideoReferences,
    required int availableAudioReferences,
    required List<String> referenceDefinitions,
  }) {
    final lines = <String>[];
    if (sequence.length > 1 && availableImageReferences >= sequence.length) {
      lines.add(
        '@图片1至@图片$availableImageReferences是同一连续镜头的顺序动作参考，'
        '保持主体、场景、构图与光影连续，不要求逐帧精确到达。',
      );
    } else if (availableImageReferences > 0) {
      lines.add('@图片1是画面参考，用于保持主体、场景、构图与整体视觉质感。');
    }
    for (var index = 1; index <= availableVideoReferences; index++) {
      lines.add('@视频$index提供动作、运镜与剪辑节奏参考。');
    }
    for (var index = 1; index <= availableAudioReferences; index++) {
      lines.add('@音频$index提供声音节奏与听觉质感参考。');
    }
    for (final definition in referenceDefinitions) {
      final normalized = _compactText(definition, maxChars: 100);
      if (normalized.isNotEmpty) lines.add(normalized);
    }
    return _joinUnique(lines, separator: '\n');
  }

  static String _creativeText({
    required ScriptShot shot,
    required List<ScriptShot> sequence,
    required double duration,
    required String globalStyle,
    required String sourcePrompt,
  }) {
    final first = sequence.first;
    final action = _stageAction(first, maxChars: 72);
    final parts = <String>[
      '${_durationText(duration)}视频',
      _compactText(globalStyle, maxChars: 70),
      action,
      _compactText(shot.scene, maxChars: 48),
      _compactText(shot.cameraAngle, maxChars: 42),
      _compactText(shot.cameraMovement, maxChars: 100),
      _compactText(shot.lightingMood, maxChars: 65),
      _compactText(shot.colorPalette, maxChars: 42),
      _compactText(shot.visualFocus, maxChars: 50),
      _compactText(_sourceCreativeText(sourcePrompt), maxChars: 80),
    ];
    final result = _joinUnique(parts);
    return result.isEmpty ? _fallbackCreative(shot) : '$result。';
  }

  static String _singleShotProcess(ScriptShot shot) {
    final action = _stageAction(shot, maxChars: 120);
    final parts = _joinUnique([
      _compactText(shot.shotSize, maxChars: 20),
      action,
      if (shot.dialogue.trim().isNotEmpty)
        '台词：${_compactText(_dialogueText(shot.dialogue), maxChars: 100)}',
    ]);
    return '画面：$parts。';
  }

  static String _sequenceProcess(List<ScriptShot> sequence) {
    final lines = <String>[];
    for (var index = 0; index < sequence.length; index++) {
      final shot = sequence[index];
      final referenceCue = '衔接@图片${index + 1}';
      final parts = _joinUnique([
        referenceCue,
        _compactText(shot.actionStage, maxChars: 24),
        _stageAction(shot, maxChars: 72),
        _compactText(shot.movementTrend, maxChars: 55),
        if (shot.dialogue.trim().isNotEmpty)
          '台词：${_compactText(_dialogueText(shot.dialogue), maxChars: 80)}',
      ]);
      lines.add('${_sequenceStageLabel(index, sequence.length)}：$parts。');
    }
    return lines.join('\n');
  }

  static String _sequenceStageLabel(int index, int length) {
    if (index == 0) return '开头';
    if (index == length - 1) return '最后';
    return index == 1 ? '随后' : '接着';
  }

  static String _stageAction(ScriptShot shot, {required int maxChars}) {
    final candidates = [shot.content, shot.visual];
    for (final candidate in candidates) {
      final normalized = _compactText(candidate, maxChars: maxChars);
      if (normalized.isNotEmpty) return normalized;
    }
    return _compactText(shot.movementTrend, maxChars: maxChars);
  }

  static String _requirements({
    required ScriptShot shot,
    required String constraints,
  }) => _joinUnique([
    _compactText(shot.replicationInstructions, maxChars: 80),
    _compactText(constraints, maxChars: 100),
    '保持主体身份、空间关系与动作方向稳定',
    '不新增字幕、乱码文字、水印或无关Logo',
  ]);

  static String _soundDesign(List<ScriptShot> sequence) {
    final effects = <String>[];
    for (final shot in sequence) {
      for (final segment in _soundSegments(shot.sound)) {
        if (_isMusicSegment(segment) || _isSoundRule(segment)) continue;
        final normalized = _compactText(
          segment.replaceFirst(RegExp(r'^(?:音效设计|音效氛围|音效)\s*[：:]\s*'), ''),
          maxChars: 70,
        );
        if (normalized.isEmpty || _containsEquivalent(effects, normalized)) {
          continue;
        }
        effects.add(normalized);
        if (effects.length >= 2) break;
      }
      if (effects.length >= 2) break;
    }
    final sound = _joinUnique(effects);
    return _joinUnique([
      sound.isEmpty ? '自然环境声与画面中的物理动作声' : sound,
      '按画面事件自然同步，保持真实速度和自然音高',
    ]);
  }

  static String _musicText(List<ScriptShot> sequence) {
    final music = <String>[];
    for (final shot in sequence) {
      final raw = shot.sound.trim();
      final segments = _soundSegments(raw);
      final explicitMusic = segments.where(_isMusicSegment).toList();
      if (explicitMusic.isNotEmpty) {
        for (final segment in explicitMusic) {
          final normalized = _compactText(
            segment.replaceFirst(
              RegExp(
                r'^(?:非叙事性音乐|音乐氛围|配乐|背景音乐|BGM)\s*[：:]\s*',
                caseSensitive: false,
              ),
              '',
            ),
            maxChars: 100,
          );
          if (normalized.isNotEmpty && !_isNoMusic(normalized)) {
            music.add(normalized);
          }
        }
      } else if (RegExp(r'配乐|背景音乐|BGM|bgm|鼓点|旋律|弦乐|钢琴').hasMatch(raw)) {
        music.add(_compactText(raw, maxChars: 100));
      }
    }
    final result = _joinUnique(music);
    return result.isEmpty ? 'N/A' : result;
  }

  static List<String> _soundSegments(String value) => value
      .split(RegExp(r'[；\n]+'))
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);

  static bool _isMusicSegment(String value) => RegExp(
    r'^(?:非叙事性音乐|音乐氛围|配乐|背景音乐|BGM)\s*[：:]',
    caseSensitive: false,
  ).hasMatch(value.trim());

  static bool _isSoundRule(String value) =>
      RegExp(r'^(?:同步要求|所有声音|所有音效|禁止|声音同步)').hasMatch(value.trim());

  static bool _isNoMusic(String value) => RegExp(
    r'^(?:N\s*/?\s*A|无|不添加|不需要|除非脚本明确指定)',
    caseSensitive: false,
  ).hasMatch(value.trim());

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

  static String _withoutExactTimingDirectives(String value) {
    return value
        .replaceAllMapped(
          RegExp(
            r'(^|[；;。\n])\s*(?:第\s*)?\d+(?:\.\d+)?\s*'
            r'(?:[-—~～至到]\s*\d+(?:\.\d+)?)?\s*(?:秒|s)'
            r'(?:内|时)?\s*[：:，,]\s*',
            caseSensitive: false,
          ),
          (match) => match.group(1) ?? '',
        )
        .replaceAll(
          RegExp(
            r'\d+(?:\.\d+)?\s*[-—~～至到]\s*\d+(?:\.\d+)?\s*(?:秒|s)',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'第\s*\d+(?:\.\d+)?\s*秒(?:内|时)?'), '随后')
        .replaceAll(RegExp(r'[；;，,]\s*[；;，,]+'), '；')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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

  static bool _isOfficialH3Prompt(String value) {
    if (value.isEmpty) return false;
    if (value.startsWith('subject_definitions:')) {
      const fields = [
        'subject_definitions:',
        'summary:',
        'retention_analysis:',
        'detailed_description:',
        'overall_soundscape:',
        'non_diegetic_music:',
      ];
      var previous = -1;
      for (final field in fields) {
        final index = value.indexOf(field);
        if (index <= previous) return false;
        previous = index;
      }
      return true;
    }
    final integrated = value.indexOf('integrated_multimodal_description:');
    final soundscape = value.indexOf('overall_soundscape:');
    final music = value.indexOf('non_diegetic_music:');
    return integrated >= 0 && soundscape > integrated && music > soundscape;
  }

  static double _sequenceDuration(List<ScriptShot> sequence) {
    final duration = sequence.last.durationSeconds;
    return duration <= 0 ? 4 : duration;
  }

  static String _durationText(num seconds) {
    final rounded = seconds.roundToDouble();
    return seconds == rounded
        ? '${rounded.toInt()}秒'
        : '${seconds.toStringAsFixed(1)}秒';
  }

  static String _compactText(String value, {required int maxChars}) {
    final normalized = value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[，,；;。\s]+|[，,；;。\s]+$'), '')
        .trim();
    if (normalized.isEmpty || normalized.length <= maxChars) {
      return normalized;
    }
    final clauses = normalized
        .split(RegExp(r'[；;。\n]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final result = <String>[];
    var length = 0;
    for (final clause in clauses) {
      final nextLength = length + clause.length + (result.isEmpty ? 0 : 1);
      if (nextLength > maxChars) break;
      result.add(clause);
      length = nextLength;
    }
    if (result.isNotEmpty) return result.join('，');
    final commaClause = normalized.split(RegExp(r'[，,]')).first.trim();
    if (commaClause.isNotEmpty && commaClause.length <= maxChars) {
      return commaClause;
    }
    return normalized.substring(0, maxChars);
  }

  static bool _containsEquivalent(List<String> values, String candidate) {
    final normalizedCandidate = _semanticKey(candidate);
    return values.any((value) {
      final normalizedValue = _semanticKey(value);
      return normalizedValue == normalizedCandidate ||
          normalizedValue.contains(normalizedCandidate) ||
          normalizedCandidate.contains(normalizedValue);
    });
  }

  static String _semanticKey(String value) => value
      .replaceAll(RegExp(r'[\s，,；;。.!！?？：:]'), '')
      .replaceAll(RegExp(r'^(?:场景|构图|机位|运镜|视觉焦点|光影|氛围|色彩)'), '')
      .trim();

  static String _joinUnique(Iterable<String> values, {String separator = '，'}) {
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || _containsEquivalent(result, normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result.join(separator);
  }
}
