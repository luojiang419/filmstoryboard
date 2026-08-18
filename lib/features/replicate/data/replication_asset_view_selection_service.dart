import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../domain/replicate_models.dart';

class ReplicationAssetView {
  const ReplicationAssetView({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.orientation = '',
    this.description = '',
    this.matchReason = '',
    this.matchScore = 0,
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;
  final String orientation;
  final String description;
  final String matchReason;
  final double matchScore;
}

class ReplicationAssetViewSelection {
  const ReplicationAssetViewSelection({
    required this.isMultiView,
    required this.views,
    required this.primaryViewId,
    required this.detailViewIds,
    required this.rawResponse,
  });

  final bool isMultiView;
  final List<ReplicationAssetView> views;
  final String primaryViewId;
  final List<String> detailViewIds;
  final String rawResponse;
}

class ReplicationPreparedAssetView {
  const ReplicationPreparedAssetView({
    required this.path,
    required this.description,
    required this.isDetail,
  });

  final String path;
  final String description;
  final bool isDetail;
}

class ReplicationAssetViewSelectionService {
  const ReplicationAssetViewSelectionService({
    VisionStoryboardService? visionService,
  }) : _visionService = visionService;

  final VisionStoryboardService? _visionService;

  Future<List<ReplicationPreparedAssetView>> prepare({
    required AppSettings settings,
    required File originalFrame,
    required File assetImage,
    required Directory outputDirectory,
    required int shotNumber,
    required String assetId,
    required String assetName,
    required ReplicateAssetType assetType,
    required String slotLabel,
    int maximumOutputCount = 3,
  }) async {
    if (maximumOutputCount <= 1) {
      return [_original(assetImage)];
    }
    final visionService = _visionService;
    if (visionService == null ||
        !originalFrame.existsSync() ||
        !assetImage.existsSync()) {
      return [_original(assetImage)];
    }
    final decoded = img.decodeImage(await assetImage.readAsBytes());
    if (decoded == null) return [_original(assetImage)];
    final response = await visionService.complete(
      settings: settings,
      prompt: buildPrompt(
        shotNumber: shotNumber,
        assetName: assetName,
        assetType: assetType,
        slotLabel: slotLabel,
      ),
      imageFiles: [originalFrame, assetImage],
      maxTokens: 2200,
      allowThinking: false,
      compressOversizedImages: true,
    );
    final selection = parseResponse(response);
    if (!selection.isMultiView || selection.views.length < 2) {
      return [_original(assetImage)];
    }
    final viewsById = {for (final view in selection.views) view.id: view};
    final primary =
        viewsById[selection.primaryViewId] ??
        ([
          ...selection.views,
        ]..sort((a, b) => b.matchScore.compareTo(a.matchScore))).first;
    final selected = <({ReplicationAssetView view, bool isDetail})>[
      (view: primary, isDetail: false),
    ];
    for (final id in selection.detailViewIds) {
      final view = viewsById[id];
      if (view == null || view.id == primary.id) continue;
      selected.add((view: view, isDetail: true));
      if (selected.length >= maximumOutputCount) break;
    }
    await outputDirectory.create(recursive: true);
    final result = <ReplicationPreparedAssetView>[];
    for (final item in selected) {
      final cropped = _crop(decoded, item.view);
      if (cropped == null) continue;
      final target = File(
        p.join(
          outputDirectory.path,
          '${_safeName(assetId)}_${_safeName(item.view.id)}.png',
        ),
      );
      await target.writeAsBytes(img.encodePng(cropped), flush: true);
      result.add(
        ReplicationPreparedAssetView(
          path: target.path,
          description: [
            item.view.orientation,
            item.view.description,
            item.view.matchReason,
          ].where((value) => value.trim().isNotEmpty).join('；'),
          isDetail: item.isDetail,
        ),
      );
    }
    return result.isEmpty ? [_original(assetImage)] : result;
  }

  ReplicationAssetViewSelection parseResponse(String response) {
    final json = _extractJsonObject(response);
    final rawViews = json['views'];
    final views = <ReplicationAssetView>[];
    if (rawViews is List) {
      for (var index = 0; index < rawViews.length; index++) {
        final raw = rawViews[index];
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry('$key', value));
        final box = item['bbox'] ?? item['box'];
        if (box is! List || box.length < 4) continue;
        final left = _number(box[0]);
        final top = _number(box[1]);
        final width = _number(box[2]);
        final height = _number(box[3]);
        if (width <= 0 || height <= 0) continue;
        views.add(
          ReplicationAssetView(
            id: _text(item, const ['id', 'view_id']).isEmpty
                ? 'view-${index + 1}'
                : _text(item, const ['id', 'view_id']),
            left: left.clamp(0.0, 1.0),
            top: top.clamp(0.0, 1.0),
            width: width.clamp(0.0, 1.0),
            height: height.clamp(0.0, 1.0),
            orientation: _text(item, const ['orientation', 'viewpoint']),
            description: _text(item, const ['description', 'visible_details']),
            matchReason: _text(item, const ['match_reason', 'reason']),
            matchScore: _number(
              item['match_score'] ?? item['score'],
            ).clamp(0.0, 1.0),
          ),
        );
      }
    }
    final detailIds = json['selected_detail_view_ids'];
    return ReplicationAssetViewSelection(
      isMultiView: _flag(json['is_multi_view']) && views.length >= 2,
      views: List.unmodifiable(views),
      primaryViewId: '${json['selected_primary_view_id'] ?? ''}'.trim(),
      detailViewIds: detailIds is List
          ? detailIds
                .map((value) => '$value'.trim())
                .where((value) => value.isNotEmpty)
                .toList(growable: false)
          : const [],
      rawResponse: response,
    );
  }

  static String buildPrompt({
    required int shotNumber,
    required String assetName,
    required ReplicateAssetType assetType,
    required String slotLabel,
  }) =>
      '''
你正在为镜头 $shotNumber 选择高保真复刻参考图。
图片1是当前原视频帧，只用于判断目标主体在成片中的机位、朝向、可见面、景别、遮挡和需要展示的局部。
图片2是${slotLabel.isEmpty ? '绑定资产' : slotLabel}“$assetName”（类型：${assetType.name}）。

判断图片2是否为包含两个或以上独立视图、分栏、宫格、正反侧面或整体与细节的多视图拼图。不要把单张照片中的背景区域、镜面反射或多个真实主体误判为拼图。
若是多视图拼图：
1. 为每个独立视图给出紧贴有效画面的归一化边界 [left, top, width, height]，数值范围 0 到 1；排除分隔线、空白边和文字标题。
2. 根据图片1的目标机位和可见面选择一个主视图。主视图优先完整轮廓、视角匹配、遮挡少、分辨率高；不能只因为位于中间而选择。
3. 最多选择两个额外细节视图，只用于补充主视图看不到但镜头中需要呈现的结构、接缝、边缘、材质或五官。不要选择内容重复或低清视图。
若图片2不是多视图拼图，`is_multi_view` 必须为 false，选择字段留空。

只返回标准 JSON，不要 Markdown 或解释：
{
  "is_multi_view": true,
  "views": [
    {
      "id": "view-1",
      "bbox": [0.0, 0.0, 0.2, 1.0],
      "orientation": "正面/背面/画面左侧面/画面右侧面/三分之二侧面/局部细节",
      "description": "该视图可见的整体结构与独有细节",
      "match_score": 0.0,
      "match_reason": "与图片1目标机位、可见面和细节需求的对应理由"
    }
  ],
  "selected_primary_view_id": "view-1",
  "selected_detail_view_ids": ["view-4"]
}
''';

  static ReplicationPreparedAssetView _original(File file) =>
      ReplicationPreparedAssetView(
        path: file.path,
        description: '',
        isDetail: false,
      );

  static img.Image? _crop(img.Image source, ReplicationAssetView view) {
    final left = (view.left * source.width).round().clamp(0, source.width - 1);
    final top = (view.top * source.height).round().clamp(0, source.height - 1);
    final right = ((view.left + view.width) * source.width).round().clamp(
      left + 1,
      source.width,
    );
    final bottom = ((view.top + view.height) * source.height).round().clamp(
      top + 1,
      source.height,
    );
    final width = right - left;
    final height = bottom - top;
    if (width < 16 || height < 16) return null;
    return img.copyCrop(source, x: left, y: top, width: width, height: height);
  }

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
      // 继续提取最外层 JSON。
    }
    final start = normalized.indexOf('{');
    final end = normalized.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('多视图分析未返回可解析 JSON');
    }
    final decoded = jsonDecode(normalized.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('多视图分析 JSON 格式异常');
  }

  static String _text(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value != null && '$value'.trim().isNotEmpty) return '$value'.trim();
    }
    return '';
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }

  static bool _flag(Object? value) =>
      value == true || value == 1 || '$value'.toLowerCase() == 'true';

  static String _safeName(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return normalized.isEmpty ? 'view' : normalized;
  }
}
