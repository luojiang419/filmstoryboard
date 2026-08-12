import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../data/project_catalog_repository.dart';
import '../data/project_aspect_repository.dart';
import '../data/project_directories.dart';
import '../data/project_path_resolver.dart';
import '../domain/project_manifest.dart';
import '../domain/project_aspect_ratio.dart';
import '../domain/project_models.dart';

class ProjectService {
  ProjectService({
    required ProjectCatalogRepository catalog,
    Uuid uuid = const Uuid(),
  }) : _catalog = catalog,
       _uuid = uuid;

  static const indexFileName = 'project.storyboard';
  static final _invalidNamePattern = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static const _reservedWindowsNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  final ProjectCatalogRepository _catalog;
  final Uuid _uuid;

  String? validateProjectName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      return '请输入工程名称';
    }
    if (name.length > 80) {
      return '工程名称不能超过 80 个字符';
    }
    if (_invalidNamePattern.hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      return '工程名称包含 Windows 不允许的字符';
    }
    final stem = name.split('.').first.toUpperCase();
    if (_reservedWindowsNames.contains(stem)) {
      return '该名称是 Windows 保留名称';
    }
    return null;
  }

  Future<ProjectSession> createProject({
    required String name,
    required Directory parentDirectory,
    ProjectAspectMode aspectMode = ProjectAspectMode.auto,
  }) async {
    final normalizedName = name.trim();
    final error = validateProjectName(normalizedName);
    if (error != null) {
      throw ProjectException(error);
    }
    if (!parentDirectory.existsSync()) {
      await parentDirectory.create(recursive: true);
    }
    final target = _availableProjectDirectory(parentDirectory, normalizedName);
    final staging = Directory(
      p.join(parentDirectory.path, '.creating-${_uuid.v4()}'),
    );
    try {
      await staging.create(recursive: true);
      final stagingDirectories = ProjectDirectories.fromRoot(staging);
      await stagingDirectories.create();
      final database = await AppDatabase.open(stagingDirectories.databaseFile);
      ProjectAspectRepository(
        database,
      ).save(ProjectAspectState(mode: aspectMode));
      final validDatabase = database.integrityCheck();
      database.dispose();
      if (!validDatabase) {
        throw const ProjectException('新工程数据库初始化失败');
      }
      final now = DateTime.now().toUtc();
      final manifest = ProjectManifest(
        projectId: _uuid.v4(),
        name: p.basename(target.path),
        createdAt: now,
        updatedAt: now,
      );
      await stagingDirectories.indexFile.writeAsString(
        '${manifest.encode()}\n',
        flush: true,
      );
      await staging.rename(target.path);
      return openProject(File(p.join(target.path, indexFileName)));
    } catch (error) {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      if (error is ProjectException) {
        rethrow;
      }
      throw ProjectException('创建工程失败：$error');
    }
  }

  Future<ProjectSession> openProject(File indexFile) async {
    if (!indexFile.existsSync()) {
      throw const ProjectException('工程索引不存在');
    }
    ProjectManifest manifest;
    try {
      manifest = ProjectManifest.decode(await indexFile.readAsString());
    } on UnsupportedError catch (error) {
      throw ProjectException(error.message?.toString() ?? '$error');
    } on FormatException catch (error) {
      throw ProjectException(error.message);
    }
    final directories = ProjectDirectories.fromRoot(indexFile.parent);
    if (!ProjectPathResolver.isSafeRelativePath(manifest.databasePath)) {
      throw const ProjectException('工程数据库路径不安全');
    }
    final resolver = ProjectPathResolver(directories.root);
    final databaseFile = File(resolver.toRuntimePath(manifest.databasePath));
    if (!databaseFile.existsSync()) {
      throw const ProjectException('工程数据库不存在');
    }
    await directories.database.create(recursive: true);
    final lock = await directories.lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      throw const ProjectException('工程正在被其他窗口使用');
    }
    try {
      final database = await AppDatabase.open(databaseFile);
      if (!database.integrityCheck()) {
        database.dispose();
        throw const ProjectException('工程数据库完整性检查失败');
      }
      _catalog.register(manifest, indexFile);
      return ProjectSession(
        manifest: manifest,
        directories: directories,
        database: database,
        lockFile: lock,
      );
    } catch (error) {
      await lock.unlock();
      await lock.close();
      if (error is ProjectException) {
        rethrow;
      }
      throw ProjectException('打开工程失败：$error');
    }
  }

  Future<ProjectManifest> renameProject({
    required ProjectEntry entry,
    required String name,
  }) async {
    final normalizedName = name.trim();
    final error = validateProjectName(normalizedName);
    if (error != null) {
      throw ProjectException(error);
    }
    final indexFile = File(entry.indexPath);
    if (!indexFile.existsSync()) {
      throw const ProjectException('工程索引不存在');
    }
    try {
      final manifest = ProjectManifest.decode(await indexFile.readAsString());
      if (manifest.projectId != entry.projectId) {
        throw const ProjectException('工程目录记录与索引不一致');
      }
      final renamed = manifest.copyWith(
        name: normalizedName,
        updatedAt: DateTime.now().toUtc(),
      );
      await _replaceManifest(indexFile, '${renamed.encode()}\n');
      _catalog.register(renamed, indexFile, openedAt: entry.lastOpenedAt);
      return renamed;
    } catch (error) {
      if (error is ProjectException) {
        rethrow;
      }
      throw ProjectException('重命名工程失败：$error');
    }
  }

  Future<void> _replaceManifest(File indexFile, String contents) async {
    final token = _uuid.v4();
    final temporary = File('${indexFile.path}.renaming-$token');
    final backup = File('${indexFile.path}.backup-$token');
    await temporary.writeAsString(contents, flush: true);
    await indexFile.rename(backup.path);
    try {
      await temporary.rename(indexFile.path);
    } catch (_) {
      if (!indexFile.existsSync() && backup.existsSync()) {
        await backup.rename(indexFile.path);
      }
      rethrow;
    } finally {
      if (temporary.existsSync()) {
        await temporary.delete();
      }
    }
    if (backup.existsSync()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // 新索引已生效，残留备份不影响工程使用。
      }
    }
  }

  Directory _availableProjectDirectory(Directory parent, String name) {
    var candidate = Directory(p.join(parent.path, name));
    var suffix = 2;
    while (candidate.existsSync()) {
      candidate = Directory(p.join(parent.path, '$name ($suffix)'));
      suffix++;
    }
    return candidate;
  }
}
