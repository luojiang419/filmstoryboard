import 'package:filmstoryboard/features/replicate/domain/lightweight_replication_prompt_compiler.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/replicate/domain/quick_replication_reference.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:test/test.dart';

void main() {
  test('按图片编号生成紧凑自然语言复刻提示词', () {
    final prompt = const LightweightReplicationPromptCompiler().compile(
      instruction: '让金发模特在露台长椅旁自然坐下',
      references: const [
        LightweightReplicationReference(
          imageNumber: 2,
          type: ReplicateAssetType.scene,
          name: '露台背景',
          slotLabel: '场景',
        ),
        LightweightReplicationReference(
          imageNumber: 3,
          type: ReplicateAssetType.character,
          name: '金发模特',
          slotLabel: '模特A',
        ),
        LightweightReplicationReference(
          imageNumber: 4,
          type: ReplicateAssetType.product,
          name: '蓝色长裤',
          slotLabel: '产品A',
        ),
      ],
    );

    expect(prompt, startsWith('让金发模特在露台长椅旁自然坐下'));
    expect(prompt, contains('使用图片2中的“露台背景”作为背景环境'));
    expect(prompt, contains('只使用图片3中的“金发模特”的身份、脸部、发型、肤色和体型'));
    expect(prompt, contains('【组合路由】M1-P1-S1'));
    expect(prompt, contains('穿着或使用图片4中的“蓝色长裤”（产品A）'));
    expect(prompt, contains('图片2是新场景与背景的唯一权威来源'));
    expect(prompt, contains('必须完整替换图片1的原背景'));
    expect(prompt, contains('不得继承图片1的场景、背景或环境光'));
    expect(prompt, contains('环境光、色温和阴影以场景参考图为准'));
    expect(prompt.length, lessThan(900));
    expect(prompt, isNot(contains('确定性精准复刻协议')));
    expect(prompt, isNot(contains('高精度深度图')));
  });

  test('拒绝空说明和非图片参考', () {
    expect(
      () => const LightweightReplicationPromptCompiler().compile(
        instruction: '   ',
        references: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => const LightweightReplicationPromptCompiler().compile(
        instruction: '生成画面',
        references: const [
          LightweightReplicationReference(
            imageNumber: 2,
            type: ReplicateAssetType.video,
            name: '视频',
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('结构化计划按固定职责顺序编译且产品主图与细节不串组', () {
    final plan = const QuickReplicationLocalPlanner().plan(
      references: const [
        QuickReplicationReference(
          assetId: 'scene',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.scene,
          description: '夜间城市露台',
        ),
        QuickReplicationReference(
          assetId: 'model',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.model,
        ),
        QuickReplicationReference(
          assetId: 'product-a',
          imageNumber: 4,
          order: 3,
          role: QuickReferenceRole.product,
          description: '黑色阔腿裤',
        ),
        QuickReplicationReference(
          assetId: 'detail-a',
          imageNumber: 5,
          order: 4,
          role: QuickReferenceRole.productDetail,
          description: '产品A的腰头和口袋',
        ),
        QuickReplicationReference(
          assetId: 'product-b',
          imageNumber: 6,
          order: 5,
          role: QuickReferenceRole.product,
          description: '白色运动鞋',
        ),
        QuickReplicationReference(
          assetId: 'detail-b',
          imageNumber: 7,
          order: 6,
          role: QuickReferenceRole.productDetail,
          description: '产品B鞋底',
        ),
        QuickReplicationReference(
          assetId: 'accessory',
          imageNumber: 8,
          order: 7,
          role: QuickReferenceRole.accessory,
        ),
      ],
      supplement: '图3模特穿产品A和产品B，佩戴图8配饰',
    );

    final prompt = const LightweightReplicationPromptCompiler().compilePlan(
      instruction: '模特在露台完成全身产品展示',
      plan: plan,
    );

    expect(prompt, startsWith('只输出一张完成的分镜图'));
    expect(
      prompt.indexOf('图片2是新场景与背景的唯一权威来源'),
      lessThan(prompt.indexOf('模特A只以图片3')),
    );
    expect(prompt, contains('禁止继承图片1中的建筑、家具、道路、地面、植物、天空'));
    expect(prompt, contains('环境光、色温、阴影与空间氛围以场景参考图为准'));
    expect(prompt, contains('产品A以图片4为主图'));
    expect(prompt, contains('图片5只补充产品A'));
    expect(prompt, contains('产品B以图片6为主图'));
    expect(prompt, contains('模特A与产品A一一对应'));
    expect(prompt, contains('不继承该图的服装、姿势和背景'));
    expect(prompt, contains('图片7只补充产品B'));
    expect(prompt, contains('图片5说明：产品A的腰头和口袋'));
    expect(prompt, contains('补充关系：图3模特穿产品A和产品B，佩戴图8配饰'));
    expect(prompt.indexOf('产品A以图片4'), lessThan(prompt.indexOf('图片8作为配饰')));
    expect(prompt, isNot(contains('高精度深度图')));
  });

  test('产品细节空描述时使用通用局部证据模板', () {
    final plan = const QuickReplicationLocalPlanner().plan(
      references: const [
        QuickReplicationReference(
          assetId: 'master',
          imageNumber: 2,
          order: 1,
          role: QuickReferenceRole.product,
        ),
        QuickReplicationReference(
          assetId: 'detail',
          imageNumber: 3,
          order: 2,
          role: QuickReferenceRole.productDetail,
        ),
      ],
    );
    final prompt = const LightweightReplicationPromptCompiler().compilePlan(
      instruction: '生成商品展示画面',
      plan: plan,
    );

    expect(prompt, contains('图片3补充产品A可见的局部结构、材质、接缝、表面处理和工艺细节'));
    expect(prompt, contains('整体形态以图片2为准'));
    expect(prompt, contains('与图片1一致的光照方向和空间关系'));
    expect(prompt, isNot(contains('必须完整替换图片1的原背景')));
  });

  test('拒绝图片编号不连续的结构化计划', () {
    const reference = QuickReplicationReference(
      assetId: 'scene',
      imageNumber: 3,
      order: 1,
      role: QuickReferenceRole.scene,
    );
    const assignment = QuickReferenceAssignment(
      assetId: 'scene',
      imageNumber: 3,
      role: QuickReferenceRole.scene,
      normalizedDescription: '',
      evidence: QuickReferenceEvidence.unresolved,
      confidence: 1,
    );
    expect(
      () => const LightweightReplicationPromptCompiler().compilePlan(
        instruction: '生成画面',
        plan: const QuickReplicationPlan(
          references: [reference],
          productGroups: [],
          assignments: [assignment],
          normalizedSupplement: '',
          needsVisualPlanning: false,
        ),
      ),
      throwsArgumentError,
    );
  });
}
