import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:storyboard_grid_app/core/database/app_database.dart';
import 'package:storyboard_grid_app/core/services/app_directories.dart';
import 'package:storyboard_grid_app/features/settings/application/settings_controller.dart';
import 'package:storyboard_grid_app/features/settings/data/settings_repository.dart';
import 'package:storyboard_grid_app/features/settings/domain/app_settings.dart';
import 'package:storyboard_grid_app/features/storyboard/application/storyboard_controller.dart';
import 'package:storyboard_grid_app/features/storyboard/data/image_generation_service.dart';
import 'package:storyboard_grid_app/features/storyboard/data/vision_storyboard_service.dart';
import 'package:storyboard_grid_app/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('批量加选只追加未使用资源并保持顺序', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setAssetsUsed([assets[0], assets[1]], true);
    controller.setAssetsUsed([assets[1], assets[2]], true);

    expect(_itemIds(controller), ['asset-1', 'asset-2', 'asset-3']);
  });

  test('批量减选只移除目标范围资源', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3), _asset(4)];

    controller.setAssetsUsed(assets, true);
    controller.setAssetsUsed([assets[1], assets[2]], false);

    expect(_itemIds(controller), ['asset-1', 'asset-4']);
  });

  test('每个画板可独立撤销恢复且新操作会清空恢复栈', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.setGrid(2, 2);
    controller.setGap(30);
    expect(controller.value.selectedBoard!.gap, 30);

    controller.undoSelectedBoard();
    expect(controller.value.selectedBoard!.gap, 18);
    expect(controller.canRedoSelectedBoard, isTrue);

    controller.setGap(18);
    expect(
      controller.canRedoSelectedBoard,
      isTrue,
      reason: '无变化操作不应污染历史或清空恢复栈',
    );

    controller.undoSelectedBoard();
    expect(controller.value.selectedBoard!.rows, 3);
    expect(controller.value.selectedBoard!.columns, 3);

    controller.redoSelectedBoard();
    expect(controller.value.selectedBoard!.rows, 2);
    expect(controller.value.selectedBoard!.columns, 2);

    controller.setResolution(1600, 0);
    expect(controller.canRedoSelectedBoard, isFalse);
  });

  test('无效移除不会产生伪撤销记录', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.removeAsset('not-exists');

    expect(controller.value.selectedBoard!.items, isEmpty);
    expect(controller.canUndoSelectedBoard, isFalse);
  });

  test('画板撤销历史最多保留100步', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    for (var width = 1000; width <= 1100; width++) {
      controller.setResolution(width, 0);
    }
    for (var step = 0; step < 100; step++) {
      controller.undoSelectedBoard();
    }

    expect(controller.value.selectedBoard!.width, 1000);
    expect(controller.canUndoSelectedBoard, isFalse);
  });

  test('批量加选超过参数布局会自动扩容并在减选后回落', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [for (var index = 1; index <= 10; index++) _asset(index)];

    controller.setAssetsUsed(assets, true);

    var board = controller.value.selectedBoard!;
    expect(board.items, hasLength(10));
    expect(board.rows, 3);
    expect(board.columns, 4);
    expect(board.configuredRows, 3);
    expect(board.configuredColumns, 3);

    controller.setAssetsUsed(assets.skip(8), false);

    board = controller.value.selectedBoard!;
    expect(board.items, hasLength(8));
    expect(board.rows, 3);
    expect(board.columns, 3);
    expect(board.configuredRows, 3);
    expect(board.configuredColumns, 3);
  });

  test('单张加选超过参数布局会自动扩容并在取消后回落', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setGrid(1, 2);
    for (final asset in assets) {
      controller.addOrRemoveAsset(asset);
    }

    var board = controller.value.selectedBoard!;
    expect(_slotIds(controller, 3), ['asset-1', 'asset-2', 'asset-3']);
    expect(board.rows, 1);
    expect(board.columns, 3);
    expect(board.configuredRows, 1);
    expect(board.configuredColumns, 2);

    controller.addOrRemoveAsset(assets.last);

    board = controller.value.selectedBoard!;
    expect(_slotIds(controller, 2), ['asset-1', 'asset-2']);
    expect(board.rows, 1);
    expect(board.columns, 2);
    expect(board.configuredRows, 1);
    expect(board.configuredColumns, 2);
  });

  test('调整图片间距会扩展画板并保持格子尺寸', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final before = controller.value.selectedBoard!;
    final beforeMetrics = _boardGridMetrics(before);

    controller.setGap(64);

    final after = controller.value.selectedBoard!;
    final afterMetrics = _boardGridMetrics(after);
    expect(after.gap, 64);
    expect(after.width, greaterThan(before.width));
    expect(after.height, greaterThan(before.height));
    expect(afterMetrics.cellWidth, closeTo(beforeMetrics.cellWidth, 0.5));
    expect(
      afterMetrics.rowBandHeight,
      closeTo(beforeMetrics.rowBandHeight, 0.5),
    );

    controller.setGap(before.gap);
    final restored = controller.value.selectedBoard!;
    expect(restored.width, closeTo(before.width, 1));
    expect(restored.height, closeTo(before.height, 1));
  });

  test('竖屏模式切换为每行一图并在关闭后恢复原宫格', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    controller.setAssetsUsed([_asset(1), _asset(2)], true);
    final before = controller.value.selectedBoard!;

    controller.setPortraitMode(true);

    final portrait = controller.value.selectedBoard!;
    expect(portrait.portraitMode, isTrue);
    expect(portrait.height, greaterThan(before.height));
    expect(portrait.rows, 2);
    expect(portrait.columns, 1);
    expect(portrait.imageAspectRatio, 16 / 9);
    expect(portrait.items.map((item) => item.asset.id), ['asset-1', 'asset-2']);

    controller.addOrRemoveAsset(_asset(3));
    expect(controller.value.selectedBoard!.rows, 3);
    expect(controller.value.selectedBoard!.columns, 1);
    controller.addOrRemoveAsset(_asset(3));
    expect(controller.value.selectedBoard!.rows, 2);

    controller.setPortraitMode(false);
    final restored = controller.value.selectedBoard!;
    expect(restored.portraitMode, isFalse);
    expect(restored.rows, before.rows);
    expect(restored.columns, before.columns);
    expect(restored.height, before.height);

    controller.setPortraitMode(true);
    controller.clearSelectedBoard();
    expect(controller.value.selectedBoard!.rows, 1);
    expect(controller.value.selectedBoard!.columns, 1);
  });

  test('拖到空格位会自动补位到末尾', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setAssetsUsed(assets, true);
    controller.moveItem(0, 4);

    expect(_slotIds(controller, 5), [
      'asset-2',
      'asset-3',
      'asset-1',
      null,
      null,
    ]);
  });

  test('拖到已有图片格位时区间图片自动让位', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3), _asset(4)];

    controller.setAssetsUsed(assets, true);
    controller.moveItem(0, 2);

    expect(_slotIds(controller, 4), [
      'asset-2',
      'asset-3',
      'asset-1',
      'asset-4',
    ]);
  });

  test('多选拖拽排序会保持组内顺序并让其他图片让位', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3), _asset(4), _asset(5)];

    controller.setAssetsUsed(assets, true);
    controller.moveItems({'asset-2', 'asset-3'}, 4);

    expect(_slotIds(controller, 5), [
      'asset-1',
      'asset-4',
      'asset-5',
      'asset-2',
      'asset-3',
    ]);
  });

  test('多选拖拽只有一张图片时复用单张排序', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setAssetsUsed(assets, true);
    controller.moveItems({'asset-1'}, 2);

    expect(_slotIds(controller, 3), ['asset-2', 'asset-3', 'asset-1']);
  });

  test('左侧资源拖入已有格位会插入并让后续图片顺延', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3), _asset(4)];

    controller.setAssetsUsed(assets.take(3), true);
    controller.placeAssetAtSlot(assets[3], 1);

    expect(_slotIds(controller, 4), [
      'asset-1',
      'asset-4',
      'asset-2',
      'asset-3',
    ]);
  });

  test('左侧资源拖入格位后可完整撤销并恢复', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];
    controller.setAssetsUsed(assets.take(2), true);
    final beforeDrop = _itemIds(controller);

    controller.placeAssetAtSlot(assets.last, 1);
    expect(_itemIds(controller), ['asset-1', 'asset-3', 'asset-2']);

    controller.undoSelectedBoard();
    expect(_itemIds(controller), beforeDrop);
    expect(controller.canRedoSelectedBoard, isTrue);

    controller.redoSelectedBoard();
    expect(_itemIds(controller), ['asset-1', 'asset-3', 'asset-2']);
  });

  test('左侧已使用资源拖入格位时复用现有移动排序', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setAssetsUsed(assets, true);
    controller.placeAssetAtSlot(assets[0], 2);

    expect(_slotIds(controller, 3), ['asset-2', 'asset-3', 'asset-1']);
  });

  test('画板已满时拖入左侧新资源会自动扩容并插入', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setGrid(1, 2);
    controller.setAssetsUsed(assets.take(2), true);
    controller.placeAssetAtSlot(assets[2], 0);

    final board = controller.value.selectedBoard!;
    expect(_slotIds(controller, 3), ['asset-3', 'asset-1', 'asset-2']);
    expect(board.rows, 1);
    expect(board.columns, 3);
    expect(board.configuredRows, 1);
    expect(board.configuredColumns, 2);
  });

  test('描述更新按宫格位匹配图片', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2)];

    controller.setAssetsUsed(assets, true);
    controller.moveItem(0, 4);
    final beforeHeight = controller.value.selectedBoard!.height;
    controller.updateCaption(1, '移动后的描述');

    final item = controller.value.selectedBoard!.itemAtSlot(1);
    expect(item?.asset.id, 'asset-1');
    expect(item?.caption, '移动后的描述');
    expect(
      controller.value.selectedBoard!.height,
      greaterThanOrEqualTo(beforeHeight),
    );
  });

  test('长描述更新后画板高度会自动增高', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.setAssetsUsed([_asset(1)], true);
    final beforeHeight = controller.value.selectedBoard!.height;
    controller.updateCaption(
      0,
      '角色从画面左侧向右穿过尘土街道，回头看向远方，随后停在马匹旁边整理衣袖，神情从紧张逐渐变得坚定。',
    );

    expect(controller.value.selectedBoard!.height, greaterThan(beforeHeight));
  });

  test('图片翻转切换会写入当前格位图片', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.setAssetsUsed([_asset(1)], true);
    controller.toggleItemFlipHorizontal(0);
    controller.toggleItemFlipVertical(0);

    var item = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(item.flipHorizontal, isTrue);
    expect(item.flipVertical, isTrue);

    controller.toggleItemFlipHorizontal(0);
    item = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(item.flipHorizontal, isFalse);
    expect(item.flipVertical, isTrue);
  });

  test('手动替换图片会复制到工程目录并保留当前格描述与翻转状态', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_replace_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, '新镜头.png'));
    await source.writeAsBytes(img.encodePng(img.Image(width: 4, height: 3)));

    controller.setAssetsUsed([_asset(1)], true);
    controller.updateCaption(0, '保留当前说明');
    controller.toggleItemFlipHorizontal(0);
    final original = controller.value.selectedBoard!.itemAtSlot(0)!;

    final replaced = await controller.replaceItemImage(
      item: original,
      imagePath: source.path,
    );

    expect(replaced, isTrue);
    final item = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(item.asset.id, startsWith('replacement-cut-'));
    expect(item.asset.imageId, 'storyboard-manual-replacement-images');
    expect(item.asset.sourceName, '手动替换');
    expect(item.asset.path, isNot(source.path));
    expect(
      p.isWithin(directories.generatedImages.path, item.asset.path),
      isTrue,
    );
    expect(p.basename(p.dirname(item.asset.path)), '画板 1-手动替换');
    expect(p.basename(item.asset.path), '001-画板 1-手动替换.png');
    expect(File(item.asset.path).readAsBytesSync(), source.readAsBytesSync());
    expect(item.caption, '保留当前说明');
    expect(item.flipHorizontal, isTrue);
    expect(controller.value.message, '已替换当前格图片，可撤回/重做（最多100步）');
    expect(
      database.listCutResults().any((record) => record.id == item.asset.id),
      isTrue,
    );

    controller.undoSelectedBoard();
    expect(controller.value.selectedBoard!.itemAtSlot(0)!.asset.id, 'asset-1');
    controller.redoSelectedBoard();
    expect(
      controller.value.selectedBoard!.itemAtSlot(0)!.asset.id,
      item.asset.id,
    );
  });

  test('连续手动替换按画板名称归档并合并为单一来源组', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_manual_archive_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final sources = <File>[];
    for (var index = 1; index <= 3; index++) {
      final source = File(p.join(root.path, '手动镜头$index.png'));
      await source.writeAsBytes(
        img.encodePng(img.Image(width: 3 + index, height: 2 + index)),
      );
      sources.add(source);
    }

    controller.setAssetsUsed([_asset(1)], true);
    controller.renameSelectedBoard('春日:镜头');
    for (final source in sources.take(2)) {
      final current = controller.value.selectedBoard!.itemAtSlot(0)!;
      expect(
        await controller.replaceItemImage(
          item: current,
          imagePath: source.path,
        ),
        isTrue,
      );
    }
    controller.addBoard();
    controller.renameSelectedBoard('夜景镜头');
    controller.setAssetsUsed([_asset(2)], true);
    expect(
      await controller.replaceItemImage(
        item: controller.value.selectedBoard!.itemAtSlot(0)!,
        imagePath: sources.last.path,
      ),
      isTrue,
    );
    await controller.refreshAssets();

    final replacements = controller.value.assets
        .where((asset) => asset.id.startsWith('replacement-cut-'))
        .toList();
    expect(replacements, hasLength(3));
    expect(replacements.map((asset) => asset.imageId).toSet(), {
      'storyboard-manual-replacement-images',
    });
    expect(replacements.map((asset) => asset.sourceName).toSet(), {'手动替换'});
    expect(replacements.map((asset) => asset.indexNo).toList()..sort(), [
      1,
      2,
      3,
    ]);

    final archive = Directory(
      p.join(directories.generatedImages.path, '春日_镜头-手动替换'),
    );
    final names =
        archive
            .listSync()
            .whereType<File>()
            .map((file) => p.basename(file.path))
            .toList()
          ..sort();
    expect(names, ['001-春日_镜头-手动替换.png', '002-春日_镜头-手动替换.png']);
    expect(
      Directory(
        p.join(directories.generatedImages.path, '夜景镜头-手动替换'),
      ).listSync().whereType<File>().map((file) => p.basename(file.path)),
      ['003-夜景镜头-手动替换.png'],
    );
    expect(
      directories.generatedImages.listSync().whereType<Directory>().map(
        (directory) => p.basename(directory.path),
      ),
      containsAll(['春日_镜头-手动替换', '夜景镜头-手动替换']),
    );
  });

  test('手动替换图片支持100步撤回重做并淘汰更早记录', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_replace_history_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, '连续替换.png'));
    await source.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));

    controller.setAssetsUsed([_asset(1)], true);
    controller.updateCaption(0, '连续替换仍保留说明');
    controller.toggleItemFlipVertical(0);
    final assetIds = <String>[
      controller.value.selectedBoard!.itemAtSlot(0)!.asset.id,
    ];

    for (var step = 1; step <= 101; step++) {
      final currentItem = controller.value.selectedBoard!.itemAtSlot(0)!;
      expect(
        await controller.replaceItemImage(
          item: currentItem,
          imagePath: source.path,
        ),
        isTrue,
        reason: '第 $step 次替换应成功',
      );
      final replacedItem = controller.value.selectedBoard!.itemAtSlot(0)!;
      assetIds.add(replacedItem.asset.id);
      expect(replacedItem.caption, '连续替换仍保留说明');
      expect(replacedItem.flipVertical, isTrue);
    }

    for (var expectedIndex = 100; expectedIndex >= 1; expectedIndex--) {
      controller.undoSelectedBoard();
      expect(
        controller.value.selectedBoard!.itemAtSlot(0)!.asset.id,
        assetIds[expectedIndex],
      );
    }
    expect(controller.canUndoSelectedBoard, isFalse);

    for (var expectedIndex = 2; expectedIndex <= 101; expectedIndex++) {
      controller.redoSelectedBoard();
      expect(
        controller.value.selectedBoard!.itemAtSlot(0)!.asset.id,
        assetIds[expectedIndex],
      );
    }
    expect(controller.canRedoSelectedBoard, isFalse);
    final finalItem = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(finalItem.caption, '连续替换仍保留说明');
    expect(finalItem.flipVertical, isTrue);
  });

  test('替换图片右键取消使用后可撤回恢复并重做', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_replace_remove_history_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, '待取消使用.png'));
    await source.writeAsBytes(img.encodePng(img.Image(width: 3, height: 2)));

    controller.setAssetsUsed([_asset(1)], true);
    controller.updateCaption(0, '取消后仍可恢复的说明');
    controller.toggleItemFlipHorizontal(0);
    final original = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(
      await controller.replaceItemImage(item: original, imagePath: source.path),
      isTrue,
    );
    final replacement = controller.value.selectedBoard!.itemAtSlot(0)!;
    final copiedPath = replacement.asset.path;
    await source.delete();

    controller.removeAsset(replacement.asset.id);

    expect(controller.value.selectedBoard!.items, isEmpty);
    expect(controller.value.message, '已取消使用图片，可撤回恢复（最多100步）');
    expect(File(copiedPath).existsSync(), isTrue);

    controller.undoSelectedBoard();
    final restored = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(restored.asset.id, replacement.asset.id);
    expect(restored.asset.path, copiedPath);
    expect(File(restored.asset.path).existsSync(), isTrue);
    expect(restored.caption, '取消后仍可恢复的说明');
    expect(restored.flipHorizontal, isTrue);

    controller.redoSelectedBoard();
    expect(controller.value.selectedBoard!.items, isEmpty);
  });

  test('手动替换会拒绝无效图片且不改变当前格', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_replace_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final invalid = File(p.join(root.path, '损坏图片.png'));
    await invalid.writeAsString('not-an-image');
    controller.setAssetsUsed([_asset(1)], true);
    final original = controller.value.selectedBoard!.itemAtSlot(0)!;

    final replaced = await controller.replaceItemImage(
      item: original,
      imagePath: invalid.path,
    );

    expect(replaced, isFalse);
    expect(controller.value.selectedBoard!.itemAtSlot(0)!.asset.id, 'asset-1');
    expect(controller.value.message, contains('不是有效图片'));
  });

  test('故事描述开关、逐行描述和字体设置会写入当前画板', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.setStoryDescriptionEnabled(false);
    controller.setRowDescriptionEnabled(true);
    controller.setCaptionFontFamily('SimHei');
    controller.setCaptionFontSize(30);
    controller.updateRowCaption(1, '第二行描述');

    final board = controller.value.selectedBoard!;
    expect(board.storyDescriptionEnabled, isFalse);
    expect(board.rowDescriptionEnabled, isTrue);
    expect(board.captionFontFamily, 'SimHei');
    expect(board.captionFontSize, 30);
    expect(board.rowCaptionAt(1), '第二行描述');
  });

  test('画板锁定后编辑入口不改变数据，解锁后恢复', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final assets = [_asset(1), _asset(2), _asset(3)];

    controller.setGrid(2, 2);
    controller.setAssetsUsed(assets.take(2), true);
    controller.updateCaption(0, '原描述');
    controller.updateRowCaption(0, '原行描述');
    final before = controller.value.selectedBoard!;

    controller.toggleSelectedBoardLock();
    controller.addOrRemoveAsset(assets[2]);
    controller.placeAssetAtSlot(assets[2], 0);
    controller.removeAsset(assets[0].id);
    controller.moveItem(0, 1);
    controller.moveItems({assets[0].id, assets[1].id}, 2);
    controller.updateCaption(0, '锁定后描述');
    controller.updateRowCaption(0, '锁定后行描述');
    controller.applyCaptionsByLines('第一行\n第二行');
    controller.toggleItemFlipHorizontal(0);
    controller.toggleItemFlipVertical(0);
    controller.setGrid(3, 3);
    controller.setGap(64);
    controller.setStoryDescriptionEnabled(false);
    controller.setRowDescriptionEnabled(true);
    controller.setCaptionFontFamily('SimHei');
    controller.setCaptionFontSize(30);
    controller.clearSelectedBoard();

    var board = controller.value.selectedBoard!;
    expect(board.locked, isTrue);
    expect(_slotIds(controller, 3), ['asset-1', 'asset-2', null]);
    expect(board.itemAtSlot(0)?.caption, '原描述');
    expect(board.itemAtSlot(0)?.flipHorizontal, isFalse);
    expect(board.itemAtSlot(0)?.flipVertical, isFalse);
    expect(board.rowCaptionAt(0), '原行描述');
    expect(board.rows, before.rows);
    expect(board.columns, before.columns);
    expect(board.gap, before.gap);
    expect(board.storyDescriptionEnabled, before.storyDescriptionEnabled);
    expect(board.rowDescriptionEnabled, before.rowDescriptionEnabled);
    expect(board.captionFontFamily, before.captionFontFamily);
    expect(board.captionFontSize, before.captionFontSize);
    expect(controller.value.message, contains('已锁定'));

    controller.toggleSelectedBoardLock();
    controller.addOrRemoveAsset(assets[2]);
    controller.updateCaption(0, '解锁后描述');
    controller.toggleItemFlipHorizontal(0);
    controller.moveItem(0, 2);

    board = controller.value.selectedBoard!;
    expect(board.locked, isFalse);
    expect(_slotIds(controller, 3), ['asset-2', 'asset-3', 'asset-1']);
    expect(board.itemAtSlot(2)?.caption, '解锁后描述');
    expect(board.itemAtSlot(2)?.flipHorizontal, isTrue);
  });

  test('调整行数时逐行描述按新行数同步', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    controller.updateRowCaption(0, '第一行');
    controller.updateRowCaption(2, '第三行');
    controller.setGrid(2, 3);

    final board = controller.value.selectedBoard!;
    expect(board.rowCaptions, ['第一行', '']);
    expect(board.rows, 2);
  });

  test('删除非最后一个画板后会选中相邻画板', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;

    final firstBoardId = controller.value.selectedBoard!.id;
    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;
    controller.addBoard();
    final thirdBoardId = controller.value.selectedBoard!.id;

    controller.selectBoard(secondBoardId);
    controller.deleteBoard(secondBoardId);

    expect(controller.value.boards.map((board) => board.id), [
      firstBoardId,
      thirdBoardId,
    ]);
    expect(controller.value.selectedBoard?.id, thirdBoardId);
  });

  test('只剩一个画板时不能删除', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final boardId = controller.value.selectedBoard!.id;

    controller.deleteBoard(boardId);

    expect(controller.value.boards, hasLength(1));
    expect(controller.value.selectedBoard?.id, boardId);
    expect(controller.value.message, '至少保留一个画板');
  });

  test('关闭画板只移除顶栏页签并允许全部关闭后重新打开', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final firstBoardId = controller.value.selectedBoard!.id;
    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;

    controller.closeBoard(secondBoardId);

    expect(controller.value.boards, hasLength(2));
    expect(controller.value.openBoardIds, [firstBoardId]);
    expect(controller.value.selectedBoardId, firstBoardId);

    controller.closeBoard(firstBoardId);
    expect(controller.value.boards, hasLength(2));
    expect(controller.value.openBoardIds, isEmpty);
    expect(controller.value.selectedBoard, isNull);
    expect(controller.value.selectedBoardId, isNull);

    controller.openBoard(secondBoardId);
    expect(controller.value.openBoardIds, [secondBoardId]);
    expect(controller.value.selectedBoardId, secondBoardId);
  });

  test('画板编组支持创建重命名批量移动和删除组后保留画板', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final firstBoardId = controller.value.selectedBoard!.id;
    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;

    final groupId = controller.createBoardGroup('广告篇章');
    expect(groupId, isNotNull);
    controller.assignBoardsToGroup([firstBoardId, secondBoardId], groupId);
    expect(
      controller.value.boards.map((board) => board.groupId),
      everyElement(groupId),
    );

    controller.renameBoardGroup(groupId!, '秋冬广告');
    expect(controller.value.boardGroups.single.name, '秋冬广告');

    controller.deleteBoardGroup(groupId);
    expect(controller.value.boardGroups, isEmpty);
    expect(controller.value.boards, hasLength(2));
    expect(
      controller.value.boards.map((board) => board.groupId),
      everyElement(isNull),
    );
  });

  test('空名称不会覆盖当前画板名称', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final originalName = controller.value.selectedBoard!.name;

    controller.renameSelectedBoard('   ');

    expect(controller.value.selectedBoard!.name, originalName);
    expect(controller.value.message, '画板名称不能为空');
  });

  test('清空当前画板只移除选中画板内容并保留参数', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final firstBoardId = controller.value.selectedBoard!.id;

    controller.renameSelectedBoard('镜头组 A');
    controller.setGrid(2, 2);
    controller.setAssetsUsed([_asset(1), _asset(2)], true);
    controller.setRowDescriptionEnabled(true);
    controller.updateRowCaption(0, '第一行描述');
    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;
    controller.setAssetsUsed([_asset(3)], true);

    controller.selectBoard(firstBoardId);
    controller.clearSelectedBoard();

    final firstBoard = controller.value.boards.firstWhere(
      (board) => board.id == firstBoardId,
    );
    final secondBoard = controller.value.boards.firstWhere(
      (board) => board.id == secondBoardId,
    );
    expect(controller.value.selectedBoard?.id, firstBoardId);
    expect(firstBoard.name, '镜头组 A');
    expect(firstBoard.rows, 2);
    expect(firstBoard.columns, 2);
    expect(firstBoard.items, isEmpty);
    expect(firstBoard.rowCaptions, ['', '']);
    expect(secondBoard.items, hasLength(1));
    expect(secondBoard.itemAtSlot(0)?.asset.id, 'asset-3');
    expect(controller.value.message, '已清空 镜头组 A');
  });

  test('保存后重新创建控制器会恢复画板状态', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_restore_');
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    final image = File(p.join(root.path, 'cut-1.png'));
    await image.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      database.dispose();
      await root.delete(recursive: true);
    });

    final firstController = StoryboardController(database: database);
    firstController.renameSelectedBoard('  镜头总览  ');
    firstController.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-restore',
        imageId: 'image-restore',
        sourceName: 'restore.png',
        path: image.path,
        indexNo: 1,
      ),
    ], true);
    firstController.updateCaption(0, '恢复用描述');
    firstController.toggleItemFlipHorizontal(0);
    firstController.setGrid(2, 2);
    firstController.setPortraitMode(true);
    firstController.setRowDescriptionEnabled(true);
    firstController.updateRowCaption(0, '单列恢复');
    firstController.setCaptionFontFamily('SimHei');
    firstController.setCaptionFontSize(30);
    firstController.setRowDividerEnabled(true);
    firstController.setRowDividerStyle(StoryboardDividerStyle.solid);
    firstController.setRowDividerOpacity(0.7);
    firstController.dispose();

    final secondController = StoryboardController(database: database);
    addTearDown(secondController.dispose);

    final board = secondController.value.selectedBoard!;
    final item = board.itemAtSlot(0)!;
    expect(board.name, '镜头总览');
    expect(board.rows, 1);
    expect(board.columns, 1);
    expect(board.portraitMode, isTrue);
    expect(board.rowDescriptionEnabled, isTrue);
    expect(board.rowCaptionAt(0), '单列恢复');
    expect(board.captionFontFamily, 'SimHei');
    expect(board.captionFontSize, 30);
    expect(board.rowDividerEnabled, isTrue);
    expect(board.rowDividerStyle, StoryboardDividerStyle.solid);
    expect(board.rowDividerOpacity, 0.7);
    expect(item.asset.id, 'asset-restore');
    expect(item.caption, '恢复用描述');
    expect(item.flipHorizontal, isTrue);
  });

  test('资源失效刷新后会清理画板并保存', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_cleanup_');
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    addTearDown(() async {
      database.dispose();
      await root.delete(recursive: true);
    });
    final controller = StoryboardController(database: database);
    addTearDown(controller.dispose);
    final asset = await _registeredAsset(database, root, 1);

    await controller.refreshAssets();
    controller.setAssetsUsed([asset], true);
    expect(controller.value.selectedBoard!.items, hasLength(1));

    await File(asset.path).delete();
    await controller.refreshAssets();
    expect(controller.value.selectedBoard!.items, isEmpty);

    final restored = StoryboardController(database: database);
    addTearDown(restored.dispose);
    expect(restored.value.selectedBoard!.items, isEmpty);
  });

  test('总图片目录编组会清理旧编组中的来源及子图引用', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final firstAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      1,
    );
    final secondAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      2,
    );
    await controller.refreshAssets();

    await controller.createResourceGroup(
      name: '历史子图组',
      assetIds: [firstAsset.id],
    );
    await controller.createResourceGroup(
      name: '单图组',
      assetIds: [secondAsset.id],
    );
    await controller.createResourceGroup(
      name: '移动来源',
      sourceImageIds: [firstAsset.imageId],
    );

    expect(controller.value.resourceGroups, hasLength(2));
    expect(controller.value.resourceGroups.first.name, '单图组');
    expect(controller.value.resourceGroups.first.assetIds, [secondAsset.id]);
    expect(controller.value.resourceGroups.last.name, '移动来源');
    expect(controller.value.resourceGroups.last.sourceImageIds, [
      firstAsset.imageId,
    ]);
    expect(controller.value.message, '已创建裁切资源编组 移动来源');
  });

  test('资源编组刷新时会清理失效引用', () async {
    final fixture = await _createFixture();
    final controller = fixture.controller;
    final firstAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      1,
    );
    final secondAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      2,
    );
    await controller.refreshAssets();

    await controller.createResourceGroup(
      name: '混合组',
      assetIds: [firstAsset.id],
      sourceImageIds: [secondAsset.imageId],
    );

    await File(firstAsset.path).delete();
    await controller.refreshAssets();
    var group = controller.value.resourceGroups.single;
    expect(group.assetIds, isEmpty);
    expect(group.sourceImageIds, [secondAsset.imageId]);

    await File(secondAsset.path).delete();
    await controller.refreshAssets();
    expect(controller.value.resourceGroups, isEmpty);
  });

  test('资源编组会随工作区快照恢复', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_group_restore_',
    );
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    addTearDown(() async {
      database.dispose();
      await root.delete(recursive: true);
    });

    final asset = await _registeredAsset(database, root, 1);
    final firstController = StoryboardController(database: database);
    await firstController.refreshAssets();
    await firstController.createResourceGroup(
      name: '恢复组',
      assetIds: [asset.id],
    );
    firstController.toggleResourceGroupExpanded(
      firstController.value.resourceGroups.single.id,
    );
    firstController.dispose();

    final restored = StoryboardController(database: database);
    addTearDown(restored.dispose);
    await restored.refreshAssets();

    final group = restored.value.resourceGroups.single;
    expect(group.name, '恢复组');
    expect(group.assetIds, [asset.id]);
    expect(group.expanded, isFalse);
  });

  test('自定义文件夹会保存拖入图片并刷新为可用资源', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_folder_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final source = File(p.join(root.path, 'source.png'));
    final external = File(p.join(root.path, 'external.jpg'));
    await source.writeAsBytes([1, 2, 3]);
    await external.writeAsBytes([4, 5, 6]);

    await controller.createFolder('镜头参考');
    var folder = controller.value.folders.single;
    expect(folder.path, p.join(directories.storyboardFolders.path, '镜头参考'));
    expect(Directory(folder.path).existsSync(), isTrue);

    await controller.copyAssetToFolder(
      asset: StoryboardCutAsset(
        id: 'source-asset',
        imageId: 'source-image',
        sourceName: 'source.png',
        path: source.path,
        indexNo: 1,
      ),
      folderId: folder.id,
    );
    await controller.copyPathsToFolder(
      paths: [external.path, p.join(root.path, 'note.txt')],
      folderId: folder.id,
    );

    await controller.refreshAssets();
    folder = controller.value.folders.single;
    expect(folder.assets, hasLength(2));
    expect(folder.assets.map((asset) => p.dirname(asset.path)).toSet(), {
      folder.path,
    });
    expect(
      folder.assets.every((asset) => File(asset.path).existsSync()),
      isTrue,
    );

    controller.addOrRemoveAsset(folder.assets.first);
    final item = controller.value.selectedBoard!.itemAtSlot(0);
    expect(item?.asset.id, folder.assets.first.id);

    final deletedAsset = folder.assets.first;
    final deletedPath = deletedAsset.path;
    await controller.deleteFolderAsset(deletedAsset);

    expect(File(deletedPath).existsSync(), isFalse);
    folder = controller.value.folders.single;
    expect(folder.assets, hasLength(1));
    expect(folder.assets.any((asset) => asset.id == deletedAsset.id), isFalse);
    expect(controller.value.selectedBoard!.items, isEmpty);
  });

  test('自定义文件夹可以创建资源编组', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_folder_group_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await controller.createFolder('镜头参考');
    final folder = controller.value.folders.single;

    await controller.createResourceGroup(name: '文件夹组', folderIds: [folder.id]);

    final group = controller.value.resourceGroups.single;
    expect(group.name, '文件夹组');
    expect(group.folderIds, [folder.id]);
  });

  test('裁切资源编组支持多级嵌套重排重命名并阻止循环', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_resource_tree_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await controller.createFolder('文件夹一');
    await controller.createFolder('文件夹二');
    final folders = controller.value.folders;
    await controller.createResourceGroup(
      name: '父编组',
      folderIds: [folders[0].id],
    );
    await controller.createResourceGroup(
      name: '子编组',
      folderIds: [folders[1].id],
    );
    final parentId = controller.value.resourceGroups.first.id;
    final childId = controller.value.resourceGroups.last.id;

    expect(
      controller.moveResourceNode(
        StoryboardResourceNodeRef.group(childId).key,
        targetGroupId: parentId,
      ),
      isTrue,
    );
    expect(
      controller.value.resourceGroups
          .firstWhere((group) => group.id == childId)
          .parentGroupId,
      parentId,
    );

    expect(
      controller.moveResourceNode(
        StoryboardResourceNodeRef.folder(folders[0].id).key,
        targetGroupId: childId,
        beforeNodeKey: StoryboardResourceNodeRef.folder(folders[1].id).key,
      ),
      isTrue,
    );
    final child = controller.value.resourceGroups.firstWhere(
      (group) => group.id == childId,
    );
    expect(child.folderIds, [folders[1].id, folders[0].id]);
    expect(child.childOrder, [
      StoryboardResourceNodeRef.folder(folders[0].id).key,
      StoryboardResourceNodeRef.folder(folders[1].id).key,
    ]);

    expect(
      controller.moveResourceNode(
        StoryboardResourceNodeRef.group(parentId).key,
        targetGroupId: childId,
      ),
      isFalse,
    );
    expect(controller.value.message, '不能把编组移动到自身或其子编组中');

    expect(controller.renameResourceGroup(childId, '父编组'), isTrue);
    expect(
      controller.value.resourceGroups
          .firstWhere((group) => group.id == childId)
          .name,
      '父编组 2',
    );

    controller.flushWorkspaceSnapshot();
    final restored = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(restored.dispose);
    await restored.refreshAssets();
    final restoredChild = restored.value.resourceGroups.firstWhere(
      (group) => group.id == childId,
    );
    expect(restoredChild.parentGroupId, parentId);
    expect(restoredChild.name, '父编组 2');
    expect(restoredChild.childOrder, child.childOrder);
  });

  test('自动解析会逐图入库并按逐行模式回填文本', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_vision_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = SettingsRepository(
      database,
      directories,
      visionDefaultsText: 'url:127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
    );
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final visionService = _FakeVisionStoryboardService();
    final controller = StoryboardController(
      database: database,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      visionService.close();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final assets = [
      await _registeredAsset(database, root, 1),
      await _registeredAsset(database, root, 2),
    ];
    controller.setAssetsUsed(assets, true);
    controller.setRowDescriptionEnabled(true);

    await controller.analyzeSelectedBoardWithVision();

    final board = controller.value.selectedBoard!;
    expect(board.itemAtSlot(0)?.caption, '开场镜头1。');
    expect(board.itemAtSlot(1)?.caption, '随后镜头2。');
    expect(board.rowCaptionAt(0), isNot(contains('；')));
    expect(board.rowCaptionAt(0), contains('镜头依次呈现开场镜头1，并过渡到随后镜头2'));
    expect(board.rowCaptionAt(0), contains('运动趋势表现为向右行走与准备起身'));
    expect(board.summary?.outline, '测试大纲');
    expect(database.countRows('vision_analysis_items'), 2);
    expect(database.countRows('storyboard_summaries'), 1);
  });

  test('自动解析连贯化部分缺项时显示自动恢复且任务成功', () async {
    final visionService = _FakeVisionStoryboardService(
      captionFallbackSequenceNos: const [2],
    );
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();

    final board = controller.value.selectedBoard!;
    expect(board.itemAtSlot(0)?.caption, '开场镜头1。');
    expect(board.itemAtSlot(1)?.caption, '镜头2');
    expect(controller.value.message, '故事板自动解析完成，连贯文本已自动恢复');
    expect(
      fixture.database
          .getLatestVisionAnalysisBatchForBoard(board.id)
          ?.run
          .status,
      'completed',
    );
  });

  test('自动解析完成时目标画板已锁定不会写回文本和摘要', () async {
    final visionService = _BlockingVisionStoryboardService();
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final asset = await _registeredAsset(fixture.database, fixture.root, 1);
    controller.setAssetsUsed([asset], true);

    final analyzeFuture = controller.analyzeSelectedBoardWithVision();
    await visionService.analysisStarted.future;

    controller.toggleSelectedBoardLock();
    visionService.releaseAnalysis();
    await analyzeFuture;

    final board = controller.value.selectedBoard!;
    expect(board.locked, isTrue);
    expect(board.itemAtSlot(0)?.caption, '');
    expect(board.summary, isNull);
    expect(controller.value.isAnalyzing, isFalse);
    expect(controller.value.isCancellingAnalysis, isFalse);
    expect(controller.value.message, contains('已锁定，未写回'));
  });

  test('自动解析前只清理当前画板的视觉缓存', () async {
    final visionService = _FakeVisionStoryboardService();
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final firstAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      1,
    );
    final secondAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      2,
    );

    final firstBoardId = controller.value.selectedBoard!.id;
    controller.setAssetsUsed([firstAsset], true);
    await controller.analyzeSelectedBoardWithVision();
    final firstRunId = fixture.database
        .getLatestVisionAnalysisBatchForBoard(firstBoardId)!
        .run
        .id;

    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;
    controller.setAssetsUsed([secondAsset], true);
    await controller.analyzeSelectedBoardWithVision();
    final secondRunId = fixture.database
        .getLatestVisionAnalysisBatchForBoard(secondBoardId)!
        .run
        .id;

    controller.selectBoard(firstBoardId);
    await controller.analyzeSelectedBoardWithVision();

    final refreshedFirstRun = fixture.database
        .getLatestVisionAnalysisBatchForBoard(firstBoardId)!
        .run;
    final secondRun = fixture.database
        .getLatestVisionAnalysisBatchForBoard(secondBoardId)!
        .run;
    expect(refreshedFirstRun.id, isNot(firstRunId));
    expect(secondRun.id, secondRunId);
    expect(fixture.database.countRows('vision_analysis_runs'), 2);
    expect(fixture.database.countRows('vision_analysis_items'), 2);
    expect(fixture.database.countRows('storyboard_summaries'), 2);
  });

  test('视觉任务队列会写回已关闭画板且不抢当前选中画板', () async {
    final visionService = _BlockingVisionStoryboardService();
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final firstAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      1,
    );
    final secondAsset = await _registeredAsset(
      fixture.database,
      fixture.root,
      2,
    );

    final firstBoardId = controller.value.selectedBoard!.id;
    controller.setAssetsUsed([firstAsset], true);
    controller.addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;
    controller.setAssetsUsed([secondAsset], true);

    controller.selectBoard(firstBoardId);
    final firstFuture = controller.analyzeSelectedBoardWithVision();
    await visionService.analysisStarted.future;

    controller.closeBoard(firstBoardId);
    expect(controller.value.openBoardIds, isNot(contains(firstBoardId)));
    expect(controller.value.selectedBoardId, secondBoardId);
    final secondFuture = controller.analyzeSelectedBoardWithVision();

    expect(
      controller.value.isVisionTaskActiveFor(
        firstBoardId,
        StoryboardVisionTaskKind.analyze,
      ),
      isTrue,
    );
    expect(
      controller.value.isVisionTaskQueuedFor(
        secondBoardId,
        StoryboardVisionTaskKind.analyze,
      ),
      isTrue,
    );

    visionService.releaseAnalysis();
    await Future.wait([firstFuture, secondFuture]);

    final firstBoard = controller.value.boards.firstWhere(
      (board) => board.id == firstBoardId,
    );
    final secondBoard = controller.value.boards.firstWhere(
      (board) => board.id == secondBoardId,
    );
    expect(firstBoard.itemAtSlot(0)?.caption, '镜头1');
    expect(secondBoard.itemAtSlot(0)?.caption, '镜头1');
    expect(controller.value.selectedBoardId, secondBoardId);
    expect(controller.value.activeVisionBoardId, isNull);
    expect(controller.value.queuedVisionTasks, isEmpty);
  });

  test('自动重排序会按最近解析内容调整画板图片顺序', () async {
    final visionService = _FakeVisionStoryboardService(order: const [2, 1]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();
    await controller.reorderSelectedBoardByVisionAnalysis();

    final board = controller.value.selectedBoard!;
    expect(controller.value.reorderAnimationToken, 1);
    expect(_slotIds(controller, 2), ['asset-2', 'asset-1']);
    expect(board.itemAtSlot(0)?.caption, '开场镜头2。');
    expect(board.itemAtSlot(1)?.caption, '随后镜头1。');
    expect(board.summary?.outline, '测试大纲');
    expect(controller.value.message, '自动重排序完成，已更新图片顺序');
    expect(controller.value.isAnalyzing, isFalse);
    expect(visionService.analyzeImageCount, 2);
    expect(visionService.orderRequestCount, 1);
  });

  test('自动重排序遇到最优顺序时给出安抚提示', () async {
    final visionService = _FakeVisionStoryboardService(order: const [1, 2]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();
    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(controller.value.reorderAnimationToken, 0);
    expect(_slotIds(controller, 2), ['asset-1', 'asset-2']);
    expect(controller.value.message, '分镜组合已是最优，无需重新排列');
    expect(controller.value.isAnalyzing, isFalse);
    expect(visionService.orderRequestCount, 1);
  });

  test('自动重排序没有解析结果时会先自动解析再排序', () async {
    final visionService = _FakeVisionStoryboardService(order: const [2, 1]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.reorderSelectedBoardByVisionAnalysis();

    final board = controller.value.selectedBoard!;
    expect(_slotIds(controller, 2), ['asset-2', 'asset-1']);
    expect(board.itemAtSlot(0)?.caption, '开场镜头2。');
    expect(board.itemAtSlot(1)?.caption, '随后镜头1。');
    expect(controller.value.message, '自动重排序完成，已更新图片顺序');
    expect(controller.value.isAnalyzing, isFalse);
    expect(visionService.analyzeImageCount, 2);
    expect(visionService.orderRequestCount, 1);
    expect(fixture.database.countRows('vision_analysis_items'), 2);
  });

  test('自动重排序发现图片变化时会清理旧解析并重解当前画板', () async {
    final visionService = _FakeVisionStoryboardService(order: const [2, 1]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
      await _registeredAsset(fixture.database, fixture.root, 3),
    ];
    controller.setAssetsUsed(assets.take(2), true);
    await controller.analyzeSelectedBoardWithVision();

    controller.removeAsset(assets[0].id);
    controller.addOrRemoveAsset(assets[2]);
    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(_slotIds(controller, 2), ['asset-3', 'asset-2']);
    expect(visionService.analyzeImageCount, 4);
    expect(visionService.orderRequestCount, 1);
    expect(fixture.database.countRows('vision_analysis_runs'), 1);
    expect(fixture.database.countRows('vision_analysis_items'), 2);
  });

  test('自动重排序连贯化异常时静默恢复并保留解析文本', () async {
    final visionService = _FakeVisionStoryboardService(
      order: const [2, 1],
      captionRewriteError: const FormatException('captions 异常'),
    );
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.reorderSelectedBoardByVisionAnalysis();

    final board = controller.value.selectedBoard!;
    expect(_slotIds(controller, 2), ['asset-2', 'asset-1']);
    expect(board.itemAtSlot(0)?.caption, '镜头2');
    expect(board.itemAtSlot(1)?.caption, '镜头1');
    expect(controller.value.message, '自动重排序完成，连贯文本已自动恢复');
    expect(controller.value.isAnalyzing, isFalse);
  });

  test('自动重排序遇到画板图片变更会自动重新解析再排序', () async {
    final visionService = _FakeVisionStoryboardService(order: const [3, 2, 1]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
      await _registeredAsset(fixture.database, fixture.root, 3),
    ];
    controller.setAssetsUsed(assets.take(2), true);

    await controller.analyzeSelectedBoardWithVision();
    controller.setAssetsUsed([assets[2]], true);
    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(_slotIds(controller, 3), ['asset-3', 'asset-2', 'asset-1']);
    expect(controller.value.message, '自动重排序完成，已更新图片顺序');
    expect(controller.value.isAnalyzing, isFalse);
    expect(visionService.analyzeImageCount, 5);
    expect(visionService.orderRequestCount, 1);
  });

  test('自动重排序遇到旧解析结果会自动重新解析再排序', () async {
    final visionService = _FakeVisionStoryboardService(order: const [2, 1]);
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);
    final boardId = controller.value.selectedBoard!.id;

    fixture.database
      ..insertVisionAnalysisRun(
        id: 'legacy-run',
        boardId: boardId,
        model: 'legacy-vlm',
        status: 'running',
        totalImages: 2,
      )
      ..insertVisionAnalysisItem(
        id: 'legacy-item-1',
        runId: 'legacy-run',
        boardId: boardId,
        cutResultId: 'asset-1',
        slotIndex: 0,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 0,
        status: 'success',
        caption: '旧解析1',
        detail: '旧解析只有基础描述',
        scene: '室内',
        props: '',
        people: '角色',
        expression: '神情专注',
        bodyAction: '站立',
        movementTrend: '不明显',
        rawResponse: '{}',
      )
      ..insertVisionAnalysisItem(
        id: 'legacy-item-2',
        runId: 'legacy-run',
        boardId: boardId,
        cutResultId: 'asset-2',
        slotIndex: 1,
        sequenceNo: 2,
        rowIndex: 0,
        columnIndex: 1,
        status: 'success',
        caption: '旧解析2',
        detail: '旧解析只有基础描述',
        scene: '室内',
        props: '',
        people: '角色',
        expression: '神情专注',
        bodyAction: '起身',
        movementTrend: '向右',
        rawResponse: '{}',
      )
      ..updateVisionAnalysisRun(
        id: 'legacy-run',
        status: 'completed',
        successCount: 2,
      );

    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(_slotIds(controller, 2), ['asset-2', 'asset-1']);
    expect(controller.value.message, '自动重排序完成，已更新图片顺序');
    expect(controller.value.isAnalyzing, isFalse);
    expect(visionService.analyzeImageCount, 2);
    expect(visionService.orderRequestCount, 1);
  });

  test('自动重排序遇到模型顺序异常不会改变画板', () async {
    final fixture = await _createVisionFixture(
      visionService: _FakeVisionStoryboardService(
        orderError: const FormatException('顺序异常'),
      ),
    );
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();
    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(controller.value.reorderAnimationToken, 0);
    expect(_slotIds(controller, 2), ['asset-1', 'asset-2']);
    expect(controller.value.message, contains('自动重排序失败'));
    expect(controller.value.isAnalyzing, isFalse);
  });

  test('自动重排序运行中可以取消', () async {
    final visionService = _CancellableVisionStoryboardService(
      order: const [2, 1],
    );
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();
    final reorderFuture = controller.reorderSelectedBoardByVisionAnalysis();
    await visionService.orderStarted.future;

    expect(controller.value.isAnalyzing, isTrue);
    controller.cancelVisionAnalysis();
    await reorderFuture;

    expect(visionService.cancelCalled, isTrue);
    expect(controller.value.isAnalyzing, isFalse);
    expect(controller.value.isCancellingAnalysis, isFalse);
    expect(controller.value.message, '已取消自动重排序');
    expect(_slotIds(controller, 2), ['asset-1', 'asset-2']);
  });

  test('自动重排序会写入日志并清理三天前日志', () async {
    final visionService = _FakeVisionStoryboardService(
      order: const [2, 1],
      analysisRecoveryMode: VisionImageRecoveryMode.jsonRepair,
    );
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final oldLog = File(
      p.join(fixture.directories.logs.path, 'vision-auto-sort-old.log'),
    );
    await oldLog.writeAsString('old');
    await oldLog.setLastModified(
      DateTime.now().subtract(const Duration(days: 4)),
    );
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.reorderSelectedBoardByVisionAnalysis();

    expect(oldLog.existsSync(), isFalse);
    final logs = fixture.directories.logs
        .listSync()
        .whereType<File>()
        .where((file) => p.basename(file.path).startsWith('vision-auto-sort-'))
        .toList();
    expect(logs, isNotEmpty);
    final content = await logs.first.readAsString();
    expect(content, contains('reorder_start'));
    expect(content, contains('reorder_complete'));
    expect(content, contains('analysis_image_recovery'));
    expect(content, contains('jsonRepair'));
    expect(content, contains('requestCount'));
    expect(content, contains('initialReturnedCount'));
    expect(content, contains('repairedSequenceNos'));
    expect(content, contains('fallbackSequenceNos'));
    expect(content, contains('rawResponsePreview'));
  });

  test('自动提示词没有解析结果时会先自动解析并带入多维上下文', () async {
    final visionService = _FakeVisionStoryboardService();
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    final suggestion = await controller.suggestImageEditPromptForItem(
      controller.value.selectedBoard!.itemAtSlot(1)!,
    );

    expect(suggestion.prompt, contains('镜头2'));
    expect(controller.value.message, '已生成当前分镜修改建议');
    expect(visionService.analyzeImageCount, 2);
    expect(visionService.suggestRequestCount, 1);
    expect(visionService.lastCurrentCaption, '随后镜头2。');
    expect(visionService.lastStoryboardSummary, contains('测试大纲'));
    expect(visionService.lastCurrentAnalysis?.detail, '第 2 张图的详细内容');
    expect(visionService.lastPreviousAnalysis?.caption, '镜头1');
    expect(visionService.lastNextAnalysis, isNull);
    expect(
      visionService.lastSuggestionAnalyses.map((analysis) => analysis.caption),
      ['镜头1', '镜头2'],
    );
    expect(fixture.database.countRows('vision_analysis_items'), 2);
  });

  test('自动提示词会复用已有解析结果而不重复解析', () async {
    final visionService = _FakeVisionStoryboardService();
    final fixture = await _createVisionFixture(visionService: visionService);
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);

    await controller.analyzeSelectedBoardWithVision();
    final analyzedCount = visionService.analyzeImageCount;
    await controller.suggestImageEditPromptForItem(
      controller.value.selectedBoard!.itemAtSlot(0)!,
    );

    expect(visionService.analyzeImageCount, analyzedCount);
    expect(visionService.suggestRequestCount, 1);
    expect(visionService.lastCurrentAnalysis?.caption, '镜头1');
    expect(visionService.lastNextAnalysis?.caption, '镜头2');
  });

  test('图片修改生成只替换当前格并保留文本和翻转状态', () async {
    final fixture = await _createImageGenerationFixture();
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);
    controller.updateCaption(0, '保留当前说明');
    controller.toggleItemFlipHorizontal(0);

    final selectedItem = controller.value.selectedBoard!.itemAtSlot(0)!;
    final generated = await controller.generateReplacementForItem(
      item: selectedItem,
      prompt: '让角色回头看向门口',
      model: 'nano-banana-fast',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      extraReferenceImagePaths: const [],
    );

    expect(generated, isTrue);
    final board = controller.value.selectedBoard!;
    final first = board.itemAtSlot(0)!;
    final second = board.itemAtSlot(1)!;
    expect(first.asset.id, startsWith('generated-cut-'));
    expect(
      p.basename(first.asset.path),
      matches(RegExp(r'^001-画板 1-AI修改\.png$')),
    );
    expect(p.basename(first.asset.path), isNot('fake_result.png'));
    expect(File(first.asset.path).existsSync(), isTrue);
    expect(File('${first.asset.path}.json').existsSync(), isTrue);
    expect(
      File('${fixture.imageService.resultPath}.json').existsSync(),
      isFalse,
    );
    expect(first.caption, '保留当前说明');
    expect(first.flipHorizontal, isTrue);
    expect(second.asset.id, 'asset-2');
    expect(
      fixture.imageService.lastRequest?.referenceImagePaths.first,
      assets[0].path,
    );
    expect(fixture.imageService.lastRequest?.apiKey, 'test-image-key');
    expect(controller.value.isGeneratingImage, isFalse);
    expect(controller.value.message, '图片修改完成，已替换当前格');

    final generatedAssetId = first.asset.id;
    controller.undoSelectedBoard();
    expect(controller.value.selectedBoard!.itemAtSlot(0)!.asset.id, 'asset-1');
    controller.redoSelectedBoard();
    expect(
      controller.value.selectedBoard!.itemAtSlot(0)!.asset.id,
      generatedAssetId,
    );
  });

  test('多个图片修改任务可并发生成且完成后不会切走当前画板', () async {
    final fixture = await _createImageGenerationFixture(
      imageServiceFactory: _ConcurrentImageGenerationService.new,
    );
    final imageService =
        fixture.imageService as _ConcurrentImageGenerationService;
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);
    final sourceBoard = controller.value.selectedBoard!;

    final firstTask = controller.generateReplacementForItem(
      item: sourceBoard.itemAtSlot(0)!,
      prompt: '并发任务一',
      model: 'nano-banana-fast',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      extraReferenceImagePaths: const [],
    );
    final secondTask = controller.generateReplacementForItem(
      item: sourceBoard.itemAtSlot(1)!,
      prompt: '并发任务二',
      model: 'nano-banana-fast',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      extraReferenceImagePaths: const [],
    );
    await imageService.bothStarted.future;
    expect(imageService.requests, hasLength(2));
    expect(controller.value.isGeneratingImage, isTrue);

    controller.addBoard();
    final activeBoardId = controller.value.selectedBoardId;
    imageService.releaseAll();
    expect(await Future.wait([firstTask, secondTask]), [isTrue, isTrue]);

    expect(controller.value.selectedBoardId, activeBoardId);
    final updatedSourceBoard = controller.value.boards.firstWhere(
      (board) => board.id == sourceBoard.id,
    );
    expect(
      updatedSourceBoard.items.map((item) => item.asset.id),
      everyElement(startsWith('generated-cut-')),
    );
    expect(updatedSourceBoard.items.map((item) => item.asset.indexNo).toSet(), {
      1,
      2,
    });
    expect(controller.value.isGeneratingImage, isFalse);
  });

  test('高清重绘当前画板固定使用Gemini Pro参数并并发替换', () async {
    final fixture = await _createImageGenerationFixture(
      imageServiceFactory: _ConcurrentImageGenerationService.new,
    );
    await fixture.settingsController.setImageGenerationSettings(
      baseUrl: 'https://grsai.example.com',
      grsaiApiKey: 'grsai-key-123',
      geminiBaseUrl: 'https://generativelanguage.googleapis.com',
      geminiApiKey: 'gemini-key-456',
      model: 'nano-banana-fast',
    );
    final imageService =
        fixture.imageService as _ConcurrentImageGenerationService;
    final controller = fixture.controller;
    final assets = [
      await _registeredAsset(fixture.database, fixture.root, 1),
      await _registeredAsset(fixture.database, fixture.root, 2),
    ];
    controller.setAssetsUsed(assets, true);
    controller.updateCaption(0, '第一格说明');

    final accepted = controller.enqueueHighDefinitionRedrawForSelectedBoard();

    expect(accepted, isTrue);
    await imageService.bothStarted.future;
    expect(imageService.requests, hasLength(2));
    expect(imageService.requests.map((request) => request.model).toSet(), {
      'gemini-3-pro-image',
    });
    expect(
      imageService.requests.map((request) => request.aspectRatio).toSet(),
      {'16:9'},
    );
    expect(imageService.requests.map((request) => request.imageSize).toSet(), {
      '4K',
    });
    expect(imageService.requests.map((request) => request.apiKey).toSet(), {
      'gemini-key-456',
    });
    expect(imageService.requests.first.prompt, contains('高清重绘'));
    expect(imageService.requests.first.prompt, contains('不是重新创作'));
    expect(imageService.requests.first.prompt, contains('严格禁止'));
    expect(imageService.requests.first.prompt, contains('不得覆盖参考图视觉证据'));
    expect(imageService.requests.first.prompt, contains('第一格说明'));
    expect(imageService.requests.first.referenceImagePaths, [assets[0].path]);
    expect(imageService.requests.last.referenceImagePaths, [assets[1].path]);
    expect(controller.value.isGeneratingImage, isTrue);

    imageService.releaseAll();
    await _waitUntil(() {
      final board = controller.value.selectedBoard;
      return board != null &&
          board.items.length == 2 &&
          board.items.every(
            (item) => item.asset.id.startsWith('generated-cut-'),
          );
    });
    await _waitUntil(() => !controller.value.isGeneratingImage);

    final updatedBoard = controller.value.selectedBoard!;
    expect(
      updatedBoard.items.map((item) => item.asset.id),
      everyElement(startsWith('generated-cut-')),
    );
    expect(
      fixture.database.listImageGenerationRecords().where(
        (record) => record.model == 'gemini-3-pro-image',
      ),
      hasLength(2),
    );
    expect(controller.value.message, contains('高清重绘完成'));
  });

  test('连续 AI 修改按画板名称归档并合并为单一来源组', () async {
    final fixture = await _createImageGenerationFixture();
    final controller = fixture.controller;
    final asset = await _registeredAsset(fixture.database, fixture.root, 1);
    controller.setAssetsUsed([asset], true);
    controller.renameSelectedBoard('春日:镜头');

    for (var index = 0; index < 2; index++) {
      final current = controller.value.selectedBoard!.itemAtSlot(0)!;
      expect(
        await controller.generateReplacementForItem(
          item: current,
          prompt: '保持构图并调整光线 $index',
          model: 'nano-banana-fast',
          aspectRatio: '16:9',
          imageSize: '2K',
          quality: 'auto',
          extraReferenceImagePaths: const [],
        ),
        isTrue,
      );
    }
    controller.addBoard();
    controller.renameSelectedBoard('夜景镜头');
    controller.setAssetsUsed([asset], true);
    expect(
      await controller.generateReplacementForItem(
        item: controller.value.selectedBoard!.itemAtSlot(0)!,
        prompt: '保持构图并调整夜景光线',
        model: 'nano-banana-fast',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        extraReferenceImagePaths: const [],
      ),
      isTrue,
    );

    final generated = controller.value.assets
        .where((asset) => asset.id.startsWith('generated-cut-'))
        .toList();
    expect(generated, hasLength(3));
    expect(generated.map((asset) => asset.imageId).toSet(), hasLength(1));
    expect(generated.map((asset) => asset.sourceName).toSet(), {'AI修改'});
    expect(generated.map((asset) => asset.indexNo).toList()..sort(), [1, 2, 3]);

    final archive = Directory(
      p.join(fixture.directories.generatedImages.path, '春日_镜头-AI修改'),
    );
    final names =
        archive
            .listSync()
            .whereType<File>()
            .map((file) => p.basename(file.path))
            .toList()
          ..sort();
    expect(names, [
      '001-春日_镜头-AI修改.png',
      '001-春日_镜头-AI修改.png.json',
      '002-春日_镜头-AI修改.png',
      '002-春日_镜头-AI修改.png.json',
    ]);
    expect(
      Directory(
        p.join(fixture.directories.generatedImages.path, '夜景镜头-AI修改'),
      ).listSync().whereType<File>().map((file) => p.basename(file.path)),
      ['003-夜景镜头-AI修改.png', '003-夜景镜头-AI修改.png.json'],
    );
    expect(
      fixture.directories.generatedImages.listSync().whereType<Directory>(),
      hasLength(2),
    );
  });

  test('旧版分散 AI 修改结果仅在确认后归纳并保持画板引用', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_ai_migrate_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final boardId = controller.value.selectedBoard!.id;
    final legacyAssets = [
      await _registerLegacyGeneratedAsset(
        database,
        directories,
        1,
        boardId: boardId,
      ),
      await _registerLegacyGeneratedAsset(
        database,
        directories,
        2,
        boardId: boardId,
      ),
    ];
    controller.setAssetsUsed(legacyAssets, true);

    await controller.refreshAssets();

    expect(controller.value.assetNormalizationRequired, isTrue);
    expect(controller.value.legacyAiEditedImageCount, 2);
    expect(
      legacyAssets.every((asset) => File(asset.path).existsSync()),
      isTrue,
      reason: '启动检测不能在用户确认前移动旧图片',
    );
    expect(await controller.normalizeLegacyReplacementAssets(), isTrue);

    final generated = controller.value.assets
        .where((asset) => asset.id.startsWith('generated-cut-'))
        .toList();
    expect(generated, hasLength(2));
    expect(generated.map((asset) => asset.imageId).toSet(), {
      'storyboard-ai-edited-images',
    });
    expect(generated.map((asset) => asset.sourceName).toSet(), {'AI修改'});
    expect(generated.map((asset) => asset.indexNo).toList()..sort(), [1, 2]);
    for (final asset in generated) {
      expect(p.basename(p.dirname(asset.path)), '画板 1-AI修改');
      expect(File(asset.path).existsSync(), isTrue);
      final databaseRecord = database.listCutResults().singleWhere(
        (record) => record.id == asset.id,
      );
      expect(databaseRecord.imageId, 'storyboard-ai-edited-images');
      final generationRecord = database
          .listImageGenerationRecords()
          .singleWhere((record) => record.resultAssetId == asset.id);
      expect(generationRecord.resultPath, databaseRecord.path);
    }
    expect(database.countRows('imported_images'), 1);
    expect(controller.value.assetNormalizationRequired, isFalse);
    expect(
      controller.value.selectedBoard!.items.map((item) => item.asset.path),
      containsAll(generated.map((asset) => asset.path)),
    );
    expect(
      directories.generatedImages.listSync().whereType<Directory>().map(
        (directory) => p.basename(directory.path),
      ),
      ['画板 1-AI修改'],
    );
  });

  test('旧版 manual_replacements 会迁移并更新数据库与画板引用', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_manual_migrate_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final boardId = controller.value.selectedBoard!.id;
    final legacyAssets = [
      await _registerLegacyManualReplacementAsset(
        database,
        directories,
        boardId,
        1,
      ),
      await _registerLegacyManualReplacementAsset(
        database,
        directories,
        boardId,
        2,
      ),
    ];
    controller.setAssetsUsed(legacyAssets, true);

    await controller.refreshAssets();

    expect(controller.value.assetNormalizationRequired, isTrue);
    expect(controller.value.legacyManualReplacementImageCount, 2);
    expect(
      legacyAssets.every((asset) => File(asset.path).existsSync()),
      isTrue,
      reason: '启动检测不能在用户确认前移动旧图片',
    );
    expect(await controller.normalizeLegacyReplacementAssets(), isTrue);

    final replacements = controller.value.assets
        .where((asset) => asset.id.startsWith('replacement-cut-legacy-'))
        .toList();
    expect(replacements, hasLength(2));
    expect(replacements.map((asset) => asset.imageId).toSet(), {
      'storyboard-manual-replacement-images',
    });
    expect(replacements.map((asset) => asset.sourceName).toSet(), {'手动替换'});
    expect(replacements.map((asset) => asset.indexNo).toList()..sort(), [1, 2]);
    expect(database.countRows('imported_images'), 1);

    final expectedDirectory = p.join(
      directories.generatedImages.path,
      '画板 1-手动替换',
    );
    final expectedNames = <String>{'001-画板 1-手动替换.png', '002-画板 1-手动替换.png'};
    for (final asset in replacements) {
      expect(p.dirname(asset.path), expectedDirectory);
      expect(expectedNames, contains(p.basename(asset.path)));
      expect(File(asset.path).existsSync(), isTrue);
      final databaseRecord = database.listCutResults().singleWhere(
        (record) => record.id == asset.id,
      );
      expect(databaseRecord.imageId, 'storyboard-manual-replacement-images');
      expect(
        p.normalize(databaseRecord.path),
        p.normalize(
          p.join('generated_images', '画板 1-手动替换', p.basename(asset.path)),
        ),
      );
      expect(databaseRecord.indexNo, asset.indexNo);
    }
    final boardAssets = controller.value.selectedBoard!.items
        .map((item) => item.asset)
        .where((asset) => asset.id.startsWith('replacement-cut-legacy-'))
        .toList();
    expect(boardAssets, hasLength(2));
    expect(boardAssets.map((asset) => asset.path).toSet(), {
      for (final asset in replacements) asset.path,
    });
    expect(
      Directory(
        p.join(
          directories.generatedImages.path,
          boardId,
          'manual_replacements',
        ),
      ).existsSync(),
      isFalse,
    );
  });

  test('图片修改完成时目标画板已锁定不会自动替换', () async {
    final fixture = await _createImageGenerationFixture(
      imageServiceFactory: _BlockingImageGenerationService.new,
    );
    final imageService =
        fixture.imageService as _BlockingImageGenerationService;
    final controller = fixture.controller;
    final asset = await _registeredAsset(fixture.database, fixture.root, 1);
    controller.setAssetsUsed([asset], true);

    final selectedItem = controller.value.selectedBoard!.itemAtSlot(0)!;
    final generationFuture = controller.generateReplacementForItem(
      item: selectedItem,
      prompt: '保持构图并提升光线',
      model: 'nano-banana-fast',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      extraReferenceImagePaths: const [],
    );
    await imageService.requestStarted.future;

    controller.toggleSelectedBoardLock();
    imageService.release();
    final generated = await generationFuture;

    final board = controller.value.selectedBoard!;
    expect(generated, isFalse);
    expect(board.locked, isTrue);
    expect(board.itemAtSlot(0)?.asset.id, 'asset-1');
    expect(controller.value.isGeneratingImage, isFalse);
    expect(controller.value.message, contains('已锁定，未自动替换'));
  });

  test('Gemini图片修改模型使用Gemini专用Key', () async {
    final fixture = await _createImageGenerationFixture();
    await fixture.settingsController.setImageGenerationSettings(
      baseUrl: 'https://grsai.example.com',
      grsaiApiKey: 'grsai-key-123',
      geminiApiKey: 'gemini-key-456',
      model: 'gemini-3-pro-image',
    );
    final controller = fixture.controller;
    final asset = await _registeredAsset(fixture.database, fixture.root, 1);
    controller.setAssetsUsed([asset], true);

    final selectedItem = controller.value.selectedBoard!.itemAtSlot(0)!;
    final generated = await controller.generateReplacementForItem(
      item: selectedItem,
      prompt: '保持构图并提升光线',
      model: 'gemini-3-pro-image',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      extraReferenceImagePaths: const [],
    );

    expect(generated, isTrue);
    expect(fixture.imageService.lastRequest?.apiKey, 'gemini-key-456');
  });
}

