import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/project_manifest.dart';
import '../domain/project_models.dart';
import 'project_catalog_repository.dart';
import 'project_directories.dart';
import 'project_path_resolver.dart';

class ProjectMigrationResult {
  const ProjectMigrationResult({
    required this.entry,
    required this.oldSourceRetained,
  });

  final ProjectEntry entry;
  final bool oldSourceRetained;
}

class ProjectOperationsService {
  ProjectOperationsService({
    required ProjectCatalogRepository catalog,
    Uuid uuid = const Uuid(),
  }) : _catalog = catalog,
       _uuid = uuid;

  static const packageFormat = 'storyboard-project-package';
  static const packageSchemaVersion = 1;
  static const packageManifestName = 'package-manifest.json';

  final ProjectCatalogRepository _catalog;
  final Uuid _uuid;

  Future<File> exportProject({
    required ProjectEntry entry,
    required File outputFile,
  }) async {
    final root = _validatedProjectRoot(entry);
    final manifest = ProjectManifest.decode(
      await File(p.join(root.path, 'project.storyboard')).readAsString(),
    );
    final databaseFile = File(p.join(root.path, manifest.databasePath));
    final database = await AppDatabase.open(databaseFile);
    try {
      if (!database.integrityCheck()) {
        throw const ProjectException('工程数据库完整性检查失败，不能导出');
      }
      database.checkpoint();
    } finally {
      database.dispose();
    }

    final archive = Archive();
    final checksums = <String, String>{};
    final files =
        root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => !_shouldExclude(root, file))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final relative = p
          .relative(file.path, from: root.path)
          .replaceAll('\\', '/');
      if (!ProjectPathResolver.isSafeRelativePath(relative)) {
        throw ProjectException('工程包含不安全路径：$relative');
      }
      final bytes = await file.readAsBytes();
      checksums[relative] = sha256.convert(bytes).toString();
      archive.addFile(ArchiveFile.bytes(relative, bytes));
    }
    final packageManifest = utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': packageFormat,
        'schemaVersion': packageSchemaVersion,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'projectFile': 'project.storyboard',
        'checksums': checksums,
      }),
    );
    archive.addFile(ArchiveFile.bytes(packageManifestName, packageManifest));
    final encoded = ZipEncoder().encode(archive);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(encoded, flush: true);
    return outputFile;
  }

  Future<ProjectEntry> importPackage({
    required File packageFile,
    required Directory projectRoot,
  }) async {
    if (!packageFile.existsSync()) {
      throw const ProjectException('工程包不存在');
    }
    // 工程包清单中的 SHA-256 已覆盖所有工程文件；不再重复执行 ZIP
    // CRC 的全量校验，避免大型工程在解压前额外读取一次全部内容。
    final archive = ZipDecoder().decodeBytes(await packageFile.readAsBytes());
    final entries = <String, ArchiveFile>{};
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (file.isSymbolicLink ||
          !ProjectPathResolver.isSafeRelativePath(name) ||
          entries.containsKey(name)) {
        throw ProjectException('工程包包含不安全或重复路径：$name');
      }
      if (file.isFile) {
        entries[name] = file;
      }
    }
    final packageEntry = entries[packageManifestName];
    final indexEntry = entries['project.storyboard'];
    if (packageEntry == null || indexEntry == null) {
      throw const ProjectException('工程包缺少必要清单或工程索引');
    }
    final packageJson = jsonDecode(utf8.decode(packageEntry.content));
    if (packageJson is! Map<String, Object?> ||
        packageJson['format'] != packageFormat ||
        packageJson['schemaVersion'] != packageSchemaVersion) {
      throw const ProjectException('工程包格式或版本不受支持');
    }
    final checksumValue = packageJson['checksums'];
    if (checksumValue is! Map<String, Object?>) {
      throw const ProjectException('工程包缺少文件摘要');
    }
    if (packageJson['projectFile'] != 'project.storyboard' ||
        checksumValue.keys
            .toSet()
            .difference(
              entries.keys.where((name) => name != packageManifestName).toSet(),
            )
            .isNotEmpty ||
        entries.keys
            .where((name) => name != packageManifestName)
            .toSet()
            .difference(checksumValue.keys.toSet())
            .isNotEmpty) {
      throw const ProjectException('工程包文件清单不完整或包含未登记文件');
    }
    final verifiedContents = <String, List<int>>{};
    for (final checksumEntry in checksumValue.entries) {
      final file = entries[checksumEntry.key];
      final expected = checksumEntry.value;
      if (file == null || expected is! String) {
        throw ProjectException('工程包缺少文件：${checksumEntry.key}');
      }
      final contents = file.content;
      final actual = sha256.convert(contents).toString();
      if (actual != expected) {
        throw ProjectException('工程包文件摘要不匹配：${checksumEntry.key}');
      }
      verifiedContents[checksumEntry.key] = contents;
    }

    await projectRoot.create(recursive: true);
    final staging = Directory(
      p.join(projectRoot.path, '.importing-${_uuid.v4()}'),
    );
    try {
      await staging.create(recursive: true);
      for (final entry in verifiedContents.entries) {
        if (entry.key == packageManifestName) {
          continue;
        }
        final target = File(p.joinAll([staging.path, ...entry.key.split('/')]));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.value);
      }
      var manifest = ProjectManifest.decode(
        await File(p.join(staging.path, 'project.storyboard')).readAsString(),
      );
      final duplicateId = _catalog.load().any(
        (entry) => entry.projectId == manifest.projectId,
      );
      final preferredName = duplicateId
          ? '${manifest.name} (副本)'
          : manifest.name;
      final target = _availableDirectory(projectRoot, preferredName);
      if (duplicateId || p.basename(target.path) != manifest.name) {
        manifest = manifest.copyWith(
          projectId: duplicateId ? _uuid.v4() : manifest.projectId,
          name: p.basename(target.path),
          updatedAt: DateTime.now().toUtc(),
        );
        await File(
          p.join(staging.path, 'project.storyboard'),
        ).writeAsString('${manifest.encode()}\n', flush: true);
      }
      await _repairPortablePaths(staging);
      await _validateDatabase(staging, manifest);
      await staging.rename(target.path);
      final indexFile = File(p.join(target.path, 'project.storyboard'));
      _catalog.register(manifest, indexFile);
      return _catalog.load().firstWhere(
        (entry) => entry.projectId == manifest.projectId,
      );
    } catch (_) {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<ProjectMigrationResult> migrateProject({
    required ProjectEntry entry,
    required Directory targetParent,
  }) async {
    final source = _validatedProjectRoot(entry);
    final sourcePath = p.normalize(source.absolute.path);
    final targetParentPath = p.normalize(targetParent.absolute.path);
    if (sourcePath == targetParentPath ||
        p.isWithin(sourcePath, targetParentPath)) {
      throw const ProjectException('迁移目标不能是当前工程或其内部目录');
    }
    await targetParent.create(recursive: true);
    final target = _availableDirectory(targetParent, p.basename(source.path));
    final staging = Directory(
      p.join(targetParent.path, '.migrating-${_uuid.v4()}'),
    );
    try {
      await staging.create(recursive: true);
      await _copyDirectoryContents(source, staging);
      final manifest = ProjectManifest.decode(
        await File(p.join(staging.path, 'project.storyboard')).readAsString(),
      );
      await _validateDatabase(staging, manifest);
      await _verifyCopies(source, staging);
      await staging.rename(target.path);
      final indexFile = File(p.join(target.path, 'project.storyboard'));
      _catalog.register(manifest, indexFile);
      var retained = false;
      try {
        await source.delete(recursive: true);
      } catch (_) {
        retained = true;
      }
      final migratedEntry = _catalog.load().firstWhere(
        (candidate) => candidate.projectId == manifest.projectId,
      );
      return ProjectMigrationResult(
        entry: migratedEntry,
        oldSourceRetained: retained,
      );
    } catch (_) {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> permanentlyDeleteProject({
    required ProjectEntry entry,
    required Directory defaultProjectRoot,
    required String confirmedName,
  }) async {
    if (confirmedName != entry.displayName) {
      throw const ProjectException('输入的工程名称不匹配');
    }
    final root = _validatedProjectRoot(entry);
    final normalizedRoot = p.normalize(root.absolute.path);
    final driveRoot = p.rootPrefix(normalizedRoot);
    if (normalizedRoot == p.normalize(defaultProjectRoot.absolute.path) ||
        normalizedRoot == p.normalize(driveRoot) ||
        p.basename(normalizedRoot).trim().isEmpty) {
      throw const ProjectException('目录边界校验失败，拒绝永久删除');
    }
    final manifest = ProjectManifest.decode(
      await File(p.join(root.path, 'project.storyboard')).readAsString(),
    );
    if (manifest.projectId != entry.projectId ||
        manifest.name != entry.displayName) {
      throw const ProjectException('工程索引与卡片信息不匹配，拒绝永久删除');
    }
    await root.delete(recursive: true);
    _catalog.remove(entry.projectId);
  }

  Directory _validatedProjectRoot(ProjectEntry entry) {
    final indexFile = File(entry.indexPath);
    if (!indexFile.existsSync() ||
        p.basename(indexFile.path) != 'project.storyboard') {
      throw const ProjectException('工程索引不存在或名称无效');
    }
    final manifest = ProjectManifest.decode(indexFile.readAsStringSync());
    if (manifest.projectId != entry.projectId) {
      throw const ProjectException('工程索引 ID 与项目目录不匹配');
    }
    return indexFile.parent;
  }

  Future<void> _validateDatabase(
    Directory root,
    ProjectManifest manifest,
  ) async {
    if (!ProjectPathResolver.isSafeRelativePath(manifest.databasePath)) {
      throw const ProjectException('工程数据库路径不安全');
    }
    final databaseFile = File(
      p.joinAll([root.path, ...manifest.databasePath.split('/')]),
    );
    if (!databaseFile.existsSync()) {
      throw const ProjectException('工程数据库不存在');
    }
    final database = await AppDatabase.open(databaseFile);
    try {
      if (!database.integrityCheck()) {
        throw const ProjectException('工程数据库完整性检查失败');
      }
      database.checkpoint();
    } finally {
      database.dispose();
    }
  }

  Future<void> _repairPortablePaths(Directory root) async {
    final directories = ProjectDirectories.fromRoot(root);
    final database = await AppDatabase.open(directories.databaseFile);
    try {
      database.rewriteManagedPaths((value) => _rebaseImportedPath(root, value));
      database.checkpoint();
    } finally {
      database.dispose();
    }
  }

  String _rebaseImportedPath(Directory root, String value) {
    if (!p.isAbsolute(value)) {
      return value;
    }
    final parts = p.split(p.normalize(value));
    const managedRoots = {
      'imports',
      'cuts',
      'storyboards',
      'generated_images',
      'exports',
      'videos',
      'frames',
      'analyses',
      'reports',
      'scripts',
      'assets',
      'prompts',
    };
    for (var index = 0; index < parts.length; index++) {
      if (!managedRoots.contains(parts[index].toLowerCase())) {
        continue;
      }
      final candidate = File(p.joinAll([root.path, ...parts.skip(index)]));
      if (!candidate.existsSync()) {
        continue;
      }
      return ProjectPathResolver(root).toStoredPath(candidate.path);
    }
    return value;
  }

  bool _shouldExclude(Directory root, File file) {
    final relative = p
        .relative(file.path, from: root.path)
        .replaceAll('\\', '/');
    final first = relative.split('/').first.toLowerCase();
    final name = p.basename(relative).toLowerCase();
    return first == 'temp' ||
        first == 'logs' ||
        name == 'project.lock' ||
        name.endsWith('-wal') ||
        name.endsWith('-shm') ||
        name == packageManifestName;
  }

  Directory _availableDirectory(Directory parent, String name) {
    var candidate = Directory(p.join(parent.path, name));
    var suffix = 2;
    while (candidate.existsSync()) {
      candidate = Directory(p.join(parent.path, '$name ($suffix)'));
      suffix++;
    }
    return candidate;
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory target,
  ) async {
    await for (final entity in source.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw ProjectException('工程包含不允许迁移的符号链接：${entity.path}');
      }
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is File) {
        if (!_shouldExclude(source, entity)) {
          await entity.copy(targetPath);
        }
      } else if (entity is Directory) {
        final relative = p
            .relative(entity.path, from: source.path)
            .replaceAll('\\', '/');
        final first = relative.split('/').first.toLowerCase();
        if (first != 'temp' && first != 'logs') {
          final child = Directory(targetPath);
          await child.create(recursive: true);
          await _copyDirectoryContents(entity, child);
        }
      }
    }
  }

  Future<void> _verifyCopies(Directory source, Directory target) async {
    final sourceHashes = await _hashTree(source);
    final targetHashes = await _hashTree(target);
    if (sourceHashes.length != targetHashes.length) {
      throw const ProjectException('迁移文件数量校验失败');
    }
    for (final entry in sourceHashes.entries) {
      if (targetHashes[entry.key] != entry.value) {
        throw ProjectException('迁移文件摘要校验失败：${entry.key}');
      }
    }
  }

  Future<Map<String, String>> _hashTree(Directory root) async {
    final result = <String, String>{};
    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => !_shouldExclude(root, file));
    for (final file in files) {
      final relative = p
          .relative(file.path, from: root.path)
          .replaceAll('\\', '/');
      result[relative] = sha256.convert(await file.readAsBytes()).toString();
    }
    return result;
  }
}
