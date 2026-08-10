import 'dart:math' as math;

import '../../replicate/data/seedance_prompt_generation_service.dart';
import '../../shooting_script/domain/shooting_script_models.dart';

class KlingVideoPromptAdapter {
  const KlingVideoPromptAdapter();

  String adapt(
    ScriptShot shot, {
    String? sourcePrompt,
    List<ScriptShot> actionSequence = const [],
    int availableImageReferences = 0,
    int availableVideoReferences = 0,
    bool? useStartEndFrameReferences,
    String globalStyle = '',
    String constraints = '',
  }) {
    final sequence = actionSequence.isEmpty
        ? <ScriptShot>[shot]
        : actionSequence;
    final hasTailReference =
        useStartEndFrameReferences ??
        (sequence.length > 1 && availableImageReferences == 2);
    final providedPrompt = _normalizeKlingImageLead(sourcePrompt?.trim() ?? '');
    if (_canPassThrough(
      providedPrompt,
      sequenceLength: sequence.length,
      hasTailReference: hasTailReference,
    )) {
      return providedPrompt;
    }

    final reference = _referenceInstruction(
      sequenceLength: sequence.length,
      availableImageReferences: availableImageReferences,
      hasTailReference: hasTailReference,
    );
    final action = sequence.length > 1
        ? _sequenceAction(sequence)
        : _stageAction(shot, maxChars: 100);
    final camera = _joinUnique([
      _shotText(shot.shotSize, maxChars: 18),
      _shotText(shot.cameraAngle, maxChars: 32),
      _shotText(shot.composition, maxChars: 58),
      _shotText(shot.cameraMovement, maxChars: 90),
      _shotText(shot.visualFocus, maxChars: 42),
    ]);
    final environment = _joinUnique([
      _shotText(shot.scene, maxChars: 48),
      _shotText(shot.lightingMood, maxChars: 55),
      _shotText(shot.colorPalette, maxChars: 36),
    ]);
    final constraintText = _joinUnique([
      _shotText(shot.replicationInstructions, maxChars: 70),
      _compactText(constraints, maxChars: 90),
    ]);
    final sourceInstruction = _sourceInstruction(
      sourcePrompt ?? '',
      availableImageReferences: availableImageReferences,
      availableVideoReferences: availableVideoReferences,
    );
    final parts = <String>[
      reference,
      if (action.isNotEmpty) sequence.length > 1 ? action : '$action。',
      if (camera.isNotEmpty) '镜头：$camera。',
      if (shot.dialogue.trim().isNotEmpty)
        '对白：${_compactText(_dialogueText(shot.dialogue), maxChars: 90)}。',
      if (sourceInstruction.isNotEmpty) '$sourceInstruction。',
      if (constraintText.isNotEmpty) '要求：$constraintText。',
      if (environment.isNotEmpty) '环境：$environment。',
      if (shot.sound.trim().isNotEmpty) '声音：${_soundText(shot.sound)}。',
      if (globalStyle.trim().isNotEmpty)
        '风格：${_compactText(globalStyle, maxChars: 60)}。',
    ];
    return _joinWithinLimit(parts, maxChars: 500);
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

  static String _referenceInstruction({
    required int sequenceLength,
    required int availableImageReferences,
    required bool hasTailReference,
  }) {
    if (availableImageReferences <= 0) return '';
    if (hasTailReference && availableImageReferences >= 2) {
      return '图片1为首帧，图片2为尾帧；单镜头连续完成，只补全两帧之间的自然动作。';
    }
    final sequenceReferences = math.min(
      sequenceLength,
      availableImageReferences,
    );
    if (sequenceLength > 1 && sequenceReferences > 1) {
      return '图片1至图片$sequenceReferences为同一连续动作的顺序参考；'
          '保持主体、场景、构图与光影连续，不要求逐帧精确到达。';
    }
    return '图片1为起始画面与主体参考。';
  }

  static String _sequenceAction(List<ScriptShot> sequence) {
    final stages = <String>[];
    for (var index = 0; index < sequence.length; index++) {
      final action = _stageAction(sequence[index], maxChars: 68);
      if (action.isEmpty) continue;
      final trend = _shotText(sequence[index].movementTrend, maxChars: 42);
      final detail = _joinUnique([action, trend]);
      stages.add('${_stageLabel(index, sequence.length)}：$detail。');
    }
    return stages.join('');
  }

  static String _stageLabel(int index, int length) {
    if (index == 0) return '开头';
    if (index == length - 1) return '最后';
    return index == 1 ? '随后' : '接着';
  }

  static String _stageAction(ScriptShot shot, {required int maxChars}) {
    for (final candidate in [shot.content, shot.visual]) {
      final normalized = _shotText(candidate, maxChars: maxChars);
      if (normalized.isNotEmpty) return normalized;
    }
    return _shotText(shot.movementTrend, maxChars: maxChars);
  }

  String _sourceInstruction(
    String sourcePrompt, {
    required int availableImageReferences,
    required int availableVideoReferences,
  }) {
    final normalized = sourcePrompt.trim();
    if (normalized.isEmpty ||
        _isStructuredPrompt(normalized) ||
        RegExp(
          r'@?(?:图片|图|视频)\s*\d+',
          caseSensitive: false,
        ).hasMatch(normalized)) {
      return '';
    }
    final available = removeUnavailableReferences(
      normalized,
      availableImageReferences: availableImageReferences,
      availableVideoReferences: availableVideoReferences,
    );
    return _shotText(available, maxChars: 100);
  }

  static String _soundText(String value) {
    final effects = <String>[];
    for (final segment in value.split(RegExp(r'[；;\n]+'))) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty ||
          RegExp(r'^(?:同步要求|所有声音|所有音效|禁止|声音同步)').hasMatch(trimmed)) {
        continue;
      }
      final normalized = _shotText(
        trimmed.replaceFirst(RegExp(r'^(?:音效设计|音效氛围|音乐氛围|音效)\s*[：:]\s*'), ''),
        maxChars: 65,
      );
      if (normalized.isEmpty || _containsEquivalent(effects, normalized)) {
        continue;
      }
      effects.add(normalized);
      if (effects.length >= 2) break;
    }
    return effects.isEmpty ? '自然环境声与动作声同步' : _joinUnique(effects);
  }

  static String _shotText(String value, {required int maxChars}) {
    final withoutAppearance = value
        .replaceAll('画面中', '构图中')
        .replaceAll(
          RegExp(
            r'(?:身穿|穿着|服装为|造型为|斜挎|肩背|背着|脚踩|佩戴|戴着)'
            r'[^，,；;。\n]*',
          ),
          '',
        );
    return _compactText(
      SeedancePromptGenerationService.stripSpecificWardrobeAndObjectDetails(
        withoutAppearance,
      ),
      maxChars: maxChars,
    );
  }

  static String _compactText(String value, {required int maxChars}) {
    final normalized = value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[，,；;。\s]+|[，,；;。\s]+$'), '')
        .trim();
    if (normalized.length <= maxChars) return normalized;
    final result = <String>[];
    var length = 0;
    for (final clause in normalized.split(RegExp(r'[；;。\n]+'))) {
      final trimmed = clause.trim();
      if (trimmed.isEmpty) continue;
      final nextLength = length + trimmed.length + (result.isEmpty ? 0 : 1);
      if (nextLength > maxChars) break;
      result.add(trimmed);
      length = nextLength;
    }
    if (result.isNotEmpty) return result.join('，');
    return normalized.substring(0, maxChars);
  }

  static String _joinWithinLimit(
    Iterable<String> values, {
    required int maxChars,
  }) {
    final result = StringBuffer();
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty) continue;
      if (result.length + normalized.length > maxChars) continue;
      result.write(normalized);
    }
    return result.toString().trim();
  }

  static String _keepReference(Match match, int availableCount) {
    final number = int.tryParse(match.group(1) ?? '') ?? 0;
    return number > 0 && number <= availableCount ? match.group(0)! : '';
  }

  static String _joinUnique(Iterable<String> values) {
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || _containsEquivalent(result, normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result.join('，');
  }

  static bool _containsEquivalent(List<String> values, String candidate) {
    final candidateKey = _semanticKey(candidate);
    return values.any((value) {
      final valueKey = _semanticKey(value);
      return valueKey == candidateKey ||
          valueKey.contains(candidateKey) ||
          candidateKey.contains(valueKey);
    });
  }

  static String _semanticKey(String value) => value
      .replaceAll(RegExp(r'[\s，,；;。.!！?？：:]'), '')
      .replaceAll(RegExp(r'^(?:场景|构图|机位|运镜|视觉焦点|光影|氛围|色彩)'), '')
      .trim();

  static String _dialogueText(String value) =>
      value.replaceAll(RegExp(r'[{}<>【】]'), '').trim();

  static String _normalizeKlingImageLead(String prompt) => prompt
      .replaceFirst('以输入图片作为首帧和主体外观参考', '以图片1作为首帧和主体外观参考')
      .replaceFirst('以@图片1作为首帧和主体外观参考', '以图片1作为首帧和主体外观参考');

  static bool _canPassThrough(
    String prompt, {
    required int sequenceLength,
    required bool hasTailReference,
  }) {
    if (!_isKlingPrompt(prompt)) return false;
    if (hasTailReference) return _mentionsTailReference(prompt);
    if (sequenceLength > 1) {
      return RegExp(r'图片\s*1\s*(?:至|到|[-~～])\s*图片?\s*\d+').hasMatch(prompt);
    }
    return true;
  }

  static bool _isKlingPrompt(String prompt) =>
      RegExp(r'^(?:以)?图片\s*1\s*(?:作为|为)').hasMatch(prompt);

  static bool _mentionsTailReference(String prompt) =>
      RegExp(r'图片\s*2(?!\d)').hasMatch(prompt) || prompt.contains('尾帧');

  static bool _isStructuredPrompt(String value) {
    const markers = [
      '【参考素材说明】',
      '【核心创意】',
      '【画面过程描述】',
      '【整体要求补充】',
      '【声音设计】',
      '主体与动作：',
      '镜头时序：',
      'subject_definitions:',
      'integrated_multimodal_description:',
    ];
    return markers.any(value.contains) ||
        RegExp(r'(^|\n)\s*镜头\d+[：:]').hasMatch(value);
  }
}
