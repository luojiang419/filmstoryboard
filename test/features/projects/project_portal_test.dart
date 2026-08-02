import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/projects/application/project_service.dart';
import 'package:filmstoryboard/features/projects/application/project_workspace_controller.dart';
import 'package:filmstoryboard/features/projects/data/project_catalog_repository.dart';
import 'package:filmstoryboard/features/projects/presentation/project_portal.dart';

void main() {
  test('工程门户组件可以加载', () {
    expect(const ProjectPortal(), isA<ProjectPortal>());
  });

  testWidgets('工程首页提供已有工程的重命名入口', (tester) async {
    late Directory root;
    late AppDirectories directories;
    late AppDatabase database;
    late String projectId;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('project_portal_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final catalog = ProjectCatalogRepository(database);
      final service = ProjectService(catalog: catalog);
      final session = await service.createProject(
        name: '旧版工程',
        parentDirectory: directories.projects,
      );
      projectId = session.manifest.projectId;
      await session.close();
    });
    database.setSetting(
      ProjectWorkspaceController.showWelcomeSettingKey,
      'false',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      database.dispose();
      for (var i = 0; i < 5 && root.existsSync(); i++) {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          globalDatabaseProvider.overrideWithValue(database),
          appDirectoriesProvider.overrideWithValue(directories),
        ],
        child: const MaterialApp(home: ProjectPortal()),
      ),
    );
    for (var i = 0; i < 20 && find.text('旧版工程').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.byKey(ValueKey('rename-project-$projectId')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(
      find.byKey(const ValueKey('rename-project-name')),
      '我的故事项目',
    );
    expect(find.text('我的故事项目'), findsOneWidget);
    expect(find.text('只修改显示名称，不改变磁盘文件夹路径'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-rename-project')),
      findsOneWidget,
    );
  });
}
