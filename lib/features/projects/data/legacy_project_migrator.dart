import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_directories.dart';
import '../domain/project_manifest.dart';
import 'project_catalog_repository.dart';
import 'project_directories.dart';
import 'project_path_resolver.dart';

enum LegacyMigrationStatus { noData, alreadyMigrated, migrated }

class LegacyMigrationResult {
  const LegacyMigrationResult(this.status, {this.manifest, this.indexFile});

  final LegacyMigrationStatus status;
  final ProjectManifest? manifest;
  final File? indexFile;
}

class LegacyProjectMigrator {
  LegacyProjectMigrator({
    required AppDirectories appDirectories,
    required AppDatabase globalDatabase,
    required ProjectCatalogRepository catalog,
    Uuid uuid = const Uuid(),
  }) : _appDirectories = appDirectories,
       _globalDatabase = globalDatabase,
       _catalog = catalog,
       _uuid = uuid;

  static const migrationSettingKey = 'projectLegacyMigrationVersion';
  static const migrationVersion = '1';
  static const projectSettingKeys = {
    'appShellSelectedTabIndex',
    'appShellSelectedTabIndexVersion',
    'gridCutWorkspaceSnapshot',
    'gridCutPageUiState',
    'storyboardWorkspaceSnapshot',
    'storyboardPageUiState',
    'storyboardAssetSidebarUiState',
    'storyboardCanvasSelectionState',
    'exporterPageUiState',
    'storyDesignInputPanelWidth',
  };
  static const projectTables = [
    'imported_images',
    'cut_tasks',
    'cut_results',
    'storyboard_tasks',
    'storyboard_boards',
    'storyboard_items',
    'export_records',
    'vision_analysis_runs',
    'vision_analysis_items',
    'storyboard_summaries',
    'image_generation_records',
  ];

  final AppDirectories _appDirectories;
  final AppDatabase _globalDatabase;
  final ProjectCatalogRepository _catalog;
  final Uuid _uuid;

  bool get isComplete =>
      _globalDatabase.getSetting(migrationSettingKey) == migrationVersion;

  Future<LegacyMigrationResult> migrateIfNeeded() async {
    if (isComplete) {
      return const LegacyMigrationResult(LegacyMigrationStatus.alreadyMigrated);
    }
    final existingLegacy = (await _catalog.loadAsync()).where(
      (entry) => entry.displayName == '旧版工程' && entry.exists,
    );
    if (existingLegacy.isNotEmpty) {
      _globalDatabase.setSetting(migrationSettingKey, migrationVersion);
      return const LegacyMigrationResult(LegacyMigrationStatus.alreadyMigrated);
    }
    if (!_hasLegacyData()) {
      _globalDatabase.setSetting(migrationSettingKey, migrationVersion);
      return const LegacyMigrationResult(LegacyMigrationStatus.noData);
    }

    await _appDirectories.projects.create(recursive: true);
    final target = _availableTarget('旧版工程');
    final staging = Directory(
      p.join(_appDirectories.projects.path, '.legacy-migrating-${_uuid.v4()}'),
    );
    try {
      await staging.create(recursive: true);
      final directories = ProjectDirectories.fromRoot(staging);
      await directories.create();
      await _copyManagedDirectories(directories);

      final database = await AppDatabase.open(directories.databaseFile);
      try {
        database.importProjectDataFrom(
          _appDirectories.databaseFile,
          projectSettingKeys: projectSettingKeys,
        );
        final oldRoot = p.normalize(_appDirectories.data.absolute.path);
        database.rewriteManagedPaths((value) {
          if (!p.isAbsolute(value)) {
            return value;
          }
          final normalized = p.normalize(value);
          if (!p.isWithin(oldRoot, normalized)) {
            return value;
          }
          final relative = p
              .relative(normalized, from: oldRoot)
              .replaceAll('\\', '/');
          return ProjectPathResolver.isSafeRelativePath(relative)
              ? relative
              : value;
        });
        _verifyRowCounts(database);
        if (!database.integrityCheck()) {
          throw StateError('迁移后的工程数据库完整性检查失败');
        }
        database.checkpoint();
      } finally {
        database.dispose();
      }

      final now = DateTime.now().toUtc();
      final manifest = ProjectManifest(
        projectId: _uuid.v4(),
        name: p.basename(target.path),
        createdAt: now,
        updatedAt: now,
      );
      await directories.indexFile.writeAsString(
        '${manifest.encode()}\n',
        flush: true,
      );
      await staging.rename(target.path);
      final indexFile = File(p.join(target.path, 'project.storyboard'));
      _catalog.register(manifest, indexFile);
      _globalDatabase.setSetting(migrationSettingKey, migrationVersion);
      return LegacyMigrationResult(
        LegacyMigrationStatus.migrated,
        manifest: manifest,
        indexFile: indexFile,
      );
    } catch (_) {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  bool _hasLegacyData() {
    if (projectTables.any((table) => _globalDatabase.countRows(table) > 0)) {
      return true;
    }
    return [
      _appDirectories.imports,
      _appDirectories.cuts,
      _appDirectories.storyboards,
      _appDirectories.generatedImages,
      _appDirectories.exports,
    ].any(_containsFile);
  }

  bool _containsFile(Directory directory) {
    if (!directory.existsSync()) {
      return false;
    }
    return directory.listSync(recursive: true).any((entity) => entity is File);
  }

  Directory _availableTarget(String name) {
    var candidate = Directory(p.join(_appDirectories.projects.path, name));
    var suffix = 2;
    while (candidate.existsSync()) {
      candidate = Directory(
        p.join(_appDirectories.projects.path, '$name ($suffix)'),
      );
      suffix++;
    }
    return candidate;
  }

  Future<void> _copyManagedDirectories(ProjectDirectories target) async {
    final pairs = [
      (_appDirectories.imports, target.imports),
      (_appDirectories.cuts, target.cuts),
      (_appDirectories.storyboards, target.storyboards),
      (_appDirectories.generatedImages, target.generatedImages),
      (_appDirectories.exports, target.exports),
    ];
    for (final pair in pairs) {
      await _copyDirectoryContents(pair.$1, pair.$2);
      if (_fileCount(pair.$1) != _fileCount(pair.$2)) {
        throw StateError('旧版目录复制校验失败：${pair.$1.path}');
      }
    }
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory target,
  ) async {
    if (!source.existsSync()) {
      return;
    }
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(targetPath));
      }
    }
  }

  int _fileCount(Directory directory) {
    if (!directory.existsSync()) {
      return 0;
    }
    return directory.listSync(recursive: true).whereType<File>().length;
  }

  void _verifyRowCounts(AppDatabase target) {
    for (final table in projectTables) {
      final sourceCount = _globalDatabase.countRows(table);
      final targetCount = target.countRows(table);
      if (sourceCount != targetCount) {
        throw StateError('旧版数据表复制校验失败：$table ($sourceCount/$targetCount)');
      }
    }
  }
}
