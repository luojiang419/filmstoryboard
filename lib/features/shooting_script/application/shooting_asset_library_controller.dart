import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../replicate/domain/replicate_models.dart';
import '../data/shooting_asset_library_repository.dart';
import '../domain/shooting_asset_library_models.dart';

final shootingAssetLibraryControllerProvider =
    Provider<ShootingAssetLibraryController>((ref) {
      final controller = ShootingAssetLibraryController(
        repository: ShootingAssetLibraryRepository(
          database: ref.watch(appDatabaseProvider),
          directories: ref.watch(projectDirectoriesProvider),
        ),
        directories: ref.watch(projectDirectoriesProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    }, dependencies: [appDatabaseProvider, projectDirectoriesProvider]);

class ShootingAssetLibraryState {
  const ShootingAssetLibraryState({
    this.items = const [],
    this.isBusy = false,
    this.message = '',
    this.errorMessage = '',
  });

  final List<ShootingAssetLibraryItem> items;
  final bool isBusy;
  final String message;
  final String errorMessage;

  ShootingAssetLibraryState copyWith({
    List<ShootingAssetLibraryItem>? items,
    bool? isBusy,
    String? message,
    String? errorMessage,
  }) => ShootingAssetLibraryState(
    items: items ?? this.items,
    isBusy: isBusy ?? this.isBusy,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class ShootingAssetLibraryController
    extends ValueNotifier<ShootingAssetLibraryState> {
  ShootingAssetLibraryController({
    required ShootingAssetLibraryRepository repository,
    required WorkspaceDirectories directories,
  }) : _repository = repository,
       _directories = directories,
       super(const ShootingAssetLibraryState()) {
    refresh();
  }

  final ShootingAssetLibraryRepository _repository;
  final WorkspaceDirectories _directories;

  void refresh() {
    value = value.copyWith(items: _repository.listItems());
  }

  Future<ShootingAssetLibraryItem?> importItem({
    required String sourcePath,
    required ReplicateAssetType type,
    String name = '',
    String description = '',
    List<String> aliases = const [],
  }) async {
    final items = await importItems([
      (
        sourcePath: sourcePath,
        type: type,
        name: name,
        description: description,
        aliases: aliases,
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
        List<String> aliases,
      })
    >
    requests,
  ) async {
    final normalizedRequests = [
      for (final request in requests)
        if (request.sourcePath.trim().isNotEmpty)
          (
            sourcePath: request.sourcePath,
            type: _normalizedTypeForPath(request.type, request.sourcePath),
            name: request.name,
            description: request.description,
            aliases: request.aliases,
          ),
    ];
    if (normalizedRequests.isEmpty) {
      return const [];
    }
    value = value.copyWith(isBusy: true, message: '正在添加资产…', errorMessage: '');
    try {
      final imported = await _repository.importItems(normalizedRequests);
      if (imported.isEmpty) {
        throw const FileSystemException('资产文件不存在');
      }
      final items = _repository.listItems();
      value = value.copyWith(
        items: items,
        isBusy: false,
        message: imported.length == 1
            ? '已添加 ${imported.single.name}'
            : '已添加 ${imported.length} 个资产',
        errorMessage: '',
      );
      return imported;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '添加资产失败：$error',
      );
      return const [];
    }
  }

  void updateItem(ShootingAssetLibraryItem item) {
    _repository.updateItem(item);
    value = value.copyWith(
      items: _repository.listItems(),
      message: '资产信息已保存',
      errorMessage: '',
    );
  }

  Future<ShootingAssetLibraryItem?> replaceItemFile({
    required String id,
    required String sourcePath,
  }) async {
    final existing = value.items.where((item) => item.id == id).firstOrNull;
    if (existing == null || sourcePath.trim().isEmpty) {
      return null;
    }
    value = value.copyWith(isBusy: true, message: '正在替换资产…', errorMessage: '');
    try {
      final updated = await _repository.replaceItemFile(
        id: id,
        sourcePath: sourcePath,
        type: _normalizedTypeForPath(existing.type, sourcePath),
      );
      if (updated == null) {
        throw const FileSystemException('资产文件不存在');
      }
      value = value.copyWith(
        items: _repository.listItems(),
        isBusy: false,
        message: '已替换 ${updated.name}',
        errorMessage: '',
      );
      return updated;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '替换资产失败：$error',
      );
      return null;
    }
  }

  Future<void> deleteItem(String id) async {
    await _repository.deleteItem(id);
    value = value.copyWith(
      items: _repository.listItems(),
      message: '已删除资产',
      errorMessage: '',
    );
  }

  Future<void> openLibraryDirectory() async {
    final directory = Directory(p.join(_directories.assets.path, 'library'));
    await directory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [directory.path]);
    }
  }

  static ReplicateAssetType _normalizedTypeForPath(
    ReplicateAssetType requested,
    String path,
  ) {
    final extension = p.extension(path).toLowerCase();
    if (const {
      '.mp4',
      '.mov',
      '.mkv',
      '.avi',
      '.webm',
      '.m4v',
    }.contains(extension)) {
      return ReplicateAssetType.video;
    }
    if (const {
      '.mp3',
      '.wav',
      '.m4a',
      '.aac',
      '.flac',
      '.ogg',
    }.contains(extension)) {
      return ReplicateAssetType.audio;
    }
    return requested == ReplicateAssetType.video ||
            requested == ReplicateAssetType.audio
        ? ReplicateAssetType.reference
        : requested;
  }
}
