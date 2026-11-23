import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('逐镜复刻指导记录可持久化配饰选择、动作和骨架状态', () async {
    final root = await Directory.systemTemp.createTemp('replicate_guide_');
    addTearDown(() => root.delete(recursive: true));
    final database = await AppDatabase.open(
      File(p.join(root.path, 'workspace.sqlite')),
    );
    addTearDown(database.dispose);
    final now = DateTime.now().toUtc();
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
        actionDescription: '人物侧身面向画面右侧，右臂自然下垂。',
        poseConstraints: '保持头肩夹角、右肘弯曲角度和身体重心。',
        personCount: 2,
        skeletonPath: p.join(root.path, 'pose', 'shot-1.png'),
        analysisModel: 'test-vision-model',
        analysisStatus: ProcessingStatus.completed,
        poseStatus: ProcessingStatus.completed,
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
    expect(restored?.poseStatus, ProcessingStatus.completed);
    expect(restored?.skeletonPath, endsWith(p.join('pose', 'shot-1.png')));

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

  test('版本22数据库自动迁移人物数量列并保留既有骨架记录', () async {
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
          'SELECT person_count, skeleton_path FROM replicate_shot_guides '
          "WHERE shot_id = 'shot-legacy';",
        )
        .single;
    expect(row['person_count'], 0);
    expect(row['skeleton_path'], 'legacy-pose.png');
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
