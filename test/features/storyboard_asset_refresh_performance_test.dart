import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';

void main() {
  test('1500 项资源刷新保持事件循环心跳并批量清理缺失记录', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_asset_refresh_',
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

    const missingResultCount = 1300;
    const folderAssetCount = 200;
    _insertMissingCutResults(database, root, missingResultCount);
    final folder = Directory(p.join(directories.storyboardFolders.path, '性能资源'))
      ..createSync(recursive: true);
    for (var index = 0; index < folderAssetCount; index++) {
      File(
        p.join(folder.path, 'frame-${index.toString().padLeft(4, '0')}.png'),
      ).writeAsBytesSync([index & 0xff]);
    }

    var notifications = 0;
    controller.addListener(() => notifications++);
    var heartbeatRan = false;
    Timer.run(() => heartbeatRan = true);

    final firstRefresh = controller.refreshAssets();
    final duplicateRefresh = controller.refreshAssets();
    expect(duplicateRefresh, same(firstRefresh));
    await firstRefresh;

    expect(heartbeatRan, isTrue);
    expect(notifications, 1);
    expect(database.listCutResults(), isEmpty);
    expect(controller.value.assets, isEmpty);
    expect(controller.value.folders, hasLength(1));
    expect(controller.value.folders.single.assets, hasLength(folderAssetCount));
    expect(
      controller.value.folders.single.assets.first.path,
      endsWith('frame-0000.png'),
    );
    expect(
      controller.value.folders.single.assets.last.path,
      endsWith('frame-0199.png'),
    );
  });

  test('资源变化期间重复通知最多合并为一次补充扫描', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_asset_refresh_queue_',
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

    var notifications = 0;
    controller.addListener(() => notifications++);
    final refresh = controller.refreshAssets();
    controller
      ..handleCutResultsChanged()
      ..handleCutResultsChanged()
      ..handleCutResultsChanged();
    await refresh;

    expect(notifications, 2);
    expect(controller.value.message, '裁切结果已更新，资源已刷新');
  });

  test('增量缓存驱逐只返回新增、删除和签名变化路径', () {
    final changed = changedStoryboardAssetImagePaths(
      const {
        'same.png': 'same-signature',
        'changed.png': 'old-signature',
        'removed.png': 'removed-signature',
      },
      const {
        'same.png': 'same-signature',
        'changed.png': 'new-signature',
        'added.png': 'added-signature',
      },
    );

    expect(changed, {'changed.png', 'removed.png', 'added.png'});
  });
}

void _insertMissingCutResults(AppDatabase database, Directory root, int count) {
  const imageId = 'performance-image';
  const taskId = 'performance-task';
  final now = DateTime(2026).toIso8601String();
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: p.join(root.path, 'source.png'),
      originalName: 'source.png',
      storedPath: p.join(root.path, 'source.png'),
      width: 100,
      height: 100,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'exported',
      rows: 1,
      columns: count,
      confidence: 1,
    );
  for (var index = 0; index < count; index++) {
    database.insertCutResult(
      id: 'missing-$index',
      taskId: taskId,
      imageId: imageId,
      indexNo: index + 1,
      path: p.join(root.path, 'missing', 'frame-$index.png'),
      x: index,
      y: 0,
      width: 1,
      height: 1,
      selected: true,
    );
  }
}
