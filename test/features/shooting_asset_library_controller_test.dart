import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('常用资产导入、编辑、恢复和删除会持久化到项目库', () async {
    final root = await Directory.systemTemp.createTemp(
      'shooting_asset_library_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = ShootingAssetLibraryRepository(
      database: database,
      directories: directories,
    );
    final controller = ShootingAssetLibraryController(
      repository: repository,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final source = File(p.join(root.path, 'model.png'));
    await source.writeAsBytes([1, 2, 3, 4]);

    final item = await controller.importItem(
      sourcePath: source.path,
      type: ReplicateAssetType.character,
      name: '现代模特',
      description: '短发白衬衫',
    );

    expect(item, isNotNull);
    expect(controller.value.items, hasLength(1));
    expect(controller.value.items.single.name, '现代模特');
    expect(File(controller.value.items.single.path).existsSync(), isTrue);
    expect(controller.value.items.single.path, isNot(source.path));

    controller.updateItem(
      controller.value.items.single.copyWith(description: '短发白衬衫，银色耳饰'),
    );
    expect(controller.value.items.single.description, contains('银色耳饰'));

    final restored = ShootingAssetLibraryController(
      repository: repository,
      directories: directories,
    );
    addTearDown(restored.dispose);
    expect(restored.value.items, hasLength(1));
    expect(restored.value.items.single.description, contains('银色耳饰'));

    final copiedPath = restored.value.items.single.path;
    await restored.deleteItem(restored.value.items.single.id);
    expect(restored.value.items, isEmpty);
    expect(File(copiedPath).existsSync(), isFalse);
  });
}
