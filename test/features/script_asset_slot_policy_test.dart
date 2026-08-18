import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/script_asset_slot_policy.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 14);

  ScriptShot shot({String content = '', String visual = ''}) => ScriptShot(
    id: 'shot-1',
    scriptId: 'script-1',
    shotNumber: 1,
    durationSeconds: 5,
    framePath: '',
    visual: visual,
    content: content,
    shotSize: '',
    cameraMovement: '',
    cameraNotes: '',
    scene: '',
    productCode: '',
    productStyling: '',
    dialogue: '',
    sound: '',
    prompt: '',
    status: ProcessingStatus.completed,
    updatedAt: now,
  );

  ScriptShotAnalysisRecord analysis(String people) => ScriptShotAnalysisRecord(
    id: 'analysis-1',
    shotId: 'shot-1',
    model: 'test-model',
    status: ProcessingStatus.completed,
    fieldSources: const {},
    fieldConfidence: const {},
    promptContext: ScriptShotPromptContext(subject: {'people': people}),
    promptContextSchemaVersion: ScriptShotPromptContext.currentSchemaVersion,
    rawResponse: '',
    errorMessage: '',
    createdAt: now,
    updatedAt: now,
  );

  test('结构化分析识别三位模特并创建对应预设槽位', () {
    final slots = ScriptAssetSlotPolicy.presetSlotsFor(
      shot: shot(content: '模特展示产品'),
      analysis: analysis('三位模特并排站立'),
    );

    expect(slots.map((item) => item.label(characterCount: 3)), [
      '模特A',
      '模特B',
      '模特C',
      '产品A',
      '产品细节A',
      '产品B',
      '产品细节B',
      '产品C',
      '产品细节C',
      '场景（可选）',
    ]);
    expect(slots.map((item) => item.sortOrder), [
      1000,
      1001,
      1002,
      2000,
      2001,
      2100,
      2200,
      2101,
      2201,
      3000,
    ]);
  });

  test('支持模特A与模特B标记并在未识别时保留单模特槽位', () {
    expect(
      ScriptAssetSlotPolicy.recognizedCharacterCount(
        shot: shot(content: '模特A与模特B一起展示产品'),
      ),
      2,
    );
    final fallback = ScriptAssetSlotPolicy.presetSlotsFor(
      shot: shot(content: '产品在桌面上旋转'),
    );
    expect(fallback.first.label(characterCount: 1), '模特');
    expect(fallback[1].label(characterCount: 1), '产品');
    expect(fallback[2].label(characterCount: 1), '产品细节');
    expect(fallback[3].label(characterCount: 1), '场景（可选）');
    expect(fallback, hasLength(4));
  });

  test('两位女孩或男孩按双人镜头创建从左到右的模特A和模特B槽位', () {
    for (final content in ['两位女孩迎风行走', '两名男孩并排站立', '两位女模特分别展示服装']) {
      final slots = ScriptAssetSlotPolicy.presetSlotsFor(
        shot: shot(content: content),
      );
      final characters = slots
          .where((slot) => slot.kind == ScriptAssetPresetSlotKind.character)
          .toList(growable: false);

      expect(characters, hasLength(2), reason: content);
      expect(characters.map((slot) => slot.label(characterCount: 2)), [
        '模特A',
        '模特B',
      ], reason: content);
    }
  });

  test('中文人数、多人与另一位表述都能安全兜底', () {
    expect(
      ScriptAssetSlotPolicy.recognizedCharacterCount(
        shot: shot(),
        analysis: analysis('十二名角色在舞台上'),
      ),
      12,
    );
    expect(
      ScriptAssetSlotPolicy.recognizedCharacterCount(
        shot: shot(),
        analysis: analysis('多人群像'),
      ),
      2,
    );
    expect(
      ScriptAssetSlotPolicy.recognizedCharacterCount(
        shot: shot(),
        analysis: analysis('一位女性与另一位男模特'),
      ),
      2,
    );
  });

  test('预设槽位顺序可反解且资产类型限制正确', () {
    final character = ScriptAssetSlotPolicy.presetSlotForSortOrder(1001)!;
    final productB = ScriptAssetSlotPolicy.presetSlotForSortOrder(2100)!;
    final detail = ScriptAssetSlotPolicy.presetSlotForSortOrder(2001)!;
    final detailB = ScriptAssetSlotPolicy.presetSlotForSortOrder(2200)!;
    final scene = ScriptAssetSlotPolicy.presetSlotForSortOrder(3000)!;

    expect(character.label(characterCount: 2), '模特B');
    expect(character.accepts(ReplicateAssetType.character), isTrue);
    expect(character.accepts(ReplicateAssetType.product), isFalse);
    expect(productB.label(characterCount: 2), '产品B');
    expect(productB.sortOrder, 2100);
    expect(productB.accepts(ReplicateAssetType.product), isTrue);
    expect(detail.label(characterCount: 1), '产品细节');
    expect(detail.accepts(ReplicateAssetType.product), isTrue);
    expect(detail.accepts(ReplicateAssetType.reference), isTrue);
    expect(detail.accepts(ReplicateAssetType.video), isFalse);
    expect(detailB.label(characterCount: 2), '产品细节B');
    expect(detailB.productIndex, 1);
    expect(scene.label(characterCount: 2), '场景（可选）');
    expect(scene.accepts(ReplicateAssetType.scene), isTrue);
    expect(scene.accepts(ReplicateAssetType.product), isFalse);
  });

  test('综合参考可按名称语义进入模特或产品槽位', () {
    final character = ScriptAssetPresetSlot.character(0);
    const product = ScriptAssetPresetSlot.product();

    expect(
      character.acceptsAsset(
        type: ReplicateAssetType.reference,
        name: '女模特',
        description: '人物全身综合参考',
      ),
      isTrue,
    );
    expect(
      product.acceptsAsset(
        type: ReplicateAssetType.reference,
        name: '女模特',
        description: '人物全身综合参考',
      ),
      isFalse,
    );
    expect(
      ScriptAssetSlotPolicy.effectiveTypeForSlotting(
        type: ReplicateAssetType.reference,
        name: '女模特',
        description: '人物全身综合参考',
      ),
      ReplicateAssetType.character,
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.reference,
        name: '女模特',
        description: '人物全身综合参考',
        occupiedSortOrders: const {},
      ),
      ScriptAssetSlotPolicy.characterSortOrderBase,
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.reference,
        name: '产品细节图',
        description: '瓶口材质与接缝特写',
        occupiedSortOrders: const {},
      ),
      ScriptAssetSlotPolicy.productDetailSortOrder,
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.reference,
        name: '棚拍场景图',
        description: '白色影棚环境参考',
        occupiedSortOrders: const {},
      ),
      ScriptAssetSlotPolicy.sceneSortOrder,
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.product,
        name: '产品细节图',
        description: '第二件产品的材质特写',
        occupiedSortOrders: const {
          ScriptAssetSlotPolicy.productDetailSortOrder,
        },
        maximumProductCount: 2,
      ),
      ScriptAssetSlotPolicy.productDetailSortOrderForIndex(1),
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.product,
        name: '红色连衣裙',
        description: '第二位模特的服装',
        occupiedSortOrders: const {ScriptAssetSlotPolicy.productSortOrder},
        maximumProductCount: 2,
      ),
      ScriptAssetSlotPolicy.productSortOrderForIndex(1),
    );
    expect(
      ScriptAssetSlotPolicy.preferredSortOrderForAsset(
        type: ReplicateAssetType.product,
        name: '红色连衣裙',
        description: '单模特服装',
        occupiedSortOrders: const {ScriptAssetSlotPolicy.productSortOrder},
      ),
      isNull,
      reason: '单模特的第二件普通产品不能误占产品细节槽',
    );
  });
}
