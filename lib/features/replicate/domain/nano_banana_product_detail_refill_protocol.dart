import 'dart:collection';

import 'nano_banana_asset_manifest.dart';
import 'replicate_asset_preparation_models.dart';

class NanoBananaAuthorizedProductMark {
  const NanoBananaAuthorizedProductMark({
    required this.productSlotIndex,
    required this.referenceAssetId,
    required this.referenceImageNumber,
    required this.allowedTypes,
    required this.exactText,
    required this.location,
  });

  final int productSlotIndex;
  final String referenceAssetId;
  final int referenceImageNumber;
  final List<ReplicateAuthorizedMarkType> allowedTypes;
  final String exactText;
  final String location;
}

class NanoBananaProductDetailRefillProtocol {
  NanoBananaProductDetailRefillProtocol._({
    required this.firstRoundProtocol,
    required List<NanoBananaFirstRoundImage> detailImages,
    required List<NanoBananaAuthorizedProductMark> authorizedMarks,
  }) : detailImages = UnmodifiableListView(detailImages),
       authorizedMarks = UnmodifiableListView(authorizedMarks);

  factory NanoBananaProductDetailRefillProtocol.build({
    required NanoBananaFirstRoundProtocol firstRoundProtocol,
    Iterable<ReplicateProductMarkAuthorization> markAuthorizations = const [],
    Map<String, String> manifestAssetIdByReferenceAssetId = const {},
  }) {
    final detailImages = [
      for (final image in firstRoundProtocol.images)
        if (image.assetEntry?.kind == NanoBananaAssetKind.productDetail) image,
    ];
    final authorizedMarks = <NanoBananaAuthorizedProductMark>[];
    final seenSlots = <int>{};
    for (final authorization in markAuthorizations) {
      if (!authorization.enabled) continue;
      if (authorization.status != ReplicateAuthorizationStatus.confirmed) {
        throw FormatException(
          '产品槽位${_slotLabel(authorization.productSlotIndex)}的标识授权尚未确认或已撤销；请确认授权，或关闭该授权后再生成。',
        );
      }
      if (!seenSlots.add(authorization.productSlotIndex)) {
        throw FormatException(
          '产品槽位${_slotLabel(authorization.productSlotIndex)}只能保留一份生效的标识授权。',
        );
      }
      final referenceAssetId = authorization.referenceAssetId.trim();
      final location = authorization.location.trim();
      final exactText = authorization.exactText.trim();
      if (authorization.productSlotIndex < 0 ||
          referenceAssetId.isEmpty ||
          authorization.allowedTypes.isEmpty ||
          location.isEmpty) {
        throw FormatException('生效的产品标识授权必须填写产品槽位、参考资产、标识类型和准确位置。');
      }
      final requiresExactText = authorization.allowedTypes.any(
        (type) => type != ReplicateAuthorizedMarkType.logo,
      );
      if (requiresExactText && exactText.isEmpty) {
        throw FormatException('产品名称、型号或包装文字授权必须填写逐字准确文本。');
      }
      final manifestAssetId =
          manifestAssetIdByReferenceAssetId[referenceAssetId] ??
          referenceAssetId;
      final matchingImages = [
        for (final image in firstRoundProtocol.images)
          if (image.assetEntry case final entry?
              when entry.assetId == manifestAssetId &&
                  entry.slotIndex == authorization.productSlotIndex &&
                  (entry.kind == NanoBananaAssetKind.product ||
                      entry.kind == NanoBananaAssetKind.productDetail))
            image,
      ];
      if (matchingImages.isEmpty) {
        throw FormatException(
          '产品槽位${_slotLabel(authorization.productSlotIndex)}的授权参考资产不属于本槽位的产品主图或细节图。',
        );
      }
      final referenceImage = matchingImages.firstWhere(
        (image) => image.assetEntry?.kind == NanoBananaAssetKind.productDetail,
        orElse: () => matchingImages.first,
      );
      authorizedMarks.add(
        NanoBananaAuthorizedProductMark(
          productSlotIndex: authorization.productSlotIndex,
          referenceAssetId: referenceAssetId,
          referenceImageNumber: referenceImage.imageNumber,
          allowedTypes: List.unmodifiable(authorization.allowedTypes),
          exactText: exactText,
          location: location,
        ),
      );
    }
    authorizedMarks.sort(
      (left, right) => left.productSlotIndex.compareTo(right.productSlotIndex),
    );
    return NanoBananaProductDetailRefillProtocol._(
      firstRoundProtocol: firstRoundProtocol,
      detailImages: detailImages,
      authorizedMarks: authorizedMarks,
    );
  }

