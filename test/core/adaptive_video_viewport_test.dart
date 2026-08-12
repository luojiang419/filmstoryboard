import 'package:filmstoryboard/core/widgets/adaptive_video_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('横屏视频使用可用宽度并保持实际比例', () {
    final size = constrainedVideoSize(
      maxWidth: 360,
      maxHeight: 420,
      aspectRatio: 16 / 9,
    );

    expect(size.width, 360);
    expect(size.height, closeTo(202.5, 0.001));
  });

  test('竖屏视频受最大高度约束且不会被裁切', () {
    final size = constrainedVideoSize(
      maxWidth: 360,
      maxHeight: 420,
      aspectRatio: 9 / 16,
    );

    expect(size.width, closeTo(236.25, 0.001));
    expect(size.height, 420);
    expect(size.width / size.height, closeTo(9 / 16, 0.001));
  });

  test('4比3和4比5视频都保持各自真实比例', () {
    final landscape = constrainedVideoSize(
      maxWidth: 400,
      maxHeight: 420,
      aspectRatio: 4 / 3,
    );
    final portrait = constrainedVideoSize(
      maxWidth: 400,
      maxHeight: 420,
      aspectRatio: 4 / 5,
    );

    expect(landscape.width, 400);
    expect(landscape.height, 300);
    expect(portrait.width / portrait.height, closeTo(4 / 5, 0.001));
    expect(portrait.height, 420);
  });

  test('无效视频比例安全回退到16比9', () {
    final size = constrainedVideoSize(
      maxWidth: 320,
      maxHeight: double.infinity,
      aspectRatio: 0,
    );

    expect(size.width, 320);
    expect(size.height, 180);
  });
}
