import 'dart:collection';

import 'replication_authority_policy.dart';

enum NanoBananaAssetKind { sourceFrame, model, product, productDetail, scene }

class NanoBananaAssetInput {
  const NanoBananaAssetInput._({
    required this.assetId,
    required this.path,
    required this.kind,
    required this.slotIndex,
    required this.viewOrder,
  });

  const NanoBananaAssetInput.model({
    required String assetId,
    required String path,
    required int slotIndex,
    int viewOrder = 0,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.model,
         slotIndex: slotIndex,
         viewOrder: viewOrder,
       );

  const NanoBananaAssetInput.product({
    required String assetId,
    required String path,
    required int slotIndex,
    int viewOrder = 0,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.product,
         slotIndex: slotIndex,
         viewOrder: viewOrder,
       );

  const NanoBananaAssetInput.productDetail({
    required String assetId,
    required String path,
    required int productSlotIndex,
    int viewOrder = 0,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.productDetail,
         slotIndex: productSlotIndex,
         viewOrder: viewOrder,
       );

  const NanoBananaAssetInput.scene({
    required String assetId,
    required String path,
    int viewOrder = 0,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.scene,
         slotIndex: null,
         viewOrder: viewOrder,
       );

  final String assetId;
  final String path;
  final NanoBananaAssetKind kind;
  final int? slotIndex;
  final int viewOrder;
}

class NanoBananaAssetEntry {
  const NanoBananaAssetEntry({
    required this.imageNumber,
    required this.assetId,
    required this.path,
    required this.kind,
    required this.authoritySource,
    required this.slotIndex,
    required this.viewOrder,
  });

  final int imageNumber;
  final String assetId;
  final String path;
  final NanoBananaAssetKind kind;
  final ReplicationAuthoritySource authoritySource;
  final int? slotIndex;
  final int viewOrder;

  String get imageLabel => '图片$imageNumber';
}

class NanoBananaAssetManifest {
  NanoBananaAssetManifest._(List<NanoBananaAssetEntry> entries)
    : entries = UnmodifiableListView(entries);

  factory NanoBananaAssetManifest.build({
    required String sourceFrameId,
    required String sourceFramePath,
    Iterable<NanoBananaAssetInput> modelAssets = const [],
    Iterable<NanoBananaAssetInput> productAssets = const [],
    Iterable<NanoBananaAssetInput> productDetailAssets = const [],
    Iterable<NanoBananaAssetInput> sceneAssets = const [],
  }) {
    final sourceId = sourceFrameId.trim();
    final sourcePath = sourceFramePath.trim();
    if (sourceId.isEmpty || sourcePath.isEmpty) {
      throw ArgumentError('原帧 ID 和路径不能为空');
    }

    final inputs = [
      ...modelAssets,
      ...productAssets,
      ...productDetailAssets,
      ...sceneAssets,
    ];
    _validateInputs(inputs, sourceFrameId: sourceId);

    final models = _sorted(inputs, NanoBananaAssetKind.model);
    final products = _sorted(inputs, NanoBananaAssetKind.product);
    final details = _sorted(inputs, NanoBananaAssetKind.productDetail);
    final scenes = _sorted(inputs, NanoBananaAssetKind.scene);
    final slotIndexes = {
      for (final input in [...models, ...products, ...details])
        input.slotIndex!,
    }.toList()..sort();

    final ordered = <NanoBananaAssetInput>[];
    for (final slotIndex in slotIndexes) {
      ordered
        ..addAll(models.where((input) => input.slotIndex == slotIndex))
        ..addAll(products.where((input) => input.slotIndex == slotIndex))
        ..addAll(details.where((input) => input.slotIndex == slotIndex));
    }
    ordered.addAll(scenes);

    final entries = <NanoBananaAssetEntry>[
      NanoBananaAssetEntry(
        imageNumber: 1,
        assetId: sourceId,
        path: sourcePath,
        kind: NanoBananaAssetKind.sourceFrame,
        authoritySource: ReplicationAuthoritySource.sourceFrame,
        slotIndex: null,
        viewOrder: 0,
      ),
    ];
    for (final input in ordered) {
      entries.add(
        NanoBananaAssetEntry(
          imageNumber: entries.length + 1,
          assetId: input.assetId.trim(),
          path: input.path.trim(),
          kind: input.kind,
          authoritySource: _authoritySourceFor(input.kind),
          slotIndex: input.slotIndex,
          viewOrder: input.viewOrder,
        ),
      );
    }
    return NanoBananaAssetManifest._(entries);
  }

  final List<NanoBananaAssetEntry> entries;

  List<String> get inputPaths =>
      UnmodifiableListView(entries.map((entry) => entry.path));

  NanoBananaAssetEntry image(int imageNumber) {
    if (imageNumber < 1 || imageNumber > entries.length) {
      throw RangeError.range(imageNumber, 1, entries.length, 'imageNumber');
    }
    return entries[imageNumber - 1];
  }

  static List<NanoBananaAssetInput> _sorted(
    List<NanoBananaAssetInput> inputs,
    NanoBananaAssetKind kind,
  ) =>
      [
        for (final input in inputs)
          if (input.kind == kind) input,
      ]..sort((left, right) {
        final slotOrder = (left.slotIndex ?? 0).compareTo(right.slotIndex ?? 0);
        if (slotOrder != 0) return slotOrder;
        final viewOrder = left.viewOrder.compareTo(right.viewOrder);
        if (viewOrder != 0) return viewOrder;
        return left.assetId.compareTo(right.assetId);
      });

  static void _validateInputs(
    List<NanoBananaAssetInput> inputs, {
    required String sourceFrameId,
  }) {
    final identityByAssetId = <String, (NanoBananaAssetKind, int?)>{};
    final viewKeys = <(NanoBananaAssetKind, int?, String, int)>{};
    final mainAssetIdsBySlot = <(NanoBananaAssetKind, int), Set<String>>{};
    final productSlots = <int>{};
    final sceneAssetIds = <String>{};

    for (final input in inputs) {
      final assetId = input.assetId.trim();
      final path = input.path.trim();
      if (assetId.isEmpty || path.isEmpty) {
        throw ArgumentError('资产 ID 和路径不能为空');
      }
      if (assetId == sourceFrameId) {
        throw ArgumentError('资产 ID 不能与原帧 ID 重复：$assetId');
      }
      if (input.kind == NanoBananaAssetKind.sourceFrame) {
        throw ArgumentError('原帧必须通过 sourceFrameId/sourceFramePath 提供');
      }
      if (input.viewOrder < 0) {
        throw ArgumentError('viewOrder 不能小于 0：$assetId');
      }
      if (input.kind == NanoBananaAssetKind.scene) {
        if (input.slotIndex != null) {
          throw ArgumentError('场景资产不能绑定人物或产品槽位：$assetId');
        }
        sceneAssetIds.add(assetId);
      } else if (input.slotIndex == null || input.slotIndex! < 0) {
        throw ArgumentError('模特、产品和产品细节必须绑定非负槽位：$assetId');
      }

      final identity = (input.kind, input.slotIndex);
      final previousIdentity = identityByAssetId[assetId];
      if (previousIdentity != null && previousIdentity != identity) {
        throw ArgumentError('同一资产 ID 不能跨角色或槽位使用：$assetId');
      }
      identityByAssetId[assetId] = identity;

      final viewKey = (input.kind, input.slotIndex, assetId, input.viewOrder);
      if (!viewKeys.add(viewKey)) {
        throw ArgumentError('同一资产视图不能重复提交：$assetId/${input.viewOrder}');
      }

      if (input.kind == NanoBananaAssetKind.model ||
          input.kind == NanoBananaAssetKind.product) {
        final key = (input.kind, input.slotIndex!);
        mainAssetIdsBySlot.putIfAbsent(key, () => <String>{}).add(assetId);
      }
      if (input.kind == NanoBananaAssetKind.product) {
        productSlots.add(input.slotIndex!);
      }
    }

    for (final entry in mainAssetIdsBySlot.entries) {
      if (entry.value.length > 1) {
        throw ArgumentError('同一主资产槽位只能绑定一个逻辑资产：${entry.key}');
      }
    }
    if (sceneAssetIds.length > 1) {
      throw ArgumentError('一次请求只能绑定一个逻辑场景资产');
    }
    for (final detail in inputs.where(
      (input) => input.kind == NanoBananaAssetKind.productDetail,
    )) {
      if (!productSlots.contains(detail.slotIndex)) {
        throw ArgumentError('产品细节必须绑定已有产品主资产：${detail.assetId}');
      }
    }
  }

  static ReplicationAuthoritySource _authoritySourceFor(
    NanoBananaAssetKind kind,
  ) => switch (kind) {
    NanoBananaAssetKind.sourceFrame => ReplicationAuthoritySource.sourceFrame,
    NanoBananaAssetKind.model => ReplicationAuthoritySource.modelAsset,
    NanoBananaAssetKind.product => ReplicationAuthoritySource.productAsset,
    NanoBananaAssetKind.productDetail =>
      ReplicationAuthoritySource.productDetailAsset,
    NanoBananaAssetKind.scene => ReplicationAuthoritySource.sceneAsset,
  };
}
