import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('逐镜复刻指导记录可持久化配饰选择、动作和深度状态', () async {
    final root = await Directory.systemTemp.createTemp('replicate_guide_');
    addTearDown(() => root.delete(recursive: true));
    final database = await AppDatabase.open(
      File(p.join(root.path, 'workspace.sqlite')),
    );
    addTearDown(database.dispose);
    final now = DateTime.now().toUtc();
    final authorizationTime = DateTime.utc(2026, 8, 18, 9, 30);
    _insertShot(database, now: now);
    final repository = ReplicateRepository(database);

    repository.upsertShotGuide(
      ReplicateShotGuide(
        shotId: 'shot-1',
        sourceFrameFingerprint: 'frame-v1',
        elements: const [
          ReplicatePreservedElement(
            id: 'glasses:金属框眼镜',
            category: '眼镜',
            label: '金属框眼镜',
            description: '细金属框、透明镜片',
            location: '人物面部',
            relationship: '佩戴在双眼前方',
            confidence: 0.94,
            selected: true,
          ),
          ReplicatePreservedElement(
            id: 'bag:黑色手提包',
            category: '包',
            label: '黑色手提包',
            description: '短提手皮包',
            location: '画面右下方',
            relationship: '人物右手提握',
            confidence: 0.88,
          ),
        ],
        subjects: const [
          ReplicateDetectedSubject(
            id: 'person:0',
            type: ReplicateSubjectType.person,
            label: '画面左侧人物',
            slotIndex: 0,
            decision: ReplicateSubjectDecision.replace,
          ),
          ReplicateDetectedSubject(
            id: 'product:0',
            type: ReplicateSubjectType.product,
            label: '黑色手提包',
            slotIndex: 0,
            decision: ReplicateSubjectDecision.keep,
          ),
          ReplicateDetectedSubject(
            id: 'product:1',
            type: ReplicateSubjectType.product,
            label: '白色运动鞋',
            slotIndex: 1,
            decision: ReplicateSubjectDecision.remove,
          ),
        ],
        fullOutfitAssets: const [
          ReplicateFullOutfitAsset(
            id: 'outfit:model-a',
            personSlotIndex: 0,
            name: '模特 A 完整穿搭',
            primaryViewId: 'outfit:model-a:front',
            views: [
              ReplicateFullOutfitView(
                id: 'outfit:model-a:front',
                scriptAssetId: 'asset-model-a-front',
                role: ReplicateOutfitViewRole.front,
              ),
              ReplicateFullOutfitView(
                id: 'outfit:model-a:side',
                scriptAssetId: 'asset-model-a-side',
                role: ReplicateOutfitViewRole.side,
                order: 1,
              ),
              ReplicateFullOutfitView(
                id: 'outfit:model-a:back',
                scriptAssetId: 'asset-model-a-back',
                role: ReplicateOutfitViewRole.back,
                order: 2,
              ),
            ],
          ),
        ],
        wearableProductLinks: const [
          ReplicateWearableProductLink(
            personSlotIndex: 0,
            productSlotIndex: 0,
            fullOutfitAssetId: 'outfit:model-a',
          ),
        ],
        productMarkAuthorizations: [
          ReplicateProductMarkAuthorization(
            productSlotIndex: 0,
            enabled: true,
            referenceAssetId: 'asset-logo-a',
            exactText: 'FILM A',
            allowedTypes: const [
              ReplicateAuthorizedMarkType.logo,
              ReplicateAuthorizedMarkType.productName,
            ],
            status: ReplicateAuthorizationStatus.confirmed,
            confirmedAt: authorizationTime,
            location: '鞋舌正面',
          ),
        ],
        actionDescription: '人物侧身面向画面右侧，右臂自然下垂。',
        poseConstraints: '保持头肩夹角、右肘弯曲角度和身体重心。',
        personCount: 2,
        depthPath: p.join(root.path, 'pose', 'shot-1.png'),
        analysisModel: 'test-vision-model',
        analysisStatus: ProcessingStatus.completed,
        depthStatus: ProcessingStatus.completed,
        rawResponse: '{"elements":[]}',
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final restored = repository.getShotGuide('shot-1');
    expect(restored, isNotNull);
    expect(restored?.sourceFrameFingerprint, 'frame-v1');
    expect(restored?.selectedElements.single.label, '金属框眼镜');
    expect(restored?.unselectedElements.single.label, '黑色手提包');
    expect(restored?.elements.last.selected, isFalse);
    expect(restored?.actionDescription, contains('侧身面向画面右侧'));
    expect(restored?.poseConstraints, contains('右肘弯曲角度'));
    expect(restored?.personCount, 2);
    expect(restored?.subjects, hasLength(3));
    expect(restored?.subjects.first.decision, ReplicateSubjectDecision.replace);
    expect(restored?.subjects[1].decision, ReplicateSubjectDecision.keep);
    expect(restored?.subjects.last.decision, ReplicateSubjectDecision.remove);
    expect(restored?.fullOutfitAssets, hasLength(1));
    expect(restored?.fullOutfitAssets.single.hasCompleteThreeViewSet, isTrue);
    expect(
      restored?.fullOutfitAssets.single.primaryView?.scriptAssetId,
      'asset-model-a-front',
    );
    expect(restored?.wearableProductLinks.single.personSlotIndex, 0);
    expect(restored?.wearableProductLinks.single.productSlotIndex, 0);
    expect(restored?.wearableProductLinks.single.linked, isTrue);
    expect(restored?.productMarkAuthorizations.single.isAuthorized, isTrue);
    expect(restored?.productMarkAuthorizations.single.exactText, 'FILM A');
    expect(
      restored?.productMarkAuthorizations.single.confirmedAt,
      authorizationTime,
    );
    expect(restored?.depthStatus, ProcessingStatus.completed);
    expect(restored?.depthPath, endsWith(p.join('pose', 'shot-1.png')));

    database.executeStatement('DELETE FROM script_shots WHERE id = ?;', [
      'shot-1',
    ]);
    expect(repository.getShotGuide('shot-1'), isNull);
  });

  test('旧主体保留决策读取后回落为未选择并要求重新确认', () {
    final restored = ReplicateDetectedSubject.fromJson(const {
      'id': 'person:0',
      'type': 'person',
      'label': '旧项目人物',
      'slotIndex': 0,
      'decision': 'preserve',
    });

    expect(restored.decision, ReplicateSubjectDecision.undecided);
  });

  test('授权标识默认关闭且未知标识类型被忽略', () {
    final authorization = ReplicateProductMarkAuthorization.fromJson(const {
      'productSlotIndex': 2,
      'exactText': 'MODEL-X',
      'allowedTypes': ['model', 'futureType'],
    });
    expect(authorization.enabled, isFalse);
    expect(authorization.isAuthorized, isFalse);
    expect(authorization.allowedTypes, [ReplicateAuthorizedMarkType.model]);
  });

  test('版本26数据库补齐深度字段并移除骨架结构', () async {
    final root = await Directory.systemTemp.createTemp('replicate_guide_v26_');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(file.path);
    legacy
      ..execute('''
        CREATE TABLE replicate_shot_guides (
          shot_id TEXT PRIMARY KEY,
          subjects_json TEXT NOT NULL DEFAULT '[]',
          skeleton_path TEXT NOT NULL DEFAULT '',
          pose_status TEXT NOT NULL DEFAULT 'pending'
        );
      ''')
      ..execute(
        'INSERT INTO replicate_shot_guides('
        'shot_id, subjects_json, skeleton_path, pose_status'
        ') VALUES(?, ?, ?, ?);',
        [
          'shot-v26',
          '[{"id":"person:0","type":"person","decision":"keep"}]',
          'pose-v26.png',
          'completed',
        ],
      )
      ..execute('PRAGMA user_version = 26;')
      ..close();

    final database = await AppDatabase.open(file);
    addTearDown(database.dispose);
    final row = database.selectRows(
      'SELECT * FROM replicate_shot_guides WHERE shot_id = ?;',
      ['shot-v26'],
    ).single;
    final columns = database
        .selectRows('PRAGMA table_info(replicate_shot_guides);')
        .map((item) => item['name'])
        .toSet();

    expect(row['subjects_json'], contains('person:0'));
    expect(row['depth_path'], '');
    expect(row['depth_status'], 'pending');
    expect(row['full_outfit_assets_json'], '[]');
    expect(row['wearable_product_links_json'], '[]');
    expect(row['product_mark_authorizations_json'], '[]');
    expect(columns, isNot(contains('editable_pose_json')));
    expect(columns, isNot(contains('skeleton_path')));
    expect(columns, isNot(contains('pose_status')));
    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
  });

  test('版本22数据库迁移人物数量并丢弃旧骨架记录', () async {
    final root = await Directory.systemTemp.createTemp('replicate_guide_v22_');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(file.path);
    legacy
      ..execute('''
        CREATE TABLE replicate_shot_guides (
          shot_id TEXT PRIMARY KEY,
          source_frame_fingerprint TEXT NOT NULL DEFAULT '',
          elements_json TEXT NOT NULL DEFAULT '[]',
          action_description TEXT NOT NULL DEFAULT '',
          pose_constraints TEXT NOT NULL DEFAULT '',
          skeleton_path TEXT NOT NULL DEFAULT '',
          analysis_model TEXT NOT NULL DEFAULT '',
          analysis_status TEXT NOT NULL DEFAULT 'pending',
          pose_status TEXT NOT NULL DEFAULT 'pending',
          raw_response TEXT NOT NULL DEFAULT '',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        INSERT INTO replicate_shot_guides(
          shot_id, skeleton_path, pose_status, created_at, updated_at
        ) VALUES('shot-legacy', 'legacy-pose.png', 'completed', '2026-01-01', '2026-01-01');
      ''')
      ..execute('PRAGMA user_version = 22;')
      ..close();

    final database = await AppDatabase.open(file);
    addTearDown(database.dispose);
    final row = database
        .selectRows(
          'SELECT person_count, depth_path, depth_status FROM replicate_shot_guides '
          "WHERE shot_id = 'shot-legacy';",
        )
        .single;
    expect(row['person_count'], 0);
    expect(row['depth_path'], '');
    expect(row['depth_status'], 'pending');
    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
  });

  test('版本21数据库自动迁移逐镜复刻指导表并更新到最新版本', () async {
    final root = await Directory.systemTemp.createTemp('replicate_guide_v21_');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(file.path);
    legacy
      ..execute('''
        CREATE TABLE shooting_scripts (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'draft',
          version INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE script_shots (
          id TEXT PRIMARY KEY,
          script_id TEXT NOT NULL REFERENCES shooting_scripts(id) ON DELETE CASCADE,
          shot_number INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('PRAGMA user_version = 21;')
      ..close();

    final database = await AppDatabase.open(file);
    addTearDown(database.dispose);
    expect(
      database.selectRows(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'replicate_shot_guides';",
      ),
      hasLength(1),
    );
    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
  });
}

void _insertShot(AppDatabase database, {required DateTime now}) {
  final timestamp = now.toIso8601String();
  database
    ..executeStatement(
      'INSERT INTO shooting_scripts('
      'id, name, status, version, created_at, updated_at'
      ') VALUES(?, ?, ?, ?, ?, ?);',
      ['script-1', '复刻指导测试', 'draft', 1, timestamp, timestamp],
    )
    ..executeStatement(
      'INSERT INTO script_shots(id, script_id, shot_number, updated_at) '
      'VALUES(?, ?, ?, ?);',
      ['shot-1', 'script-1', 1, timestamp],
    );
}
