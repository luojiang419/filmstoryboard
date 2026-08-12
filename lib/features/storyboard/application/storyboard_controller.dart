import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/database/app_database.dart';
import '../../../core/services/empty_directory_cleaner.dart';
import '../../../core/services/vision_request_rate_limiter.dart';
import '../../../core/services/workspace_snapshot_save_queue.dart';
import '../../../core/services/workspace_directories.dart';
import '../../grid_cut/application/grid_cut_controller.dart';
import '../../projects/application/project_aspect_controller.dart';
import '../../projects/data/project_path_resolver.dart';
import '../../settings/application/settings_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../data/image_generation_service.dart';
import '../data/image_generation_diagnostic_logger.dart';
import '../domain/image_generation_provider_resolver.dart';
import '../data/vision_run_logger.dart';
import '../data/vision_storyboard_service.dart';
import '../domain/storyboard_models.dart';

final storyboardControllerProvider = Provider<StoryboardController>(
  (ref) {
    final controller = StoryboardController(
      database: ref.watch(appDatabaseProvider),
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      projectAspectController: ref.watch(projectAspectControllerProvider),
    );
    unawaited(controller.refreshAssets());
    final cutResultsChangeNotifier = ref.watch(
      cutResultsChangeNotifierProvider,
    );
    void handleCutResultsChanged() {
      controller.handleCutResultsChanged();
    }

    cutResultsChangeNotifier.addListener(handleCutResultsChanged);
    ref.onDispose(() {
      cutResultsChangeNotifier.removeListener(handleCutResultsChanged);
      controller.dispose();
    });
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
    projectAspectControllerProvider,
    cutResultsChangeNotifierProvider,
  ],
);

const _storyDesignFolderId = 'design-storyboards';
const _storyDesignFolderName = '分镜图';

class StoryboardController extends ValueNotifier<StoryboardState> {
  StoryboardController({
    required AppDatabase database,
    WorkspaceDirectories? directories,
    SettingsController? settingsController,
    ProjectAspectController? projectAspectController,
    VisionStoryboardService? visionService,
    ImageGenerationService? imageGenerationService,
  }) : _database = database,
       _directories = directories,
       _pathResolver = directories == null
           ? null
           : ProjectPathResolver(directories.workspaceRoot),
       _settingsController = settingsController,
       _projectAspectController = projectAspectController,
       _visionService = visionService ?? VisionStoryboardService(),
       _imageGenerationService =
           imageGenerationService ??
           ImageGenerationService(
             diagnosticLogger: directories == null
                 ? null
                 : ImageGenerationDiagnosticLogger(directories.logs),
           ),
       _visionLogger = directories == null
           ? null
           : VisionRunLogger(directories.logs),
       _ownsVisionService = visionService == null,
       _ownsImageGenerationService = imageGenerationService == null,
       super(const StoryboardState.initial()) {
    _workspaceSaveQueue = WorkspaceSnapshotSaveQueue(
      buildSnapshot: () => jsonEncode(_workspaceSnapshotToJson(value)),
      writeSnapshot: (snapshot) =>
          _database.setSetting(_workspaceSnapshotKey, snapshot),
    );
    _selectionSaveQueue = WorkspaceSnapshotSaveQueue(
      buildSnapshot: () => value.selectedBoardId ?? '',
      writeSnapshot: (selection) =>
          _database.setSetting(_selectionStateKey, selection),
    );
    _projectAspectController?.addListener(_handleProjectAspectChanged);
    _restoreWorkspaceOrCreateDefault();
  }

  static const _workspaceSnapshotKey = 'storyboardWorkspaceSnapshot';
  static const _selectionStateKey = 'storyboardWorkspaceSelection';
  static const _workspaceSnapshotVersion = 4;
  static const _maxConfiguredGridExtent = 12;
  static const _maxAutomaticGridExtent = storyboardMaxGridExtent;
  static const _historyLimit = 100;
  static const _aiEditedImagesDirectorySuffix = 'AI修改';
  static const _aiEditedImagesSourceName = 'AI修改';
  static const _aiEditedImagesImageId = 'storyboard-ai-edited-images';
  static const _manualReplacementDirectorySuffix = '手动替换';
  static const _manualReplacementSourceName = '手动替换';
  static const _manualReplacementImageId =
      'storyboard-manual-replacement-images';
  static const _manualAddedFolderName = '手动添加';
  static const _assetNormalizationVersionKey =
      'storyboardAssetNormalizationVersion';
  static const _assetNormalizationVersion = 1;
  static const highDefinitionRedrawModel = 'gemini-3-pro-image';
  static const highDefinitionRedrawImageSize = '4K';

  final AppDatabase _database;
  final WorkspaceDirectories? _directories;
  final ProjectPathResolver? _pathResolver;
  final SettingsController? _settingsController;
  final ProjectAspectController? _projectAspectController;
  final VisionStoryboardService _visionService;
  final ImageGenerationService _imageGenerationService;
  final VisionRunLogger? _visionLogger;
  final bool _ownsVisionService;
  final bool _ownsImageGenerationService;
  final _uuid = const Uuid();
  late final WorkspaceSnapshotSaveQueue _workspaceSaveQueue;
  late final WorkspaceSnapshotSaveQueue _selectionSaveQueue;
  Future<void>? _assetRefreshFuture;
  bool _assetRefreshPending = false;
  String? _pendingAssetRefreshMessage;
  bool _pendingAssetCacheEviction = false;
  var _assetFileSignatures = <String, _AssetFileSignature>{};
  bool _disposed = false;
  final _visionChannelsByBoardId = <String, _BoardVisionTaskChannel>{};
  final _visionOperationGenerationByBoardId = <String, int>{};
  final _visionCancelRequestedBoardIds = <String>{};
  final _boardTaskMessages = <String, String>{};
  final _undoHistoryByBoardId = <String, List<StoryboardBoard>>{};
  final _redoHistoryByBoardId = <String, List<StoryboardBoard>>{};
  final _activeImageGenerationCountByBoardId = <String, int>{};
  Future<void> _imageResultCommitTail = Future<void>.value();

  @override
  void dispose() {
    _disposed = true;
    _projectAspectController?.removeListener(_handleProjectAspectChanged);
    _workspaceSaveQueue.dispose();
    _selectionSaveQueue.dispose();
    _visionService.cancelActiveRequests();
    if (_ownsVisionService) {
      _visionService.close();
    }
    if (_ownsImageGenerationService) {
      _imageGenerationService.close();
    }
    super.dispose();
  }

  double get projectImageAspectRatio =>
      _projectAspectController?.state.effectiveRatio.value ??
      StoryboardBoard.defaultImageAspectRatio;

  String get projectAspectRatioLabel =>
      _projectAspectController?.state.effectiveRatio.label ?? '16:9';

  void _handleProjectAspectChanged() {
    final ratio = projectImageAspectRatio;
    if (value.boards.every(
      (board) => (board.imageAspectRatio - ratio).abs() < 0.0001,
    )) {
      return;
    }
    _setState(
      value.copyWith(
        boards: [
          for (final board in value.boards)
            board.copyWith(imageAspectRatio: ratio).withAdaptiveHeight(),
        ],
        message: '项目画幅已切换为 $projectAspectRatioLabel',
      ),
    );
  }

  void cancelVisionAnalysis() {
    final boardId = value.selectedBoardId;
    final channel = boardId == null ? null : _visionChannelsByBoardId[boardId];
    if (boardId == null ||
        channel?.activeTask == null ||
        channel!.isCancelling) {
      return;
    }
    channel.isCancelling = true;
    _visionCancelRequestedBoardIds.add(boardId);
    _visionOperationGenerationByBoardId[boardId] =
        (_visionOperationGenerationByBoardId[boardId] ?? 0) + 1;
    _syncVisionTaskState(boardId: boardId, message: '正在取消当前视觉任务...');
    unawaited(_logVisionEvent('cancel_requested', {'boardId': boardId}));
  }

  _VisionOperationToken _beginVisionOperation(String boardId) {
    _visionCancelRequestedBoardIds.remove(boardId);
    final generation = (_visionOperationGenerationByBoardId[boardId] ?? 0) + 1;
    _visionOperationGenerationByBoardId[boardId] = generation;
    return _VisionOperationToken(boardId: boardId, generation: generation);
  }

  bool _isVisionOperationCancelled(_VisionOperationToken token) {
    return _visionCancelRequestedBoardIds.contains(token.boardId) ||
        token.generation !=
            (_visionOperationGenerationByBoardId[token.boardId] ?? 0);
  }

  Future<void> _finishCancelledVisionOperation(
    _VisionOperationToken token, {
    required String message,
    String? runId,
  }) async {
    _visionCancelRequestedBoardIds.remove(token.boardId);
    final channel = _visionChannelsByBoardId[token.boardId];
    if (channel != null) {
      channel.isCancelling = false;
    }
    final details = <String, Object?>{
      'boardId': token.boardId,
      'generation': token.generation,
      'message': message,
    };
    if (runId != null) {
      details['runId'] = runId;
    }
    await _logVisionEvent('cancelled', details);
    _syncVisionTaskState(boardId: token.boardId, message: message);
  }

  Future<void> _logVisionEvent(
    String event,
    Map<String, Object?> details,
  ) async {
    final logger = _visionLogger;
    if (logger == null) {
      return;
    }
    await logger.write(event, details);
  }

