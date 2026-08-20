import '../../shooting_script/domain/shooting_script_workflow_models.dart';

enum QuickReferenceEvidence {
  master,
  explicitImageNumber,
  explicitProductLabel,
  productName,
  singleProduct,
  leftSequence,
  unresolved,
}

class QuickReplicationReference {
  const QuickReplicationReference({
    required this.assetId,
    required this.imageNumber,
    required this.order,
    required this.role,
    this.name = '',
    this.description = '',
    this.groupAnchorAssetId,
    this.groupConfidence,
    this.groupWarning = '',
  });

  final String assetId;
  final int imageNumber;
  final int order;
  final QuickReferenceRole role;
  final String name;
  final String description;
  final String? groupAnchorAssetId;
  final double? groupConfidence;
  final String groupWarning;

  QuickReplicationReference copyWith({
    String? description,
    String? groupAnchorAssetId,
    bool clearGroupAnchorAssetId = false,
    double? groupConfidence,
    bool clearGroupConfidence = false,
    String? groupWarning,
  }) => QuickReplicationReference(
    assetId: assetId,
    imageNumber: imageNumber,
    order: order,
    role: role,
    name: name,
    description: description ?? this.description,
    groupAnchorAssetId: clearGroupAnchorAssetId
        ? null
        : groupAnchorAssetId ?? this.groupAnchorAssetId,
    groupConfidence: clearGroupConfidence
        ? null
        : groupConfidence ?? this.groupConfidence,
    groupWarning: groupWarning ?? this.groupWarning,
  );
}

class QuickProductGroup {
  const QuickProductGroup({
    required this.label,
    required this.anchorAssetId,
    required this.masterImageNumber,
    this.detailAssetIds = const [],
    this.detailImageNumbers = const [],
  });

  final String label;
  final String anchorAssetId;
  final int masterImageNumber;
  final List<String> detailAssetIds;
  final List<int> detailImageNumbers;
}

class QuickReferenceAssignment {
  const QuickReferenceAssignment({
    required this.assetId,
    required this.imageNumber,
    required this.role,
    required this.normalizedDescription,
    required this.evidence,
    required this.confidence,
    this.groupAnchorAssetId,
    this.productLabel,
    this.warning = '',
  });

  final String assetId;
  final int imageNumber;
  final QuickReferenceRole role;
  final String normalizedDescription;
  final QuickReferenceEvidence evidence;
  final double confidence;
  final String? groupAnchorAssetId;
  final String? productLabel;
  final String warning;
}

class QuickReplicationPlan {
  const QuickReplicationPlan({
    required this.references,
    required this.productGroups,
    required this.assignments,
    required this.normalizedSupplement,
    required this.needsVisualPlanning,
    this.warnings = const [],
  });

  final List<QuickReplicationReference> references;
  final List<QuickProductGroup> productGroups;
  final List<QuickReferenceAssignment> assignments;
  final String normalizedSupplement;
  final bool needsVisualPlanning;
  final List<String> warnings;

  Map<String, String> get productLabelByAnchorAssetId => {
    for (final group in productGroups) group.anchorAssetId: group.label,
  };

  Map<String, String> get productAnchorAssetIdByLabel => {
    for (final group in productGroups) group.label: group.anchorAssetId,
  };

  QuickReferenceAssignment? assignmentFor(String assetId) {
    for (final assignment in assignments) {
      if (assignment.assetId == assetId) return assignment;
    }
    return null;
  }
}

class QuickReplicationLocalPlanner {
  const QuickReplicationLocalPlanner();

