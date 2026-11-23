import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/desktop_file_dialog_service.dart';
import '../../../core/services/empty_directory_cleaner.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/services/workspace_snapshot_save_queue.dart';
import '../../../core/services/workspace_directories.dart';
import '../../projects/data/project_path_resolver.dart';
import '../data/grid_crop_service.dart';
import '../data/grid_detection_service.dart';
import '../domain/grid_cut_models.dart';

final cutResultsChangeNotifierProvider = Provider<ValueNotifier<int>>((ref) {
  final notifier = ValueNotifier<int>(0);
  ref.onDispose(notifier.dispose);
  return notifier;
}, dependencies: []);

final gridCutControllerProvider = Provider<GridCutController>(
  (ref) {
    final controller = GridCutController(
      directories: ref.watch(projectDirectoriesProvider),
      database: ref.watch(appDatabaseProvider),
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
      cutResultsChangeNotifier: ref.watch(cutResultsChangeNotifierProvider),
      projectName: ref.watch(currentProjectNameProvider),
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    projectDirectoriesProvider,
    appDatabaseProvider,
    cutResultsChangeNotifierProvider,
    currentProjectNameProvider,
  ],
);

class GridCutController extends ValueNotifier<GridCutState> {
  GridCutController({
    required WorkspaceDirectories directories,
    required AppDatabase database,
    required GridDetectionService detectionService,
    required GridCropService cropService,
    DesktopFileDialogService? fileDialogService,
    ValueNotifier<int>? cutResultsChangeNotifier,
    String projectName = '项目',
  }) : _directories = directories,
       _database = database,
       _detectionService = detectionService,
       _cropService = cropService,
       _fileDialogService =
           fileDialogService ??
           DesktopFileDialogService(defaultDirectory: directories.imports),
       _ownsFileDialogService = fileDialogService == null,
       _cutResultsChangeNotifier = cutResultsChangeNotifier,
       _projectName = projectName.trim().isEmpty ? '项目' : projectName.trim(),
       _pathResolver = ProjectPathResolver(directories.workspaceRoot),
       super(const GridCutState.initial()) {
    _workspaceSaveQueue = WorkspaceSnapshotSaveQueue(
      buildSnapshot: () => jsonEncode(_workspaceSnapshotToJson(value)),
      writeSnapshot: (snapshot) =>
          _database.setSetting(_workspaceSnapshotKey, snapshot),
    );
    _selectionSaveQueue = WorkspaceSnapshotSaveQueue(
      buildSnapshot: () => value.selectedImageId ?? '',
      writeSnapshot: (selection) =>
          _database.setSetting(_selectionStateKey, selection),
    );
    _restoreWorkspaceSnapshot();
  }

  static const _imageTypes = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
  );
  static const _workspaceSnapshotKey = 'gridCutWorkspaceSnapshot';
  static const _selectionStateKey = 'gridCutWorkspaceSelection';
  static const _workspaceSnapshotVersion = 2;

  final WorkspaceDirectories _directories;
  final AppDatabase _database;
  final GridDetectionService _detectionService;
  final GridCropService _cropService;
  final DesktopFileDialogService _fileDialogService;
  final bool _ownsFileDialogService;
  final ValueNotifier<int>? _cutResultsChangeNotifier;
  final String _projectName;
  final ProjectPathResolver _pathResolver;
  final _uuid = const Uuid();
  late final WorkspaceSnapshotSaveQueue _workspaceSaveQueue;
  late final WorkspaceSnapshotSaveQueue _selectionSaveQueue;
  int _nextImportSequence = 1;

  @override
  void dispose() {
    _workspaceSaveQueue.dispose();
    _selectionSaveQueue.dispose();
    if (_ownsFileDialogService) {
      _fileDialogService.dispose();
    }
    super.dispose();
  }

  Future<void> pickImages() async {
    final files = await _fileDialogService.openFiles(
      source: 'grid_cut.pick_images',
      acceptedTypeGroups: [_imageTypes],
      initialDirectory: _directories.imports.path,
      confirmButtonText: '导入图片',
    );
    await importPaths(files.map((file) => file.path).toList());
  }

  Future<void> pasteImages() async {
    final paths = await Pasteboard.files();
    final imagePaths = paths.where(_isSupportedImage).toList();
    if (imagePaths.isNotEmpty) {
      await importPaths(imagePaths);
      return;
    }

    final imageBytes = await Pasteboard.image;
    if (imageBytes == null) {
      _setMessage('剪贴板中没有可用图片');
      return;
    }

    await _importBytes(
      originalPath: 'clipboard',
      sourceName: 'clipboard.png',
      bytes: imageBytes,
    );
  }

  Future<void> importPaths(List<String> paths) async {
    final imagePaths = paths.where(_isSupportedImage).toList();
    if (imagePaths.isEmpty) {
      _setMessage('未发现支持的图片文件');
      return;
    }

    _setState(
      value.copyWith(isBusy: true, message: '正在导入 ${imagePaths.length} 张图片...'),
    );
    try {
      for (final path in imagePaths) {
        final file = File(path);
        if (!file.existsSync()) {
          continue;
        }
        await _importBytes(
          originalPath: path,
          sourceName: p.basename(path),
          bytes: await file.readAsBytes(),
        );
      }
      _setState(
        value.copyWith(
          isBusy: false,
          message: '已导入 ${imagePaths.length} 张图片，仅完成宫格识别，请点击裁切多宫格图片生成结果',
        ),
      );
    } catch (error) {
      _setState(value.copyWith(isBusy: false, message: '导入失败：$error'));
    }
  }

  Future<void> _importBytes({
    required String originalPath,
    required String sourceName,
    required Uint8List bytes,
  }) async {
    final layout = await _detectionService.detectAsync(bytes);
    final id = _uuid.v4();
    final taskId = _uuid.v4();
    final sourceExtension = p.extension(sourceName).toLowerCase();
    final extension = sourceExtension.isEmpty ? '.png' : sourceExtension;
    final originalName = '$_projectName$_nextImportSequence$extension';
    final storedFile = File(p.join(_directories.imports.path, '$id$extension'));
    await storedFile.writeAsBytes(bytes);
    final createdAt = DateTime.now();

    final image = GridCutImage(
      id: id,
      taskId: taskId,
      originalPath: originalPath,
      originalName: originalName,
      storedPath: storedFile.path,
      layout: layout,
      selectedCells: const {},
      exportedPaths: const [],
      createdAt: createdAt,
    );

    _database
      ..upsertImportedImage(
        id: id,
        originalPath: originalPath,
        originalName: originalName,
        storedPath: _toStoredPath(storedFile.path),
        width: layout.imageWidth,
        height: layout.imageHeight,
        createdAt: createdAt.toIso8601String(),
      )
      ..upsertCutTask(
        id: taskId,
        imageId: id,
        status: 'recognized',
        rows: layout.rows,
        columns: layout.columns,
        confidence: layout.confidence,
      );

    _nextImportSequence++;
    final imageNodeKey = GridCutTaskNodeRef.image(id).key;
    _setState(
      value.copyWith(
        images: [...value.images, image],
        taskOrder: [..._normalizedTaskOrder(value), imageNodeKey],
        selectedImageId: id,
      ),
    );
  }

  void selectImage(String imageId) {
    _setState(value.copyWith(selectedImageId: imageId), saveWorkspace: false);
  }

  bool selectAdjacentImage(int direction) {
    final images = value.images;
    if (images.isEmpty) {
      return false;
    }
    if (images.length == 1) {
      _setMessage('当前只有一张图片任务');
      return true;
    }
    var currentIndex = images.indexWhere(
      (image) => image.id == value.selectedImage?.id,
    );
    if (currentIndex < 0) {
      currentIndex = 0;
    }
    final nextIndex = (currentIndex + direction) % images.length;
    final next = images[nextIndex];
    _setState(
      value.copyWith(
        selectedImageId: next.id,
        message: '已切换到 ${next.originalName}（${nextIndex + 1}/${images.length}）',
      ),
      saveWorkspace: false,
    );
    return true;
  }

  void removeImageTask(String imageId) {
    final images = value.images;
    final index = images.indexWhere((image) => image.id == imageId);
    if (index < 0) {
      return;
    }
    final removed = images[index];
    final nextImages = [
      for (final image in images)
        if (image.id != imageId) image,
    ];
    final nextSelectedId = _nextSelectedImageIdAfterRemoval(
      removedId: imageId,
      removedIndex: index,
      remainingImages: nextImages,
    );
    _setState(
      value.copyWith(
        images: nextImages,
        taskGroups: _groupsWithoutImages({imageId}, value.taskGroups),
        taskOrder: _normalizedTaskOrder(
          value.copyWith(
            images: nextImages,
            taskGroups: _groupsWithoutImages({imageId}, value.taskGroups),
            taskOrder: [
              for (final key in value.taskOrder)
                if (key != GridCutTaskNodeRef.image(imageId).key) key,
            ],
          ),
        ),
        selectedImageId: nextSelectedId,
        clearSelectedImageId: nextSelectedId == null,
        message: nextImages.isEmpty
            ? '已移除 ${removed.originalName}，图片任务栏已清空'
            : '已移除 ${removed.originalName}',
      ),
    );
  }

  void clearImageTasks() {
    final count = value.images.length;
    if (count == 0) {
      _setMessage('图片任务栏已经是空的');
      return;
    }
    _setState(
      value.copyWith(
        images: const [],
        taskGroups: const [],
        taskOrder: const [],
        clearSelectedImageId: true,
        message: '已清空 $count 张图片任务',
      ),
    );
  }

  void setDraggingOver(bool dragging) {
    _setState(value.copyWith(isDraggingOver: dragging), saveWorkspace: false);
  }

  void setEvenGrid(int rows, int columns) {
    final selected = value.selectedImage;
    if (selected == null) {
      return;
    }
    final layout = _detectionService.evenGrid(
      imageWidth: selected.layout.imageWidth,
      imageHeight: selected.layout.imageHeight,
      rows: rows.clamp(1, 24),
      columns: columns.clamp(1, 24),
    );
    _replaceSelected(
      selected.copyWith(layout: layout, selectedCells: const {}),
      message: '已切换为 $rows x $columns 等分宫格',
    );
  }

  void commitLayout(GridLayout layout) {
    final selected = value.selectedImage;
    if (selected == null ||
        layout.imageWidth != selected.layout.imageWidth ||
        layout.imageHeight != selected.layout.imageHeight ||
        identical(layout, selected.layout)) {
      return;
    }
    _replaceSelected(
      selected.copyWith(
        layout: layout,
        selectedCells: layout.cellCount == selected.layout.cellCount
            ? selected.selectedCells
            : const {},
      ),
    );
  }

  void insertVerticalLine(int imageX) {
    final selected = value.selectedImage;
    if (selected == null) {
      return;
    }
    final layout = selected.layout.insertVerticalLine(imageX);
    if (identical(layout, selected.layout)) {
      _setMessage('裁切线位置太靠近边界或已有裁切线');
      return;
    }
    _replaceSelected(
      selected.copyWith(layout: layout, selectedCells: const {}),
      message: '已添加竖向裁切线',
    );
  }

  void insertHorizontalLine(int imageY) {
    final selected = value.selectedImage;
    if (selected == null) {
      return;
    }
    final layout = selected.layout.insertHorizontalLine(imageY);
    if (identical(layout, selected.layout)) {
      _setMessage('裁切线位置太靠近边界或已有裁切线');
      return;
    }
    _replaceSelected(
      selected.copyWith(layout: layout, selectedCells: const {}),
      message: '已添加横向裁切线',
    );
  }

  void toggleCell(int index, {required bool selected, int? anchorIndex}) {
    final image = value.selectedImage;
    if (image == null) {
      return;
    }
    final next = {...image.selectedCells};
    final start = anchorIndex == null ? index : math.min(anchorIndex, index);
    final end = anchorIndex == null ? index : math.max(anchorIndex, index);
    for (var i = start; i <= end; i++) {
      if (selected) {
        next.add(i);
      } else {
        next.remove(i);
      }
    }
    _replaceSelected(image.copyWith(selectedCells: next));
  }

  void clearCellSelection() {
    final image = value.selectedImage;
    if (image == null) {
      return;
    }
    _replaceSelected(image.copyWith(selectedCells: {}));
  }

  Future<void> exportSelectedImage() async {
    final image = value.selectedImage;
    if (image == null) {
      _setMessage('请先导入图片');
      return;
    }
    await _exportImage(image);
    _notifyCutResultsChanged();
  }

  Future<void> exportAllImages() async {
    if (value.images.isEmpty) {
      _setMessage('请先导入图片');
      return;
    }
    _setState(
      value.copyWith(
        isBusy: true,
        message: '正在批量裁切 ${value.images.length} 张图片...',
      ),
      saveWorkspace: false,
    );
    try {
      for (final image in value.images) {
        await _exportImage(image, quiet: true);
      }
      _setState(value.copyWith(isBusy: false, message: '批量裁切完成'));
      _notifyCutResultsChanged();
    } catch (error) {
      _setState(value.copyWith(isBusy: false, message: '批量裁切失败：$error'));
    }
  }

  void groupImageTasks(String name, Iterable<String> imageIds) {
    final selectedIds = imageIds.toSet();
    if (selectedIds.isEmpty) {
      _setMessage('请先选择要编组的图片任务');
      return;
    }
    final validIds = value.images.map((image) => image.id).toSet();
    selectedIds.removeWhere((id) => !validIds.contains(id));
    if (selectedIds.isEmpty) {
      _setMessage('所选图片任务已不存在');
      return;
    }

    final safeName = _safeGroupName(name);
    final groupName = _uniqueGroupName(safeName);
    final selectedInImageOrder = [
      for (final image in value.images)
        if (selectedIds.contains(image.id)) image.id,
    ];
    final nextGroups = <GridCutTaskGroup>[
      for (final group in value.taskGroups)
        _groupWithoutImages(group, selectedIds),
    ].where((group) => group.imageIds.isNotEmpty).toList();
    nextGroups.add(
      GridCutTaskGroup(
        id: _uuid.v4(),
        name: groupName,
        imageIds: selectedInImageOrder,
      ),
    );

    final retainedGroupIds = nextGroups.map((group) => group.id).toSet();
    final currentOrder = _normalizedTaskOrder(value);
    final firstSelectedIndex = currentOrder.indexWhere((key) {
      final node = GridCutTaskNodeRef.tryParse(key);
      return node?.kind == GridCutTaskNodeKind.image &&
          selectedIds.contains(node?.id);
    });
    final nextOrder = <String>[];
    var insertionIndex = 0;
    for (var index = 0; index < currentOrder.length; index++) {
      final key = currentOrder[index];
      final node = GridCutTaskNodeRef.tryParse(key);
      final retained =
          node != null &&
          !(node.kind == GridCutTaskNodeKind.image &&
              selectedIds.contains(node.id)) &&
          (node.kind != GridCutTaskNodeKind.group ||
              retainedGroupIds.contains(node.id));
      if (retained) {
        nextOrder.add(key);
        if (firstSelectedIndex < 0 || index < firstSelectedIndex) {
          insertionIndex++;
        }
      }
    }
    nextOrder.insert(
      insertionIndex.clamp(0, nextOrder.length),
      GridCutTaskNodeRef.group(nextGroups.last.id).key,
    );

    _setState(
      value.copyWith(
        taskGroups: nextGroups,
        taskOrder: nextOrder,
        message: '已将 ${selectedInImageOrder.length} 张图片任务编组到 $groupName',
      ),
    );
  }

  bool moveTaskNode(
    String nodeKey, {
    String? targetGroupId,
    String? beforeNodeKey,
  }) {
    final node = GridCutTaskNodeRef.tryParse(nodeKey);
    if (node == null) {
      return false;
    }
    if (node.kind == GridCutTaskNodeKind.group && targetGroupId != null) {
      _setMessage('图片任务编组仅支持在根层排序');
      return false;
    }
    if (targetGroupId != null &&
        !value.taskGroups.any((group) => group.id == targetGroupId)) {
      return false;
    }

    var groups = [for (final group in value.taskGroups) group];
    var rootOrder = _normalizedTaskOrder(value)..remove(nodeKey);
    if (node.kind == GridCutTaskNodeKind.image) {
      if (!value.images.any((image) => image.id == node.id)) {
        return false;
      }
      groups = [
        for (final group in groups)
          group.copyWith(
            imageIds: [
              for (final imageId in group.imageIds)
                if (imageId != node.id) imageId,
            ],
          ),
      ];
      if (targetGroupId == null) {
        _insertBefore(rootOrder, nodeKey, beforeNodeKey);
      } else {
        groups = [
          for (final group in groups)
            if (group.id == targetGroupId)
              group.copyWith(
                imageIds: _withInsertedImage(
                  group.imageIds,
                  node.id,
                  beforeNodeKey,
                ),
              )
            else
              group,
        ];
      }
    } else {
      if (!groups.any((group) => group.id == node.id)) {
        return false;
      }
      _insertBefore(rootOrder, nodeKey, beforeNodeKey);
    }

    groups = groups.where((group) => group.imageIds.isNotEmpty).toList();
    final nextState = value.copyWith(taskGroups: groups, taskOrder: rootOrder);
    final normalizedOrder = _normalizedTaskOrder(nextState);
    final orderedImages = _imagesInTaskOrder(
      nextState.copyWith(taskOrder: normalizedOrder),
    );
    _setState(
      nextState.copyWith(
        images: orderedImages,
        taskOrder: normalizedOrder,
        message: '已调整图片任务顺序',
      ),
    );
    return true;
  }

  void toggleTaskGroupExpanded(String groupId) {
    _setState(
      value.copyWith(
        taskGroups: [
          for (final group in value.taskGroups)
            if (group.id == groupId)
              group.copyWith(expanded: !group.expanded)
            else
              group,
        ],
      ),
    );
  }

  Future<void> openExportFolder() async {
    final image = value.selectedImage;
    if (image == null) {
      return;
    }
    final folder = Directory(p.join(_directories.cuts.path, image.baseName));
    if (!folder.existsSync()) {
      _setMessage('导出文件夹不存在，请先裁切图片');
      return;
    }
    final opened = await const FileExplorerService().openDirectory(folder.path);
    if (!opened) {
      _setMessage('导出文件夹不存在，请先裁切图片');
    }
  }

  Future<void> _exportImage(GridCutImage image, {bool quiet = false}) async {
    if (!quiet) {
      _setState(
        value.copyWith(isBusy: true, message: '正在裁切 ${image.originalName}...'),
        saveWorkspace: false,
      );
    }
    final bytes = await File(image.storedPath).readAsBytes();
    final indexes =
        (image.selectedCells.isEmpty
                ? {for (var i = 0; i < image.layout.cellCount; i++) i}
                : image.selectedCells)
            .toList()
          ..sort();
    final outputDirectory = Directory(
      p.join(_directories.cuts.path, image.baseName),
    );
    final exported = await _cropService.exportCells(
      bytes: bytes,
      layout: image.layout,
      cellIndexes: indexes,
      outputDirectory: outputDirectory,
      baseName: image.baseName,
    );

    _database
      ..upsertCutTask(
        id: image.taskId,
        imageId: image.id,
        status: 'exported',
        rows: image.layout.rows,
        columns: image.layout.columns,
        confidence: image.layout.confidence,
      )
      ..deleteCutResultsForImageSource(
        originalPath: image.originalPath,
        originalName: image.originalName,
      )
      ..deleteCutResultsForTask(image.taskId);

    for (var i = 0; i < exported.length; i++) {
      final cell = image.layout.cellAt(indexes[i]);
      _database.insertCutResult(
        id: _uuid.v4(),
        taskId: image.taskId,
        imageId: image.id,
        indexNo: i + 1,
        path: _toStoredPath(exported[i]),
        x: cell.x,
        y: cell.y,
        width: cell.width,
        height: cell.height,
        selected: true,
      );
    }

    _replaceSelected(
      image.copyWith(exportedPaths: exported),
      message: quiet
          ? null
          : '已导出 ${exported.length} 张图片到 ${outputDirectory.path}',
      busy: quiet ? null : false,
    );
  }

  void _replaceSelected(GridCutImage image, {String? message, bool? busy}) {
    _setState(
      value.copyWith(
        images: [
          for (final item in value.images)
            if (item.id == image.id) image else item,
        ],
        selectedImageId: image.id,
        message: message,
        isBusy: busy,
      ),
    );
  }

  void _setMessage(String message) {
    _setState(value.copyWith(message: message), saveWorkspace: false);
  }

  void _notifyCutResultsChanged() {
    final notifier = _cutResultsChangeNotifier;
    if (notifier == null) {
      return;
    }
    notifier.value++;
  }

  int cleanEmptyCutDirectories() {
    return const EmptyDirectoryCleaner().cleanChildren(_directories.cuts);
  }

  void _setState(
    GridCutState next, {
    bool saveWorkspace = true,
    bool saveSelection = true,
  }) {
    final selectionChanged = next.selectedImageId != value.selectedImageId;
    value = next;
    if (saveWorkspace) {
      _workspaceSaveQueue.markDirty();
    }
    if (saveSelection && selectionChanged) {
      _selectionSaveQueue.markDirty();
    }
  }

  void flushWorkspaceSnapshot() {
    _workspaceSaveQueue
      ..markDirty(delay: Duration.zero)
      ..flush();
    _selectionSaveQueue
      ..markDirty(delay: Duration.zero)
      ..flush();
  }

  void _restoreWorkspaceSnapshot() {
    final restored = _loadWorkspaceSnapshot();
    if (restored == null) {
      return;
    }
    _setState(restored, saveWorkspace: false, saveSelection: false);
    _workspaceSaveQueue
      ..markDirty(delay: Duration.zero)
      ..flush();
  }

  GridCutState? _loadWorkspaceSnapshot() {
    final raw = _database.getSetting(_workspaceSnapshotKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final imageValues = decoded['images'];
      if (imageValues is! List) {
        return null;
      }
      final images = <GridCutImage>[];
      for (final imageValue in imageValues) {
        final image = _imageFromJson(imageValue);
        if (image != null) {
          images.add(image);
        }
      }
      final inferredNextSequence = _nextSequenceFromImages(images);
      _nextImportSequence = math.max(
        _jsonInt(decoded['nextImportSequence'], 1),
        inferredNextSequence,
      );
      if (images.isEmpty) {
        return const GridCutState.initial();
      }
      final lightweightSelection = _database.getSetting(_selectionStateKey);
      final selectedImageId = lightweightSelection?.trim().isNotEmpty == true
          ? lightweightSelection
          : decoded['selectedImageId']?.toString();
      final restoredSelectedImageId =
          selectedImageId != null &&
              images.any((image) => image.id == selectedImageId)
          ? selectedImageId
          : images.first.id;
      final taskGroups = _taskGroupsFromJson(decoded['taskGroups'], images);
      final restored = GridCutState(
        images: images,
        taskGroups: taskGroups,
        taskOrder: _jsonStringList(decoded['taskOrder']),
        selectedImageId: restoredSelectedImageId,
        isBusy: false,
        message: '已恢复上次裁切任务',
        isDraggingOver: false,
      );
      final normalizedOrder = _normalizedTaskOrder(restored);
      return restored.copyWith(
        images: _imagesInTaskOrder(
          restored.copyWith(taskOrder: normalizedOrder),
        ),
        taskOrder: normalizedOrder,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _workspaceSnapshotToJson(GridCutState state) {
    return {
      'version': _workspaceSnapshotVersion,
      'nextImportSequence': _nextImportSequence,
      'selectedImageId': state.selectedImage?.id,
      'images': [for (final image in state.images) _imageToJson(image)],
      'taskGroups': [for (final group in state.taskGroups) _groupToJson(group)],
      'taskOrder': _normalizedTaskOrder(state),
    };
  }

  Map<String, Object?> _groupToJson(GridCutTaskGroup group) {
    return {
      'id': group.id,
      'name': group.name,
      'imageIds': group.imageIds,
      'expanded': group.expanded,
    };
  }

  Map<String, Object?> _imageToJson(GridCutImage image) {
    return {
      'id': image.id,
      'taskId': image.taskId,
      'originalPath': image.originalPath,
      'originalName': image.originalName,
      'storedPath': _toStoredPath(image.storedPath),
      'createdAt': image.createdAt.toIso8601String(),
      'layout': {
        'imageWidth': image.layout.imageWidth,
        'imageHeight': image.layout.imageHeight,
        'xLines': image.layout.xLines,
        'yLines': image.layout.yLines,
        'confidence': image.layout.confidence,
        'usedFallback': image.layout.usedFallback,
      },
      'selectedCells': image.selectedCells.toList()..sort(),
      'exportedPaths': [
        for (final path in image.exportedPaths) _toStoredPath(path),
      ],
    };
  }

  GridCutImage? _imageFromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final id = _jsonString(value['id'], '');
    final taskId = _jsonString(value['taskId'], '');
    final storedValue = _jsonString(value['storedPath'], '');
    final storedPath = _toRuntimePath(storedValue);
    final originalName = _jsonString(value['originalName'], '');
    if (id.isEmpty ||
        taskId.isEmpty ||
        storedPath.isEmpty ||
        originalName.isEmpty ||
        !File(storedPath).existsSync()) {
      return null;
    }
    final layout = _layoutFromJson(value['layout']);
    if (layout == null) {
      return null;
    }
    final selectedCells = _jsonIntSet(
      value['selectedCells'],
    ).where((index) => index >= 0 && index < layout.cellCount).toSet();
    final exportedPaths = _jsonStringList(
      value['exportedPaths'],
    ).map(_toRuntimePath).where((path) => File(path).existsSync()).toList();
    return GridCutImage(
      id: id,
      taskId: taskId,
      originalPath: _jsonString(value['originalPath'], storedPath),
      originalName: originalName,
      storedPath: storedPath,
      layout: layout,
      selectedCells: selectedCells,
      exportedPaths: exportedPaths,
      createdAt:
          DateTime.tryParse(_jsonString(value['createdAt'], '')) ??
          DateTime.now(),
    );
  }

  String _toStoredPath(String path) {
    if (path.trim().isEmpty || !p.isAbsolute(path)) {
      return path;
    }
    return _pathResolver.toStoredPath(path);
  }

  String _toRuntimePath(String path) {
    if (path.trim().isEmpty || p.isAbsolute(path)) {
      return path;
    }
    return _pathResolver.toRuntimePath(path);
  }

  List<GridCutTaskGroup> _taskGroupsFromJson(
    Object? value,
    List<GridCutImage> images,
  ) {
    if (value is! List) {
      return const [];
    }
    final validIds = images.map((image) => image.id).toSet();
    final claimedIds = <String>{};
    final groups = <GridCutTaskGroup>[];
    for (final item in value) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final id = _jsonString(item['id'], '');
      final name = _jsonString(item['name'], '');
      if (id.isEmpty || name.trim().isEmpty) {
        continue;
      }
      final imageIds = [
        for (final imageId in _jsonStringList(item['imageIds']))
          if (validIds.contains(imageId) && claimedIds.add(imageId)) imageId,
      ];
      if (imageIds.isEmpty) {
        continue;
      }
      groups.add(
        GridCutTaskGroup(
          id: id,
          name: name,
          imageIds: imageIds,
          expanded: _jsonBool(item['expanded'], true),
        ),
      );
    }
    return groups;
  }

  GridLayout? _layoutFromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final imageWidth = _jsonInt(value['imageWidth'], 0);
    final imageHeight = _jsonInt(value['imageHeight'], 0);
    if (imageWidth <= 0 || imageHeight <= 0) {
      return null;
    }
    final xLines = _normalizedLines(_jsonIntList(value['xLines']), imageWidth);
    final yLines = _normalizedLines(_jsonIntList(value['yLines']), imageHeight);
    if (xLines.length < 2 || yLines.length < 2) {
      return null;
    }
    return GridLayout(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      xLines: xLines,
      yLines: yLines,
      confidence: _jsonDouble(value['confidence'], 0),
      usedFallback: _jsonBool(value['usedFallback'], true),
    );
  }

  List<int> _normalizedLines(List<int> source, int maxValue) {
    final lines =
        source.map((line) => line.clamp(0, maxValue).toInt()).toSet().toList()
          ..sort();
    if (lines.isEmpty || lines.first != 0) {
      lines.insert(0, 0);
    }
    if (lines.last != maxValue) {
      lines.add(maxValue);
    }
    return lines;
  }

  String _jsonString(Object? value, String fallback) {
    if (value is String) {
      return value;
    }
    return value?.toString() ?? fallback;
  }

  int _jsonInt(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  double _jsonDouble(Object? value, double fallback) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _jsonBool(Object? value, bool fallback) {
    if (value is bool) {
      return value;
    }
    if (value is String) {
      return value.toLowerCase() == 'true';
    }
    return fallback;
  }

  List<int> _jsonIntList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return [for (final item in value) _jsonInt(item, 0)];
  }

  Set<int> _jsonIntSet(Object? value) {
    return _jsonIntList(value).toSet();
  }

  List<String> _jsonStringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return [for (final item in value) item?.toString() ?? ''];
  }

  List<GridCutTaskGroup> _groupsWithoutImages(
    Set<String> imageIds,
    List<GridCutTaskGroup> groups,
  ) {
    return [
      for (final group in groups) _groupWithoutImages(group, imageIds),
    ].where((group) => group.imageIds.isNotEmpty).toList();
  }

  List<String> _normalizedTaskOrder(GridCutState state) {
    final imageIds = state.images.map((image) => image.id).toSet();
    final groupedImageIds = {
      for (final group in state.taskGroups) ...group.imageIds,
    };
    final groupIds = state.taskGroups
        .where((group) => group.imageIds.any(imageIds.contains))
        .map((group) => group.id)
        .toSet();
    final validKeys = <String>{
      for (final groupId in groupIds) GridCutTaskNodeRef.group(groupId).key,
      for (final imageId in imageIds)
        if (!groupedImageIds.contains(imageId))
          GridCutTaskNodeRef.image(imageId).key,
    };
    final result = <String>[];
    final seen = <String>{};
    for (final key in state.taskOrder) {
      if (validKeys.contains(key) && seen.add(key)) {
        result.add(key);
      }
    }
    for (final group in state.taskGroups) {
      final key = GridCutTaskNodeRef.group(group.id).key;
      if (validKeys.contains(key) && seen.add(key)) {
        result.add(key);
      }
    }
    for (final image in state.images) {
      final key = GridCutTaskNodeRef.image(image.id).key;
      if (validKeys.contains(key) && seen.add(key)) {
        result.add(key);
      }
    }
    return result;
  }

  List<GridCutImage> _imagesInTaskOrder(GridCutState state) {
    final imagesById = {for (final image in state.images) image.id: image};
    final groupsById = {for (final group in state.taskGroups) group.id: group};
    final result = <GridCutImage>[];
    final seen = <String>{};
    void addImage(String imageId) {
      final image = imagesById[imageId];
      if (image != null && seen.add(imageId)) {
        result.add(image);
      }
    }

    for (final key in _normalizedTaskOrder(state)) {
      final node = GridCutTaskNodeRef.tryParse(key);
      if (node?.kind == GridCutTaskNodeKind.image) {
        addImage(node!.id);
      } else if (node?.kind == GridCutTaskNodeKind.group) {
        for (final imageId in groupsById[node!.id]?.imageIds ?? const []) {
          addImage(imageId);
        }
      }
    }
    for (final image in state.images) {
      addImage(image.id);
    }
    return result;
  }

  void _insertBefore(List<String> values, String value, String? beforeValue) {
    values.remove(value);
    final index = beforeValue == null ? -1 : values.indexOf(beforeValue);
    values.insert(index < 0 ? values.length : index, value);
  }

  List<String> _withInsertedImage(
    List<String> imageIds,
    String imageId,
    String? beforeNodeKey,
  ) {
    final result = [
      for (final id in imageIds)
        if (id != imageId) id,
    ];
    final before = beforeNodeKey == null
        ? null
        : GridCutTaskNodeRef.tryParse(beforeNodeKey);
    final index = before?.kind == GridCutTaskNodeKind.image
        ? result.indexOf(before!.id)
        : -1;
    result.insert(index < 0 ? result.length : index, imageId);
    return result;
  }

  GridCutTaskGroup _groupWithoutImages(
    GridCutTaskGroup group,
    Set<String> imageIds,
  ) {
    return group.copyWith(
      imageIds: [
        for (final imageId in group.imageIds)
          if (!imageIds.contains(imageId)) imageId,
      ],
    );
  }

  String _uniqueGroupName(String name) {
    final existingNames = value.taskGroups.map((group) => group.name).toSet();
    var candidate = name;
    var index = 2;
    while (existingNames.contains(candidate)) {
      candidate = '$name $index';
      index++;
    }
    return candidate;
  }

  String _safeGroupName(String name) {
    var result = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final char in const ['<', '>', ':', '"', '/', '\\', '|', '?', '*']) {
      result = result.replaceAll(char, '_');
    }
    result = result.replaceAll(RegExp(r'[. ]+$'), '');
    return result.isEmpty ? '图片任务编组' : result;
  }

  int _nextSequenceFromImages(List<GridCutImage> images) {
    var highest = 0;
    for (final image in images) {
      final stem = p.basenameWithoutExtension(image.originalName);
      if (!stem.startsWith(_projectName)) {
        continue;
      }
      final sequence = int.tryParse(stem.substring(_projectName.length));
      if (sequence != null && sequence > highest) {
        highest = sequence;
      }
    }
    return highest + 1;
  }

  String? _nextSelectedImageIdAfterRemoval({
    required String removedId,
    required int removedIndex,
    required List<GridCutImage> remainingImages,
  }) {
    if (remainingImages.isEmpty) {
      return null;
    }
    if (value.selectedImageId != removedId) {
      return value.selectedImageId;
    }
    final nextIndex = removedIndex.clamp(0, remainingImages.length - 1).toInt();
    return remainingImages[nextIndex].id;
  }

  bool _isSupportedImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return const {'.png', '.jpg', '.jpeg', '.webp', '.bmp'}.contains(ext);
  }
}
