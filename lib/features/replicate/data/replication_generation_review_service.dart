import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';

class ReplicationGenerationReviewInput {
  const ReplicationGenerationReviewInput({
    required this.shotNumber,
    required this.originalFrame,
    required this.orderedReferenceImages,
    required this.depthReferenceImageNumber,
    required this.generatedImage,
    required this.structuredConstraints,
  });

  final int shotNumber;
  final File originalFrame;

  /// 与图片生成请求完全相同的稳定顺序；图片 1 必须是原帧。
  final List<File> orderedReferenceImages;

  /// 高精度深度图在 [orderedReferenceImages] 中使用的一基图片编号。
  final int depthReferenceImageNumber;
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

enum ReplicationPoseReviewDecision { passed, correctionRequired, inconclusive }

class ReplicationGenerationReviewResult {
  const ReplicationGenerationReviewResult({
    required this.decision,
    required this.rawResponse,
    this.issue,
    this.diagnostic = '',
  });

  final ReplicationPoseReviewDecision decision;
  final ReplicationGenerationReviewIssue? issue;
  final String rawResponse;
  final String diagnostic;

  bool get passed => decision == ReplicationPoseReviewDecision.passed;

  bool get requiresCorrection =>
      decision == ReplicationPoseReviewDecision.correctionRequired;

  bool get isInconclusive =>
      decision == ReplicationPoseReviewDecision.inconclusive;

  Map<String, Object?> toJson() => {
    'decision': decision.name,
    'passed': passed,
    if (issue != null) 'issue': issue!.toJson(),
    if (diagnostic.isNotEmpty) 'diagnostic': diagnostic,
    'rawResponse': rawResponse,
  };