  String _visionLogPreview(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 1000) {
      return compact;
    }
    return '${compact.substring(0, 1000)}...';
  }

  Future<void> _enqueueVisionTask(StoryboardVisionTask task) {
    final channel = _visionChannelsByBoardId.putIfAbsent(
      task.boardId,
      _BoardVisionTaskChannel.new,
    );
    final activeTask = channel.activeTask;
    if (activeTask != null && activeTask.task.sameTarget(task)) {
      _syncVisionTaskState(
        boardId: task.boardId,
        message: _visionTaskAlreadyRunningMessage(task),
      );
      return activeTask.completer.future;
    }
    for (final queuedTask in channel.queue) {
      if (queuedTask.task.sameTarget(task)) {
        _syncVisionTaskState(
          boardId: task.boardId,
          message: _visionTaskAlreadyQueuedMessage(task),
        );
        return queuedTask.completer.future;
      }
    }

    final queuedTask = _QueuedVisionTask(task);
    channel.queue.add(queuedTask);
    _syncVisionTaskState(
      boardId: task.boardId,
      message: channel.activeTask == null
          ? _visionTaskStartingMessage(task)
          : _visionTaskQueuedMessage(task),
    );
    unawaited(_runVisionTaskQueue(task.boardId, channel));
    return queuedTask.completer.future;
  }

  Future<void> _runVisionTaskQueue(
    String boardId,
    _BoardVisionTaskChannel channel,
  ) async {
    if (channel.isRunning) {
      return;
    }
    channel.isRunning = true;
    try {
      while (channel.queue.isNotEmpty) {
        final queuedTask = channel.queue.removeAt(0);
        channel
          ..activeTask = queuedTask
          ..isCancelling = false;
        _syncVisionTaskState(
          boardId: boardId,
          message: _visionTaskStartingMessage(queuedTask.task),
        );
        final operationToken = _beginVisionOperation(boardId);
        try {
          await _runVisionTask(queuedTask.task, operationToken);
        } catch (error) {
          _syncVisionTaskState(boardId: boardId, message: '视觉任务失败：$error');
        } finally {
          if (!queuedTask.completer.isCompleted) {
            queuedTask.completer.complete();
          }
          if (identical(channel.activeTask, queuedTask)) {
            channel.activeTask = null;
          }
          channel.isCancelling = false;
          _syncVisionTaskState();
        }
      }
    } finally {
      channel
        ..isRunning = false
        ..activeTask = null
        ..isCancelling = false;
      if (channel.queue.isEmpty) {
        _visionChannelsByBoardId.remove(boardId);
      }
      _syncVisionTaskState();
    }
  }

  Future<void> _runVisionTask(
    StoryboardVisionTask task,
    _VisionOperationToken operationToken,
  ) async {
    switch (task.kind) {
      case StoryboardVisionTaskKind.analyze:
        _database.deleteVisionAnalysisForBoard(task.boardId);
        await _analyzeBoardWithVision(
          boardId: task.boardId,
          operationToken: operationToken,
        );
        return;
      case StoryboardVisionTaskKind.reorder:
        await _reorderBoardByVisionAnalysis(
          boardId: task.boardId,
          operationToken: operationToken,
        );
        return;
    }
  }

  void _syncVisionTaskState({String? boardId, String? message}) {
    if (boardId != null && message != null) {
      _boardTaskMessages[boardId] = message;
    }
    final selectedBoardId = value.selectedBoardId;
    final selectedChannel = selectedBoardId == null
        ? null
        : _visionChannelsByBoardId[selectedBoardId];
    final selectedActiveTask = selectedChannel?.activeTask?.task;
    final activeTasks = [
      for (final channel in _visionChannelsByBoardId.values)
        if (channel.activeTask case final activeTask?) activeTask.task,
    ];
    final queuedTasks = [
      for (final channel in _visionChannelsByBoardId.values)
        for (final queuedTask in channel.queue) queuedTask.task,
    ];
    value = value.copyWith(
      isAnalyzing: selectedActiveTask != null,
      isCancellingAnalysis: selectedChannel?.isCancelling ?? false,
      activeVisionBoardId: selectedActiveTask?.boardId,
      activeVisionTaskKind: selectedActiveTask?.kind,
      activeVisionTasks: activeTasks,
      queuedVisionTasks: queuedTasks,
      generatingImageBoardIds: _generatingImageBoardIds(),
      isGeneratingImage:
          selectedBoardId != null &&
          (_activeImageGenerationCountByBoardId[selectedBoardId] ?? 0) > 0,
      message: boardId != null && boardId == selectedBoardId ? message : null,
    );
  }

  void _setBoardTaskMessage(String boardId, String message) {
    if (_disposed) {
      return;
    }
    _syncVisionTaskState(boardId: boardId, message: message);
  }

  List<String> _generatingImageBoardIds() {
    return [
      for (final entry in _activeImageGenerationCountByBoardId.entries)
        if (entry.value > 0) entry.key,
    ];
  }

  StoryboardState _withSelectedBoardTaskStatus(StoryboardState state) {
    final selectedBoardId = state.selectedBoardId;
    final selectedChannel = selectedBoardId == null
        ? null
        : _visionChannelsByBoardId[selectedBoardId];
    final selectedActiveTask = selectedChannel?.activeTask?.task;
    return state.copyWith(
      isAnalyzing: selectedActiveTask != null,
      isCancellingAnalysis: selectedChannel?.isCancelling ?? false,
      isGeneratingImage:
          selectedBoardId != null &&
          (_activeImageGenerationCountByBoardId[selectedBoardId] ?? 0) > 0,
      activeVisionBoardId: selectedActiveTask?.boardId,
      activeVisionTaskKind: selectedActiveTask?.kind,
      activeVisionTasks: [
        for (final channel in _visionChannelsByBoardId.values)
          if (channel.activeTask case final activeTask?) activeTask.task,
      ],
      queuedVisionTasks: [
        for (final channel in _visionChannelsByBoardId.values)
          for (final queuedTask in channel.queue) queuedTask.task,
      ],
      generatingImageBoardIds: _generatingImageBoardIds(),
      message: selectedBoardId == null
          ? state.message
          : _boardTaskMessages[selectedBoardId] ?? state.message,
    );
  }

  String _visionTaskStartingMessage(StoryboardVisionTask task) {
    return switch (task.kind) {
      StoryboardVisionTaskKind.analyze => '正在启动自动解析...',
      StoryboardVisionTaskKind.reorder => '正在启动自动重排序...',
    };
  }

  String _visionTaskQueuedMessage(StoryboardVisionTask task) {
    return switch (task.kind) {
      StoryboardVisionTaskKind.analyze => '已加入自动解析队列',
      StoryboardVisionTaskKind.reorder => '已加入自动重排序队列',
    };
  }

  String _visionTaskAlreadyRunningMessage(StoryboardVisionTask task) {
    return switch (task.kind) {
      StoryboardVisionTaskKind.analyze => '当前画板正在自动解析',
      StoryboardVisionTaskKind.reorder => '当前画板正在自动重排序',
    };
  }

  String _visionTaskAlreadyQueuedMessage(StoryboardVisionTask task) {
    return switch (task.kind) {
      StoryboardVisionTaskKind.analyze => '当前画板已在自动解析队列中',
      StoryboardVisionTaskKind.reorder => '当前画板已在自动重排序队列中',
    };
  }

  Future<void> refreshAssets() {
    return _reloadAssets();
  }

  void handleCutResultsChanged() {
    unawaited(
      _reloadAssets(
        message: '裁切结果已更新，资源已刷新',
        evictImageCache: true,
        ensureLatest: true,
      ),
    );
  }

  Future<void> createFolder(String name) async {
    final root = _directories?.storyboardFolders;
    if (root == null) {
      value = value.copyWith(message: '数据目录尚未初始化，无法创建文件夹');
      return;
    }
    if (!root.existsSync()) {
      await root.create(recursive: true);
    }
    final safeName = _safeFolderName(name);
    final folderName = _uniqueFolderName(root, safeName);
    final folder = Directory(p.join(root.path, folderName));
    await folder.create(recursive: true);
    await _reloadAssets(message: '已创建文件夹 $folderName', ensureLatest: true);
  }

  Future<void> copyAssetToFolder({
    required StoryboardCutAsset asset,
    required String folderId,
  }) async {
    final folder = _folderDirectory(folderId);
    if (folder == null) {
      value = value.copyWith(message: '目标文件夹不存在，请刷新后重试');
      return;
    }
    final source = File(asset.path);
    if (!source.existsSync() || !_isSupportedImage(source.path)) {
      await _reloadAssets(message: '图片文件不存在，已刷新资源状态', ensureLatest: true);
      return;
    }
    final copied = await _copyImageFileToFolder(source, folder);
    if (copied == null) {
      value = value.copyWith(message: '图片已在 ${p.basename(folder.path)} 中');
      return;
    }
    await _reloadAssets(
      message: '已保存图片到 ${p.basename(folder.path)}',
      ensureLatest: true,
    );
  }

  Future<void> copyPathsToFolder({
    required Iterable<String> paths,
    required String folderId,
  }) async {
    final folder = _folderDirectory(folderId);
    if (folder == null) {
      value = value.copyWith(message: '目标文件夹不存在，请刷新后重试');
      return;
    }
    final imagePaths = paths.where(_isSupportedImage).toList();
    if (imagePaths.isEmpty) {
      value = value.copyWith(message: '未发现支持的图片文件');
      return;
    }

    var copiedCount = 0;
    var existingCount = 0;
    for (final imagePath in imagePaths) {
      final source = File(imagePath);
      if (!source.existsSync()) {
        continue;
      }
      final copied = await _copyImageFileToFolder(source, folder);
      if (copied == null) {
        existingCount++;
      } else {
        copiedCount++;
      }
    }

    final folderName = p.basename(folder.path);
    if (copiedCount == 0 && existingCount > 0) {
      value = value.copyWith(message: '图片已在 $folderName 中');
      return;
    }
    await _reloadAssets(
      message: '已保存 $copiedCount 张图片到 $folderName',
      ensureLatest: true,
    );
  }

  Future<int> importPathsToManualFolder(Iterable<String> paths) async {
    final importedAssets = await _archivePathsToManualFolder(paths);
    if (importedAssets.isEmpty) {
      return 0;
    }
    value = value.copyWith(
      message: '已保存 ${importedAssets.length} 张图片到 $_manualAddedFolderName',
    );
    return importedAssets.length;
  }

  Future<int> importPathsToSelectedBoard(Iterable<String> paths) async {
    final board = value.selectedBoard;
    if (board == null) {
      value = value.copyWith(message: '请先选择画板');
      return 0;
    }
    if (_guardLockedBoard(board, '拖入图片')) {
      return 0;
    }

    final targetBoardId = board.id;
    final importedAssets = await _archivePathsToManualFolder(paths);
    if (importedAssets.isEmpty) {
      return 0;
    }

    final currentBoard = value.selectedBoard;
    if (currentBoard == null || currentBoard.id != targetBoardId) {
      value = value.copyWith(
        message:
            '已保存 ${importedAssets.length} 张图片到 $_manualAddedFolderName；画板已切换，未自动排版',
      );
      return 0;
    }
    if (_guardLockedBoard(currentBoard, '拖入图片')) {
      return 0;
    }

    final previousCount = currentBoard.visibleItemCount;
    setAssetsUsed(importedAssets, true);
    final addedCount = math.max(
      0,
      (value.selectedBoard?.visibleItemCount ?? previousCount) - previousCount,
    );
    value = value.copyWith(
      message: addedCount == importedAssets.length
          ? '已保存并自动排版 $addedCount 张图片'
          : addedCount == 0
          ? '图片已保存到 $_manualAddedFolderName，当前画板没有可新增的位置'
          : '已保存 ${importedAssets.length} 张图片，并自动排版 $addedCount 张',
    );
    return addedCount;
  }

  Future<List<StoryboardCutAsset>> _archivePathsToManualFolder(
    Iterable<String> paths,
  ) async {
    final root = _directories?.storyboardFolders;
    if (root == null) {
      value = value.copyWith(message: '数据目录尚未初始化，无法保存图片');
      return const [];
    }
    final folder = Directory(p.join(root.path, _manualAddedFolderName));
    await folder.create(recursive: true);

    final sources = <File>[];
    final seenPaths = <String>{};
    for (final path in paths) {
      if (!_isSupportedImage(path)) {
        continue;
      }
      final source = File(path);
      if (!source.existsSync()) {
        continue;
      }
      final normalizedPath = _normalizedFilePath(source.path);
      if (seenPaths.add(normalizedPath)) {
        sources.add(source);
      }
    }
    if (sources.isEmpty) {
      value = value.copyWith(message: '未发现支持的图片文件');
      return const [];
    }

    final archivedPaths = <String>[];
    for (final source in sources) {
      final sourceInManualFolder =
          _normalizedFilePath(p.dirname(source.path)) ==
          _normalizedFilePath(folder.path);
      final archived = sourceInManualFolder
          ? source
          : await _copyImageFileToFolder(source, folder);
      if (archived != null) {
        archivedPaths.add(_normalizedFilePath(archived.path));
      }
    }
    if (archivedPaths.isEmpty) {
      value = value.copyWith(message: '未能保存图片，请检查文件权限');
      return const [];
    }

    await _reloadAssets(ensureLatest: true);
    final archivedPathSet = archivedPaths.toSet();
    for (final candidate in value.folders) {
      if (candidate.id != _manualAddedFolderName) {
        continue;
      }
      return candidate.assets
          .where(
            (asset) =>
                archivedPathSet.contains(_normalizedFilePath(asset.path)),
          )
          .toList(growable: false);
    }
    return const [];
  }

  Future<void> createResourceGroup({
    required String name,
    Iterable<String> assetIds = const [],
    Iterable<String> sourceImageIds = const [],
    Iterable<String> folderIds = const [],
  }) async {
    final validAssetIds = {
      for (final asset in value.assets) asset.id,
      for (final folder in value.folders)
        for (final asset in folder.assets) asset.id,
    };
    final validSourceImageIds = {
      for (final asset in value.assets) asset.imageId,
    };
    final validFolderIds = {for (final folder in value.folders) folder.id};
    final nextAssetIds = [
      for (final assetId in assetIds.toSet())
        if (validAssetIds.contains(assetId)) assetId,
    ];
    final nextSourceImageIds = [
      for (final sourceImageId in sourceImageIds.toSet())
        if (validSourceImageIds.contains(sourceImageId)) sourceImageId,
    ];
    final nextFolderIds = [
      for (final folderId in folderIds.toSet())
        if (validFolderIds.contains(folderId)) folderId,
    ];
    if (nextAssetIds.isEmpty &&
        nextSourceImageIds.isEmpty &&
        nextFolderIds.isEmpty) {
      value = value.copyWith(message: '请先选择要编组的裁切资源');
      return;
    }

    final safeName = _safeFolderName(name);
    final groupName = _uniqueResourceGroupName(safeName);
    final movingSourceIds = nextSourceImageIds.toSet();
    final movingFolderIds = nextFolderIds.toSet();
    final movingAssetIds = {
      ...nextAssetIds,
      for (final asset in value.assets)
        if (movingSourceIds.contains(asset.imageId)) asset.id,
      for (final folder in value.folders)
        if (movingFolderIds.contains(folder.id))
          for (final asset in folder.assets) asset.id,
    };
    final currentTree = _normalizeResourceTree(
      groups: value.resourceGroups,
      rootOrder: value.resourceRootOrder,
      assets: value.assets,
      folders: value.folders,
    );
    final groups = [
      for (final group in currentTree.groups)
        _resourceGroupWithout(
          group,
          assetIds: movingAssetIds,
          sourceImageIds: movingSourceIds,
          folderIds: movingFolderIds,
        ),
    ];
    final groupId = _uuid.v4();
    final selectedNodeKeys = <String>{
      for (final sourceImageId in nextSourceImageIds)
        StoryboardResourceNodeRef.source(sourceImageId).key,
      for (final folderId in nextFolderIds)
        StoryboardResourceNodeRef.folder(folderId).key,
    };
    final childOrder = [
      for (final key in currentTree.rootOrder)
        if (selectedNodeKeys.contains(key)) key,
      for (final key in selectedNodeKeys)
        if (!currentTree.rootOrder.contains(key)) key,
    ];
    groups.add(
      StoryboardResourceGroup(
        id: groupId,
        name: groupName,
        assetIds: nextAssetIds,
        sourceImageIds: nextSourceImageIds,
        folderIds: nextFolderIds,
        childOrder: childOrder,
      ),
    );
    final rootOrder = [
      for (final key in currentTree.rootOrder)
        if (!selectedNodeKeys.contains(key)) key,
      StoryboardResourceNodeRef.group(groupId).key,
    ];
    final nextTree = _normalizeResourceTree(
      groups: groups,
      rootOrder: rootOrder,
      assets: value.assets,
      folders: value.folders,
    );
    _setState(
      value.copyWith(
        resourceGroups: nextTree.groups,
        resourceRootOrder: nextTree.rootOrder,
        message: '已创建裁切资源编组 $groupName',
      ),
    );
  }

  void toggleResourceGroupExpanded(String groupId) {
    _setState(
      value.copyWith(
        resourceGroups: [
          for (final group in value.resourceGroups)
            if (group.id == groupId)
              group.copyWith(expanded: !group.expanded)
            else
              group,
        ],
      ),
    );
  }

  bool renameResourceGroup(String groupId, String name) {
    if (name.trim().isEmpty) {
      value = value.copyWith(message: '编组名称不能为空');
      return false;
    }
    final index = value.resourceGroups.indexWhere(
      (group) => group.id == groupId,
    );
    if (index < 0) {
      return false;
    }
    final safeName = _safeFolderName(name);
    final uniqueName = _uniqueResourceGroupName(
      safeName,
      excludingGroupId: groupId,
    );
    final previousName = value.resourceGroups[index].name;
    _setState(
      value.copyWith(
        resourceGroups: [
          for (final group in value.resourceGroups)
            if (group.id == groupId)
              group.copyWith(name: uniqueName)
            else
              group,
        ],
        message: '已将 $previousName 重命名为 $uniqueName',
      ),
    );
    return true;
  }

  bool moveResourceNode(
    String nodeKey, {
    String? targetGroupId,
    String? beforeNodeKey,
  }) {
    final node = StoryboardResourceNodeRef.tryParse(nodeKey);
    if (node == null) {
      return false;
    }
    final currentTree = _normalizeResourceTree(
      groups: value.resourceGroups,
      rootOrder: value.resourceRootOrder,
      assets: value.assets,
      folders: value.folders,
    );
    if (targetGroupId != null &&
        !currentTree.groups.any((group) => group.id == targetGroupId)) {
      return false;
    }
    if (!_resourceNodeExists(node, currentTree.groups)) {
      return false;
    }
    if (node.kind == StoryboardResourceNodeKind.group &&
        targetGroupId != null &&
        (targetGroupId == node.id ||
            _isResourceGroupDescendant(
              targetGroupId,
              ancestorGroupId: node.id,
              groups: currentTree.groups,
            ))) {
      _setState(
        value.copyWith(message: '不能把编组移动到自身或其子编组中'),
        saveWorkspace: false,
      );
      return false;
    }

    var groups = [
      for (final group in currentTree.groups)
        group.copyWith(
          folderIds: node.kind == StoryboardResourceNodeKind.folder
              ? [
                  for (final id in group.folderIds)
                    if (id != node.id) id,
                ]
              : group.folderIds,
          sourceImageIds: node.kind == StoryboardResourceNodeKind.source
              ? [
                  for (final id in group.sourceImageIds)
                    if (id != node.id) id,
                ]
              : group.sourceImageIds,
          childOrder: [
            for (final key in group.childOrder)
              if (key != nodeKey) key,
          ],
        ),
    ];
    var rootOrder = [
      for (final key in currentTree.rootOrder)
        if (key != nodeKey) key,
    ];

    if (node.kind == StoryboardResourceNodeKind.group) {
      groups = [
        for (final group in groups)
          if (group.id == node.id)
            group.copyWith(parentGroupId: targetGroupId)
          else
            group,
      ];
    } else if (targetGroupId != null) {
      groups = [
        for (final group in groups)
          if (group.id == targetGroupId)
            group.copyWith(
              folderIds: node.kind == StoryboardResourceNodeKind.folder
                  ? [...group.folderIds, node.id]
                  : group.folderIds,
              sourceImageIds: node.kind == StoryboardResourceNodeKind.source
                  ? [...group.sourceImageIds, node.id]
                  : group.sourceImageIds,
            )
          else
            group,
      ];
    }

    if (targetGroupId == null) {
      _insertResourceNodeBefore(rootOrder, nodeKey, beforeNodeKey);
    } else {
      groups = [
        for (final group in groups)
          if (group.id == targetGroupId)
            group.copyWith(
              childOrder: _resourceOrderWithInsertedNode(
                group.childOrder,
                nodeKey,
                beforeNodeKey,
              ),
            )
          else
            group,
      ];
    }

    final nextTree = _normalizeResourceTree(
      groups: groups,
      rootOrder: rootOrder,
      assets: value.assets,
      folders: value.folders,
    );
    _setState(
      value.copyWith(
        resourceGroups: nextTree.groups,
        resourceRootOrder: nextTree.rootOrder,
        message: targetGroupId == null ? '已调整裁切资源顺序' : '已移动到编组中',
      ),
    );
    return true;
  }

  Future<void> _reloadAssets({
    String? message,
    bool evictImageCache = false,
    bool ensureLatest = false,
  }) {
    if (_disposed) {
      return Future.value();
    }

    final activeRefresh = _assetRefreshFuture;
    if (activeRefresh != null) {
      if (ensureLatest) {
        _queueAssetRefresh(message, evictImageCache);
      }
      return activeRefresh;
    }

    _queueAssetRefresh(message, evictImageCache);
    final completer = Completer<void>();
    _assetRefreshFuture = completer.future;
    unawaited(_drainAssetRefreshQueue(completer));
    return completer.future;
  }

  void _queueAssetRefresh(String? message, bool evictImageCache) {
    _assetRefreshPending = true;
    _pendingAssetRefreshMessage = message;
    _pendingAssetCacheEviction |= evictImageCache;
  }

  Future<void> _drainAssetRefreshQueue(Completer<void> completer) async {
    try {
      while (_assetRefreshPending && !_disposed) {
        final message = _pendingAssetRefreshMessage;
        final evictImageCache = _pendingAssetCacheEviction;
        _assetRefreshPending = false;
        _pendingAssetRefreshMessage = null;
        _pendingAssetCacheEviction = false;
        await _performAssetRefresh(
          message: message,
          evictImageCache: evictImageCache,
        );
      }
      completer.complete();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      _assetRefreshFuture = null;
    }
  }

  Future<void> _performAssetRefresh({
    required String? message,
    required bool evictImageCache,
  }) async {
    final records = _database.listCutResults();
    final normalization = _detectLegacyAssetNormalization(records);
    final scanRequest = _AssetScanRequest(
      cutResults: [
        for (final record in records)
          _AssetScanEntry(id: record.id, path: _toRuntimePath(record.path)),
      ],
      storyboardFoldersPath: _directories?.storyboardFolders.path,
      storyDesignImagesPath: _directories == null
          ? null
          : p.join(_directories.generatedImages.path, 'design'),
      cutsPath: _directories?.cuts.path,
    );
    final scanResult = await compute(
      _scanStoryboardAssets,
      scanRequest,
      debugLabel: 'storyboard-asset-refresh',
    );
    if (_disposed) {
      return;
    }

    final deleted = _database.deleteCutResultsByIds(scanResult.missingIds);
    final refreshedRecords = _database.listCutResults();
    final aiEditedIndexByAssetId = _aiEditedIndexByAssetId(refreshedRecords);
    final manualReplacementIndexByAssetId = _manualReplacementIndexByAssetId(
      refreshedRecords,
    );
    final assets = refreshedRecords
        .map(
          (record) => StoryboardCutAsset(
            id: record.id,
            imageId: _isAiEditedAssetId(record.id)
                ? _aiEditedImagesImageId
                : _isManualReplacementAssetId(record.id)
                ? _manualReplacementImageId
                : record.imageId,
            sourceName: _isAiEditedAssetId(record.id)
                ? _aiEditedImagesSourceName
                : _isManualReplacementAssetId(record.id)
                ? _manualReplacementSourceName
                : record.originalName,
            path: _toRuntimePath(record.path),
            indexNo:
                aiEditedIndexByAssetId[record.id] ??
                manualReplacementIndexByAssetId[record.id] ??
                record.indexNo,
          ),
        )
        .toList();
    final folders = _foldersFromScan(scanResult.folders);
    final resourceTree = _normalizeResourceTree(
      groups: value.resourceGroups,
      rootOrder: value.resourceRootOrder,
      assets: assets,
      folders: folders,
    );
    if (evictImageCache) {
      _evictFileImageCache(
        changedStoryboardAssetImagePaths(
          _assetFileSignatures,
          scanResult.fileSignatures,
        ),
      );
    }
    _assetFileSignatures = scanResult.fileSignatures;
    final validIds = {
      for (final asset in assets) asset.id,
      for (final folder in folders)
        for (final asset in folder.assets) asset.id,
    };
    final reconciliation = _reconcileBoardAssets(
      value.boards,
      assets,
      folders,
      validIds,
    );
    _setState(
      value.copyWith(
        assets: assets,
        folders: folders,
        resourceGroups: resourceTree.groups,
        resourceRootOrder: resourceTree.rootOrder,
        boards: reconciliation.boards,
        openBoardIds: _openBoardIdsAfterDeleting(
          reconciliation.deletedBoardIds,
        ),
        selectedBoardId: _selectedBoardIdAfterDeleting(
          reconciliation.deletedBoardIds,
        ),
        assetNormalizationRequired: normalization.total > 0,
        legacyAiEditedImageCount: normalization.aiEdited,
        legacyManualReplacementImageCount: normalization.manualReplacement,
        message:
            message ??
            _assetRefreshMessage(
              assets,
              folders,
              deleted,
              scanResult.cleanedEmptyDirectories,
            ),
      ),
    );
    _disposeDeletedBoards(reconciliation.deletedBoardIds);
  }

  List<StoryboardFolder> _foldersFromScan(
    List<_ScannedStoryboardFolder> scannedFolders,
  ) {
    return [
      for (final folder in scannedFolders)
        StoryboardFolder(
          id: folder.id,
          name: folder.name,
          path: folder.path,
          assets: [
            for (var index = 0; index < folder.files.length; index++)
              StoryboardCutAsset(
                id: 'folder:${folder.id}:${p.basename(folder.files[index])}',
                imageId: 'folder:${folder.id}',
                sourceName: folder.name,
                path: folder.files[index],
                indexNo: index + 1,
              ),
          ],
        ),
    ];
  }

  ({int aiEdited, int manualReplacement, int total})
  _detectLegacyAssetNormalization(List<CutResultRecord> records) {
    if (_database.getSetting(_assetNormalizationVersionKey) ==
        '$_assetNormalizationVersion') {
      return (aiEdited: 0, manualReplacement: 0, total: 0);
    }
    var aiEdited = 0;
    var manualReplacement = 0;
    for (final record in records) {
      final file = File(_toRuntimePath(record.path));
      if (!file.existsSync()) {
        continue;
      }
      if (_isAiEditedAssetId(record.id) &&
          (record.imageId != _aiEditedImagesImageId ||
              !_isAiEditedImageArchived(file))) {
        aiEdited++;
      } else if (_isManualReplacementAssetId(record.id) &&
          (record.imageId != _manualReplacementImageId ||
              !_isManualReplacementImageArchived(file))) {
        manualReplacement++;
      }
    }
    return (
      aiEdited: aiEdited,
      manualReplacement: manualReplacement,
      total: aiEdited + manualReplacement,
    );
  }

  bool _isAiEditedImageArchived(File file) {
    final directoryName = p.basename(file.parent.path);
    return directoryName != _aiEditedImagesDirectorySuffix &&
        directoryName.endsWith('-$_aiEditedImagesDirectorySuffix') &&
        RegExp(r'^\d+-.+-AI修改\.[^.]+$').hasMatch(p.basename(file.path));
  }

  bool _isManualReplacementImageArchived(File file) {
    return p
            .basename(file.parent.path)
            .endsWith('-$_manualReplacementDirectorySuffix') &&
        RegExp(r'^\d+-.+-手动替换\.[^.]+$').hasMatch(p.basename(file.path));
  }

  Future<bool> normalizeLegacyReplacementAssets() async {
    final directories = _directories;
    if (directories == null || value.isNormalizingAssets) {
      return false;
    }
    final initialRecords = _database.listCutResults();
    final pending = _detectLegacyAssetNormalization(initialRecords);
    if (pending.total == 0) {
      _database.setSetting(
        _assetNormalizationVersionKey,
        '$_assetNormalizationVersion',
      );
      value = value.copyWith(
        assetNormalizationRequired: false,
        legacyAiEditedImageCount: 0,
        legacyManualReplacementImageCount: 0,
      );
      return true;
    }

    value = value.copyWith(
      isNormalizingAssets: true,
      message: '正在归纳 AI 修改和手动替换图片，请勿关闭工程',
    );
    try {
      var records = initialRecords;
      await _migrateLegacyAiEditedImages(records);
      records = _database.listCutResults();
      await _migrateLegacyManualReplacementImages(records);
      await _reloadAssets(
        message:
            '图片归纳完成：AI 修改 ${pending.aiEdited} 张，手动替换 ${pending.manualReplacement} 张',
        evictImageCache: true,
        ensureLatest: true,
      );
      _database.setSetting(
        _assetNormalizationVersionKey,
        '$_assetNormalizationVersion',
      );
      value = value.copyWith(
        isNormalizingAssets: false,
        assetNormalizationRequired: false,
        legacyAiEditedImageCount: 0,
        legacyManualReplacementImageCount: 0,
        message:
            '图片归纳完成：AI 修改 ${pending.aiEdited} 张，手动替换 ${pending.manualReplacement} 张',
      );
      flushWorkspaceSnapshot();
      return true;
    } catch (error) {
      try {
        await _reloadAssets(
          message: '图片归纳未完成，可稍后重试：$error',
          evictImageCache: true,
          ensureLatest: true,
        );
      } catch (_) {
        // 保留原始错误，避免刷新异常覆盖归纳失败原因。
      }
      value = value.copyWith(
        isNormalizingAssets: false,
        assetNormalizationRequired: true,
        message: '图片归纳未完成，可稍后重试：$error',
      );
      return false;
    }
  }

  Future<bool> _migrateLegacyAiEditedImages(
    List<CutResultRecord> records,
  ) async {
    final directories = _directories;
    if (directories == null) {
      return false;
    }
    final generatedRecords = records
        .where((record) => _isAiEditedAssetId(record.id))
        .toList();
    if (generatedRecords.isEmpty) {
      return false;
    }

    final generationByAssetId = {
      for (final record in _database.listImageGenerationRecords())
        if (record.resultAssetId.isNotEmpty) record.resultAssetId: record,
    };
    generatedRecords.sort((first, second) {
      final firstCreated =
          generationByAssetId[first.id]?.createdAt ?? first.createdAt;
      final secondCreated =
          generationByAssetId[second.id]?.createdAt ?? second.createdAt;
      final byTime = firstCreated.compareTo(secondCreated);
      return byTime != 0 ? byTime : first.id.compareTo(second.id);
    });

    var sequence = 0;
    for (final record in generatedRecords) {
      final source = File(_toRuntimePath(record.path));
      if (!source.existsSync()) {
        continue;
      }
      if (_isAiEditedImageArchived(source)) {
        final parsed = int.tryParse(p.basename(source.path).split('-').first);
        sequence = math.max(sequence, parsed ?? record.indexNo);
      }
    }

    var changed = false;
    for (final record in generatedRecords) {
      final source = File(_toRuntimePath(record.path));
      if (!source.existsSync()) {
        continue;
      }
      final alreadyArchived = _isAiEditedImageArchived(source);
      var archivedFile = source;
      var archivedIndex = record.indexNo;
      if (!alreadyArchived) {
        sequence++;
        final boardName = _aiEditedImageBoardName(
          record.id,
          source,
          generationByAssetId[record.id]?.boardId,
        );
        final safeBoardName = _safeFileNamePart(boardName, fallback: '历史画板');
        final outputDirectory = _aiEditedImagesDirectory(
          directories,
          safeBoardName,
        );
        await outputDirectory.create(recursive: true);
        final extension = p.extension(source.path).toLowerCase();
        final safeExtension = _isSupportedImage(source.path)
            ? extension
            : '.png';
        var target = File(
          p.join(
            outputDirectory.path,
            '${sequence.toString().padLeft(3, '0')}-$safeBoardName-AI修改$safeExtension',
          ),
        );
        while (target.existsSync() && !_sameFilePath(source, target)) {
          sequence++;
          target = File(
            p.join(
              outputDirectory.path,
              '${sequence.toString().padLeft(3, '0')}-$safeBoardName-AI修改$safeExtension',
            ),
          );
        }

        try {
          archivedFile = await source.rename(target.path);
        } on FileSystemException {
          archivedFile = await source.copy(target.path);
          try {
            await source.delete();
          } on FileSystemException {
            // 复制成功即可完成兼容迁移，无法删除的旧文件留给用户手动处理。
          }
        }
        archivedIndex = sequence;
        _database.updateCutResultPathAndIndex(
          record.id,
          _toStoredPath(archivedFile.path),
          archivedIndex,
        );
        changed = true;
      } else {
        final parsed = int.tryParse(p.basename(source.path).split('-').first);
        if (parsed != null && parsed != record.indexNo) {
          archivedIndex = parsed;
          _database.updateCutResultPathAndIndex(
            record.id,
            _toStoredPath(source.path),
            archivedIndex,
          );
          changed = true;
        }
      }

      final storedPath = _toStoredPath(archivedFile.path);
      if (record.imageId != _aiEditedImagesImageId) {
        final previousImageId = record.imageId;
        _database
          ..upsertImportedImage(
            id: _aiEditedImagesImageId,
            originalPath: storedPath,
            originalName: _aiEditedImagesSourceName,
            storedPath: storedPath,
            width: record.width,
            height: record.height,
            createdAt: record.createdAt,
          )
          ..reassignCutResultImageSource(
            resultId: record.id,
            taskId: record.taskId,
            imageId: _aiEditedImagesImageId,
          )
          ..deleteImportedImageIfUnreferenced(previousImageId);
        changed = true;
      } else if (!alreadyArchived) {
        _database.updateImportedImageStoredPath(
          _aiEditedImagesImageId,
          storedPath,
        );
      }
      if (!alreadyArchived) {
        _database.updateImageGenerationResultPathByAssetId(
          record.id,
          storedPath,
        );
      }
    }
    if (changed) {
      const EmptyDirectoryCleaner().cleanChildren(directories.generatedImages);
    }
    return changed;
  }

  String _aiEditedImageBoardName(
    String assetId,
    File source,
    String? generationBoardId,
  ) {
    if (generationBoardId != null) {
      for (final board in value.boards) {
        if (board.id == generationBoardId) {
          return board.name;
        }
      }
    }
    for (final board in value.boards) {
      if (board.items.any((item) => item.asset.id == assetId)) {
        return board.name;
      }
    }
    final legacyParentName = p.basename(source.parent.path);
    for (final board in value.boards) {
      if (board.id == legacyParentName) {
        return board.name;
      }
    }
    final archivedName = RegExp(
      r'^\d+-(.+)-AI修改\.[^.]+$',
    ).firstMatch(p.basename(source.path));
    return archivedName?.group(1) ?? '历史画板';
  }

  Future<bool> _migrateLegacyManualReplacementImages(
    List<CutResultRecord> records,
  ) async {
    final directories = _directories;
    if (directories == null) {
      return false;
    }
    final replacementRecords =
        records
            .where((record) => _isManualReplacementAssetId(record.id))
            .toList()
          ..sort((first, second) {
            final byTime = first.createdAt.compareTo(second.createdAt);
            return byTime != 0 ? byTime : first.id.compareTo(second.id);
          });
    if (replacementRecords.isEmpty) {
      return false;
    }

    final archivedNamePattern = RegExp(r'^\d+-.+-手动替换\.[^.]+$');
    var sequence = 0;
    for (final record in replacementRecords) {
      final source = File(_toRuntimePath(record.path));
      if (!source.existsSync()) {
        continue;
      }
      final archivedDirectory = p.basename(source.parent.path);
      if (archivedDirectory.endsWith('-$_manualReplacementDirectorySuffix') &&
          archivedNamePattern.hasMatch(p.basename(source.path))) {
        final parsed = int.tryParse(p.basename(source.path).split('-').first);
        sequence = math.max(sequence, parsed ?? record.indexNo);
      }
    }

    var changed = false;
    for (final record in replacementRecords) {
      final source = File(_toRuntimePath(record.path));
      if (!source.existsSync()) {
        continue;
      }
      final archivedDirectory = p.basename(source.parent.path);
      final alreadyArchived =
          archivedDirectory.endsWith('-$_manualReplacementDirectorySuffix') &&
          archivedNamePattern.hasMatch(p.basename(source.path));
      var archivedFile = source;
      var archivedIndex = record.indexNo;
      if (!alreadyArchived) {
        sequence++;
        final boardName = _manualReplacementBoardName(record.id, source);
        final safeBoardName = _safeFileNamePart(boardName, fallback: '历史画板');
        final outputDirectory = _manualReplacementDirectory(
          directories,
          safeBoardName,
        );
        await outputDirectory.create(recursive: true);
        final extension = p.extension(source.path).toLowerCase();
        final safeExtension = _isSupportedImage(source.path)
            ? extension
            : '.png';
        var target = File(
          p.join(
            outputDirectory.path,
            '${sequence.toString().padLeft(3, '0')}-$safeBoardName-手动替换$safeExtension',
          ),
        );
        while (target.existsSync() && !_sameFilePath(source, target)) {
          sequence++;
          target = File(
            p.join(
              outputDirectory.path,
              '${sequence.toString().padLeft(3, '0')}-$safeBoardName-手动替换$safeExtension',
            ),
          );
        }

        try {
          archivedFile = await source.rename(target.path);
        } on FileSystemException {
          archivedFile = await source.copy(target.path);
          try {
            await source.delete();
          } on FileSystemException {
            // 复制成功即可完成兼容迁移，无法删除的旧文件留给用户手动处理。
          }
        }
        archivedIndex = sequence;
        _database.updateCutResultPathAndIndex(
          record.id,
          _toStoredPath(archivedFile.path),
          archivedIndex,
        );
        changed = true;
      } else {
        final parsed = int.tryParse(p.basename(source.path).split('-').first);
        if (parsed != null && parsed != record.indexNo) {
          archivedIndex = parsed;
          _database.updateCutResultPathAndIndex(
            record.id,
            _toStoredPath(source.path),
            archivedIndex,
          );
          changed = true;
        }
      }

      final storedPath = _toStoredPath(archivedFile.path);
      if (record.imageId != _manualReplacementImageId) {
        final previousImageId = record.imageId;
        _database
          ..upsertImportedImage(
            id: _manualReplacementImageId,
            originalPath: storedPath,
            originalName: _manualReplacementSourceName,
            storedPath: storedPath,
            width: record.width,
            height: record.height,
            createdAt: record.createdAt,
          )
          ..reassignCutResultImageSource(
            resultId: record.id,
            taskId: record.taskId,
            imageId: _manualReplacementImageId,
          )
          ..deleteImportedImageIfUnreferenced(previousImageId);
        changed = true;
      } else if (!alreadyArchived) {
        _database.updateImportedImageStoredPath(
          _manualReplacementImageId,
          storedPath,
        );
      }
    }
    if (changed) {
      const EmptyDirectoryCleaner().cleanChildren(directories.generatedImages);
    }
    return changed;
  }

  String _manualReplacementBoardName(String assetId, File source) {
    for (final board in value.boards) {
      if (board.items.any((item) => item.asset.id == assetId)) {
        return board.name;
      }
    }
    if (p.basename(source.parent.path) == 'manual_replacements') {
      final legacyBoardId = p.basename(source.parent.parent.path);
      for (final board in value.boards) {
        if (board.id == legacyBoardId) {
          return board.name;
        }
      }
    }
    return '历史画板';
  }

  Map<String, int> _aiEditedIndexByAssetId(List<CutResultRecord> records) {
    final generated =
        records.where((record) => _isAiEditedAssetId(record.id)).toList()
          ..sort((first, second) {
            final byIndex = first.indexNo.compareTo(second.indexNo);
            if (byIndex != 0) {
              return byIndex;
            }
            final byTime = first.createdAt.compareTo(second.createdAt);
            return byTime != 0 ? byTime : first.id.compareTo(second.id);
          });
    return {
      for (var index = 0; index < generated.length; index++)
        generated[index].id: index + 1,
    };
  }

  bool _isAiEditedAssetId(String assetId) =>
      assetId.startsWith('generated-cut-');

  Map<String, int> _manualReplacementIndexByAssetId(
    List<CutResultRecord> records,
  ) {
    final replacements =
        records
            .where((record) => _isManualReplacementAssetId(record.id))
            .toList()
          ..sort((first, second) {
            final byIndex = first.indexNo.compareTo(second.indexNo);
            if (byIndex != 0) {
              return byIndex;
            }
            final byTime = first.createdAt.compareTo(second.createdAt);
            return byTime != 0 ? byTime : first.id.compareTo(second.id);
          });
    return {
      for (var index = 0; index < replacements.length; index++)
        replacements[index].id: index + 1,
    };
  }

  bool _isManualReplacementAssetId(String assetId) =>
      assetId.startsWith('replacement-cut-');

  void _evictFileImageCache(Iterable<String> paths) {
    for (final path in paths) {
      if (path.trim().isEmpty) {
        continue;
      }
      unawaited(FileImage(File(path)).evict());
    }
  }

  void deleteAssetGroup(String imageId) {
    final assets = value.assets
        .where((asset) => asset.imageId == imageId)
        .toList();
    if (assets.isEmpty) {
      return;
    }

    final isExternalReference = imageId.startsWith('external-image:');
    var deletedFiles = 0;
    if (!isExternalReference) {
      for (final asset in assets) {
        final file = File(asset.path);
        if (file.existsSync()) {
          try {
            file.deleteSync();
            deletedFiles++;
          } on FileSystemException {
            // 数据库记录仍会删除，避免界面残留无法使用的资源。
          }
        }
      }
    }

    if (imageId == _aiEditedImagesImageId ||
        imageId == _manualReplacementImageId) {
      _database.deleteCutResultsByIds(assets.map((asset) => asset.id));
    } else {
      _database.deleteCutResultsForImage(imageId);
    }
    final cleanedEmptyDirectories = _cleanEmptyCutDirectories();
    final nextAssets = value.assets
        .where((asset) => asset.imageId != imageId)
        .toList();
    final resourceTree = _normalizeResourceTree(
      groups: value.resourceGroups,
      rootOrder: value.resourceRootOrder,
      assets: nextAssets,
      folders: value.folders,
    );
    final validIds = {
      for (final asset in nextAssets) asset.id,
      for (final folder in value.folders)
        for (final folderAsset in folder.assets) folderAsset.id,
    };
    final reconciliation = _reconcileBoardAssets(
      value.boards,
      nextAssets,
      value.folders,
      validIds,
    );
    _setState(
      value.copyWith(
        assets: nextAssets,
        resourceGroups: resourceTree.groups,
        resourceRootOrder: resourceTree.rootOrder,
        boards: reconciliation.boards,
        openBoardIds: _openBoardIdsAfterDeleting(
          reconciliation.deletedBoardIds,
        ),
        selectedBoardId: _selectedBoardIdAfterDeleting(
          reconciliation.deletedBoardIds,
        ),
        message: isExternalReference
            ? '已解除 ${assets.length} 个外部视频帧的故事板引用'
            : '已删除 ${assets.length} 张裁切资源，清理 $deletedFiles 个文件'
                  '${cleanedEmptyDirectories > 0 ? '，清理 $cleanedEmptyDirectories 个空文件夹' : ''}',
      ),
    );
    _disposeDeletedBoards(reconciliation.deletedBoardIds);
  }

  Future<void> deleteFolderAsset(StoryboardCutAsset asset) async {
    StoryboardFolder? matchedFolder;
    StoryboardCutAsset? matchedAsset;
    for (final folder in value.folders) {
      for (final folderAsset in folder.assets) {
        if (folderAsset.id == asset.id) {
          matchedFolder = folder;
          matchedAsset = folderAsset;
          break;
        }
      }
      if (matchedAsset != null) {
        break;
      }
    }

    if (matchedFolder == null || matchedAsset == null) {
      await _reloadAssets(message: '图片文件不存在，已刷新资源状态', ensureLatest: true);
      return;
    }

    final file = File(matchedAsset.path);
    if (!file.existsSync()) {
      await _reloadAssets(message: '图片文件不存在，已刷新资源状态', ensureLatest: true);
      return;
    }

    try {
      await file.delete();
    } on FileSystemException {
      value = value.copyWith(message: '删除图片失败，请确认文件未被占用');
      return;
    }

    await _reloadAssets(
      message: '已删除 ${matchedFolder.name} 中的图片',
      evictImageCache: true,
      ensureLatest: true,
    );
  }

  StoryboardBoard addBoard() {
    final index = value.boards.length + 1;
    final board = _newBoard(index);
    _setState(
      value.copyWith(
        boards: [...value.boards, board],
        openBoardIds: [...value.openBoardIds, board.id],
        selectedBoardId: board.id,
        message: '已创建 ${board.name}',
      ),
    );
    return board;
  }

  StoryboardBoard? duplicateSelectedBoard() {
    final board = value.selectedBoard;
    if (board == null) {
      return null;
    }
    final duplicate = board.copyWith(
      id: _uuid.v4(),
      name: _uniqueBoardName('${board.name} 副本'),
      locked: false,
      autoGeneratedSourceImageId: null,
    );
    _setState(
      value.copyWith(
        boards: [...value.boards, duplicate],
        openBoardIds: [...value.openBoardIds, duplicate.id],
        selectedBoardId: duplicate.id,
        message: '已复制 ${board.name}',
      ),
    );
    return duplicate;
  }

  bool syncFromShootingScript({
    required String boardId,
    required List<ScriptShot> shots,
  }) {
    final board = value.boards.cast<StoryboardBoard?>().firstWhere(
      (item) => item?.id == boardId,
      orElse: () => null,
    );
    if (board == null) {
      return false;
    }
    final itemByAssetId = {for (final item in board.items) item.asset.id: item};
    final synchronizedItems = <StoryboardItem>[];
    final orderedShots = shots.toList()
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    for (final shot in orderedShots) {
      final assetId = shot.sourceStoryboardAssetId;
      final item = assetId == null ? null : itemByAssetId[assetId];
      if (item == null) {
        continue;
      }
      final asset = shot.framePath == item.asset.path
          ? item.asset
          : StoryboardCutAsset(
              id: item.asset.id,
              imageId: item.asset.imageId,
              sourceName: item.asset.sourceName,
              path: shot.framePath,
              indexNo: item.asset.indexNo,
            );
      synchronizedItems.add(
        item.copyWith(
          asset: asset,
          caption: shot.content,
          slotIndex: synchronizedItems.length,
        ),
      );
    }
    final hasChanges =
        board.items.length != synchronizedItems.length ||
        board.items.any((item) {
          final next = synchronizedItems.cast<StoryboardItem?>().firstWhere(
            (candidate) => candidate?.asset.id == item.asset.id,
            orElse: () => null,
          );
          return next == null ||
              next.slotIndex != item.slotIndex ||
              next.caption != item.caption ||
              next.asset.path != item.asset.path;
        });
    if (!hasChanges) {
      return false;
    }
    _replaceBoard(
      _boardWithGridForItemCount(
        board.copyWith(items: synchronizedItems),
        itemCount: synchronizedItems.length,
      ),
      message: '',
      selectBoard: false,
    );
    return true;
  }

  Future<String?> createOrReplaceBoardFromExternalImages({
    required String sourceId,
    required String boardName,
    required List<StoryboardExternalImage> images,
    StoryboardSummary? summary,
    bool selectBoard = true,
    bool preserveExistingCaptions = false,
  }) async {
    final normalizedSourceId = sourceId.trim();
    final normalizedBoardName = boardName.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (normalizedSourceId.isEmpty || normalizedBoardName.isEmpty) {
      value = value.copyWith(message: '故事板来源和名称不能为空');
      return null;
    }
    if (images.isEmpty) {
      value = value.copyWith(message: '没有可生成故事板的焦点帧');
      return null;
    }
    if (images.length > _maxSlotCount) {
      value = value.copyWith(message: '单个故事板最多支持 $_maxSlotCount 个镜头，请减少焦点帧后重试');
      return null;
    }

    final validImages = <StoryboardExternalImage>[];
    final stableIds = <String>{};
    for (final image in images) {
      final stableId = image.stableId.trim();
      final file = File(image.path);
      if (stableId.isEmpty ||
          !stableIds.add(stableId) ||
          !file.existsSync() ||
          !_isSupportedImage(file.path) ||
          image.width <= 0 ||
          image.height <= 0) {
        continue;
      }
      validImages.add(image);
    }
    if (validImages.isEmpty) {
      value = value.copyWith(message: '焦点帧文件不存在或格式无效，未生成故事板');
      return null;
    }
    if (validImages.length != images.length) {
      value = value.copyWith(message: '部分焦点帧文件无效，请修复后重试');
      return null;
    }

    final boardId = 'external-board:$normalizedSourceId';
    final existingBoard = value.boards.cast<StoryboardBoard?>().firstWhere(
      (board) => board?.id == boardId,
      orElse: () => null,
    );
    if (existingBoard?.locked == true) {
      value = value.copyWith(message: '${existingBoard!.name} 已锁定，请先解锁后再更新');
      return null;
    }

    final imageId = 'external-image:$normalizedSourceId';
    final taskId = 'external-task:$normalizedSourceId';
    final now = DateTime.now().toIso8601String();
    final first = validImages.first;
    final firstStoredPath = _toStoredPath(first.path);
    _database
      ..upsertImportedImage(
        id: imageId,
        originalPath: firstStoredPath,
        originalName: first.sourceName,
        storedPath: firstStoredPath,
        width: first.width,
        height: first.height,
        createdAt: now,
      )
      ..upsertCutTask(
        id: taskId,
        imageId: imageId,
        status: 'external-storyboard',
        rows: 1,
        columns: validImages.length,
        confidence: 1,
      )
      ..deleteCutResultsForTask(taskId);
    for (var index = 0; index < validImages.length; index++) {
      final image = validImages[index];
      _database.insertCutResult(
        id: 'external-cut:${image.stableId}',
        taskId: taskId,
        imageId: imageId,
        indexNo: index + 1,
        path: _toStoredPath(image.path),
        x: 0,
        y: 0,
        width: image.width,
        height: image.height,
        selected: true,
      );
    }

    await _reloadAssets(
      message: '正在生成 $normalizedBoardName',
      ensureLatest: true,
    );
    final assetsById = {for (final asset in value.assets) asset.id: asset};
    final existingCaptionsByAssetId = {
      for (final item in existingBoard?.items ?? const <StoryboardItem>[])
        item.asset.id: item.caption,
    };
    final items = <StoryboardItem>[];
    for (var index = 0; index < validImages.length; index++) {
      final image = validImages[index];
      final asset = assetsById['external-cut:${image.stableId}'];
      if (asset == null) {
        value = value.copyWith(message: '焦点帧资源注册失败，请重试');
        return null;
      }
      items.add(
        StoryboardItem(
          asset: asset,
          caption: _mergedExternalCaption(
            incoming: image.caption,
            existing: existingCaptionsByAssetId[asset.id],
            preserveExisting: preserveExistingCaptions,
          ),
          slotIndex: index,
        ),
      );
    }

    final baseBoard =
        existingBoard ??
        StoryboardBoard(
          id: boardId,
          name: normalizedBoardName,
          width: 1920,
          height: StoryboardBoard.heightForLayout(
            width: 1920,
            rows: 3,
            columns: 3,
            imageAspectRatio: projectImageAspectRatio,
          ),
          rows: 3,
          columns: 3,
          gap: 18,
          items: const [],
          rowCaptions: const ['', '', ''],
          imageAspectRatio: projectImageAspectRatio,
          autoGeneratedSourceImageId: imageId,
        );
    final nextBoard = _boardWithAdaptiveHeight(
      _boardWithGridForItemCount(
        baseBoard.copyWith(
          name: normalizedBoardName,
          items: items,
          autoGeneratedSourceImageId: imageId,
          summary: summary,
          clearSummary: summary == null,
        ),
        itemCount: items.length,
      ),
    );
    final alreadyExists = existingBoard != null;
    final nextBoards = [
      for (final board in value.boards)
        if (board.id == boardId) nextBoard else board,
      if (!alreadyExists) nextBoard,
    ];
    final nextOpenBoardIds = value.openBoardIds.contains(boardId)
        ? value.openBoardIds
        : [...value.openBoardIds, boardId];
    _setState(
      value.copyWith(
        boards: nextBoards,
        openBoardIds: nextOpenBoardIds,
        selectedBoardId: selectBoard ? boardId : value.selectedBoardId,
        message: alreadyExists
            ? '已更新 $normalizedBoardName，共 ${items.length} 个镜头'
            : '已生成 $normalizedBoardName，共 ${items.length} 个镜头',
      ),
    );
    flushWorkspaceSnapshot();
    return boardId;
  }

  static String _mergedExternalCaption({
    required String incoming,
    required String? existing,
    required bool preserveExisting,
  }) {
    final current = existing?.trim() ?? '';
    if (preserveExisting && current.isNotEmpty && current != '视频解析镜头') {
      return current;
    }
    return incoming.trim();
  }

  void closeBoard(String boardId) {
    final index = value.openBoardIds.indexOf(boardId);
    if (index < 0) {
      return;
    }
    final nextOpenBoardIds = [
      for (final id in value.openBoardIds)
        if (id != boardId) id,
    ];
    var selectedBoardId = value.selectedBoardId;
    if (selectedBoardId == boardId) {
      selectedBoardId = nextOpenBoardIds.isEmpty
          ? null
          : nextOpenBoardIds[index
                .clamp(0, nextOpenBoardIds.length - 1)
                .toInt()];
    }
    final board = value.boards.cast<StoryboardBoard?>().firstWhere(
      (item) => item?.id == boardId,
      orElse: () => null,
    );
    _setState(
      value.copyWith(
        openBoardIds: nextOpenBoardIds,
        selectedBoardId: selectedBoardId,
        message: board == null ? value.message : '已关闭 ${board.name} 的页签',
      ),
    );
  }

  void closeSelectedBoard() {
    final boardId = value.selectedBoardId;
    if (boardId != null) {
      closeBoard(boardId);
    }
  }

  void openBoard(String boardId) {
    final board = value.boards.cast<StoryboardBoard?>().firstWhere(
      (item) => item?.id == boardId,
      orElse: () => null,
    );
    if (board == null) {
      return;
    }
    final nextOpenBoardIds = value.openBoardIds.contains(boardId)
        ? value.openBoardIds
        : [...value.openBoardIds, boardId];
    _setState(
      value.copyWith(
        openBoardIds: nextOpenBoardIds,
        selectedBoardId: boardId,
        message: '已打开 ${board.name}',
      ),
    );
  }

  String? createBoardGroup(String name) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      value = value.copyWith(message: '编组名称不能为空');
      return null;
    }
    if (_boardGroupNameExists(normalizedName)) {
      value = value.copyWith(message: '已存在同名画板编组');
      return null;
    }
    final group = StoryboardBoardGroup(id: _uuid.v4(), name: normalizedName);
    _setState(
      value.copyWith(
        boardGroups: [...value.boardGroups, group],
        message: '已创建画板编组 ${group.name}',
      ),
    );
    return group.id;
  }

  void renameBoardGroup(String groupId, String name) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      value = value.copyWith(message: '编组名称不能为空');
      return;
    }
    final index = value.boardGroups.indexWhere((group) => group.id == groupId);
    if (index < 0) {
      return;
    }
    if (_boardGroupNameExists(normalizedName, excludingId: groupId)) {
      value = value.copyWith(message: '已存在同名画板编组');
      return;
    }
    final previous = value.boardGroups[index];
    _setState(
      value.copyWith(
        boardGroups: [
          for (final group in value.boardGroups)
            if (group.id == groupId)
              group.copyWith(name: normalizedName)
            else
              group,
        ],
        message: '已将 ${previous.name} 重命名为 $normalizedName',
      ),
    );
  }

  void deleteBoardGroup(String groupId) {
    final group = value.boardGroups.cast<StoryboardBoardGroup?>().firstWhere(
      (item) => item?.id == groupId,
      orElse: () => null,
    );
    if (group == null) {
      return;
    }
    _setState(
      value.copyWith(
        boardGroups: [
          for (final item in value.boardGroups)
            if (item.id != groupId) item,
        ],
        boards: [
          for (final board in value.boards)
            if (board.groupId == groupId)
              board.copyWith(groupId: null)
            else
              board,
        ],
        message: '已删除编组 ${group.name}，画板已移至未编组',
      ),
    );
  }

  void assignBoardsToGroup(Iterable<String> boardIds, String? groupId) {
    final ids = boardIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    if (groupId != null &&
        !value.boardGroups.any((group) => group.id == groupId)) {
      value = value.copyWith(message: '目标画板编组不存在');
      return;
    }
    _setState(
      value.copyWith(
        boards: [
          for (final board in value.boards)
            if (ids.contains(board.id))
              board.copyWith(groupId: groupId)
            else
              board,
        ],
        message: groupId == null
            ? '已将 ${ids.length} 个画板移出编组'
            : '已移动 ${ids.length} 个画板到编组',
      ),
    );
  }

  bool _boardGroupNameExists(String name, {String? excludingId}) {
    final normalized = name.trim().toLowerCase();
    return value.boardGroups.any(
      (group) =>
          group.id != excludingId &&
          group.name.trim().toLowerCase() == normalized,
    );
  }

  void deleteBoard(String boardId) {
    final index = value.boards.indexWhere((board) => board.id == boardId);
    if (index < 0) {
      return;
    }
    final deletedBoard = value.boards[index];
    if (_guardLockedBoard(deletedBoard, '删除画板')) {
      return;
    }
    _undoHistoryByBoardId.remove(boardId);
    _redoHistoryByBoardId.remove(boardId);
    _database.deleteVisionAnalysisForBoard(boardId);
    final nextBoards = [
      for (final board in value.boards)
        if (board.id != boardId) board,
    ];
    final deletedOpenIndex = value.openBoardIds.indexOf(boardId);
    final nextOpenBoardIds = [
      for (final id in value.openBoardIds)
        if (id != boardId) id,
    ];
    String? selectedBoardId = value.selectedBoardId;
    if (selectedBoardId == boardId ||
        (selectedBoardId != null &&
            !nextOpenBoardIds.contains(selectedBoardId))) {
      selectedBoardId = nextOpenBoardIds.isEmpty
          ? null
          : nextOpenBoardIds[deletedOpenIndex
                .clamp(0, nextOpenBoardIds.length - 1)
                .toInt()];
    }
    _setState(
      value.copyWith(
        boards: nextBoards,
        openBoardIds: nextOpenBoardIds,
        selectedBoardId: selectedBoardId,
        message: '已删除 ${deletedBoard.name}',
      ),
    );
  }

  void selectBoard(String boardId) {
    if (!value.openBoardIds.contains(boardId)) {
      return;
    }
    _setState(value.copyWith(selectedBoardId: boardId), saveWorkspace: false);
  }

  void selectNextOpenBoard() {
    final openBoardIds = value.openBoardIds;
    if (openBoardIds.length < 2) {
      return;
    }
    final currentIndex = openBoardIds.indexOf(value.selectedBoardId ?? '');
    final nextIndex = currentIndex < 0
        ? 0
        : (currentIndex + 1) % openBoardIds.length;
    selectBoard(openBoardIds[nextIndex]);
  }

  bool get canUndoSelectedBoard {
    final boardId = value.selectedBoardId;
    return boardId != null &&
        (_undoHistoryByBoardId[boardId]?.isNotEmpty ?? false);
  }

  bool get canRedoSelectedBoard {
    final boardId = value.selectedBoardId;
    return boardId != null &&
        (_redoHistoryByBoardId[boardId]?.isNotEmpty ?? false);
  }

  void undoSelectedBoard() {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    final undoHistory = _undoHistoryByBoardId[board.id];
    if (undoHistory == null || undoHistory.isEmpty) {
      value = value.copyWith(message: '没有可撤销的操作');
      return;
    }
    final previousBoard = undoHistory.removeLast();
    _pushBoardHistory(_redoHistoryByBoardId, board);
    _restoreBoardFromHistory(previousBoard, message: '已撤销上一步操作');
  }

  void redoSelectedBoard() {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    final redoHistory = _redoHistoryByBoardId[board.id];
    if (redoHistory == null || redoHistory.isEmpty) {
      value = value.copyWith(message: '没有可恢复的操作');
      return;
    }
    final nextBoard = redoHistory.removeLast();
    _pushBoardHistory(_undoHistoryByBoardId, board);
    _restoreBoardFromHistory(nextBoard, message: '已恢复下一步操作');
  }

  void toggleSelectedBoardLock() {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    final locked = !board.locked;
    _replaceBoard(
      board.copyWith(locked: locked),
      message: locked ? '${board.name} 已锁定' : '${board.name} 已解锁',
    );
  }

  bool _guardLockedBoard(StoryboardBoard board, String action) {
    if (!board.locked) {
      return false;
    }
    value = value.copyWith(message: '${board.name} 已锁定，请先解锁后再$action');
    return true;
  }

  void renameSelectedBoard(String name) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '重命名画板')) {
      return;
    }
    final nextName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (nextName.isEmpty) {
      value = value.copyWith(message: '画板名称不能为空');
      return;
    }
    if (nextName == board.name) {
      return;
    }
    _replaceBoard(board.copyWith(name: nextName), message: '已重命名为 $nextName');
  }

  void clearSelectedBoard() {
    if (value.isAnalyzing) {
      value = value.copyWith(message: '正在解析故事板，暂不能清空当前画板');
      return;
    }
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '清空画板')) {
      return;
    }
    _replaceBoard(
      _boardWithAdaptiveHeight(
        board.copyWith(
          items: const [],
          rowCaptions: _emptyRowCaptions(board.rows),
          clearSummary: true,
        ),
      ),
      message: '已清空 ${board.name}',
    );
  }

  void addOrRemoveAsset(StoryboardCutAsset asset) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '添加或移除图片')) {
      return;
    }
    final exists = board.items.any((item) => item.asset.id == asset.id);
    if (exists) {
      removeAsset(asset.id);
      return;
    }
    final compactBoard = _compactBoardItems(board);
    final nextSlotIndex = compactBoard.visibleItemCount;
    if (nextSlotIndex >= _maxSlotCount) {
      value = value.copyWith(message: '当前画板宫格已达上限');
      return;
    }
    final nextItems = [
      ...compactBoard.items,
      StoryboardItem(asset: asset, caption: '', slotIndex: nextSlotIndex),
    ];
    final nextBoard = _boardWithGridForItemCount(
      compactBoard.copyWith(items: nextItems),
      itemCount: nextItems.length,
    );
    _replaceBoard(
      nextBoard,
      message: '已添加 ${asset.sourceName}${asset.indexNo}',
    );
  }

  void placeAssetAtSlot(StoryboardCutAsset asset, int slotIndex) {
    final board = value.selectedBoard;
    if (board == null || slotIndex < 0 || slotIndex >= board.slotCount) {
      return;
    }
    if (_guardLockedBoard(board, '放入图片')) {
      return;
    }
    final compactBoard = _compactBoardItems(board);
    StoryboardItem? existingItem;
    for (final item in compactBoard.items) {
      if (item.asset.id == asset.id) {
        existingItem = item;
        break;
      }
    }
    if (existingItem != null) {
      moveItem(existingItem.slotIndex, slotIndex);
      return;
    }
    final items = [...compactBoard.items]
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    if (items.length >= _maxSlotCount) {
      value = value.copyWith(message: '当前画板宫格已达上限');
      return;
    }
    final target = slotIndex.clamp(0, compactBoard.slotCount - 1).toInt();
    final insertIndex = target.clamp(0, items.length).toInt();
    items.insert(
      insertIndex,
      StoryboardItem(asset: asset, caption: '', slotIndex: insertIndex),
    );
    for (var i = 0; i < items.length; i++) {
      items[i] = items[i].copyWith(slotIndex: i);
    }
    final nextBoard = _boardWithGridForItemCount(
      compactBoard.copyWith(items: items),
      itemCount: items.length,
    );
    _replaceBoard(
      nextBoard,
      message: '已放入 ${asset.sourceName}${asset.indexNo}',
    );
  }

  Future<bool> replaceItemImage({
    required StoryboardItem item,
    required String imagePath,
  }) async {
    final board = value.selectedBoard;
    if (board == null) {
      return false;
    }
    if (_guardLockedBoard(board, '替换图片')) {
      return false;
    }
    final currentItem = board.itemAtSlot(item.slotIndex);
    if (currentItem == null || currentItem.asset.id != item.asset.id) {
      value = value.copyWith(message: '当前格内容已变化，请重新选择后替换');
      return false;
    }
    final directories = _directories;
    if (directories == null) {
      value = value.copyWith(message: '数据目录尚未初始化，无法替换图片');
      return false;
    }
    final source = File(imagePath);
    if (!source.existsSync() || !_isSupportedImage(source.path)) {
      value = value.copyWith(message: '请选择 PNG、JPG、WEBP 或 BMP 图片');
      return false;
    }
    final size = await _readImageSize(source);
    if (size.width <= 0 || size.height <= 0) {
      value = value.copyWith(message: '所选文件不是有效图片，未进行替换');
      return false;
    }

    try {
      final archivedReplacement = await _archiveManualReplacementImage(
        sourcePath: source.path,
        boardName: board.name,
      );
      final replacement = _registerReplacementImageAsset(
        originalPath: source.path,
        resultPath: archivedReplacement.path,
        sourceName: _manualReplacementSourceName,
        size: size,
        idPrefix: 'replacement',
        taskStatus: 'manual-replacement',
        sharedImageId: _manualReplacementImageId,
        indexNo: archivedReplacement.indexNo,
      );
      return _replaceCurrentItemAsset(
        boardId: board.id,
        slotIndex: item.slotIndex,
        oldAssetId: item.asset.id,
        replacement: replacement,
        successMessage: '已替换当前格图片，可撤回/重做（最多100步）',
        changedMessage: '当前格内容已变化，未进行替换',
      );
    } on FileSystemException {
      value = value.copyWith(message: '复制替换图片失败，请检查文件权限');
      return false;
    }
  }

  void setAssetsUsed(Iterable<StoryboardCutAsset> assets, bool used) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, used ? '批量添加图片' : '批量移除图片')) {
      return;
    }
    final selectedAssets = assets.toList();
    if (selectedAssets.isEmpty) {
      return;
    }
    if (used) {
      final compactBoard = _compactBoardItems(board);
      final usedIds = compactBoard.items.map((item) => item.asset.id).toSet();
      final nextItems = [...compactBoard.items];
      var added = 0;
      var skippedForFull = false;
      for (final asset in selectedAssets) {
        if (usedIds.add(asset.id)) {
          if (nextItems.length >= _maxSlotCount) {
            skippedForFull = true;
            break;
          }
          nextItems.add(
            StoryboardItem(
              asset: asset,
              caption: '',
              slotIndex: nextItems.length,
            ),
          );
          added++;
        }
      }
      final nextBoard = _boardWithGridForItemCount(
        compactBoard.copyWith(items: nextItems),
        itemCount: nextItems.length,
      );
      _replaceBoard(
        nextBoard,
        message: added == 0
            ? skippedForFull
                  ? '当前画板宫格已达上限'
                  : '所选图片已在画板中'
            : skippedForFull
            ? '已批量添加 $added 张图片，当前画板宫格已达上限'
            : '已批量添加 $added 张图片',
      );
      return;
    }

    final targetIds = selectedAssets.map((asset) => asset.id).toSet();
    final nextItems = board.items
        .where((item) => !targetIds.contains(item.asset.id))
        .toList();
    final removed = board.items.length - nextItems.length;
    final nextBoard = _boardWithGridForItemCount(
      board.copyWith(items: nextItems),
      itemCount: nextItems.length,
    );
    _replaceBoard(
      nextBoard,
      message: removed == 0 ? '所选图片未在画板中' : '已批量移除 $removed 张图片',
    );
  }

  void removeAsset(String assetId) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '移除图片')) {
      return;
    }
    if (!board.items.any((item) => item.asset.id == assetId)) {
      value = value.copyWith(message: '图片未在当前画板中');
      return;
    }
    final nextItems = board.items
        .where((item) => item.asset.id != assetId)
        .toList();
    final nextBoard = _boardWithGridForItemCount(
      board.copyWith(items: nextItems),
      itemCount: nextItems.length,
    );
    _replaceBoard(nextBoard, message: '已取消使用图片，可撤回恢复（最多100步）');
  }

  void moveItem(int from, int to) {
    final board = value.selectedBoard;
    if (board == null || from == to || from < 0 || from >= board.slotCount) {
      return;
    }
    if (_guardLockedBoard(board, '排序图片')) {
      return;
    }
    final compactBoard = _compactBoardItems(board);
    final items = [...compactBoard.items]
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    final draggedIndex = items.indexWhere((item) => item.slotIndex == from);
    if (draggedIndex < 0) {
      return;
    }
    final draggedItem = items.removeAt(draggedIndex);
    final target = to.clamp(0, compactBoard.slotCount - 1).toInt();
    final targetIndex = target.clamp(0, items.length).toInt();
    items.insert(targetIndex, draggedItem);
    for (var i = 0; i < items.length; i++) {
      items[i] = items[i].copyWith(slotIndex: i);
    }
    _replaceBoard(compactBoard.copyWith(items: items), saveWorkspace: false);
    _scheduleWorkspaceSnapshotSave();
  }

  void moveItems(Set<String> assetIds, int to) {
    final board = value.selectedBoard;
    if (board == null || assetIds.isEmpty) {
      return;
    }
    if (_guardLockedBoard(board, '排序图片')) {
      return;
    }
    final compactBoard = _compactBoardItems(board);
    final items = [...compactBoard.items]
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    final movingItems = [
      for (final item in items)
        if (assetIds.contains(item.asset.id)) item,
    ];
    if (movingItems.isEmpty) {
      return;
    }
    if (movingItems.length == 1) {
      moveItem(movingItems.single.slotIndex, to);
      return;
    }
    final remainingItems = [
      for (final item in items)
        if (!assetIds.contains(item.asset.id)) item,
    ];
    final target = to.clamp(0, compactBoard.slotCount - 1).toInt();
    final targetIndex = target.clamp(0, remainingItems.length).toInt();
    remainingItems.insertAll(targetIndex, movingItems);
    for (var i = 0; i < remainingItems.length; i++) {
      remainingItems[i] = remainingItems[i].copyWith(slotIndex: i);
    }
    _replaceBoard(
      compactBoard.copyWith(items: remainingItems),
      saveWorkspace: false,
    );
    _scheduleWorkspaceSnapshotSave();
  }

  void updateCaption(int index, String caption) {
    final board = value.selectedBoard;
    if (board == null || index < 0 || index >= board.slotCount) {
      return;
    }
    if (_guardLockedBoard(board, '编辑描述')) {
      return;
    }
    final items = [...board.items];
    final itemIndex = items.indexWhere((item) => item.slotIndex == index);
    if (itemIndex < 0) {
      return;
    }
    items[itemIndex] = items[itemIndex].copyWith(caption: caption);
    _replaceBoard(board.copyWith(items: items));
  }

  void toggleItemFlipHorizontal(int index) {
    final board = value.selectedBoard;
    if (board == null || index < 0 || index >= board.slotCount) {
      return;
    }
    if (_guardLockedBoard(board, '翻转图片')) {
      return;
    }
    final items = [...board.items];
    final itemIndex = items.indexWhere((item) => item.slotIndex == index);
    if (itemIndex < 0) {
      return;
    }
    final item = items[itemIndex];
    final flipped = !item.flipHorizontal;
    items[itemIndex] = item.copyWith(flipHorizontal: flipped);
    _replaceBoard(
      board.copyWith(items: items),
      message: flipped ? '已水平翻转图片' : '已恢复图片水平方向',
    );
  }

  void toggleItemFlipVertical(int index) {
    final board = value.selectedBoard;
    if (board == null || index < 0 || index >= board.slotCount) {
      return;
    }
    if (_guardLockedBoard(board, '翻转图片')) {
      return;
    }
    final items = [...board.items];
    final itemIndex = items.indexWhere((item) => item.slotIndex == index);
    if (itemIndex < 0) {
      return;
    }
    final item = items[itemIndex];
    final flipped = !item.flipVertical;
    items[itemIndex] = item.copyWith(flipVertical: flipped);
    _replaceBoard(
      board.copyWith(items: items),
      message: flipped ? '已垂直翻转图片' : '已恢复图片垂直方向',
    );
  }

  void updateRowCaption(int rowIndex, String caption) {
    final board = value.selectedBoard;
    if (board == null || rowIndex < 0 || rowIndex >= board.rows) {
      return;
    }
    if (_guardLockedBoard(board, '编辑描述')) {
      return;
    }
    final rowCaptions = _rowCaptionsForRows(board, board.rows);
    rowCaptions[rowIndex] = caption;
    _replaceBoard(board.copyWith(rowCaptions: rowCaptions));
  }

  void applyCaptionsByLines(String text) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '应用描述文本')) {
      return;
    }
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (board.rowDescriptionEnabled) {
      final rowCaptions = _rowCaptionsForRows(board, board.rows);
      for (var rowIndex = 0; rowIndex < board.rows; rowIndex++) {
        if (rowIndex >= lines.length) {
          break;
        }
        rowCaptions[rowIndex] = lines[rowIndex];
      }
      _replaceBoard(
        board.copyWith(rowCaptions: rowCaptions),
        message: '已按行应用描述文本',
      );
      return;
    }
    final items = [...board.items];
    var lineIndex = 0;
    for (var slotIndex = 0; slotIndex < board.slotCount; slotIndex++) {
      if (lineIndex >= lines.length) {
        break;
      }
      final itemIndex = items.indexWhere((item) => item.slotIndex == slotIndex);
      if (itemIndex < 0) {
        continue;
      }
      items[itemIndex] = items[itemIndex].copyWith(caption: lines[lineIndex]);
      lineIndex++;
    }
    _replaceBoard(board.copyWith(items: items), message: '已按行应用描述文本');
  }

  /// 应用外部审阅入口提交的文字修改，不改变桌面端当前选中的画板。
  bool updateBoardReviewFields({
    required String boardId,
    String? name,
    Map<String, String> itemCaptionsByAssetId = const {},
    List<String>? rowCaptions,
    StoryboardSummary? summary,
    bool clearSummary = false,
  }) {
    final board = value.boards.cast<StoryboardBoard?>().firstWhere(
      (item) => item?.id == boardId,
      orElse: () => null,
    );
    if (board == null || board.locked) {
      return false;
    }
    final normalizedName = name?.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedName != null && normalizedName.isEmpty) {
      return false;
    }
    final nextItems = [
      for (final item in board.items)
        itemCaptionsByAssetId.containsKey(item.asset.id)
            ? item.copyWith(caption: itemCaptionsByAssetId[item.asset.id])
            : item,
    ];
    final nextRowCaptions = rowCaptions == null
        ? board.rowCaptions
        : [
            for (var rowIndex = 0; rowIndex < board.rows; rowIndex++)
              rowIndex < rowCaptions.length ? rowCaptions[rowIndex] : '',
          ];
    final nextBoard = board.copyWith(
      name: normalizedName,
      items: nextItems,
      rowCaptions: nextRowCaptions,
      summary: summary,
      clearSummary: clearSummary,
    );
    if (_sameBoardSnapshot(board, nextBoard)) {
      return false;
    }
    _replaceBoard(nextBoard, message: '已同步远程故事板审阅修改', selectBoard: false);
    flushWorkspaceSnapshot();
    return true;
  }

  Future<VisionImageEditSuggestion> suggestImageEditPromptForItem(
    StoryboardItem item,
  ) async {
    final settingsController = _settingsController;
    if (settingsController == null) {
      throw StateError('视觉模型设置尚未初始化');
    }
    if (value.isAnalyzing) {
      throw StateError('正在解析故事板，请稍后再生成自动提示词');
    }
    final board = value.selectedBoard;
    if (board == null) {
      throw StateError('请先创建故事板');
    }
    if (board.locked) {
      final message = '${board.name} 已锁定，请先解锁后再生成自动提示词';
      _setBoardTaskMessage(board.id, message);
      throw StateError(message);
    }
    final orderedItems = _orderedVisibleItems(board);
    final itemIndex = orderedItems.indexWhere(
      (candidate) =>
          candidate.asset.id == item.asset.id &&
          candidate.slotIndex == item.slotIndex,
    );
    if (itemIndex < 0) {
      throw StateError('当前图片已不在画板中');
    }
    final currentItem = orderedItems[itemIndex];
    final imageFile = File(currentItem.asset.path);
    if (!imageFile.existsSync()) {
      throw const FileSystemException('当前图片文件不存在');
    }

    final operationToken = _beginVisionOperation(board.id);
    final batch = await _visionPromptBatchForCurrentBoard(
      board: board,
      orderedItems: orderedItems,
      operationToken: operationToken,
    );
    if (_isVisionOperationCancelled(operationToken)) {
      throw StateError('已取消自动提示词生成');
    }
    if (batch == null) {
      throw StateError('自动提示词前解析失败，请检查视觉模型配置后重试');
    }

    final currentBoard = value.selectedBoard;
    if (currentBoard == null || currentBoard.id != board.id) {
      throw StateError('当前画板已切换，请重新生成自动提示词');
    }
    final currentOrderedItems = _orderedVisibleItems(currentBoard);
    final currentItemIndex = currentOrderedItems.indexWhere(
      (candidate) => candidate.asset.id == item.asset.id,
    );
    if (currentItemIndex < 0) {
      throw StateError('当前图片已不在画板中');
    }
    final refreshedItem = currentOrderedItems[currentItemIndex];
    final rowIndex = refreshedItem.slotIndex ~/ currentBoard.columns;
    final columnIndex = refreshedItem.slotIndex % currentBoard.columns;
    final recordItems = _visionRecordItemsInCurrentOrder(
      currentOrderedItems,
      batch.items,
    );
    if (recordItems.length != currentOrderedItems.length) {
      throw StateError('解析结果未完整覆盖当前画板图片');
    }
    final analyses = recordItems.map((item) => item.analysis).toList();
    final summary = _summaryForPrompt(currentBoard, analyses);
    final storyboardSummary = _storyboardSummaryText(summary);

    _setBoardTaskMessage(board.id, '正在综合故事板解析生成自动提示词...');
    try {
      final suggestion = await _visionService.suggestImageEditPrompt(
        settings: settingsController.value,
        imageFile: imageFile,
        sequenceNo: currentItemIndex + 1,
        rowIndex: rowIndex,
        columnIndex: columnIndex,
        currentCaption: refreshedItem.caption,
        previousCaption: currentItemIndex > 0
            ? currentOrderedItems[currentItemIndex - 1].caption
            : '',
        nextCaption: currentItemIndex + 1 < currentOrderedItems.length
            ? currentOrderedItems[currentItemIndex + 1].caption
            : '',
        rowCaption: currentBoard.rowCaptionAt(rowIndex),
        storyboardSummary: storyboardSummary,
        currentAnalysis: analyses[currentItemIndex],
        previousAnalysis: currentItemIndex > 0
            ? analyses[currentItemIndex - 1]
            : null,
        nextAnalysis: currentItemIndex + 1 < analyses.length
            ? analyses[currentItemIndex + 1]
            : null,
        storyboardAnalyses: analyses,
      );
      _setBoardTaskMessage(board.id, '已生成当前分镜修改建议');
      return suggestion;
    } catch (error) {
      _setBoardTaskMessage(board.id, '自动提示词失败：$error');
      rethrow;
    }
  }

  bool enqueueReplacementForItem({
    required StoryboardItem item,
    required String prompt,
    required String model,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    required List<String> extraReferenceImagePaths,
  }) {
    final task = _prepareImageReplacementTask(
      item: item,
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      imageSize: imageSize,
      quality: quality,
      extraReferenceImagePaths: extraReferenceImagePaths,
    );
    if (task == null) {
      return false;
    }
    unawaited(_runImageReplacementTask(task));
    return true;
  }

  Future<bool> generateReplacementForItem({
    required StoryboardItem item,
    required String prompt,
    required String model,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    required List<String> extraReferenceImagePaths,
  }) {
    final task = _prepareImageReplacementTask(
      item: item,
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      imageSize: imageSize,
      quality: quality,
      extraReferenceImagePaths: extraReferenceImagePaths,
    );
    return task == null
        ? Future<bool>.value(false)
        : _runImageReplacementTask(task);
  }

  _PreparedImageReplacementTask? _prepareImageReplacementTask({
    required StoryboardItem item,
    required String prompt,
    required String model,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    required List<String> extraReferenceImagePaths,
    String? successMessage,
    String? changedMessage,
  }) {
    final directories = _directories;
    if (directories == null) {
      value = value.copyWith(message: '数据目录尚未初始化，无法生成图片');
      return null;
    }
    final settingsController = _settingsController;
    if (settingsController == null) {
      value = value.copyWith(message: '图片生成设置尚未初始化');
      return null;
    }
    final board = value.selectedBoard;
    if (board == null) {
      value = value.copyWith(message: '请先创建故事板');
      return null;
    }
    if (_guardLockedBoard(board, '修改图片')) {
      return null;
    }
    final currentItem = board.itemAtSlot(item.slotIndex);
    if (currentItem == null || currentItem.asset.id != item.asset.id) {
      value = value.copyWith(message: '当前图片已变化，请重新选择后再修改');
      return null;
    }
    final source = File(currentItem.asset.path);
    if (!source.existsSync()) {
      value = value.copyWith(message: '当前图片文件不存在，无法作为参考图');
      return null;
    }
    if (prompt.trim().isEmpty) {
      value = value.copyWith(message: '请先输入修改提示词');
      return null;
    }

    final references = [
      source.path,
      for (final path in extraReferenceImagePaths)
        if (path.trim().isNotEmpty) path.trim(),
    ];
    final effectiveAspectRatio = aspectRatio.trim().toLowerCase() == 'auto'
        ? projectAspectRatioLabel
        : aspectRatio;
    final generationId = _uuid.v4();
    _database.insertImageGenerationRecord(
      id: generationId,
      boardId: board.id,
      slotIndex: currentItem.slotIndex,
      sourceAssetId: currentItem.asset.id,
      sourcePath: _toStoredPath(currentItem.asset.path),
      model: model,
      prompt: prompt,
      aspectRatio: effectiveAspectRatio,
      imageSize: imageSize,
      quality: quality,
      referencePathsJson: jsonEncode([
        for (final path in references) _toStoredPath(path),
      ]),
      status: 'running',
    );
    final activeCount =
        (_activeImageGenerationCountByBoardId[board.id] ?? 0) + 1;
    _activeImageGenerationCountByBoardId[board.id] = activeCount;
    _syncVisionTaskState(
      boardId: board.id,
      message: activeCount == 1
          ? '已提交后台图片修改任务'
          : '已提交后台图片修改任务（$activeCount 个进行中）',
    );
    return _PreparedImageReplacementTask(
      generationId: generationId,
      boardId: board.id,
      boardName: board.name,
      slotIndex: currentItem.slotIndex,
      sourceAsset: currentItem.asset,
      model: model,
      prompt: prompt,
      aspectRatio: effectiveAspectRatio,
      imageSize: imageSize,
      quality: quality,
      referenceImagePaths: references,
      successMessage: successMessage ?? '图片修改完成，已替换当前格',
      changedMessage: changedMessage ?? '图片已生成，但当前格内容已变化，未自动替换',
    );
  }

  bool enqueueHighDefinitionRedrawForSelectedBoard() {
    final board = value.selectedBoard;
    if (board == null) {
      value = value.copyWith(message: '请先创建故事板');
      return false;
    }
    if (_guardLockedBoard(board, '高清重绘')) {
      return false;
    }
    final items = _orderedVisibleItems(board);
    if (items.isEmpty) {
      value = value.copyWith(message: '当前画板没有可高清重绘的图片');
      return false;
    }
    final descriptor = ImageGenerationModelCatalog.descriptorFor(
      highDefinitionRedrawModel,
    );
    if (descriptor == null) {
      value = value.copyWith(message: '高清重绘模型未配置');
      return false;
    }

    final existingItems = <StoryboardItem>[];
    var missingCount = 0;
    for (final item in items) {
      if (File(item.asset.path).existsSync()) {
        existingItems.add(item);
      } else {
        missingCount++;
      }
    }
    if (existingItems.isEmpty) {
      value = value.copyWith(message: '当前画板图片文件不存在，无法高清重绘');
      return false;
    }

    final tasks = <_PreparedImageReplacementTask>[];
    for (var index = 0; index < existingItems.length; index++) {
      final item = existingItems[index];
      final task = _prepareImageReplacementTask(
        item: item,
        prompt: _highDefinitionRedrawPrompt(
          board: board,
          item: item,
          sequenceNo: index + 1,
        ),
        model: highDefinitionRedrawModel,
        aspectRatio: projectAspectRatioLabel,
        imageSize: highDefinitionRedrawImageSize,
        quality: 'auto',
        extraReferenceImagePaths: const [],
        successMessage: '高清重绘完成，已替换当前格',
        changedMessage: '图片已高清重绘，但当前格内容已变化，未自动替换',
      );
      if (task != null) {
        tasks.add(task);
      }
    }
    if (tasks.isEmpty) {
      return false;
    }

    for (final task in tasks) {
      unawaited(_runImageReplacementTask(task));
    }
    _syncVisionTaskState(
      boardId: board.id,
      message:
          '已并发提交 ${tasks.length} 张高清重绘任务'
          '${missingCount > 0 ? '，跳过 $missingCount 张缺失图片' : ''}',
    );
    return true;
  }

  String _highDefinitionRedrawPrompt({
    required StoryboardBoard board,
    required StoryboardItem item,
    required int sequenceNo,
  }) {
    final rowIndex = item.slotIndex ~/ board.columns;
    final columnIndex = item.slotIndex % board.columns;
    final parts = [
      '这是高清重绘的图像超分辨率修复任务，不是重新创作。请先分析参考图，再以参考图为唯一视觉依据，修复当前故事板第 $sequenceNo 张分镜。',
      '在不改变原图内容的前提下，恢复原图中已有但因低清、压缩、噪点或运动模糊而损失的真实细节；保持原图的媒介、画风、色彩逻辑和真实质感，不把插画或概念图改成另一种风格。',
      '必须保持完全一致：画面裁切、景别、镜头角度、透视、主体位置、人物身份与脸部特征、姿态与表情、服装和配饰、道具、背景空间关系、光源方向、阴影、色温、曝光和故事连续性。',
      '只补回参考图有视觉证据支持的细节：自然的边缘、发丝、皮肤与毛发纹理、布料和材质纹理、建筑与环境细节、真实光影层次；细节应与原有焦点、景深和颗粒感一致。',
      '严格禁止：新增或删除人物、道具、文字、标识和背景元素；改变构图、动作、表情、年龄、身份、服装颜色或镜头语言；臆造看不见的内容；过度锐化、光晕、塑料皮肤、蜡像感、重复纹理、伪影和不自然的 HDR。原图文字、标识、图案若存在，按原样保留，不重写。',
      '输出一张适合故事板演示的真实高清 $projectAspectRatioLabel 4K 图像，画面干净、边缘自然、纹理清晰，但不要添加任何新的创意元素或水印。',
      '格位：第 ${rowIndex + 1} 行，第 ${columnIndex + 1} 列。',
    ];
    final caption = item.caption.trim();
    if (caption.isNotEmpty) {
      parts.add('辅助理解（不得覆盖参考图视觉证据）- 当前分镜描述：$caption');
    }
    final rowCaption = board.rowCaptionAt(rowIndex).trim();
    if (rowCaption.isNotEmpty) {
      parts.add('辅助理解（不得覆盖参考图视觉证据）- 当前行描述：$rowCaption');
    }
    final summary = board.summary;
    if (summary != null) {
      final outline = summary.outline.trim();
      if (outline.isNotEmpty) {
        parts.add('辅助理解（不得覆盖参考图视觉证据）- 故事概述：$outline');
      }
    }
    return parts.join('\n');
  }

  Future<bool> _runImageReplacementTask(
    _PreparedImageReplacementTask task,
  ) async {
    try {
      final settings = _settingsController!.value;
      final provider = ImageGenerationProviderResolver.resolve(
        settings: settings,
        model: task.model,
      );
      final result = await _imageGenerationService.generateEditedImage(
        ImageGenerationRequest(
          provider: provider,
          model: task.model,
          prompt: task.prompt,
          aspectRatio: task.aspectRatio,
          imageSize: task.imageSize,
          quality: task.quality,
          referenceImagePaths: task.referenceImagePaths,
          outputDirectory: _aiEditedImagesDirectory(
            _directories!,
            task.boardName,
          ),
        ),
      );
      return _withImageResultCommitLock(() async {
        final archivedResult = await _archiveAiEditedImage(
          sourcePath: result.localPath,
          boardName: task.boardName,
        );
        final replacement = await _registerGeneratedImageAsset(
          sourceAsset: task.sourceAsset,
          resultPath: archivedResult.path,
          indexNo: archivedResult.indexNo,
        );
        final applied = _replaceCurrentItemAsset(
          boardId: task.boardId,
          slotIndex: task.slotIndex,
          oldAssetId: task.sourceAsset.id,
          replacement: replacement,
          successMessage: task.successMessage,
          changedMessage: task.changedMessage,
        );
        _database.updateImageGenerationRecord(
          id: task.generationId,
          status: applied ? 'succeeded' : 'orphaned',
          resultAssetId: replacement.id,
          resultPath: _toStoredPath(replacement.path),
          rawResponse: result.rawResponse,
        );
        return applied;
      });
    } catch (error) {
      _database.updateImageGenerationRecord(
        id: task.generationId,
        status: 'failed',
        errorMessage: error.toString(),
      );
      if (!_disposed) {
        _setBoardTaskMessage(task.boardId, '图片修改失败：$error');
      }
      return false;
    } finally {
      _finishImageGenerationTask(task.boardId);
    }
  }

  Future<T> _withImageResultCommitLock<T>(Future<T> Function() action) async {
    final previous = _imageResultCommitTail;
    final release = Completer<void>();
    _imageResultCommitTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  void _finishImageGenerationTask(String boardId) {
    final remaining = math.max(
      0,
      (_activeImageGenerationCountByBoardId[boardId] ?? 0) - 1,
    );
    if (remaining == 0) {
      _activeImageGenerationCountByBoardId.remove(boardId);
    } else {
      _activeImageGenerationCountByBoardId[boardId] = remaining;
    }
    if (_disposed) {
      return;
    }
    final currentMessage = (_boardTaskMessages[boardId] ?? '').trim();
    _syncVisionTaskState(
      boardId: boardId,
      message: remaining > 0 && currentMessage.isNotEmpty
          ? '$currentMessage（另有 $remaining 个后台任务进行中）'
          : currentMessage,
    );
  }

  Future<void> analyzeSelectedBoardWithVision() async {
    final board = value.selectedBoard;
    if (board == null) {
      value = value.copyWith(message: '请先创建故事板');
      return;
    }
    if (_guardLockedBoard(board, '自动解析')) {
      return;
    }
    if (_orderedVisibleItems(board).isEmpty) {
      value = value.copyWith(message: '当前画板没有可解析的图片');
      return;
    }
    await _enqueueVisionTask(
      StoryboardVisionTask(
        boardId: board.id,
        kind: StoryboardVisionTaskKind.analyze,
      ),
    );
  }

  Future<void> _analyzeBoardWithVision({
    required String boardId,
    required _VisionOperationToken operationToken,
    bool triggeredByReorder = false,
    bool triggeredByPrompt = false,
  }) async {
    final settingsController = _settingsController;
    if (settingsController == null) {
      _setBoardTaskMessage(boardId, '视觉模型设置尚未初始化');
      return;
    }
    final board = _boardById(boardId);
    if (board == null) {
      _setBoardTaskMessage(boardId, '目标画板已不存在');
      return;
    }
    if (board.locked) {
      _setBoardTaskMessage(boardId, '${board.name} 已锁定，请先解锁后再自动解析');
      return;
    }
    final orderedItems =
        board.items
            .where(
              (item) => item.slotIndex >= 0 && item.slotIndex < board.slotCount,
            )
            .toList()
          ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    if (orderedItems.isEmpty) {
      _setBoardTaskMessage(boardId, '当前画板没有可解析的图片');
      return;
    }

    final settings = settingsController.value;
    final runId = _uuid.v4();
    await _logVisionEvent('analysis_start', {
      'runId': runId,
      'boardId': board.id,
      'triggeredByReorder': triggeredByReorder,
      'triggeredByPrompt': triggeredByPrompt,
      'model': settings.visionModel,
      'totalImages': orderedItems.length,
    });
    _database.insertVisionAnalysisRun(
      id: runId,
      boardId: board.id,
      model: settings.visionModel,
      status: 'running',
      totalImages: orderedItems.length,
    );

    _syncVisionTaskState(
      boardId: boardId,
      message: '正在解析故事板图片 0/${orderedItems.length}',
    );

    final analyzedItems = <_AnalyzedStoryboardItem>[];
    var successCount = 0;
    var failedCount = 0;

    Future<void> finishCancelled() async {
      _database.updateVisionAnalysisRun(
        id: runId,
        status: 'cancelled',
        successCount: successCount,
        errorMessage: '用户取消',
      );
      await _finishCancelledVisionOperation(
        operationToken,
        runId: runId,
        message: triggeredByReorder
            ? '已取消自动重排序'
            : triggeredByPrompt
            ? '已取消自动提示词解析'
            : '已取消自动解析',
      );
    }

    Future<void> processItem(int i) async {
      if (_isVisionOperationCancelled(operationToken)) {
        return;
      }
      final item = orderedItems[i];
      final rowIndex = item.slotIndex ~/ board.columns;
      final columnIndex = item.slotIndex % board.columns;
      _setBoardTaskMessage(
        boardId,
        '正在解析第 ${i + 1}/${orderedItems.length} 张图片',
      );
      await _logVisionEvent('analysis_image_start', {
        'runId': runId,
        'sequenceNo': i + 1,
        'slotIndex': item.slotIndex,
        'assetId': item.asset.id,
        'path': item.asset.path,
      });
      try {
        final analysis = await _visionService.analyzeImage(
          settings: settings,
          imageFile: File(item.asset.path),
          sequenceNo: i + 1,
          rowIndex: rowIndex,
          columnIndex: columnIndex,
          onRecovery: (mode) {
            if (_isVisionOperationCancelled(operationToken)) {
              return;
            }
            final recoveryMessage = switch (mode) {
              VisionImageRecoveryMode.jsonRepair => '第 ${i + 1} 张返回格式异常，正在自动修复',
              VisionImageRecoveryMode.imageRetry => '第 ${i + 1} 张解析异常，正在重新解析',
              VisionImageRecoveryMode.simplifiedFallback =>
                '第 ${i + 1} 张完整解析异常，正在使用稳定模式',
              VisionImageRecoveryMode.none =>
                '正在解析第 ${i + 1}/${orderedItems.length} 张图片',
            };
            _setBoardTaskMessage(boardId, recoveryMessage);
          },
        );
        if (_isVisionOperationCancelled(operationToken)) {
          return;
        }
        _database.insertVisionAnalysisItem(
          id: _uuid.v4(),
          runId: runId,
          boardId: board.id,
          cutResultId: item.asset.id,
          slotIndex: item.slotIndex,
          sequenceNo: i + 1,
          rowIndex: rowIndex,
          columnIndex: columnIndex,
          status: 'success',
          caption: analysis.caption,
          detail: analysis.detail,
          scene: analysis.scene,
          props: analysis.props,
          people: analysis.people,
          expression: analysis.expression,
          bodyAction: analysis.bodyAction,
          movementTrend: analysis.movementTrend,
          cameraMovement: analysis.cameraMovement,
          shotSize: analysis.shotSize,
          composition: analysis.composition,
          subjectDirection: analysis.subjectDirection,
          gazeDirection: analysis.gazeDirection,
          actionStage: analysis.actionStage,
          spatialRelation: analysis.spatialRelation,
          chronologyCue: analysis.chronologyCue,
          cameraAngle: analysis.cameraAngle,
          visualFocus: analysis.visualFocus,
          lightingMood: analysis.lightingMood,
          colorPalette: analysis.colorPalette,
          narrativeFunction: analysis.narrativeFunction,
          transitionHint: analysis.transitionHint,
          rawResponse: analysis.rawResponse,
        );
        analyzedItems.add(
          _AnalyzedStoryboardItem(
            slotIndex: item.slotIndex,
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            analysis: analysis,
          ),
        );
        successCount++;
        if (analysis.recoveryMode != VisionImageRecoveryMode.none) {
          await _logVisionEvent('analysis_image_recovery', {
            'runId': runId,
            'sequenceNo': i + 1,
            'assetId': item.asset.id,
            'mode': analysis.recoveryMode.name,
            'requestCount': analysis.requestCount,
            'recoveryErrors': analysis.recoveryErrors,
          });
        }
        await _logVisionEvent('analysis_image_success', {
          'runId': runId,
          'sequenceNo': i + 1,
          'assetId': item.asset.id,
          'recoveryMode': analysis.recoveryMode.name,
          'requestCount': analysis.requestCount,
          'recoveryErrors': analysis.recoveryErrors,
          'rawResponsePreview': _visionLogPreview(analysis.rawResponse),
        });
      } catch (error) {
        if (_isVisionOperationCancelled(operationToken)) {
          return;
        }
        failedCount++;
        final analysisError = error is VisionImageAnalysisException
            ? error
            : null;
        await _logVisionEvent('analysis_image_failed', {
          'runId': runId,
          'sequenceNo': i + 1,
          'assetId': item.asset.id,
          'error': error.toString(),
          if (analysisError != null) ...{
            'requestCount': analysisError.requestCount,
            'recoveryErrors': analysisError.recoveryErrors,
            'rawResponsePreview': _visionLogPreview(analysisError.rawResponse),
          },
        });
        _database.insertVisionAnalysisItem(
          id: _uuid.v4(),
          runId: runId,
          boardId: board.id,
          cutResultId: item.asset.id,
          slotIndex: item.slotIndex,
          sequenceNo: i + 1,
          rowIndex: rowIndex,
          columnIndex: columnIndex,
          status: 'failed',
          caption: '',
          detail: '',
          scene: '',
          props: '',
          people: '',
          expression: '',
          bodyAction: '',
          movementTrend: '',
          rawResponse: analysisError?.rawResponse ?? '',
          errorMessage: error.toString(),
        );
      }
    }

    var nextIndex = 0;
    Future<void> processQueue() async {
      while (nextIndex < orderedItems.length &&
          !_isVisionOperationCancelled(operationToken)) {
        await processItem(nextIndex++);
      }
    }

    final workerCount = VisionRequestRateLimiter.maxConcurrentRequestsFor(
      settings,
    ).clamp(1, orderedItems.length);
    await Future.wait([
      for (var worker = 0; worker < workerCount; worker++) processQueue(),
    ]);
    if (_isVisionOperationCancelled(operationToken)) {
      await finishCancelled();
      return;
    }
    // 并发返回顺序不稳定，连贯化与写回必须始终遵循故事板槽位顺序。
    analyzedItems.sort(
      (first, second) => first.slotIndex.compareTo(second.slotIndex),
    );

    var captionRewriteError = '';
    var captionRewriteFallbackCount = 0;
    var displayAnalyzedItems = analyzedItems;
    if (analyzedItems.length > 1) {
      if (_isVisionOperationCancelled(operationToken)) {
        await finishCancelled();
        return;
      }
      _setBoardTaskMessage(boardId, '正在连贯化故事板文本...');
      await _logVisionEvent('caption_rewrite_start', {
        'runId': runId,
        'count': analyzedItems.length,
      });
      try {
        final captionResult = await _visionService.rewriteStoryboardCaptions(
          settings: settings,
          analyses: analyzedItems.map((item) => item.analysis).toList(),
          onProgress: (completed, total) {
            if (!_isVisionOperationCancelled(operationToken)) {
              _setBoardTaskMessage(boardId, '正在连贯化故事板文本 $completed/$total');
            }
          },
        );
        if (_isVisionOperationCancelled(operationToken)) {
          await finishCancelled();
          return;
        }
        displayAnalyzedItems = [
          for (var i = 0; i < analyzedItems.length; i++)
            analyzedItems[i].copyWith(
              analysis: analyzedItems[i].analysis.withCaption(
                captionResult.captions[i],
              ),
            ),
        ];
        captionRewriteFallbackCount = captionResult.fallbackSequenceNos.length;
        await _logVisionEvent('caption_rewrite_success', {
          'runId': runId,
          'requestedCount': analyzedItems.length,
          'initialReturnedCount': captionResult.initialReturnedCount,
          'repairedSequenceNos': captionResult.repairedSequenceNos,
          'fallbackSequenceNos': captionResult.fallbackSequenceNos,
          'diagnostics': captionResult.diagnostics,
          'rawResponsePreview': _visionLogPreview(captionResult.rawResponse),
        });
      } catch (error) {
        if (_isVisionOperationCancelled(operationToken)) {
          await finishCancelled();
          return;
        }
        captionRewriteFallbackCount = analyzedItems.length;
        await _logVisionEvent('caption_rewrite_failed', {
          'runId': runId,
          'error': error.toString(),
          'recovery': 'controller_preserved_analyzed_captions',
        });
      }
    }

    StoryboardSummary? summary;
    var summaryError = '';
    if (displayAnalyzedItems.isNotEmpty) {
      if (_isVisionOperationCancelled(operationToken)) {
        await finishCancelled();
        return;
      }
      _setBoardTaskMessage(boardId, '正在归纳故事板内容...');
      await _logVisionEvent('summary_start', {
        'runId': runId,
        'count': displayAnalyzedItems.length,
      });
      try {
        final summaryResult = await _visionService.summarizeStoryboard(
          settings: settings,
          analyses: displayAnalyzedItems.map((item) => item.analysis).toList(),
        );
        if (_isVisionOperationCancelled(operationToken)) {
          await finishCancelled();
          return;
        }
        summary = StoryboardSummary(
          outline: summaryResult.outline,
          content: summaryResult.content,
          scenes: summaryResult.scenes,
          props: summaryResult.props,
        );
        _database.upsertStoryboardSummary(
          boardId: board.id,
          runId: runId,
          outline: summaryResult.outline,
          content: summaryResult.content,
          scenes: summaryResult.scenes,
          props: summaryResult.props,
          rawResponse: summaryResult.rawResponse,
        );
        await _logVisionEvent('summary_success', {'runId': runId});
      } catch (error) {
        if (_isVisionOperationCancelled(operationToken)) {
          await finishCancelled();
          return;
        }
        summaryError = error.toString();
        await _logVisionEvent('summary_failed', {
          'runId': runId,
          'error': summaryError,
        });
      }
    }

    final errorMessage = [
      if (captionRewriteError.isNotEmpty) captionRewriteError,
      if (summaryError.isNotEmpty) summaryError,
    ].join('\n');
    final status =
        failedCount == 0 && captionRewriteError.isEmpty && summaryError.isEmpty
        ? 'completed'
        : 'completed_with_errors';
    _database.updateVisionAnalysisRun(
      id: runId,
      status: status,
      successCount: successCount,
      errorMessage: errorMessage,
    );
    await _logVisionEvent('analysis_complete', {
      'runId': runId,
      'status': status,
      'successCount': successCount,
      'failedCount': failedCount,
      if (errorMessage.isNotEmpty) 'error': errorMessage,
    });
    _applyVisionResults(
      boardId: board.id,
      analyzedItems: displayAnalyzedItems,
      summary: summary,
      message: _visionCompletionMessage(
        totalCount: analyzedItems.length,
        successCount: successCount,
        failedCount: failedCount,
        captionRewriteError: captionRewriteError,
        captionRewriteFallbackCount: captionRewriteFallbackCount,
        summaryError: summaryError,
      ),
    );
  }

  Future<void> reorderSelectedBoardByVisionAnalysis() async {
    final settingsController = _settingsController;
    if (settingsController == null) {
      value = value.copyWith(message: '视觉模型设置尚未初始化');
      return;
    }
    var board = value.selectedBoard;
    if (board == null) {
      value = value.copyWith(message: '请先创建故事板');
      return;
    }
    if (_guardLockedBoard(board, '自动重排序')) {
      return;
    }
    var orderedItems = _orderedVisibleItems(board);
    if (orderedItems.length < 2) {
      value = value.copyWith(message: '至少需要 2 张图片才能自动重排序');
      return;
    }

    await _enqueueVisionTask(
      StoryboardVisionTask(
        boardId: board.id,
        kind: StoryboardVisionTaskKind.reorder,
      ),
    );
  }

  Future<void> _reorderBoardByVisionAnalysis({
    required String boardId,
    required _VisionOperationToken operationToken,
  }) async {
    final settingsController = _settingsController;
    if (settingsController == null) {
      _setBoardTaskMessage(boardId, '视觉模型设置尚未初始化');
      return;
    }
    var board = _boardById(boardId);
    if (board == null) {
      _setBoardTaskMessage(boardId, '目标画板已不存在');
      return;
    }
    if (board.locked) {
      _setBoardTaskMessage(boardId, '${board.name} 已锁定，请先解锁后再自动重排序');
      return;
    }
    var orderedItems = _orderedVisibleItems(board);
    if (orderedItems.length < 2) {
      _setBoardTaskMessage(boardId, '至少需要 2 张图片才能自动重排序');
      return;
    }

    final reorderRunId = _uuid.v4();
    await _logVisionEvent('reorder_start', {
      'runId': reorderRunId,
      'boardId': board.id,
      'imageCount': orderedItems.length,
      'model': settingsController.value.visionModel,
    });
    final batch = await _visionOrderingBatchForBoard(
      board: board,
      orderedItems: orderedItems,
      operationToken: operationToken,
    );
    if (_isVisionOperationCancelled(operationToken)) {
      await _finishCancelledVisionOperation(
        operationToken,
        runId: reorderRunId,
        message: '已取消自动重排序',
      );
      return;
    }
    if (batch == null) {
      return;
    }
    board = _boardById(batch.run.boardId);
    if (board == null || board.id != batch.run.boardId) {
      _setBoardTaskMessage(boardId, '目标画板已不存在，请重新自动重排序');
      return;
    }
    orderedItems = _orderedVisibleItems(board);

    _syncVisionTaskState(boardId: boardId, message: '正在根据解析内容自动重排序...');

    final settings = settingsController.value;
    final currentItemByAssetId = {
      for (final item in orderedItems) item.asset.id: item,
    };
    final recordItems = _visionRecordItemsInCurrentOrder(
      orderedItems,
      batch.items,
    );
    if (recordItems.length != orderedItems.length) {
      _setBoardTaskMessage(boardId, '当前画板图片与最近解析结果不一致，请重新自动解析后再重排序');
      return;
    }

    try {
      await _logVisionEvent('reorder_order_request_start', {
        'runId': reorderRunId,
        'analysisCount': recordItems.length,
      });
      final orderResult = await _visionService.suggestStoryboardOrder(
        settings: settings,
        analyses: recordItems.map((item) => item.analysis).toList(),
      );
      if (_isVisionOperationCancelled(operationToken)) {
        await _finishCancelledVisionOperation(
          operationToken,
          runId: reorderRunId,
          message: '已取消自动重排序',
        );
        return;
      }
      await _logVisionEvent('reorder_order_request_success', {
        'runId': reorderRunId,
        'order': orderResult.order,
        'rawResponse': orderResult.rawResponse,
      });
      final reorderedRecordItems = [
        for (final index in orderResult.order) recordItems[index - 1],
      ];

      var captionRewriteError = '';
      var captionRewriteFallbackCount = 0;
      var displayRecordItems = reorderedRecordItems;
      try {
        await _logVisionEvent('reorder_caption_rewrite_start', {
          'runId': reorderRunId,
          'count': reorderedRecordItems.length,
        });
        final captionResult = await _visionService.rewriteStoryboardCaptions(
          settings: settings,
          analyses: reorderedRecordItems.map((item) => item.analysis).toList(),
          onProgress: (completed, total) {
            if (!_isVisionOperationCancelled(operationToken)) {
              _setBoardTaskMessage(boardId, '正在连贯化重排序文本 $completed/$total');
            }
          },
        );
        if (_isVisionOperationCancelled(operationToken)) {
          await _finishCancelledVisionOperation(
            operationToken,
            runId: reorderRunId,
            message: '已取消自动重排序',
          );
          return;
        }
        displayRecordItems = [
          for (var i = 0; i < reorderedRecordItems.length; i++)
            reorderedRecordItems[i].copyWith(
              analysis: reorderedRecordItems[i].analysis.withCaption(
                captionResult.captions[i],
              ),
            ),
        ];
        captionRewriteFallbackCount = captionResult.fallbackSequenceNos.length;
        await _logVisionEvent('reorder_caption_rewrite_success', {
          'runId': reorderRunId,
          'requestedCount': reorderedRecordItems.length,
          'initialReturnedCount': captionResult.initialReturnedCount,
          'repairedSequenceNos': captionResult.repairedSequenceNos,
          'fallbackSequenceNos': captionResult.fallbackSequenceNos,
          'diagnostics': captionResult.diagnostics,
          'rawResponsePreview': _visionLogPreview(captionResult.rawResponse),
        });
      } catch (error) {
        if (_isVisionOperationCancelled(operationToken)) {
          await _finishCancelledVisionOperation(
            operationToken,
            runId: reorderRunId,
            message: '已取消自动重排序',
          );
          return;
        }
        captionRewriteFallbackCount = reorderedRecordItems.length;
        await _logVisionEvent('reorder_caption_rewrite_failed', {
          'runId': reorderRunId,
          'error': error.toString(),
          'recovery': 'controller_preserved_analyzed_captions',
        });
      }

      final nextAnalyzedItems = [
        for (var i = 0; i < displayRecordItems.length; i++)
          _AnalyzedStoryboardItem(
            slotIndex: i,
            rowIndex: i ~/ board.columns,
            columnIndex: i % board.columns,
            analysis: displayRecordItems[i].analysis,
          ),
      ];

      var summaryError = '';
      var summary = _fallbackSummaryForAnalyses(
        nextAnalyzedItems.map((item) => item.analysis).toList(),
      );
      try {
        await _logVisionEvent('reorder_summary_start', {
          'runId': reorderRunId,
          'count': nextAnalyzedItems.length,
        });
        final summaryResult = await _visionService.summarizeStoryboard(
          settings: settings,
          analyses: nextAnalyzedItems.map((item) => item.analysis).toList(),
        );
        if (_isVisionOperationCancelled(operationToken)) {
          await _finishCancelledVisionOperation(
            operationToken,
            runId: reorderRunId,
            message: '已取消自动重排序',
          );
          return;
        }
        summary = StoryboardSummary(
          outline: summaryResult.outline,
          content: summaryResult.content,
          scenes: summaryResult.scenes,
          props: summaryResult.props,
        );
        await _logVisionEvent('reorder_summary_success', {
          'runId': reorderRunId,
        });
      } catch (error) {
        if (_isVisionOperationCancelled(operationToken)) {
          await _finishCancelledVisionOperation(
            operationToken,
            runId: reorderRunId,
            message: '已取消自动重排序',
          );
          return;
        }
        summaryError = error.toString();
        await _logVisionEvent('reorder_summary_failed', {
          'runId': reorderRunId,
          'error': summaryError,
        });
      }

      final nextItems = <StoryboardItem>[];
      for (var i = 0; i < displayRecordItems.length; i++) {
        final recordItem = displayRecordItems[i];
        final currentItem = currentItemByAssetId[recordItem.record.cutResultId];
        if (currentItem == null) {
          _setBoardTaskMessage(boardId, '当前画板图片与最近解析结果不一致，请重新自动解析后再重排序');
          return;
        }
        final analyzedCaption = recordItem.analysis.caption.trim();
        nextItems.add(
          currentItem.copyWith(
            slotIndex: i,
            caption: analyzedCaption.isNotEmpty
                ? recordItem.analysis.caption
                : currentItem.caption,
          ),
        );
      }

      final rowCaptions = _rowCaptionsForRows(board, board.rows);
      if (board.rowDescriptionEnabled) {
        for (var rowIndex = 0; rowIndex < board.rows; rowIndex++) {
          final rowItems =
              nextAnalyzedItems
                  .where((item) => item.rowIndex == rowIndex)
                  .toList()
                ..sort((a, b) => a.columnIndex.compareTo(b.columnIndex));
          rowCaptions[rowIndex] = composeVisionAnalysesDescription(
            rowItems.map((item) => item.analysis).toList(),
          );
        }
      }

      final moved = !_sameItemOrder(orderedItems, nextItems);
      await _logVisionEvent('reorder_complete', {
        'runId': reorderRunId,
        'moved': moved,
        if (captionRewriteError.isNotEmpty)
          'captionRewriteError': captionRewriteError,
        if (captionRewriteFallbackCount > 0)
          'captionRewriteFallbackCount': captionRewriteFallbackCount,
        if (summaryError.isNotEmpty) 'summaryError': summaryError,
      });
      final latestBoard = _boardById(board.id);
      if (latestBoard == null) {
        _setBoardTaskMessage(boardId, '自动重排序完成，但目标画板已不存在');
        return;
      }
      if (latestBoard.locked) {
        _setBoardTaskMessage(boardId, '${latestBoard.name} 已锁定，未写回自动重排序');
        return;
      }
      final completionMessage = _visionReorderCompletionMessage(
        moved: moved,
        captionRewriteError: captionRewriteError,
        captionRewriteFallbackCount: captionRewriteFallbackCount,
        summaryError: summaryError,
      );
      _setBoardTaskMessage(boardId, completionMessage);
      _replaceBoard(
        latestBoard.copyWith(
          items: nextItems,
          rowCaptions: rowCaptions,
          summary: summary,
        ),
        message: value.selectedBoardId == boardId ? completionMessage : null,
        reorderAnimationToken: moved && value.selectedBoardId == boardId
            ? value.reorderAnimationToken + 1
            : null,
        selectBoard: value.selectedBoardId == latestBoard.id,
      );
    } catch (error) {
      if (_isVisionOperationCancelled(operationToken)) {
        await _finishCancelledVisionOperation(
          operationToken,
          runId: reorderRunId,
          message: '已取消自动重排序',
        );
        return;
      }
      await _logVisionEvent('reorder_failed', {
        'runId': reorderRunId,
        'error': error.toString(),
      });
      _setBoardTaskMessage(boardId, '自动重排序失败：$error');
    }
  }

  void setResolution(int width, int _) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整画板尺寸')) {
      return;
    }
    final nextWidth = width.clamp(320, 12000).toInt();
    _replaceBoard(
      board.copyWith(width: nextWidth).withAdaptiveHeight(),
      message: '画板宽度已更新，高度已按宫格自动适配',
    );
  }

  void setPortraitMode(bool enabled) {
    final board = value.selectedBoard;
    if (board == null || board.portraitMode == enabled) {
      return;
    }
    if (_guardLockedBoard(board, '切换竖屏模式')) {
      return;
    }
    final compactBoard = _compactBoardItems(board);
    if (enabled) {
      final nextRows = math.max(1, compactBoard.visibleItemCount);
      _replaceBoard(
        compactBoard
            .copyWith(
              rows: nextRows,
              columns: 1,
              configuredRows: board.effectiveConfiguredRows,
              configuredColumns: board.effectiveConfiguredColumns,
              rowCaptions: _rowCaptionsForRows(compactBoard, nextRows),
              portraitMode: true,
            )
            .withAdaptiveHeight(),
        message: '已切换为竖屏故事板（每行 1 张图）',
      );
      return;
    }
    final landscapeBoard = compactBoard.copyWith(portraitMode: false);
    _replaceBoard(
      _boardWithGridForItemCount(
        landscapeBoard,
        itemCount: landscapeBoard.visibleItemCount,
      ).withAdaptiveHeight(),
      message: '已恢复横屏宫格布局',
    );
  }

  void setGrid(int rows, int columns) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整宫格布局')) {
      return;
    }
    if (board.portraitMode) {
      value = value.copyWith(message: '竖屏模式固定为每行 1 张图，请先关闭竖屏模式');
      return;
    }
    final nextRows = rows.clamp(1, _maxConfiguredGridExtent).toInt();
    final nextColumns = columns.clamp(1, _maxConfiguredGridExtent).toInt();
    final nextBoard = _boardWithGridForItemCount(
      board,
      itemCount: board.visibleItemCount,
      configuredRows: nextRows,
      configuredColumns: nextColumns,
    );
    _replaceBoard(
      nextBoard,
      message: nextBoard.isAutoExpandedFromConfiguredLayout
          ? '宫格布局已设置为 $nextRows x $nextColumns，当前图片已自动适配为 ${nextBoard.rows} x ${nextBoard.columns}'
          : '宫格布局已更新为 $nextRows x $nextColumns',
    );
  }

  void setColumns(int columns) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    setGrid(board.effectiveConfiguredRows, columns);
  }

  void setRowsAndAdaptColumns(int rows) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    final nextRows = rows.clamp(1, _maxConfiguredGridExtent).toInt();
    final itemCount = board.visibleItemCount.clamp(1, _maxSlotCount).toInt();
    final nextColumns = (itemCount / nextRows)
        .ceil()
        .clamp(1, _maxAutomaticGridExtent)
        .toInt();
    setGrid(nextRows, nextColumns);
  }

  void setColumnsAndAdaptRows(int columns) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    final nextColumns = columns.clamp(1, _maxConfiguredGridExtent).toInt();
    final itemCount = board.visibleItemCount.clamp(1, _maxSlotCount).toInt();
    final nextRows = (itemCount / nextColumns)
        .ceil()
        .clamp(1, _maxAutomaticGridExtent)
        .toInt();
    setGrid(nextRows, nextColumns);
  }

  void setGap(double gap) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整图片间距')) {
      return;
    }
    final nextGap = gap.clamp(0, 80).toDouble();
    if ((board.gap - nextGap).abs() < 0.01) {
      return;
    }
    final columns = math.max(1, board.columns);
    final rows = math.max(1, board.rows);
    final cellWidth = math.max(
      1.0,
      (board.width - board.gap * (columns + 1)) / columns,
    );
    final nextWidth = (cellWidth * columns + nextGap * (columns + 1))
        .round()
        .clamp(320, 12000)
        .toInt();
    final rowBandHeight = math.max(
      1.0,
      (board.height - board.gap * (rows + 1)) / rows,
    );
    final nextHeight = (rowBandHeight * rows + nextGap * (rows + 1))
        .round()
        .clamp(1, 60000)
        .toInt();
    final nextBoard = _compactBoardItems(
      board.copyWith(width: nextWidth, height: nextHeight, gap: nextGap),
    );
    _recordBoardHistory(board);
    _setState(
      value.copyWith(
        boards: [
          for (final item in value.boards)
            if (item.id == nextBoard.id) nextBoard else item,
        ],
        message: '图片间距已更新，画板尺寸已自动扩展',
      ),
      saveWorkspace: false,
    );
    _scheduleWorkspaceSnapshotSave(delay: const Duration(milliseconds: 300));
  }

  void setStoryDescriptionEnabled(bool enabled) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整描述显示')) {
      return;
    }
    _replaceBoard(
      board.copyWith(storyDescriptionEnabled: enabled),
      message: enabled ? '已显示故事描述文本框' : '已隐藏故事描述文本框',
    );
  }

  void setRowDescriptionEnabled(bool enabled) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整描述显示')) {
      return;
    }
    _replaceBoard(
      board.copyWith(
        rowDescriptionEnabled: enabled,
        rowCaptions: _rowCaptionsForRows(board, board.rows),
      ),
      message: enabled ? '已启用逐行描述' : '已关闭逐行描述',
    );
  }

  void setCaptionFontFamily(String fontFamily) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整描述字体')) {
      return;
    }
    _replaceBoard(board.copyWith(captionFontFamily: fontFamily));
  }

  void setCaptionFontSize(double fontSize) {
    final board = value.selectedBoard;
    if (board == null) {
      return;
    }
    if (_guardLockedBoard(board, '调整描述字体')) {
      return;
    }
    _replaceBoard(
      board.copyWith(captionFontSize: fontSize.clamp(12, 48)),
      saveWorkspace: false,
    );
    _scheduleWorkspaceSnapshotSave(delay: const Duration(milliseconds: 300));
  }

  void setRowDividerEnabled(bool enabled) {
    final board = value.selectedBoard;
    if (board == null || _guardLockedBoard(board, '调整行分割线')) {
      return;
    }
    _replaceBoard(
      board.copyWith(rowDividerEnabled: enabled),
      message: enabled ? '已显示行分割线' : '已隐藏行分割线',
    );
  }

  void setRowDividerStyle(StoryboardDividerStyle style) {
    final board = value.selectedBoard;
    if (board == null || _guardLockedBoard(board, '调整行分割线')) {
      return;
    }
    _replaceBoard(board.copyWith(rowDividerStyle: style));
  }

  void setRowDividerOpacity(double opacity) {
    final board = value.selectedBoard;
    if (board == null || _guardLockedBoard(board, '调整行分割线')) {
      return;
    }
    _replaceBoard(
      board.copyWith(rowDividerOpacity: opacity.clamp(0.05, 1.0)),
      saveWorkspace: false,
    );
    _scheduleWorkspaceSnapshotSave(delay: const Duration(milliseconds: 300));
  }

  void setTitleAlignment(StoryboardTitleAlignment alignment) {
    final board = value.selectedBoard;
    if (board == null || _guardLockedBoard(board, '调整标题对齐')) {
      return;
    }
    _replaceBoard(board.copyWith(titleAlignment: alignment));
  }

  Directory? _folderDirectory(String folderId) {
    for (final folder in value.folders) {
      if (folder.id == folderId) {
        return Directory(folder.path);
      }
    }
    final root = _directories?.storyboardFolders;
    if (root == null) {
      return null;
    }
    final folder = Directory(p.join(root.path, folderId));
    if (!folder.existsSync()) {
      return null;
    }
    return folder;
  }

  Future<File?> _copyImageFileToFolder(File source, Directory folder) async {
    if (!folder.existsSync()) {
      await folder.create(recursive: true);
    }
    final originalTarget = File(p.join(folder.path, p.basename(source.path)));
    if (originalTarget.existsSync() && _sameFilePath(source, originalTarget)) {
      return null;
    }
    final target = _uniqueFile(folder, p.basename(source.path));
    return source.copy(target.path);
  }

  StoryboardCutAsset _registerReplacementImageAsset({
    required String originalPath,
    required String resultPath,
    required String sourceName,
    required ({int width, int height}) size,
    required String idPrefix,
    required String taskStatus,
    String? sharedImageId,
    int indexNo = 1,
  }) {
    final imageId = sharedImageId ?? '$idPrefix-image-${_uuid.v4()}';
    final taskId = '$idPrefix-task-${_uuid.v4()}';
    final resultId = '$idPrefix-cut-${_uuid.v4()}';
    final now = DateTime.now().toIso8601String();
    final storedPath = _toStoredPath(resultPath);

    _database
      ..upsertImportedImage(
        id: imageId,
        originalPath: originalPath,
        originalName: sourceName,
        storedPath: storedPath,
        width: size.width,
        height: size.height,
        createdAt: now,
      )
      ..upsertCutTask(
        id: taskId,
        imageId: imageId,
        status: taskStatus,
        rows: 1,
        columns: 1,
        confidence: 1,
      )
      ..insertCutResult(
        id: resultId,
        taskId: taskId,
        imageId: imageId,
        indexNo: indexNo,
        path: storedPath,
        x: 0,
        y: 0,
        width: size.width,
        height: size.height,
        selected: true,
      );

    return StoryboardCutAsset(
      id: resultId,
      imageId: imageId,
      sourceName: sourceName,
      path: resultPath,
      indexNo: indexNo,
    );
  }

  Future<StoryboardCutAsset> _registerGeneratedImageAsset({
    required StoryboardCutAsset sourceAsset,
    required String resultPath,
    required int indexNo,
  }) async {
    final file = File(resultPath);
    final size = await _readImageSize(file);
    return _registerReplacementImageAsset(
      originalPath: sourceAsset.path,
      resultPath: resultPath,
      sourceName: _aiEditedImagesSourceName,
      size: size,
      idPrefix: 'generated',
      taskStatus: 'generated',
      sharedImageId: _aiEditedImagesImageId,
      indexNo: indexNo,
    );
  }

  Directory _aiEditedImagesDirectory(
    WorkspaceDirectories directories,
    String boardName,
  ) {
    final safeBoardName = _safeFileNamePart(boardName, fallback: '画板');
    return Directory(
      p.join(
        directories.generatedImages.path,
        '$safeBoardName-$_aiEditedImagesDirectorySuffix',
      ),
    );
  }

  Directory _manualReplacementDirectory(
    WorkspaceDirectories directories,
    String boardName,
  ) {
    final safeBoardName = _safeFileNamePart(boardName, fallback: '画板');
    return Directory(
      p.join(
        directories.generatedImages.path,
        '$safeBoardName-$_manualReplacementDirectorySuffix',
      ),
    );
  }

  Future<({String path, int indexNo})> _archiveManualReplacementImage({
    required String sourcePath,
    required String boardName,
  }) async {
    final directories = _directories!;
    final safeBoardName = _safeFileNamePart(boardName, fallback: '画板');
    final outputDirectory = _manualReplacementDirectory(
      directories,
      safeBoardName,
    );
    await outputDirectory.create(recursive: true);
    final indexNo = _nextManualReplacementIndex(directories);
    final extension = p.extension(sourcePath).toLowerCase();
    final safeExtension = _isSupportedImage(sourcePath) ? extension : '.png';
    final fileName =
        '${indexNo.toString().padLeft(3, '0')}-$safeBoardName-手动替换$safeExtension';
    final copied = await File(
      sourcePath,
    ).copy(p.join(outputDirectory.path, fileName));
    return (path: copied.path, indexNo: indexNo);
  }

  int _nextManualReplacementIndex(WorkspaceDirectories directories) {
    var maxIndex = 0;
    for (final record in _database.listCutResults()) {
      if (!_isManualReplacementAssetId(record.id)) {
        continue;
      }
      maxIndex = math.max(maxIndex, record.indexNo);
    }
    if (directories.generatedImages.existsSync()) {
      final sequencePattern = RegExp(r'^(\d+)-');
      final manualDirectories = directories.generatedImages
          .listSync()
          .whereType<Directory>()
          .where(
            (directory) => p
                .basename(directory.path)
                .endsWith('-$_manualReplacementDirectorySuffix'),
          );
      for (final directory in manualDirectories) {
        for (final file in directory.listSync().whereType<File>()) {
          final match = sequencePattern.firstMatch(p.basename(file.path));
          final parsed = match == null ? null : int.tryParse(match.group(1)!);
          if (parsed != null) {
            maxIndex = math.max(maxIndex, parsed);
          }
        }
      }
    }
    return maxIndex + 1;
  }

  Future<({String path, int indexNo})> _archiveAiEditedImage({
    required String sourcePath,
    required String boardName,
  }) async {
    final directories = _directories!;
    final safeBoardName = _safeFileNamePart(boardName, fallback: '画板');
    final outputDirectory = _aiEditedImagesDirectory(
      directories,
      safeBoardName,
    );
    await outputDirectory.create(recursive: true);
    final indexNo = _nextAiEditedImageIndex(directories);
    final extension = p.extension(sourcePath).toLowerCase();
    final safeExtension = _isSupportedImage(sourcePath) ? extension : '.png';
    final fileName =
        '${indexNo.toString().padLeft(3, '0')}-$safeBoardName-AI修改$safeExtension';
    final target = File(p.join(outputDirectory.path, fileName));
    final source = File(sourcePath);
    if (_sameFilePath(source, target)) {
      return (path: target.path, indexNo: indexNo);
    }
    try {
      final moved = await source.rename(target.path);
      await _archiveImageMetadata(
        sourcePath: source.path,
        targetPath: moved.path,
      );
      return (path: moved.path, indexNo: indexNo);
    } on FileSystemException {
      final copied = await source.copy(target.path);
      try {
        await source.delete();
      } on FileSystemException {
        // 复制已成功时保留无法删除的源文件，不影响结果可用性。
      }
      await _archiveImageMetadata(
        sourcePath: source.path,
        targetPath: copied.path,
      );
      return (path: copied.path, indexNo: indexNo);
    }
  }

  Future<void> _archiveImageMetadata({
    required String sourcePath,
    required String targetPath,
  }) async {
    final source = File('$sourcePath.json');
    if (!source.existsSync()) {
      return;
    }
    final target = File('$targetPath.json');
    if (_sameFilePath(source, target)) {
      return;
    }
    try {
      await source.rename(target.path);
      return;
    } on FileSystemException {
      try {
        await source.copy(target.path);
      } on FileSystemException {
        // 元数据归档失败不应使已成功生成的图片失效。
        return;
      }
    }
    try {
      await source.delete();
    } on FileSystemException {
      // 复制已成功时保留无法删除的源元数据，不影响图片结果可用性。
    }
  }

  int _nextAiEditedImageIndex(WorkspaceDirectories directories) {
    var maxIndex = 0;
    for (final record in _database.listCutResults()) {
      if (!_isAiEditedAssetId(record.id)) {
        continue;
      }
      maxIndex = math.max(maxIndex, record.indexNo);
    }
    if (directories.generatedImages.existsSync()) {
      final sequencePattern = RegExp(r'^(\d+)-');
      final aiEditedDirectories = directories.generatedImages
          .listSync()
          .whereType<Directory>()
          .where(
            (directory) => p
                .basename(directory.path)
                .endsWith('-$_aiEditedImagesDirectorySuffix'),
          );
      for (final directory in aiEditedDirectories) {
        for (final file in directory.listSync().whereType<File>()) {
          final match = sequencePattern.firstMatch(p.basename(file.path));
          final parsed = match == null ? null : int.tryParse(match.group(1)!);
          if (parsed != null) {
            maxIndex = math.max(maxIndex, parsed);
          }
        }
      }
    }
    return maxIndex + 1;
  }

  String _safeFileNamePart(String name, {required String fallback}) {
    var result = name.trim();
    for (final char in const ['<', '>', ':', '"', '/', '\\', '|', '?', '*']) {
      result = result.replaceAll(char, '_');
    }
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    result = result.replaceAll(RegExp(r'[. ]+$'), '');
    if (result.length > 80) {
      result = result.substring(0, 80).replaceAll(RegExp(r'[. ]+$'), '');
    }
    return result.isEmpty ? fallback : result;
  }

  Future<({int width, int height})> _readImageSize(File file) async {
    if (!file.existsSync()) {
      return (width: 0, height: 0);
    }
    final bytes = await file.readAsBytes();
    final transferable = TransferableTypedData.fromList([bytes]);
    final size = await Isolate.run(() => _readImageSizeInWorker(transferable));
    return (width: size[0], height: size[1]);
  }

  bool _replaceCurrentItemAsset({
    required String boardId,
    required int slotIndex,
    required String oldAssetId,
    required StoryboardCutAsset replacement,
    String successMessage = '图片修改完成，已替换当前格',
    String changedMessage = '图片已生成，但当前格内容已变化，未自动替换',
  }) {
    StoryboardBoard? currentBoard;
    for (final board in value.boards) {
      if (board.id == boardId) {
        currentBoard = board;
        break;
      }
    }
    if (currentBoard == null) {
      _setBoardTaskMessage(boardId, '图片已生成，但当前画板已不存在');
      return false;
    }
    if (currentBoard.locked) {
      _setBoardTaskMessage(boardId, '${currentBoard.name} 已锁定，未自动替换');
      return false;
    }
    final itemIndex = currentBoard.items.indexWhere(
      (item) => item.slotIndex == slotIndex && item.asset.id == oldAssetId,
    );
    if (itemIndex < 0) {
      _setBoardTaskMessage(boardId, changedMessage);
      return false;
    }

    final nextItems = [...currentBoard.items];
    nextItems[itemIndex] = nextItems[itemIndex].copyWith(asset: replacement);
    final nextBoard = _boardWithAdaptiveHeight(
      currentBoard.copyWith(items: nextItems),
    );
    _recordBoardHistory(currentBoard);
    _setBoardTaskMessage(boardId, successMessage);
    _setState(
      value.copyWith(
        assets: [
          replacement,
          for (final asset in value.assets)
            if (asset.id != replacement.id) asset,
        ],
        boards: [
          for (final board in value.boards)
            if (board.id == boardId) nextBoard else board,
        ],
        message: value.selectedBoardId == boardId ? successMessage : null,
      ),
    );
    return true;
  }

  File _uniqueFile(Directory folder, String fileName) {
    final extension = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName).trim().isEmpty
        ? 'image'
        : p.basenameWithoutExtension(fileName).trim();
    var candidate = File(p.join(folder.path, '$baseName$extension'));
    var index = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(folder.path, '${baseName}_$index$extension'));
      index++;
    }
    return candidate;
  }

  String _uniqueFolderName(Directory root, String folderName) {
    var candidate = folderName;
    var index = 2;
    while (Directory(p.join(root.path, candidate)).existsSync()) {
      candidate = '${folderName}_$index';
      index++;
    }
    return candidate;
  }

  String _safeFolderName(String name) {
    var result = name.trim();
    for (final char in const ['<', '>', ':', '"', '/', '\\', '|', '?', '*']) {
      result = result.replaceAll(char, '_');
    }
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    result = result.replaceAll(RegExp(r'[. ]+$'), '');
    return result.isEmpty ? '自定义文件夹' : result;
  }

  bool _sameFilePath(File a, File b) {
    return _normalizedFilePath(a.path) == _normalizedFilePath(b.path);
  }

  String _normalizedFilePath(String path) {
    final normalized = p.normalize(File(path).absolute.path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _isSupportedImage(String path) {
    return const {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.bmp',
    }.contains(p.extension(path).toLowerCase());
  }

  String _assetRefreshMessage(
    List<StoryboardCutAsset> assets,
    List<StoryboardFolder> folders,
    int deleted,
    int cleanedEmptyDirectories,
  ) {
    final folderAssetCount = folders.fold<int>(
      0,
      (total, folder) => total + folder.assets.length,
    );
    if (assets.isEmpty && folderAssetCount == 0 && folders.isEmpty) {
      return '还没有裁切资源，请先导出多宫格图片';
    }
    final parts = [
      '已加载 ${assets.length} 张裁切图片',
      if (folders.isNotEmpty) '${folders.length} 个文件夹 / $folderAssetCount 张图片',
      if (deleted > 0) '已清理 $deleted 条失效记录',
      if (cleanedEmptyDirectories > 0) '已清理 $cleanedEmptyDirectories 个空文件夹',
    ];
    return parts.join('，');
  }

  ({List<StoryboardResourceGroup> groups, List<String> rootOrder})
  _normalizeResourceTree({
    required List<StoryboardResourceGroup> groups,
    required List<String> rootOrder,
    required List<StoryboardCutAsset> assets,
    required List<StoryboardFolder> folders,
  }) {
    final validAssetIds = {
      for (final asset in assets) asset.id,
      for (final folder in folders)
        for (final asset in folder.assets) asset.id,
    };
    final sourceImageIds = <String>[];
    final seenSourceImageIds = <String>{};
    for (final asset in assets) {
      if (seenSourceImageIds.add(asset.imageId)) {
        sourceImageIds.add(asset.imageId);
      }
    }
    final validSourceImageIds = sourceImageIds.toSet();
    final validFolderIds = {for (final folder in folders) folder.id};
    final seenGroupIds = <String>{};
    var normalizedGroups = <StoryboardResourceGroup>[];
    final claimedAssetIds = <String>{};
    final claimedSourceImageIds = <String>{};
    final claimedFolderIds = <String>{};
    for (final group in groups) {
      if (group.id.trim().isEmpty || !seenGroupIds.add(group.id)) {
        continue;
      }
      normalizedGroups.add(
        group.copyWith(
          assetIds: [
            for (final assetId in group.assetIds)
              if (validAssetIds.contains(assetId) &&
                  claimedAssetIds.add(assetId))
                assetId,
          ],
          sourceImageIds: [
            for (final sourceImageId in group.sourceImageIds)
              if (validSourceImageIds.contains(sourceImageId) &&
                  claimedSourceImageIds.add(sourceImageId))
                sourceImageId,
          ],
          folderIds: [
            for (final folderId in group.folderIds)
              if (validFolderIds.contains(folderId) &&
                  claimedFolderIds.add(folderId))
                folderId,
          ],
        ),
      );
    }

    final groupIds = normalizedGroups.map((group) => group.id).toSet();
    normalizedGroups = [
      for (final group in normalizedGroups)
        group.copyWith(
          parentGroupId:
              group.parentGroupId != null &&
                  group.parentGroupId != group.id &&
                  groupIds.contains(group.parentGroupId)
              ? group.parentGroupId
              : null,
        ),
    ];

    for (final group in [...normalizedGroups]) {
      final visited = <String>{group.id};
      var parentId = group.parentGroupId;
      var cyclic = false;
      while (parentId != null) {
        if (!visited.add(parentId)) {
          cyclic = true;
          break;
        }
        parentId = normalizedGroups
            .cast<StoryboardResourceGroup?>()
            .firstWhere(
              (candidate) => candidate?.id == parentId,
              orElse: () => null,
            )
            ?.parentGroupId;
      }
      if (cyclic) {
        normalizedGroups = [
          for (final candidate in normalizedGroups)
            if (candidate.id == group.id)
              candidate.copyWith(parentGroupId: null)
            else
              candidate,
        ];
      }
    }

    while (true) {
      final groupsWithChildren = {
        for (final group in normalizedGroups)
          if (group.parentGroupId != null) group.parentGroupId!,
      };
      final removableIds = {
        for (final group in normalizedGroups)
          if (group.isEmpty && !groupsWithChildren.contains(group.id)) group.id,
      };
      if (removableIds.isEmpty) {
        break;
      }
      normalizedGroups = [
        for (final group in normalizedGroups)
          if (!removableIds.contains(group.id)) group,
      ];
    }

    final retainedGroupIds = normalizedGroups.map((group) => group.id).toSet();
    normalizedGroups = [
      for (final group in normalizedGroups)
        group.copyWith(
          parentGroupId: retainedGroupIds.contains(group.parentGroupId)
              ? group.parentGroupId
              : null,
        ),
    ];
    final childGroupIdsByParent = <String, List<String>>{};
    for (final group in normalizedGroups) {
      final parentId = group.parentGroupId;
      if (parentId != null) {
        childGroupIdsByParent.putIfAbsent(parentId, () => []).add(group.id);
      }
    }
    normalizedGroups = [
      for (final group in normalizedGroups)
        group.copyWith(
          childOrder: _normalizedResourceOrder(group.childOrder, [
            for (final groupId in childGroupIdsByParent[group.id] ?? const [])
              StoryboardResourceNodeRef.group(groupId).key,
            for (final folderId in group.folderIds)
              StoryboardResourceNodeRef.folder(folderId).key,
            for (final sourceImageId in group.sourceImageIds)
              StoryboardResourceNodeRef.source(sourceImageId).key,
          ]),
        ),
    ];

    final retainedClaimedAssetIds = {
      for (final group in normalizedGroups) ...group.assetIds,
    };
    final retainedClaimedSourceIds = {
      for (final group in normalizedGroups) ...group.sourceImageIds,
    };
    final retainedClaimedFolderIds = {
      for (final group in normalizedGroups) ...group.folderIds,
    };
    final rootKeys = <String>[
      for (final group in normalizedGroups)
        if (group.parentGroupId == null)
          StoryboardResourceNodeRef.group(group.id).key,
      for (final folder in folders)
        if (!retainedClaimedFolderIds.contains(folder.id))
          StoryboardResourceNodeRef.folder(folder.id).key,
      for (final sourceImageId in sourceImageIds)
        if (!retainedClaimedSourceIds.contains(sourceImageId) &&
            assets.any(
              (asset) =>
                  asset.imageId == sourceImageId &&
                  !retainedClaimedAssetIds.contains(asset.id),
            ))
          StoryboardResourceNodeRef.source(sourceImageId).key,
    ];
    return (
      groups: normalizedGroups,
      rootOrder: _normalizedResourceOrder(rootOrder, rootKeys),
    );
  }

  List<String> _normalizedResourceOrder(
    Iterable<String> preferred,
    Iterable<String> valid,
  ) {
    final validKeys = valid.toSet();
    final result = <String>[];
    final seen = <String>{};
    for (final key in preferred) {
      if (validKeys.contains(key) && seen.add(key)) {
        result.add(key);
      }
    }
    for (final key in valid) {
      if (seen.add(key)) {
        result.add(key);
      }
    }
    return result;
  }

  bool _resourceNodeExists(
    StoryboardResourceNodeRef node,
    List<StoryboardResourceGroup> groups,
  ) {
    return switch (node.kind) {
      StoryboardResourceNodeKind.group => groups.any(
        (group) => group.id == node.id,
      ),
      StoryboardResourceNodeKind.folder => value.folders.any(
        (folder) => folder.id == node.id,
      ),
      StoryboardResourceNodeKind.source => value.assets.any(
        (asset) => asset.imageId == node.id,
      ),
    };
  }

  bool _isResourceGroupDescendant(
    String groupId, {
    required String ancestorGroupId,
    required List<StoryboardResourceGroup> groups,
  }) {
    final groupsById = {for (final group in groups) group.id: group};
    var currentId = groupId;
    final visited = <String>{};
    while (visited.add(currentId)) {
      final parentId = groupsById[currentId]?.parentGroupId;
      if (parentId == null) {
        return false;
      }
      if (parentId == ancestorGroupId) {
        return true;
      }
      currentId = parentId;
    }
    return true;
  }

  void _insertResourceNodeBefore(
    List<String> values,
    String value,
    String? beforeValue,
  ) {
    values.remove(value);
    final index = beforeValue == null ? -1 : values.indexOf(beforeValue);
    values.insert(index < 0 ? values.length : index, value);
  }

  List<String> _resourceOrderWithInsertedNode(
    List<String> values,
    String value,
    String? beforeValue,
  ) {
    final result = [...values];
    _insertResourceNodeBefore(result, value, beforeValue);
    return result;
  }

  StoryboardResourceGroup _resourceGroupWithout(
    StoryboardResourceGroup group, {
    required Set<String> assetIds,
    required Set<String> sourceImageIds,
    required Set<String> folderIds,
  }) {
    return group.copyWith(
      assetIds: [
        for (final assetId in group.assetIds)
          if (!assetIds.contains(assetId)) assetId,
      ],
      sourceImageIds: [
        for (final sourceImageId in group.sourceImageIds)
          if (!sourceImageIds.contains(sourceImageId)) sourceImageId,
      ],
      folderIds: [
        for (final folderId in group.folderIds)
          if (!folderIds.contains(folderId)) folderId,
      ],
      childOrder: [
        for (final key in group.childOrder)
          if (!sourceImageIds.contains(
                StoryboardResourceNodeRef.tryParse(key)?.id,
              ) &&
              !folderIds.contains(StoryboardResourceNodeRef.tryParse(key)?.id))
            key,
      ],
    );
  }

  String _uniqueResourceGroupName(String name, {String? excludingGroupId}) {
    final existingNames = value.resourceGroups
        .where((group) => group.id != excludingGroupId)
        .map((group) => group.name)
        .toSet();
    var candidate = name;
    var index = 2;
    while (existingNames.contains(candidate)) {
      candidate = '$name $index';
      index++;
    }
    return candidate;
  }

  int _cleanEmptyCutDirectories() {
    final cuts = _directories?.cuts;
    if (cuts == null) {
      return 0;
    }
    return const EmptyDirectoryCleaner().cleanChildren(cuts);
  }

  List<String> _rowCaptionsForRows(StoryboardBoard board, int rows) {
    return [
      for (var rowIndex = 0; rowIndex < rows; rowIndex++)
        rowIndex < board.rowCaptions.length ? board.rowCaptions[rowIndex] : '',
    ];
  }

  List<StoryboardItem> _orderedVisibleItems(StoryboardBoard board) {
    return [
      for (final item in board.items)
        if (item.slotIndex >= 0 && item.slotIndex < board.slotCount) item,
    ]..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
  }

  StoryboardBoard? _boardById(String boardId) {
    for (final board in value.boards) {
      if (board.id == boardId) {
        return board;
      }
    }
    return null;
  }

  bool _visionBatchMatchesCurrentItems(
    List<StoryboardItem> items,
    List<VisionAnalysisItemRecord> records,
  ) {
    if (items.length != records.length) {
      return false;
    }
    final assetIds = items.map((item) => item.asset.id).toSet();
    final recordIds = records.map((record) => record.cutResultId).toSet();
    return assetIds.length == items.length &&
        recordIds.length == records.length &&
        assetIds.containsAll(recordIds) &&
        recordIds.containsAll(assetIds);
  }

  Future<VisionAnalysisBatchRecord?> _visionOrderingBatchForBoard({
    required StoryboardBoard board,
    required List<StoryboardItem> orderedItems,
    required _VisionOperationToken operationToken,
  }) async {
    final existingBatch = _database.getLatestVisionAnalysisBatchForBoard(
      board.id,
    );
    if (_visionBatchReadyForOrdering(orderedItems, existingBatch)) {
      return existingBatch;
    }

    _setBoardTaskMessage(board.id, '正在补全专业视觉解析后自动重排序...');
    _database.deleteVisionAnalysisForBoard(board.id);
    await _analyzeBoardWithVision(
      boardId: board.id,
      operationToken: operationToken,
      triggeredByReorder: true,
    );
    if (_isVisionOperationCancelled(operationToken)) {
      return null;
    }

    final currentBoard = _boardById(board.id);
    if (currentBoard == null) {
      _setBoardTaskMessage(board.id, '目标画板已不存在，请重新自动重排序');
      return null;
    }
    final currentItems = _orderedVisibleItems(currentBoard);
    if (currentItems.length < 2) {
      _setBoardTaskMessage(board.id, '至少需要 2 张图片才能自动重排序');
      return null;
    }

    final refreshedBatch = _database.getLatestVisionAnalysisBatchForBoard(
      currentBoard.id,
    );
    if (_visionBatchReadyForOrdering(currentItems, refreshedBatch)) {
      return refreshedBatch;
    }
    if (refreshedBatch == null || refreshedBatch.items.isEmpty) {
      _setBoardTaskMessage(board.id, '自动重排序前解析失败，请检查视觉模型配置后重试');
      return null;
    }
    if (!_visionBatchMatchesCurrentItems(currentItems, refreshedBatch.items)) {
      _setBoardTaskMessage(board.id, '自动解析未完整覆盖当前画板图片，请重试自动重排序');
      return null;
    }
    _setBoardTaskMessage(board.id, '解析结果仍缺少专业排序维度，请重新自动解析后再重排序');
    return null;
  }

  Future<VisionAnalysisBatchRecord?> _visionPromptBatchForCurrentBoard({
    required StoryboardBoard board,
    required List<StoryboardItem> orderedItems,
    required _VisionOperationToken operationToken,
  }) async {
    final existingBatch = _database.getLatestVisionAnalysisBatchForBoard(
      board.id,
    );
    if (_visionBatchReadyForPrompt(orderedItems, existingBatch)) {
      return existingBatch;
    }

    _setBoardTaskMessage(board.id, '正在补全故事板视觉解析后生成自动提示词...');
    await _analyzeBoardWithVision(
      boardId: board.id,
      operationToken: operationToken,
      triggeredByPrompt: true,
    );
    if (_isVisionOperationCancelled(operationToken)) {
      return null;
    }

    final currentBoard = _boardById(board.id);
    if (currentBoard == null) {
      _setBoardTaskMessage(board.id, '目标画板已不存在，请重新生成自动提示词');
      return null;
    }
    final currentItems = _orderedVisibleItems(currentBoard);
    if (currentItems.isEmpty) {
      _setBoardTaskMessage(board.id, '当前画板没有可解析的图片');
      return null;
    }

    final refreshedBatch = _database.getLatestVisionAnalysisBatchForBoard(
      currentBoard.id,
    );
    if (_visionBatchReadyForPrompt(currentItems, refreshedBatch)) {
      return refreshedBatch;
    }
    if (refreshedBatch == null || refreshedBatch.items.isEmpty) {
      _setBoardTaskMessage(board.id, '自动提示词前解析失败，请检查视觉模型配置后重试');
      return null;
    }
    if (!_visionBatchMatchesCurrentItems(currentItems, refreshedBatch.items)) {
      _setBoardTaskMessage(board.id, '自动解析未完整覆盖当前画板图片，请重新生成自动提示词');
      return null;
    }
    _setBoardTaskMessage(board.id, '解析结果缺少多维度内容，请重新自动解析后再生成提示词');
    return null;
  }

  bool _visionBatchReadyForOrdering(
    List<StoryboardItem> items,
    VisionAnalysisBatchRecord? batch,
  ) {
    return batch != null &&
        batch.items.isNotEmpty &&
        _visionBatchMatchesCurrentItems(items, batch.items) &&
        _visionBatchHasOrderingCues(batch.items);
  }

  bool _visionBatchReadyForPrompt(
    List<StoryboardItem> items,
    VisionAnalysisBatchRecord? batch,
  ) {
    return batch != null &&
        batch.items.isNotEmpty &&
        _visionBatchMatchesCurrentItems(items, batch.items) &&
        _visionBatchHasPromptContext(batch.items);
  }

  bool _visionBatchHasOrderingCues(List<VisionAnalysisItemRecord> records) {
    return records.every((record) {
      return record.shotSize.trim().isNotEmpty ||
          record.composition.trim().isNotEmpty ||
          record.subjectDirection.trim().isNotEmpty ||
          record.gazeDirection.trim().isNotEmpty ||
          record.actionStage.trim().isNotEmpty ||
          record.spatialRelation.trim().isNotEmpty ||
          record.chronologyCue.trim().isNotEmpty ||
          record.visualFocus.trim().isNotEmpty ||
          record.narrativeFunction.trim().isNotEmpty ||
          record.transitionHint.trim().isNotEmpty;
    });
  }

  bool _visionBatchHasPromptContext(List<VisionAnalysisItemRecord> records) {
    return records.every((record) {
      final fields = [
        record.scene,
        record.props,
        record.people,
        record.expression,
        record.bodyAction,
        record.movementTrend,
        record.shotSize,
        record.composition,
        record.subjectDirection,
        record.gazeDirection,
        record.actionStage,
        record.spatialRelation,
        record.chronologyCue,
        record.cameraAngle,
        record.visualFocus,
        record.lightingMood,
        record.colorPalette,
        record.narrativeFunction,
        record.transitionHint,
      ];
      return record.detail.trim().isNotEmpty &&
          fields.any((field) => field.trim().isNotEmpty);
    });
  }

  List<_VisionAnalysisRecordItem> _visionRecordItemsInCurrentOrder(
    List<StoryboardItem> orderedItems,
    List<VisionAnalysisItemRecord> records,
  ) {
    final recordByAssetId = {
      for (final record in records) record.cutResultId: record,
    };
    final result = <_VisionAnalysisRecordItem>[];
    for (final item in orderedItems) {
      final record = recordByAssetId[item.asset.id];
      if (record == null) {
        continue;
      }
      result.add(
        _VisionAnalysisRecordItem(
          record: record,
          analysis: _analysisFromVisionRecord(record),
        ),
      );
    }
    return result;
  }

  StoryboardSummary _summaryForPrompt(
    StoryboardBoard board,
    List<VisionImageAnalysis> analyses,
  ) {
    final boardSummary = board.summary;
    if (boardSummary != null && !boardSummary.isEmpty) {
      return boardSummary;
    }
    final record = _database.getStoryboardSummary(board.id);
    if (record != null) {
      final summary = StoryboardSummary(
        outline: record.outline,
        content: record.content,
        scenes: record.scenes,
        props: record.props,
      );
      if (!summary.isEmpty) {
        return summary;
      }
    }
    return _fallbackSummaryForAnalyses(analyses);
  }

  String _storyboardSummaryText(StoryboardSummary summary) {
    return [
      if (summary.outline.trim().isNotEmpty) summary.outline.trim(),
      if (summary.content.trim().isNotEmpty) summary.content.trim(),
      if (summary.scenes.trim().isNotEmpty) '场景：${summary.scenes.trim()}',
      if (summary.props.trim().isNotEmpty) '道具：${summary.props.trim()}',
    ].join('\n');
  }

  bool _sameItemOrder(List<StoryboardItem> before, List<StoryboardItem> after) {
    if (before.length != after.length) {
      return false;
    }
    for (var i = 0; i < before.length; i++) {
      if (before[i].asset.id != after[i].asset.id) {
        return false;
      }
    }
    return true;
  }

  List<String> _emptyRowCaptions(int rows) {
    return [for (var rowIndex = 0; rowIndex < rows; rowIndex++) ''];
  }

  void _applyVisionResults({
    required String boardId,
    required List<_AnalyzedStoryboardItem> analyzedItems,
    required StoryboardSummary? summary,
    required String message,
  }) {
    StoryboardBoard? currentBoard;
    for (final board in value.boards) {
      if (board.id == boardId) {
        currentBoard = board;
        break;
      }
    }
    if (currentBoard == null) {
      _setBoardTaskMessage(boardId, message);
      return;
    }
    if (currentBoard.locked) {
      _setBoardTaskMessage(boardId, '${currentBoard.name} 已锁定，未写回解析文本');
      return;
    }
    final bySlot = {
      for (final item in analyzedItems) item.slotIndex: item.analysis,
    };
    final nextItems = [
      for (final item in currentBoard.items)
        item.copyWith(caption: bySlot[item.slotIndex]?.caption ?? item.caption),
    ];
    final rowCaptions = _rowCaptionsForRows(currentBoard, currentBoard.rows);
    if (currentBoard.rowDescriptionEnabled) {
      for (var rowIndex = 0; rowIndex < currentBoard.rows; rowIndex++) {
        final rowItems =
            analyzedItems.where((item) => item.rowIndex == rowIndex).toList()
              ..sort((a, b) => a.columnIndex.compareTo(b.columnIndex));
        rowCaptions[rowIndex] = composeVisionAnalysesDescription(
          rowItems.map((item) => item.analysis).toList(),
        );
      }
    }
    _setBoardTaskMessage(boardId, message);
    _replaceBoard(
      currentBoard.copyWith(
        items: nextItems,
        rowCaptions: rowCaptions,
        summary: summary,
      ),
      message: value.selectedBoardId == boardId ? message : null,
      selectBoard: value.selectedBoardId == currentBoard.id,
    );
  }

  VisionImageAnalysis _analysisFromVisionRecord(
    VisionAnalysisItemRecord record,
  ) {
    return VisionImageAnalysis(
      caption: normalizeVisionModelRoleTerms(record.caption),
      detail: normalizeVisionModelRoleTerms(record.detail),
      scene: normalizeVisionModelRoleTerms(record.scene),
      props: normalizeVisionModelRoleTerms(record.props),
      people: normalizeVisionModelRoleTerms(record.people),
      expression: normalizeVisionModelRoleTerms(record.expression),
      bodyAction: normalizeVisionModelRoleTerms(record.bodyAction),
      movementTrend: normalizeVisionModelRoleTerms(record.movementTrend),
      cameraMovement: normalizeVisionModelRoleTerms(record.cameraMovement),
      shotSize: normalizeVisionModelRoleTerms(record.shotSize),
      composition: normalizeVisionModelRoleTerms(record.composition),
      subjectDirection: normalizeVisionModelRoleTerms(record.subjectDirection),
      gazeDirection: normalizeVisionModelRoleTerms(record.gazeDirection),
      actionStage: normalizeVisionModelRoleTerms(record.actionStage),
      spatialRelation: normalizeVisionModelRoleTerms(record.spatialRelation),
      chronologyCue: normalizeVisionModelRoleTerms(record.chronologyCue),
      cameraAngle: normalizeVisionModelRoleTerms(record.cameraAngle),
      visualFocus: normalizeVisionModelRoleTerms(record.visualFocus),
      lightingMood: normalizeVisionModelRoleTerms(record.lightingMood),
      colorPalette: normalizeVisionModelRoleTerms(record.colorPalette),
      narrativeFunction: normalizeVisionModelRoleTerms(
        record.narrativeFunction,
      ),
      transitionHint: normalizeVisionModelRoleTerms(record.transitionHint),
      rawResponse: record.rawResponse,
    );
  }

  StoryboardSummary _fallbackSummaryForAnalyses(
    List<VisionImageAnalysis> analyses,
  ) {
    return StoryboardSummary(
      outline: composeVisionAnalysesOutline(analyses),
      content: composeVisionAnalysesDescription(analyses),
      scenes: _joinedUniqueVisionValues(analyses.map((item) => item.scene)),
      props: _joinedUniqueVisionValues(analyses.map((item) => item.props)),
    );
  }

  String _joinedUniqueVisionValues(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      for (final part in raw.split(RegExp(r'[、,，]'))) {
        final value = part.trim();
        if (value.isEmpty || !seen.add(value)) {
          continue;
        }
        result.add(value);
      }
    }
    return result.join('、');
  }

  String _visionReorderCompletionMessage({
    required bool moved,
    required String captionRewriteError,
    required int captionRewriteFallbackCount,
    required String summaryError,
  }) {
    const alreadyOptimalMessage = '分镜组合已是最优，无需重新排列';
    if (captionRewriteError.isEmpty &&
        captionRewriteFallbackCount == 0 &&
        summaryError.isEmpty) {
      return moved ? '自动重排序完成，已更新图片顺序' : alreadyOptimalMessage;
    }
    if (captionRewriteError.isEmpty &&
        captionRewriteFallbackCount > 0 &&
        summaryError.isEmpty) {
      const suffix = '连贯文本已自动恢复';
      return moved ? '自动重排序完成，$suffix' : '$alreadyOptimalMessage，$suffix';
    }
    if (captionRewriteError.isNotEmpty && summaryError.isNotEmpty) {
      return moved ? '自动重排序完成，文本和摘要更新失败' : '$alreadyOptimalMessage，但文本和摘要更新失败';
    }
    if (captionRewriteError.isNotEmpty) {
      return moved ? '自动重排序完成，文本连贯化失败' : '$alreadyOptimalMessage，但文本连贯化失败';
    }
    return moved ? '自动重排序完成，摘要生成失败' : '$alreadyOptimalMessage，但摘要生成失败';
  }

  String _visionCompletionMessage({
    required int totalCount,
    required int successCount,
    required int failedCount,
    required String captionRewriteError,
    required int captionRewriteFallbackCount,
    required String summaryError,
  }) {
    if (failedCount == 0 &&
        captionRewriteError.isEmpty &&
        captionRewriteFallbackCount == 0 &&
        summaryError.isEmpty) {
      return '故事板自动解析完成，已连贯填入 $totalCount 条描述';
    }
    if (failedCount == 0 &&
        captionRewriteError.isEmpty &&
        captionRewriteFallbackCount > 0 &&
        summaryError.isEmpty) {
      return '故事板自动解析完成，连贯文本已自动恢复';
    }
    if (failedCount == 0 && captionRewriteError.isNotEmpty) {
      return '故事板自动解析完成，连贯文本已自动恢复';
    }
    if (failedCount == 0 && summaryError.isNotEmpty) {
      return '解析完成，故事板概述生成失败';
    }
    return '解析完成：成功 $successCount 张，失败 $failedCount 张';
  }

  void _replaceBoard(
    StoryboardBoard board, {
    String? message,
    bool? isAnalyzing,
    bool? isCancellingAnalysis,
    int? reorderAnimationToken,
    bool saveWorkspace = true,
    bool selectBoard = true,
  }) {
    final nextBoard = _boardWithAdaptiveHeight(board);
    final previousBoard = value.boards.cast<StoryboardBoard?>().firstWhere(
      (item) => item?.id == nextBoard.id,
      orElse: () => null,
    );
    if (previousBoard != null &&
        !_sameBoardSnapshot(previousBoard, nextBoard)) {
      _recordBoardHistory(previousBoard);
    }
    _setState(
      value.copyWith(
        boards: [
          for (final item in value.boards)
            if (item.id == nextBoard.id) nextBoard else item,
        ],
        selectedBoardId: selectBoard ? nextBoard.id : value.selectedBoardId,
        message: message,
        isAnalyzing: isAnalyzing,
        isCancellingAnalysis:
            isCancellingAnalysis ?? (isAnalyzing == false ? false : null),
        reorderAnimationToken: reorderAnimationToken,
      ),
      saveWorkspace: saveWorkspace,
    );
  }

  bool _sameBoardSnapshot(StoryboardBoard first, StoryboardBoard second) {
    if (identical(first, second)) {
      return true;
    }
    return jsonEncode(_boardToJson(_compactBoardItems(first))) ==
        jsonEncode(_boardToJson(_compactBoardItems(second)));
  }

  void _recordBoardHistory(StoryboardBoard board) {
    _pushBoardHistory(_undoHistoryByBoardId, board);
    _redoHistoryByBoardId.remove(board.id);
  }

  void _pushBoardHistory(
    Map<String, List<StoryboardBoard>> histories,
    StoryboardBoard board,
  ) {
    final history = histories.putIfAbsent(board.id, () => <StoryboardBoard>[]);
    history.add(board);
    if (history.length > _historyLimit) {
      history.removeAt(0);
    }
  }

  void _restoreBoardFromHistory(
    StoryboardBoard board, {
    required String message,
  }) {
    _setState(
      value.copyWith(
        boards: [
          for (final item in value.boards)
            if (item.id == board.id) board else item,
        ],
        message: message,
      ),
    );
  }

  StoryboardBoard _boardWithAdaptiveHeight(StoryboardBoard board) {
    final compactBoard = _compactBoardItems(board);
    final normalizedBoard = compactBoard.portraitMode
        ? _boardWithGridForItemCount(
            compactBoard,
            itemCount: compactBoard.visibleItemCount,
          )
        : compactBoard;
    return normalizedBoard.withAdaptiveHeight();
  }

  int get _maxSlotCount => _maxAutomaticGridExtent * _maxAutomaticGridExtent;

  StoryboardBoard _boardWithGridForItemCount(
    StoryboardBoard board, {
    required int itemCount,
    int? configuredRows,
    int? configuredColumns,
  }) {
    if (board.portraitMode) {
      final portraitRows = itemCount.clamp(1, _maxSlotCount).toInt();
      return board.copyWith(
        rows: portraitRows,
        columns: 1,
        rowCaptions: _rowCaptionsForRows(board, portraitRows),
      );
    }
    final baseRows = (configuredRows ?? board.effectiveConfiguredRows)
        .clamp(1, _maxConfiguredGridExtent)
        .toInt();
    final baseColumns = (configuredColumns ?? board.effectiveConfiguredColumns)
        .clamp(1, _maxConfiguredGridExtent)
        .toInt();
    final grid = _gridForItemCount(
      configuredRows: baseRows,
      configuredColumns: baseColumns,
      itemCount: itemCount,
    );
    return board.copyWith(
      rows: grid.rows,
      columns: grid.columns,
      configuredRows: baseRows,
      configuredColumns: baseColumns,
      rowCaptions: _rowCaptionsForRows(board, grid.rows),
    );
  }

  ({int rows, int columns}) _gridForItemCount({
    required int configuredRows,
    required int configuredColumns,
    required int itemCount,
  }) {
    final safeRows = configuredRows.clamp(1, _maxConfiguredGridExtent).toInt();
    final safeColumns = configuredColumns
        .clamp(1, _maxConfiguredGridExtent)
        .toInt();
    final requiredCount = itemCount.clamp(0, _maxSlotCount).toInt();
    if (requiredCount <= safeRows * safeColumns) {
      return (rows: safeRows, columns: safeColumns);
    }

    final columnsForConfiguredRows = (requiredCount / safeRows).ceil();
    if (columnsForConfiguredRows <= _maxConfiguredGridExtent) {
      return (rows: safeRows, columns: columnsForConfiguredRows);
    }

    final targetAspect = safeRows / safeColumns;
    double? bestScore;
    var bestRows = safeRows;
    var bestColumns = safeColumns;
    var bestCapacity = _maxSlotCount + 1;
    for (var rows = 1; rows <= _maxAutomaticGridExtent; rows++) {
      for (var columns = 1; columns <= _maxAutomaticGridExtent; columns++) {
        final capacity = rows * columns;
        if (capacity < requiredCount) {
          continue;
        }
        final aspectPenalty =
            ((rows / columns) - targetAspect).abs() / targetAspect;
        final spareRatio = (capacity - requiredCount) / requiredCount;
        final distance =
            (rows - safeRows).abs() + (columns - safeColumns).abs();
        final score = aspectPenalty * 4 + spareRatio + distance * 0.02;
        final shouldReplace =
            bestScore == null ||
            score < bestScore - 0.0001 ||
            ((score - bestScore).abs() <= 0.0001 &&
                (capacity < bestCapacity ||
                    (capacity == bestCapacity && columns > bestColumns)));
        if (!shouldReplace) {
          continue;
        }
        bestScore = score;
        bestRows = rows;
        bestColumns = columns;
        bestCapacity = capacity;
      }
    }
    return (rows: bestRows, columns: bestColumns);
  }

  ({List<StoryboardBoard> boards, Set<String> deletedBoardIds})
  _reconcileBoardAssets(
    List<StoryboardBoard> boards,
    List<StoryboardCutAsset> assets,
    List<StoryboardFolder> folders,
    Set<String> validIds,
  ) {
    final assetsById = {
      for (final asset in assets) asset.id: asset,
      for (final folder in folders)
        for (final asset in folder.assets) asset.id: asset,
    };
    final availableSourceImageIds = {
      for (final asset in assets) asset.imageId,
      for (final folder in folders)
        for (final asset in folder.assets) asset.imageId,
    };
    final reconciledBoards = <StoryboardBoard>[];
    final deletedBoardIds = <String>{};
    for (final board in boards) {
      final autoSourceImageId = _autoGeneratedSourceImageId(board);
      if (autoSourceImageId != null &&
          !availableSourceImageIds.contains(autoSourceImageId)) {
        deletedBoardIds.add(board.id);
        continue;
      }
      reconciledBoards.add(
        _boardWithAdaptiveHeight(
          board.copyWith(
            items: [
              for (final item in board.items)
                if (validIds.contains(item.asset.id))
                  item.copyWith(
                    asset: assetsById[item.asset.id] ?? item.asset,
                    resourceRemoved: false,
                  )
                else
                  item.copyWith(resourceRemoved: true),
            ],
          ),
        ),
      );
    }
    return (boards: reconciledBoards, deletedBoardIds: deletedBoardIds);
  }

  String? _autoGeneratedSourceImageId(StoryboardBoard board) {
    final configuredSourceId = board.autoGeneratedSourceImageId?.trim();
    if (configuredSourceId != null && configuredSourceId.isNotEmpty) {
      return configuredSourceId;
    }
    const legacyPrefix = 'external-board:';
    if (!board.id.startsWith(legacyPrefix)) {
      return null;
    }
    final sourceId = board.id.substring(legacyPrefix.length).trim();
    return sourceId.isEmpty ? null : 'external-image:$sourceId';
  }

  List<String> _openBoardIdsAfterDeleting(Set<String> deletedBoardIds) {
    if (deletedBoardIds.isEmpty) {
      return value.openBoardIds;
    }
    return [
      for (final boardId in value.openBoardIds)
        if (!deletedBoardIds.contains(boardId)) boardId,
    ];
  }

  String? _selectedBoardIdAfterDeleting(Set<String> deletedBoardIds) {
    if (deletedBoardIds.isEmpty) {
      return value.selectedBoardId;
    }
    final nextOpenBoardIds = _openBoardIdsAfterDeleting(deletedBoardIds);
    final selectedBoardId = value.selectedBoardId;
    if (selectedBoardId != null && nextOpenBoardIds.contains(selectedBoardId)) {
      return selectedBoardId;
    }
    final selectedIndex = selectedBoardId == null
        ? 0
        : value.openBoardIds.indexOf(selectedBoardId);
    if (nextOpenBoardIds.isEmpty) {
      return null;
    }
    return nextOpenBoardIds[selectedIndex
        .clamp(0, nextOpenBoardIds.length - 1)
        .toInt()];
  }

  void _disposeDeletedBoards(Set<String> deletedBoardIds) {
    for (final boardId in deletedBoardIds) {
      _undoHistoryByBoardId.remove(boardId);
      _redoHistoryByBoardId.remove(boardId);
      _database.deleteVisionAnalysisForBoard(boardId);
    }
  }

  void _restoreWorkspaceOrCreateDefault() {
    final restored = _loadWorkspaceSnapshot();
    if (restored != null) {
      _setState(restored, saveWorkspace: false, saveSelection: false);
      return;
    }
    final board = _newBoard(1);
    _setState(
      value.copyWith(
        boards: [board],
        openBoardIds: [board.id],
        selectedBoardId: board.id,
        message: '已创建 ${board.name}',
      ),
    );
    flushWorkspaceSnapshot();
  }

  StoryboardBoard _newBoard(int index) {
    return StoryboardBoard(
      id: _uuid.v4(),
      name: '画板 $index',
      width: 1920,
      height: StoryboardBoard.heightForLayout(
        width: 1920,
        rows: 3,
        columns: 3,
        imageAspectRatio: projectImageAspectRatio,
      ),
      rows: 3,
      columns: 3,
      gap: 18,
      items: const [],
      rowCaptions: const ['', '', ''],
      imageAspectRatio: projectImageAspectRatio,
    );
  }

  String _uniqueBoardName(String requested) {
    final base = requested.trim().isEmpty ? '画板' : requested.trim();
    final usedNames = value.boards
        .map((board) => board.name.toLowerCase())
        .toSet();
    if (!usedNames.contains(base.toLowerCase())) {
      return base;
    }
    var suffix = 2;
    while (usedNames.contains('$base $suffix'.toLowerCase())) {
      suffix++;
    }
    return '$base $suffix';
  }

  void _setState(
    StoryboardState next, {
    bool saveWorkspace = true,
    bool saveSelection = true,
  }) {
    final selectionChanged = next.selectedBoardId != value.selectedBoardId;
    if (selectionChanged) {
      next = _withSelectedBoardTaskStatus(next);
    }
    value = next;
    if (saveWorkspace) {
      _workspaceSaveQueue.markDirty();
    }
    if (saveSelection && selectionChanged) {
      _selectionSaveQueue.markDirty();
    }
  }

  void _scheduleWorkspaceSnapshotSave({
    Duration delay = const Duration(milliseconds: 80),
  }) {
    _workspaceSaveQueue.markDirty(delay: delay);
  }

  void flushWorkspaceSnapshot() {
    _workspaceSaveQueue
      ..markDirty(delay: Duration.zero)
      ..flush();
    _selectionSaveQueue
      ..markDirty(delay: Duration.zero)
      ..flush();
  }

  StoryboardState? _loadWorkspaceSnapshot() {
    final raw = _database.getSetting(_workspaceSnapshotKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final boardValues = decoded['boards'];
      if (boardValues is! List) {
        return null;
      }
      final boards = <StoryboardBoard>[];
      for (final boardValue in boardValues) {
        final board = _boardFromJson(boardValue);
        if (board != null) {
          boards.add(board.withAdaptiveHeight());
        }
      }
      if (boardValues.isNotEmpty && boards.isEmpty) {
        return null;
      }
      final boardGroups = _boardGroupsFromJson(decoded['boardGroups']);
      final validGroupIds = boardGroups.map((group) => group.id).toSet();
      final normalizedBoards = [
        for (final board in boards)
          validGroupIds.contains(board.groupId)
              ? board
              : board.copyWith(groupId: null),
      ];
      final boardIds = normalizedBoards.map((board) => board.id).toSet();
      final storedOpenBoardIds = decoded['openBoardIds'];
      final openBoardIds = <String>[];
      if (storedOpenBoardIds is List) {
        for (final rawId in storedOpenBoardIds) {
          final id = rawId?.toString();
          if (id != null &&
              boardIds.contains(id) &&
              !openBoardIds.contains(id)) {
            openBoardIds.add(id);
          }
        }
      } else {
        openBoardIds.addAll(normalizedBoards.map((board) => board.id));
      }
      final lightweightSelection = _database.getSetting(_selectionStateKey);
      final selectedBoardId = lightweightSelection?.trim().isNotEmpty == true
          ? lightweightSelection
          : decoded['selectedBoardId']?.toString();
      final restoredSelectedBoardId =
          selectedBoardId != null && openBoardIds.contains(selectedBoardId)
          ? selectedBoardId
          : openBoardIds.isEmpty
          ? null
          : openBoardIds.first;
      return StoryboardState(
        assets: value.assets,
        folders: value.folders,
        resourceGroups: _resourceGroupsFromJson(decoded['resourceGroups']),
        resourceRootOrder: _jsonStringList(decoded['resourceRootOrder']),
        boards: normalizedBoards.map(_boardWithAdaptiveHeight).toList(),
        boardGroups: boardGroups,
        openBoardIds: openBoardIds,
        selectedBoardId: restoredSelectedBoardId,
        message: '已恢复上次画板状态',
        isAnalyzing: false,
        isCancellingAnalysis: false,
        isGeneratingImage: false,
        reorderAnimationToken: 0,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _workspaceSnapshotToJson(StoryboardState state) {
    return {
      'version': _workspaceSnapshotVersion,
      'selectedBoardId': state.selectedBoardId,
      'openBoardIds': state.openBoardIds,
      'boardGroups': [
        for (final group in state.boardGroups) _boardGroupToJson(group),
      ],
      'resourceGroups': [
        for (final group in state.resourceGroups) _resourceGroupToJson(group),
      ],
      'resourceRootOrder': state.resourceRootOrder,
      'boards': [
        for (final board in state.boards)
          _boardToJson(_compactBoardItems(board)),
      ],
    };
  }

  Map<String, Object?> _resourceGroupToJson(StoryboardResourceGroup group) {
    return {
      'id': group.id,
      'name': group.name,
      'assetIds': group.assetIds,
      'sourceImageIds': group.sourceImageIds,
      'folderIds': group.folderIds,
      'parentGroupId': group.parentGroupId,
      'childOrder': group.childOrder,
      'expanded': group.expanded,
    };
  }

  Map<String, Object?> _boardGroupToJson(StoryboardBoardGroup group) {
    return {'id': group.id, 'name': group.name};
  }

  Map<String, Object?> _boardToJson(StoryboardBoard board) {
    return {
      'id': board.id,
      'name': board.name,
      'width': board.width,
      'height': board.height,
      'rows': board.rows,
      'columns': board.columns,
      'configuredRows': board.configuredRows,
      'configuredColumns': board.configuredColumns,
      'gap': board.gap,
      'storyDescriptionEnabled': board.storyDescriptionEnabled,
      'rowDescriptionEnabled': board.rowDescriptionEnabled,
      'captionFontFamily': board.captionFontFamily,
      'captionFontSize': board.captionFontSize,
      'rowCaptions': board.rowCaptions,
      'rowDividerEnabled': board.rowDividerEnabled,
      'rowDividerStyle': board.rowDividerStyle.name,
      'rowDividerOpacity': board.rowDividerOpacity,
      'titleAlignment': board.titleAlignment.name,
      'portraitMode': board.portraitMode,
      'imageAspectRatio': board.imageAspectRatio,
      'locked': board.locked,
      'autoGeneratedSourceImageId': board.autoGeneratedSourceImageId,
      'groupId': board.groupId,
      'summary': board.summary == null
          ? null
          : {
              'outline': board.summary!.outline,
              'content': board.summary!.content,
              'scenes': board.summary!.scenes,
              'props': board.summary!.props,
            },
      'items': [for (final item in board.items) _itemToJson(item)],
    };
  }

  Map<String, Object?> _itemToJson(StoryboardItem item) {
    return {
      'caption': item.caption,
      'slotIndex': item.slotIndex,
      'flipHorizontal': item.flipHorizontal,
      'flipVertical': item.flipVertical,
      'resourceRemoved': item.resourceRemoved,
      'asset': {
        'id': item.asset.id,
        'imageId': item.asset.imageId,
        'sourceName': item.asset.sourceName,
        'path': _toStoredPath(item.asset.path),
        'indexNo': item.asset.indexNo,
      },
    };
  }

  StoryboardBoard? _boardFromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final portraitMode = _jsonBool(value['portraitMode'], false);
    final imageAspectRatio = _jsonDouble(
      value['imageAspectRatio'],
      projectImageAspectRatio,
    ).clamp(0.1, 10).toDouble();
    final rows = _jsonInt(
      value['rows'],
      3,
    ).clamp(1, portraitMode ? _maxSlotCount : _maxAutomaticGridExtent).toInt();
    final columns = _jsonInt(
      value['columns'],
      3,
    ).clamp(1, _maxAutomaticGridExtent).toInt();
    final configuredRows = _jsonNullableInt(
      value['configuredRows'],
    )?.clamp(1, _maxConfiguredGridExtent).toInt();
    final configuredColumns = _jsonNullableInt(
      value['configuredColumns'],
    )?.clamp(1, _maxConfiguredGridExtent).toInt();
    final rowCaptions = _jsonStringList(value['rowCaptions']);
    final items = _jsonItems(value['items']);
    final normalizedRows = portraitMode ? math.max(1, items.length) : rows;
    final normalizedColumns = portraitMode ? 1 : columns;
    final board = StoryboardBoard(
      id: _jsonString(value['id'], _uuid.v4()),
      name: _jsonString(value['name'], '画板'),
      width: _jsonInt(value['width'], 1920).clamp(320, 12000).toInt(),
      height: _jsonInt(
        value['height'],
        StoryboardBoard.heightForLayout(
          width: 1920,
          rows: rows,
          columns: columns,
          imageAspectRatio: imageAspectRatio,
        ),
      ),
      rows: normalizedRows,
      columns: normalizedColumns,
      gap: _jsonDouble(value['gap'], 18).clamp(0, 80).toDouble(),
      items: items,
      configuredRows: configuredRows ?? (portraitMode ? rows : null),
      configuredColumns: configuredColumns ?? (portraitMode ? columns : null),
      storyDescriptionEnabled: _jsonBool(
        value['storyDescriptionEnabled'],
        true,
      ),
      rowDescriptionEnabled: _jsonBool(value['rowDescriptionEnabled'], false),
      captionFontFamily: _jsonString(
        value['captionFontFamily'],
        'Microsoft YaHei UI',
      ),
      captionFontSize: _jsonDouble(
        value['captionFontSize'],
        12,
      ).clamp(12, 48).toDouble(),
      rowCaptions: [
        for (var rowIndex = 0; rowIndex < normalizedRows; rowIndex++)
          rowIndex < rowCaptions.length ? rowCaptions[rowIndex] : '',
      ],
      rowDividerEnabled: _jsonBool(value['rowDividerEnabled'], true),
      rowDividerStyle: StoryboardDividerStyle.values.firstWhere(
        (style) => style.name == value['rowDividerStyle']?.toString(),
        orElse: () => StoryboardDividerStyle.dashed,
      ),
      rowDividerOpacity: _jsonDouble(
        value['rowDividerOpacity'],
        0.35,
      ).clamp(0.05, 1.0).toDouble(),
      titleAlignment: StoryboardTitleAlignment.values.firstWhere(
        (alignment) => alignment.name == value['titleAlignment']?.toString(),
        orElse: () => StoryboardTitleAlignment.center,
      ),
      portraitMode: portraitMode,
      imageAspectRatio: imageAspectRatio,
      locked: _jsonBool(value['locked'], false),
      autoGeneratedSourceImageId: _jsonNullableString(
        value['autoGeneratedSourceImageId'],
      ),
      groupId: _jsonNullableString(value['groupId']),
      summary: _summaryFromJson(value['summary']),
    );
    return portraitMode ? board.withAdaptiveHeight() : board;
  }

  List<StoryboardItem> _jsonItems(Object? value) {
    if (value is! List) {
      return const [];
    }
    final items = <StoryboardItem>[];
    for (final itemValue in value) {
      final item = _itemFromJson(itemValue);
      if (item != null) {
        items.add(item);
      }
    }
    return items;
  }

  List<StoryboardResourceGroup> _resourceGroupsFromJson(Object? value) {
    if (value is! List) {
      return const [];
    }
    final groups = <StoryboardResourceGroup>[];
    for (final item in value) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final id = _jsonString(item['id'], '');
      final name = _jsonString(item['name'], '');
      if (id.isEmpty || name.trim().isEmpty) {
        continue;
      }
      final group = StoryboardResourceGroup(
        id: id,
        name: name,
        assetIds: _jsonStringList(item['assetIds']),
        sourceImageIds: _jsonStringList(item['sourceImageIds']),
        folderIds: _jsonStringList(item['folderIds']),
        parentGroupId: _jsonNullableString(item['parentGroupId']),
        childOrder: _jsonStringList(item['childOrder']),
        expanded: _jsonBool(item['expanded'], true),
      );
      groups.add(group);
    }
    return groups;
  }

  List<StoryboardBoardGroup> _boardGroupsFromJson(Object? value) {
    if (value is! List) {
      return const [];
    }
    final groups = <StoryboardBoardGroup>[];
    final usedNames = <String>{};
    for (final item in value) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final id = _jsonString(item['id'], '').trim();
      final name = _jsonString(item['name'], '').trim();
      final normalizedName = name.toLowerCase();
      if (id.isEmpty || name.isEmpty || usedNames.contains(normalizedName)) {
        continue;
      }
      usedNames.add(normalizedName);
      groups.add(StoryboardBoardGroup(id: id, name: name));
    }
    return groups;
  }

  StoryboardItem? _itemFromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final assetValue = value['asset'];
    if (assetValue is! Map<String, Object?>) {
      return null;
    }
    final assetId = _jsonString(assetValue['id'], '');
    final storedPath = _jsonString(assetValue['path'], '');
    final path = _toRuntimePath(storedPath);
    if (assetId.isEmpty || path.isEmpty) {
      return null;
    }
    return StoryboardItem(
      asset: StoryboardCutAsset(
        id: assetId,
        imageId: _jsonString(assetValue['imageId'], assetId),
        sourceName: _jsonString(assetValue['sourceName'], p.basename(path)),
        path: path,
        indexNo: _jsonInt(assetValue['indexNo'], 1),
      ),
      caption: _jsonString(value['caption'], ''),
      slotIndex: _jsonInt(value['slotIndex'], 0),
      flipHorizontal: _jsonBool(value['flipHorizontal'], false),
      flipVertical: _jsonBool(value['flipVertical'], false),
      resourceRemoved: _jsonBool(value['resourceRemoved'], false),
    );
  }

  String _toStoredPath(String path) {
    final resolver = _pathResolver;
    if (resolver == null || path.trim().isEmpty || !p.isAbsolute(path)) {
      return path;
    }
    try {
      return resolver.toStoredPath(path);
    } on ArgumentError {
      return path;
    }
  }

  String _toRuntimePath(String path) {
    final resolver = _pathResolver;
    if (resolver == null || path.trim().isEmpty || p.isAbsolute(path)) {
      return path;
    }
    return resolver.toRuntimePath(path);
  }

  StoryboardSummary? _summaryFromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      return null;
    }
    final summary = StoryboardSummary(
      outline: _jsonString(value['outline'], ''),
      content: _jsonString(value['content'], ''),
      scenes: _jsonString(value['scenes'], ''),
      props: _jsonString(value['props'], ''),
    );
    return summary.isEmpty ? null : summary;
  }

  StoryboardBoard _compactBoardItems(StoryboardBoard board) {
    final orderedItems = [
      for (final item in board.items)
        if (item.slotIndex >= 0 && item.slotIndex < board.slotCount) item,
    ]..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    final compactedItems = <StoryboardItem>[];
    for (final item in orderedItems) {
      if (compactedItems.length >= board.slotCount) {
        break;
      }
      compactedItems.add(item.copyWith(slotIndex: compactedItems.length));
    }
    return board.copyWith(items: compactedItems);
  }

  String _jsonString(Object? value, String fallback) {
    if (value is String) {
      return value;
    }
    return value?.toString() ?? fallback;
  }

  String? _jsonNullableString(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
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

  int? _jsonNullableInt(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value.toString());
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

  List<String> _jsonStringList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return [for (final item in value) item?.toString() ?? ''];
  }
}

