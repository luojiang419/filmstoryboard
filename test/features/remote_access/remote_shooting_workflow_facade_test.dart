import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_shooting_workflow_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_task_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_shooting_workflow_models.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('拍摄脚本工作流只投影媒体 ID 并以本机任务执行命令', () async {
    final root = await Directory.systemTemp.createTemp('remote-workflow-');
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final image = File('${directories.frames.path}/asset.png');
    await image.writeAsBytes(const [1, 2, 3]);
    final database = await AppDatabase.open(directories.databaseFile);
    final now = DateTime.now().toUtc();
    final repository = ShootingScriptRepository(database);
    repository.upsertScript(
      ShootingScript(
        id: 'script-1',
        name: '测试脚本',
        sourceStoryboardId: null,
        sourceVideoId: null,
        status: ShootingScriptStatus.active,
        version: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final changeBus = RemoteChangeBus();
    final workspace = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-1',
          projectName: '工作流工程',
          database: database,
          directories: directories,
        ),
      );
    final source = _FakeWorkflowSource(image.path);
    final workflowRegistry = RemoteShootingWorkflowRegistry(
      workspaceRegistry: workspace,
      changeBus: changeBus,
    )..attach(source);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: workspace,
      changeBus: changeBus,
    );
    final facade = RemoteAccessFacade(
      workspaceRegistry: workspace,
      changeBus: changeBus,
      mediaRegistry: RemoteMediaRegistry(
        workspaceRegistry: workspace,
        secret: 'workflow-test',
      ),
      taskRegistry: taskRegistry,
      shootingWorkflowRegistry: workflowRegistry,
    );
    addTearDown(() async {
      workflowRegistry.dispose();
      await source.dispose();
      database.dispose();
      await changeBus.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final detail = facade.shootingWorkflow('script-1');
    final encoded = jsonEncode(detail);
    expect(encoded, isNot(contains(root.path)));
    expect(encoded, isNot(contains('localPath')));
    expect(
      ((detail['assets']! as List<Object?>).single
          as Map<String, Object?>)['mediaId'],
      isNotEmpty,
    );

    facade.confirmShootingWorkflowShots('script-1');
    expect(source.confirmCalls, 1);
    final started = facade.startShootingWorkflowAction(
      scriptId: 'script-1',
      action: 'matchAssets',
    );
    final taskId = started['id']! as String;
    for (var index = 0; index < 20; index++) {
      final task = facade.taskDetail(taskId);
      if (task['status'] == 'succeeded') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(facade.taskDetail(taskId)['status'], 'succeeded');
    expect(source.matchCalls, 1);
  });
}

class _FakeWorkflowSource implements RemoteShootingWorkflowSource {
  _FakeWorkflowSource(this.path);

  final String path;
  final StreamController<String> _changes = StreamController.broadcast();
  int confirmCalls = 0;
  int matchCalls = 0;

  @override
  Stream<String> get changes => _changes.stream;

  @override
  RemoteShootingWorkflowRecord? workflowFor(String scriptId) =>
      scriptId != 'script-1'
      ? null
      : RemoteShootingWorkflowRecord(
          scriptId: scriptId,
          currentStep: 'prepareAssets',
          confirmShotsStatus: 'pending',
          prepareAssetsStatus: 'pending',
          composePromptsStatus: 'pending',
          shotCount: 1,
          confirmedShotCount: 0,
          promptCount: 0,
          analysisCompletedCount: 0,
          analysisFailedCount: 0,
          analysisTotalCount: 1,
          isBusy: false,
          message: '',
          errorMessage: '',
          assets: [
            RemoteShootingWorkflowAssetRecord(
              id: 'asset-1',
              name: '角色参考',
              type: 'character',
              description: '主角',
              referenceNumber: 1,
              localPath: path,
            ),
          ],
          links: const [],
          replicas: const [],
        );

  @override
  void confirmShots(String scriptId) {
    confirmCalls++;
    _changes.add(scriptId);
  }

  @override
  Future<void> matchAssets(String scriptId) async {
    matchCalls++;
    _changes.add(scriptId);
  }

  @override
  Future<void> buildScript(String scriptId) async {}

  @override
  Future<void> replicateStoryboards(String scriptId, {String? shotId}) async {}

  @override
  void cancelBuild() {}

  @override
  void cancelMatching() {}

  Future<void> dispose() => _changes.close();
}
