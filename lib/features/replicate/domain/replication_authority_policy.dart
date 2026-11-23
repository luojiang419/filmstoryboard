import 'dart:collection';

enum ReplicationAuthoritySource {
  sourceFrame,
  modelAsset,
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
  });

  final bool hasSceneAsset;
  final bool hasWearableProductAsset;
  final bool hasProductDetailAsset;
  final bool isSourceElementSelected;
}

class ReplicationAuthorityPolicy {
  const ReplicationAuthorityPolicy._();

  static ReplicationAuthoritySource? authorityFor(
    ReplicationAuthorityScope scope, {
    ReplicationAuthorityContext context = const ReplicationAuthorityContext(),
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
      ReplicationAuthoritySource.modelAsset,
    ReplicationAuthorityScope.personWardrobeAppearance =>
      context.hasWearableProductAsset
          ? ReplicationAuthoritySource.productAsset
          : ReplicationAuthoritySource.modelAsset,
    ReplicationAuthorityScope.productSilhouetteAndProportion ||
    ReplicationAuthorityScope.productStructure ||
    ReplicationAuthorityScope.productColorAndMaterial =>
      ReplicationAuthoritySource.productAsset,
    ReplicationAuthorityScope.productLocalDetail =>
      context.hasProductDetailAsset
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
  }) => authorityFor(scope, context: context) == source;

  static Set<ReplicationAuthorityScope> scopesFor(
    ReplicationAuthoritySource source, {
    ReplicationAuthorityContext context = const ReplicationAuthorityContext(),
  }) => UnmodifiableSetView({
    for (final scope in ReplicationAuthorityScope.values)
      if (authorityFor(scope, context: context) == source) scope,
  });
}