typedef _AssetFileSignature = ({
  String sourceId,
  int size,
  int modifiedMicroseconds,
});

class _AssetScanEntry {
  const _AssetScanEntry({required this.id, required this.path});

  final String id;
  final String path;
}

class _AssetScanRequest {
  const _AssetScanRequest({
    required this.cutResults,
    required this.storyboardFoldersPath,
    required this.storyDesignImagesPath,
    required this.cutsPath,
  });

  final List<_AssetScanEntry> cutResults;
  final String? storyboardFoldersPath;
  final String? storyDesignImagesPath;
  final String? cutsPath;
}

class _ScannedStoryboardFolder {
  const _ScannedStoryboardFolder({
    required this.id,
    required this.name,
    required this.path,
    required this.files,
  });

  final String id;
  final String name;
  final String path;
  final List<String> files;
}

class _AssetScanResult {
  const _AssetScanResult({
    required this.missingIds,
    required this.folders,
    required this.fileSignatures,
    required this.cleanedEmptyDirectories,
  });

  final List<String> missingIds;
  final List<_ScannedStoryboardFolder> folders;
  final Map<String, _AssetFileSignature> fileSignatures;
  final int cleanedEmptyDirectories;
}

_AssetScanResult _scanStoryboardAssets(_AssetScanRequest request) {
  final missingIds = <String>[];
  final fileSignatures = <String, _AssetFileSignature>{};
  for (final entry in request.cutResults) {
    final signature = _readAssetFileSignature(entry.path, entry.id);
    if (signature == null) {
      missingIds.add(entry.id);
    } else {
      fileSignatures[entry.path] = signature;
    }
  }

  final folders = <_ScannedStoryboardFolder>[];
  final foldersPath = request.storyboardFoldersPath;
  if (foldersPath != null) {
    final root = Directory(foldersPath);
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    final directories = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final directory in directories) {
      final folderName = p.basename(directory.path);
      final files =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => _isSupportedStoryboardImage(file.path))
              .toList()
            ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      final paths = <String>[];
      for (final file in files) {
        final fileName = p.basename(file.path);
        final sourceId = 'folder:$folderName:$fileName';
        final signature = _readAssetFileSignature(file.path, sourceId);
        if (signature == null) {
          continue;
        }
        paths.add(file.path);
        fileSignatures[file.path] = signature;
      }
      folders.add(
        _ScannedStoryboardFolder(
          id: folderName,
          name: folderName,
          path: directory.path,
          files: paths,
        ),
      );
    }
  }

  final designPath = request.storyDesignImagesPath;
  if (designPath != null) {
    final designDirectory = Directory(designPath);
    if (designDirectory.existsSync()) {
      final files =
          designDirectory
              .listSync(followLinks: false)
              .whereType<File>()
              .where((file) => _isSupportedStoryboardImage(file.path))
              .toList()
            ..sort(
              (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
            );
      final paths = <String>[];
      for (final file in files) {
        final fileName = p.basename(file.path);
        final sourceId = 'folder:$_storyDesignFolderId:$fileName';
        final signature = _readAssetFileSignature(file.path, sourceId);
        if (signature == null) {
          continue;
        }
        paths.add(file.path);
        fileSignatures[file.path] = signature;
      }
      if (paths.isNotEmpty) {
        folders.insert(
          0,
          _ScannedStoryboardFolder(
            id: _storyDesignFolderId,
            name: _storyDesignFolderName,
            path: designDirectory.path,
            files: paths,
          ),
        );
      }
    }
  }

  final cutsPath = request.cutsPath;
  final cleanedEmptyDirectories = cutsPath == null
      ? 0
      : const EmptyDirectoryCleaner().cleanChildren(Directory(cutsPath));
  return _AssetScanResult(
    missingIds: missingIds,
    folders: folders,
    fileSignatures: fileSignatures,
    cleanedEmptyDirectories: cleanedEmptyDirectories,
  );
}

