import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('替换镜头可持久化全部字段', () async {
    final root = await Directory.systemTemp.createTemp('script_repository_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = ShootingScriptRepository(database);
    final now = DateTime.utc(2026, 8, 3);

    repository.upsertScript(
      ShootingScript(
        id: 'script-1',
        name: '测试脚本',
        sourceStoryboardId: 'board-1',
        sourceVideoId: 'video-1',
        status: ShootingScriptStatus.draft,
        version: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.replaceShots('script-1', [
      ScriptShot(
        id: 'shot-1',
        scriptId: 'script-1',
        sourceStoryboardAssetId: 'asset-1',
        shotNumber: 1,
        durationSeconds: 2.5,
        framePath: 'frames/shot-1.png',
        visual: '产品特写',
        content: '模特拿起产品',
        shotSize: '近景',
        cameraMovement: '推进',
        cameraNotes: '柔光',
        composition: '居中构图',
        cameraAngle: '平视',
        lightingMood: '明亮',
        colorPalette: '暖白',
        visualFocus: '产品标签',
        transitionHint: '叠化',
        scene: '摄影棚',
        productCode: 'SKU-1',
        productStyling: '白色',
        dialogue: '你好',
        sound: '轻音乐',
        prompt: '产品保持一致',
        status: ProcessingStatus.completed,
        updatedAt: now,
      ),
    ]);

    final shot = repository.listShots('script-1').single;
    expect(shot.sourceStoryboardAssetId, 'asset-1');
    expect(shot.durationSeconds, 2.5);
    expect(shot.composition, '居中构图');
    expect(shot.transitionHint, '叠化');
    expect(shot.prompt, '产品保持一致');
  });
}
