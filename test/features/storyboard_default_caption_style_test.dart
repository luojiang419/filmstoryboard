import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:test/test.dart';

void main() {
  test('新建故事板默认使用 12 号描述字体', () {
    const board = StoryboardBoard(
      id: 'board-1',
      name: '默认样式',
      width: 1920,
      height: 1080,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [],
    );

    expect(board.captionFontSize, 12);
  });
}
