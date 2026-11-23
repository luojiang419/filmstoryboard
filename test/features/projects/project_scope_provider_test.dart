import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';

void main() {
  test('项目作用域中的故事板控制器不读取全局旧项目快照', () async {
    final root = await Directory.systemTemp.createTemp('project_scope_');
    final appDirectories = await AppDirectories.create(
      executableDirectory: root,
    );
    final globalDatabase = await AppDatabase.open(appDirectories.databaseFile);
    final projectDirectories = ProjectDirectories.fromRoot(
      Directory(p.join(root.path, '秋冬广告')),
    );
    await projectDirectories.create();
    final projectDatabase = await AppDatabase.open(
      projectDirectories.databaseFile,
    );
    final settingsRepository = SettingsRepository(
      globalDatabase,
      appDirectories,
    );
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final globalStoryboard =
        StoryboardController(
            database: globalDatabase,
            directories: appDirectories,
          )
          ..renameSelectedBoard('001')
          ..addBoard();
    globalStoryboard.dispose();
    final projectStoryboard =
        StoryboardController(
            database: projectDatabase,
            directories: projectDirectories,
          )
          ..renameSelectedBoard('西部牛仔双人篇')
          ..addBoard()
          ..renameSelectedBoard('西部牛仔单人篇');
    projectStoryboard.dispose();

    final rootContainer = ProviderContainer(
      overrides: [
        globalDatabaseProvider.overrideWithValue(globalDatabase),
        appDirectoriesProvider.overrideWithValue(appDirectories),
        settingsRepositoryProvider.overrideWithValue(settingsRepository),
        settingsControllerProvider.overrideWithValue(settingsController),
      ],
    );
    final projectContainer = ProviderContainer(
      parent: rootContainer,
      overrides: [
        projectDatabaseProvider.overrideWithValue(projectDatabase),
        projectDirectoriesProvider.overrideWithValue(projectDirectories),
        currentProjectNameProvider.overrideWithValue('0714-LV秋冬广告'),
      ],
    );
    addTearDown(() async {
      projectContainer.dispose();
      rootContainer.dispose();
      settingsController.dispose();
      projectDatabase.dispose();
      globalDatabase.dispose();
      await root.delete(recursive: true);
    });

    final restored = projectContainer.read(storyboardControllerProvider);

    expect(restored.value.boards.map((board) => board.name), [
      '西部牛仔双人篇',
      '西部牛仔单人篇',
    ]);
    expect(
      restored.value.boards.map((board) => board.name),
      isNot(contains('001')),
    );
  });
}
