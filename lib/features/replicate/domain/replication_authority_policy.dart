import 'dart:collection';

enum ReplicationAuthoritySource {
  sourceFrame,
  modelAsset,
  fullOutfitAsset,
  productAsset,
  productDetailAsset,
  sceneAsset,
  selectedSourceElement,
}

enum ReplicationAuthorityScope {
  canvasAndAspectRatio,
  shotSizeAndCamera,
  compositionAndPerspective,
  poseAndOrientation,
  placementScaleAndBalance,
  contactAndOcclusion,
  environmentAppearance,
  environmentLightingAndColor,
  personIdentity,
  personFace,
  personHair,
  personBodyShape,
  personWardrobeAppearance,
  productSilhouetteAndProportion,
  productStructure,
  productColorAndMaterial,
  productLocalDetail,
  sourceElementAppearance,
  sourceElementPlacementAndContact,
}

class ReplicationAuthorityContext {
  const ReplicationAuthorityContext({
    this.hasSceneAsset = false,
    this.hasWearableProductAsset = false,
    this.hasProductDetailAsset = false,
    this.isSourceElementSelected = false,
    this.wearableProductSlots = const {},
    this.modelSlots = const {},
    this.productDetailSlots = const {},
    this.fullOutfitPersonSlots = const {},
    this.fullOutfitProductSlotByPersonSlot = const {},
  });

  final bool hasSceneAsset;
  final bool hasWearableProductAsset;
  final bool hasProductDetailAsset;
  final bool isSourceElementSelected;
  final Set<int> wearableProductSlots;
  final Set<int> modelSlots;
  final Set<int> productDetailSlots;
  final Set<int> fullOutfitPersonSlots;
  final Map<int, int> fullOutfitProductSlotByPersonSlot;

  bool isFullOutfitPersonSlot(int? slotIndex) =>
      slotIndex != null &&
      (fullOutfitPersonSlots.contains(slotIndex) ||
          fullOutfitProductSlotByPersonSlot.containsKey(slotIndex));

  bool isFullOutfitProductSlot(int? slotIndex) =>
      slotIndex != null &&
      fullOutfitProductSlotByPersonSlot.values.contains(slotIndex);
}

class ReplicationAuthorityPolicy {
  const ReplicationAuthorityPolicy._();

  static ReplicationAuthoritySource? authorityFor(
    ReplicationAuthorityScope scope, {
    ReplicationAuthorityContext context = const ReplicationAuthorityContext(),
    int? slotIndex,
  }) => switch (scope) {
    ReplicationAuthorityScope.canvasAndAspectRatio ||
    ReplicationAuthorityScope.shotSizeAndCamera ||
    ReplicationAuthorityScope.compositionAndPerspective ||
    ReplicationAuthorityScope.poseAndOrientation ||
    ReplicationAuthorityScope.placementScaleAndBalance ||
    ReplicationAuthorityScope.contactAndOcclusion =>
      ReplicationAuthoritySource.sourceFrame,
    ReplicationAuthorityScope.environmentAppearance ||
    ReplicationAuthorityScope.environmentLightingAndColor =>
      context.hasSceneAsset
          ? ReplicationAuthoritySource.sceneAsset
          : ReplicationAuthoritySource.sourceFrame,
    ReplicationAuthorityScope.personIdentity ||
    ReplicationAuthorityScope.personFace ||
    ReplicationAuthorityScope.personHair ||
    ReplicationAuthorityScope.personBodyShape =>
      context.isFullOutfitPersonSlot(slotIndex)
          ? ReplicationAuthoritySource.fullOutfitAsset
          : (slotIndex == null
                ? context.modelSlots.isNotEmpty
                : context.modelSlots.contains(slotIndex))
          ? ReplicationAuthoritySource.modelAsset
          : ReplicationAuthoritySource.sourceFrame,
    ReplicationAuthorityScope.personWardrobeAppearance =>
      context.wearableProductSlots.contains(slotIndex) ||
              (slotIndex == null && context.hasWearableProductAsset)
          ? ReplicationAuthoritySource.productAsset
          : context.isFullOutfitPersonSlot(slotIndex)
          ? ReplicationAuthoritySource.fullOutfitAsset
          : ReplicationAuthoritySource.sourceFrame,
    ReplicationAuthorityScope.productSilhouetteAndProportion ||
    ReplicationAuthorityScope.productStructure ||
    ReplicationAuthorityScope.productColorAndMaterial =>
      context.isFullOutfitProductSlot(slotIndex)
          ? ReplicationAuthoritySource.fullOutfitAsset
          : ReplicationAuthoritySource.productAsset,
    ReplicationAuthorityScope.productLocalDetail =>
      context.isFullOutfitProductSlot(slotIndex)
          ? ReplicationAuthoritySource.fullOutfitAsset
          : context.productDetailSlots.contains(slotIndex) ||
                (slotIndex == null && context.hasProductDetailAsset)
          ? ReplicationAuthoritySource.productDetailAsset
          : ReplicationAuthoritySource.productAsset,
    ReplicationAuthorityScope.sourceElementAppearance ||
    ReplicationAuthorityScope.sourceElementPlacementAndContact =>
      context.isSourceElementSelected
          ? ReplicationAuthoritySource.selectedSourceElement
          : null,
  };

  static bool isAuthorized(
    ReplicationAuthoritySource source,
    ReplicationAuthorityScope scope, {
    ReplicationAuthorityContext context = const ReplicationAuthorityContext(),
    int? slotIndex,
  }) => authorityFor(scope, context: context, slotIndex: slotIndex) == source;

  static Set<ReplicationAuthorityScope> scopesFor(
    ReplicationAuthoritySource source, {
    ReplicationAuthorityContext context = const ReplicationAuthorityContext(),
    int? slotIndex,
  }) => UnmodifiableSetView({
    for (final scope in ReplicationAuthorityScope.values)
      if (authorityFor(scope, context: context, slotIndex: slotIndex) == source)
        scope,
  });
}
