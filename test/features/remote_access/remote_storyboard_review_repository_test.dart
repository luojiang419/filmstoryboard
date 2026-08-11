import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/remote_access/data/remote_storyboard_review_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('批注在工程数据库中持久化并按未解决优先排序', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    var id = 0;
    var now = DateTime.utc(2026, 8, 11, 1);
    final repository = RemoteStoryboardReviewRepository(
      fixture.database,
      idFactory: () => 'annotation-${++id}',
      clock: () => now,
    );

    final first = repository.create(
      boardId: 'board-1',
      assetId: 'asset-1',
      body: '  调整人物视线  ',
      authorSessionId: 'session-1',
      authorName: '远端导演',
    );
    now = now.add(const Duration(minutes: 1));
    final second = repository.create(
      boardId: 'board-1',
      body: '检查整场节奏',
      authorSessionId: 'session-1',
      authorName: '远端导演',
    );
    now = now.add(const Duration(minutes: 1));
    repository.update(annotationId: first.id, resolved: true);

    final reopened = RemoteStoryboardReviewRepository(fixture.database);
    final annotations = reopened.listForBoard('board-1');
    expect(annotations.map((item) => item.id), [second.id, first.id]);
    expect(annotations.last.body, '调整人物视线');
    expect(annotations.last.resolved, isTrue);
    expect(annotations.last.updatedAt, now);
    final stored =
        jsonDecode(
              fixture.database.getSetting(
                RemoteStoryboardReviewRepository.storageKey,
              )!,
            )
            as Map<String, Object?>;
    expect(stored['version'], 1);
  });

  test('清理已删除画板和镜头的孤立批注', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    var id = 0;
    final repository = RemoteStoryboardReviewRepository(
      fixture.database,
      idFactory: () => 'annotation-${++id}',
    );
    repository
      ..create(
        boardId: 'board-1',
        assetId: 'asset-kept',
        body: '保留',
        authorSessionId: 'session',
        authorName: '导演',
      )
      ..create(
        boardId: 'board-1',
        assetId: 'asset-removed',
        body: '镜头已删除',
        authorSessionId: 'session',
        authorName: '导演',
      )
      ..create(
        boardId: 'board-removed',
        body: '画板已删除',
        authorSessionId: 'session',
        authorName: '导演',
      );

    expect(
      repository.prune(
        boardIds: const {'board-1'},
        assetIdsByBoard: const {
          'board-1': {'asset-kept'},
        },
      ),
      isTrue,
    );
    expect(repository.listForBoard('board-1').single.body, '保留');
    expect(repository.listForBoard('board-removed'), isEmpty);
    expect(
      repository.prune(
        boardIds: const {'board-1'},
        assetIdsByBoard: const {
          'board-1': {'asset-kept'},
        },
      ),
      isFalse,
    );
  });

  test('空正文、超长正文和无字段更新会被拒绝', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final repository = RemoteStoryboardReviewRepository(
      fixture.database,
      idFactory: () => 'annotation-1',
    );

    expect(
      () => repository.create(
        boardId: 'board',
        body: '   ',
        authorSessionId: 'session',
        authorName: '导演',
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.create(
        boardId: 'board',
        body: 'a' * (RemoteStoryboardReviewRepository.maxBodyLength + 1),
        authorSessionId: 'session',
        authorName: '导演',
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.update(annotationId: 'missing'),
      throwsArgumentError,
    );
  });
}

class _Fixture {
  const _Fixture({required this.root, required this.database});

  final Directory root;
  final AppDatabase database;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'remote-storyboard-review-',
    );
    final database = await AppDatabase.open(File('${root.path}/data.db'));
    return _Fixture(root: root, database: database);
  }

  Future<void> dispose() async {
    database.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
