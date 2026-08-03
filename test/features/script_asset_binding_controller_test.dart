import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('从资产库加入指定镜头会创建已确认且锁定的绑定', () async {
    final root = await Directory.systemTemp.createTemp('asset_binding_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsController = SettingsController(
      repository: SettingsRepository(database, directories),
      initialSettings: SettingsRepository(database, directories).load(),
    );
    final scriptController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final script = scriptController.createEmpty(name: '绑定测试脚本');
    final shot = scriptController.addShot()!;
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final source = File(p.join(root.path, 'hero.png'));
    await source.writeAsBytes([1, 2, 3]);
    final item = await libraryController.importItem(
      sourcePath: source.path,
      type: ReplicateAssetType.character,
      name: '主角',
      description: '白衬衫短发',
    );
    expect(item, isNotNull);
    final bindingController = ShootingScriptAssetBindingController(
      shootingScriptController: scriptController,
      libraryController: libraryController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
    );
    addTearDown(() {
      bindingController.dispose();
      libraryController.dispose();
      scriptController.dispose();
      settingsController.dispose();
    });

    await bindingController.addLibraryAssetToShot(item!, shot.id);

    expect(bindingController.value.scriptId, script.id);
    expect(bindingController.value.assets, hasLength(1));
    final link = bindingController.value.links.single;
    expect(link.shotId, shot.id);
    expect(link.confirmed, isTrue);
    expect(link.locked, isTrue);
    expect(link.matchSource, ScriptAssetMatchSource.manual);
  });
}
