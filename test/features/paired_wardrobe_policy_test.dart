import 'package:filmstoryboard/features/replicate/domain/paired_wardrobe_policy.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/replicate/domain/lightweight_replication_prompt_compiler.dart';
import 'package:filmstoryboard/features/replicate/domain/quick_replication_reference.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:test/test.dart';

void main() {
  test('人数决定成对槽位，旧鞋包不会扩增格子且规范化可重复读取', () {
    for (final count in [0, 1, 2, 5, 20]) {
      final result = PairedWardrobePolicy.subjects(const [
        ReplicateDetectedSubject(
          id: 'product:9',
          type: ReplicateSubjectType.product,
          label: '鞋包',
          slotIndex: 9,
          decision: ReplicateSubjectDecision.remove,
        ),
      ], count);
      expect(result, hasLength(count * 2));
      expect(
        result.where((s) => s.type == ReplicateSubjectType.product),
        hasLength(count),
      );
      expect(
        PairedWardrobePolicy.subjects(result, count).map((s) => s.toJson()),
        result.map((s) => s.toJson()),
      );
    }
  });

  test('只有模特B与服装B也保留B编号，图片重排不改变人物归属', () {
    final plan = const QuickReplicationLocalPlanner().plan(
      references: const [
        QuickReplicationReference(
          assetId: 'wardrobe-b',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
          name: '长裤',
        ),
        QuickReplicationReference(
          assetId: 'model-b',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.model,
          name: '模特照片',
        ),
        QuickReplicationReference(
          assetId: 'scene',
          imageNumber: 4,
          order: 3,
          role: QuickReferenceRole.scene,
          name: '花园',
        ),
      ],
    );
    final prompt = const LightweightReplicationPromptCompiler().compilePlan(
      instruction: '保持双人动作',
      plan: plan,
      slotLabelsByAssetId: const {
        'wardrobe-b': '产品B',
        'model-b': '模特B',
        'scene': '场景',
      },
    );
    expect(prompt, contains('模特B只使用图片3'));
    expect(prompt, contains('服装参考B以图片2为唯一服装来源，只穿在模特B身上'));
    expect(prompt, isNot(contains('模特A只以图片3')));
    expect(prompt, contains('图片4是新场景与背景的唯一权威来源'));
    expect(prompt, contains('上装只替换上身'));
    expect(prompt, contains('下装只替换裤装或裙装'));
    expect(prompt, contains('明确的套装替换成套衣物'));
  });
}
