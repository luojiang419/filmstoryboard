import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../settings/domain/app_settings.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../domain/quick_replication_reference.dart';

class QuickReplicationPlanningOutcome {
  const QuickReplicationPlanningOutcome({
    required this.plan,
    required this.usedVision,
    required this.cacheHit,
    this.fallbackReason = '',
    this.rawResponse = '',
  });

  final QuickReplicationPlan plan;
  final bool usedVision;
  final bool cacheHit;
  final String fallbackReason;
  final String rawResponse;

  bool get usedLocalFallback => fallbackReason.isNotEmpty;
}

class QuickReplicationPromptPlanningService {
  QuickReplicationPromptPlanningService({
    VisionStoryboardService? visionService,
    this.maximumCacheEntries = 64,
  }) : _visionService = visionService;

  final VisionStoryboardService? _visionService;
  final int maximumCacheEntries;
  final LinkedHashMap<String, QuickReplicationPlan> _cache = LinkedHashMap();

  int get cacheEntryCount => _cache.length;

  void clearCache() => _cache.clear();

  Future<QuickReplicationPlanningOutcome> plan({
    required AppSettings settings,
    required List<QuickReplicationReference> references,
    required Map<String, File> imageFilesByAssetId,
    String supplement = '',
    QuickReplicationPlan? localPlan,
  }) async {
    final local =
        localPlan ??
        const QuickReplicationLocalPlanner().plan(
          references: references,
          supplement: supplement,
        );
    if (!local.needsVisualPlanning) {
      return QuickReplicationPlanningOutcome(
        plan: local,
        usedVision: false,
        cacheHit: false,
      );
    }
    final visionService = _visionService;
    if (visionService == null) {
      return QuickReplicationPlanningOutcome(
        plan: local,
        usedVision: false,
        cacheHit: false,
        fallbackReason: '轻量视觉规划服务未配置，已使用本地顺序计划。',
      );
    }

    final orderedFiles = <File>[];
    for (final reference in local.references) {
      final file = imageFilesByAssetId[reference.assetId];
      if (file == null || !file.existsSync()) {
        return QuickReplicationPlanningOutcome(
          plan: local,
          usedVision: false,
          cacheHit: false,
          fallbackReason: '图${reference.imageNumber}的资产文件不存在，已使用本地顺序计划。',
        );
      }
      orderedFiles.add(file);
    }

    final cacheKey = await _cacheKey(
      plan: local,
      files: orderedFiles,
      supplement: supplement,
    );
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      return QuickReplicationPlanningOutcome(
        plan: cached,
        usedVision: true,
        cacheHit: true,
      );
    }

