import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/grid_cut/domain/grid_cut_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:test/test.dart';

void main() {
  test('导入图片按项目名称和导入顺序规范化命名', () async {
    final fixture = await _createFixture(projectName: '广告项目');
    final paths = await _createImages(fixture.root, 3);

    await fixture.controller.importPaths(paths);

    expect(fixture.controller.value.images.map((image) => image.originalName), [
      '广告项目1.png',
      '广告项目2.png',
      '广告项目3.png',
    ]);

    fixture.controller.removeImageTask(fixture.controller.value.images[1].id);
    await fixture.controller.importPaths([paths.first]);

    expect(fixture.controller.value.selectedImage?.originalName, '广告项目4.png');
  });

  test('移除图片任务会更新任务列表并保持合理选中项', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 3);

    await fixture.controller.importPaths(paths);

    final ids = fixture.controller.value.images
        .map((image) => image.id)
        .toList();
    expect(ids, hasLength(3));
    expect(fixture.controller.value.selectedImageId, ids[2]);

    fixture.controller.removeImageTask(ids[2]);

    expect(fixture.controller.value.images.map((image) => image.id), [
      ids[0],
      ids[1],
    ]);
    expect(fixture.controller.value.selectedImageId, ids[1]);
    expect(fixture.controller.value.selectedImage?.id, ids[1]);

    fixture.controller.selectImage(ids[0]);
    fixture.controller.removeImageTask(ids[1]);

    expect(fixture.controller.value.images.map((image) => image.id), [ids[0]]);
    expect(fixture.controller.value.selectedImageId, ids[0]);

    fixture.controller.removeImageTask(ids[0]);

    expect(fixture.controller.value.images, isEmpty);
    expect(fixture.controller.value.selectedImageId, isNull);
    expect(fixture.controller.value.selectedImage, isNull);
  });

  test('清空图片任务栏会移除当前导入的全部图片', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 2);

    await fixture.controller.importPaths(paths);

    expect(fixture.controller.value.images, hasLength(2));

    fixture.controller.clearImageTasks();

    expect(fixture.controller.value.images, isEmpty);
    expect(fixture.controller.value.selectedImageId, isNull);
    expect(fixture.controller.value.selectedImage, isNull);
    expect(fixture.controller.value.message, '已清空 2 张图片任务');
  });

  test('图片任务支持前后循环切换选中项', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 3);

    await fixture.controller.importPaths(paths);

    final ids = fixture.controller.value.images
        .map((image) => image.id)
        .toList();
    expect(fixture.controller.value.selectedImageId, ids[2]);

    expect(fixture.controller.selectAdjacentImage(-1), isTrue);
    expect(fixture.controller.value.selectedImageId, ids[1]);
    expect(fixture.controller.value.selectedImage?.originalName, '项目2.png');

    expect(fixture.controller.selectAdjacentImage(1), isTrue);
    expect(fixture.controller.value.selectedImageId, ids[2]);

    expect(fixture.controller.selectAdjacentImage(1), isTrue);
    expect(fixture.controller.value.selectedImageId, ids[0]);
    expect(fixture.controller.value.message, contains('1/3'));
  });

  test('导入和调整布局默认不选中宫格且清空仍可用', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 1);

    await fixture.controller.importPaths(paths);

    expect(fixture.controller.value.selectedImage!.selectedCells, isEmpty);

    fixture.controller.setEvenGrid(2, 2);
    expect(fixture.controller.value.selectedImage!.selectedCells, isEmpty);

    fixture.controller.toggleCell(1, selected: true);
    expect(fixture.controller.value.selectedImage!.selectedCells, {1});

    fixture.controller.clearCellSelection();
    expect(fixture.controller.value.selectedImage!.selectedCells, isEmpty);

    fixture.controller.insertVerticalLine(5);
    expect(fixture.controller.value.selectedImage!.selectedCells, isEmpty);

    fixture.controller.insertHorizontalLine(5);
    expect(fixture.controller.value.selectedImage!.selectedCells, isEmpty);
  });

  test('保存后重新创建控制器会恢复裁切任务状态', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 1);

    await fixture.controller.importPaths(paths);
    fixture.controller.setEvenGrid(1, 1);
    fixture.controller.insertVerticalLine(10);
    fixture.controller.insertHorizontalLine(10);
    fixture.controller.clearCellSelection();
    fixture.controller.toggleCell(3, selected: true);
    await fixture.controller.exportSelectedImage();

    final savedImage = fixture.controller.value.selectedImage!;
    expect(savedImage.layout.xLines, [0, 10, 20]);
    expect(savedImage.layout.yLines, [0, 10, 20]);
    expect(savedImage.selectedCells, {3});
    expect(savedImage.exportedPaths, isNotEmpty);
    fixture.controller.flushWorkspaceSnapshot();
    final persistedSnapshot = fixture.database.getSetting(
      'gridCutWorkspaceSnapshot',
    )!;
    expect(persistedSnapshot, contains('imports/'));
    expect(persistedSnapshot, isNot(contains(fixture.root.path)));

    final restored = GridCutController(
      directories: await AppDirectories.create(
        executableDirectory: fixture.root,
      ),
      database: fixture.database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(restored.dispose);

    final restoredImage = restored.value.selectedImage!;
    expect(restored.value.images, hasLength(1));
    expect(restored.value.selectedImageId, savedImage.id);
    expect(restoredImage.id, savedImage.id);
    expect(restoredImage.taskId, savedImage.taskId);
    expect(restoredImage.storedPath, savedImage.storedPath);
    expect(restoredImage.layout.xLines, savedImage.layout.xLines);
    expect(restoredImage.layout.yLines, savedImage.layout.yLines);
    expect(restoredImage.selectedCells, savedImage.selectedCells);
    expect(restoredImage.exportedPaths, savedImage.exportedPaths);
  });

  test('打开不存在的导出文件夹不会创建空 cuts 子目录', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 1);

    await fixture.controller.importPaths(paths);
    final image = fixture.controller.value.selectedImage!;
    final folder = Directory(
      p.join(fixture.root.path, 'data', 'cuts', image.baseName),
    );
    expect(folder.existsSync(), isFalse);

    await fixture.controller.openExportFolder();

    expect(folder.existsSync(), isFalse);
    expect(fixture.controller.value.message, '导出文件夹不存在，请先裁切图片');
  });

  test('图片任务编组会移动任务并随工作区恢复', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 3);

    await fixture.controller.importPaths(paths);
    final ids = fixture.controller.value.images
        .map((image) => image.id)
        .toList();

    fixture.controller.groupImageTasks('第一组', [ids[0], ids[2]]);
    expect(fixture.controller.value.taskGroups, hasLength(1));
    expect(fixture.controller.value.taskGroups.single.name, '第一组');
    expect(fixture.controller.value.taskGroups.single.imageIds, [
      ids[0],
      ids[2],
    ]);

    fixture.controller.groupImageTasks('第二组', [ids[2]]);
    expect(fixture.controller.value.taskGroups.map((group) => group.name), [
      '第一组',
      '第二组',
    ]);
    expect(fixture.controller.value.taskGroups.first.imageIds, [ids[0]]);
    expect(fixture.controller.value.taskGroups.last.imageIds, [ids[2]]);

    final secondGroupId = fixture.controller.value.taskGroups.last.id;
    fixture.controller.toggleTaskGroupExpanded(secondGroupId);
    fixture.controller.flushWorkspaceSnapshot();

    final restored = GridCutController(
      directories: await AppDirectories.create(
        executableDirectory: fixture.root,
      ),
      database: fixture.database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(restored.dispose);

    expect(restored.value.taskGroups, hasLength(2));
    expect(restored.value.taskGroups.first.imageIds, [ids[0]]);
    expect(restored.value.taskGroups.last.imageIds, [ids[2]]);
    expect(restored.value.taskGroups.last.expanded, isFalse);
  });

  test('图片任务支持跨层拖拽重排并持久化统一顺序', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 4);
    await fixture.controller.importPaths(paths);
    final ids = fixture.controller.value.images
        .map((image) => image.id)
        .toList();

    fixture.controller.groupImageTasks('镜头组', [ids[0], ids[1]]);
    final group = fixture.controller.value.taskGroups.single;
    final groupKey = GridCutTaskNodeRef.group(group.id).key;
    final fourthKey = GridCutTaskNodeRef.image(ids[3]).key;

    expect(
      fixture.controller.moveTaskNode(fourthKey, beforeNodeKey: groupKey),
      isTrue,
    );
    expect(fixture.controller.value.taskOrder.first, fourthKey);

    expect(
      fixture.controller.moveTaskNode(
        GridCutTaskNodeRef.image(ids[2]).key,
        targetGroupId: group.id,
        beforeNodeKey: GridCutTaskNodeRef.image(ids[0]).key,
      ),
      isTrue,
    );
    expect(fixture.controller.value.taskGroups.single.imageIds, [
      ids[2],
      ids[0],
      ids[1],
    ]);
    expect(fixture.controller.value.images.map((image) => image.id), [
      ids[3],
      ids[2],
      ids[0],
      ids[1],
    ]);

    fixture.controller.flushWorkspaceSnapshot();
    final restored = GridCutController(
      directories: await AppDirectories.create(
        executableDirectory: fixture.root,
      ),
      database: fixture.database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(restored.dispose);

    expect(restored.value.taskOrder, fixture.controller.value.taskOrder);
    expect(restored.value.taskGroups.single.imageIds, [ids[2], ids[0], ids[1]]);
  });

  test('恢复时会移除已丢失的裁切任务图片并保存清理结果', () async {
    final fixture = await _createFixture();
    final paths = await _createImages(fixture.root, 1);

    await fixture.controller.importPaths(paths);
    final storedPath = fixture.controller.value.selectedImage!.storedPath;
    fixture.controller.flushWorkspaceSnapshot();
    await File(storedPath).delete();

    final restored = GridCutController(
      directories: await AppDirectories.create(
        executableDirectory: fixture.root,
      ),
      database: fixture.database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(restored.dispose);

    expect(restored.value.images, isEmpty);
    expect(restored.value.selectedImageId, isNull);
    restored.flushWorkspaceSnapshot();
    expect(
      fixture.database.getSetting('gridCutWorkspaceSnapshot'),
      contains('"images":[]'),
    );
  });
}

Future<
  ({
    Directory root,
    AppDatabase database,
    SettingsController settingsController,
    GridCutController controller,
  })
>
_createFixture({String projectName = '项目'}) async {
  final root = await Directory.systemTemp.createTemp('grid_cut_controller_');
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
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
    projectName: projectName,
  );
  addTearDown(() async {
    controller.dispose();
    settingsController.dispose();
    database.dispose();
    await root.delete(recursive: true);
  });
  return (
    root: root,
    database: database,
    settingsController: settingsController,
    controller: controller,
  );
}

Future<List<String>> _createImages(Directory root, int count) async {
  final paths = <String>[];
  for (var i = 0; i < count; i++) {
    final image = img.Image(width: 20, height: 20);
    img.fill(
      image,
      color: img.ColorRgb8(80 + i * 20, 120 + i * 20, 160 + i * 20),
    );
    final file = File(p.join(root.path, 'source_$i.png'));
    await file.writeAsBytes(img.encodePng(image));
    paths.add(file.path);
  }
  return paths;
}
