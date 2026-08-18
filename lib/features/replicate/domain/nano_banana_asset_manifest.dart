import 'dart:collection';

import 'replication_authority_policy.dart';

enum NanoBananaAssetKind {
  sourceFrame,
  model,
  fullOutfit,
  product,
  productDetail,
  scene,
}

enum NanoBananaAssetViewRole {
  primary,
  front,
  side,
  back,
  detail,
  supplemental,
}

class NanoBananaAssetInput {
  const NanoBananaAssetInput._({
    required this.assetId,
    required this.path,
    required this.kind,
    required this.slotIndex,
    required this.linkedProductSlotIndex,
    required this.viewOrder,
    required this.viewRole,
    required this.isPrimaryView,
  });

  const NanoBananaAssetInput.model({
    required String assetId,
    required String path,
    required int slotIndex,
    int viewOrder = 0,
    NanoBananaAssetViewRole? viewRole,
    bool? isPrimaryView,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.model,
         slotIndex: slotIndex,
         linkedProductSlotIndex: null,
         viewOrder: viewOrder,
         viewRole: viewRole,
         isPrimaryView: isPrimaryView,
       );

  const NanoBananaAssetInput.fullOutfit({
    required String assetId,
    required String path,
    required int personSlotIndex,
    int? productSlotIndex,
    required int viewOrder,
    required NanoBananaAssetViewRole viewRole,
    required bool isPrimaryView,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.fullOutfit,
         slotIndex: personSlotIndex,
         linkedProductSlotIndex: productSlotIndex,
         viewOrder: viewOrder,
         viewRole: viewRole,
         isPrimaryView: isPrimaryView,
       );

  const NanoBananaAssetInput.product({
    required String assetId,
    required String path,
    required int slotIndex,
    int viewOrder = 0,
    NanoBananaAssetViewRole? viewRole,
    bool? isPrimaryView,
  }) : this._(
         assetId: assetId,
         path: path,
         kind: NanoBananaAssetKind.product,
         slotIndex: slotIndex,
         linkedProductSlotIndex: null,
         viewOrder: viewOrder,
         viewRole: viewRole,
         isPrimaryView: isPrimaryView,
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
         linkedProductSlotIndex: null,
         viewOrder: viewOrder,
         viewRole: NanoBananaAssetViewRole.detail,
         isPrimaryView: false,
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
         linkedProductSlotIndex: null,
         viewOrder: viewOrder,
         viewRole: viewOrder == 0
             ? NanoBananaAssetViewRole.primary
             : NanoBananaAssetViewRole.supplemental,
         isPrimaryView: viewOrder == 0,
       );

  final String assetId;
  final String path;
  final NanoBananaAssetKind kind;
  final int? slotIndex;
  final int? linkedProductSlotIndex;
  final int viewOrder;
  final NanoBananaAssetViewRole? viewRole;
  final bool? isPrimaryView;
}

class NanoBananaAssetEntry {
  const NanoBananaAssetEntry({
    required this.imageNumber,
    required this.assetId,
    required this.path,
    required this.kind,
    required this.authoritySource,
    required this.slotIndex,
    required this.linkedProductSlotIndex,
    required this.viewOrder,
    required this.viewRole,
    required this.isPrimaryView,
  });

  final int imageNumber;
  final String assetId;
  final String path;
  final NanoBananaAssetKind kind;
  final ReplicationAuthoritySource authoritySource;
  final int? slotIndex;
  final int? linkedProductSlotIndex;
  final int viewOrder;
  final NanoBananaAssetViewRole viewRole;
  final bool isPrimaryView;

  String get imageLabel => '图片$imageNumber';
}

class NanoBananaAssetManifest {
  NanoBananaAssetManifest._(List<NanoBananaAssetEntry> entries)
    : entries = UnmodifiableListView(entries);

  factory NanoBananaAssetManifest.build({
    required String sourceFrameId,
    required String sourceFramePath,
    Iterable<NanoBananaAssetInput> modelAssets = const [],
    Iterable<NanoBananaAssetInput> fullOutfitAssets = const [],
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
      ...fullOutfitAssets,
      ...productAssets,
      ...productDetailAssets,
      ...sceneAssets,
    ];
    _validateInputs(inputs, sourceFrameId: sourceId);

    final models = _sorted(inputs, NanoBananaAssetKind.model);
    final fullOutfits = _sorted(inputs, NanoBananaAssetKind.fullOutfit);
    final products = _sorted(inputs, NanoBananaAssetKind.product);
    final details = _sorted(inputs, NanoBananaAssetKind.productDetail);
    final scenes = _sorted(inputs, NanoBananaAssetKind.scene);
    final slotIndexes = {
      for (final input in [...models, ...fullOutfits, ...products, ...details])
        input.slotIndex!,
    }.toList()..sort();

    final ordered = <NanoBananaAssetInput>[];
    for (final slotIndex in slotIndexes) {
      ordered
        ..addAll(models.where((input) => input.slotIndex == slotIndex))
        ..addAll(fullOutfits.where((input) => input.slotIndex == slotIndex))
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
        linkedProductSlotIndex: null,
        viewOrder: 0,
        viewRole: NanoBananaAssetViewRole.primary,
        isPrimaryView: true,
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
          linkedProductSlotIndex: input.linkedProductSlotIndex,
          viewOrder: input.viewOrder,
          viewRole:
              input.viewRole ??
              (input.viewOrder == 0
                  ? NanoBananaAssetViewRole.primary
                  : NanoBananaAssetViewRole.supplemental),
          isPrimaryView: input.isPrimaryView ?? input.viewOrder == 0,
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
        final leftPrimaryOrder = (left.isPrimaryView ?? left.viewOrder == 0)
            ? 0
            : 1;
        final rightPrimaryOrder = (right.isPrimaryView ?? right.viewOrder == 0)
            ? 0
            : 1;
        final primaryOrder = leftPrimaryOrder.compareTo(rightPrimaryOrder);
        if (primaryOrder != 0) return primaryOrder;
        final viewOrder = left.viewOrder.compareTo(right.viewOrder);
        if (viewOrder != 0) return viewOrder;
        return left.assetId.compareTo(right.assetId);
      });

  static void _validateInputs(
    List<NanoBananaAssetInput> inputs, {
    required String sourceFrameId,
  }) {
    final identityByAssetId = <String, (NanoBananaAssetKind, int?, int?)>{};
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

      final identity = (
        input.kind,
        input.slotIndex,
        input.linkedProductSlotIndex,
      );
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
          input.kind == NanoBananaAssetKind.fullOutfit ||
          input.kind == NanoBananaAssetKind.product) {
        final key = (input.kind, input.slotIndex!);
        mainAssetIdsBySlot.putIfAbsent(key, () => <String>{}).add(assetId);
      }
      if (input.kind == NanoBananaAssetKind.product) {
        productSlots.add(input.slotIndex!);
      }
      if (input.kind == NanoBananaAssetKind.fullOutfit &&
          input.linkedProductSlotIndex != null &&
          input.linkedProductSlotIndex! < 0) {
        throw ArgumentError('完整穿搭资产绑定的产品槽位不能小于 0：$assetId');
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
    final fullOutfitGroups = <String, List<NanoBananaAssetInput>>{};
    for (final input in inputs.where(
      (input) => input.kind == NanoBananaAssetKind.fullOutfit,
    )) {
      fullOutfitGroups.putIfAbsent(input.assetId.trim(), () => []).add(input);
    }
    for (final entry in fullOutfitGroups.entries) {
      final views = entry.value;
      final roles = views.map((view) => view.viewRole).toSet();
      if (views.length != 3 ||
          !roles.contains(NanoBananaAssetViewRole.front) ||
          !roles.contains(NanoBananaAssetViewRole.side) ||
          !roles.contains(NanoBananaAssetViewRole.back)) {
        throw ArgumentError('完整穿搭资产必须提供互不重复的正面、侧面、背面三视图：${entry.key}');
      }
      if (views.where((view) => view.isPrimaryView == true).length != 1) {
        throw ArgumentError('完整穿搭资产必须且只能指定一个主视图：${entry.key}');
      }
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
    NanoBananaAssetKind.fullOutfit =>
      ReplicationAuthoritySource.fullOutfitAsset,
    NanoBananaAssetKind.product => ReplicationAuthoritySource.productAsset,
    NanoBananaAssetKind.productDetail =>
      ReplicationAuthoritySource.productDetailAsset,
    NanoBananaAssetKind.scene => ReplicationAuthoritySource.sceneAsset,
  };
}

class NanoBananaStructuralReference {
  const NanoBananaStructuralReference({
    required this.id,
    required this.path,
    required this.description,
  });

  final String id;
  final String path;
  final String description;
}

class NanoBananaFirstRoundImage {
  const NanoBananaFirstRoundImage({
    required this.imageNumber,
    required this.path,
    this.assetEntry,
    this.structuralReference,
  });

  final int imageNumber;
  final String path;
  final NanoBananaAssetEntry? assetEntry;
  final NanoBananaStructuralReference? structuralReference;

  bool get isStructural => structuralReference != null;
}

class NanoBananaFirstRoundProtocol {
  NanoBananaFirstRoundProtocol._({
    required this.manifest,
    required List<NanoBananaFirstRoundImage> images,
  }) : images = UnmodifiableListView(images);

  factory NanoBananaFirstRoundProtocol.build({
    required NanoBananaAssetManifest manifest,
    Iterable<NanoBananaStructuralReference> structuralReferences = const [],
  }) {
    if (manifest.entries.isEmpty ||
        manifest.entries.first.kind != NanoBananaAssetKind.sourceFrame) {
      throw ArgumentError('第一轮协议的图片1必须是原帧');
    }
    final structural = structuralReferences.toList(growable: false);
    final images = <NanoBananaFirstRoundImage>[
      NanoBananaFirstRoundImage(
        imageNumber: 1,
        path: manifest.entries.first.path,
        assetEntry: manifest.entries.first,
      ),
      for (var index = 0; index < structural.length; index++)
        NanoBananaFirstRoundImage(
          imageNumber: index + 2,
          path: structural[index].path.trim(),
          structuralReference: structural[index],
        ),
      for (final entry in manifest.entries.skip(1))
        NanoBananaFirstRoundImage(
          imageNumber:
              imagesLengthBeforeAssets(structural.length) +
              entry.imageNumber -
              1,
          path: entry.path,
          assetEntry: entry,
        ),
    ];
    final identities = <String>{};
    for (final image in images) {
      if (image.path.trim().isEmpty) {
        throw ArgumentError('第一轮协议的图片${image.imageNumber}路径不能为空');
      }
      final identity = image.path.trim().replaceAll('\\', '/').toLowerCase();
      if (!identities.add(identity)) {
        throw ArgumentError('第一轮协议不能重复提交同一路径：${image.path}');
      }
    }
    return NanoBananaFirstRoundProtocol._(manifest: manifest, images: images);
  }

  final NanoBananaAssetManifest manifest;
  final List<NanoBananaFirstRoundImage> images;

  List<String> get inputPaths =>
      UnmodifiableListView(images.map((image) => image.path));

  NanoBananaFirstRoundImage imageForAsset(NanoBananaAssetEntry entry) =>
      images.singleWhere((image) => identical(image.assetEntry, entry));

  void validateSubmissionPaths(Iterable<String> submittedPaths) {
    final actual = submittedPaths.toList(growable: false);
    if (actual.length != images.length) {
      throw StateError(
        '第一轮提交图片数量与权威协议不一致：协议 ${images.length} 张，提交 ${actual.length} 张',
      );
    }
    for (var index = 0; index < images.length; index++) {
      if (actual[index] != images[index].path) {
        throw StateError(
          '第一轮提交图片${index + 1}与权威协议不一致：期望 ${images[index].path}，实际 ${actual[index]}',
        );
      }
    }
  }

  static int imagesLengthBeforeAssets(int structuralCount) =>
      1 + structuralCount;
}
