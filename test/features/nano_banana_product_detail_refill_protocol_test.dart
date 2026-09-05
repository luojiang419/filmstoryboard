import 'package:filmstoryboard/features/replicate/domain/nano_banana_asset_manifest.dart';
import 'package:filmstoryboard/features/replicate/domain/nano_banana_product_detail_refill_protocol.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:test/test.dart';

void main() {
  NanoBananaFirstRoundProtocol firstRoundProtocol() {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'source',
      sourceFramePath: 'source.png',
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
    );
    return NanoBananaFirstRoundProtocol.build(
      manifest: manifest,
      structuralReferences: const [
        NanoBananaStructuralReference(
          id: 'pose',
          path: 'pose.png',
          description: '高精度人物深度图',
        ),
      ],
    );
  }

  test('默认关闭的授权不生效，产品细节仍触发一次局部回填协议', () {
    final protocol = NanoBananaProductDetailRefillProtocol.build(
      firstRoundProtocol: firstRoundProtocol(),
      markAuthorizations: const [
        ReplicateProductMarkAuthorization(
          productSlotIndex: 0,
          referenceAssetId: 'detail-a',
          exactText: 'FILM A',
          allowedTypes: [ReplicateAuthorizedMarkType.productName],
          location: '鞋舌正面',
        ),
      ],
    );

    expect(protocol.shouldRun, isTrue);
    expect(protocol.authorizedMarks, isEmpty);
    expect(protocol.detailImages.single.imageNumber, 4);
    expect(protocol.markWhitelistPrompt, contains('授权标识白名单】无'));
    expect(protocol.compileContinuationPrompt(), contains('产品槽位A使用图片4'));
    expect(protocol.compileContinuationPrompt(), contains('不得改变产品主图锁定的整体轮廓'));
  });

  test('已确认授权精确解析到第一轮图片编号并生成最小白名单', () {
    final protocol = NanoBananaProductDetailRefillProtocol.build(
      firstRoundProtocol: firstRoundProtocol(),
      markAuthorizations: [
        ReplicateProductMarkAuthorization(
          productSlotIndex: 0,
          enabled: true,
          referenceAssetId: 'bound-detail-a',
          exactText: 'FILM A',
          allowedTypes: const [
            ReplicateAuthorizedMarkType.logo,
            ReplicateAuthorizedMarkType.productName,
          ],
          status: ReplicateAuthorizationStatus.confirmed,
          confirmedAt: DateTime.utc(2026, 8, 18),
          location: '鞋舌正面',
        ),
      ],
      manifestAssetIdByReferenceAssetId: const {'bound-detail-a': 'detail-a'},
    );

    expect(protocol.authorizedMarks.single.referenceImageNumber, 4);
    expect(protocol.markWhitelistPrompt, contains('产品槽位A：仅可依据图片4'));
    expect(protocol.markWhitelistPrompt, contains('Logo/图形商标、产品名称'));
    expect(protocol.markWhitelistPrompt, contains('逐字文本必须且只能是“FILM A”'));
    expect(protocol.markWhitelistPrompt, contains('不得扩展到其他位置、产品、背景、人物或原帧'));
  });

  test('启用但未确认、跨槽引用和文字型授权缺少逐字文本均拒绝', () {
    final firstRound = firstRoundProtocol();

    expect(
      () => NanoBananaProductDetailRefillProtocol.build(
        firstRoundProtocol: firstRound,
        markAuthorizations: const [
          ReplicateProductMarkAuthorization(
            productSlotIndex: 0,
            enabled: true,
            referenceAssetId: 'detail-a',
            allowedTypes: [ReplicateAuthorizedMarkType.logo],
            location: '鞋舌正面',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => NanoBananaProductDetailRefillProtocol.build(
        firstRoundProtocol: firstRound,
        markAuthorizations: const [
          ReplicateProductMarkAuthorization(
            productSlotIndex: 1,
            enabled: true,
            referenceAssetId: 'detail-a',
            allowedTypes: [ReplicateAuthorizedMarkType.logo],
            status: ReplicateAuthorizationStatus.confirmed,
            location: '正面',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => NanoBananaProductDetailRefillProtocol.build(
        firstRoundProtocol: firstRound,
        markAuthorizations: const [
          ReplicateProductMarkAuthorization(
            productSlotIndex: 0,
            enabled: true,
            referenceAssetId: 'detail-a',
            allowedTypes: [ReplicateAuthorizedMarkType.model],
            status: ReplicateAuthorizationStatus.confirmed,
            location: '侧面',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('没有产品细节和授权时不允许编译续写请求', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'source',
      sourceFramePath: 'source.png',
    );
    final protocol = NanoBananaProductDetailRefillProtocol.build(
      firstRoundProtocol: NanoBananaFirstRoundProtocol.build(
        manifest: manifest,
      ),
    );

    expect(protocol.shouldRun, isFalse);
    expect(protocol.compileContinuationPrompt, throwsStateError);
  });

  test('恢复协议 v3 保存回填状态并兼容读取模块 5 的 v2 姿势恢复记录', () {
    const recovery = ReplicatedShotGenerationRecovery(
      stage: ReplicatedShotRecoveryStage.awaitingProductDetailRefill,
      orderedReferencePaths: ['source.png', 'detail.png'],
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'high',
      continuationTransport: ReplicatedShotContinuationTransport.interactions,
      continuationApiModel: 'gemini-3-pro-image',
      previousInteractionId: 'interaction-1',
      continuationResumable: true,
      productDetailRefillPrompt: '只回填产品局部细节',
      poseProtectionRequired: true,
    );

    final restored = ReplicatedShotGenerationRecovery.fromJson(
      recovery.toJson(),
    );
    expect(restored.stage, recovery.stage);
    expect(restored.productDetailRefillPrompt, '只回填产品局部细节');
    expect(restored.poseProtectionRequired, isTrue);
    expect(restored.hasResumableContinuation, isTrue);

    final legacy = ReplicatedShotGenerationRecovery.fromJson({
      'schemaVersion': 2,
      'stage': 'awaitingInitialReview',
      'orderedReferencePaths': ['source.png', 'pose.png'],
      'aspectRatio': '16:9',
      'imageSize': '2K',
      'quality': 'high',
      'reviewAttempts': const [],
      'continuation': const {
        'transport': 'interactions',
        'apiModel': 'gemini-3-pro-image',
        'previousInteractionId': 'legacy-interaction',
        'resumable': true,
      },
    });
    expect(legacy.stage, ReplicatedShotRecoveryStage.awaitingInitialReview);
    expect(legacy.poseProtectionRequired, isTrue);
    expect(legacy.hasResumableContinuation, isTrue);
  });
}
