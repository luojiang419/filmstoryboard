class DeterministicReplacementPromptScenario {
  const DeterministicReplacementPromptScenario({
    required this.hasModel,
    required this.hasProduct,
    required this.hasScene,
    required this.title,
    required this.instruction,
  });

  final bool hasModel;
  final bool hasProduct;
  final bool hasScene;
  final String title;
  final String instruction;

  String get id =>
      'M${hasModel ? 1 : 0}-P${hasProduct ? 1 : 0}-S${hasScene ? 1 : 0}';

  String compileReviewTemplate({bool hasDepthMap = true}) => <String>[
    '【确定性一键替换协议】',
    '【组合路由】$id · $title：$instruction',
    '图片1是原视频帧，也是构图、机位、透视、主体位置、姿势、接触、遮挡和所有空资产槽外观的唯一来源。',
    if (hasDepthMap)
      '图片2是原帧配准深度图，只锁定人体前后关系、动作几何、遮挡边界和可辨认褶皱起伏，不提供身份、产品、材质、颜色或场景外观。',
    if (hasModel) '模特资产只提供对应人物槽位的身份、脸部、发型、肤色和体型；不得带入素材图的服装、姿势、背景、机位或调色。',
    if (hasProduct) '产品资产只提供对应产品槽位的轮廓、结构、颜色、材质和细节；按首次原帧分析保存的穿着、持拿、接触或独立摆放关系执行。',
    if (hasScene) '场景资产只提供环境外观、材质和环境光；主体布局、动作、接触、遮挡、机位和透视继续服从图片1。',
    '【默认保留】任何没有绑定资产的对应格子都完整保留图片1内容；不得擅自替换、删除、美化或重绘。',
    '【槽位规则】模特A只对应人物A，产品A只对应产品A；B、C及后续槽位依次类推。不得合并、互换、串穿或混搭。',
    '【输出规则】只输出一张完成的连续分镜画面，不输出拼图、对照图、参考图、深度图、界面或说明文字。',
  ].join('\n');
}

class DeterministicReplacementPromptCatalog {
  const DeterministicReplacementPromptCatalog._();

  static const scenarios = <DeterministicReplacementPromptScenario>[
    DeterministicReplacementPromptScenario(
      hasModel: false,
      hasProduct: false,
      hasScene: false,
      title: '全部保留',
      instruction: '没有绑定替换资产的主体完整沿用图片1；只执行处理计划中显式要求的移除。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: true,
      hasProduct: false,
      hasScene: false,
      title: '仅替换模特',
      instruction: '只替换已绑定人物槽位的身份、脸部、发型、肤色和体型；原服装、产品、动作与场景保持图片1不变。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: false,
      hasProduct: true,
      hasScene: false,
      title: '仅替换产品',
      instruction: '保留图片1人物身份与场景；已绑定产品按原分析的穿着、持拿、接触或独立摆放关系替换对应原产品。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: false,
      hasProduct: false,
      hasScene: true,
      title: '仅替换场景',
      instruction: '保留图片1全部人物、服装与产品，只用场景资产重建环境外观和环境光。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: true,
      hasProduct: true,
      hasScene: false,
      title: '模特与产品',
      instruction: '已绑定模特按同槽位穿着、持拿或使用已绑定产品；动作、接触、遮挡与原场景保持图片1不变。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: true,
      hasProduct: false,
      hasScene: true,
      title: '模特与场景',
      instruction: '替换已绑定人物身份并置入新场景；原服装和原产品保持图片1不变。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: false,
      hasProduct: true,
      hasScene: true,
      title: '产品与场景',
      instruction: '保留图片1人物身份，使其按原关系穿着、持拿或使用已绑定产品，并置入新场景。',
    ),
    DeterministicReplacementPromptScenario(
      hasModel: true,
      hasProduct: true,
      hasScene: true,
      title: '模特、产品与场景',
      instruction: '已绑定模特按同槽位穿着、持拿或使用已绑定产品，保持图片1动作与构图并自然置入新场景。',
    ),
  ];

  static DeterministicReplacementPromptScenario resolve({
    required bool hasModel,
    required bool hasProduct,
    required bool hasScene,
  }) => scenarios.singleWhere(
    (scenario) =>
        scenario.hasModel == hasModel &&
        scenario.hasProduct == hasProduct &&
        scenario.hasScene == hasScene,
  );
}