Future<
  ({Directory root, AppDatabase database, StoryboardController controller})
>
_createFixture() async {
  final root = await Directory.systemTemp.createTemp('storyboard_batch_');
  final database = await AppDatabase.open(
    File(p.join(root.path, 'storyboard.sqlite')),
  );
  final controller = StoryboardController(database: database);
  addTearDown(() async {
    controller.dispose();
    database.dispose();
    await root.delete(recursive: true);
  });
  return (root: root, database: database, controller: controller);
}

Future<
  ({
    Directory root,
    AppDirectories directories,
    AppDatabase database,
    SettingsController settingsController,
    _FakeVisionStoryboardService visionService,
    StoryboardController controller,
  })
>
_createVisionFixture({_FakeVisionStoryboardService? visionService}) async {
  final root = await Directory.systemTemp.createTemp('storyboard_vision_');
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final repository = SettingsRepository(
    database,
    directories,
    visionDefaultsText: 'url:127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
  );
  final settingsController = SettingsController(
    repository: repository,
    initialSettings: repository.load(),
  );
  final service = visionService ?? _FakeVisionStoryboardService();
  final controller = StoryboardController(
    database: database,
    directories: directories,
    settingsController: settingsController,
    visionService: service,
  );
  addTearDown(() async {
    controller.dispose();
    service.close();
    settingsController.dispose();
    database.dispose();
    await root.delete(recursive: true);
  });
  return (
    root: root,
    directories: directories,
    database: database,
    settingsController: settingsController,
    visionService: service,
    controller: controller,
  );
}

