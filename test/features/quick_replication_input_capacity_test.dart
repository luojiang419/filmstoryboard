import 'package:filmstoryboard/features/replicate/domain/quick_replication_input_capacity.dart';
import 'package:test/test.dart';

void main() {
  test('总输入计数包含图1并使用当前模型动态上限', () {
    final capacity = QuickReplicationInputCapacity.evaluate(
      model: 'gemini-3-pro-image',
      userReferenceCount: 10,
      productReferenceCount: 3,
    );

    expect(capacity.totalInputCount, 11);
    expect(capacity.maximumTotalInputCount, 11);
    expect(capacity.isWithinLimits, isTrue);
  });

  test('总图片超限时返回包含原分镜和新增资产数量的具体原因', () {
    final capacity = QuickReplicationInputCapacity.evaluate(
      model: 'gemini-3-pro-image',
      userReferenceCount: 11,
      productReferenceCount: 3,
    );

    expect(capacity.isWithinLimits, isFalse);
    expect(capacity.error, contains('含图1原分镜'));
    expect(capacity.error, contains('新增资产11张'));
  });

  test('Nano Banana Pro单独限制高保真产品主图和细节图数量', () {
    final capacity = QuickReplicationInputCapacity.evaluate(
      model: 'gemini-3-pro-image',
      userReferenceCount: 7,
      productReferenceCount: 7,
    );

    expect(capacity.maximumHighFidelityProductReferenceCount, 6);
    expect(capacity.error, contains('最多使用6张高保真产品主图或产品细节图'));
    expect(capacity.error, contains('当前为7张'));
  });

  test('不支持参考图的模型返回明确切换原因', () {
    final capacity = QuickReplicationInputCapacity.evaluate(
      model: 'apimart:imagen-4.0-apimart',
      userReferenceCount: 1,
      productReferenceCount: 0,
    );

    expect(capacity.isWithinLimits, isFalse);
    expect(capacity.error, contains('不支持多图参考'));
  });
}
