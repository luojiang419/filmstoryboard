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
  test('资产名称和描述会产生可解释的规则候选', () async {
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
    expect(result.candidates, isNotEmpty);
    expect(result.candidates.first.assetId, anyOf('asset-hero', 'asset-scene'));
    expect(result.candidates.first.reason, isNotEmpty);
  });
}
