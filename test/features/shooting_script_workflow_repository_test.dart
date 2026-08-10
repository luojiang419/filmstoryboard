import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
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
        promptContext: const ScriptShotPromptContext(
          subject: {'people': '女模特', 'expression': '专注看向产品'},
          action: {'bodyAction': '抬手展示产品', 'actionStage': '进行'},
          scene: {'location': '极简摄影棚', 'spatialRelation': '产品位于胸前'},
          camera: {
            'shotSize': '中近景',
            'cameraMovement': '推',
            'speedCurve': '快速起势，中段减速，结尾锁定产品',
          },
          visualStyle: {'lightingMood': '高调商业光', 'colorPalette': '暖金色调'},
          continuity: {'transitionHint': '承接上一动作'},
          audio: {'sound': '轻快节奏铺底'},
        ),
        promptContextSchemaVersion: 1,
        sourceImageFingerprint: 'sha256:replica-frame-1',
        analysisRuleVersion: 5,
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
    expect(analysis?.promptContext.subject['people'], '女模特');
    expect(analysis?.promptContext.camera['speedCurve'], '快速起势，中段减速，结尾锁定产品');
    expect(analysis?.promptContextSchemaVersion, 1);
    expect(analysis?.sourceImageFingerprint, 'sha256:replica-frame-1');
    expect(analysis?.analysisRuleVersion, 5);

    repository.deleteLink('shot-1', 'script-asset-1');
    expect(repository.listLinksForShot('shot-1'), isEmpty);
  });

  test('版本16旧数据库会补齐提示词上下文字段且不触发数据重算', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_workflow_legacy_',
    );
    addTearDown(() => root.delete(recursive: true));
    final databaseFile = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(databaseFile.path);
    legacy
      ..execute('''
        CREATE TABLE script_shot_analysis (
          id TEXT PRIMARY KEY,
          shot_id TEXT NOT NULL UNIQUE,
          model TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          field_sources_json TEXT NOT NULL DEFAULT '{}',
          field_confidence_json TEXT NOT NULL DEFAULT '{}',
          raw_response TEXT NOT NULL DEFAULT '',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        INSERT INTO script_shot_analysis(
          id, shot_id, model, status, created_at, updated_at
        ) VALUES(
          'analysis-old', 'shot-old', 'legacy-vlm', 'completed',
          '2026-01-01', '2026-01-01'
        );
      ''')
      ..execute('PRAGMA user_version = 16;')
      ..close();

    final database = await AppDatabase.open(databaseFile);
    addTearDown(database.dispose);
    final repository = ShootingScriptWorkflowRepository(database);

    final analysis = repository.getAnalysis('shot-old');
    expect(analysis, isNotNull);
    expect(analysis?.promptContext.isEmpty, isTrue);
    expect(analysis?.promptContextSchemaVersion, 0);
    expect(analysis?.sourceImageFingerprint, '');
    expect(analysis?.analysisRuleVersion, 0);
    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
  });
}
