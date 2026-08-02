import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:test/test.dart';

void main() {
  test('输入行数后按图片总数自动适配列数', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_grid_');
    final database = await AppDatabase.open(
      File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
    );
    final controller = StoryboardController(database: database);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final assets = [
      for (var index = 0; index < 30; index++)
        StoryboardCutAsset(
          id: 'asset-$index',
          imageId: 'image-$index',
          sourceName: 'frame-$index.png',
          path: 'frames/frame-$index.png',
          indexNo: index + 1,
        ),
    ];
    controller.setAssetsUsed(assets, true);
    controller.setGrid(5, 6);
    expect(controller.value.selectedBoard!.visibleItemCount, 30);

    controller.setRowsAndAdaptColumns(7);

    final board = controller.value.selectedBoard!;
    expect(board.effectiveConfiguredRows, 7);
    expect(board.effectiveConfiguredColumns, 5);
    expect(board.rows, 7);
    expect(board.columns, 5);
    expect(board.slotCount, 35);
  });
}
