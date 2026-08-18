import 'package:filmstoryboard/features/replicate/domain/nano_banana_asset_manifest.dart';
import 'package:filmstoryboard/features/replicate/domain/replication_authority_policy.dart';
import 'package:test/test.dart';

void main() {
  test('乱序输入仍按人物产品绑定生成不可变连续图片编号', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'frame-1',
      sourceFramePath: 'frame.png',
      modelAssets: const [
        NanoBananaAssetInput.model(
          assetId: 'model-b',
          path: 'model-b.png',
          slotIndex: 1,
        ),
        NanoBananaAssetInput.model(
          assetId: 'model-a',
          path: 'model-a-side.png',
          slotIndex: 0,
          viewOrder: 1,
        ),
        NanoBananaAssetInput.model(
          assetId: 'model-a',
          path: 'model-a-front.png',
          slotIndex: 0,
        ),
      ],
      productAssets: const [
        NanoBananaAssetInput.product(
          assetId: 'product-b',
          path: 'product-b.png',
          slotIndex: 1,
        ),
        NanoBananaAssetInput.product(
          assetId: 'product-a',
          path: 'product-a.png',
          slotIndex: 0,
        ),
      ],
      productDetailAssets: const [
        NanoBananaAssetInput.productDetail(
          assetId: 'detail-b',
          path: 'detail-b.png',
          productSlotIndex: 1,
        ),
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

    expect(manifest.inputPaths, [
      'frame.png',
      'model-a-front.png',
      'model-a-side.png',
      'product-a.png',
      'detail-a.png',
      'model-b.png',
      'product-b.png',
      'detail-b.png',
      'scene.png',
    ]);
    expect(manifest.entries.map((entry) => entry.imageNumber), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
    ]);
    expect(manifest.image(1).kind, NanoBananaAssetKind.sourceFrame);
    expect(manifest.image(1).imageLabel, '图片1');
    expect(
      manifest.image(5).authoritySource,
      ReplicationAuthoritySource.productDetailAsset,
    );
    expect(manifest.image(9).kind, NanoBananaAssetKind.scene);
    expect(
      () => manifest.entries.add(manifest.entries.first),
      throwsUnsupportedError,
    );
    expect(() => manifest.inputPaths.add('extra.png'), throwsUnsupportedError);
  });

  test('产品细节不能脱离对应产品主资产', () {
    expect(
      () => NanoBananaAssetManifest.build(
        sourceFrameId: 'frame',
        sourceFramePath: 'frame.png',
        productDetailAssets: const [
          NanoBananaAssetInput.productDetail(
            assetId: 'detail-a',
            path: 'detail-a.png',
            productSlotIndex: 0,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('同槽不同主资产与同一视图重复提交都会被拒绝', () {
    expect(
      () => NanoBananaAssetManifest.build(
        sourceFrameId: 'frame',
        sourceFramePath: 'frame.png',
        modelAssets: const [
          NanoBananaAssetInput.model(
            assetId: 'model-a',
            path: 'model-a.png',
            slotIndex: 0,
          ),
          NanoBananaAssetInput.model(
            assetId: 'model-b',
            path: 'model-b.png',
            slotIndex: 0,
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => NanoBananaAssetManifest.build(
        sourceFrameId: 'frame',
        sourceFramePath: 'frame.png',
        productAssets: const [
          NanoBananaAssetInput.product(
            assetId: 'product-a',
            path: 'product-a.png',
            slotIndex: 0,
          ),
          NanoBananaAssetInput.product(
            assetId: 'product-a',
            path: 'product-a-copy.png',
            slotIndex: 0,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('完整穿搭以选定主视图优先并形成一次提交的三视图权威组', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'frame',
      sourceFramePath: 'frame.png',
      fullOutfitAssets: const [
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'front.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 0,
          viewRole: NanoBananaAssetViewRole.front,
          isPrimaryView: false,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'side.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 1,
          viewRole: NanoBananaAssetViewRole.side,
          isPrimaryView: false,
        ),
        NanoBananaAssetInput.fullOutfit(
          assetId: 'outfit-a',
          path: 'back.png',
          personSlotIndex: 0,
          productSlotIndex: 0,
          viewOrder: 2,
          viewRole: NanoBananaAssetViewRole.back,
          isPrimaryView: true,
        ),
      ],
    );

    expect(manifest.inputPaths, [
      'frame.png',
      'back.png',
      'front.png',
      'side.png',
    ]);
    expect(manifest.image(2).isPrimaryView, isTrue);
    expect(manifest.image(2).viewRole, NanoBananaAssetViewRole.back);
    expect(manifest.entries.skip(1).map((entry) => entry.assetId).toSet(), {
      'outfit-a',
    });
    expect(
      manifest.image(2).authoritySource,
      ReplicationAuthoritySource.fullOutfitAsset,
    );
  });

  test('第一轮协议冻结骨架插入位置并在提交错序时阻断', () {
    final manifest = NanoBananaAssetManifest.build(
      sourceFrameId: 'frame',
      sourceFramePath: 'frame.png',
      modelAssets: const [
        NanoBananaAssetInput.model(
          assetId: 'model-a',
          path: 'model.png',
          slotIndex: 0,
        ),
      ],
    );
    final protocol = NanoBananaFirstRoundProtocol.build(
      manifest: manifest,
      structuralReferences: const [
        NanoBananaStructuralReference(
          id: 'pose',
          path: 'pose.png',
          description: 'DWPose 骨架',
        ),
      ],
    );

    expect(protocol.inputPaths, ['frame.png', 'pose.png', 'model.png']);
    expect(protocol.imageForAsset(manifest.image(2)).imageNumber, 3);
    expect(
      () => protocol.validateSubmissionPaths([
        'frame.png',
        'model.png',
        'pose.png',
      ]),
      throwsStateError,
    );
    protocol.validateSubmissionPaths(protocol.inputPaths);
  });

  test('完整穿搭缺视图或多主视图会在建协议前被拒绝', () {
    expect(
      () => NanoBananaAssetManifest.build(
        sourceFrameId: 'frame',
        sourceFramePath: 'frame.png',
        fullOutfitAssets: const [
          NanoBananaAssetInput.fullOutfit(
            assetId: 'outfit-a',
            path: 'front.png',
            personSlotIndex: 0,
            productSlotIndex: 0,
            viewOrder: 0,
            viewRole: NanoBananaAssetViewRole.front,
            isPrimaryView: true,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
}