Future<
  ({
    Directory root,
    AppDirectories directories,
    AppDatabase database,
    SettingsController settingsController,
    _FakeImageGenerationService imageService,
    StoryboardController controller,
  })
>
_createImageGenerationFixture({
  _FakeImageGenerationService Function(Directory root)? imageServiceFactory,
}) async {
  final root = await Directory.systemTemp.createTemp('storyboard_image_gen_');
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final repository = SettingsRepository(
    database,
    directories,
    visionDefaultsText: 'url:127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
    imageGenerationDefaultsText:
        '4. `builtin-grsai-image`\nkey: test-image-key\n模型：nano-banana-fast',
  );
  final settingsController = SettingsController(
    repository: repository,
    initialSettings: repository.load(),
  );
  final imageService =
      imageServiceFactory?.call(root) ?? _FakeImageGenerationService(root);
  final controller = StoryboardController(
    database: database,
    directories: directories,
    settingsController: settingsController,
    imageGenerationService: imageService,
  );
  addTearDown(() async {
    controller.dispose();
    settingsController.dispose();
    database.dispose();
    await root.delete(recursive: true);
  });
  return (
    root: root,
    directories: directories,
    database: database,
    settingsController: settingsController,
    imageService: imageService,
    controller: controller,
  );
}

Future<StoryboardCutAsset> _registerLegacyGeneratedAsset(
  AppDatabase database,
  AppDirectories directories,
  int index, {
  String? boardId,
}) async {
  final legacyDirectory = Directory(
    p.join(directories.generatedImages.path, boardId ?? 'legacy-board-$index'),
  );
  await legacyDirectory.create(recursive: true);
  final file = File(p.join(legacyDirectory.path, 'generated-$index.png'));
  await file.writeAsBytes(
    img.encodePng(img.Image(width: 4 + index, height: 3 + index)),
  );
  final imageId = 'legacy-generated-image-$index';
  final taskId = 'legacy-generated-task-$index';
  final assetId = 'generated-cut-legacy-$index';
  final now = DateTime.now().add(Duration(seconds: index)).toIso8601String();
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: file.path,
      originalName: 'AI修改_旧图$index.png',
      storedPath: file.path,
      width: 4 + index,
      height: 3 + index,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'generated',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: assetId,
      taskId: taskId,
      imageId: imageId,
      indexNo: 1,
      path: file.path,
      x: 0,
      y: 0,
      width: 4 + index,
      height: 3 + index,
      selected: true,
    );
  final generationId = 'legacy-generation-$index';
  database
    ..insertImageGenerationRecord(
      id: generationId,
      boardId: boardId ?? 'legacy-board-$index',
      slotIndex: index - 1,
      sourceAssetId: 'source-$index',
      sourcePath: file.path,
      model: 'legacy-model',
      prompt: '旧版修改',
      aspectRatio: '16:9',
      imageSize: '1K',
      quality: 'auto',
      referencePathsJson: '[]',
      status: 'running',
    )
    ..updateImageGenerationRecord(
      id: generationId,
      status: 'success',
      resultAssetId: assetId,
      resultPath: file.path,
    );
  return StoryboardCutAsset(
    id: assetId,
    imageId: imageId,
    sourceName: 'AI修改_旧图$index.png',
    path: file.path,
    indexNo: 1,
  );
}

