import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:test/test.dart';

void main() {
  test('手动 5x5 布局生成 25 个格位并在顶部保留标题栏', () {
    final titleHeight = StoryboardBoard.titleHeightFor(12);
    final board = StoryboardBoard(
      id: 'board-1',
      name: '测试画板',
      width: 1000,
      height: StoryboardBoard.heightForLayout(width: 1000, rows: 5, columns: 5),
      rows: 5,
      columns: 5,
      gap: 18,
      items: const [],
    );

    expect(board.slotCount, 25);
    expect(board.height, (1000 + titleHeight + board.gap).ceil());
  });

  test('故事板高度以宽度为基准按行列比例自动修正', () {
    expect(
      StoryboardBoard.heightForLayout(width: 1200, rows: 3, columns: 4),
      957,
    );
    expect(
      StoryboardBoard.heightForLayout(width: 1200, rows: 4, columns: 6),
      858,
    );
  });

  test('竖屏模式保持16比9格位并以单列增加画板高度', () {
    const landscape = StoryboardBoard(
      id: 'landscape',
      name: '横屏',
      width: 1080,
      height: 1080,
      rows: 2,
      columns: 2,
      gap: 18,
      items: [],
    );
    final portrait = landscape
        .copyWith(rows: 2, columns: 1, portraitMode: true)
        .withAdaptiveHeight();

    expect(landscape.imageAspectRatio, 16 / 9);
    expect(portrait.imageAspectRatio, 16 / 9);
    expect(portrait.portraitMode, isTrue);
    expect(portrait.columns, 1);
    expect(portrait.height, greaterThan(landscape.withAdaptiveHeight().height));
    expect(
      portrait.height,
      StoryboardBoard.heightForLayout(
        width: 1080,
        rows: 2,
        columns: 1,
        portraitMode: true,
      ),
    );
  });

  test('故事板默认启用半透明虚线行分割线并支持复制配置', () {
    const board = StoryboardBoard(
      id: 'board-divider',
      name: '分割线测试',
      width: 900,
      height: 900,
      rows: 3,
      columns: 3,
      gap: 18,
      items: [],
    );

    expect(board.rowDividerEnabled, isTrue);
    expect(board.rowDividerStyle, StoryboardDividerStyle.dashed);
    expect(board.rowDividerOpacity, 0.35);
    expect(board.titleAlignment, StoryboardTitleAlignment.center);

    final changed = board.copyWith(
      rowDividerEnabled: false,
      rowDividerStyle: StoryboardDividerStyle.solid,
      rowDividerOpacity: 0.8,
      titleAlignment: StoryboardTitleAlignment.right,
    );
    expect(changed.rowDividerEnabled, isFalse);
    expect(changed.rowDividerStyle, StoryboardDividerStyle.solid);
    expect(changed.rowDividerOpacity, 0.8);
    expect(changed.titleAlignment, StoryboardTitleAlignment.right);
  });

  test('故事板高度会根据长描述文本自动增加', () {
    const asset = StoryboardCutAsset(
      id: 'asset-1',
      imageId: 'image-1',
      sourceName: 'grid.png',
      path: 'cut1.png',
      indexNo: 1,
    );
    const item = StoryboardItem(
      asset: asset,
      caption: '角色从画面左侧向右穿过尘土街道，回头看向远方，随后停在马匹旁边整理衣袖，神情从紧张逐渐变得坚定。',
      slotIndex: 0,
    );
    final baseHeight = StoryboardBoard.heightForLayout(
      width: 600,
      rows: 1,
      columns: 1,
      items: [item.copyWith(caption: '')],
      storyDescriptionEnabled: false,
    );
    final adaptiveHeight = StoryboardBoard.heightForLayout(
      width: 600,
      rows: 1,
      columns: 1,
      items: const [item],
    );

    expect(adaptiveHeight, greaterThan(baseHeight));
    expect(
      StoryboardBoard.heightForLayout(
        width: 600,
        rows: 1,
        columns: 1,
        items: const [item],
        storyDescriptionEnabled: false,
      ),
      baseHeight,
    );
  });

  test('逐行描述模式会根据行描述文本自动增加高度', () {
    final baseHeight = StoryboardBoard.heightForLayout(
      width: 900,
      rows: 3,
      columns: 3,
      storyDescriptionEnabled: false,
    );
    final adaptiveHeight = StoryboardBoard.heightForLayout(
      width: 900,
      rows: 3,
      columns: 3,
      rowDescriptionEnabled: true,
      rowCaptions: const [
        '第一行描述较长，人物从画面左侧进入并向右移动，视线望向远处建筑。',
        '第二行描述较长，角色在牧场边停下脚步，与马匹保持互动。',
        '第三行描述较长，人物转身离开并在夕阳下形成明确的运动趋势。',
      ],
    );

    expect(adaptiveHeight, greaterThan(baseHeight));
  });

  test('故事板图片项会保留水平和垂直翻转状态', () {
    const asset = StoryboardCutAsset(
      id: 'asset-1',
      imageId: 'image-1',
      sourceName: 'grid.png',
      path: 'cut1.png',
      indexNo: 1,
    );
    const item = StoryboardItem(
      asset: asset,
      caption: '原描述',
      slotIndex: 0,
      flipHorizontal: true,
    );

    final next = item.copyWith(
      caption: '新描述',
      slotIndex: 2,
      flipHorizontal: false,
      flipVertical: true,
    );

    expect(next.caption, '新描述');
    expect(next.slotIndex, 2);
    expect(next.flipHorizontal, isFalse);
    expect(next.flipVertical, isTrue);
  });

  test('故事板复制时可以显式清空摘要', () {
    const board = StoryboardBoard(
      id: 'board-1',
      name: '测试画板',
      width: 1000,
      height: 1000,
      rows: 1,
      columns: 1,
      gap: 18,
      items: [],
      summary: StoryboardSummary(
        outline: '旧大纲',
        content: '旧内容',
        scenes: '旧场景',
        props: '旧道具',
      ),
    );

    final next = board.copyWith(clearSummary: true);

    expect(next.summary, isNull);
  });

  test('裁切资源模型保留图片 id 用于按资源组操作', () {
    const record = CutResultRecord(
      id: 'result-1',
      taskId: 'task-1',
      imageId: 'image-1',
      indexNo: 1,
      path: 'cut1.png',
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      selected: true,
      createdAt: '2026-07-06T13:00:00',
      originalName: 'grid.png',
    );

    final asset = StoryboardCutAsset.fromRecord(record);

    expect(asset.id, 'result-1');
    expect(asset.imageId, 'image-1');
    expect(asset.sourceName, 'grid.png');
  });
}
