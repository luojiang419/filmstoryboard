import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';

class QuickReplicationPersonCountResult {
  const QuickReplicationPersonCountResult({
    required this.personCount,
    required this.rawResponse,
  });

  final int personCount;
  final String rawResponse;
}

class QuickReplicationPersonCountService {
  const QuickReplicationPersonCountService({
    VisionStoryboardService? visionService,
  }) : _visionService = visionService;

  final VisionStoryboardService? _visionService;

  Future<QuickReplicationPersonCountResult> analyze({
    required AppSettings settings,
    required File imageFile,
    required int shotNumber,
  }) async {
    final visionService = _visionService;
    if (visionService == null) {
      throw StateError('快速模特人数识别服务未配置视觉模型客户端');
    }
    if (!imageFile.existsSync()) {
      throw FileSystemException('原视频帧不存在', imageFile.path);
    }
    final response = await visionService.complete(
      settings: settings,
      prompt: buildPrompt(shotNumber: shotNumber),
      imageFiles: [imageFile],
      maxTokens: 64,
      allowThinking: false,
      compressOversizedImages: true,
    );
    return parseResponse(response);
  }

  QuickReplicationPersonCountResult parseResponse(String response) {
    final json = _extractJsonObject(response);
    final rawCount = json['person_count'] ?? json['personCount'];
    final count = rawCount is num
        ? rawCount.round()
        : int.tryParse('$rawCount'.trim());
    if (count == null || count < 0 || count > 20) {
      throw const FormatException('快速模特人数识别返回了无效的 person_count');
    }
    return QuickReplicationPersonCountResult(
      personCount: count,
      rawResponse: response,
    );
  }

  static String buildPrompt({required int shotNumber}) =>
      '''
只识别镜头 $shotNumber 图片中作为画面主体的真实人物或模特数量，不分析产品、服装、配饰、动作、姿态、场景、构图、文字或其他内容。

计数规则：
- 每位不同的真实人物分别计数，人物身份或服装相似也不能合并。
- 以人物中心点从画面左到右确定后续槽位顺序；程序会依次命名为模特A、模特B直到模特N。
- 不计入海报、屏幕、照片、雕像、镜中重复影像或远处非主体路人。
- 只返回 JSON，不要解释、Markdown 或其他字段：{"person_count":2}
''';

  static Map<String, dynamic> _extractJsonObject(String response) {
    final normalized = response
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 兼容模型在 JSON 外附带少量文字的情况。
    }
    final start = normalized.indexOf('{');
    final end = normalized.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('快速模特人数识别未返回可解析的 JSON');
    }
    final decoded = jsonDecode(normalized.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('快速模特人数识别 JSON 格式异常');
  }
}