Future<StoryboardCutAsset> _registerLegacyManualReplacementAsset(
  AppDatabase database,
  AppDirectories directories,
  String boardId,
  int index,
) async {
  final legacyDirectory = Directory(
    p.join(directories.generatedImages.path, boardId, 'manual_replacements'),
  );
  await legacyDirectory.create(recursive: true);
  final file = File(p.join(legacyDirectory.path, 'legacy-$index.png'));
  await file.writeAsBytes(
    img.encodePng(img.Image(width: 4 + index, height: 3 + index)),
  );
  final imageId = 'legacy-replacement-image-$index';
  final taskId = 'legacy-replacement-task-$index';
  final assetId = 'replacement-cut-legacy-$index';
  final now = DateTime.now().add(Duration(seconds: index)).toIso8601String();
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: file.path,
      originalName: '手动替换_旧图$index.png',
      storedPath: file.path,
      width: 4 + index,
      height: 3 + index,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'manual-replacement',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: assetId,
      taskId: taskId,
      imageId: imageId,
      indexNo: 1,
      path: file.path,
      x: 0,
      y: 0,
      width: 4 + index,
      height: 3 + index,
      selected: true,
    );
  return StoryboardCutAsset(
    id: assetId,
    imageId: imageId,
    sourceName: '手动替换_旧图$index.png',
    path: file.path,
    indexNo: 1,
  );
}