  QuickReplicationPlan plan({
    required List<QuickReplicationReference> references,
    String supplement = '',
    QuickReplicationPlan? previousPlan,
  }) {
    final ordered = [...references]
      ..sort((left, right) {
        final order = left.order.compareTo(right.order);
        return order != 0
            ? order
            : left.imageNumber.compareTo(right.imageNumber);
      });
    _validateUniqueInputs(ordered);

    final masters = [
      for (final reference in ordered)
        if (reference.role == QuickReferenceRole.product) reference,
    ];
    final currentLabelByAnchor = <String, String>{
      for (var index = 0; index < masters.length; index++)
        masters[index].assetId: productLabelForIndex(index),
    };
    final currentAnchorByLabel = {
      for (final entry in currentLabelByAnchor.entries) entry.value: entry.key,
    };
    final previousAnchorByLabel =
        previousPlan?.productAnchorAssetIdByLabel ?? const <String, String>{};
    final masterByAssetId = {for (final item in masters) item.assetId: item};
    final masterByImageNumber = {
      for (final item in masters) item.imageNumber: item,
    };

    final assignments = <QuickReferenceAssignment>[];
    final warnings = <String>[];
    var needsVisualPlanning = false;

    for (final reference in ordered) {
      if (reference.role == QuickReferenceRole.product) {
        assignments.add(
          QuickReferenceAssignment(
            assetId: reference.assetId,
            imageNumber: reference.imageNumber,
            role: reference.role,
            normalizedDescription: _rewriteProductMarkers(
              reference.description,
              previousAnchorByLabel: previousAnchorByLabel,
              currentLabelByAnchor: currentLabelByAnchor,
              warnings: warnings,
            ),
            evidence: QuickReferenceEvidence.master,
            confidence: 1,
            groupAnchorAssetId: reference.assetId,
            productLabel: currentLabelByAnchor[reference.assetId],
          ),
        );
        continue;
      }
      if (reference.role != QuickReferenceRole.productDetail) {
        assignments.add(
          QuickReferenceAssignment(
            assetId: reference.assetId,
            imageNumber: reference.imageNumber,
            role: reference.role,
            normalizedDescription: _rewriteProductMarkers(
              reference.description,
              previousAnchorByLabel: previousAnchorByLabel,
              currentLabelByAnchor: currentLabelByAnchor,
              warnings: warnings,
            ),
            evidence: QuickReferenceEvidence.unresolved,
            confidence: 1,
          ),
        );
        continue;
      }

      final resolution = _resolveDetail(
        reference: reference,
        masters: masters,
        masterByAssetId: masterByAssetId,
        masterByImageNumber: masterByImageNumber,
        currentAnchorByLabel: currentAnchorByLabel,
        previousAnchorByLabel: previousAnchorByLabel,
      );
      needsVisualPlanning = needsVisualPlanning || resolution.needsVisual;
      if (resolution.warning.isNotEmpty) warnings.add(resolution.warning);
      final anchorId = resolution.master?.assetId;
      final label = anchorId == null ? null : currentLabelByAnchor[anchorId];
      var normalizedDescription = _rewriteProductMarkers(
        reference.description,
        previousAnchorByLabel: previousAnchorByLabel,
        currentLabelByAnchor: currentLabelByAnchor,
        warnings: warnings,
      );
      normalizedDescription = _normalizeRecognizedProductPhrase(
        normalizedDescription,
        label,
      );
      assignments.add(
        QuickReferenceAssignment(
          assetId: reference.assetId,
          imageNumber: reference.imageNumber,
          role: reference.role,
          normalizedDescription: normalizedDescription,
          evidence: resolution.evidence,
          confidence: resolution.confidence,
          groupAnchorAssetId: anchorId,
          productLabel: label,
          warning: resolution.warning,
        ),
      );
    }

    final detailAssignments = assignments.where(
      (assignment) => assignment.role == QuickReferenceRole.productDetail,
    );
    if (masters.length >= 2 && detailAssignments.isNotEmpty) {
      needsVisualPlanning = true;
    }
    if (_containsReferenceMarker(supplement) ||
        ordered.any(
          (reference) => _containsReferenceMarker(reference.description),
        )) {
      needsVisualPlanning = true;
    }

    final normalizedReferences = [
      for (final reference in ordered)
        reference.copyWith(
          description: assignments
              .firstWhere(
                (assignment) => assignment.assetId == reference.assetId,
              )
              .normalizedDescription,
          groupAnchorAssetId: assignments
              .firstWhere(
                (assignment) => assignment.assetId == reference.assetId,
              )
              .groupAnchorAssetId,
          clearGroupAnchorAssetId:
              assignments
                  .firstWhere(
                    (assignment) => assignment.assetId == reference.assetId,
                  )
                  .groupAnchorAssetId ==
              null,
          groupConfidence: assignments
              .firstWhere(
                (assignment) => assignment.assetId == reference.assetId,
              )
              .confidence,
          groupWarning: assignments
              .firstWhere(
                (assignment) => assignment.assetId == reference.assetId,
              )
              .warning,
        ),
    ];

    final groups = <QuickProductGroup>[];
    for (final master in masters) {
      final details = [
        for (final assignment in detailAssignments)
          if (assignment.groupAnchorAssetId == master.assetId) assignment,
      ];
      groups.add(
        QuickProductGroup(
          label: currentLabelByAnchor[master.assetId]!,
          anchorAssetId: master.assetId,
          masterImageNumber: master.imageNumber,
          detailAssetIds: [for (final detail in details) detail.assetId],
          detailImageNumbers: [
            for (final detail in details) detail.imageNumber,
          ],
        ),
      );
    }

    return QuickReplicationPlan(
      references: List.unmodifiable(normalizedReferences),
      productGroups: List.unmodifiable(groups),
      assignments: List.unmodifiable(assignments),
      normalizedSupplement: _rewriteProductMarkers(
        supplement,
        previousAnchorByLabel: previousAnchorByLabel,
        currentLabelByAnchor: currentLabelByAnchor,
        warnings: warnings,
      ),
      needsVisualPlanning: needsVisualPlanning,
      warnings: List.unmodifiable(warnings.toSet()),
    );
  }