_AssetFileSignature? _readAssetFileSignature(String path, String sourceId) {
  try {
    final stat = File(path).statSync();
    if (stat.type != FileSystemEntityType.file) {
      return null;
    }
    return (
      sourceId: sourceId,
      size: stat.size,
      modifiedMicroseconds: stat.modified.microsecondsSinceEpoch,
    );
  } on FileSystemException {
    return null;
  }
}

bool _isSupportedStoryboardImage(String path) {
  return const {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
  }.contains(p.extension(path).toLowerCase());
}

@visibleForTesting
Set<String> changedStoryboardAssetImagePaths<T>(
  Map<String, T> previous,
  Map<String, T> current,
) {
  return {
    for (final path in {...previous.keys, ...current.keys})
      if (previous[path] != current[path]) path,
  };
}

List<int> _readImageSizeInWorker(TransferableTypedData transferable) {
  try {
    final bytes = transferable.materialize().asUint8List();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return const [0, 0];
    }
    return [decoded.width, decoded.height];
  } catch (_) {
    return const [0, 0];
  }
}

class _PreparedImageReplacementTask {
  const _PreparedImageReplacementTask({
    required this.generationId,
    required this.boardId,
    required this.boardName,
    required this.slotIndex,
    required this.sourceAsset,
    required this.model,
    required this.prompt,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.referenceImagePaths,
    required this.successMessage,
    required this.changedMessage,
  });

