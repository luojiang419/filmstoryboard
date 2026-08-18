import 'package:filmstoryboard/features/replicate/domain/nano_banana_asset_manifest.dart';
import 'package:filmstoryboard/features/replicate/domain/nano_banana_replication_prompt_compiler.dart';
import 'package:test/test.dart';

void main() {
  test('能力识别覆盖官方 Gemini、GRS Pro 家族与 APIMart Pro', () {
    for (final model in [
      'gemini-3-pro-image',
      'gemini-3-pro-image-preview',
      'nano-banana-pro',
      'nano-banana-pro-4k-vip',
      'nano-banana-pro-cl',
      'nano-banana-pro-vip',
      'nano-banana-pro-vt',
      'apimart:gemini-3-pro-image-preview',
      'apimart:gemini-3-pro-image-preview-official',
    ]) {
      expect(
        NanoBananaProModelCapability.supports(model),
        isTrue,
        reason: model,
      );
    }
    for (final model in [
      'nano-banana-fast',
      'gemini-3.1-flash-image',
      'apimart:gemini-3.1-flash-image-preview',
      'apimart:gpt-image-2',
    ]) {
      expect(
        NanoBananaProModelCapability.supports(model),
        isFalse,
        reason: model,
      );
    }
  });

  test('按资产清单和权威策略确定性编译多图复刻提示词', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'source',
      sourceFramePath: 'source.png',
      modelAssets: const [
        NanoBananaAssetInput.model(
          assetId: 'model-a',
          path: 'model-a.png',
          slotIndex: 0,
        ),
      ],
      productAssets: const [
        NanoBananaAssetInput.product(
          assetId: 'product-a',
          path: 'product-a.png',
          slotIndex: 0,
        ),
      ],
      productDetailAssets: const [
        NanoBananaAssetInput.productDetail(
          assetId: 'detail-a',
          path: 'detail-a.png',
          productSlotIndex: 0,
        ),
      ],
      sceneAssets: const [
        NanoBananaAssetInput.scene(assetId: 'scene', path: 'scene.png'),
      ],
    );
    final input = NanoBananaReplicationPromptInput(
      model: 'nano-banana-pro-vip',
      automaticPrompt: '【原帧主体处理计划】人物1替换，产品1保留。\n【未勾选元素：必须移除】耳环。',
      manifest: manifest,
      userInstructions: '人物看向镜头，但不要恢复耳环',
      structuralReferenceDescriptions: const ['DWPose 姿势骨架'],
    );
    const compiler = NanoBananaReplicationPromptCompiler();

    final first = compiler.compile(input);
    final second = compiler.compile(input);

    expect(second, first, reason: '相同结构化输入必须得到逐字一致的最终提示词');
    expect(first, startsWith('【Nano Banana Pro 确定性精准复刻协议】'));
    expect(first, contains('图片1是原帧编辑底图'));
    expect(first, contains('图片2是结构辅助图：DWPose 姿势骨架'));
    expect(first, contains('图片3是模特资产，槽位A'));
    expect(first, contains('人物身份、脸部、发型、体型'));
    expect(first, contains('图片4是产品资产，槽位A'));
    expect(first, contains('产品轮廓与比例、产品结构、产品颜色与材质'));
    expect(first, contains('图片5是逐产品细节资产，槽位A'));
    expect(first, contains('产品局部细节'));
    expect(first, contains('图片6是新场景资产'));
    expect(first, contains('环境外观、环境光色'));
    expect(first, contains('图片1中的原场景外观、装饰、材质、颜色与照明风格均未获授权'));
    expect(first, contains('【用户补充说明：确定性合并】人物看向镜头，但不要恢复耳环'));
    expect(first, contains('明确标记保留的主体可完整沿用其对应外观'));
    expect(first, contains('不得把其他主体或未勾选元素改为保留'));
    expect(first, contains('未获主体处理计划授权的原人物、原产品、原场景'));
    expect(first, endsWith('最终只输出一张完成的复刻分镜画面，不要输出解释、标题、镜号、界面或核对文本。'));
  });

  test('非 Nano Banana Pro 模型拒绝进入专用编译器', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'source',
      sourceFramePath: 'source.png',
    );

    expect(
      () => const NanoBananaReplicationPromptCompiler().compile(
        NanoBananaReplicationPromptInput(
          model: 'nano-banana-fast',
          automaticPrompt: '复刻正文',
          manifest: manifest,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('完整穿搭主视图独占整体权威且补充视图不能反向覆盖', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'source',
      sourceFramePath: 'source.png',
      fullOutfitAssets: const [
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'front.png',
          personSlotIndex: 0,
          productSlotIndex: 1,
          viewOrder: 0,
          viewRole: NanoBananaAssetViewRole.front,
          isPrimaryView: false,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'side.png',
          personSlotIndex: 0,
          productSlotIndex: 1,
          viewOrder: 1,
          viewRole: NanoBananaAssetViewRole.side,
          isPrimaryView: true,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'back.png',
          personSlotIndex: 0,
          productSlotIndex: 1,
          viewOrder: 2,
          viewRole: NanoBananaAssetViewRole.back,
          isPrimaryView: false,
        ),
      ],
    );
    final protocol = NanoBananaFirstRoundProtocol.build(
      manifest: manifest,
      structuralReferences: const [
        NanoBananaStructuralReference(
          id: 'pose',
          path: 'pose.png',
          description: 'DWPose 姿势骨架',
        ),
      ],
    );

    final prompt = const NanoBananaReplicationPromptCompiler().compile(
      NanoBananaReplicationPromptInput(
        model: 'nano-banana-pro-vip',
        automaticPrompt: '严格替换人物与联动服装。',
        manifest: manifest,
        firstRoundProtocol: protocol,
      ),
    );

    expect(prompt, contains('图片2是结构辅助图：DWPose 姿势骨架'));
    expect(prompt, contains('图片3是完整穿搭资产，槽位A（侧面视图）'));
    expect(prompt, contains('与产品槽位B联动'));
    expect(prompt, contains('人物身份、脸部、发型、体型、人物穿搭外观'));
    expect(prompt, contains('产品轮廓与比例、产品结构、产品颜色与材质、产品局部细节'));
    expect(prompt, contains('图片4是正面视图，与图片3共同属于同一完整穿搭资产，槽位A'));
    expect(prompt, contains('图片5是背面视图，与图片3共同属于同一完整穿搭资产，槽位A'));
    expect(prompt, contains('不得覆盖主视图锁定的整体身份、轮廓、比例、颜色'));
  });
}
