import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppDatabase database;
  late RemoteChangeBus changeBus;
  late RemoteWorkspaceRegistry registry;
  late RemoteAccessFacade facade;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('remote-facade-test-');
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    database = await AppDatabase.open(directories.databaseFile);
    changeBus = RemoteChangeBus();
    registry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-1',
          projectName: '远程测试工程',
          database: database,
          directories: directories,
        ),
      );
    facade = RemoteAccessFacade(
      workspaceRegistry: registry,
      changeBus: changeBus,
    );
    _seedScript(database);
  });

  tearDown(() async {
    database.dispose();
    await changeBus.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('工作区和脚本响应不包含本机素材绝对路径', () {
    final workspace = facade.workspaceOverview();
    final detail = facade.scriptDetail('script-1');
    final shot =
        (detail['shots']! as List<Object?>).single as Map<String, Object?>;

    expect(workspace['phase'], 'editor');
    expect((workspace['project']! as Map<String, Object?>)['name'], '远程测试工程');
    expect(detail['version'], 1);
    expect(shot['frameAvailable'], isTrue);
    expect(shot.containsKey('framePath'), isFalse);
    expect(detail.toString(), isNot(contains(root.path)));
  });

  test('镜头更新原子递增版本并发布变更事件', () async {
    final nextEvent = changeBus.events.first;

    final detail = facade.updateShot(
      scriptId: 'script-1',
      shotId: 'shot-1',
      expectedVersion: 1,
      changes: const {'content': '导演远程修改后的内容', 'durationSeconds': 8},
    );
    final event = await nextEvent;
    final shot =
        (detail['shots']! as List<Object?>).single as Map<String, Object?>;

    expect(detail['version'], 2);
    expect(shot['content'], '导演远程修改后的内容');
    expect(shot['durationSeconds'], 8.0);
    expect(event.type, 'shootingScript.changed');
    expect(event.resourceId, 'script-1');
    expect(event.revision, 2);
  });

  test('旧版本写入返回 revision_conflict 且不覆盖新值', () {
    facade.updateShot(
      scriptId: 'script-1',
      shotId: 'shot-1',
      expectedVersion: 1,
      changes: const {'content': '第一个保存值'},
    );

    expect(
      () => facade.updateShot(
        scriptId: 'script-1',
        shotId: 'shot-1',
        expectedVersion: 1,
        changes: const {'content': '过期客户端覆盖值'},
      ),
      throwsA(
        isA<RemoteOperationException>().having(
          (error) => error.code,
          'code',
          'revision_conflict',
        ),
      ),
    );
    final detail = facade.scriptDetail('script-1');
    final shot =
        (detail['shots']! as List<Object?>).single as Map<String, Object?>;
    expect(shot['content'], '第一个保存值');
  });

  test('字段白名单拒绝远程修改文件路径', () {
    expect(
      () => facade.updateShot(
        scriptId: 'script-1',
        shotId: 'shot-1',
        expectedVersion: 1,
        changes: const {'framePath': r'C:\Windows\secret.txt'},
      ),
      throwsA(
        isA<RemoteOperationException>().having(
          (error) => error.code,
          'code',
          'invalid_changes',
        ),
      ),
    );
  });
}

void _seedScript(AppDatabase database) {
  final repository = ShootingScriptRepository(database);
  final now = DateTime.utc(2026, 8, 10, 12);
  repository.upsertScript(
    ShootingScript(
      id: 'script-1',
      name: '项目 A 拍摄脚本',
      sourceStoryboardId: null,
      sourceVideoId: null,
      status: ShootingScriptStatus.active,
      version: 1,
      createdAt: now,
      updatedAt: now,
    ),
  );
  repository.replaceShots('script-1', [
    ScriptShot(
      id: 'shot-1',
      scriptId: 'script-1',
      shotNumber: 1,
      durationSeconds: 5,
      framePath: r'G:\private-project\frame-001.png',
      visual: '人物走入画面',
      content: '原始镜头内容',
      shotSize: '中景',
      cameraMovement: '缓慢推进',
      cameraNotes: '',
      scene: '室内',
      productCode: '',
      productStyling: '',
      dialogue: '',
      sound: '脚步声',
      prompt: '原始提示词',
      status: ProcessingStatus.completed,
      updatedAt: now,
    ),
  ]);
}
