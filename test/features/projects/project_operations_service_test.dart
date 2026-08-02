import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/application/project_service.dart';
import 'package:filmstoryboard/features/projects/data/project_catalog_repository.dart';
import 'package:filmstoryboard/features/projects/data/project_operations_service.dart';
import 'package:filmstoryboard/features/projects/domain/project_models.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';

void main() {
  late Directory root;
  late Directory projectsRoot;
  late AppDatabase globalDatabase;
  late ProjectCatalogRepository catalog;
  late ProjectService projectService;
  late ProjectOperationsService operations;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('project_operations_');
    projectsRoot = Directory(p.join(root.path, 'projects'));
    globalDatabase = await AppDatabase.open(
      File(p.join(root.path, 'global.sqlite')),
    );
    catalog = ProjectCatalogRepository(globalDatabase);
    projectService = ProjectService(catalog: catalog);
    operations = ProjectOperationsService(catalog: catalog);
  });

  tearDown(() async {
    globalDatabase.dispose();
    await root.delete(recursive: true);
  });

  test(
    'exports a checksummed package and imports duplicate as a copy',
    () async {
      final session = await projectService.createProject(
        name: '包装测试',
        parentDirectory: projectsRoot,
      );
      final originalId = session.manifest.projectId;
      await File(
        p.join(session.directories.imports.path, 'frame.png'),
      ).writeAsBytes([1, 2, 3, 4]);
      await File(
        p.join(session.directories.temp.path, 'ignored.tmp'),
      ).writeAsString('temporary');
      await File(
        p.join(session.directories.logs.path, 'ignored.log'),
      ).writeAsString('log');
      await session.close();
      globalDatabase.setSetting('visionApiKey', 'global-secret');
      final entry = catalog.load().single;
      final package = File(p.join(root.path, 'project.storyboard.zip'));

      await operations.exportProject(entry: entry, outputFile: package);

      final archive = ZipDecoder().decodeBytes(
        await package.readAsBytes(),
        verify: true,
      );
      final names = archive.files.map((file) => file.name).toSet();
      expect(names, contains('package-manifest.json'));
      expect(names, contains('project.storyboard'));
      expect(names, contains('imports/frame.png'));
      expect(names.any((name) => name.startsWith('temp/')), isFalse);
      expect(names.any((name) => name.startsWith('logs/')), isFalse);

      final imported = await operations.importPackage(
        packageFile: package,
        projectRoot: projectsRoot,
      );

      expect(imported.projectId, isNot(originalId));
      expect(imported.displayName, contains('副本'));
      final importedSession = await projectService.openProject(
        File(imported.indexPath),
      );
      expect(importedSession.database.getSetting('visionApiKey'), isNull);
      expect(
        File(
          p.join(importedSession.directories.imports.path, 'frame.png'),
        ).existsSync(),
        isTrue,
      );
      await importedSession.close();
    },
  );

  test(
    'imports a complete storyboard workspace with portable asset paths',
    () async {
      final source = await projectService.createProject(
        name: '完整画板工程',
        parentDirectory: projectsRoot,
      );
      final sourceCut = File(
        p.join(source.directories.cuts.path, 'scene-1.png'),
      );
      final sourceGenerated = File(
        p.join(
          source.directories.generatedImages.path,
          'board-1',
          'scene-2.png',
        ),
      );
      await sourceCut.writeAsBytes([1, 2, 3]);
      await sourceGenerated.parent.create(recursive: true);
      await sourceGenerated.writeAsBytes([4, 5, 6]);
      _insertCutAsset(
        source.database,
        idPrefix: 'cut',
        originalName: 'scene-1.png',
        path: 'cuts/scene-1.png',
      );
      _insertCutAsset(
        source.database,
        idPrefix: 'generated',
        originalName: 'scene-2.png',
        path: sourceGenerated.path,
      );
      final sourceController = StoryboardController(
        database: source.database,
        directories: source.directories,
      );
      await sourceController.refreshAssets();
      sourceController
        ..renameSelectedBoard('迁移画板')
        ..setAssetsUsed(sourceController.value.assets, true)
        ..updateCaption(0, '第一格')
        ..updateCaption(1, '第二格')
        ..addBoard()
        ..renameSelectedBoard('西部牛仔单人篇')
        ..setAssetsUsed(sourceController.value.assets.take(1), true)
        ..dispose();
      await source.close();
      final package = File(p.join(root.path, 'complete.storyboard.zip'));
      await operations.exportProject(
        entry: catalog.load().single,
        outputFile: package,
      );

      final imported = await operations.importPackage(
        packageFile: package,
        projectRoot: Directory(p.join(root.path, 'new-device-projects')),
      );
      final restored = await projectService.openProject(
        File(imported.indexPath),
      );
      final restoredController = StoryboardController(
        database: restored.database,
        directories: restored.directories,
      );
      await restoredController.refreshAssets();

      expect(restored.database.listCutResults(), hasLength(2));
      expect(
        restoredController.value.assets.map((asset) => asset.path),
        containsAll([
          p.join(restored.directories.cuts.path, 'scene-1.png'),
          p.join(
            restored.directories.generatedImages.path,
            'board-1',
            'scene-2.png',
          ),
        ]),
      );
      expect(
        restoredController.value.boards.map((board) => board.name),
        containsAll(['迁移画板', '西部牛仔单人篇']),
      );
      final restoredBoard = restoredController.value.boards.firstWhere(
        (board) => board.name == '迁移画板',
      );
      expect(restoredBoard.items, hasLength(2));
      expect(restoredBoard.itemAtSlot(0)!.caption, '第一格');
      expect(restoredBoard.itemAtSlot(1)!.caption, '第二格');

      restoredController.dispose();
      await restored.close();
    },
  );

  test(
    'rejects a package whose payload no longer matches its digest',
    () async {
      final session = await projectService.createProject(
        name: '摘要测试',
        parentDirectory: projectsRoot,
      );
      await File(
        p.join(session.directories.imports.path, 'frame.png'),
      ).writeAsBytes([1, 2, 3]);
      await session.close();
      final package = File(p.join(root.path, 'valid.zip'));
      await operations.exportProject(
        entry: catalog.load().single,
        outputFile: package,
      );
      final archive = ZipDecoder().decodeBytes(await package.readAsBytes());
      final tampered = Archive();
      for (final file in archive.files) {
        tampered.addFile(
          ArchiveFile.bytes(
            file.name,
            file.name == 'imports/frame.png' ? [9, 9, 9] : file.content,
          ),
        );
      }
      final badPackage = File(p.join(root.path, 'tampered.zip'));
      await badPackage.writeAsBytes(ZipEncoder().encode(tampered));

      expect(
        () => operations.importPackage(
          packageFile: badPackage,
          projectRoot: projectsRoot,
        ),
        throwsA(isA<ProjectException>()),
      );
    },
  );

  test('migrates after verification and protects permanent deletion', () async {
    final session = await projectService.createProject(
      name: '迁移测试',
      parentDirectory: projectsRoot,
    );
    await File(
      p.join(session.directories.imports.path, 'frame.png'),
    ).writeAsBytes(utf8.encode('image'));
    final sourceRoot = session.directories.root;
    await session.close();
    final targetParent = Directory(p.join(root.path, 'custom'));

    final result = await operations.migrateProject(
      entry: catalog.load().single,
      targetParent: targetParent,
    );

    expect(result.oldSourceRetained, isFalse);
    expect(sourceRoot.existsSync(), isFalse);
    expect(File(result.entry.indexPath).existsSync(), isTrue);
    expect(
      File(
        p.join(
          File(result.entry.indexPath).parent.path,
          'imports',
          'frame.png',
        ),
      ).existsSync(),
      isTrue,
    );
    await expectLater(
      operations.permanentlyDeleteProject(
        entry: result.entry,
        defaultProjectRoot: projectsRoot,
        confirmedName: '错误名称',
      ),
      throwsA(isA<ProjectException>()),
    );
    expect(File(result.entry.indexPath).existsSync(), isTrue);

    await operations.permanentlyDeleteProject(
      entry: result.entry,
      defaultProjectRoot: projectsRoot,
      confirmedName: result.entry.displayName,
    );
    expect(File(result.entry.indexPath).existsSync(), isFalse);
    expect(catalog.load(), isEmpty);
  });
}

void _insertCutAsset(
  AppDatabase database, {
  required String idPrefix,
  required String originalName,
  required String path,
}) {
  final imageId = '$idPrefix-image';
  final taskId = '$idPrefix-task';
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: path,
      originalName: originalName,
      storedPath: path,
      width: 1,
      height: 1,
      createdAt: DateTime.now().toIso8601String(),
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'completed',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: '$idPrefix-result',
      taskId: taskId,
      imageId: imageId,
      indexNo: 1,
      path: path,
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      selected: true,
    );
}