StoryboardCutAsset _asset(int index) {
  return StoryboardCutAsset(
    id: 'asset-$index',
    imageId: 'image-1',
    sourceName: 'grid.png',
    path: 'cut-$index.png',
    indexNo: index,
  );
}

({double cellWidth, double rowBandHeight}) _boardGridMetrics(
  StoryboardBoard board,
) {
  final columns = board.columns <= 0 ? 1 : board.columns;
  final rows = board.rows <= 0 ? 1 : board.rows;
  return (
    cellWidth: (board.width - board.gap * (columns + 1)) / columns,
    rowBandHeight: (board.height - board.gap * (rows + 1)) / rows,
  );
}

Future<StoryboardCutAsset> _registeredAsset(
  AppDatabase database,
  Directory root,
  int index,
) async {
  final file = File(p.join(root.path, 'cut-$index.png'));
  await file.writeAsBytes([index]);
  final now = DateTime.now().toIso8601String();
  final imageId = 'image-$index';
  final taskId = 'task-$index';
  final resultId = 'asset-$index';
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: p.join(root.path, 'source-$index.png'),
      originalName: 'source-$index.png',
      storedPath: p.join(root.path, 'source-$index.png'),
      width: 100,
      height: 100,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'exported',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: resultId,
      taskId: taskId,
      imageId: imageId,
      indexNo: index,
      path: file.path,
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      selected: true,
    );
  return StoryboardCutAsset(
    id: resultId,
    imageId: imageId,
    sourceName: 'source-$index.png',
    path: file.path,
    indexNo: index,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待条件超时');
}