  factory ReplicationGenerationReviewResult.fromJson(
    Map<String, Object?> json,
  ) {
    final rawIssue = json['issue'];
    final issue = rawIssue is Map
        ? ReplicationGenerationReviewIssue.fromJson(
            rawIssue.map((key, value) => MapEntry('$key', value)),
          )
        : null;
    final storedDecision = json['decision']?.toString().trim() ?? '';
    final decision = ReplicationPoseReviewDecision.values
        .where((value) => value.name == storedDecision)
        .firstOrNull;
    final resolvedDecision =
        decision ??
        (json['passed'] == true
            ? ReplicationPoseReviewDecision.passed
            : issue != null
            ? ReplicationPoseReviewDecision.correctionRequired
            : ReplicationPoseReviewDecision.inconclusive);
    if (resolvedDecision == ReplicationPoseReviewDecision.correctionRequired &&
        issue == null) {
      throw const FormatException('持久化的姿势审核结果缺少校正问题');
    }
    return ReplicationGenerationReviewResult(
      decision: resolvedDecision,
      issue: issue,
      diagnostic: json['diagnostic']?.toString() ?? '',
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
你是镜头 ${input.shotNumber} 的深度几何保护审核器。本次只核验动作、遮挡、接触与可辨认表面几何，不做通用质量审核，不创作、不改写提示词，也不得重新解释任何资产的权威边界。

图片编号：
- 图片1是原帧编辑底图。
$additionalReferenceDescription
- 图片${input.depthReferenceImageNumber}是本次唯一高精度深度结构证据：白近灰远，纯黑主体外区域无效；定义人体前后关系、动作几何、遮挡边界、身体表面起伏及可辨认衣物褶皱峰谷，不定义身份、产品设计、文字、Logo、材质、颜色、光影或背景外观。
- 图片$generatedImageNumber 是唯一待审核的生成结果。

【已冻结结构化约束】
${input.structuredConstraints.trim()}

审核规则：
1. 检查图片$generatedImageNumber 相对图片${input.depthReferenceImageNumber}与冻结约束是否存在明确的 depth_geometry 偏差：人体前后层级、肢体方向、身体重心、动作阶段、人物视线、手物接触、轮廓遮挡，或对应衣片上可明确定位的主要褶皱峰谷明显错误。
2. 不得检查或报告画幅、机位、构图、人物身份、服装或产品外观、产品局部细节、场景、文字、Logo、二维码、条形码、材质、清晰度、光影、调色或融合质量；这些均不属于本模块。
3. 只有偏差能在图片$generatedImageNumber 中直接定位，并能由图片${input.depthReferenceImageNumber}或冻结约束明确反证时，才返回 correction_required；深度图未保存的细纹理、材质明暗或遮挡造成的不可见区域不得判错。
4. 多人物时必须按冻结槽位逐一核验，禁止交换人物；若证据不足、关键肢体被遮挡或无法可靠比较，返回 inconclusive，禁止猜测。
5. correction 只能修正一个证据最明确的姿势或接触偏差，不得顺带改变任何其他内容。

只返回一个 JSON 对象，不要 Markdown、解释或额外字段：
通过时：
{"decision":"passed","issue":null}

需要校正时：
{"decision":"correction_required","issue":{"code":"depth_geometry","summary":"一个简短几何问题","evidence":"待审核图中可定位且能由深度证据反证的事实","correction":"只修正该动作、遮挡、接触或表面起伏问题的明确要求"}}

无法可靠判断时：
{"decision":"inconclusive","reason":"无法可靠比较的简短原因"}
''';
  }

  ReplicationGenerationReviewResult parseResponse(String response) {
    final json = _extractJsonObject(response);
    final decision = _reviewDecision(json);
    if (decision == ReplicationPoseReviewDecision.passed) {
      return ReplicationGenerationReviewResult(
        decision: decision,
        rawResponse: response,
      );
    }
    if (decision == ReplicationPoseReviewDecision.inconclusive) {
      final diagnostic = _text(json, const ['reason', 'diagnostic', 'summary']);
      if (diagnostic.isEmpty) {
        throw const FormatException('姿势审核无法判断，但没有返回原因');
      }
      return ReplicationGenerationReviewResult(
        decision: decision,
        rawResponse: response,
        diagnostic: diagnostic,
      );
    }
    final rawIssue = json['issue'];
    final issue = rawIssue is Map ? _issue(rawIssue) : null;
    if (issue == null) {
      throw const FormatException('姿势审核要求校正，但没有返回可验证的单一姿势问题');
    }
    return ReplicationGenerationReviewResult(
      decision: decision,
      issue: issue,
      rawResponse: response,
    );
  }

  static String buildCorrectionPrompt(ReplicationGenerationReviewIssue issue) =>
      '''
只修正以下一个问题，其他内容不变。

问题：${issue.summary}
可验证证据：${issue.evidence}
修正要求：${issue.correction}

这是一次深度几何保护校正，不是重新生成。只能调整上述证据明确指定的动作、遮挡、接触、轮廓或表面起伏；其余细节保持不变。

必须保持上一轮中除此问题之外的全部内容不变，包括画幅、机位、透视、构图、人物与产品槽位、资产唯一权威来源、原帧元素白名单、人物身份、完整穿搭、产品整体与局部外观、文字与标识、遮挡、光影、调色、景深和已经正确的细节。不得新增、删除或顺带改动其他元素，不得修补产品局部细节或改动任何 Logo/文字。最终只输出一张修正后的完整图片，不要输出解释或文字说明。
''';

  static void _validateInput(ReplicationGenerationReviewInput input) {
    if (input.orderedReferenceImages.isEmpty) {
      throw const FormatException('生成后审核缺少按生成顺序排列的参考图');
    }
    final first = input.orderedReferenceImages.first.absolute.path;
    if (first != input.originalFrame.absolute.path) {
      throw const FormatException('生成后审核的图片1必须是原帧');
    }
    if (input.depthReferenceImageNumber < 2 ||
        input.depthReferenceImageNumber > input.orderedReferenceImages.length) {
      throw const FormatException('几何审核缺少有效的高精度深度图编号');
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
    if (code != 'depth_geometry' ||
        summary.isEmpty ||
        evidence.isEmpty ||
        correction.isEmpty) {
      return null;
    }
    return ReplicationGenerationReviewIssue(
      code: code,
      priority: 1,
      summary: summary,
      evidence: evidence,
      correction: correction,
    );
  }

  static String _normalizedCode(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp(r'[\s-]+'),
      '_',
    );
    return normalized == 'depth_geometry' ? normalized : 'unknown';
  }

  static ReplicationPoseReviewDecision _reviewDecision(
    Map<String, dynamic> json,
  ) {
    final normalized = _normalizedText(json['decision'] ?? json['status']);
    if (normalized == 'passed' ||
        normalized == 'pass' ||
        _bool(json['passed']) == true) {
      return ReplicationPoseReviewDecision.passed;
    }
    if (normalized == 'correction_required' ||
        normalized == 'needs_correction' ||
        normalized == 'failed' ||
        normalized == 'fail' ||
        _bool(json['passed']) == false && json['issue'] is Map) {
      return ReplicationPoseReviewDecision.correctionRequired;
    }
    if (normalized == 'inconclusive' ||
        normalized == 'uncertain' ||
        normalized == 'unverifiable') {
      return ReplicationPoseReviewDecision.inconclusive;
    }
    throw const FormatException('姿势审核未返回有效 decision');
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
