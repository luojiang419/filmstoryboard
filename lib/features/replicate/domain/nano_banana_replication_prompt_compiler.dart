import '../../storyboard/domain/image_generation_model_catalog.dart';
import 'nano_banana_asset_manifest.dart';
import 'replication_authority_policy.dart';

class NanoBananaProModelCapability {
  const NanoBananaProModelCapability._();

  static bool supports(String model) =>
      ImageGenerationCatalog.isNanoBananaProModel(model);
}

class NanoBananaReplicationPromptInput {
  const NanoBananaReplicationPromptInput({
    required this.model,
    required this.automaticPrompt,
    required this.manifest,
    this.userInstructions = '',
    this.structuralReferenceDescriptions = const [],
    this.productOverridesWardrobeAppearance = false,
  });

  final String model;
  final String automaticPrompt;
  final NanoBananaAssetManifest manifest;
  final String userInstructions;

  /// Structural-only images inserted after image 1, for example a DWPose map.
  final List<String> structuralReferenceDescriptions;
  final bool productOverridesWardrobeAppearance;
}

class NanoBananaReplicationPromptCompiler {
  const NanoBananaReplicationPromptCompiler();

  String compile(NanoBananaReplicationPromptInput input) {
    if (!NanoBananaProModelCapability.supports(input.model)) {
      throw ArgumentError.value(
        input.model,
        'model',
        '该模型不属于 Nano Banana Pro 家族',
      );
    }
    final automaticPrompt = input.automaticPrompt.trim();
    if (automaticPrompt.isEmpty) {
      throw ArgumentError.value(
        input.automaticPrompt,
        'automaticPrompt',
        '自动复刻提示词不能为空',
      );
    }
    if (input.manifest.entries.isEmpty ||
        input.manifest.entries.first.kind != NanoBananaAssetKind.sourceFrame) {
      throw ArgumentError('资产清单的图片1必须是原帧');
    }

    final context = ReplicationAuthorityContext(
      hasSceneAsset: input.manifest.entries.any(
        (entry) => entry.kind == NanoBananaAssetKind.scene,
      ),
      hasWearableProductAsset: input.productOverridesWardrobeAppearance,
      hasProductDetailAsset: input.manifest.entries.any(
        (entry) => entry.kind == NanoBananaAssetKind.productDetail,
      ),
    );
    final structuralCount = input.structuralReferenceDescriptions.length;
    final authorityLines = <String>[
      _authorityLine(input.manifest.entries.first, context, imageNumber: 1),
      for (var index = 0; index < structuralCount; index++)
        '图片${index + 2}是结构辅助图：${input.structuralReferenceDescriptions[index].trim()}。'
            '它只提供姿态或几何关系，不提供人物、产品、场景、材质、颜色或文字外观。',
      for (final entry in input.manifest.entries.skip(1))
        _authorityLine(
          entry,
          context,
          imageNumber: entry.imageNumber + structuralCount,
        ),
    ];
    final userInstructions = input.userInstructions.trim();
    final sceneRule = context.hasSceneAsset
        ? '已提供新场景资产：图片1中的原场景外观、装饰、材质、颜色与照明风格均未获授权；只保留图片1的空间布局、机位、透视、主体位置、遮挡和接触关系，并由场景资产提供环境外观。'
        : '未提供新场景资产：图片1可继续提供原环境外观与环境光色，但不得因此恢复任何未被主体处理计划明确保留的原人物、原产品、配饰或道具。';

    return <String>[
      '【Nano Banana Pro 确定性精准复刻协议】',
      '这是多图受控编辑与合成任务，不是自由创作、风格迁移、相似画面重做或素材平均融合。请按图片编号逐一使用来源，并把每张素材只用于其被授权的视觉属性。',
      '【逐图角色与唯一权威来源】',
      ...authorityLines,
      sceneRule,
      '【编辑方法】以图片1为编辑底图，按下方正文逐项执行“保留主体、替换主体、移除主体、保留白名单元素”；只改动被明确指定的实体。保留主体完整沿用图片1中的对应外观；移除后按相邻透视、纹理、材质、遮挡与光影自然补全；新增或替换实体必须匹配图片1的尺度、位置、姿态、接触、镜头、景深和光照。',
      '同一逻辑资产的多张视图只是互补证据：主视图锁定整体身份、轮廓和比例，细节视图只补充局部结构与材质。不得生成混合身份、混合产品、额外副本，也不得把素材图自身的背景、版式、机位、姿势、光照或调色带入成图。',
      '【确定性复刻正文】',
      automaticPrompt,
      if (userInstructions.isNotEmpty) ...[
        '【用户补充说明：确定性合并】$userInstructions',
        '冲突处理：用户补充说明可覆盖镜头脚本中的普通描述，但不得改变逐图权威来源或取消“原帧主体处理计划”；只有计划中明确标记保留的原人物或原产品才能沿用，不得把其他主体或未勾选元素改为保留，也不得恢复未授权原场景。只有补充说明明确给出需要逐字出现的具体文本时，才允许该段指定文本。',
      ],
      '【提交前内部核对】逐项确认：图片编号与资产角色一致；所有保留、替换和移除均已完成；人物与产品未串槽；图片1左右方向未镜像；新实体已匹配原构图、透视、遮挡、接触和光照；未获主体处理计划授权的原人物、原产品、原场景、未勾选配饰/道具及其残影均未泄漏。不要输出核对过程。',
      '【最终输出复核】若用户未在“复刻补充说明”中明确给出需要逐字出现的具体文本，成图必须完全不含任何文字、数字、字母、符号组合、字幕、水印、Logo、商标、台标、角标、二维码或条形码；若用户已明确给出，只允许该段指定文本，其他文字与标识一律禁止。',
      '最终只输出一张完成的复刻分镜画面，不要输出解释、标题、镜号、界面或核对文本。',
    ].join('\n');
  }

