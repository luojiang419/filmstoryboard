const storyDesignNoGridCount = 0;
const storyDesignGridOptions = [storyDesignNoGridCount, 4, 6, 9, 12, 16, 24];

const _storyDesignGridLayouts = <int, String>{
  4: '2列×2行',
  6: '3列×2行',
  9: '3列×3行',
  12: '4列×3行',
  16: '4列×4行',
  24: '6列×4行',
};

String buildStoryDesignGridPrompt(
  String prompt,
  int gridCount, {
  bool portraitGrid = false,
}) {
  final normalizedPrompt = prompt.trim();
  if (gridCount == storyDesignNoGridCount) {
    return normalizedPrompt;
  }
  final normalizedCount = storyDesignGridOptions.contains(gridCount)
      ? gridCount
      : 9;
  final layout = portraitGrid
      ? '1列×$normalizedCount行'
      : _storyDesignGridLayouts[normalizedCount]!;
  final readingOrder = portraitGrid ? '从上到下' : '从左到右、从上到下';
  final portraitInstruction = portraitGrid
      ? '整体采用纵向单列长图构图，每行只能有一个分镜；竖屏仅指单列排列，单个分镜仍保持横向画幅。'
      : '';
  return '$normalizedPrompt\n\n'
      '【多宫格分镜生成指令】请在一张完整画布中生成严格 $normalizedCount 个独立分镜画面，'
      '固定排列为 $layout。$portraitInstruction每个分镜必须边界清晰、尺寸一致、间距一致，按$readingOrder的顺序阅读。'
      '所有分镜共同讲述同一段连贯情节，并保持人物身份、服装、场景与美术风格一致；各格使用有变化的景别、机位或动作推进叙事。'
      '不得合并格子，不得遗漏或增加格子，不得在宫格外附加画面，不得生成标题、编号、水印、字幕或说明文字。';
}
