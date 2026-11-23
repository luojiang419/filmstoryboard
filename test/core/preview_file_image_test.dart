import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/widgets/preview_file_image.dart';

void main() {
  test('预览图片解码宽度按固定区间复用缓存键', () {
    final first = previewFileImageProvider(
      path: 'preview.png',
      logicalWidth: 100,
      devicePixelRatio: 1,
    );
    final nearby = previewFileImageProvider(
      path: 'preview.png',
      logicalWidth: 110,
      devicePixelRatio: 1,
    );

    expect(first, isA<ResizeImage>());
    expect(first, nearby);
    expect((first as ResizeImage).width, 128);
  });

  test('预览图片解码宽度不会超过调用方上限', () {
    final provider = previewFileImageProvider(
      path: 'large-preview.png',
      logicalWidth: 5000,
      devicePixelRatio: 2,
      maxCacheWidth: 1536,
    );

    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).width, 1536);
  });

  testWidgets('预览组件按视口宽度创建缩放图片提供器', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 180,
          child: PreviewFileImage(
            path: 'missing-preview.png',
            maxCacheWidth: 512,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, 512);
  });
}
