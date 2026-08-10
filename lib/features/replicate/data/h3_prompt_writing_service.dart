import '../domain/h3_prompt_style.dart';

enum H3PromptInputMode { firstAndLastFrame, fullReference }

class H3PromptReference {
  const H3PromptReference({
    required this.pictureNumber,
    required this.role,
    this.name = '',
    this.description = '',
  });

  final int pictureNumber;
  final String role;
  final String name;
  final String description;

  String get instruction {
    final details = [
      name.trim(),
      description.trim(),
    ].where((value) => value.isNotEmpty).join(' — ');
    return '<Picture $pictureNumber> 是${role.trim()}参考'
        '${details.isEmpty ? '' : '：$details'}。';
  }
}

class H3PromptWritingService {
  const H3PromptWritingService();

  static const officialRuleId = 'minimax-h3-prompt-writing-cn-2026-08';

  String buildRewriteInstruction({
    required H3PromptInputMode mode,
    required String draft,
    required double durationSeconds,
    required int storyboardImageCount,
    List<H3PromptReference> references = const [],
    H3PromptStyle style = H3PromptStyle.general,
  }) {
    final duration = _duration(durationSeconds);
    final pictures = _pictureDefinitions(
      mode: mode,
      storyboardImageCount: storyboardImageCount,
      references: references,
    );
    final format = switch (mode) {
      H3PromptInputMode.firstAndLastFrame => _baseFormat(duration),
      H3PromptInputMode.fullReference => _referenceFormat,
    };
    final modeRules = switch (mode) {
      H3PromptInputMode.firstAndLastFrame =>
        '''
- 将 <Picture 1> 视为 0.00 秒的精确首帧，将 <Picture 2> 视为 $duration 秒的精确尾帧。
- 优先使用一个连续镜头，描述两帧之间可见的运动路径，不要重复两段静态外观。
- 保持主体身份、服装、物体结构、构图、光线和空间关系一致，并在结尾精确落到 <Picture 2>。
''',
      H3PromptInputMode.fullReference =>
        '''
- 使用 <Subject N> 标记可复用的可见内容，使用 <Picture N> 标记具体帧或分镜规划锚点，使用 <Video N> 标记整体视频结构，使用 <Audio N> 标记参考音频。
- 保持每个引用标签在六个段落中的含义稳定一致。
- retention_analysis 中，可见参考只使用 fully_preserved、partially_preserved、attribute_transfer 或 weak_reference；音频只使用 fully_copy、partially_copy、reference 或 weak_reference。
- summary 使用中文任务类型前缀，例如 [参考生成] 或 [关键帧补全 + 参考生成]。
- detailed_description 必须详细可执行，不得缩减为剧情概要；根据时长尽可能完整描述每个镜头。
''',
    };
    final styleRules = style.isGeneral
        ? ''
        : '''

选定风格：${style.label}（${style.id}）
风格化约束（只约束视觉、运动、声音策略与负向边界，不得改变官方字段顺序、引用标签含义或用户提供的事实）：
${style.visualPromptInstruction.trim()}
''';
    return '''
你是软件内置的 MiniMax H3 中文提示词编辑器。请按 MiniMax H3 官方提示词结构，将附件中的多模态请求改写为中文生成提示词。

输入模式：${mode == H3PromptInputMode.fullReference ? 'Ref2VA 全参考模式' : 'FL2VA 首尾帧模式'}
目标时长：$duration 秒
规则标识：$officialRuleId

附件顺序与作用：
$pictures

必须使用的输出格式（字段名和顺序必须原样保留）：
$format

中文写作规则：
- 所有描述性正文必须使用简体中文。只保留字段名、引用标签、镜头标签、说话人 ID、对话语言标签和 retention 关系枚举的官方写法。
- 对话、歌词和画面可见文字保留用户原文；中文对话写为 <d>[Chinese] 原文</d>，不翻译、不改写。
- [Shot 1] 不写时间戳。后续镜头使用严格递增且不超出目标时长的切镜时间，格式为 [Shot N] 在 MM:SS.mmm，……
- 详细描述构图、主体、环境、动作、状态变化、运镜、同步声音以及参考内容实际出现或生效的准确时点。
- 运镜以自然中文动作描述，按需说明运动类型、幅度和速度，不堆叠独立标签。
- 为发声主体分配稳定的 (S1) 等 ID。<d>[Language] ...</d> 内只放语言标签和用户对话原文。
- 环境声、物理动作声和非语言人声写入 overall_soundscape；与具体动作同步的声音还要在 detailed_description / integrated_multimodal_description 的对应时点明确写出，不能只写抽象氛围。
- 每个脚步、触碰、开合、碰撞、摩擦等声音必须与触发它的画面事件逐次对齐，按真实时间速度播放，保持自然音高、正常瞬态和合理空间距离。
- 禁止把视觉上的慢动作、缓慢运镜或舒缓情绪解释为音频慢放；禁止时间拉伸、低沉变调、拖长尾音、过长混响或把多个动作合成一声。
- 只有观众能听到的配乐写入 non_diegetic_music；用户或脚本未明确要求配乐时必须写 N/A，不得仅根据画面氛围自动添加慢节奏铺底音乐。
- 不得创造未定义的引用标签、超出时长的时间点、重复字段、Markdown 围栏、JSON、前置解释或分析过程。
$modeRules$styleRules

本地确定性草稿（事实和意图来源；将其重组为上述格式，移除重复或非官方包裹）：
$draft

只返回最终 MiniMax H3 中文提示词正文。
''';
  }

