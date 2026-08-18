import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';

class ReplicationGenerationReviewInput {
  const ReplicationGenerationReviewInput({
    required this.shotNumber,
    required this.originalFrame,
    required this.orderedReferenceImages,
    required this.generatedImage,
    required this.structuredConstraints,
  });

  final int shotNumber;
  final File originalFrame;

  /// 与图片生成请求完全相同的稳定顺序；图片 1 必须是原帧。
  final List<File> orderedReferenceImages;
  final File generatedImage;

  /// 已由确定性编译器冻结的资产权威边界、白名单和结构约束。
  final String structuredConstraints;
}

class ReplicationGenerationReviewIssue {
  const ReplicationGenerationReviewIssue({
    required this.code,
    required this.priority,
    required this.summary,
    required this.evidence,
    required this.correction,
  });

  final String code;
  final int priority;
  final String summary;
  final String evidence;
  final String correction;

  Map<String, Object?> toJson() => {
    'code': code,
    'priority': priority,
    'summary': summary,
    'evidence': evidence,
    'correction': correction,
  };

  factory ReplicationGenerationReviewIssue.fromJson(Map<String, Object?> json) {
    final issue = ReplicationGenerationReviewService._issue(json);
    if (issue == null) {
      throw const FormatException('持久化的生成后审核问题无效');
    }
    return issue;
  }
}

class ReplicationGenerationReviewResult {
  const ReplicationGenerationReviewResult({
    required this.passed,
    required this.rawResponse,
    this.issue,
  });

  final bool passed;
  final ReplicationGenerationReviewIssue? issue;
  final String rawResponse;

  Map<String, Object?> toJson() => {
    'passed': passed,
    if (issue != null) 'issue': issue!.toJson(),
    'rawResponse': rawResponse,
  };

  factory ReplicationGenerationReviewResult.fromJson(
    Map<String, Object?> json,
  ) {
    final passed = json['passed'] == true;
    final rawIssue = json['issue'];
    final issue = rawIssue is Map
        ? ReplicationGenerationReviewIssue.fromJson(
            rawIssue.map((key, value) => MapEntry('$key', value)),
          )
        : null;
    if (!passed && issue == null) {
      throw const FormatException('持久化的生成后审核结果缺少问题');
    }
    return ReplicationGenerationReviewResult(
      passed: passed,
      issue: issue,
      rawResponse: json['rawResponse']?.toString() ?? '',
    );
  }
}

class ReplicationGenerationReviewService {
  const ReplicationGenerationReviewService({
    VisionStoryboardService? visionService,
  }) : _visionService = visionService;

  final VisionStoryboardService? _visionService;

  static const responseTimeout = Duration(minutes: 10);

  Future<ReplicationGenerationReviewResult> review({
    required AppSettings settings,
    required ReplicationGenerationReviewInput input,
    bool allowThinking = false,
  }) async {
    final visionService = _visionService;
    if (visionService == null) {
      throw StateError('生成后审核服务未配置视觉模型客户端');
    }
    _validateInput(input);
    final response = await visionService.complete(
      settings: settings,
      prompt: buildPrompt(input),
      imageFiles: [...input.orderedReferenceImages, input.generatedImage],
      maxTokens: 1200,
      allowThinking: allowThinking,
      responseTimeout: responseTimeout,
      compressOversizedImages: true,
    );
    return parseResponse(response);
  }

  String buildPrompt(ReplicationGenerationReviewInput input) {
    final generatedImageNumber = input.orderedReferenceImages.length + 1;
    final additionalReferenceDescription =
        input.orderedReferenceImages.length > 1
        ? '- 图片2至图片${input.orderedReferenceImages.length}与生成请求中的编号和顺序完全相同，只能按下方冻结约束中声明的职责提供证据。'
        : '- 本次除图片1原帧外没有额外参考图。';
    return '''
你是镜头 ${input.shotNumber} 的生成后质量审核器。本次只做逐项核验，不创作、不改写提示词，也不得重新解释任何资产的权威边界。

图片编号：
- 图片1是原帧编辑底图。
$additionalReferenceDescription
- 图片$generatedImageNumber 是唯一待审核的生成结果。

【已冻结结构化约束】
${input.structuredConstraints.trim()}

审核规则：
1. 必须以已冻结约束为唯一判定标准；不得推断新资产职责，不得交换人物或产品槽位，不得把原帧未授权元素改判为可保留。
2. 按固定优先级检查：
   P1 composition_geometry：原帧画幅、机位、透视、构图、槽位、方向或遮挡被明显改变。
   P2 asset_authority：人物身份、产品整体/细节或场景没有使用其唯一权威资产，发生融合、串位、漏用或多余副本。
   P3 subject_decision：替换/移除计划或原帧元素白名单执行错误，出现未授权残留。
   P4 pose_contact：姿态、动作阶段、视线、手物接触或结构辅助约束明显错误。
   P5 forbidden_text：出现未授权文字、数字、字幕、水印、Logo、二维码或条形码。
   P6 integration_quality：仅在前五项都合格时，检查明显破损、畸形、低清纹理或光影融合错误。
3. 若存在多个问题，只返回优先级最高的一项；同级只返回证据最清晰、可在图片$generatedImageNumber 中直接定位的一项。禁止返回问题列表。
4. evidence 必须描述图片$generatedImageNumber 中可直接观察和定位的证据；不能验证的问题不得报告。
5. correction 只描述如何修正这一项，不得顺带改变任何其他内容。

只返回一个 JSON 对象，不要 Markdown、解释或额外字段：
通过时：
{"passed":true,"issue":null}

不通过时：
{"passed":false,"issue":{"code":"composition_geometry|asset_authority|subject_decision|pose_contact|forbidden_text|integration_quality","summary":"一个简短问题","evidence":"待审核图中可定位的证据","correction":"只修正该问题的明确要求"}}
''';
  }

