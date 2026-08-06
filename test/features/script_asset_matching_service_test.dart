import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/data/script_asset_matching_service.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_asset_library_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('资产标准名称会在本地命中且不调用视觉模型', () async {
    final root = await Directory.systemTemp.createTemp('asset_match_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settings = SettingsRepository(database, directories).load();
    final service = ScriptAssetMatchingService();
    addTearDown(service.close);

    final result = await service.match(
      settings: settings.copyWith(visionApiBaseUrl: ''),
      shot: ScriptShot(
        id: 'shot-1',
        scriptId: 'script-1',
        shotNumber: 1,
        durationSeconds: 2,
        framePath: '',
        visual: '白衬衫模特站在客厅',
        content: '模特拿起银色产品',
        shotSize: '中景',
        cameraMovement: '推镜',
        cameraNotes: '',
        scene: '客厅',
        productCode: '',
        productStyling: '',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.completed,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      assets: [
        ShootingAssetLibraryItem(
          id: 'asset-hero',
          type: ReplicateAssetType.character,
          name: '白衬衫模特',
          description: '短发，白衬衫，成年女性',
          path: '',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        ShootingAssetLibraryItem(
          id: 'asset-scene',
          type: ReplicateAssetType.scene,
          name: '客厅',
          description: '暖色现代客厅',
          path: '',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );

    expect(result.usedModel, isFalse);
    expect(
      result.candidates.map((item) => item.assetId),
      containsAll(['asset-hero', 'asset-scene']),
    );
    expect(
      result.candidates,
      everyElement(
        predicate<ScriptAssetMatchCandidate>((item) => item.confidence == 1),
      ),
    );
  });

  test('别名可命中，重复名称不会自动绑定', () async {
    final root = await Directory.systemTemp.createTemp('asset_match_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settings = SettingsRepository(database, directories).load();
    const service = ScriptAssetMatchingService();

    final result = await service.match(
      settings: settings,
      shot: ScriptShot(
        id: 'shot-1',
        scriptId: 'script-1',
        shotNumber: 1,
        durationSeconds: 2,
        framePath: '',
        visual: '小夏拿起红伞',
        content: '',
        shotSize: '',
        cameraMovement: '',
        cameraNotes: '',
        scene: '',
        productCode: '',
        productStyling: '',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.completed,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      assets: [
        ShootingAssetLibraryItem(
          id: 'hero',
          type: ReplicateAssetType.character,
          name: '林夏',
          description: '',
          aliases: const ['小夏'],
          path: '',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        ShootingAssetLibraryItem(
          id: 'umbrella-a',
          type: ReplicateAssetType.prop,
          name: '红伞',
          description: '',
          path: '',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        ShootingAssetLibraryItem(
          id: 'umbrella-b',
          type: ReplicateAssetType.prop,
          name: '红伞',
          description: '',
          path: '',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );

    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.assetId, 'hero');
    expect(result.candidates.single.confidence, 0.96);
    expect(result.candidates.single.reason, contains('别名'));
  });

  test('穿搭字段可按上装下装鞋子配饰槽位匹配唯一资产', () async {
    final root = await Directory.systemTemp.createTemp('asset_match_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settings = SettingsRepository(database, directories).load();
    const service = ScriptAssetMatchingService();

    final result = await service.match(
      settings: settings,
      shot: ScriptShot(
        id: 'shot-1',
        scriptId: 'script-1',
        shotNumber: 1,
        durationSeconds: 2,
        framePath: '',
        visual: '',
        content: '',
        shotSize: '',
        cameraMovement: '',
        cameraNotes: '',
        scene: '',
        productCode: '',
        productStyling: '上装/下装/鞋子/配饰/',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.completed,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      assets: [
        _asset('top', '上装-白衬衫'),
        _asset('bottom', '下装_牛仔裤'),
        _asset('shoes', '鞋子'),
        _asset('accessory', '配饰包'),
        _asset('scene', '米色石墙', type: ReplicateAssetType.scene),
      ],
    );

    expect(result.usedModel, isFalse);
    expect(result.candidates, hasLength(4));
    expect(
      result.candidates.map((item) => item.assetId),
      containsAll(['top', 'bottom', 'shoes', 'accessory']),
    );
    expect(
      result.candidates,
      everyElement(
        predicate<ScriptAssetMatchCandidate>((item) {
          return item.confidence >= 0.9 && item.reason.contains('穿搭字段');
        }),
      ),
    );
  });

  test('穿搭槽位存在多个资产时不会自动盲绑', () async {
    final root = await Directory.systemTemp.createTemp('asset_match_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settings = SettingsRepository(database, directories).load();
    const service = ScriptAssetMatchingService();

    final result = await service.match(
      settings: settings,
      shot: ScriptShot(
        id: 'shot-1',
        scriptId: 'script-1',
        shotNumber: 1,
        durationSeconds: 2,
        framePath: '',
        visual: '',
        content: '',
        shotSize: '',
        cameraMovement: '',
        cameraNotes: '',
        scene: '',
        productCode: '',
        productStyling: '上装/下装/',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.completed,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      assets: [
        _asset('top-a', '上装-白衬衫'),
        _asset('top-b', '上装-针织衫'),
        _asset('bottom', '下装-牛仔裤'),
      ],
    );

    expect(result.candidates.map((item) => item.assetId), ['bottom']);
  });
}

ShootingAssetLibraryItem _asset(
  String id,
  String name, {
  ReplicateAssetType type = ReplicateAssetType.product,
}) => ShootingAssetLibraryItem(
  id: id,
  type: type,
  name: name,
  description: '',
  path: '',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);
