import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_storyboard_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_remote_source.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('列表和详情投影媒体 ID 且不泄露本地路径', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    final workspace = fixture.facade.workspaceOverview();
    final statistics =
        (workspace['project']! as Map<String, Object?>)['statistics']!
            as Map<String, Object?>;
    expect(statistics['storyboardCount'], 1);
    final list = fixture.facade.listStoryboards();
    final summary =
        (list['items']! as List<Object?>).single as Map<String, Object?>;
    expect(summary['id'], fixture.boardId);
    expect(summary['revision'], 1);

    final detail = fixture.facade.storyboardDetail(fixture.boardId);
    final item =
        (detail['items']! as List<Object?>).single as Map<String, Object?>;
    expect(item['imageRemotelyAvailable'], isTrue);
    expect(item['imageMediaId'], isNotEmpty);
    expect(jsonEncode(detail), isNot(contains(fixture.root.path)));
    expect(jsonEncode(detail), isNot(contains('localPath')));
    final assets = fixture.facade.storyboardAssets(fixture.boardId);
    final asset =
        (assets['items']! as List<Object?>).single as Map<String, Object?>;
    expect(asset['id'], 'asset-1');
    expect(asset['used'], isTrue);
    expect(asset['imageMediaId'], isNotEmpty);
    expect(jsonEncode(assets), isNot(contains(fixture.root.path)));
    expect(jsonEncode(assets), isNot(contains('localPath')));
  });

  test('布局命令校验修订号并通过资源 ID 移除镜头', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final revision = fixture.storyboardRegistry.revisionFor(fixture.boardId);

    final updated = fixture.facade.updateStoryboardLayout(
      boardId: fixture.boardId,
      expectedRevision: revision,
      action: 'remove',
      assetId: 'asset-1',
    );

    expect(updated['revision'], revision + 1);
    expect(updated['itemCount'], 0);
    expect(
      () => fixture.facade.updateStoryboardLayout(
        boardId: fixture.boardId,
        expectedRevision: revision,
        action: 'remove',
        assetId: 'asset-1',
      ),
      throwsA(
        isA<RemoteOperationException>().having(
          (error) => error.code,
          'code',
          'revision_conflict',
        ),
      ),
    );
  });

  test('必要编辑和批注共用修订冲突且锁定只阻止内容编辑', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final initialRevision = fixture.storyboardRegistry.revisionFor(
      fixture.boardId,
    );

    final updated = fixture.facade.updateStoryboard(
      boardId: fixture.boardId,
      expectedRevision: initialRevision,
      changes: const {
        'name': '导演审阅版',
        'itemCaptions': {'asset-1': '需要更有张力'},
        'summary': {'outline': '新的故事梗概'},
      },
    );
    expect(updated['revision'], initialRevision + 1);
    expect(updated['name'], '导演审阅版');
    expect(
      ((updated['items']! as List<Object?>).single
          as Map<String, Object?>)['caption'],
      '需要更有张力',
    );
    expect(
      () => fixture.facade.updateStoryboard(
        boardId: fixture.boardId,
        expectedRevision: initialRevision,
        changes: const {'name': '旧客户端覆盖'},
      ),
      throwsA(
        isA<RemoteOperationException>()
            .having((error) => error.code, 'code', 'revision_conflict')
            .having(
              (error) => error.details['currentRevision'],
              'currentRevision',
              initialRevision + 1,
            ),
      ),
    );

    final annotated = fixture.facade.addStoryboardAnnotation(
      boardId: fixture.boardId,
      expectedRevision: updated['revision']! as int,
      assetId: 'asset-1',
      body: '人物视线再向左一点',
      authorSessionId: 'session-director',
      authorName: '远端导演',
    );
    expect(annotated['revision'], initialRevision + 2);
    final annotation =
        (annotated['annotations']! as List<Object?>).single
            as Map<String, Object?>;
    expect(annotation['authorName'], '远端导演');
    expect(jsonEncode(annotation), isNot(contains('session-director')));
    expect(
      () => fixture.facade.updateStoryboardAnnotation(
        boardId: fixture.boardId,
        annotationId: annotation['id']! as String,
        expectedRevision: annotated['revision']! as int,
        changes: const {'body': null, 'resolved': true},
      ),
      throwsA(
        isA<RemoteOperationException>().having(
          (error) => error.code,
          'code',
          'invalid_changes',
        ),
      ),
    );
    final resolved = fixture.facade.updateStoryboardAnnotation(
      boardId: fixture.boardId,
      annotationId: annotation['id']! as String,
      expectedRevision: annotated['revision']! as int,
      changes: const {'resolved': true},
    );
    expect(resolved['revision'], initialRevision + 3);
    expect(
      ((resolved['annotations']! as List<Object?>).single
          as Map<String, Object?>)['resolved'],
      isTrue,
    );

    fixture.controller.toggleSelectedBoardLock();
    final lockedRevision = fixture.storyboardRegistry.revisionFor(
      fixture.boardId,
    );
    expect(
      () => fixture.facade.updateStoryboard(
        boardId: fixture.boardId,
        expectedRevision: lockedRevision,
        changes: const {'name': '锁定后不允许'},
      ),
      throwsA(
        isA<RemoteOperationException>().having(
          (error) => error.code,
          'code',
          'storyboard_locked',
        ),
      ),
    );
    final lockedAnnotation = fixture.facade.addStoryboardAnnotation(
      boardId: fixture.boardId,
      expectedRevision: lockedRevision,
      body: '锁定后仍可审阅',
      authorSessionId: 'session-director',
      authorName: '远端导演',
    );
    expect(lockedAnnotation['annotationCount'], 2);
  });
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.database,
    required this.changeBus,
    required this.controller,
    required this.source,
    required this.storyboardRegistry,
    required this.facade,
    required this.boardId,
  });

  final Directory root;
  final AppDatabase database;
  final RemoteChangeBus changeBus;
  final StoryboardController controller;
  final StoryboardRemoteSource source;
  final RemoteStoryboardRegistry storyboardRegistry;
  final RemoteAccessFacade facade;
  final String boardId;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'remote-storyboard-facade-',
    );
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final image = File('${directories.frames.path}/frame.png');
    await image.writeAsBytes(const [0, 1, 2, 3]);
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-facade',
          projectName: 'Facade 工程',
          database: database,
          directories: directories,
        ),
      );
    final mediaRegistry = RemoteMediaRegistry(
      workspaceRegistry: workspaceRegistry,
      secret: 'storyboard-facade-media',
    );
    final controller = StoryboardController(database: database);
    final boardId = controller.value.selectedBoardId!;
    controller.addOrRemoveAsset(
      StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: '焦点帧',
        path: image.path,
        indexNo: 1,
      ),
    );
    final source = StoryboardRemoteSource(controller);
    final storyboardRegistry = RemoteStoryboardRegistry(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
    )..attach(source);
    final facade = RemoteAccessFacade(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
      storyboardRegistry: storyboardRegistry,
    );
    return _Fixture(
      root: root,
      database: database,
      changeBus: changeBus,
      controller: controller,
      source: source,
      storyboardRegistry: storyboardRegistry,
      facade: facade,
      boardId: boardId,
    );
  }

  Future<void> dispose() async {
    storyboardRegistry.dispose();
    source.dispose();
    controller.dispose();
    database.dispose();
    await changeBus.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
