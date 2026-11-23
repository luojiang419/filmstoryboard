import 'package:filmstoryboard/features/storyboard/presentation/storyboard_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('故事板划像对比', () {
    test('允许分割位置到达左右边缘', () {
      expect(
        resolveStoryboardComparisonSplit(positionX: 0, viewportWidth: 900),
        0,
      );
      expect(
        resolveStoryboardComparisonSplit(positionX: 900, viewportWidth: 900),
        1,
      );
    });

    test('越过视口时限制在完整对比范围内', () {
      expect(
        resolveStoryboardComparisonSplit(positionX: -20, viewportWidth: 900),
        0,
      );
      expect(
        resolveStoryboardComparisonSplit(positionX: 920, viewportWidth: 900),
        1,
      );
    });
  });
}
