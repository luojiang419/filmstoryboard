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
}