List<String> _itemIds(StoryboardController controller) {
  return controller.value.selectedBoard!.items
      .map((item) => item.asset.id)
      .toList();
}

List<String?> _slotIds(StoryboardController controller, int count) {
  final board = controller.value.selectedBoard!;
  return [
    for (var slotIndex = 0; slotIndex < count; slotIndex++)
      board.itemAtSlot(slotIndex)?.asset.id,
  ];
}

class _FakeVisionStoryboardService extends VisionStoryboardService {
  _FakeVisionStoryboardService({
    List<int> order = const [1, 2],
    Object? orderError,
    Object? captionRewriteError,
    List<int> captionFallbackSequenceNos = const [],
    VisionImageRecoveryMode analysisRecoveryMode = VisionImageRecoveryMode.none,
  }) : _order = order,
       _orderError = orderError,
       _captionRewriteError = captionRewriteError,
       _captionFallbackSequenceNos = captionFallbackSequenceNos,
       _analysisRecoveryMode = analysisRecoveryMode;

  final List<int> _order;
  final Object? _orderError;
  final Object? _captionRewriteError;
  final List<int> _captionFallbackSequenceNos;
  final VisionImageRecoveryMode _analysisRecoveryMode;
  int analyzeImageCount = 0;
  int orderRequestCount = 0;
  int suggestRequestCount = 0;
  String lastCurrentCaption = '';
  String lastStoryboardSummary = '';
  VisionImageAnalysis? lastCurrentAnalysis;
  VisionImageAnalysis? lastPreviousAnalysis;
  VisionImageAnalysis? lastNextAnalysis;
  List<VisionImageAnalysis> lastSuggestionAnalyses = const [];

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    analyzeImageCount++;
    if (_analysisRecoveryMode != VisionImageRecoveryMode.none) {
      onRecovery?.call(_analysisRecoveryMode);
    }
    return VisionImageAnalysis(
      caption: '镜头$sequenceNo',
      detail: '第 $sequenceNo 张图的详细内容',
      scene: '测试场景',
      props: '测试道具',
      people: '测试人物',
      expression: '神态$sequenceNo',
      bodyAction: sequenceNo == 1 ? '站立观察' : '扶椅起身',
      movementTrend: sequenceNo == 1 ? '向右行走' : '准备起身',
      shotSize: sequenceNo == 1 ? '全景' : '中景',
      composition: sequenceNo == 1 ? '人物位于画面左侧' : '人物与椅子位于画面中央',
      subjectDirection: sequenceNo == 1 ? '面向右侧' : '身体朝右',
      gazeDirection: sequenceNo == 1 ? '看向画面右侧' : '看向椅子方向',
      actionStage: sequenceNo == 1 ? '建立' : '准备',
      spatialRelation: sequenceNo == 1 ? '人物站在场景左侧' : '人物靠近椅子',
      chronologyCue: sequenceNo == 1 ? '开场建立' : '动作前',
      cameraAngle: sequenceNo == 1 ? '眼平全景' : '眼平中景',
      visualFocus: sequenceNo == 1 ? '人物进入场景的位置' : '人物扶椅起身的手部动作',
      lightingMood: sequenceNo == 1 ? '均匀自然光' : '柔和室内光',
      colorPalette: sequenceNo == 1 ? '中性灰绿' : '暖灰与木色',
      narrativeFunction: sequenceNo == 1 ? '建立' : '推进',
      transitionHint: sequenceNo == 1 ? '适合开场' : '适合承接上一动作',
      recoveryMode: _analysisRecoveryMode,
      requestCount: _analysisRecoveryMode == VisionImageRecoveryMode.none
          ? 1
          : 2,
      recoveryErrors: _analysisRecoveryMode == VisionImageRecoveryMode.none
          ? const []
          : const ['测试恢复错误'],
      rawResponse: '{"caption":"镜头$sequenceNo"}',
    );
  }

  @override
  Future<VisionStoryboardSummaryResult> summarizeStoryboard({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
  }) async {
    return const VisionStoryboardSummaryResult(
      outline: '测试大纲',
      content: '测试内容',
      scenes: '测试场景',
      props: '测试道具',
      rawResponse: '{"outline":"测试大纲"}',
    );
  }

  @override
  Future<VisionStoryboardCaptionRewriteResult> rewriteStoryboardCaptions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    void Function(int completed, int total)? onProgress,
  }) async {
    onProgress?.call(1, 1);
    final error = _captionRewriteError;
    if (error != null) {
      throw error;
    }
    return VisionStoryboardCaptionRewriteResult(
      captions: [
        for (var i = 0; i < analyses.length; i++)
          if (_captionFallbackSequenceNos.contains(i + 1))
            analyses[i].caption
          else if (i == 0)
            '开场${analyses[i].caption}。'
          else
            '随后${analyses[i].caption}。',
      ],
      rawResponse: '{"captions":["开场镜头1。","随后镜头2。"]}',
      initialReturnedCount:
          analyses.length - _captionFallbackSequenceNos.length,
      fallbackSequenceNos: _captionFallbackSequenceNos,
    );
  }

  @override
  Future<VisionStoryboardOrderResult> suggestStoryboardOrder({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
  }) async {
    orderRequestCount++;
    final error = _orderError;
    if (error != null) {
      throw error;
    }
    return VisionStoryboardOrderResult(order: _order, rawResponse: '{}');
  }

  @override
  Future<VisionImageEditSuggestion> suggestImageEditPrompt({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String currentCaption,
    required String previousCaption,
    required String nextCaption,
    required String rowCaption,
    required String storyboardSummary,
    required VisionImageAnalysis currentAnalysis,
    required VisionImageAnalysis? previousAnalysis,
    required VisionImageAnalysis? nextAnalysis,
    required List<VisionImageAnalysis> storyboardAnalyses,
  }) async {
    suggestRequestCount++;
    lastCurrentCaption = currentCaption;
    lastStoryboardSummary = storyboardSummary;
    lastCurrentAnalysis = currentAnalysis;
    lastPreviousAnalysis = previousAnalysis;
    lastNextAnalysis = nextAnalysis;
    lastSuggestionAnalyses = List.unmodifiable(storyboardAnalyses);
    return VisionImageEditSuggestion(
      advice: '建议优化第 $sequenceNo 张',
      prompt: '保留原图主体，强化${currentAnalysis.caption}的镜头连续性。',
      rawResponse: '{}',
    );
  }
}

