import '../../storyboard/domain/image_generation_model_catalog.dart';

class QuickReplicationInputCapacity {
  const QuickReplicationInputCapacity({
    required this.modelLabel,
    required this.totalInputCount,
    required this.maximumTotalInputCount,
    required this.productReferenceCount,
    this.maximumHighFidelityProductReferenceCount,
    this.error = '',
  });

  static const nanoBananaProHighFidelityProductLimit = 6;

  final String modelLabel;
  final int totalInputCount;
  final int maximumTotalInputCount;
  final int productReferenceCount;
  final int? maximumHighFidelityProductReferenceCount;
  final String error;

  bool get isWithinLimits => error.isEmpty;

  static QuickReplicationInputCapacity evaluate({
    required String model,
    required int userReferenceCount,
    required int productReferenceCount,
  }) {
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    if (descriptor == null) {
      return QuickReplicationInputCapacity(
        modelLabel: model,
        totalInputCount: userReferenceCount + 1,
        maximumTotalInputCount: 0,
        productReferenceCount: productReferenceCount,
        error: '不支持的图片生成模型：$model',
      );
    }
    final total = userReferenceCount + 1;
    final productLimit = ImageGenerationCatalog.isNanoBananaProModel(model)
        ? nanoBananaProHighFidelityProductLimit
        : null;
    var error = '';
    if (!descriptor.supportsReferenceImages) {
      error = '${descriptor.label}不支持多图参考，请切换到 Nano Banana 图片模型。';
    } else if (total > descriptor.maxReferenceImages) {
      error =
          '${descriptor.label}最多支持${descriptor.maxReferenceImages}张输入图片（含图1原分镜）；'
          '当前共$total张，其中新增资产$userReferenceCount张。';
    } else if (productLimit != null && productReferenceCount > productLimit) {
      error =
          '${descriptor.label}最多使用$productLimit张高保真产品主图或产品细节图；'
          '当前为$productReferenceCount张。';
    }
    return QuickReplicationInputCapacity(
      modelLabel: descriptor.label,
      totalInputCount: total,
      maximumTotalInputCount: descriptor.maxReferenceImages,
      productReferenceCount: productReferenceCount,
      maximumHighFidelityProductReferenceCount: productLimit,
      error: error,
    );
  }
}