  final String generationId;
  final String boardId;
  final String boardName;
  final int slotIndex;
  final StoryboardCutAsset sourceAsset;
  final String model;
  final String prompt;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final List<String> referenceImagePaths;
  final String successMessage;
  final String changedMessage;
}

class _AnalyzedStoryboardItem {
  const _AnalyzedStoryboardItem({
    required this.slotIndex,
    required this.rowIndex,
    required this.columnIndex,
    required this.analysis,
  });

  final int slotIndex;
  final int rowIndex;
  final int columnIndex;
  final VisionImageAnalysis analysis;

  _AnalyzedStoryboardItem copyWith({VisionImageAnalysis? analysis}) {
    return _AnalyzedStoryboardItem(
      slotIndex: slotIndex,
      rowIndex: rowIndex,
      columnIndex: columnIndex,
      analysis: analysis ?? this.analysis,
    );
  }
}

class _VisionAnalysisRecordItem {
  const _VisionAnalysisRecordItem({
    required this.record,
    required this.analysis,
  });

  final VisionAnalysisItemRecord record;
  final VisionImageAnalysis analysis;

  _VisionAnalysisRecordItem copyWith({VisionImageAnalysis? analysis}) {
    return _VisionAnalysisRecordItem(
      record: record,
      analysis: analysis ?? this.analysis,
    );
  }
}

class _QueuedVisionTask {
  _QueuedVisionTask(this.task);

  final StoryboardVisionTask task;
  final Completer<void> completer = Completer<void>();
}

class _BoardVisionTaskChannel {
  final queue = <_QueuedVisionTask>[];
  _QueuedVisionTask? activeTask;
  bool isRunning = false;
  bool isCancelling = false;
}

class _VisionOperationToken {
  const _VisionOperationToken({
    required this.boardId,
    required this.generation,
  });

  final String boardId;
  final int generation;
}
