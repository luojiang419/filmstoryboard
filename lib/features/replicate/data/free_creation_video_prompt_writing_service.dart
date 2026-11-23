import '../domain/replicate_models.dart';

class FreeCreationVideoPromptWritingService {
  const FreeCreationVideoPromptWritingService();

  String buildRewriteInstruction({
    required ShotPromptFormat format,
    required String userDescription,
    required List<String> referenceRoles,
    required bool singleContinuousShot,
    required bool explicitMultiShotIntent,
    required bool allowSlowMotion,
    required String backendSkillContext,
    List<String> repairErrors = const [],
    String previousInvalidPrompt = '',
  }) {
    if (format == ShotPromptFormat.h3) {
      throw ArgumentError('H3 必须使用独立的 H3PromptWritingService');
    }
    final modelName = format == ShotPromptFormat.kling
        ? '可灵图生视频'
        : '即梦 / Seedance 2.0 参考生视频';
    final maxChars = format == ShotPromptFormat.kling ? 500 : 1800;
    final labels = [
      for (var index = 0; index < referenceRoles.length; index++)
        '${format == ShotPromptFormat.kling ? '图片' : '@图片 '}${index + 1}：${referenceRoles[index]}',
    ];
    final structureRule = singleContinuousShot
        ? '全部参考图属于同一物理连续镜头的顺序动作阶段。只描述阶段之间的动作路径，只使用一种主要运镜，不得切镜。'
        : explicitMultiShotIntent
        ? '用户明确要求多镜头；按用户文字组织镜头，但图片编号不自动等于镜头编号。'
        : '只有一张参考画面；除非用户明确要求，否则保持单一连续镜头。';
    final speedRule = allowSlowMotion
        ? '只在用户明确指定的动作范围内使用慢动作。'
        : '按正常时间速度推进，不得自行加入慢动作、升格或变速慢放。';
    final modelRule = format == ShotPromptFormat.kling
        ? '''
- 参考图负责主体外观、服装产品、场景、构图与光影；文本只补充动作变化、单一运镜和必要约束。
- 使用简洁自然的中文句子。不得重新猜测或枚举参考图中的服装、产品、材质、品牌和颜色。
- 不得输出声音设计、配乐、任务类型、主体定义、字段名或解释。'''
        : '''
- 先明确素材引用，再写主体动作的时间顺序、单一主要运镜和必要声音；复杂多镜头才允许分镜结构。
- 参考图已经给出的外观、空间、构图与光影不重复展开，不得猜测服装、产品、材质、品牌和颜色。
- 静态主体和环境最多定义一次，避免冗余、语义冲突和多种运镜堆叠。''';
    final repairBlock = repairErrors.isEmpty
        ? ''
        : '''
【上次输出未通过】
${repairErrors.map((error) => '- $error').join('\n')}
上次输出：$previousInvalidPrompt
只修复上述问题，不扩写内容。
''';
    return '''
你正在为$modelName编写最终提示词。只遵守当前模型规则，不得套用 MiniMax H3 或其他视频模型的格式。

【用户描述】
${userDescription.trim().isEmpty ? '用户未提供描述，请从参考图推断一个简单、物理合理的连续动作。' : userDescription.trim()}

【参考图及顺序】
${labels.join('\n')}

【当前模型强制规则】
$modelRule
- $structureRule
- $speedRule
- 自主选择 4 至 15 秒的整数时长，最终正文只出现一次“X秒视频”。
- 最终正文不得超过 $maxChars 个字符，不得用截断句或省略号规避长度。
- 不得出现 subject_definitions、summary、retention_analysis、detailed_description、overall_soundscape、non_diegetic_music、<Subject N>、<Picture N>、[Shot N] 或“参考生成”等 H3 痕迹。

$backendSkillContext
$repairBlock
只返回一段最终中文提示词正文，不要标题、分析、解释或代码围栏。
''';
  }

  String normalize(String value) => value
      .trim()
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .replaceAll(RegExp(r'^```[^\n]*\n?|\n?```$', multiLine: true), '')
      .trim();

  List<String> validationErrors(String value, ShotPromptFormat format) {
    final prompt = normalize(value);
    if (prompt.isEmpty) return const ['输出为空'];
    final errors = <String>[];
    final maxChars = format == ShotPromptFormat.kling ? 500 : 1800;
    if (prompt.length > maxChars) errors.add('超过 $maxChars 个字符');
    if (prompt.contains('```') || prompt.contains('<think>')) {
      errors.add('包含代码围栏或思考标签');
    }
    if (RegExp(
      r'subject_definitions|summary\s*:|retention_analysis|detailed_description|overall_soundscape|non_diegetic_music|<Subject\s+\d+>|<Picture\s+\d+>|\[Shot\s+\d+\]|\[?参考生成\]?',
      caseSensitive: false,
    ).hasMatch(prompt)) {
      errors.add('混入了 H3 字段或引用语法');
    }
    final durations = RegExp(r'(\d+)\s*秒视频').allMatches(prompt).toList();
    if (durations.length != 1) {
      errors.add('必须且只能出现一次“X秒视频”');
    } else {
      final duration = int.tryParse(durations.single.group(1) ?? '');
      if (duration == null || duration < 4 || duration > 15) {
        errors.add('视频时长必须是 4 至 15 秒的整数');
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
}