  static String productLabelForIndex(int index) {
    if (index < 0) throw RangeError.value(index, 'index');
    var value = index + 1;
    final result = StringBuffer();
    while (value > 0) {
      value--;
      result.writeCharCode(65 + value % 26);
      value ~/= 26;
    }
    return result.toString().split('').reversed.join();
  }

  static void _validateUniqueInputs(
    List<QuickReplicationReference> references,
  ) {
    final assetIds = <String>{};
    final imageNumbers = <int>{};
    for (final reference in references) {
      if (reference.assetId.trim().isEmpty) {
        throw ArgumentError('快速引用资产 ID 不能为空');
      }
      if (reference.imageNumber < 2) {
        throw ArgumentError('快速引用图片编号必须从图2开始');
      }
      if (!assetIds.add(reference.assetId)) {
        throw ArgumentError('快速引用资产 ID 重复：${reference.assetId}');
      }
      if (!imageNumbers.add(reference.imageNumber)) {
        throw ArgumentError('快速引用图片编号重复：图${reference.imageNumber}');
      }
    }
  }

  static _DetailResolution _resolveDetail({
    required QuickReplicationReference reference,
    required List<QuickReplicationReference> masters,
    required Map<String, QuickReplicationReference> masterByAssetId,
    required Map<int, QuickReplicationReference> masterByImageNumber,
    required Map<String, String> currentAnchorByLabel,
    required Map<String, String> previousAnchorByLabel,
  }) {
    if (masters.isEmpty) {
      return const _DetailResolution(
        evidence: QuickReferenceEvidence.unresolved,
        confidence: 0,
        warning: '存在产品细节图，但当前没有产品主图，需补充产品主图或由视觉规划确认。',
        needsVisual: true,
      );
    }

    final description = reference.description.trim();
    final imageMatch = RegExp(r'图\s*(\d+)').firstMatch(description);
    if (imageMatch != null) {
      final imageNumber = int.tryParse(imageMatch.group(1)!);
      final master = masterByImageNumber[imageNumber];
      if (master != null) {
        return _resolved(
          reference,
          master,
          QuickReferenceEvidence.explicitImageNumber,
          1,
        );
      }
      return _fallbackWithWarning(
        reference: reference,
        masters: masters,
        warning:
            '图${reference.imageNumber}的描述引用图$imageNumber，但该图片不是当前产品主图；已按本地顺序临时归组。',
      );
    }

    final label = _explicitProductLabel(description);
    if (label != null) {
      final anchorId =
          previousAnchorByLabel[label] ?? currentAnchorByLabel[label];
      final master = anchorId == null ? null : masterByAssetId[anchorId];
      if (master != null) {
        return _resolved(
          reference,
          master,
          QuickReferenceEvidence.explicitProductLabel,
          1,
        );
      }
      return _fallbackWithWarning(
        reference: reference,
        masters: masters,
        warning:
            '图${reference.imageNumber}的描述引用产品$label，但该产品主图已不存在或已改类型；保留原文并按本地顺序临时归组。',
      );
    }

    final ordinalIndex = _explicitProductOrdinal(description);
    if (ordinalIndex != null) {
      if (ordinalIndex >= 0 && ordinalIndex < masters.length) {
        return _resolved(
          reference,
          masters[ordinalIndex],
          QuickReferenceEvidence.explicitProductLabel,
          1,
        );
      }
      return _fallbackWithWarning(
        reference: reference,
        masters: masters,
        warning: '图${reference.imageNumber}引用的产品序号超出当前产品数量；已按本地顺序临时归组。',
      );
    }

    final named = [
      for (final master in masters)
        if (_descriptionNamesMaster(description, master)) master,
    ];
    if (named.length == 1) {
      return _resolved(
        reference,
        named.single,
        QuickReferenceEvidence.productName,
        .9,
      );
    }
    if (named.length > 1) {
      return _fallbackWithWarning(
        reference: reference,
        masters: masters,
        warning: '图${reference.imageNumber}的描述同时匹配多个产品名称；已按本地顺序临时归组，等待视觉规划确认。',
      );
    }
    if (masters.every((master) => master.order > reference.order)) {
      return const _DetailResolution(
        evidence: QuickReferenceEvidence.unresolved,
        confidence: 0,
        warning: '产品细节图位于所有产品主图之前，需由视觉规划确认归属。',
        needsVisual: true,
      );
    }
    if (masters.length == 1) {
      return _resolved(
        reference,
        masters.single,
        QuickReferenceEvidence.singleProduct,
        .98,
      );
    }
    return _fallbackBySequence(reference: reference, masters: masters);
  }

