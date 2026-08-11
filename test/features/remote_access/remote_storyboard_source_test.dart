import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_storyboard_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_storyboard_models.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_remote_source.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('远程定向编辑不切换桌面画板并发布递增修订事件', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final firstBoard = fixture.controller.value.selectedBoard!;
    fixture.controller.addOrRemoveAsset(
      const StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: '焦点帧',
        path: r'C:\not-exposed\frame.png',
        indexNo: 1,
      ),
    );
    final secondBoard = fixture.controller.addBoard();
    expect(fixture.controller.value.selectedBoardId, secondBoard.id);
    final revisionBeforeEdit = fixture.storyboardRegistry.revisionFor(
      firstBoard.id,
    );

    final eventFuture = fixture.changeBus.events.firstWhere(
      (event) =>
          event.type == 'storyboard.changed' &&
          event.resourceId == firstBoard.id,
    );
    final outcome = fixture.storyboardRegistry.performRemoteMutation(
      (source) => source.applyEdit(
        RemoteStoryboardEditCommand(
          boardId: firstBoard.id,
          name: '导演审阅版',
          itemCaptions: const {'asset-1': '远程修改后的镜头描述'},
          summary: const RemoteStoryboardSummaryRecord(
            outline: '故事梗概',
            content: '主要内容',
            scenes: '室内',
            props: '手表',
          ),
        ),
      ),
    );

    expect(outcome, RemoteStoryboardEditOutcome.updated);
    expect(fixture.controller.value.selectedBoardId, secondBoard.id);
    final updated = fixture.controller.value.boards.firstWhere(
      (board) => board.id == firstBoard.id,
    );
    expect(updated.name, '导演审阅版');
    expect(updated.items.single.caption, '远程修改后的镜头描述');
    expect(updated.summary?.outline, '故事梗概');
    final event = await eventFuture;
    expect(event.revision, revisionBeforeEdit + 1);
    expect(event.data['source'], 'remote');

    final snapshot =
        jsonDecode(fixture.database.getSetting('storyboardWorkspaceSnapshot')!)
            as Map<String, Object?>;
    final boards = snapshot['boards']! as List<Object?>;
    expect(
      boards.cast<Map<String, Object?>>().firstWhere(
        (board) => board['id'] == firstBoard.id,
      )['name'],
      '导演审阅版',
    );
  });

  test('选择变化不产生内容事件且锁定画板拒绝远程编辑', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final firstBoard = fixture.controller.value.selectedBoard!;
    final secondBoard = fixture.controller.addBoard();
    var storyboardEventCount = 0;
    final subscription = fixture.changeBus.events.listen((event) {
      if (event.type.startsWith('storyboard')) storyboardEventCount++;
    });
    addTearDown(subscription.cancel);

    fixture.controller.selectBoard(firstBoard.id);
    fixture.controller.selectBoard(secondBoard.id);
    expect(storyboardEventCount, 0);

    fixture.controller.selectBoard(firstBoard.id);
    fixture.controller.toggleSelectedBoardLock();
    fixture.controller.selectBoard(secondBoard.id);
    expect(storyboardEventCount, 1);
    final outcome = fixture.storyboardRegistry.performRemoteMutation(
      (source) => source.applyEdit(
        RemoteStoryboardEditCommand(boardId: firstBoard.id, name: '不应保存的名称'),
      ),
    );

    expect(outcome, RemoteStoryboardEditOutcome.locked);
    expect(
      fixture.controller.value.boards
          .firstWhere((board) => board.id == firstBoard.id)
          .name,
      firstBoard.name,
    );
    expect(fixture.controller.value.selectedBoardId, secondBoard.id);
    expect(storyboardEventCount, 1);
  });
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.directories,
    required this.database,
    required this.changeBus,
    required this.workspaceRegistry,
    required this.controller,
    required this.source,
    required this.storyboardRegistry,
  });

  final Directory root;
  final ProjectDirectories directories;
  final AppDatabase database;
  final RemoteChangeBus changeBus;
  final RemoteWorkspaceRegistry workspaceRegistry;
  final StoryboardController controller;
  final StoryboardRemoteSource source;
  final RemoteStoryboardRegistry storyboardRegistry;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'remote-storyboard-source-',
    );
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-storyboard',
          projectName: '故事板工程',
          database: database,
          directories: directories,
        ),
      );
    final controller = StoryboardController(database: database);
    final source = StoryboardRemoteSource(controller);
    final storyboardRegistry = RemoteStoryboardRegistry(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
    )..attach(source);
    return _Fixture(
      root: root,
      directories: directories,
      database: database,
      changeBus: changeBus,
      workspaceRegistry: workspaceRegistry,
      controller: controller,
      source: source,
      storyboardRegistry: storyboardRegistry,
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
