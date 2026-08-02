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
  }) async {
    value = value.copyWith(isBusy: true, message: '正在添加资产…', errorMessage: '');
    try {
      final normalizedType = _normalizedTypeForPath(type, sourcePath);
      final item = await _repository.importItem(
        sourcePath: sourcePath,
        type: normalizedType,
        name: name,
        description: description,
      );
      if (item == null) {
        throw const FileSystemException('资产文件不存在');
      }
      value = value.copyWith(
        items: _repository.listItems(),
        isBusy: false,
        message: '已添加 ${item.name}',
        errorMessage: '',
      );
      return item;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '添加资产失败：$error',
      );
      return null;
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
