import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/storyboard/presentation/storyboard_page.dart';

void main() {
  testWidgets('损坏的资源编组环不会阻塞故事板首帧', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'storyboard_resource_cycle_',
      );
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      database.setSetting(
        'storyboardWorkspaceSnapshot',
        jsonEncode({
          'version': 4,
          'selectedBoardId': 'board-1',
          'openBoardIds': ['board-1'],
          'boards': [
            {
              'id': 'board-1',
              'name': '画板 1',
              'width': 1920,
              'height': 1200,
              'rows': 3,
              'columns': 3,
              'gap': 18,
              'items': [],
            },
          ],
          'resourceRootOrder': ['group:group-a'],
          'resourceGroups': [
            {
              'id': 'group-a',
              'name': 'A',
              'parentGroupId': 'group-b',
              'childOrder': ['group:group-b'],
            },
            {
              'id': 'group-b',
              'name': 'B',
              'parentGroupId': 'group-a',
              'childOrder': ['group:group-a'],
            },
          ],
        }),
      );
    });

    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          projectDirectoriesProvider.overrideWithValue(directories),
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('storyboard-canvas-viewport')),
      findsOneWidget,
    );
    expect(controller.value.resourceGroups, hasLength(2));

    final groupsById = {
      for (final group in controller.value.resourceGroups) group.id: group,
    };
    for (final group in controller.value.resourceGroups) {
      final visited = <String>{};
      var currentId = group.id;
      var cycleDetected = false;
      while (true) {
        if (!visited.add(currentId)) {
          cycleDetected = true;
          break;
        }
        final parentId = groupsById[currentId]?.parentGroupId;
        if (parentId == null) {
          break;
        }
        currentId = parentId;
      }
      expect(cycleDetected, isFalse);
    }
  });

  test('原故事板帧查找复用生成记录索引并解析来源链', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_original_frame_cache_',
    );
    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    final originalFile = File(p.join(root.path, 'original.png'))
      ..writeAsBytesSync([1]);
    final resultFile = File(p.join(root.path, 'result.png'))
      ..writeAsBytesSync([2]);
    database
      ..insertImageGenerationRecord(
        id: 'generation-1',
        boardId: 'board-1',
        slotIndex: 0,
        sourceAssetId: 'source-asset',
        sourcePath: originalFile.path,
        model: 'test-model',
        prompt: 'test',
        aspectRatio: '16:9',
        imageSize: '1K',
        quality: 'auto',
        referencePathsJson: '[]',
        status: 'running',
      )
      ..updateImageGenerationRecord(
        id: 'generation-1',
        status: 'succeeded',
        resultAssetId: 'result-asset',
        resultPath: resultFile.path,
      );
    final controller = StoryboardController(database: database);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final item = StoryboardItem(
      asset: StoryboardCutAsset(
        id: 'result-asset',
        imageId: 'result-image',
        sourceName: 'result.png',
        path: resultFile.path,
        indexNo: 1,
      ),
      caption: '',
      slotIndex: 0,
    );

    expect(controller.originalImagePathForItem(item), originalFile.path);
    expect(controller.originalImagePathForItem(item), originalFile.path);
  });
}