  String normalize(String value) {
    var result = value
        .trim()
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .replaceFirst(
          RegExp(r'^```(?:text|markdown|json)?\s*', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'\s*```\s*$'), '')
        .trim();
    final starts = <int>[
      result.indexOf('subject_definitions:'),
      result.indexOf('参考图片与目标视频的对齐方式'),
      result.indexOf('How the reference pictures align with the target video'),
      result.indexOf('For the target video,'),
      result.indexOf('integrated_multimodal_description:'),
    ].where((index) => index >= 0).toList();
    if (starts.isNotEmpty) {
      starts.sort();
      result = result.substring(starts.first).trim();
    }
    return result;
  }

  bool isValid(String value, H3PromptInputMode mode) {
    final prompt = normalize(value);
    if (prompt.isEmpty ||
        prompt.contains('```') ||
        prompt.contains('<think>')) {
      return false;
    }
    if (mode == H3PromptInputMode.firstAndLastFrame) {
      return prompt.startsWith('参考图片与目标视频的对齐方式') &&
          _hasChineseBody(prompt) &&
          _hasFieldsInOrder(prompt, const [
            'integrated_multimodal_description:',
            'overall_soundscape:',
            'non_diegetic_music:',
          ]) &&
          prompt.contains('<Picture 1>') &&
          prompt.contains('<Picture 2>') &&
          prompt.contains('[Shot 1]');
    }
    return prompt.startsWith('subject_definitions:') &&
        _hasChineseBody(prompt) &&
        _hasFieldsInOrder(prompt, const [
          'subject_definitions:',
          'summary:',
          'retention_analysis:',
          'detailed_description:',
          'overall_soundscape:',
          'non_diegetic_music:',
        ]) &&
        prompt.contains('[Shot 1]');
  }

  static String _pictureDefinitions({
    required H3PromptInputMode mode,
    required int storyboardImageCount,
    required List<H3PromptReference> references,
  }) {
    final count = storyboardImageCount < 1 ? 1 : storyboardImageCount;
    final lines = <String>[];
    if (mode == H3PromptInputMode.firstAndLastFrame) {
      lines.add('<Picture 1> 是 [Shot 1] 的精确首帧锚点。');
      lines.add('<Picture 2> 是 [Shot 1] 的精确尾帧锚点。');
    } else if (count == 1) {
      lines.add('<Picture 1> 是复刻分镜图，用作主要构图、场景、动作、光线和风格参考。');
    } else {
      for (var index = 1; index <= count; index++) {
        lines.add(
          '<Picture $index> 是 $count 张复刻分镜参考中的第 $index 张，用于定义对应动作阶段、构图、空间关系、光线和镜头规划。',
        );
      }
    }
    lines.addAll(references.map((reference) => reference.instruction));
    return lines.join('\n');
  }

  static String _baseFormat(String duration) =>
      '''
参考图片与目标视频的对齐方式——图片1（来自镜头1）对齐目标视频的 0.00 秒；图片2（来自镜头1）对齐目标视频的 $duration 秒。

integrated_multimodal_description: [Shot 1] 中文镜头描述……

overall_soundscape: 中文环境声与物理音效……

non_diegetic_music: 中文非叙事性配乐描述……
''';

  static const _referenceFormat = '''
subject_definitions:
<主体/图片/视频/音频定义>

summary:
[中文任务类型] 中文摘要

retention_analysis:
<每个引用标签一行，关系枚举保留英文>

detailed_description:
<中文风格开场>
[Shot 1] 中文镜头过程……

overall_soundscape:
中文环境声与物理音效……

non_diegetic_music:
中文非叙事性配乐……
''';

  static bool _hasChineseBody(String value) =>
      RegExp(r'[\u4e00-\u9fff]').allMatches(value).length >= 12;

  static bool _hasFieldsInOrder(String value, List<String> fields) {
    var previous = -1;
    for (final field in fields) {
      final index = value.indexOf(field, previous + 1);
      if (index < 0 || index <= previous) return false;
      previous = index;
    }
    return true;
  }

  static String _duration(double seconds) {
    final normalized = seconds <= 0 ? 4.0 : seconds;
    return normalized.toStringAsFixed(2);
  }
}