class _CancellableVisionStoryboardService extends _FakeVisionStoryboardService {
  _CancellableVisionStoryboardService({super.order});

  final orderStarted = Completer<void>();
  final _orderBlocker = Completer<void>();
  var cancelCalled = false;

  @override
  Future<VisionStoryboardOrderResult> suggestStoryboardOrder({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
  }) async {
    orderRequestCount++;
    if (!orderStarted.isCompleted) {
      orderStarted.complete();
    }
    await _orderBlocker.future;
    return super.suggestStoryboardOrder(settings: settings, analyses: analyses);
  }

  @override
  void cancelActiveRequests() {
    cancelCalled = true;
    if (!_orderBlocker.isCompleted) {
      _orderBlocker.completeError(const FormatException('cancelled'));
    }
  }
}

class _BlockingVisionStoryboardService extends _FakeVisionStoryboardService {
  final analysisStarted = Completer<void>();
  final _analysisBlocker = Completer<void>();

  void releaseAnalysis() {
    if (!_analysisBlocker.isCompleted) {
      _analysisBlocker.complete();
    }
  }

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    if (!analysisStarted.isCompleted) {
      analysisStarted.complete();
    }
    await _analysisBlocker.future;
    return super.analyzeImage(
      settings: settings,
      imageFile: imageFile,
      sequenceNo: sequenceNo,
      rowIndex: rowIndex,
      columnIndex: columnIndex,
      onRecovery: onRecovery,
    );
  }
}

