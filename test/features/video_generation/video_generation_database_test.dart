import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_directories.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('video-generation-db-');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('schema 12 升级到当前版本时回填源视频帧并创建视频生成表', () async {
    final file = File('${root.path}/legacy.sqlite');
    final legacy = sqlite3.open(file.path);
    legacy
      ..execute('PRAGMA foreign_keys = OFF;')
      ..execute('''
        CREATE TABLE source_videos(id TEXT PRIMARY KEY);
        CREATE TABLE video_frames(
          id TEXT PRIMARY KEY,
          video_id TEXT NOT NULL,
          path TEXT NOT NULL
        );
        CREATE TABLE shooting_scripts(
          id TEXT PRIMARY KEY,
          source_video_id TEXT
        );
        CREATE TABLE script_shots(
          id TEXT PRIMARY KEY,
          script_id TEXT NOT NULL,
          frame_path TEXT NOT NULL
        );
        CREATE TABLE replicate_runs(id TEXT PRIMARY KEY);
      ''')
      ..execute("INSERT INTO source_videos(id) VALUES('video-1');")
      ..execute(
        "INSERT INTO video_frames(id, video_id, path) VALUES('frame-1', 'video-1', 'C:\\\\Frames\\\\001.jpg');",
      )
      ..execute(
        "INSERT INTO shooting_scripts(id, source_video_id) VALUES('script-1', 'video-1');",
      )
      ..execute(
        "INSERT INTO script_shots(id, script_id, frame_path) VALUES('shot-1', 'script-1', 'c:\\\\frames\\\\001.jpg');",
      )
      ..execute("INSERT INTO replicate_runs(id) VALUES('run-1');")
      ..execute('PRAGMA user_version = 12;')
      ..close();

    final database = await AppDatabase.open(file);
    addTearDown(database.dispose);

    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
    expect(
      database
          .selectRows(
            "SELECT source_video_frame_id FROM script_shots WHERE id = 'shot-1';",
          )
          .single['source_video_frame_id'],
      'frame-1',
    );
    expect(
      database
          .selectRows('PRAGMA table_info(script_shots);')
          .map((row) => row['name']),
      contains('generation_feedback'),
    );
    for (final table in const [
      'video_generation_profiles',
      'video_generation_drafts',
      'video_generation_tasks',
    ]) {
      expect(database.countRows(table), 0, reason: table);
    }
    expect(database.integrityCheck(), isTrue);
  });

  test('配置、提示词草稿、不可变提交快照和恢复队列可往返', () async {
    final database = await AppDatabase.open(
      File('${root.path}/current.sqlite'),
    );
    addTearDown(database.dispose);
    final now = DateTime.utc(2026, 8, 4);
    database
      ..executeStatement(
        '''
        INSERT INTO shooting_scripts(
          id, name, status, version, created_at, updated_at
        ) VALUES('script-1', '脚本', 'draft', 1, ?, ?);
      ''',
        [now.toIso8601String(), now.toIso8601String()],
      )
      ..executeStatement(
        '''
        INSERT INTO script_shots(
          id, script_id, shot_number, updated_at
        ) VALUES('shot-1', 'script-1', 1, ?);
      ''',
        [now.toIso8601String()],
      );
    final repository = VideoGenerationRepository(database);
    repository
      ..upsertProfile(
        VideoGenerationProfile(
          scriptId: 'script-1',
          model: 'kling-video-v3_0_turbo',
          parameters: const {'resolution': '1080p'},
          directoryName: '脚本-script-1',
          createdAt: now,
          updatedAt: now,
        ),
      )
      ..upsertDraft(
        VideoGenerationDraft(
          id: 'draft-1',
          scriptId: 'script-1',
          shotId: 'shot-1',
          sourcePrompt: '原提示词',
          klingPrompt: '主体缓慢转身，镜头轻推',
          h3Prompt: '【参考素材说明】@图片1 是画面参考图',
          updatedAt: now,
        ),
      )
      ..upsertTask(
        VideoGenerationTask(
          id: 'task-1',
          scriptId: 'script-1',
          shotId: 'shot-1',
          generationId: 'generation-1',
          model: 'kling-video-v3_0_turbo',
          parameters: const {'resolution': '1080p'},
          durationSeconds: 5,
          promptMode: VideoPromptMode.klingOptimized,
          prompt: '提交时固定文本',
          tailImagePath: 'frames/tail.png',
          creditsBefore: 46220,
          status: VideoGenerationTaskStatus.timedOut,
          createdAt: now,
          updatedAt: now,
        ),
      );

    expect(repository.getProfile('script-1')?.model, 'kling-video-v3_0_turbo');
    expect(
      repository.listDrafts('script-1').single.selectedPrompt,
      contains('轻推'),
    );
    expect(
      repository.listDrafts('script-1').single.h3Prompt,
      contains('参考素材说明'),
    );
    expect(
      repository.listRecoverableTasks().single.generationId,
      'generation-1',
    );
    expect(repository.listRecoverableTasks(includeTimedOut: false), isEmpty);
    expect(repository.getTask('task-1')?.prompt, '提交时固定文本');
    expect(repository.getTask('task-1')?.tailImagePath, 'frames/tail.png');
  });

  test('生成目录使用安全稳定脚本名且不创建原视频片段目录', () async {
    final projectDirectories = ProjectDirectories.fromRoot(root);
    final directories = VideoGenerationDirectories.resolve(
      projectDirectories: projectDirectories,
      scriptName: '产品:脚本? A',
      scriptId: '12345678-abcd',
    );
    await directories.create();

    expect(directories.root.path, contains('产品_脚本_ A-12345678'));
    expect(directories.results.existsSync(), isTrue);
    expect(
      Directory('${directories.root.path}/原视频3秒').existsSync(),
      isFalse,
      reason: 'IO 点预览复用源视频，不应生成片段目录',
    );
  });

  test('生成目录会截断历史超长脚本名并保留脚本短标识', () {
    final directories = VideoGenerationDirectories.resolve(
      projectDirectories: ProjectDirectories.fromRoot(root),
      scriptName: 'unused',
      scriptId: 'abcdef12-3456',
      stableDirectoryName: '${'超长提示词目录' * 30}-abcdef12',
    );

    final name = p.basename(directories.root.path);
    expect(name, endsWith('-abcdef12'));
    expect(name.length, lessThanOrEqualTo(57));
  });
}
