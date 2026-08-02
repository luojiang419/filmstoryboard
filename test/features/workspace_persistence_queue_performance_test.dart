import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/core/services/workspace_snapshot_save_queue.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';

void main() {
  test('revision 队列连续标记 100 次只写最终快照', () async {
    var state = 0;
    final snapshots = <String>[];
    late final WorkspaceSnapshotSaveQueue queue;
    queue = WorkspaceSnapshotSaveQueue(
      buildSnapshot: () {
        if (state == 100) {
          state = 101;
          queue.markDirty();
        }
        return '$state';
      },
      writeSnapshot: snapshots.add,
    );
    addTearDown(queue.dispose);

    for (var revision = 1; revision <= 100; revision++) {
      state = revision;
      queue.markDirty();
    }
    queue.flush();

    expect(snapshots, ['101']);
    expect(queue.hasPendingSave, isFalse);
  });

  test('故事板连续切换 100 次不重写完整工作区且恢复最终选择', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_persistence_queue_',
    );
    final writes = <String, int>{};
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
      settingWriteObserver: (key) =>
          writes.update(key, (count) => count + 1, ifAbsent: () => 1),
    );
    final controller = StoryboardController(database: database)..addBoard();
    controller.flushWorkspaceSnapshot();
    writes.clear();
    final boardIds = controller.value.boards.map((board) => board.id).toList();

    for (var index = 0; index < 100; index++) {
      controller.selectBoard(boardIds[index.isEven ? 0 : 1]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(writes['storyboardWorkspaceSnapshot'] ?? 0, lessThanOrEqualTo(1));
    expect(writes['storyboardWorkspaceSelection'], 1);
    expect(controller.value.selectedBoardId, boardIds[1]);
    controller.dispose();

    final restored = StoryboardController(database: database);
    addTearDown(() async {
      restored.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    expect(restored.value.boards, hasLength(2));
    expect(restored.value.selectedBoardId, boardIds[1]);
  });

  test('故事板快照恢复打开顺序、全部关闭状态和编组', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_board_manager_persistence_',
    );
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    final controller = StoryboardController(database: database)..addBoard();
    final boardIds = controller.value.boards.map((board) => board.id).toList();
    final groupId = controller.createBoardGroup('第一组')!;
    controller.assignBoardsToGroup([boardIds.last], groupId);
    controller.closeBoard(boardIds.first);
    controller.flushWorkspaceSnapshot();
    controller.dispose();

    var restored = StoryboardController(database: database);
    expect(restored.value.openBoardIds, [boardIds.last]);
    expect(restored.value.selectedBoardId, boardIds.last);
    expect(restored.value.boardGroups.single.name, '第一组');
    expect(restored.value.boards.last.groupId, groupId);

    restored.closeBoard(boardIds.last);
    restored.flushWorkspaceSnapshot();
    restored.dispose();
    restored = StoryboardController(database: database);
    addTearDown(() async {
      restored.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    expect(restored.value.openBoardIds, isEmpty);
    expect(restored.value.selectedBoardId, isNull);
    expect(restored.value.boards, hasLength(2));
  });

  test('旧版工作区快照迁移时默认打开全部画板', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_legacy_snapshot_',
    );
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    database.setSetting(
      'storyboardWorkspaceSnapshot',
      jsonEncode({
        'version': 1,
        'selectedBoardId': 'legacy-b',
        'boards': [
          {'id': 'legacy-a', 'name': '旧画板 A', 'items': <Object?>[]},
          {'id': 'legacy-b', 'name': '旧画板 B', 'items': <Object?>[]},
        ],
      }),
    );
    final controller = StoryboardController(database: database);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    expect(controller.value.openBoardIds, ['legacy-a', 'legacy-b']);
    expect(controller.value.selectedBoardId, 'legacy-b');
  });

  test('裁切任务连续切换 100 次不重写完整工作区且恢复最终选择', () async {
    final root = await Directory.systemTemp.createTemp(
      'grid_cut_persistence_queue_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final writes = <String, int>{};
    final database = await AppDatabase.open(
      directories.databaseFile,
      settingWriteObserver: (key) =>
          writes.update(key, (count) => count + 1, ifAbsent: () => 1),
    );
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final controller = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    final imagePaths = await _createImages(root, 2);
    await controller.importPaths(imagePaths);
    controller.flushWorkspaceSnapshot();
    writes.clear();
    final imageIds = controller.value.images.map((image) => image.id).toList();

    for (var index = 0; index < 100; index++) {
      controller.selectImage(imageIds[index.isEven ? 0 : 1]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(writes['gridCutWorkspaceSnapshot'] ?? 0, lessThanOrEqualTo(1));
    expect(writes['gridCutWorkspaceSelection'], 1);
    expect(controller.value.selectedImageId, imageIds[1]);
    controller.dispose();

    final restored = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(() async {
      restored.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    expect(restored.value.images, hasLength(2));
    expect(restored.value.selectedImageId, imageIds[1]);
  });
}

Future<List<String>> _createImages(Directory root, int count) async {
  final paths = <String>[];
  for (var index = 0; index < count; index++) {
    final image = img.Image(width: 20, height: 20);
    img.fill(image, color: img.ColorRgb8(80 + index * 30, 120, 160));
    final file = File(p.join(root.path, 'source-$index.png'));
    await file.writeAsBytes(img.encodePng(image));
    paths.add(file.path);
  }
  return paths;
}
