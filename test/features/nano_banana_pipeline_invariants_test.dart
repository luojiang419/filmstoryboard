import 'package:filmstoryboard/features/replicate/domain/nano_banana_asset_manifest.dart';
import 'package:filmstoryboard/features/replicate/domain/nano_banana_product_detail_refill_protocol.dart';
import 'package:filmstoryboard/features/replicate/domain/nano_banana_replication_prompt_compiler.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:test/test.dart';

void main() {
  test('完整穿搭联动槽与独立产品槽共存时冻结同一套权威编号和回填白名单', () {
    final manifest = _buildMixedAuthorityManifest();
    final firstRound = NanoBananaFirstRoundProtocol.build(
      manifest: manifest,
      structuralReferences: const [
        NanoBananaStructuralReference(
          id: 'pose',
          path: 'pose.png',
          description: 'DWPose 结构化姿势骨架',
        ),
      ],
    );
    final refill = NanoBananaProductDetailRefillProtocol.build(
      firstRoundProtocol: firstRound,
      markAuthorizations: [
        ReplicateProductMarkAuthorization(
          productSlotIndex: 1,
          enabled: true,
          referenceAssetId: 'detail-view-b',
          exactText: 'FILM B',
          allowedTypes: const [ReplicateAuthorizedMarkType.productName],
          status: ReplicateAuthorizationStatus.confirmed,
          confirmedAt: DateTime.utc(2026, 8, 18),
          location: '瓶身正面',
        ),
      ],
      manifestAssetIdByReferenceAssetId: const {'detail-view-b': 'detail-b'},
    );

    expect(firstRound.inputPaths, [
      'frame.png',
      'pose.png',
      'outfit-side.png',
      'outfit-front.png',
      'outfit-back.png',
      'model-b.png',
      'product-b.png',
      'detail-b.png',
    ]);
    firstRound.validateSubmissionPaths(firstRound.inputPaths);
    expect(refill.detailImages.single.imageNumber, 8);
    expect(refill.authorizedMarks.single.productSlotIndex, 1);
    expect(refill.authorizedMarks.single.referenceImageNumber, 8);

    final prompt = const NanoBananaReplicationPromptCompiler().compile(
      NanoBananaReplicationPromptInput(
        model: 'nano-banana-pro-vip',
        automaticPrompt: '保持图片1构图，替换人物与产品。',
        manifest: manifest,
        firstRoundProtocol: firstRound,
        authorizedProductMarks: refill.authorizedMarks,
      ),
    );
    expect(prompt, contains('图片2是结构辅助图：DWPose 结构化姿势骨架'));
    expect(prompt, contains('图片3是完整穿搭资产，槽位A'));
    expect(prompt, contains('并与产品槽位A联动'));
    expect(prompt, contains('图片7是产品资产，槽位B'));
    expect(prompt, contains('图片8是逐产品细节资产，槽位B'));
    expect(prompt, contains('产品槽位B：仅可依据图片8'));
    expect(prompt, isNot(contains('产品槽位A：仅可依据')));

    final refillPrompt = refill.compileContinuationPrompt();
    expect(refillPrompt, contains('产品槽位B使用图片8'));
    expect(refillPrompt, contains('逐字文本必须且只能是“FILM B”'));
    expect(refillPrompt, contains('完整穿搭、姿势、手脚、接触、遮挡'));

    final recovery = ReplicatedShotGenerationRecovery(
      stage: ReplicatedShotRecoveryStage.awaitingProductDetailRefill,
      orderedReferencePaths: firstRound.inputPaths,
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'high',
      continuationTransport: ReplicatedShotContinuationTransport.interactions,
      continuationApiModel: 'gemini-3-pro-image-preview',
      previousInteractionId: 'interaction-1',
      continuationResumable: true,
      productDetailRefillPrompt: refillPrompt,
      poseProtectionRequired: true,
    );
    final restored = ReplicatedShotGenerationRecovery.fromJson(
      recovery.toJson(),
    );
    expect(
      restored.stage,
      ReplicatedShotRecoveryStage.awaitingProductDetailRefill,
    );
    expect(restored.orderedReferencePaths, firstRound.inputPaths);
    expect(restored.productDetailRefillPrompt, refillPrompt);
    expect(restored.poseProtectionRequired, isTrue);
    expect(restored.hasResumableContinuation, isTrue);
    expect(
      ReplicatedShotGenerationRecovery.fromJson(
        restored
            .copyWith(
              stage: ReplicatedShotRecoveryStage.productDetailRefillInFlight,
            )
            .toJson(),
      ).stage,
      ReplicatedShotRecoveryStage.productDetailRefillInFlight,
    );
  });

  test('完整穿搭联动产品槽不能借用穿搭视图获得产品标识授权', () {
    final manifest = _buildMixedAuthorityManifest();
    final firstRound = NanoBananaFirstRoundProtocol.build(manifest: manifest);

    expect(
      () => NanoBananaProductDetailRefillProtocol.build(
        firstRoundProtocol: firstRound,
        markAuthorizations: [
          ReplicateProductMarkAuthorization(
            productSlotIndex: 0,
            enabled: true,
            referenceAssetId: 'outfit-view',
            allowedTypes: const [ReplicateAuthorizedMarkType.logo],
            status: ReplicateAuthorizationStatus.confirmed,
            confirmedAt: DateTime.utc(2026, 8, 18),
            location: '上衣胸前',
          ),
        ],
        manifestAssetIdByReferenceAssetId: const {'outfit-view': 'outfit-a'},
      ),
      throwsFormatException,
    );
  });
}

NanoBananaAssetManifest _buildMixedAuthorityManifest() =>
    NanoBananaAssetManifest.build(
      sourceFrameId: 'frame',
      sourceFramePath: 'frame.png',
      fullOutfitAssets: const [
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'outfit-front.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 0,
          viewRole: NanoBananaAssetViewRole.front,
          isPrimaryView: false,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'outfit-side.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 1,
          viewRole: NanoBananaAssetViewRole.side,
          isPrimaryView: true,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'outfit-back.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 2,
          viewRole: NanoBananaAssetViewRole.back,
          isPrimaryView: false,
        ),
      ],
      modelAssets: const [
        NanoBananaAssetInput.model(
          assetId: 'model-b',
          path: 'model-b.png',
          slotIndex: 1,
        ),
      ],
      productAssets: const [
        NanoBananaAssetInput.product(
          assetId: 'product-b',
          path: 'product-b.png',
          slotIndex: 1,
        ),
      ],
      productDetailAssets: const [
        NanoBananaAssetInput.productDetail(
          assetId: 'detail-b',
          path: 'detail-b.png',
          productSlotIndex: 1,
        ),
      ],
    );