  static String _authorityLine(
    NanoBananaAssetEntry entry,
    ReplicationAuthorityContext context, {
    required int imageNumber,
  }) {
    final scopes = ReplicationAuthorityPolicy.scopesFor(
      entry.authoritySource,
      context: context,
    ).map(_scopeLabel).where((label) => label.isNotEmpty).join('、');
    final slot = entry.slotIndex == null
        ? ''
        : '，槽位${_slotLabel(entry.slotIndex!)}';
    final view = entry.viewOrder == 0 ? '主视图' : '补充视图${entry.viewOrder}';
    return switch (entry.kind) {
      NanoBananaAssetKind.sourceFrame =>
        '图片$imageNumber是原帧编辑底图，也是以下属性的唯一权威来源：$scopes。原帧主体处理计划中明确标记保留的主体可完整沿用其对应外观；其他原人物身份/外观、原产品外观不得继承，且未勾选配饰或道具没有任何继承权限。',
      NanoBananaAssetKind.model =>
        '图片$imageNumber是模特资产$slot（$view），是以下属性的唯一权威来源：$scopes。忽略其背景、构图、姿态、光照与调色。',
      NanoBananaAssetKind.product =>
        '图片$imageNumber是产品资产$slot（$view），是以下属性的唯一权威来源：$scopes。忽略其背景、摆放、机位、光照、包装文字与标识。',
      NanoBananaAssetKind.productDetail =>
        '图片$imageNumber是逐产品细节资产$slot（$view），是以下属性的唯一权威来源：$scopes。只补充对应产品的局部证据，不改变主产品整体轮廓与比例。',
      NanoBananaAssetKind.scene =>
        '图片$imageNumber是新场景资产（$view），是以下属性的唯一权威来源：$scopes。忽略其构图与主体布局，服从图片1的机位、透视、位置、遮挡和接触关系。',
    };
  }

  static String _scopeLabel(ReplicationAuthorityScope scope) => switch (scope) {
    ReplicationAuthorityScope.canvasAndAspectRatio => '画幅与宽高比',
    ReplicationAuthorityScope.shotSizeAndCamera => '景别与摄影角度',
    ReplicationAuthorityScope.compositionAndPerspective => '构图与透视',
    ReplicationAuthorityScope.poseAndOrientation => '动作、姿态与朝向',
    ReplicationAuthorityScope.placementScaleAndBalance => '位置、尺度与画面平衡',
    ReplicationAuthorityScope.contactAndOcclusion => '接触与遮挡关系',
    ReplicationAuthorityScope.environmentAppearance => '环境外观',
    ReplicationAuthorityScope.environmentLightingAndColor => '环境光色',
    ReplicationAuthorityScope.personIdentity => '人物身份',
    ReplicationAuthorityScope.personFace => '脸部',
    ReplicationAuthorityScope.personHair => '发型',
    ReplicationAuthorityScope.personBodyShape => '体型',
    ReplicationAuthorityScope.personWardrobeAppearance => '人物穿搭外观',
    ReplicationAuthorityScope.productSilhouetteAndProportion => '产品轮廓与比例',
    ReplicationAuthorityScope.productStructure => '产品结构',
    ReplicationAuthorityScope.productColorAndMaterial => '产品颜色与材质',
    ReplicationAuthorityScope.productLocalDetail => '产品局部细节',
    ReplicationAuthorityScope.sourceElementAppearance => '勾选原帧元素外观',
    ReplicationAuthorityScope.sourceElementPlacementAndContact =>
      '勾选原帧元素位置与接触关系',
  };

  static String _slotLabel(int slotIndex) {
    var number = slotIndex + 1;
    final codeUnits = <int>[];
    while (number > 0) {
      number--;
      codeUnits.add(65 + number % 26);
      number ~/= 26;
    }
    return String.fromCharCodes(codeUnits.reversed);
  }
}