  final NanoBananaFirstRoundProtocol firstRoundProtocol;
  final List<NanoBananaFirstRoundImage> detailImages;
  final List<NanoBananaAuthorizedProductMark> authorizedMarks;

  bool get shouldRun => detailImages.isNotEmpty || authorizedMarks.isNotEmpty;

  String get markWhitelistPrompt => authorizedMarks.isEmpty
      ? '【授权标识白名单】无。所有文字、数字、字母、Logo、商标、型号、包装文字、水印、二维码与条形码均禁止出现。'
      : <String>[
          '【授权标识白名单：只允许以下精确项目】',
          for (final mark in authorizedMarks)
            '产品槽位${_slotLabel(mark.productSlotIndex)}：仅可依据图片${mark.referenceImageNumber}，'
                '在“${mark.location}”恢复${mark.allowedTypes.map(_markTypeLabel).join('、')}'
                '${mark.exactText.isEmpty ? '' : '，逐字文本必须且只能是“${mark.exactText}”'}。',
          '白名单只授权上述产品槽位、来源图片、标识类型、准确位置与逐字文本的交集；不得扩展到其他位置、产品、背景、人物或原帧。所有未列出的文字与标识仍严格禁止。',
        ].join('\n');

  String compileContinuationPrompt() {
    if (!shouldRun) {
      throw StateError('没有产品细节或授权标识时不得发起局部回填续写');
    }
    return <String>[
      '【产品局部细节单次回填】',
      '基于当前会话中的上一张成图做一次局部修复；不要重新构图、重绘整张图或生成新方案。',
      if (detailImages.isNotEmpty) ...[
        '只在对应产品已经可见的局部区域，按以下第一轮参考图回填结构、接缝、边缘、材质与纹理：',
        for (final image in detailImages)
          '产品槽位${_slotLabel(image.assetEntry!.slotIndex!)}使用图片${image.imageNumber}的局部证据；不得改变产品主图锁定的整体轮廓、比例、颜色与使用关系。',
      ],
      markWhitelistPrompt,
      '硬性保护：人物身份、脸部、发型、体型、完整穿搭、姿势、手脚、接触、遮挡、构图、机位、透视、景别、场景、光照、画幅与宽高比全部保持上一张成图不变；不得新增、删除或移动任何主体。',
      '除白名单逐项授权的内容外，清除并禁止任何文字、数字、字母、符号组合、字幕、水印、Logo、商标、台标、角标、二维码或条形码。',
      '最终只输出一张完成局部回填的图像，不要输出解释、对比图、标题、界面或核对文本。',
    ].join('\n');
  }

  static String _markTypeLabel(ReplicateAuthorizedMarkType type) =>
      switch (type) {
        ReplicateAuthorizedMarkType.logo => 'Logo/图形商标',
        ReplicateAuthorizedMarkType.productName => '产品名称',
        ReplicateAuthorizedMarkType.model => '型号',
        ReplicateAuthorizedMarkType.packagingText => '包装文字',
      };

  static String _slotLabel(int slotIndex) {
    var number = slotIndex + 1;
    final codeUnits = <int>[];
    while (number > 0) {
      number--;
      codeUnits.add(65 + number % 26);
      number ~/= 26;
    }
    return String.fromCharCodes(codeUnits.reversed);
  }
}
