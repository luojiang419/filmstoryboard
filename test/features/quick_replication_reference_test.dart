import 'package:filmstoryboard/features/replicate/domain/quick_replication_reference.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:test/test.dart';

void main() {
  const planner = QuickReplicationLocalPlanner();

  test('按快速顺序派生产品A/B/C并以主图资产ID作为稳定锚点', () {
    final plan = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'detail-a',
          imageNumber: 5,
          order: 4,
          role: QuickReferenceRole.productDetail,
        ),
        QuickReplicationReference(
          assetId: 'product-b',
          imageNumber: 7,
          order: 6,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'product-a',
          imageNumber: 4,
          order: 3,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'product-c',
          imageNumber: 9,
          order: 8,
          role: QuickReferenceRole.product,
        ),
      ],
    );

    expect(
      plan.productGroups.map((group) => group.label),
      orderedEquals(['A', 'B', 'C']),
    );
    expect(plan.productGroups[0].anchorAssetId, 'product-a');
    expect(plan.productGroups[0].detailAssetIds, ['detail-a']);
    expect(plan.assignmentFor('detail-a')!.groupAnchorAssetId, 'product-a');
    expect(
      plan.assignmentFor('detail-a')!.evidence,
      QuickReferenceEvidence.leftSequence,
    );
  });

  test('单产品细节无需视觉模型即可直接归入产品A', () {
    final plan = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'master',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'detail-1',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.productDetail,
        ),
        QuickReplicationReference(
          assetId: 'detail-2',
          imageNumber: 4,
          order: 3,
          role: QuickReferenceRole.productDetail,
        ),
      ],
    );

    expect(plan.needsVisualPlanning, isFalse);
    expect(plan.productGroups.single.detailImageNumbers, [3, 4]);
    expect(
      plan.assignmentFor('detail-2')!.evidence,
      QuickReferenceEvidence.singleProduct,
    );
    expect(plan.assignmentFor('detail-2')!.confidence, .98);
  });

  test('产品A/B、A产品、图N和产品名称均作为强归组证据', () {
    final plan = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'black-pants',
          imageNumber: 4,
          order: 1,
          role: QuickReferenceRole.product,
          name: '黑色裤子',
        ),
        QuickReplicationReference(
          assetId: 'white-shoes',
          imageNumber: 7,
          order: 2,
          role: QuickReferenceRole.product,
          name: '白色鞋子',
        ),
        QuickReplicationReference(
          assetId: 'by-image',
          imageNumber: 8,
          order: 3,
          role: QuickReferenceRole.productDetail,
          description: '图4的背面细节',
        ),
        QuickReplicationReference(
          assetId: 'by-label',
          imageNumber: 9,
          order: 4,
          role: QuickReferenceRole.productDetail,
          description: '产品B鞋底',
        ),
        QuickReplicationReference(
          assetId: 'by-reversed-label',
          imageNumber: 10,
          order: 5,
          role: QuickReferenceRole.productDetail,
          description: 'A产品的腰头',
        ),
        QuickReplicationReference(
          assetId: 'by-name',
          imageNumber: 11,
          order: 6,
          role: QuickReferenceRole.productDetail,
          description: '黑色裤子的口袋',
        ),
      ],
    );

    expect(plan.assignmentFor('by-image')!.groupAnchorAssetId, 'black-pants');
    expect(plan.assignmentFor('by-label')!.groupAnchorAssetId, 'white-shoes');
    expect(
      plan.assignmentFor('by-reversed-label')!.groupAnchorAssetId,
      'black-pants',
    );
    expect(plan.assignmentFor('by-name')!.groupAnchorAssetId, 'black-pants');
    expect(
      plan.assignmentFor('by-name')!.evidence,
      QuickReferenceEvidence.productName,
    );
  });

  test('删除前一产品后通过两阶段占位符安全将产品B改写为产品A', () {
    final previous = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'removed',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'survivor',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'detail',
          imageNumber: 4,
          order: 3,
          role: QuickReferenceRole.productDetail,
          description: '产品B正面，避免把普通字母A改掉',
        ),
      ],
      supplement: '模特手持产品B，保留型号A字样',
    );
    final reordered = planner.plan(
      previousPlan: previous,
      references: const [
        QuickReplicationReference(
          assetId: 'survivor',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'detail',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.productDetail,
          description: '产品B正面，避免把普通字母A改掉',
          groupAnchorAssetId: 'survivor',
        ),
      ],
      supplement: '模特手持产品B，保留型号A字样',
    );

    expect(
      reordered.assignmentFor('detail')!.normalizedDescription,
      '产品A正面，避免把普通字母A改掉',
    );
    expect(reordered.normalizedSupplement, '模特手持产品A，保留型号A字样');
    expect(reordered.assignmentFor('detail')!.groupAnchorAssetId, 'survivor');
  });

  test('主图删除或改类型导致锚点失效时保留原文并返回非阻塞警告', () {
    final previous = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'product-a',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'product-b',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.product,
        ),
      ],
    );
    final changed = planner.plan(
      previousPlan: previous,
      references: const [
        QuickReplicationReference(
          assetId: 'product-a',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'detail',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.productDetail,
          description: '产品B的鞋底',
          groupAnchorAssetId: 'product-b',
        ),
      ],
    );

    expect(changed.assignmentFor('detail')!.normalizedDescription, '产品B的鞋底');
    expect(changed.assignmentFor('detail')!.groupAnchorAssetId, 'product-a');
    expect(changed.needsVisualPlanning, isTrue);
    expect(changed.warnings.join('\n'), contains('已不存在或已改类型'));
  });

  test('细节位于全部产品之前时不强行归组并请求视觉规划', () {
    final plan = planner.plan(
      references: const [
        QuickReplicationReference(
          assetId: 'detail',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.productDetail,
        ),
        QuickReplicationReference(
          assetId: 'master',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.product,
        ),
      ],
    );

    expect(plan.assignmentFor('detail')!.groupAnchorAssetId, isNull);
    expect(
      plan.assignmentFor('detail')!.evidence,
      QuickReferenceEvidence.unresolved,
    );
    expect(plan.needsVisualPlanning, isTrue);
    expect(plan.assignmentFor('detail')!.warning, contains('位于所有产品主图之前'));
  });
}
