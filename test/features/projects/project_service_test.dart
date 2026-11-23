import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/projects/application/project_service.dart';
import 'package:filmstoryboard/features/projects/application/project_workspace_controller.dart';
import 'package:filmstoryboard/features/projects/data/legacy_project_migrator.dart';
import 'package:filmstoryboard/features/projects/data/project_catalog_repository.dart';
import 'package:filmstoryboard/features/projects/data/project_aspect_repository.dart';
import 'package:filmstoryboard/features/projects/data/project_path_resolver.dart';
import 'package:filmstoryboard/features/projects/domain/project_aspect_ratio.dart';
import 'package:filmstoryboard/features/projects/domain/project_manifest.dart';
import 'package:filmstoryboard/features/projects/domain/project_models.dart';

void main() {
  group('ProjectManifest', () {
    test('round trips the portable project index', () {
      final now = DateTime.utc(2026, 7, 10, 12);
      final manifest = ProjectManifest(
        projectId: 'project-id',
        name: '测试工程',
        createdAt: now,
        updatedAt: now,
      );

      final restored = ProjectManifest.decode(manifest.encode());

      expect(restored.projectId, 'project-id');
      expect(restored.name, '测试工程');
      expect(restored.databasePath, 'database/project.sqlite');
    });

    test('rejects an unsupported schema version', () {
      expect(
        () => ProjectManifest.decode('''
          {
            "format": "storyboard-project",
            "schemaVersion": 99,
            "projectId": "id",
            "name": "name",
            "createdAt": "2026-07-10T00:00:00Z",
            "updatedAt": "2026-07-10T00:00:00Z",
            "databasePath": "database/project.sqlite"
          }
        '''),
        throwsUnsupportedError,
      );
    });
  });

  group('ProjectPathResolver', () {
    test('stores managed files as portable relative paths', () async {
      final root = await Directory.systemTemp.createTemp('project_paths_');
      addTearDown(() => root.delete(recursive: true));
      final resolver = ProjectPathResolver(root);
      final file = File(
        '${root.path}${Platform.pathSeparator}imports${Platform.pathSeparator}a.png',
      );

      expect(resolver.toStoredPath(file.path), 'imports/a.png');
      expect(resolver.toRuntimePath('imports/a.png'), file.path);
    });

    test('rejects traversal and external paths', () async {
      final root = await Directory.systemTemp.createTemp('project_paths_');
      addTearDown(() => root.delete(recursive: true));
      final resolver = ProjectPathResolver(root);

      expect(
        () => resolver.toRuntimePath('../outside.png'),
        throwsArgumentError,
      );
      expect(
        () => resolver.toStoredPath(root.parent.path),
        throwsArgumentError,
      );
    });
  });

  group('ProjectService', () {
    late Directory root;
    late AppDatabase globalDatabase;
    late ProjectCatalogRepository catalog;
    late ProjectService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('project_service_');
      globalDatabase = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}global.sqlite'),
      );
      catalog = ProjectCatalogRepository(globalDatabase);
      service = ProjectService(catalog: catalog);
    });

    tearDown(() async {
      globalDatabase.dispose();
      await root.delete(recursive: true);
    });

    test('creates, registers and reopens a project', () async {
      final projects = Directory(
        '${root.path}${Platform.pathSeparator}projects',
      );
      final firstSession = await service.createProject(
        name: '广告分镜',
        parentDirectory: projects,
      );
      final indexFile = firstSession.directories.indexFile;

      expect(indexFile.existsSync(), isTrue);
      expect(firstSession.directories.databaseFile.existsSync(), isTrue);
      expect(
        ProjectAspectRepository(firstSession.database).load().mode,
        ProjectAspectMode.auto,
      );
      expect(catalog.load().single.displayName, '广告分镜');
      await firstSession.close();

      final reopened = await service.openProject(indexFile);
      expect(reopened.manifest.projectId, catalog.load().single.projectId);
      await reopened.close();
    });

    test('创建工程时持久化手动竖屏画幅', () async {
      final projects = Directory(
        '${root.path}${Platform.pathSeparator}projects',
      );
      final session = await service.createProject(
        name: '竖屏广告',
        parentDirectory: projects,
        aspectMode: ProjectAspectMode.portrait,
      );

      final state = ProjectAspectRepository(session.database).load();
      expect(state.mode, ProjectAspectMode.portrait);
      expect(state.effectiveRatio, ProjectAspectRatio.portrait9x16);
      await session.close();
    });

    test('does not overwrite an existing same-name directory', () async {
      final projects = Directory(
        '${root.path}${Platform.pathSeparator}projects',
      );
      final first = await service.createProject(
        name: '广告分镜',
        parentDirectory: projects,
      );
      await first.close();
      final second = await service.createProject(
        name: '广告分镜',
        parentDirectory: projects,
      );

      expect(second.manifest.name, '广告分镜 (2)');
      await second.close();
    });

    test(
      'renames only the project display name and keeps its directory',
      () async {
        final projects = Directory(
          '${root.path}${Platform.pathSeparator}projects',
        );
        final session = await service.createProject(
          name: '旧版工程',
          parentDirectory: projects,
        );
        final indexFile = session.directories.indexFile;
        final originalDirectoryPath = indexFile.parent.path;
        await session.close();

        final renamed = await service.renameProject(
          entry: catalog.load().single,
          name: '自定义项目名称',
        );

        expect(renamed.name, '自定义项目名称');
        expect(indexFile.parent.path, originalDirectoryPath);
        expect(indexFile.existsSync(), isTrue);
        expect(
          ProjectManifest.decode(indexFile.readAsStringSync()).name,
          '自定义项目名称',
        );
        expect(catalog.load().single.displayName, '自定义项目名称');
        expect(catalog.load().single.indexPath, indexFile.path);
      },
    );

    test('rejects Windows reserved project names', () {
      expect(service.validateProjectName('CON'), isNotNull);
      expect(service.validateProjectName('valid name'), isNull);
    });
  });

  test('legacy migration copies project data without global secrets', () async {
    final root = await Directory.systemTemp.createTemp('legacy_migration_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final globalDatabase = await AppDatabase.open(directories.databaseFile);
    addTearDown(() async {
      globalDatabase.dispose();
      await root.delete(recursive: true);
    });
    final image = File(
      '${directories.imports.path}${Platform.pathSeparator}legacy.png',
    );
    await image.writeAsBytes([1, 2, 3]);
    globalDatabase.upsertImportedImage(
      id: 'legacy-image',
      originalPath: 'clipboard',
      originalName: 'legacy.png',
      storedPath: image.path,
      width: 10,
      height: 10,
      createdAt: DateTime.utc(2026, 7, 10).toIso8601String(),
    );
    globalDatabase
      ..setSetting('visionApiKey', 'must-not-be-exported')
      ..setSetting(
        'gridCutWorkspaceSnapshot',
        '{"images":[{"storedPath":${_jsonString(image.path)}}]}',
      );
    final catalog = ProjectCatalogRepository(globalDatabase);
    final migrator = LegacyProjectMigrator(
      appDirectories: directories,
      globalDatabase: globalDatabase,
      catalog: catalog,
    );

    final result = await migrator.migrateIfNeeded();

    expect(result.status, LegacyMigrationStatus.migrated);
    expect(image.existsSync(), isTrue, reason: '旧版素材必须保留');
    final migratedDatabase = await AppDatabase.open(
      File(
        '${result.indexFile!.parent.path}${Platform.pathSeparator}database'
        '${Platform.pathSeparator}project.sqlite',
      ),
    );
    expect(migratedDatabase.countRows('imported_images'), 1);
    expect(migratedDatabase.getSetting('visionApiKey'), isNull);
    expect(
      migratedDatabase.getSetting('gridCutWorkspaceSnapshot'),
      contains('imports/legacy.png'),
    );
    migratedDatabase.dispose();
  });

  test(
    'workspace gate opens the editor only after a project session exists',
    () async {
      final root = await Directory.systemTemp.createTemp('workspace_gate_');
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      final globalDatabase = await AppDatabase.open(directories.databaseFile);
      final catalog = ProjectCatalogRepository(globalDatabase);
      final service = ProjectService(catalog: catalog);
      final controller = ProjectWorkspaceController(
        appDirectories: directories,
        globalDatabase: globalDatabase,
        catalog: catalog,
        projectService: service,
        legacyMigrator: LegacyProjectMigrator(
          appDirectories: directories,
          globalDatabase: globalDatabase,
          catalog: catalog,
        ),
      );
      addTearDown(() async {
        await controller.disposeSession();
        controller.dispose();
        globalDatabase.dispose();
        await root.delete(recursive: true);
      });

      await controller.initialize();
      expect(controller.phase, ProjectWorkspacePhase.welcome);
      expect(controller.session, isNull);

      await controller.createProject(name: '门禁测试工程');
      expect(controller.phase, ProjectWorkspacePhase.editor);
      expect(controller.session, isNotNull);

      await controller.closeProject();
      expect(controller.phase, ProjectWorkspacePhase.home);
      expect(controller.session, isNull);

      final entry = controller.projects.single;
      final directoryPath = File(entry.indexPath).parent.path;
      await controller.renameProject(entry, '重命名后的工程');
      expect(controller.projects.single.displayName, '重命名后的工程');
      expect(
        File(controller.projects.single.indexPath).parent.path,
        directoryPath,
      );
    },
  );

  test(
    'remote catalog switch keeps current project when target open fails',
    () async {
      final root = await Directory.systemTemp.createTemp('workspace_switch_');
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      final globalDatabase = await AppDatabase.open(directories.databaseFile);
      final catalog = ProjectCatalogRepository(globalDatabase);
      final service = ProjectService(catalog: catalog);
      final controller = ProjectWorkspaceController(
        appDirectories: directories,
        globalDatabase: globalDatabase,
        catalog: catalog,
        projectService: service,
        legacyMigrator: LegacyProjectMigrator(
          appDirectories: directories,
          globalDatabase: globalDatabase,
          catalog: catalog,
        ),
      );
      addTearDown(() async {
        await controller.disposeSession();
        controller.dispose();
        globalDatabase.dispose();
        await root.delete(recursive: true);
      });

      await controller.initialize();
      await controller.createProject(name: '当前工程');
      final currentId = controller.session!.manifest.projectId;
      final targetSession = await service.createProject(
        name: '目标工程',
        parentDirectory: controller.defaultProjectRoot,
      );
      final targetId = targetSession.manifest.projectId;
      await targetSession.close();
      await controller.refreshProjects();
      final target = controller.projects.singleWhere(
        (entry) => entry.projectId == targetId,
      );

      await controller.switchToCatalogProject(target);
      expect(controller.session!.manifest.projectId, targetId);
      expect(controller.phase, ProjectWorkspacePhase.editor);

      final brokenSession = await service.createProject(
        name: '稍后损坏的工程',
        parentDirectory: controller.defaultProjectRoot,
      );
      final brokenId = brokenSession.manifest.projectId;
      await brokenSession.close();
      await controller.refreshProjects();
      final staleAvailableEntry = controller.projects.singleWhere(
        (entry) => entry.projectId == brokenId,
      );
      await File(staleAvailableEntry.indexPath).delete();

      await expectLater(
        controller.switchToCatalogProject(staleAvailableEntry),
        throwsA(isA<ProjectException>()),
      );
      expect(controller.session!.manifest.projectId, targetId);
      expect(controller.session!.manifest.projectId, isNot(currentId));
      expect(controller.phase, ProjectWorkspacePhase.editor);
    },
  );
}

String _jsonString(String value) {
  return '"${value.replaceAll('\\', '\\\\')}"';
}