  static _DetailResolution _resolved(
    QuickReplicationReference reference,
    QuickReplicationReference master,
    QuickReferenceEvidence evidence,
    double confidence,
  ) {
    final persistedAnchor = reference.groupAnchorAssetId;
    final conflict =
        persistedAnchor != null && persistedAnchor != master.assetId;
    return _DetailResolution(
      master: master,
      evidence: evidence,
      confidence: confidence,
      warning: conflict
          ? '图${reference.imageNumber}的文字证据优先于原自动归组，已改归当前明确指定的产品。'
          : '',
      needsVisual: conflict,
    );
  }

  static _DetailResolution _fallbackWithWarning({
    required QuickReplicationReference reference,
    required List<QuickReplicationReference> masters,
    required String warning,
  }) {
    final fallback = _fallbackBySequence(
      reference: reference,
      masters: masters,
    );
    return _DetailResolution(
      master: fallback.master,
      evidence: fallback.evidence,
      confidence: fallback.confidence,
      warning: warning,
      needsVisual: true,
    );
  }

  static _DetailResolution _fallbackBySequence({
    required QuickReplicationReference reference,
    required List<QuickReplicationReference> masters,
  }) {
    QuickReplicationReference? nearestLeft;
    for (final master in masters) {
      if (master.order < reference.order) nearestLeft = master;
    }
    if (nearestLeft != null) {
      return _DetailResolution(
        master: nearestLeft,
        evidence: QuickReferenceEvidence.leftSequence,
        confidence: .7,
        needsVisual: masters.length > 1,
      );
    }
    return const _DetailResolution(
      evidence: QuickReferenceEvidence.unresolved,
      confidence: 0,
      warning: '产品细节图位于所有产品主图之前，需由视觉规划确认归属。',
      needsVisual: true,
    );
  }

  static bool _descriptionNamesMaster(
    String description,
    QuickReplicationReference master,
  ) {
    if (description.isEmpty) return false;
    final candidates = [
      master.name.trim(),
      master.description.trim(),
    ].where((value) => value.length >= 2);
    return candidates.any(description.contains);
  }

  static String? _explicitProductLabel(String text) {
    final match = RegExp(
      r'(?:产品\s*([A-Za-z]+)|\b([A-Za-z]+)\s*产品)',
      caseSensitive: false,
    ).firstMatch(text);
    return (match?.group(1) ?? match?.group(2))?.toUpperCase();
  }

  static int? _explicitProductOrdinal(String text) {
    const ordinals = <String, int>{
      '第一件产品': 0,
      '第一个产品': 0,
      '第二件产品': 1,
      '第二个产品': 1,
      '第三件产品': 2,
      '第三个产品': 2,
      '第四件产品': 3,
      '第四个产品': 3,
    };
    for (final entry in ordinals.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return null;
  }

  static String _normalizeRecognizedProductPhrase(String text, String? label) {
    if (label == null || text.isEmpty) return text;
    return text.replaceAll(RegExp(r'第[一二三四](?:件|个)产品'), '产品$label');
  }

  static bool _containsReferenceMarker(String text) =>
      RegExp(r'图\s*\d+').hasMatch(text) ||
      _explicitProductLabel(text) != null ||
      _explicitProductOrdinal(text) != null;

  static String _rewriteProductMarkers(
    String text, {
    required Map<String, String> previousAnchorByLabel,
    required Map<String, String> currentLabelByAnchor,
    required List<String> warnings,
  }) {
    if (text.isEmpty || previousAnchorByLabel.isEmpty) return text;
    var result = text;
    final placeholders = <String, String>{};
    var placeholderIndex = 0;
    result = result.replaceAllMapped(
      RegExp(r'(?:产品\s*([A-Za-z]+)|\b([A-Za-z]+)\s*产品)', caseSensitive: false),
      (match) {
        final oldLabel = (match.group(1) ?? match.group(2))!.toUpperCase();
        final anchorId = previousAnchorByLabel[oldLabel];
        if (anchorId == null) return match.group(0)!;
        final newLabel = currentLabelByAnchor[anchorId];
        if (newLabel == null) {
          warnings.add('描述中的产品$oldLabel所对应主图已删除或改类型，已保留原文并等待重新规划。');
          return match.group(0)!;
        }
        final placeholder = '__QUICK_PRODUCT_${placeholderIndex++}__';
        placeholders[placeholder] = '产品$newLabel';
        return placeholder;
      },
    );
    for (final entry in placeholders.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }
}

class _DetailResolution {
  const _DetailResolution({
    this.master,
    required this.evidence,
    required this.confidence,
    this.warning = '',
    this.needsVisual = false,
  });

  final QuickReplicationReference? master;
  final QuickReferenceEvidence evidence;
  final double confidence;
  final String warning;
  final bool needsVisual;
}