    try {
      final response = await visionService.complete(
        settings: settings,
        prompt: buildPrompt(localPlan: local, supplement: supplement),
        imageFiles: orderedFiles,
        maxTokens: 2200,
        allowThinking: false,
        compressOversizedImages: true,
      );
      final planned = parseAndValidateResponse(
        response,
        localPlan: local,
        originalSupplement: supplement,
      );
      _cache[cacheKey] = planned;
      while (_cache.length > maximumCacheEntries && _cache.isNotEmpty) {
        _cache.remove(_cache.keys.first);
      }
      return QuickReplicationPlanningOutcome(
        plan: planned,
        usedVision: true,
        cacheHit: false,
        rawResponse: response,
      );
    } catch (error) {
      return QuickReplicationPlanningOutcome(
        plan: local,
        usedVision: true,
        cacheHit: false,
        fallbackReason: '轻量视觉规划失败，已使用本地顺序计划：$error',
      );
    }
  }

  QuickReplicationPlan parseAndValidateResponse(
    String response, {
    required QuickReplicationPlan localPlan,
    required String originalSupplement,
  }) {
    final json = _extractJsonObject(response);
    final referencesByImage = {
      for (final reference in localPlan.references)
        reference.imageNumber: reference,
    };
    final productByImage = {
      for (final reference in localPlan.references)
        if (reference.role == QuickReferenceRole.product)
          reference.imageNumber: reference,
    };
    final detailByImage = {
      for (final reference in localPlan.references)
        if (reference.role == QuickReferenceRole.productDetail)
          reference.imageNumber: reference,
    };
    final localGroupByLabel = {
      for (final group in localPlan.productGroups) group.label: group,
    };

    final rawGroups = json['productGroups'] ?? json['product_groups'];
    if (rawGroups is! List) {
      throw const FormatException('视觉规划缺少 productGroups 数组');
    }
    final masterImagesSeen = <int>{};
    final detailGroupLabelByImage = <int, String>{};
    for (final raw in rawGroups) {
      if (raw is! Map) throw const FormatException('productGroups 项格式异常');
      final item = raw.map((key, value) => MapEntry('$key', value));
      final label = '${item['label'] ?? ''}'.trim().toUpperCase();
      final masterImage = _integer(item['masterImage'] ?? item['master_image']);
      final expectedGroup = localGroupByLabel[label];
      if (expectedGroup == null ||
          expectedGroup.masterImageNumber != masterImage ||
          !productByImage.containsKey(masterImage)) {
        throw FormatException('产品$label的主图编号无效：图$masterImage');
      }
      if (!masterImagesSeen.add(masterImage)) {
        throw FormatException('产品主图重复分组：图$masterImage');
      }
      final rawDetails =
          item['detailImages'] ?? item['detail_images'] ?? const [];
      if (rawDetails is! List) {
        throw FormatException('产品$label的 detailImages 不是数组');
      }
      for (final rawDetail in rawDetails) {
        final detailImage = _integer(rawDetail);
        if (!detailByImage.containsKey(detailImage)) {
          throw FormatException('产品$label引用了非产品细节图：图$detailImage');
        }
        if (detailGroupLabelByImage.putIfAbsent(detailImage, () => label) !=
            label) {
          throw FormatException('图$detailImage被归入多个产品');
        }
      }
    }
    if (masterImagesSeen.length != productByImage.length) {
      throw const FormatException('视觉规划遗漏产品主图');
    }

    final rawReferences = json['references'];
    if (rawReferences is! List) {
      throw const FormatException('视觉规划缺少 references 数组');
    }
    final modelReferenceByImage = <int, Map<String, dynamic>>{};
    for (final raw in rawReferences) {
      if (raw is! Map) throw const FormatException('references 项格式异常');
      final item = raw.map((key, value) => MapEntry('$key', value));
      final imageNumber = _integer(item['imageNumber'] ?? item['image_number']);
      if (!referencesByImage.containsKey(imageNumber)) {
        throw FormatException('视觉规划添加了不存在的图片编号：图$imageNumber');
      }
      if (modelReferenceByImage.putIfAbsent(imageNumber, () => item) != item) {
        throw FormatException('视觉规划重复返回图$imageNumber');
      }
      final assignedProduct = _assignedProductLabel(item);
      if (assignedProduct != null &&
          !localGroupByLabel.containsKey(assignedProduct)) {
        throw FormatException('图$imageNumber引用了不存在的产品$assignedProduct');
      }
      final groupedLabel = detailGroupLabelByImage[imageNumber];
      if (assignedProduct != null &&
          groupedLabel != null &&
          assignedProduct != groupedLabel) {
        throw FormatException('图$imageNumber的产品分组与引用结果冲突');
      }
    }

    final assignments = <QuickReferenceAssignment>[];
    final warnings = <String>[...localPlan.warnings];
    for (final reference in localPlan.references) {
      final localAssignment = localPlan.assignmentFor(reference.assetId)!;
      final modelReference = modelReferenceByImage[reference.imageNumber];
      final normalizedDescription = modelReference == null
          ? localAssignment.normalizedDescription
          : _text(modelReference, const [
              'normalizedDescription',
              'normalized_description',
            ], fallback: localAssignment.normalizedDescription);
      if (reference.role != QuickReferenceRole.productDetail) {
        assignments.add(
          QuickReferenceAssignment(
            assetId: reference.assetId,
            imageNumber: reference.imageNumber,
            role: reference.role,
            normalizedDescription: normalizedDescription,
            evidence: localAssignment.evidence,
            confidence: localAssignment.confidence,
            groupAnchorAssetId: localAssignment.groupAnchorAssetId,
            productLabel: localAssignment.productLabel,
            warning: localAssignment.warning,
          ),
        );
        continue;
      }

      final modelLabel = modelReference == null
          ? detailGroupLabelByImage[reference.imageNumber]
          : _assignedProductLabel(modelReference) ??
                detailGroupLabelByImage[reference.imageNumber];
      final modelGroup = modelLabel == null
          ? null
          : localGroupByLabel[modelLabel];
      var anchorId = modelGroup?.anchorAssetId;
      var productLabel = modelLabel;
      var warning = modelReference == null
          ? localAssignment.warning
          : _text(modelReference, const ['warning']);
      var evidence = _evidence(
        modelReference?['evidence'],
        fallback: localAssignment.evidence,
      );
      var confidence = _number(
        modelReference?['confidence'],
        fallback: localAssignment.confidence,
      ).clamp(0.0, 1.0);

      final explicitLocal =
          localAssignment.evidence ==
              QuickReferenceEvidence.explicitImageNumber ||
          localAssignment.evidence ==
              QuickReferenceEvidence.explicitProductLabel;
      if (explicitLocal &&
          localAssignment.groupAnchorAssetId != null &&
          anchorId != localAssignment.groupAnchorAssetId) {
        anchorId = localAssignment.groupAnchorAssetId;
        productLabel = localAssignment.productLabel;
        evidence = localAssignment.evidence;
        confidence = 1;
        warning = [
          warning,
          '视觉判断与用户明确描述冲突，已按用户指定的$productLabel归组。',
        ].where((value) => value.trim().isNotEmpty).join(' ');
      }
      if (anchorId == null && productByImage.isNotEmpty && warning.isEmpty) {
        throw FormatException('图${reference.imageNumber}未分组且没有明确警告');
      }
      if (warning.isNotEmpty) warnings.add(warning);
      assignments.add(
        QuickReferenceAssignment(
          assetId: reference.assetId,
          imageNumber: reference.imageNumber,
          role: reference.role,
          normalizedDescription: normalizedDescription,
          evidence: evidence,
          confidence: confidence,
          groupAnchorAssetId: anchorId,
          productLabel: productLabel,
          warning: warning,
        ),
      );
    }

    final groups = <QuickProductGroup>[];
    for (final localGroup in localPlan.productGroups) {
      final details = assignments.where(
        (assignment) =>
            assignment.role == QuickReferenceRole.productDetail &&
            assignment.groupAnchorAssetId == localGroup.anchorAssetId,
      );
      groups.add(
        QuickProductGroup(
          label: localGroup.label,
          anchorAssetId: localGroup.anchorAssetId,
          masterImageNumber: localGroup.masterImageNumber,
          detailAssetIds: [for (final detail in details) detail.assetId],
          detailImageNumbers: [
            for (final detail in details) detail.imageNumber,
          ],
        ),
      );
    }
    final assignmentByAssetId = {
      for (final assignment in assignments) assignment.assetId: assignment,
    };
    final normalizedReferences = [
      for (final reference in localPlan.references)
        reference.copyWith(
          description:
              assignmentByAssetId[reference.assetId]!.normalizedDescription,
          groupAnchorAssetId:
              assignmentByAssetId[reference.assetId]!.groupAnchorAssetId,
          clearGroupAnchorAssetId:
              assignmentByAssetId[reference.assetId]!.groupAnchorAssetId ==
              null,
          groupConfidence: assignmentByAssetId[reference.assetId]!.confidence,
          clearGroupConfidence:
              assignmentByAssetId[reference.assetId]!.groupAnchorAssetId ==
              null,
          groupWarning: assignmentByAssetId[reference.assetId]!.warning,
        ),
    ];

    return QuickReplicationPlan(
      references: List.unmodifiable(normalizedReferences),
      productGroups: List.unmodifiable(groups),
      assignments: List.unmodifiable(assignments),
      normalizedSupplement: _text(json, const [
        'normalizedSupplement',
        'normalized_supplement',
      ], fallback: originalSupplement),
      needsVisualPlanning: false,
      warnings: List.unmodifiable(warnings.toSet()),
    );
  }

  static String buildPrompt({
    required QuickReplicationPlan localPlan,
    required String supplement,
  }) {
    final input = {
      'references': [
        for (final reference in localPlan.references)
          {
            'imageNumber': reference.imageNumber,
            'assetId': reference.assetId,
            'type': reference.role.name,
            'name': reference.name,
            'description': reference.description,
            'localAssignedProduct': localPlan
                .assignmentFor(reference.assetId)
                ?.productLabel,
          },
      ],
      'supplement': supplement,
    };
    return '''
你只负责为快速图片复刻整理多参考图的引用关系，不分析原帧动作，不生成场景分析、人体姿势、主体去留、产品长描述或最终图片提示词。

随请求提交的图片严格依次对应下列 references；不得重排、删除或添加图片编号。类型和用户描述是强约束，不得虚构品牌、文字、颜色、材质或结构。产品主图按输入顺序固定为产品A、产品B、产品C；主图控制整体外形，产品细节图只补充对应产品的局部证据。

归组证据优先级：描述明确图N > 描述明确产品A/B > 产品名称匹配 > 可见主体、轮廓、颜色、材质、结构和局部相似性 > 左侧最近产品。用户明确写出的图N或产品A/B不得被视觉判断覆盖；若明显冲突，仍按用户描述并写入 warning。无法可靠归组时 assignedProduct 留空并提供非空 warning。

输入：
${jsonEncode(input)}

只返回标准 JSON，不要 Markdown、解释或额外文字：
{
  "productGroups": [
    {"label":"A","masterImage":4,"detailImages":[5,6]}
  ],
  "references": [
    {
      "imageNumber":5,
      "role":"productDetail",
      "assignedProduct":"A",
      "normalizedDescription":"只陈述该图提供的可见局部证据",
      "evidence":"description/visual/sequence/unresolved",
      "confidence":1.0,
      "warning":""
    }
  ],
  "normalizedSupplement":"仅规范引用标记，不增加用户未提供的事实"
}
''';
  }

  Future<String> _cacheKey({
    required QuickReplicationPlan plan,
    required List<File> files,
    required String supplement,
  }) async {
    final fingerprints = <String>[];
    for (final file in files) {
      fingerprints.add(sha256.convert(await file.readAsBytes()).toString());
    }
    final payload = {
      'references': [
        for (var index = 0; index < plan.references.length; index++)
          {
            'assetId': plan.references[index].assetId,
            'imageNumber': plan.references[index].imageNumber,
            'order': plan.references[index].order,
            'role': plan.references[index].role.name,
            'name': plan.references[index].name,
            'description': plan.references[index].description,
            'anchor': plan.references[index].groupAnchorAssetId,
            'fingerprint': fingerprints[index],
          },
      ],
      'supplement': supplement,
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
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
      throw const FormatException('轻量视觉规划未返回可解析 JSON');
    }
    final decoded = jsonDecode(normalized.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('轻量视觉规划 JSON 格式异常');
  }

  static String? _assignedProductLabel(Map<String, dynamic> item) {
    final value = '${item['assignedProduct'] ?? item['assigned_product'] ?? ''}'
        .trim()
        .toUpperCase()
        .replaceFirst(RegExp(r'^产品'), '');
    return value.isEmpty ? null : value;
  }

  static QuickReferenceEvidence _evidence(
    Object? value, {
    required QuickReferenceEvidence fallback,
  }) => switch ('$value'.trim().toLowerCase()) {
    'description' ||
    'explicitimagenumber' => QuickReferenceEvidence.explicitImageNumber,
    'explicitproductlabel' => QuickReferenceEvidence.explicitProductLabel,
    'productname' => QuickReferenceEvidence.productName,
    'visual' => QuickReferenceEvidence.productName,
    'sequence' => QuickReferenceEvidence.leftSequence,
    'unresolved' => QuickReferenceEvidence.unresolved,
    _ => fallback,
  };

  static String _text(
    Map<String, dynamic> json,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = json[key];
      if (value != null && '$value'.trim().isNotEmpty) return '$value'.trim();
    }
    return fallback;
  }

  static int _integer(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? -1;
  }

  static double _number(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? fallback;
  }
}