class _FakeImageGenerationService extends ImageGenerationService {
  _FakeImageGenerationService(this.root);

  final Directory root;
  ImageGenerationRequest? lastRequest;
  String resultPath = '';

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) async {
    lastRequest = request;
    if (!request.outputDirectory.existsSync()) {
      await request.outputDirectory.create(recursive: true);
    }
    final image = img.Image(width: 16, height: 10);
    img.fill(image, color: img.ColorRgb8(80, 120, 160));
    final file = File(p.join(request.outputDirectory.path, 'fake_result.png'));
    await file.writeAsBytes(img.encodePng(image));
    await File('${file.path}.json').writeAsString(
      '{"status":"succeeded","payloadOmissions":{"imagePayloadCount":1}}',
    );
    resultPath = file.path;
    return ImageGenerationResult(
      localPath: file.path,
      remoteUrl: 'https://files.example/fake_result.png',
      rawResponse: '{"status":"succeeded"}',
    );
  }

  @override
  void close() {}
}

class _BlockingImageGenerationService extends _FakeImageGenerationService {
  _BlockingImageGenerationService(super.root);

  final requestStarted = Completer<void>();
  final _blocker = Completer<void>();

  void release() {
    if (!_blocker.isCompleted) {
      _blocker.complete();
    }
  }

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) async {
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    await _blocker.future;
    return super.generateEditedImage(request);
  }
}

class _ConcurrentImageGenerationService extends _FakeImageGenerationService {
  _ConcurrentImageGenerationService(super.root);

  final bothStarted = Completer<void>();
  final requests = <ImageGenerationRequest>[];
  final _blockers = <Completer<void>>[];

  void releaseAll() {
    for (final blocker in _blockers) {
      if (!blocker.isCompleted) {
        blocker.complete();
      }
    }
  }

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) async {
    final requestIndex = requests.length;
    requests.add(request);
    final blocker = Completer<void>();
    _blockers.add(blocker);
    if (requests.length == 2 && !bothStarted.isCompleted) {
      bothStarted.complete();
    }
    await blocker.future;
    await request.outputDirectory.create(recursive: true);
    final image = img.Image(width: 16, height: 10);
    img.fill(image, color: img.ColorRgb8(80 + requestIndex, 120, 160));
    final file = File(
      p.join(request.outputDirectory.path, 'concurrent-$requestIndex.png'),
    );
    await file.writeAsBytes(img.encodePng(image));
    return ImageGenerationResult(
      localPath: file.path,
      remoteUrl: 'https://files.example/concurrent-$requestIndex.png',
      rawResponse: '{"status":"succeeded"}',
    );
  }
}
