import 'package:filmstoryboard/features/replicate/domain/replication_authority_policy.dart';
import 'package:test/test.dart';

void main() {
  test('原帧只提供结构关系且新场景完全接管环境外观', () {
    const context = ReplicationAuthorityContext(hasSceneAsset: true);

    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.poseAndOrientation,
        context: context,
      ),
      ReplicationAuthoritySource.sourceFrame,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.environmentAppearance,
        context: context,
      ),
      ReplicationAuthoritySource.sceneAsset,
    );
    expect(
      ReplicationAuthorityPolicy.scopesFor(
        ReplicationAuthoritySource.sourceFrame,
        context: context,
      ),
      isNot(contains(ReplicationAuthorityScope.environmentLightingAndColor)),
    );
  });

  test('产品细节只接管局部且不能重定义产品整体外形', () {
    const context = ReplicationAuthorityContext(hasProductDetailAsset: true);

    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.productLocalDetail,
        context: context,
      ),
      ReplicationAuthoritySource.productDetailAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.productSilhouetteAndProportion,
        context: context,
      ),
      ReplicationAuthoritySource.productAsset,
    );
    expect(
      ReplicationAuthorityPolicy.isAuthorized(
        ReplicationAuthoritySource.productDetailAsset,
        ReplicationAuthorityScope.productSilhouetteAndProportion,
        context: context,
      ),
      isFalse,
    );
  });

  test('可穿戴产品覆盖模特服装区域但不覆盖人物身份', () {
    const context = ReplicationAuthorityContext(
      hasWearableProductAsset: true,
      modelSlots: {0},
    );

    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personWardrobeAppearance,
        context: context,
      ),
      ReplicationAuthoritySource.productAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personIdentity,
        context: context,
        slotIndex: 0,
      ),
      ReplicationAuthoritySource.modelAsset,
    );
  });

  test('没有产品资产时原帧继续拥有人物穿搭权威', () {
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personIdentity,
      ),
      ReplicationAuthoritySource.sourceFrame,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personWardrobeAppearance,
      ),
      ReplicationAuthoritySource.sourceFrame,
    );
    expect(
      ReplicationAuthorityPolicy.scopesFor(
        ReplicationAuthoritySource.modelAsset,
      ),
      isNot(contains(ReplicationAuthorityScope.personWardrobeAppearance)),
    );
  });

  test('完整穿搭只接管联动槽且其他模特产品仍保持独立权威', () {
    const context = ReplicationAuthorityContext(
      fullOutfitProductSlotByPersonSlot: {1: 2},
      productDetailSlots: {0},
      modelSlots: {0},
    );

    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personIdentity,
        context: context,
        slotIndex: 1,
      ),
      ReplicationAuthoritySource.fullOutfitAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personWardrobeAppearance,
        context: context,
        slotIndex: 1,
      ),
      ReplicationAuthoritySource.fullOutfitAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.productStructure,
        context: context,
        slotIndex: 2,
      ),
      ReplicationAuthoritySource.fullOutfitAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personIdentity,
        context: context,
        slotIndex: 0,
      ),
      ReplicationAuthoritySource.modelAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.productLocalDetail,
        context: context,
        slotIndex: 0,
      ),
      ReplicationAuthoritySource.productDetailAsset,
    );
  });

  test('解除完整穿搭联动后同槽独立产品恢复穿搭外观权威', () {
    const context = ReplicationAuthorityContext(
      fullOutfitPersonSlots: {0},
      wearableProductSlots: {0},
    );

    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personIdentity,
        context: context,
        slotIndex: 0,
      ),
      ReplicationAuthoritySource.fullOutfitAsset,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.personWardrobeAppearance,
        context: context,
        slotIndex: 0,
      ),
      ReplicationAuthoritySource.productAsset,
    );
  });

  test('原帧元素只有勾选后才获得外观与接触关系权限', () {
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.sourceElementAppearance,
      ),
      isNull,
    );
    expect(
      ReplicationAuthorityPolicy.authorityFor(
        ReplicationAuthorityScope.sourceElementPlacementAndContact,
        context: const ReplicationAuthorityContext(
          isSourceElementSelected: true,
        ),
      ),
      ReplicationAuthoritySource.selectedSourceElement,
    );
  });
}
