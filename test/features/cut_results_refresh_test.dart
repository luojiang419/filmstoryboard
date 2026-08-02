import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('裁切结果通知会驱动故事板资源自动刷新', () async {
    final root = await Directory.systemTemp.createTemp('cut_results_refresh_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWithValue(directories),
        appDatabaseProvider.overrideWithValue(database),
        settingsControllerProvider.overrideWithValue(settingsController),
      ],
    );
    addTearDown(() async {
      container.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final controller = container.read(storyboardControllerProvider);
    expect(controller.value.assets, isEmpty);

    final cutPath = await _writeImage(root, 'cut_1.png');
    _insertCutResult(database, cutPath);

    container.read(cutResultsChangeNotifierProvider).value++;
    await controller.refreshAssets();

    expect(controller.value.assets, hasLength(1));
    expect(controller.value.assets.single.path, cutPath);
    expect(controller.value.message, '裁切结果已更新，资源已刷新');
  });
}

Future<String> _writeImage(Directory root, String name) async {
  final image = img.Image(width: 24, height: 18);
  img.fill(image, color: img.ColorRgb8(100, 140, 180));
  final file = File(p.join(root.path, name));
  await file.writeAsBytes(img.encodePng(image));
  return file.path;
}

void _insertCutResult(AppDatabase database, String path) {
  final now = DateTime.now().toIso8601String();
  database
    ..upsertImportedImage(
      id: 'image-1',
      originalPath: path,
      originalName: p.basename(path),
      storedPath: path,
      width: 24,
      height: 18,
      createdAt: now,
    )
    ..upsertCutTask(
      id: 'task-1',
      imageId: 'image-1',
      status: 'exported',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: 'cut-1',
      taskId: 'task-1',
      imageId: 'image-1',
      indexNo: 1,
      path: path,
      x: 0,
      y: 0,
      width: 24,
      height: 18,
      selected: true,
    );
}
