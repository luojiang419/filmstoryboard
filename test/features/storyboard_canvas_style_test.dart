import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_canvas_style.dart';

void main() {
  test('故事板画布 UI 样式在深色主题保持原深灰配色', () {
    final colors = StoryboardCanvasStyle.fromColorScheme(
      AppTheme.dark().colorScheme,
    );

    expect(colors.background, StoryboardCanvasStyle.background);
    expect(colors.tileBackground, StoryboardCanvasStyle.tileBackground);
    expect(colors.imageBackground, StoryboardCanvasStyle.imageBackground);
    expect(colors.slotBackground, StoryboardCanvasStyle.slotBackground);
    expect(colors.slotBorder, StoryboardCanvasStyle.slotBorder);
    expect(colors.text, StoryboardCanvasStyle.text);
    expect(colors.mutedText, StoryboardCanvasStyle.mutedText);
  });

  test('故事板画布 UI 样式在浅色主题切换为浅色背景', () {
    final colors = StoryboardCanvasStyle.fromColorScheme(
      AppTheme.light().colorScheme,
    );

    expect(colors.background, isNot(StoryboardCanvasStyle.background));
    expect(colors.tileBackground, isNot(StoryboardCanvasStyle.tileBackground));
    expect(
      colors.imageBackground,
      isNot(StoryboardCanvasStyle.imageBackground),
    );
    expect(colors.slotBackground, isNot(StoryboardCanvasStyle.slotBackground));
    expect(colors.background.computeLuminance(), greaterThan(0.65));
    expect(colors.text.computeLuminance(), lessThan(0.35));
  });
}
