import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/workspace_directories.dart';
import '../../replicate/domain/replicate_models.dart';
import '../domain/shooting_asset_library_models.dart';

class ShootingAssetLibraryRepository {
  const ShootingAssetLibraryRepository({
    required AppDatabase database,
    required WorkspaceDirectories directories,
    Uuid uuid = const Uuid(),
  }) : _database = database,
       _directories = directories,
       _uuid = uuid;

  static const _settingKey = 'shootingAssetLibraryItems';

  final AppDatabase _database;
  final WorkspaceDirectories _directories;
  final Uuid _uuid;

  List<ShootingAssetLibraryItem> listItems() {
    final rows = _database.selectRows(
      'SELECT * FROM shooting_asset_library_items ORDER BY updated_at DESC;',
    );
    if (rows.isNotEmpty) {
      return rows.map(_fromRow).toList();
    }
    final legacyItems = _readLegacyItems();
    if (legacyItems.isNotEmpty) {
      _saveItems(legacyItems);
    }
    return legacyItems;
  }

  Future<ShootingAssetLibraryItem?> importItem({
    required String sourcePath,
    required ReplicateAssetType type,
    String name = '',
    String description = '',
  }) async {
    final items = await importItems([
      (
        sourcePath: sourcePath,
        type: type,
        name: name,
        description: description,
      ),
    ]);
    return items.firstOrNull;
  }

  Future<List<ShootingAssetLibraryItem>> importItems(
    Iterable<
      ({
        String sourcePath,
        ReplicateAssetType type,
        String name,
        String description,
      })
    >
    requests,
  ) async {
    final directory = await _libraryDirectory();
    final imported = <ShootingAssetLibraryItem>[];
    for (final request in requests) {
      final source = File(request.sourcePath);
      if (!await source.exists()) {
        continue;
      }
      final target = await _uniqueFile(directory, p.basename(source.path));
      await source.copy(target.path);
      final now = DateTime.now().toUtc();
      imported.add(
        ShootingAssetLibraryItem(
          id: _uuid.v4(),
          type: request.type,
          name: request.name.trim().isEmpty
              ? p.basenameWithoutExtension(source.path)
              : request.name.trim(),
          description: request.description.trim(),
          path: target.path,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    if (imported.isNotEmpty) {
      _upsertItems(imported);
    }
    return imported;
  }

  void updateItem(ShootingAssetLibraryItem updated) {
    final existing = listItems().where((item) => item.id == updated.id);
    if (existing.isEmpty) {
      return;
    }
    final original = existing.first;
    _upsertItems([
      updated.copyWith(
        name: updated.name.trim().isEmpty ? original.name : updated.name.trim(),
        description: updated.description.trim(),
        updatedAt: DateTime.now().toUtc(),
      ),
    ]);
  }

  Future<void> deleteItem(String id) async {
    final removed = listItems().where((item) => item.id == id).toList();
    _database.executeStatement(
      'DELETE FROM shooting_asset_library_items WHERE id = ?;',
      [id],
    );
    for (final item in removed) {
      await _deleteManagedFile(item.path);
    }
  }

  Future<Directory> _libraryDirectory() async {
    final directory = Directory(p.join(_directories.assets.path, 'library'));
    await directory.create(recursive: true);
    return directory;
  }

  void _saveItems(List<ShootingAssetLibraryItem> items) {
    final unique = <String, ShootingAssetLibraryItem>{};
    for (final item in items) {
      unique[item.id] = item;
    }
    final normalized = unique.values.toList()
      ..sort((first, second) => second.updatedAt.compareTo(first.updatedAt));
    _database.executeStatement('BEGIN IMMEDIATE;');
    try {
      _database.executeStatement('DELETE FROM shooting_asset_library_items;');
      for (final item in normalized) {
        _database.executeStatement(
          '''
          INSERT INTO shooting_asset_library_items(
            id, asset_type, name, description, path, created_at, updated_at
          ) VALUES(?, ?, ?, ?, ?, ?, ?);
          ''',
          [
            item.id,
            item.type.name,
            item.name,
            item.description,
            item.path,
            item.createdAt.toIso8601String(),
            item.updatedAt.toIso8601String(),
          ],
        );
      }
      _database.executeStatement('COMMIT;');
    } catch (_) {
      _database.executeStatement('ROLLBACK;');
      rethrow;
    }
    // The SQLite table is the source of truth after legacy migration. Keeping
    // the full JSON setting in sync makes each asset edit O(total assets).
  }

  void _upsertItems(Iterable<ShootingAssetLibraryItem> items) {
    _database.executeStatement('BEGIN IMMEDIATE;');
    try {
      for (final item in items) {
        _database.executeStatement(
          '''
          INSERT INTO shooting_asset_library_items(
            id, asset_type, name, description, path, created_at, updated_at
          ) VALUES(?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            asset_type = excluded.asset_type,
            name = excluded.name,
            description = excluded.description,
            path = excluded.path,
            updated_at = excluded.updated_at;
          ''',
          [
            item.id,
            item.type.name,
            item.name,
            item.description,
            item.path,
            item.createdAt.toIso8601String(),
            item.updatedAt.toIso8601String(),
          ],
        );
      }
      _database.executeStatement('COMMIT;');
    } catch (_) {
      _database.executeStatement('ROLLBACK;');
      rethrow;
    }
  }

  List<ShootingAssetLibraryItem> _readLegacyItems() {
    final raw = _database.getSetting(_settingKey);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map>()
          .map((item) => _fromJson(item.cast<String, Object?>()))
          .where((item) => item.path.trim().isNotEmpty)
          .toList()
        ..sort((first, second) => second.updatedAt.compareTo(first.updatedAt));
    } catch (_) {
      return const [];
    }
  }

  ShootingAssetLibraryItem _fromRow(Map<String, Object?> row) =>
      ShootingAssetLibraryItem(
        id: row['id'] as String,
        type: ReplicateAssetType.values.firstWhere(
          (item) => item.name == row['asset_type'],
          orElse: () => ReplicateAssetType.reference,
        ),
        name: row['name'] as String,
        description: row['description'] as String,
        path: row['path'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  Future<void> _deleteManagedFile(String path) async {
    if (path.trim().isEmpty) {
      return;
    }
    final file = File(path);
    final root = p.canonicalize(
      p.join(_directories.assets.absolute.path, 'library'),
    );
    final candidate = p.canonicalize(file.absolute.path);
    if ((p.isWithin(root, candidate) || p.equals(root, p.dirname(candidate))) &&
        file.existsSync()) {
      await file.delete();
    }
  }

  ShootingAssetLibraryItem _fromJson(Map<String, Object?> json) {
    final typeName = json['type'] as String?;
    return ShootingAssetLibraryItem(
      id: (json['id'] as String?) ?? _uuid.v4(),
      type: ReplicateAssetType.values.firstWhere(
        (item) => item.name == typeName,
        orElse: () => ReplicateAssetType.reference,
      ),
      name: (json['name'] as String?) ?? '未命名资产',
      description: (json['description'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt:
          DateTime.tryParse((json['updatedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  static Future<File> _uniqueFile(Directory directory, String name) async {
    var file = File(p.join(directory.path, name));
    if (!await file.exists()) {
      return file;
    }
    final extension = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    var suffix = 2;
    while (await file.exists()) {
      file = File(p.join(directory.path, '$base ($suffix)$extension'));
      suffix++;
    }
    return file;
  }
}
