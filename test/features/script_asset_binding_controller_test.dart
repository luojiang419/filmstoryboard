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
import 'package:filmstoryboard/features/shooting_script/domain/script_asset_slot_policy.dart';
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

    await bindingController.addLibraryAssetToShot(
      item!,
      shot.id,
      slotSortOrder: ScriptAssetSlotPolicy.characterSortOrderBase + 1,
      slotLabel: '模特B',
    );

    expect(bindingController.value.scriptId, script.id);
    expect(bindingController.value.assets, hasLength(1));
    final link = bindingController.value.links.single;
    expect(link.shotId, shot.id);
    expect(link.confirmed, isTrue);
    expect(link.locked, isTrue);
    expect(link.matchSource, ScriptAssetMatchSource.manual);
    expect(link.sortOrder, 1001);
    expect(link.matchReason, contains('模特B'));

    bindingController.refresh();
    expect(bindingController.value.links.single.sortOrder, 1001);
  });

  test('自动匹配会按识别数量把单人物的三个产品写入产品A到产品C槽位', () async {
    final root = await Directory.systemTemp.createTemp('asset_auto_slot_');
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
    scriptController.createEmpty(name: '自动槽位测试脚本');
    final shot = scriptController.addShot()!;
    scriptController.updateShot(
      shot.copyWith(content: '一位女模特展示白色套装、红色连衣裙和蓝色牛仔裤'),
    );
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final modelFile = File(p.join(root.path, 'female-model.png'));
    final productFile = File(p.join(root.path, 'product.png'));
    final productBFile = File(p.join(root.path, 'product-b.png'));
    final productCFile = File(p.join(root.path, 'product-c.png'));
    await modelFile.writeAsBytes([1, 2, 3]);
    await productFile.writeAsBytes([4, 5, 6]);
    await productBFile.writeAsBytes([7, 8, 9]);
    await productCFile.writeAsBytes([10, 11, 12]);
    await libraryController.importItem(
      sourcePath: modelFile.path,
      type: ReplicateAssetType.reference,
      name: '女模特',
      description: '人物全身综合参考',
    );
    await libraryController.importItem(
      sourcePath: productFile.path,
      type: ReplicateAssetType.reference,
      name: '白色套装',
      description: '白色套装产品参考',
    );
    await libraryController.importItem(
      sourcePath: productBFile.path,
      type: ReplicateAssetType.reference,
      name: '红色连衣裙',
      description: '第二位模特服装产品参考',
    );
    await libraryController.importItem(
      sourcePath: productCFile.path,
      type: ReplicateAssetType.reference,
      name: '蓝色牛仔裤',
      description: '第三件服装产品参考',
    );
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

    await bindingController.autoMatchShot(shot.id, maximumProductCount: 3);

    final assetsByName = {
      for (final asset in bindingController.value.assets) asset.name: asset,
    };
    final linksByAssetId = {
      for (final link in bindingController.value.links)
        link.scriptAssetId: link,
    };
    expect(assetsByName['女模特']?.type, ReplicateAssetType.character);
    expect(assetsByName['白色套装']?.type, ReplicateAssetType.product);
    expect(assetsByName['红色连衣裙']?.type, ReplicateAssetType.product);
    expect(assetsByName['蓝色牛仔裤']?.type, ReplicateAssetType.product);
    expect(
      linksByAssetId[assetsByName['女模特']!.id]?.sortOrder,
      ScriptAssetSlotPolicy.characterSortOrderBase,
    );
    expect(
      {
        linksByAssetId[assetsByName['白色套装']!.id]?.sortOrder,
        linksByAssetId[assetsByName['红色连衣裙']!.id]?.sortOrder,
        linksByAssetId[assetsByName['蓝色牛仔裤']!.id]?.sortOrder,
      },
      {
        ScriptAssetSlotPolicy.productSortOrder,
        ScriptAssetSlotPolicy.productSortOrderForIndex(1),
        ScriptAssetSlotPolicy.productSortOrderForIndex(2),
      },
    );
    expect(
      linksByAssetId.values.map((link) => link.sortOrder),
      isNot(contains(ScriptAssetSlotPolicy.productDetailSortOrder)),
    );
  });
}
