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

  Future<ShootingAssetLibraryItem?> importItem({
    required String sourcePath,
    required ReplicateAssetType type,
    String name = '',
    String description = '',
  }) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      return null;
    }
    final directory = await _libraryDirectory();
    final target = _uniqueFile(directory, p.basename(source.path));
    await source.copy(target.path);
    final now = DateTime.now().toUtc();
    final item = ShootingAssetLibraryItem(
      id: _uuid.v4(),
      type: type,
      name: name.trim().isEmpty
          ? p.basenameWithoutExtension(source.path)
          : name.trim(),
      description: description.trim(),
      path: target.path,
      createdAt: now,
      updatedAt: now,
    );
    _saveItems([item, ...listItems()]);
    return item;
  }

  void updateItem(ShootingAssetLibraryItem updated) {
    final items = listItems();
    final index = items.indexWhere((item) => item.id == updated.id);
    if (index < 0) {
      return;
    }
    final existing = items[index];
    items[index] = updated.copyWith(
      name: updated.name.trim().isEmpty ? existing.name : updated.name.trim(),
      description: updated.description.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    _saveItems(items);
  }

  Future<void> deleteItem(String id) async {
    final items = listItems();
    final removed = items.where((item) => item.id == id).toList();
    _saveItems([
      for (final item in items)
        if (item.id != id) item,
    ]);
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
    final encoded = jsonEncode([
      for (final item in unique.values) _toJson(item),
    ]);
    _database.setSetting(_settingKey, encoded);
  }

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

  static Map<String, Object?> _toJson(ShootingAssetLibraryItem item) => {
    'id': item.id,
    'type': item.type.name,
    'name': item.name,
    'description': item.description,
    'path': item.path,
    'createdAt': item.createdAt.toIso8601String(),
    'updatedAt': item.updatedAt.toIso8601String(),
  };

  static File _uniqueFile(Directory directory, String name) {
    var file = File(p.join(directory.path, name));
    if (!file.existsSync()) {
      return file;
    }
    final extension = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    var suffix = 2;
    while (file.existsSync()) {
      file = File(p.join(directory.path, '$base ($suffix)$extension'));
      suffix++;
    }
    return file;
  }
}
