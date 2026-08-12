import '../domain/h3_prompt_style.dart';
import '../../storyboard/domain/cinematic_motion_policy.dart';

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
    required String draft,
    required double durationSeconds,
    required int storyboardImageCount,
    List<H3PromptReference> references = const [],
    H3PromptStyle style = H3PromptStyle.general,
    bool chooseDurationFromIntent = false,
    String fullStyleSkillContext = '',
    List<String> repairErrors = const [],
    String previousInvalidPrompt = '',
    bool singleContinuousShot = false,
    bool allowSlowMotion = false,
  }) {
    final duration = _duration(durationSeconds);
    final pictures = _pictureDefinitions(
      storyboardImageCount: storyboardImageCount,
      references: references,
      singleContinuousShot: singleContinuousShot,
    );
    const modeRules = '''
- 使用 <Subject N> 标记可复用的可见内容，使用 <Picture N> 标记具体帧或分镜规划锚点，使用 <Video N> 标记整体视频结构，使用 <Audio N> 标记参考音频。
- 保持每个引用标签在六个段落中的含义稳定一致。
- retention_analysis 中，可见参考只使用 fully_preserved、partially_preserved、attribute_transfer 或 weak_reference；音频只使用 fully_copy、partially_copy、reference 或 weak_reference。
- summary 使用中文任务类型前缀，例如 [参考生成] 或 [关键帧补全 + 参考生成]。
- detailed_description 必须详细可执行，不得缩减为剧情概要；根据时长尽可能完整描述每个镜头。
''';
    const seedanceDirectorRules = '''

运镜与动作组织采用即梦 / Seedance 2.0 成熟导演语法作为基线（只影响内容组织，不改变 MiniMax H3 六段字段与引用标签）：
- 按“空间层 + 时间层”写作：先锁定主体、场景、空间关系和光影，再按发生顺序描述动作、表情、摄影机路径与结束状态。
- 动作具体到肢体、重心、视线、幅度、速度、力度和前后惯性；后一动作必须从前一状态自然承接。
- 一个物理镜头尽量只使用一种有动机的主运镜，不堆叠推拉摇移；摄影机移动速度与视频播放速度必须分开表达。
''';
    final styleRules = style.isGeneral
        ? ''
        : '''

选定风格：${style.label}（${style.id}）
风格化约束（只约束视觉、运动、声音策略与负向边界，不得改变官方字段顺序、引用标签含义或用户提供的事实）：
${style.visualPromptInstruction.trim()}
''';
    final durationRule = chooseDurationFromIntent
        ? '根据用户创作意图、镜头动作量与节奏选择唯一的 4–15 秒整数时长；只在 summary 中写一次“X秒视频”'
        : '目标时长为 $duration 秒；只在 summary 中写一次对应的“X秒视频”';
    final skillRules = fullStyleSkillContext.trim().isEmpty
        ? ''
        : '''

以下是当前选定风格的完整 Skill 上下文，必须完整执行：
${fullStyleSkillContext.trim()}
''';
    final repairRules = repairErrors.isEmpty
        ? ''
        : '''

上一次输出未通过校验，这是唯一一次格式修复：
${repairErrors.map((error) => '- $error').join('\n')}

上一次输出：
${previousInvalidPrompt.trim()}

必须在保留创作意图的前提下修复全部错误，不得输出解释。
''';
    final shotStructureRules = singleContinuousShot
        ? '''

当前目标镜头结构：单一连续镜头（最高优先级）
- <Picture 1> 至 <Picture $storyboardImageCount> 是同一物理镜头按时间顺序抽取的动作阶段帧，不是不同镜头的首帧，也不代表切镜。
- detailed_description 中必须且只能出现一次 [Shot 1]；禁止输出 [Shot 2] 或更高编号，禁止写任何切镜时间。
- 必须在 [Shot 1] 内按图片顺序描述开始、发展和结束阶段，把主体尺度、景别或构图变化解释为镜内动作、连续跟随、推拉、摇移、升降或主体靠近/远离。
- 禁止把 Picture N 映射成 Shot N，禁止把 <Picture 2> 及后续图片定义为新镜头首帧。
'''
        : '''

当前目标镜头结构：按用户文字组织。只有用户明确写出切镜或多个目标镜头时才使用 [Shot 2+]；图片数量不自动等于镜头数量，也不得仅按 Picture 编号机械切镜。
''';
    final playbackSpeedRules = allowSlowMotion
        ? '''

播放速度授权：用户已在当前镜头的剧情描述中明确要求慢动作/升格。只在落实该明确意图所必需的动作阶段使用，不得把整条视频默认处理为慢动作，也不得将摄影机缓慢移动误写成播放变慢。
'''
        : '''

播放速度规则（最高优先级）：用户没有在当前镜头的剧情描述中明确要求慢动作、慢放、升格或高帧率回放。
- 最终提示词中的主体动作、表情变化、环境运动和声音一律按正常时间速度发生。
- 禁止设计或写出慢动作、慢镜头、慢放、升格、高帧率慢放、speed ramp、slow motion 或时间拉伸；所选风格、完整 Skill、参考图观感和模型自由发挥都不能覆盖本条。
- “缓慢推近/平稳跟随/末段缓停”只描述摄影机自身的运动速度，不代表画面播放速度改变，也不得据此延长人物动作。
''';
    return '''
你是软件内置的 MiniMax H3 中文提示词编辑器。请按 MiniMax H3 官方提示词结构，将附件中的多模态请求改写为中文生成提示词。

输入模式：Ref2VA 全参考模式
时长规则：$durationRule
规则标识：$officialRuleId

附件顺序与作用：
$pictures

必须使用的输出格式（字段名和顺序必须原样保留）：
$_referenceFormat

中文写作规则：
- 所有描述性正文必须使用简体中文。只保留字段名、引用标签、镜头标签、说话人 ID、对话语言标签和 retention 关系枚举的官方写法。
- 对话、歌词和画面可见文字保留用户原文；中文对话写为 <d>[Chinese] 原文</d>，不翻译、不改写。
- [Shot 1] 不写时间戳。允许多镜头时，后续镜头使用严格递增且不超出目标时长的切镜时间，格式为 [Shot N] 在 MM:SS.mmm，……
- 详细描述构图、主体、环境、动作、状态变化、运镜、同步声音以及参考内容实际出现或生效的准确时点。
- 运镜以自然中文动作描述，按需说明运动类型、幅度和速度，不堆叠独立标签。
- 为发声主体分配稳定的 (S1) 等 ID。<d>[Language] ...</d> 内只放语言标签和用户对话原文。
- 环境声、物理动作声和非语言人声写入 overall_soundscape；与具体动作同步的声音还要在 detailed_description / integrated_multimodal_description 的对应时点明确写出，不能只写抽象氛围。
- 每个脚步、触碰、开合、碰撞、摩擦等声音必须与触发它的画面事件逐次对齐，按真实时间速度播放，保持自然音高、正常瞬态和合理空间距离。
- 禁止把视觉上的慢动作、缓慢运镜或舒缓情绪解释为音频慢放；禁止时间拉伸、低沉变调、拖长尾音、过长混响或把多个动作合成一声。
- 只有观众能听到的配乐写入 non_diegetic_music；用户或脚本未明确要求配乐时必须写 N/A，不得仅根据画面氛围自动添加慢节奏铺底音乐。
- 不得创造未定义的引用标签、超出时长的时间点、重复字段、Markdown 围栏、JSON、前置解释或分析过程。
$modeRules$seedanceDirectorRules$styleRules$skillRules$shotStructureRules$playbackSpeedRules

本地确定性草稿（事实和意图来源；将其重组为上述格式，移除重复或非官方包裹）：
$draft
$repairRules

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

  bool isValid(
    String value, {
    int? referenceImageCount,
    bool requireAiDuration = false,
    bool singleContinuousShot = false,
    bool allowSlowMotion = false,
  }) => validationErrors(
    value,
    referenceImageCount: referenceImageCount,
    requireAiDuration: requireAiDuration,
    singleContinuousShot: singleContinuousShot,
    allowSlowMotion: allowSlowMotion,
  ).isEmpty;

  List<String> validationErrors(
    String value, {
    int? referenceImageCount,
    bool requireAiDuration = false,
    bool singleContinuousShot = false,
    bool allowSlowMotion = false,
  }) {
    final prompt = normalize(value);
    final errors = <String>[];
    if (prompt.isEmpty) return const ['输出为空'];
    if (prompt.contains('```') || prompt.contains('<think>')) {
      errors.add('不得包含代码围栏或思考标签');
    }
    const fields = [
      'subject_definitions:',
      'summary:',
      'retention_analysis:',
      'detailed_description:',
      'overall_soundscape:',
      'non_diegetic_music:',
    ];
    if (!prompt.startsWith(fields.first)) {
      errors.add('必须以 subject_definitions: 开头');
    }
    if (!_hasFieldsInOrder(prompt, fields)) {
      errors.add('六个字段缺失或顺序错误');
    }
    for (final field in fields) {
      if (RegExp(
            '^${RegExp.escape(field)}',
            multiLine: true,
          ).allMatches(prompt).length !=
          1) {
        errors.add('字段 $field 必须且只能出现一次');
      }
    }
    if (!_hasChineseBody(prompt)) errors.add('描述性正文必须使用简体中文');
    if (!prompt.contains('[Shot 1]')) {
      errors.add('detailed_description 必须包含 [Shot 1]');
    }
    if (singleContinuousShot) {
      final shotNumbers = RegExp(
        r'\[Shot\s+(\d+)\]',
        caseSensitive: false,
      ).allMatches(prompt).map((match) => int.tryParse(match.group(1) ?? ''));
      if (shotNumbers.whereType<int>().any((number) => number > 1)) {
        errors.add('单一连续镜头模式只允许 [Shot 1]，不得出现 [Shot 2] 或更高编号');
      }
      final detailed = _fieldBody(
        prompt,
        'detailed_description:',
        'overall_soundscape:',
      );
      final detailedShotLabels = RegExp(
        r'\[Shot\s+\d+\]',
        caseSensitive: false,
      ).allMatches(detailed);
      if (detailedShotLabels.length != 1) {
        errors.add('单一连续镜头的 detailed_description 必须且只能包含一个 [Shot 1]');
      }
    }
    if (!allowSlowMotion &&
        CinematicMotionPolicy.containsUnauthorizedSlowMotion(prompt)) {
      errors.add('用户未授权慢动作，最终提示词不得包含慢动作、慢放、升格或变速慢放');
    }
    if (requireAiDuration) {
      final durations = RegExp(r'(\d+)\s*秒视频').allMatches(prompt).toList();
      if (durations.length != 1) {
        errors.add('全文必须且只能出现一个“X秒视频”');
      } else {
        final duration = int.tryParse(durations.single.group(1) ?? '');
        if (duration == null || duration < 4 || duration > 15) {
          errors.add('视频时长必须是 4–15 秒整数');
        }
        final summary = _fieldBody(prompt, 'summary:', 'retention_analysis:');
        if (!summary.contains(durations.single.group(0)!)) {
          errors.add('唯一的“X秒视频”必须写在 summary 中');
        }
      }
    }
    final expectedPictures = referenceImageCount ?? 0;
    if (expectedPictures > 0) {
      final numbers = RegExp(r'<Picture\s+(\d+)>')
          .allMatches(prompt)
          .map((match) => int.tryParse(match.group(1) ?? ''))
          .whereType<int>()
          .toSet();
      for (var number = 1; number <= expectedPictures; number++) {
        if (!numbers.contains(number)) {
          errors.add('缺少附件引用 <Picture $number>');
        }
      }
      final invalid = numbers.where(
        (number) => number < 1 || number > expectedPictures,
      );
      if (invalid.isNotEmpty) {
        errors.add('存在超出附件范围的 Picture 编号：${invalid.join(', ')}');
      }
    }
    return errors;
  }

  int? extractDurationSeconds(String value) {
    final matches = RegExp(r'(\d+)\s*秒视频').allMatches(normalize(value));
    if (matches.length != 1) return null;
    final duration = int.tryParse(matches.single.group(1) ?? '');
    return duration != null && duration >= 4 && duration <= 15
        ? duration
        : null;
  }

  static String _pictureDefinitions({
    required int storyboardImageCount,
    required List<H3PromptReference> references,
    required bool singleContinuousShot,
  }) {
    final count = storyboardImageCount < 1 ? 1 : storyboardImageCount;
    final referenceByNumber = {
      for (final reference in references) reference.pictureNumber: reference,
    };
    final lines = <String>[];
    if (count == 1) {
      lines.add(
        referenceByNumber.remove(1)?.instruction ??
            '<Picture 1> 是复刻分镜图，用作主要构图、场景、动作、光线和风格参考。',
      );
    } else {
      for (var index = 1; index <= count; index++) {
        lines.add(
          referenceByNumber.remove(index)?.instruction ??
              (singleContinuousShot
                  ? '<Picture $index> 是同一连续镜头按时间顺序抽取的第 $index 个动作阶段帧，用于定义该阶段的构图、空间关系和光线；不是新镜头首帧。'
                  : '<Picture $index> 是 $count 张复刻分镜参考中的第 $index 张，用于定义对应动作阶段、构图、空间关系、光线和镜头规划。'),
        );
      }
    }
    final remaining = referenceByNumber.values.toList()
      ..sort(
        (first, second) => first.pictureNumber.compareTo(second.pictureNumber),
      );
    lines.addAll(remaining.map((reference) => reference.instruction));
    return lines.join('\n');
  }

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

  static String _fieldBody(String value, String start, String end) {
    final startIndex = value.indexOf(start);
    if (startIndex < 0) return '';
    final endIndex = value.indexOf(end, startIndex + start.length);
    if (endIndex < 0) return '';
    return value.substring(startIndex + start.length, endIndex).trim();
  }

  static String _duration(double seconds) {
    final normalized = seconds <= 0 ? 4.0 : seconds;
    return normalized.toStringAsFixed(2);
  }

  static bool hasExplicitMultiShotIntent(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return false;
    final patterns = <RegExp>[
      RegExp(r'\[Shot\s*[2-9]\d*\]', caseSensitive: false),
      RegExp(r'第\s*(?:[2-9]\d*|[二三四五六七八九十]+)\s*(?:个)?\s*镜头'),
      RegExp(r'(?:切到|切至|硬切|跳切|转场|镜头切换|切换镜头)'),
      RegExp(r'(?:多镜头|双镜头|两(?:个)?镜头|[三四五六七八九十](?:个)?镜头)'),
    ];
    for (final clause in normalized.split(RegExp(r'[，,。；;！!？?\n]+'))) {
      if (RegExp(
        r'(?:不要|不得|禁止|不应|无需|无须|不能).{0,12}(?:切镜|切换镜头|转场|硬切|多镜头|第二个镜头)',
      ).hasMatch(clause)) {
        continue;
      }
      if (patterns.any((pattern) => pattern.hasMatch(clause))) return true;
    }
    return false;
  }

  static bool shouldUseSingleContinuousShot({
    required String description,
    required int storyboardImageCount,
  }) => storyboardImageCount > 1 && !hasExplicitMultiShotIntent(description);
}
