import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('脚本资产、镜头绑定和解析记录可以持久化并按脚本读取', () async {
    final root = await Directory.systemTemp.createTemp('script_workflow_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    database.executeStatement('''
      INSERT INTO shooting_scripts(
        id, name, status, version, created_at, updated_at
      ) VALUES('script-1', '测试脚本', 'draft', 1, '2026-01-01', '2026-01-01');
    ''');
    database.executeStatement('''
      INSERT INTO script_shots(
        id, script_id, shot_number, updated_at
      ) VALUES('shot-1', 'script-1', 1, '2026-01-01');
    ''');

    final repository = ShootingScriptWorkflowRepository(database);
    final now = DateTime.utc(2026, 1, 1);
    repository.upsertScriptAsset(
      ScriptAsset(
        id: 'script-asset-1',
        scriptId: 'script-1',
        libraryAssetId: 'library-1',
        type: ReplicateAssetType.character,
        name: '主角',
        description: '白衬衫短发',
        path: 'assets/hero.png',
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertLink(
      ScriptShotAssetLink(
        shotId: 'shot-1',
        scriptAssetId: 'script-asset-1',
        matchSource: ScriptAssetMatchSource.model,
        confidence: 0.91,
        matchReason: '镜头中出现白衬衫人物',
        confirmed: true,
        locked: false,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertAnalysis(
      ScriptShotAnalysisRecord(
        id: 'analysis-1',
        shotId: 'shot-1',
        model: 'test-vlm',
        status: ProcessingStatus.completed,
        fieldSources: const {'content': 'model'},
        fieldConfidence: const {'content': 0.88},
        rawResponse: '{"content":"人物走近"}',
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(repository.listScriptAssets('script-1'), hasLength(1));
    expect(repository.listLinksForScript('script-1'), hasLength(1));
    expect(repository.listLinksForShot('shot-1').single.confirmed, isTrue);
    final analysis = repository.getAnalysis('shot-1');
    expect(analysis?.fieldSources['content'], 'model');
    expect(analysis?.fieldConfidence['content'], closeTo(0.88, 0.001));

    repository.deleteLink('shot-1', 'script-asset-1');
    expect(repository.listLinksForShot('shot-1'), isEmpty);
  });
}