  ReplicationGenerationReviewResult parseResponse(String response) {
    final json = _extractJsonObject(response);
    final passed =
        _bool(json['passed']) ??
        (_normalizedText(json['status']) == 'pass' ||
            _normalizedText(json['status']) == 'passed');
    if (passed) {
      return ReplicationGenerationReviewResult(
        passed: true,
        rawResponse: response,
      );
    }
    final candidates = <ReplicationGenerationReviewIssue>[];
    final rawIssue = json['issue'];
    if (rawIssue is Map) {
      final issue = _issue(rawIssue);
      if (issue != null) candidates.add(issue);
    }
    final rawIssues = json['issues'];
    if (rawIssues is List) {
      for (final raw in rawIssues) {
        if (raw is! Map) continue;
        final issue = _issue(raw);
        if (issue != null) candidates.add(issue);
      }
    }
    if (candidates.isEmpty) {
      throw const FormatException('生成后审核未通过，但没有返回可验证的单一问题');
    }
    candidates.sort((left, right) => left.priority.compareTo(right.priority));
    return ReplicationGenerationReviewResult(
      passed: false,
      issue: candidates.first,
      rawResponse: response,
    );
  }

  static String buildCorrectionPrompt(ReplicationGenerationReviewIssue issue) =>
      '''
只修正以下一个问题，其他内容不变。

问题：${issue.summary}
可验证证据：${issue.evidence}
修正要求：${issue.correction}

必须保持上一轮中除此问题之外的全部内容不变，包括画幅、机位、透视、构图、人物与产品槽位、资产唯一权威来源、原帧元素白名单、姿态、接触、遮挡、光影、调色、景深和已经正确的细节。不得新增、删除或顺带改动其他元素。最终只输出一张修正后的完整图片，不要输出解释或文字说明。
''';

  static void _validateInput(ReplicationGenerationReviewInput input) {
    if (input.orderedReferenceImages.isEmpty) {
      throw const FormatException('生成后审核缺少按生成顺序排列的参考图');
    }
    final first = input.orderedReferenceImages.first.absolute.path;
    if (first != input.originalFrame.absolute.path) {
      throw const FormatException('生成后审核的图片1必须是原帧');
    }
    for (final file in [
      ...input.orderedReferenceImages,
      input.generatedImage,
    ]) {
      if (!file.existsSync()) {
        throw FileSystemException('生成后审核输入图片不存在', file.path);
      }
    }
    if (input.structuredConstraints.trim().isEmpty) {
      throw const FormatException('生成后审核缺少已冻结结构化约束');
    }
  }

  static ReplicationGenerationReviewIssue? _issue(Map<dynamic, dynamic> raw) {
    final item = raw.map((key, value) => MapEntry('$key', value));
    final code = _normalizedCode(_text(item, const ['code', 'issue_code']));
    final summary = _text(item, const ['summary', 'problem', 'description']);
    final evidence = _text(item, const ['evidence', 'visual_evidence']);
    final correction = _text(item, const [
      'correction',
      'correction_instruction',
      'fix',
    ]);
    if (!_priorityByCode.containsKey(code) ||
        summary.isEmpty ||
        evidence.isEmpty ||
        correction.isEmpty) {
      return null;
    }
    return ReplicationGenerationReviewIssue(
      code: code,
      priority: _priorityByCode[code] ?? 99,
      summary: summary,
      evidence: evidence,
      correction: correction,
    );
  }

  static const _priorityByCode = <String, int>{
    'composition_geometry': 1,
    'asset_authority': 2,
    'subject_decision': 3,
    'pose_contact': 4,
    'forbidden_text': 5,
    'integration_quality': 6,
  };

  static String _normalizedCode(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp(r'[\s-]+'),
      '_',
    );
    return _priorityByCode.containsKey(normalized) ? normalized : 'unknown';
  }

  static Map<String, dynamic> _extractJsonObject(String response) {
    final trimmed = response
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 继续从解释文本中提取最外层 JSON。
    }
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('生成后审核未返回可解析的 JSON');
    }
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('生成后审核 JSON 格式异常');
  }

  static bool? _bool(Object? value) {
    if (value is bool) return value;
    final normalized = _normalizedText(value);
    if (normalized == 'true' || normalized == 'yes') return true;
    if (normalized == 'false' || normalized == 'no') return false;
    return null;
  }

  static String _normalizedText(Object? value) =>
      value?.toString().trim().toLowerCase() ?? '';

  static String _text(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value != 'null') return value;
    }
    return '';
  }
}
