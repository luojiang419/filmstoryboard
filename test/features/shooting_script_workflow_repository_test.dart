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
        quickReferenceOrder: 1,
        quickReferenceRole: QuickReferenceRole.model,
        quickDescription: '保持短发和白衬衫造型',
        quickGroupAnchorAssetId: 'script-asset-1',
        quickGroupConfidence: 0.93,
        quickGroupWarning: '测试警告',
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
    final storedLink = repository.listLinksForShot('shot-1').single;
    expect(storedLink.confirmed, isTrue);
    expect(storedLink.quickReferenceOrder, 1);
    expect(storedLink.quickReferenceRole, QuickReferenceRole.model);
    expect(storedLink.quickDescription, '保持短发和白衬衫造型');
    expect(storedLink.quickGroupAnchorAssetId, 'script-asset-1');
    expect(storedLink.quickGroupConfidence, closeTo(0.93, 0.001));
    expect(storedLink.quickGroupWarning, '测试警告');
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

  test('版本27旧链接首次读取时连续回填快速顺序和默认类型', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_workflow_quick_legacy_',
    );
    addTearDown(() => root.delete(recursive: true));
    final databaseFile = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(databaseFile.path);
    legacy
      ..execute('''
        CREATE TABLE script_assets (
          id TEXT PRIMARY KEY,
          script_id TEXT NOT NULL,
          library_asset_id TEXT,
          asset_type TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          reference_number INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(script_id, library_asset_id)
        );
      ''')
      ..execute('''
        CREATE TABLE script_shot_asset_links (
          shot_id TEXT NOT NULL,
          script_asset_id TEXT NOT NULL,
          match_source TEXT NOT NULL DEFAULT 'manual',
          confidence REAL NOT NULL DEFAULT 1,
          match_reason TEXT NOT NULL DEFAULT '',
          confirmed INTEGER NOT NULL DEFAULT 0,
          locked INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(shot_id, script_asset_id)
        );
      ''')
      ..execute('''
        INSERT INTO script_assets(
          id, script_id, asset_type, name, created_at, updated_at
        ) VALUES
          ('asset-product', 'script-old', 'product', '裤子', '2026-01-01', '2026-01-01'),
          ('asset-model', 'script-old', 'character', '模特', '2026-01-01', '2026-01-01');
      ''')
      ..execute('''
        INSERT INTO script_shot_asset_links(
          shot_id, script_asset_id, sort_order, created_at, updated_at
        ) VALUES
          ('shot-old', 'asset-product', 8, '2026-01-01T00:00:02Z', '2026-01-01'),
          ('shot-old', 'asset-model', 3, '2026-01-01T00:00:01Z', '2026-01-01');
      ''')
      ..execute('PRAGMA user_version = 27;')
      ..close();

    final database = await AppDatabase.open(databaseFile);
    addTearDown(database.dispose);
    final repository = ShootingScriptWorkflowRepository(database);

    final links = repository.listLinksForShot('shot-old');
    expect(links.map((link) => link.scriptAssetId), [
      'asset-model',
      'asset-product',
    ]);
    expect(links.map((link) => link.quickReferenceOrder), [1, 2]);
    expect(links.map((link) => link.quickReferenceRole), [
      QuickReferenceRole.model,
      QuickReferenceRole.product,
    ]);

    final persisted = database.selectRows(
      '''
      SELECT quick_reference_order, quick_reference_role
      FROM script_shot_asset_links
      WHERE shot_id = ?
      ORDER BY quick_reference_order;
      ''',
      ['shot-old'],
    );
    expect(persisted.map((row) => row['quick_reference_order']), [1, 2]);
    expect(persisted.map((row) => row['quick_reference_role']), [
      QuickReferenceRole.model.name,
      QuickReferenceRole.product.name,
    ]);
    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
  });

  test('仅缺快速角色时保留已经写入的快速顺序', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_workflow_partial_quick_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = ShootingScriptWorkflowRepository(database);
    final now = DateTime.utc(2026, 1, 1);
    database.executeStatement('''
      INSERT INTO shooting_scripts(
        id, name, status, version, created_at, updated_at
      ) VALUES(
        'script-partial', '部分快速元数据', 'draft', 1,
        '2026-01-01', '2026-01-01'
      );
    ''');
    database.executeStatement('''
      INSERT INTO script_shots(
        id, script_id, shot_number, updated_at
      ) VALUES('shot-partial', 'script-partial', 1, '2026-01-01');
    ''');
    for (final id in ['asset-first-by-sort', 'asset-first-by-quick']) {
      repository.upsertScriptAsset(
        ScriptAsset(
          id: id,
          scriptId: 'script-partial',
          type: ReplicateAssetType.character,
          name: id,
          description: '',
          path: '$id.png',
          referenceNumber: 1,
          status: ProcessingStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    repository.upsertLink(
      ScriptShotAssetLink(
        shotId: 'shot-partial',
        scriptAssetId: 'asset-first-by-sort',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '',
        confirmed: true,
        locked: true,
        sortOrder: 1,
        quickReferenceOrder: 2,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertLink(
      ScriptShotAssetLink(
        shotId: 'shot-partial',
        scriptAssetId: 'asset-first-by-quick',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '',
        confirmed: true,
        locked: true,
        sortOrder: 2,
        quickReferenceOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final links = repository.listLinksForShot('shot-partial');
    expect(links.map((link) => link.quickReferenceOrder), [2, 1]);
    expect(
      links.map((link) => link.quickReferenceRole),
      everyElement(QuickReferenceRole.model),
    );
    final persisted = database.selectRows(
      '''
      SELECT script_asset_id, quick_reference_order, quick_reference_role
      FROM script_shot_asset_links
      WHERE shot_id = ?
      ORDER BY quick_reference_order;
      ''',
      ['shot-partial'],
    );
    expect(persisted.map((row) => row['script_asset_id']), [
      'asset-first-by-quick',
      'asset-first-by-sort',
    ]);
    expect(
      persisted.map((row) => row['quick_reference_role']),
      everyElement(QuickReferenceRole.model.name),
    );
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
