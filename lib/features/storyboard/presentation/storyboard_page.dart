import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../../../core/widgets/desktop_drop_target_scope.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../../core/widgets/image_file_context_menu.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../../core/widgets/value_listenable_selector_builder.dart';
import '../../../core/widgets/viewport_lazy_grid.dart';
import '../../exporter/data/storyboard_export_service.dart';
import '../../bridge/data/bridge_loopback_client.dart';
import '../../bridge/data/bridge_loopback_receiver.dart';
import '../../bridge/data/bridge_package_service.dart';
import '../../bridge/domain/bridge_manifest.dart';
import '../../settings/domain/app_settings.dart';
import '../../settings/presentation/cut_image_number_controls.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../application/storyboard_controller.dart';
import '../data/image_generation_service.dart';
import '../data/storyboard_image_edit_preferences_repository.dart';
import '../domain/storyboard_canvas_style.dart';
import '../domain/storyboard_models.dart';
import 'widgets/board_manager_dialog.dart';
import 'widgets/image_generation_model_selector.dart';

enum _StoryboardInspectorSection {
  analysis,
  aspectExpansion,
  lineArt,
  redraw,
  number,
  layout,
  size,
  spacing,
  descriptions,
  typography,
}

enum _ResourceContextAction { toggleUse, createGroup }

enum _FolderContextAction { openDirectory, deleteFolder }

enum _ResourceGroupContextAction { rename }

const _replacementImageTypeGroup = XTypeGroup(
  label: '图片',
  extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
);

final _storyboardTilePointerDowns =
    <int, ({String assetId, Offset position})>{};
final _storyboardTileTapStamps = <String, ({DateTime time, Offset position})>{};

bool _isReplacementImagePath(String path) => const {
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
}.contains(p.extension(path).toLowerCase());

StoryboardState _storyboardState(StoryboardState state) => state;

bool _sameBoardBarState(StoryboardState previous, StoryboardState next) {
  if (previous.selectedBoardId != next.selectedBoardId ||
      !listEquals(previous.openBoardIds, next.openBoardIds)) {
    return false;
  }
  final previousBoards = previous.openBoards;
  final nextBoards = next.openBoards;
  if (previousBoards.length != nextBoards.length) {
    return false;
  }
  for (var index = 0; index < previousBoards.length; index++) {
    final oldBoard = previousBoards[index];
    final newBoard = nextBoards[index];
    if (oldBoard.id != newBoard.id || oldBoard.name != newBoard.name) {
      return false;
    }
  }
  return true;
}

bool _sameAssetSidebarState(StoryboardState previous, StoryboardState next) {
  return identical(previous.assets, next.assets) &&
      identical(previous.folders, next.folders) &&
      identical(previous.resourceGroups, next.resourceGroups) &&
      listEquals(previous.resourceRootOrder, next.resourceRootOrder) &&
      previous.selectedBoardId == next.selectedBoardId &&
      _sameUsedAssetIds(previous.selectedBoard, next.selectedBoard);
}

bool _sameUsedAssetIds(StoryboardBoard? previous, StoryboardBoard? next) {
  if (identical(previous?.items, next?.items)) {
    return true;
  }
  final previousIds =
      previous?.items.map((item) => item.asset.id).toSet() ?? {};
  final nextIds = next?.items.map((item) => item.asset.id).toSet() ?? {};
  return previousIds.length == nextIds.length &&
      previousIds.containsAll(nextIds);
}

bool _sameStoryboardCanvasState(
  StoryboardState previous,
  StoryboardState next,
) {
  return identical(previous.selectedBoard, next.selectedBoard) &&
      previous.message == next.message &&
      previous.reorderAnimationToken == next.reorderAnimationToken;
}

bool _sameStoryboardInspectorState(
  StoryboardState previous,
  StoryboardState next,
) {
  return identical(previous.selectedBoard, next.selectedBoard) &&
      previous.isAnalyzing == next.isAnalyzing &&
      previous.isCancellingAnalysis == next.isCancellingAnalysis &&
      previous.isGeneratingImage == next.isGeneratingImage &&
      previous.activeVisionBoardId == next.activeVisionBoardId &&
      previous.activeVisionTaskKind == next.activeVisionTaskKind &&
      identical(previous.queuedVisionTasks, next.queuedVisionTasks);
}

class StoryboardPage extends ConsumerStatefulWidget {
  const StoryboardPage({
    super.key,
    this.fileExplorerService = const FileExplorerService(),
  });

  final FileExplorerService fileExplorerService;

  @override
  ConsumerState<StoryboardPage> createState() => _StoryboardPageState();
}

class _StoryboardFolderDropScope
    extends InheritedNotifier<_StoryboardFolderDropCoordinator> {
  const _StoryboardFolderDropScope({
    required _StoryboardFolderDropCoordinator coordinator,
    required super.child,
  }) : super(notifier: coordinator);

  static _StoryboardFolderDropCoordinator? maybeOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<_StoryboardFolderDropScope>()
          ?.notifier;
}

class _StoryboardFolderDropCoordinator extends ChangeNotifier {
  final _targets = <String, _StoryboardFolderDropTarget>{};
  List<StoryboardCutAsset> _assets = const [];
  Offset? _globalPosition;
  String? _hoveredFolderId;

  String? get hoveredFolderId => _hoveredFolderId;

  void registerTarget({
    required String folderId,
    required bool Function(Offset globalPosition) contains,
    required void Function(List<StoryboardCutAsset> assets) onDrop,
  }) {
    _targets[folderId] = _StoryboardFolderDropTarget(
      contains: contains,
      onDrop: onDrop,
    );
    final position = _globalPosition;
    if (position != null) {
      _resolveHoveredFolder(position);
    }
  }

  void unregisterTarget(String folderId) {
    _targets.remove(folderId);
    if (_hoveredFolderId == folderId) {
      _setHoveredFolder(null);
    }
  }

  void begin({
    required Iterable<StoryboardCutAsset> assets,
    required Offset globalPosition,
  }) {
    _assets = List<StoryboardCutAsset>.unmodifiable(assets);
    _globalPosition = globalPosition;
    _resolveHoveredFolder(globalPosition);
  }

  void update(Offset globalPosition) {
    if (_assets.isEmpty) return;
    _globalPosition = globalPosition;
    _resolveHoveredFolder(globalPosition);
  }

  bool complete() {
    final folderId = _hoveredFolderId;
    final target = folderId == null ? null : _targets[folderId];
    final assets = _assets;
    _reset();
    if (target == null || assets.isEmpty) {
      return false;
    }
    target.onDrop(assets);
    return true;
  }

  void cancel() => _reset();

  void _resolveHoveredFolder(Offset globalPosition) {
    String? nextFolderId;
    for (final entry in _targets.entries) {
      if (entry.value.contains(globalPosition)) {
        nextFolderId = entry.key;
        break;
      }
    }
    _setHoveredFolder(nextFolderId);
  }

  void _setHoveredFolder(String? folderId) {
    if (_hoveredFolderId == folderId) return;
    _hoveredFolderId = folderId;
    notifyListeners();
  }

  void _reset() {
    final hadHover = _hoveredFolderId != null;
    _assets = const [];
    _globalPosition = null;
    _hoveredFolderId = null;
    if (hadHover) {
      notifyListeners();
    }
  }
}

class _StoryboardFolderDropTarget {
  const _StoryboardFolderDropTarget({
    required this.contains,
    required this.onDrop,
  });

  final bool Function(Offset globalPosition) contains;
  final void Function(List<StoryboardCutAsset> assets) onDrop;
}

class _StoryboardPageState extends ConsumerState<StoryboardPage> {
  static const _minAssetSidebarWidth = 220.0;
  static const _maxAssetSidebarWidth = 720.0;
  static const _collapsedAssetSidebarWidth = 44.0;
  static const _uiStateKey = 'storyboardPageUiState';

  double _assetSidebarWidth = 260;
  bool _assetSidebarExpanded = true;
  bool _inspectorExpanded = false;
  bool _showOriginalStoryboard = false;
  final _assetSidebarKey = GlobalKey<_AssetSidebarState>();
  final _folderDropCoordinator = _StoryboardFolderDropCoordinator();
  final _expandedInspectorSections = <_StoryboardInspectorSection>{};
  BridgeLoopbackReceiver? _bridgeLoopbackReceiver;

  @override
  void initState() {
    super.initState();
    // 双击检测状态只属于当前故事板页面，避免测试/页面重建后复用旧点击记录。
    _storyboardTilePointerDowns.clear();
    _storyboardTileTapStamps.clear();
    _restoreUiState();
    unawaited(_startBridgeLoopbackReceiver());
  }

  @override
  void dispose() {
    _storyboardTilePointerDowns.clear();
    _storyboardTileTapStamps.clear();
    _folderDropCoordinator.dispose();
    unawaited(_bridgeLoopbackReceiver?.stop());
    super.dispose();
  }

  Future<void> _startBridgeLoopbackReceiver() async {
    try {
      final directories = ref.read(projectDirectoriesProvider);
      final receiver = BridgeLoopbackReceiver(
        directory: directories.temp,
        onPackage: (file) async {
          final result = await _applyShiyinBridgeFile(file);
          return {
            'board_id': result.manifest.bridgeId,
            'frame_count': result.frames.length,
          };
        },
      );
      await receiver.start();
      if (mounted) {
        _bridgeLoopbackReceiver = receiver;
      } else {
        await receiver.stop();
      }
    } catch (_) {
      // 端口被占用时保留文件导入，不影响故事板页面其他功能。
    }
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('storyboard.page');
    final controller = ref.watch(storyboardControllerProvider);
    void createBoardWithShootingScript() {
      final board = controller.addBoard();
      ref.read(shootingScriptControllerProvider).createForStoryboard(board);
    }

    void duplicateBoardWithShootingScript() {
      final board = controller.duplicateSelectedBoard();
      if (board != null) {
        ref.read(shootingScriptControllerProvider).createForStoryboard(board);
      }
    }

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          ValueListenableSelectorBuilder<StoryboardState, StoryboardState>(
            valueListenable: controller,
            selector: _storyboardState,
            equals: _sameBoardBarState,
            builder: (context, state, _) => _BoardBar(
              state: state,
              onSelect: controller.selectBoard,
              onAdd: createBoardWithShootingScript,
              onDuplicate: duplicateBoardWithShootingScript,
              onManage: () => showBoardManagerDialog(
                context: context,
                controller: controller,
              ),
              onClose: controller.closeBoard,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sidebarWidth = _assetSidebarExpanded
                    ? _effectiveAssetSidebarWidth(constraints.maxWidth)
                    : _collapsedAssetSidebarWidth;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CollapsiblePanelRegistration(
                      expanded: _assetSidebarExpanded,
                      onExpandedChanged: _setAssetSidebarExpanded,
                      child: const SizedBox.shrink(),
                    ),
                    SizedBox(
                      key: const ValueKey('storyboard-asset-sidebar-container'),
                      width: sidebarWidth,
                      child: _assetSidebarExpanded
                          ? ValueListenableSelectorBuilder<
                              StoryboardState,
                              StoryboardState
                            >(
                              valueListenable: controller,
                              selector: _storyboardState,
                              equals: _sameAssetSidebarState,
                              builder: (context, state, _) => _AssetSidebar(
                                key: _assetSidebarKey,
                                state: state,
                                onRefresh: controller.refreshAssets,
                                onToggleAsset: controller.addOrRemoveAsset,
                                onSetAssetsUsed: controller.setAssetsUsed,
                                onRemoveAsset: controller.removeAsset,
                                onDeleteGroup: controller.deleteAssetGroup,
                                onDeleteFolderAsset:
                                    controller.deleteFolderAsset,
                                onOpenFolderDirectory:
                                    _openAssetFolderDirectory,
                                onDeleteFolder: (folder) =>
                                    _confirmDeleteAssetFolder(
                                      controller,
                                      folder,
                                    ),
                                onCreateFolder: controller.createFolder,
                                onCopyAssetToFolder: (asset, folderId) =>
                                    controller.copyAssetToFolder(
                                      asset: asset,
                                      folderId: folderId,
                                    ),
                                onCopyPathsToFolder: (paths, folderId) =>
                                    controller.copyPathsToFolder(
                                      paths: paths,
                                      folderId: folderId,
                                    ),
                                onCreateResourceGroup:
                                    ({
                                      required name,
                                      assetIds = const [],
                                      sourceImageIds = const [],
                                      folderIds = const [],
                                    }) => controller.createResourceGroup(
                                      name: name,
                                      assetIds: assetIds,
                                      sourceImageIds: sourceImageIds,
                                      folderIds: folderIds,
                                    ),
                                onToggleResourceGroupExpanded:
                                    controller.toggleResourceGroupExpanded,
                                onMoveResourceNode: controller.moveResourceNode,
                                onRenameResourceGroup:
                                    controller.renameResourceGroup,
                                onCollapse: () =>
                                    _setAssetSidebarExpanded(false),
                              ),
                            )
                          : _CollapsedAssetSidebarRail(
                              onExpand: () => _setAssetSidebarExpanded(true),
                            ),
                    ),
                    if (_assetSidebarExpanded)
                      _SidebarResizeHandle(
                        onDragStart: () =>
                            _beginAssetSidebarResize(sidebarWidth),
                        onDragDelta: (delta) => _setAssetSidebarWidth(
                          _assetSidebarWidth + delta,
                          save: false,
                        ),
                        onDragEnd: _saveUiState,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child:
                          ValueListenableSelectorBuilder<
                            StoryboardState,
                            StoryboardState
                          >(
                            valueListenable: controller,
                            selector: _storyboardState,
                            equals: _sameStoryboardCanvasState,
                            builder: (context, state, _) => _StoryboardCanvas(
                              state: state,
                              onManageBoards: () => showBoardManagerDialog(
                                context: context,
                                controller: controller,
                              ),
                              onAddBoard: createBoardWithShootingScript,
                              canUndo: controller.canUndoSelectedBoard,
                              canRedo: controller.canRedoSelectedBoard,
                              onUndo: controller.undoSelectedBoard,
                              onRedo: controller.redoSelectedBoard,
                              onToggleLock: controller.toggleSelectedBoardLock,
                              onMove: controller.moveItem,
                              onMoveItems: controller.moveItems,
                              onPlaceAsset: controller.placeAssetAtSlot,
                              onRemove: controller.removeAsset,
                              onFlipHorizontal:
                                  controller.toggleItemFlipHorizontal,
                              onFlipVertical: controller.toggleItemFlipVertical,
                              onEditImage: (item) =>
                                  _showImageEditDialog(controller, item),
                              onLocateAsset: (item) => unawaited(
                                _locateAssetInSidebar(controller, item.asset),
                              ),
                              onPickReplacementImage: (item) => unawaited(
                                _pickReplacementImage(controller, item),
                              ),
                              onDropReplacementImages: (item, paths) =>
                                  unawaited(
                                    _replaceWithDroppedImage(
                                      controller,
                                      item,
                                      paths,
                                    ),
                                  ),
                              onCaptionChanged: controller.updateCaption,
                              onRowCaptionChanged: controller.updateRowCaption,
                              showOriginalStoryboard: _showOriginalStoryboard,
                              originalPathForItem:
                                  controller.originalImagePathForItem,
                              onCompareImage: (item) =>
                                  _showImageComparisonDialog(controller, item),
                            ),
                          ),
                    ),
                    const SizedBox(width: 12),
                    CollapsiblePanelRegistration(
                      expanded: _inspectorExpanded,
                      onExpandedChanged: _setInspectorExpanded,
                      child: const SizedBox.shrink(),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: _inspectorExpanded ? 310 : 44,
                      child: _inspectorExpanded
                          ? ValueListenableSelectorBuilder<
                              StoryboardState,
                              StoryboardState
                            >(
                              valueListenable: controller,
                              selector: _storyboardState,
                              equals: _sameStoryboardInspectorState,
                              builder: (context, state, _) =>
                                  _StoryboardInspector(
                                    controller: controller,
                                    expandedSections:
                                        _expandedInspectorSections,
                                    onToggleSection: _toggleInspectorSection,
                                    onExportBoardImages: _exportBoardImages,
                                    onExportShiyinBridge: _exportShiyinBridge,
                                    onImportShiyinBridge: _importShiyinBridge,
                                    showOriginalStoryboard:
                                        _showOriginalStoryboard,
                                    canShowOriginalStoryboard:
                                        state.selectedBoard?.items.any(
                                          (item) =>
                                              controller
                                                  .originalImagePathForItem(
                                                    item,
                                                  )
                                                  ?.isNotEmpty ==
                                              true,
                                        ) ??
                                        false,
                                    onToggleOriginalStoryboard: (value) =>
                                        setState(
                                          () => _showOriginalStoryboard = value,
                                        ),
                                    onCollapse: () =>
                                        _setInspectorExpanded(false),
                                  ),
                            )
                          : _CollapsedInspectorRail(
                              onExpand: () => _setInspectorExpanded(true),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            controller.undoSelectedBoard,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): controller.redoSelectedBoard,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            controller.redoSelectedBoard,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            controller.closeSelectedBoard,
        const SingleActivator(LogicalKeyboardKey.tab, control: true):
            controller.selectNextOpenBoard,
      },
      child: _StoryboardFolderDropScope(
        coordinator: _folderDropCoordinator,
        child: Focus(autofocus: true, child: content),
      ),
    );
  }

  Future<void> _showImageEditDialog(
    StoryboardController controller,
    StoryboardItem item,
  ) async {
    final settings = ref.read(settingsControllerProvider).value;
    StoryboardImageEditPreferencesRepository? preferencesRepository;
    var preferences = StoryboardImageEditPreferences(
      model: settings.imageGenerationModel,
      aspectRatio: 'auto',
      imageSize: '1K',
    );
    try {
      preferencesRepository = StoryboardImageEditPreferencesRepository(
        ref.read(appDatabaseProvider),
      );
      preferences = preferencesRepository.load(
        fallbackModel: settings.imageGenerationModel,
      );
      if (!ImageGenerationModelCatalog.values.contains(preferences.model)) {
        preferences = StoryboardImageEditPreferences(
          model: settings.imageGenerationModel,
          aspectRatio: preferences.aspectRatio,
          imageSize: preferences.imageSize,
        );
      }
    } catch (_) {
      // 组件测试或预览环境可能没有注入数据库，生产环境会正常持久化。
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return _ImageEditDialog(
          controller: controller,
          item: item,
          initialModel: preferences.model,
          initialAspectRatio: preferences.aspectRatio,
          initialImageSize: preferences.imageSize,
          onPreferencesChanged: preferencesRepository?.save,
        );
      },
    );
  }

  Future<void> _locateAssetInSidebar(
    StoryboardController controller,
    StoryboardCutAsset asset,
  ) async {
    if (!_assetSidebarExpanded) {
      _setAssetSidebarExpanded(true);
      await WidgetsBinding.instance.endOfFrame;
    }
    var located = false;
    for (var attempt = 0; attempt < 3 && !located; attempt++) {
      final sidebar = _assetSidebarKey.currentState;
      if (sidebar != null) {
        located = await sidebar.locateAsset(asset);
        break;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!located && mounted) {
      await controller.refreshAssets();
      if (!mounted) {
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
      located =
          await _assetSidebarKey.currentState?.locateAsset(asset) ?? false;
    }
    if (!mounted || located) {
      return;
    }
  }

  Future<void> _pickReplacementImage(
    StoryboardController controller,
    StoryboardItem item,
  ) async {
    try {
      final file = await ref
          .read(desktopFileDialogServiceProvider)
          .openFile(
            source: 'storyboard.replace_image',
            acceptedTypeGroups: const [_replacementImageTypeGroup],
            initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
          );
      if (file != null) {
        await controller.replaceItemImage(item: item, imagePath: file.path);
      }
    } catch (_) {}
  }

  Future<void> _replaceWithDroppedImage(
    StoryboardController controller,
    StoryboardItem item,
    Iterable<String> paths,
  ) async {
    String? imagePath;
    for (final path in paths) {
      if (_isReplacementImagePath(path)) {
        imagePath = path;
        break;
      }
    }
    if (imagePath == null) {
      return;
    }
    await controller.replaceItemImage(item: item, imagePath: imagePath);
  }

  Future<void> _exportBoardImages(StoryboardBoard board) async {
    final settings = ref.read(settingsControllerProvider).value;
    final path = await getDirectoryPath(
      initialDirectory: settings.exportDirectory,
    );
    if (path == null) {
      return;
    }
    try {
      await const StoryboardExportService().exportBoardImages(
        board: board,
        outputDirectory: path,
      );
    } catch (_) {}
  }

  Future<void> _exportShiyinBridge(StoryboardBoard board) async {
    final frames = <Map<String, Object?>>[];
    final uploads = <BridgeDirectUpload>[];
    final checksums = <String, String>{};
    final orderedItems = board.items.toList()
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    for (final item in orderedItems) {
      final file = File(item.asset.path);
      if (!file.existsSync()) {
        throw FormatException('故事板图片不存在：${file.path}');
      }
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) {
        throw FormatException('无法读取故事板图片：${file.path}');
      }
      final shotNumber = item.slotIndex + 1;
      final bytes = await file.readAsBytes();
      final checksum = sha256.convert(bytes).toString();
      final extension = p.extension(file.path).toLowerCase().isEmpty
          ? '.png'
          : p.extension(file.path).toLowerCase();
      final uploadName =
          'frame_${item.slotIndex.toString().padLeft(4, '0')}$extension';
      final relativePath =
          'images/original/${item.slotIndex.toString().padLeft(4, '0')}$extension';
      final stableId = BridgeManifest.stableFrameId(
        board.id,
        item.slotIndex,
        BridgeVariant.original,
      );
      frames.add({
        'stable_id': stableId,
        'shot_stable_id': BridgeManifest.stableShotId(board.id, shotNumber),
        'slot_index': item.slotIndex,
        'shot_number': shotNumber,
        'frame_index': item.slotIndex,
        'timestamp_ms': 0,
        'source_name': item.asset.sourceName,
        'relative_path': relativePath,
        'upload_name': uploadName,
        'width': decoded.width,
        'height': decoded.height,
        'variant': BridgeVariant.original.wireName,
        'caption': item.caption,
        'sha256': checksum,
        'metadata': {'source_storyboard_asset_id': item.asset.id},
      });
      checksums[relativePath] = checksum;
      uploads.add(BridgeDirectUpload(file: file, uploadName: uploadName));
    }
    if (frames.isEmpty) {
      throw const FormatException('当前故事板没有可发送的图片');
    }
    final manifest = <String, Object?>{
      'schema': bridgeSchema,
      'schema_version': bridgeSchemaVersion,
      'bridge_id': BridgeManifest.stableBridgeId(
        ref.read(currentProjectIdProvider),
        board.id,
      ),
      'direction': 'film-to-shiyin',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'source': {
        'app': 'filmstoryboard',
        'project_id': ref.read(currentProjectIdProvider),
        'project_name': ref.read(currentProjectNameProvider),
        'board_id': board.id,
      },
      'canvas': {'create_prompt_nodes': false},
      'storyboard': {
        'board_name': board.name,
        'selected_variant': BridgeVariant.original.wireName,
        'variants': [BridgeVariant.original.wireName],
        'frames': frames,
      },
      // 拍摄脚本互动功能后续开发，本次只发送故事板图片。
      'shots': <Object?>[],
      'checksums': checksums,
    };
    final loopback = BridgeLoopbackClient();
    try {
      final result = await loopback.sendDirect(
        manifest: manifest,
        uploads: uploads,
        canvasTitle: board.name,
      );
      if (Platform.isWindows) {
        try {
          await Process.start('explorer.exe', [result.editorUri.toString()]);
        } catch (_) {
          // 已成功发送；打开浏览器失败不应触发重复文件导出。
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已直接发送 ${result.frameCount} 张分镜到 SHIYIN-AI 画布'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送到 SHIYIN-AI 画布失败：$error')));
      }
    } finally {
      loopback.close();
    }
  }

  Future<void> _importShiyinBridge(StoryboardBoard currentBoard) async {
    final directories = ref.read(projectDirectoriesProvider);
    final selected = await ref
        .read(desktopFileDialogServiceProvider)
        .openFile(
          source: 'storyboard.import_shiyin_bridge',
          initialDirectory: directories.imports.path,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'SHIYIN 回传桥接包',
              extensions: ['zip', 'filmbridge', 'shiyinbridge'],
            ),
          ],
          confirmButtonText: '接收桥接包',
        );
    if (selected == null) return;
    try {
      await _applyShiyinBridgeFile(
        File(selected.path),
        fallbackBoard: currentBoard,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('接收 SHIYIN 回传失败：$error')));
    }
  }

  Future<BridgeImportResult> _applyShiyinBridgeFile(
    File packageFile, {
    StoryboardBoard? fallbackBoard,
  }) async {
    final directories = ref.read(projectDirectoriesProvider);
    final result = await const BridgePackageService().importShiyinToFilm(
      packageFile: packageFile,
      destinationRoot: directories.imports,
    );
    final variantLabel = switch (result.manifest.selectedVariant) {
      BridgeVariant.original => '原始帧',
      BridgeVariant.expanded16x9 => '16:9 扩展',
      BridgeVariant.lineArt => '线稿分镜',
      BridgeVariant.replicated => '复刻帧',
    };
    final currentBoard =
        fallbackBoard ??
        ref.read(storyboardControllerProvider).value.selectedBoard;
    final boardName = result.manifest.boardName.trim().isEmpty
        ? '${currentBoard?.name ?? 'SHIYIN 故事板'} · $variantLabel'
        : '${result.manifest.boardName} · $variantLabel';
    final storyboardController = ref.read(storyboardControllerProvider);
    final boardId = await storyboardController
        .createOrReplaceBoardFromExternalImages(
          sourceId: 'shiyin-bridge:${result.manifest.bridgeId}',
          boardName: boardName,
          images: [
            for (final frame in result.frames)
              StoryboardExternalImage(
                stableId: frame.record.stableId,
                sourceName: frame.record.sourceName,
                path: frame.file.path,
                width: frame.width,
                height: frame.height,
                caption: frame.record.caption,
              ),
          ],
          selectBoard: true,
          preserveExistingCaptions: false,
        );
    if (boardId == null) {
      throw const FormatException('回传图片已解包，但故事板创建失败');
    }
    final importedBoard = storyboardController.value.boards
        .cast<StoryboardBoard?>()
        .firstWhere((board) => board?.id == boardId, orElse: () => null);
    if (importedBoard == null) {
      throw const FormatException('无法读取刚创建的 SHIYIN 故事板');
    }
    ref
        .read(shootingScriptControllerProvider)
        .applyBridgeShots(importedBoard, result.manifest.shots);
    for (final obsolete in result.obsoleteFiles) {
      try {
        if (obsolete.existsSync()) await obsolete.delete();
      } catch (_) {
        // 清理失败不回滚已成功接收的故事板，下次接收会再次识别为旧文件。
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已接收 ${result.frames.length} 张$variantLabel，并同步拍摄脚本'),
        ),
      );
    }
    return result;
  }

  Future<void> _openAssetFolderDirectory(StoryboardFolder folder) async {
    try {
      final opened = await widget.fileExplorerService.openDirectory(
        folder.path,
      );
      if (!mounted || opened) {
        return;
      }
      return;
    } catch (_) {}
  }

  double _effectiveAssetSidebarWidth(double availableWidth) {
    final inspectorWidth = _inspectorExpanded ? 310.0 : 44.0;
    const resizeHandleWidth = 8.0;
    const canvasGap = 8.0;
    const inspectorGap = 12.0;
    const minCanvasWidth = 180.0;
    final reservedWidth =
        resizeHandleWidth + canvasGap + inspectorGap + inspectorWidth;
    final adaptiveMax = availableWidth - reservedWidth - minCanvasWidth;
    final upperBound = math.max(
      _minAssetSidebarWidth,
      math.min(_maxAssetSidebarWidth, adaptiveMax),
    );
    return _assetSidebarWidth
        .clamp(_minAssetSidebarWidth, upperBound)
        .toDouble();
  }

  void _beginAssetSidebarResize(double visibleWidth) {
    _setAssetSidebarWidth(visibleWidth, save: false);
  }

  void _setAssetSidebarWidth(double width, {bool save = true}) {
    final nextWidth = width
        .clamp(_minAssetSidebarWidth, _maxAssetSidebarWidth)
        .toDouble();
    if ((_assetSidebarWidth - nextWidth).abs() < 0.1) {
      return;
    }
    setState(() => _assetSidebarWidth = nextWidth);
    if (save) {
      _saveUiState();
    }
  }

  void _setAssetSidebarExpanded(bool expanded) {
    if (_assetSidebarExpanded == expanded) {
      return;
    }
    setState(() => _assetSidebarExpanded = expanded);
    _saveUiState();
  }

  void _setInspectorExpanded(bool expanded) {
    if (_inspectorExpanded == expanded) {
      return;
    }
    setState(() => _inspectorExpanded = expanded);
    _saveUiState();
  }

  void _restoreUiState() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(_uiStateKey);
      if (raw == null || raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      _assetSidebarWidth = _jsonDouble(
        decoded['assetSidebarWidth'],
        260,
      ).clamp(_minAssetSidebarWidth, _maxAssetSidebarWidth).toDouble();
      _assetSidebarExpanded = _jsonBool(decoded['assetSidebarExpanded'], true);
      _inspectorExpanded = _jsonBool(decoded['inspectorExpanded'], false);
      _expandedInspectorSections
        ..clear()
        ..addAll(
          _inspectorSectionSetFromJson(decoded['inspectorExpandedSections']),
        );
    } catch (_) {
      return;
    }
  }

  void _saveUiState() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(
            _uiStateKey,
            jsonEncode({
              'assetSidebarWidth': _assetSidebarWidth,
              'assetSidebarExpanded': _assetSidebarExpanded,
              'inspectorExpanded': _inspectorExpanded,
              'inspectorExpandedSections':
                  _expandedInspectorSections
                      .map((section) => section.name)
                      .toList()
                    ..sort(),
            }),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
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

  Set<_StoryboardInspectorSection> _inspectorSectionSetFromJson(Object? value) {
    if (value is! List) {
      return const {};
    }
    final names = value.map((item) => item?.toString()).toSet();
    return {
      for (final section in _StoryboardInspectorSection.values)
        if (names.contains(section.name)) section,
    };
  }

  void _toggleInspectorSection(_StoryboardInspectorSection section) {
    setState(() {
      if (!_expandedInspectorSections.remove(section)) {
        _expandedInspectorSections.add(section);
      }
    });
    _saveUiState();
  }

  Future<void> _confirmDeleteAssetFolder(
    StoryboardController controller,
    StoryboardFolder folder,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除资源文件夹'),
        content: Text(
          '确定删除“${folder.name}”及其中的 ${folder.assets.length} 张图片吗？此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('删除文件夹'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteFolder(folder);
    }
  }

  Future<void> _showImageComparisonDialog(
    StoryboardController controller,
    StoryboardItem item,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _StoryboardImageComparisonDialog(
        controller: controller,
        boardId: controller.value.selectedBoardId,
        item: item,
      ),
    );
  }
}

class _StoryboardImageComparisonDialog extends StatefulWidget {
  const _StoryboardImageComparisonDialog({
    required this.controller,
    required this.boardId,
    required this.item,
  });

  final StoryboardController controller;
  final String? boardId;
  final StoryboardItem item;

  @override
  State<_StoryboardImageComparisonDialog> createState() =>
      _StoryboardImageComparisonDialogState();
}

class _StoryboardImageComparisonDialogState
    extends State<_StoryboardImageComparisonDialog> {
  double _split = 0.5;
  String _status = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final board = widget.controller.value.boards
            .cast<StoryboardBoard?>()
            .firstWhere(
              (candidate) => candidate?.id == widget.boardId,
              orElse: () => widget.controller.value.selectedBoard,
            );
        final currentItem =
            board?.itemAtSlot(widget.item.slotIndex) ?? widget.item;
        final originalPath =
            widget.controller.originalImagePathForItem(currentItem) ??
            currentItem.asset.path;
        final currentPath = currentItem.asset.path;
        final generating =
            board != null &&
            widget.controller.value.isGeneratingImageFor(board.id);
        return Dialog(
          key: const ValueKey('storyboard-image-comparison-dialog'),
          insetPadding: const EdgeInsets.all(28),
          child: SizedBox(
            width: 980,
            height: 720,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.compare_rounded),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '分镜对比 · 第 ${currentItem.slotIndex + 1} 格',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _WipeImageComparison(
                      originalPath: originalPath,
                      currentPath: currentPath,
                      split: _split,
                      onSplitChanged: (value) => setState(() => _split = value),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.swipe_rounded, size: 18),
                      const SizedBox(width: 6),
                      const Expanded(child: Text('拖动中间分割线核对原视频帧与当前分镜')),
                      if (_status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text(
                            _status,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      FilledButton.icon(
                        key: const ValueKey('regenerate-single-line-art'),
                        onPressed: generating || board == null
                            ? null
                            : () {
                                final submitted = widget.controller
                                    .enqueueLineArtStoryboardForItem(
                                      item: currentItem,
                                    );
                                if (submitted) {
                                  setState(() => _status = '已提交单图线稿任务');
                                }
                              },
                        icon: generating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(generating ? '生成中...' : '重新生成该图线稿'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WipeImageComparison extends StatelessWidget {
  const _WipeImageComparison({
    required this.originalPath,
    required this.currentPath,
    required this.split,
    required this.onSplitChanged,
  });

  final String originalPath;
  final String currentPath;
  final double split;
  final ValueChanged<double> onSplitChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final dividerX = constraints.maxWidth * split.clamp(0.05, 0.95);
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(currentPath), fit: BoxFit.contain),
                ClipRect(
                  clipper: _LeftWipeClipper(dividerX),
                  child: Image.file(File(originalPath), fit: BoxFit.contain),
                ),
                Positioned(
                  left: dividerX - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: scheme.primary),
                ),
                Positioned(
                  left: dividerX - 22,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) {
                      onSplitChanged(
                        ((dividerX + details.delta.dx) /
                                math.max(1, constraints.maxWidth))
                            .clamp(0.05, 0.95),
                      );
                    },
                    child: SizedBox(
                      width: 44,
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 12,
                            ),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  top: 12,
                  child: _ComparisonLabel(label: '原故事板', color: scheme.primary),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: _ComparisonLabel(
                    label: '当前分镜',
                    color: scheme.tertiary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LeftWipeClipper extends CustomClipper<Rect> {
  const _LeftWipeClipper(this.right);

  final double right;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, right, size.height);

  @override
  bool shouldReclip(covariant _LeftWipeClipper oldClipper) =>
      oldClipper.right != right;
}

class _ComparisonLabel extends StatelessWidget {
  const _ComparisonLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _SidebarResizeHandle extends StatelessWidget {
  const _SidebarResizeHandle({
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => onDragStart(),
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onHorizontalDragCancel: onDragEnd,
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 2,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.64),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedAssetSidebarRail extends StatelessWidget {
  const _CollapsedAssetSidebarRail({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '展开裁切资源',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onExpand,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.48),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_library_rounded, color: scheme.primary),
              const SizedBox(height: 10),
              RotatedBox(
                quarterTurns: 3,
                child: Text(
                  '裁切资源',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: scheme.onSurfaceVariant,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapsedInspectorRail extends StatelessWidget {
  const _CollapsedInspectorRail({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '展开画板参数',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onExpand,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.48),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.tune_rounded, color: scheme.primary),
              const SizedBox(height: 10),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  '画板参数',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Icon(
                Icons.keyboard_double_arrow_left_rounded,
                color: scheme.onSurfaceVariant,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetSidebar extends ConsumerStatefulWidget {
  const _AssetSidebar({
    super.key,
    required this.state,
    required this.onRefresh,
    required this.onToggleAsset,
    required this.onSetAssetsUsed,
    required this.onRemoveAsset,
    required this.onDeleteGroup,
    required this.onDeleteFolderAsset,
    required this.onOpenFolderDirectory,
    required this.onDeleteFolder,
    required this.onCreateFolder,
    required this.onCopyAssetToFolder,
    required this.onCopyPathsToFolder,
    required this.onCreateResourceGroup,
    required this.onToggleResourceGroupExpanded,
    required this.onMoveResourceNode,
    required this.onRenameResourceGroup,
    required this.onCollapse,
  });

  final StoryboardState state;
  final Future<void> Function() onRefresh;
  final ValueChanged<StoryboardCutAsset> onToggleAsset;
  final void Function(Iterable<StoryboardCutAsset> assets, bool used)
  onSetAssetsUsed;
  final ValueChanged<String> onRemoveAsset;
  final ValueChanged<String> onDeleteGroup;
  final Future<void> Function(StoryboardCutAsset asset) onDeleteFolderAsset;
  final ValueChanged<StoryboardFolder> onOpenFolderDirectory;
  final ValueChanged<StoryboardFolder> onDeleteFolder;
  final Future<void> Function(String name) onCreateFolder;
  final Future<void> Function(StoryboardCutAsset asset, String folderId)
  onCopyAssetToFolder;
  final Future<void> Function(Iterable<String> paths, String folderId)
  onCopyPathsToFolder;
  final Future<void> Function({
    required String name,
    Iterable<String> assetIds,
    Iterable<String> sourceImageIds,
    Iterable<String> folderIds,
  })
  onCreateResourceGroup;
  final ValueChanged<String> onToggleResourceGroupExpanded;
  final bool Function(
    String nodeKey, {
    String? targetGroupId,
    String? beforeNodeKey,
  })
  onMoveResourceNode;
  final bool Function(String groupId, String name) onRenameResourceGroup;
  final VoidCallback onCollapse;

  @override
  ConsumerState<_AssetSidebar> createState() => _AssetSidebarState();
}

class _AssetSidebarState extends ConsumerState<_AssetSidebar> {
  static const _uiStateKey = 'storyboardAssetSidebarUiState';
  static const _minThumbSize = 52.0;
  static const _maxThumbSize = 360.0;
  static const _thumbStep = 6.0;

  final _expandedSources = <String>{};
  final _expandedFolders = <String>{};
  final _pinnedResourceNodeKeys = <String>[];
  final _locatedAssetGridKey = GlobalKey();
  double _thumbSize = 70;
  bool _showThumbSizeSlider = false;
  bool _assetOrderAscending = true;
  String? _rangeAnchorAssetId;
  String? _rangeTargetAssetId;
  bool _shiftPressed = false;
  bool _rangeAdding = true;
  bool _groupModeEnabled = false;
  bool _externalPanelDragging = false;
  final _groupSourceImageIds = <String>{};
  final _groupFolderIds = <String>{};
  String? _locatedAssetId;
  int _locatedAssetIndex = 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _restoreUiState();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AssetSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validSourceImageIds = widget.state.assets
        .map((asset) => asset.imageId)
        .toSet();
    final validFolderIds = widget.state.folders
        .map((folder) => folder.id)
        .toSet();
    _groupSourceImageIds.removeWhere((id) => !validSourceImageIds.contains(id));
    _groupFolderIds.removeWhere((id) => !validFolderIds.contains(id));
    final validNodeKeys = <String>{
      for (final group in widget.state.resourceGroups)
        StoryboardResourceNodeRef.group(group.id).key,
      for (final folder in widget.state.folders)
        StoryboardResourceNodeRef.folder(folder.id).key,
      for (final sourceImageId in validSourceImageIds)
        StoryboardResourceNodeRef.source(sourceImageId).key,
    };
    _pinnedResourceNodeKeys.removeWhere(
      (nodeKey) => !validNodeKeys.contains(nodeKey),
    );
  }

  void _restoreUiState() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(_uiStateKey);
      if (raw == null || raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      _expandedSources
        ..clear()
        ..addAll(_jsonStringSet(decoded['expandedSources']));
      _expandedFolders
        ..clear()
        ..addAll(_jsonStringSet(decoded['expandedFolders']));
      _thumbSize = _jsonDouble(
        decoded['thumbSize'],
        70,
      ).clamp(_minThumbSize, _maxThumbSize).toDouble();
      _showThumbSizeSlider = _jsonBool(decoded['showThumbSizeSlider'], false);
      _assetOrderAscending = _jsonBool(decoded['assetOrderAscending'], true);
      _pinnedResourceNodeKeys
        ..clear()
        ..addAll(_jsonStringList(decoded['pinnedResourceNodeKeys']));
    } catch (_) {
      return;
    }
  }

  void _saveUiState() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(
            _uiStateKey,
            jsonEncode({
              'expandedSources': _expandedSources.toList()..sort(),
              'expandedFolders': _expandedFolders.toList()..sort(),
              'thumbSize': _thumbSize,
              'showThumbSizeSlider': _showThumbSizeSlider,
              'assetOrderAscending': _assetOrderAscending,
              'pinnedResourceNodeKeys': _pinnedResourceNodeKeys,
            }),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  Set<String> _jsonStringSet(Object? value) {
    if (value is! List) {
      return const <String>{};
    }
    return {for (final item in value) item?.toString() ?? ''}..remove('');
  }

  List<String> _jsonStringList(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    final result = <String>[];
    final seen = <String>{};
    for (final item in value) {
      final text = item?.toString() ?? '';
      if (text.isNotEmpty && seen.add(text)) {
        result.add(text);
      }
    }
    return result;
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

  Future<bool> locateAsset(StoryboardCutAsset requestedAsset) async {
    StoryboardCutAsset? asset;
    StoryboardFolder? assetFolder;
    for (final candidate in widget.state.assets) {
      if (candidate.id == requestedAsset.id) {
        asset = candidate;
        break;
      }
    }
    for (final folder in widget.state.folders) {
      for (final candidate in folder.assets) {
        if (candidate.id == requestedAsset.id) {
          asset = candidate;
          assetFolder = folder;
          break;
        }
      }
      if (assetFolder != null) {
        break;
      }
    }
    if (asset == null) {
      for (final candidate in widget.state.assets) {
        if (_sameLocatedAssetPath(candidate, requestedAsset)) {
          asset = candidate;
          break;
        }
      }
      for (final folder in widget.state.folders) {
        for (final candidate in folder.assets) {
          if (_sameLocatedAssetPath(candidate, requestedAsset)) {
            asset = candidate;
            assetFolder = folder;
            break;
          }
        }
        if (assetFolder != null) {
          break;
        }
      }
    }
    if (asset == null) {
      return false;
    }

    final containingGroupIds = <String>{};
    for (final group in widget.state.resourceGroups) {
      if (group.assetIds.contains(asset.id) ||
          group.sourceImageIds.contains(asset.imageId) ||
          (assetFolder != null && group.folderIds.contains(assetFolder.id))) {
        containingGroupIds.add(group.id);
      }
    }
    final groupsById = {
      for (final group in widget.state.resourceGroups) group.id: group,
    };
    for (final groupId in [...containingGroupIds]) {
      var parentId = groupsById[groupId]?.parentGroupId;
      while (parentId != null && containingGroupIds.add(parentId)) {
        parentId = groupsById[parentId]?.parentGroupId;
      }
    }

    setState(() {
      _locatedAssetId = asset!.id;
      if (assetFolder != null) {
        _expandedFolders.add(assetFolder.id);
      } else {
        _expandedSources.add(asset.imageId);
      }
      _rangeAnchorAssetId = asset.id;
      _rangeTargetAssetId = null;
    });
    for (final groupId in containingGroupIds) {
      final group = groupsById[groupId];
      if (group != null && !group.expanded) {
        widget.onToggleResourceGroupExpanded(groupId);
      }
    }
    _saveUiState();

    await Future<void>.delayed(const Duration(milliseconds: 220));
    return _scrollLocatedAssetIntoView();
  }

  bool _sameLocatedAssetPath(
    StoryboardCutAsset candidate,
    StoryboardCutAsset requested,
  ) {
    return p.normalize(candidate.path).toLowerCase() ==
        p.normalize(requested.path).toLowerCase();
  }

  Key? _locatedGridKeyFor(List<StoryboardCutAsset> assets) {
    final assetId = _locatedAssetId;
    if (assetId == null) {
      return null;
    }
    final index = assets.indexWhere((asset) => asset.id == assetId);
    if (index < 0) {
      return null;
    }
    _locatedAssetIndex = index;
    return _locatedAssetGridKey;
  }

  Future<bool> _scrollLocatedAssetIntoView() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return false;
      }
      final gridContext = _locatedAssetGridKey.currentContext;
      if (gridContext == null || !gridContext.mounted) {
        continue;
      }
      final gridBox = gridContext.findRenderObject();
      final scrollable = Scrollable.maybeOf(gridContext);
      final viewportBox = scrollable?.position.context.storageContext
          .findRenderObject();
      if (gridBox is RenderBox &&
          gridBox.hasSize &&
          scrollable != null &&
          viewportBox is RenderBox &&
          viewportBox.hasSize) {
        final columns = math.max(
          1,
          ((gridBox.size.width + 8) / (_thumbSize + 8)).floor(),
        );
        final row = _locatedAssetIndex ~/ columns;
        final itemTop =
            gridBox.localToGlobal(Offset.zero).dy + row * (_thumbSize + 8);
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final desiredTop =
            viewportTop + (viewportBox.size.height - _thumbSize) / 2;
        final position = scrollable.position;
        final target = (position.pixels + itemTop - desiredTop)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
        if ((target - position.pixels).abs() > 1) {
          await position.animateTo(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        }
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ungroupedFolders = _ungroupedFolders();
    final ungroupedAssets = _ungroupedAssets();
    final groups = <String, List<StoryboardCutAsset>>{};
    for (final asset in ungroupedAssets) {
      groups.putIfAbsent(asset.imageId, () => []).add(asset);
    }
    final sourceIds = widget.state.assets.map((asset) => asset.imageId).toSet();
    _expandedSources.removeWhere((source) => !sourceIds.contains(source));
    final folderIds = widget.state.folders.map((folder) => folder.id).toSet();
    _expandedFolders.removeWhere((folder) => !folderIds.contains(folder));
    final visibleAssets = _visibleAssets(
      groups,
      ungroupedFolders,
      resourceGroups: widget.state.resourceGroups,
    );
    final previewIds = _previewAssetIds(visibleAssets);
    final rootNodeKeys = _rootResourceNodeKeys(
      ungroupedFolders: ungroupedFolders,
      ungroupedSourceIds: groups.keys,
    );
    final resourceNodes = _buildResourceNodes(
      nodeKeys: rootNodeKeys,
      sequencePrefix: '',
      parentGroupId: null,
      usedIds: widget.state.usedAssetIds,
      previewIds: previewIds,
    );
    final hasResources =
        groups.isNotEmpty ||
        ungroupedFolders.isNotEmpty ||
        widget.state.resourceGroups.isNotEmpty;
    final hasExpandableResources =
        groups.isNotEmpty ||
        widget.state.folders.isNotEmpty ||
        widget.state.resourceGroups.isNotEmpty;
    final allResourcesExpanded =
        hasExpandableResources &&
        sourceIds.every(_expandedSources.contains) &&
        folderIds.every(_expandedFolders.contains) &&
        widget.state.resourceGroups.every((group) => group.expanded);

    return Listener(
      onPointerSignal: _handlePointerSignal,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.48),
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: LayoutBuilder(
                builder: (context, constraints) => _AssetSidebarHeader(
                  compact: constraints.maxWidth < 340,
                  allExpanded: allResourcesExpanded,
                  canToggleAll: hasExpandableResources,
                  assetOrderAscending: _assetOrderAscending,
                  groupModeEnabled: _groupModeEnabled,
                  onToggleAll: () => _setAllResourcesExpanded(
                    expanded: !allResourcesExpanded,
                    sourceIds: sourceIds,
                    folderIds: folderIds,
                  ),
                  onGroupModeChanged: _setGroupModeEnabled,
                  onToggleAssetOrder: _toggleAssetOrder,
                  onCreateFolder: _createFolder,
                  onRefresh: widget.onRefresh,
                  onCollapse: widget.onCollapse,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: DropTarget(
                enable: DesktopDropTargetScope.enabledOf(context),
                key: const ValueKey('storyboard-asset-panel-drop-target'),
                onDragEntered: (_) {
                  if (!_externalPanelDragging) {
                    setState(() => _externalPanelDragging = true);
                  }
                },
                onDragExited: (_) {
                  if (_externalPanelDragging) {
                    setState(() => _externalPanelDragging = false);
                  }
                },
                onDragDone: (details) {
                  if (_externalPanelDragging) {
                    setState(() => _externalPanelDragging = false);
                  }
                  unawaited(
                    ref
                        .read(storyboardControllerProvider)
                        .importPathsToManualFolder(
                          details.files.map((file) => file.path),
                        ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _externalPanelDragging
                        ? scheme.primaryContainer.withValues(alpha: 0.72)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: _externalPanelDragging
                          ? scheme.primary
                          : scheme.outlineVariant.withValues(alpha: 0.65),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                        color: _externalPanelDragging
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          '拖入图片到“手动添加”（仅保存资源）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: _externalPanelDragging
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: !hasResources
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          '在多宫格裁切页导出后点击刷新',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : _ResourceGroupSelectionScope(
                      enabled: _groupModeEnabled,
                      selectedSourceImageIds: {..._groupSourceImageIds},
                      selectedFolderIds: {..._groupFolderIds},
                      onSourceCheckedChanged: _setGroupSourceChecked,
                      onFolderCheckedChanged: _setGroupFolderChecked,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        children: resourceNodes,
                      ),
                    ),
            ),
            if (_groupModeEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('resource-group-create-button'),
                    onPressed:
                        _groupSourceImageIds.isEmpty && _groupFolderIds.isEmpty
                        ? null
                        : () => unawaited(_createCheckedResourceGroup()),
                    icon: const Icon(Icons.folder_copy_rounded, size: 18),
                    label: const Text('创建所选目录编组'),
                  ),
                ),
              ),
            _ThumbnailSizeControl(
              size: _thumbSize,
              min: _minThumbSize,
              max: _maxThumbSize,
              expanded: _showThumbSizeSlider,
              onToggleExpanded: _toggleThumbSizeSlider,
              onChanged: _setThumbSize,
            ),
          ],
        ),
      ),
    );
  }

  void _setGroupModeEnabled(bool enabled) {
    setState(() {
      _groupModeEnabled = enabled;
      if (!enabled) {
        _groupSourceImageIds.clear();
        _groupFolderIds.clear();
      }
    });
  }

  void _toggleAssetOrder() {
    setState(() {
      _assetOrderAscending = !_assetOrderAscending;
      _rangeTargetAssetId = null;
    });
    _saveUiState();
  }

  void _toggleResourcePinned(String nodeKey) {
    setState(() {
      if (_pinnedResourceNodeKeys.remove(nodeKey)) {
        return;
      }
      _pinnedResourceNodeKeys.insert(0, nodeKey);
    });
    _saveUiState();
  }

  void _setGroupSourceChecked(String sourceImageId, bool checked) {
    if (!_groupModeEnabled) {
      return;
    }
    setState(() {
      if (checked) {
        _groupSourceImageIds.add(sourceImageId);
      } else {
        _groupSourceImageIds.remove(sourceImageId);
      }
    });
  }

  void _setGroupFolderChecked(String folderId, bool checked) {
    if (!_groupModeEnabled) {
      return;
    }
    setState(() {
      if (checked) {
        _groupFolderIds.add(folderId);
      } else {
        _groupFolderIds.remove(folderId);
      }
    });
  }

  Future<void> _createCheckedResourceGroup() async {
    if (!_groupModeEnabled ||
        (_groupSourceImageIds.isEmpty && _groupFolderIds.isEmpty)) {
      return;
    }
    await _createResourceGroup(
      defaultName: '新编组',
      sourceImageIds: {..._groupSourceImageIds},
      folderIds: {..._groupFolderIds},
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _groupSourceImageIds.clear();
      _groupFolderIds.clear();
    });
  }

  Future<void> _createFolder() async {
    final name = await _askFolderName();
    if (name == null || !mounted) {
      return;
    }
    await widget.onCreateFolder(name);
  }

  Future<String?> _askFolderName() async {
    var name = '';
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新建文件夹'),
          content: TextFormField(
            autofocus: true,
            decoration: const InputDecoration(labelText: '文件夹名称'),
            onChanged: (value) => name = value,
            onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(name),
              icon: const Icon(Icons.create_new_folder_rounded),
              label: const Text('创建'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createResourceGroup({
    required String defaultName,
    Iterable<String> assetIds = const [],
    Iterable<String> sourceImageIds = const [],
    Iterable<String> folderIds = const [],
  }) async {
    final name = await _askResourceGroupName(defaultName);
    if (name == null || !mounted) {
      return;
    }
    await widget.onCreateResourceGroup(
      name: name,
      assetIds: assetIds,
      sourceImageIds: sourceImageIds,
      folderIds: folderIds,
    );
  }

  Future<String?> _askResourceGroupName(String defaultName) async {
    var name = defaultName;
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新建编组'),
          content: TextFormField(
            initialValue: defaultName,
            autofocus: true,
            decoration: const InputDecoration(labelText: '编组名称'),
            onChanged: (value) => name = value,
            onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(name),
              icon: const Icon(Icons.create_new_folder_rounded),
              label: const Text('创建'),
            ),
          ],
        );
      },
    );
  }

  List<StoryboardFolder> _ungroupedFolders() {
    final groupedFolderIds = _groupedFolderIds();
    final groupedAssetIds = _groupedAssetIds();
    final folders = <StoryboardFolder>[];
    for (final folder in widget.state.folders) {
      if (groupedFolderIds.contains(folder.id)) {
        continue;
      }
      final visibleAssets = [
        for (final asset in folder.assets)
          if (!groupedAssetIds.contains(asset.id)) asset,
      ];
      if (folder.assets.isNotEmpty && visibleAssets.isEmpty) {
        continue;
      }
      folders.add(
        StoryboardFolder(
          id: folder.id,
          name: folder.name,
          path: folder.path,
          assets: _orderedAssetsForDisplay(visibleAssets),
        ),
      );
    }
    return folders;
  }

  List<StoryboardCutAsset> _ungroupedAssets() {
    final groupedAssetIds = _groupedAssetIds();
    final groupedSourceImageIds = _groupedSourceImageIds();
    return [
      for (final asset in widget.state.assets)
        if (!groupedAssetIds.contains(asset.id) &&
            !groupedSourceImageIds.contains(asset.imageId))
          asset,
    ];
  }

  Set<String> _groupedAssetIds() {
    return {for (final group in widget.state.resourceGroups) ...group.assetIds};
  }

  Set<String> _groupedSourceImageIds() {
    return {
      for (final group in widget.state.resourceGroups) ...group.sourceImageIds,
    };
  }

  Set<String> _groupedFolderIds() {
    return {
      for (final group in widget.state.resourceGroups) ...group.folderIds,
    };
  }

  List<StoryboardCutAsset> _assetsForResourceGroup(
    StoryboardResourceGroup group,
  ) {
    final assetIds = group.assetIds.toSet();
    final sourceImageIds = group.sourceImageIds.toSet();
    final folderAssetIds = {
      for (final folder in _foldersForResourceGroup(group))
        for (final asset in folder.assets) asset.id,
    };
    final assets = <StoryboardCutAsset>[];
    final seen = <String>{};
    void addAsset(StoryboardCutAsset asset) {
      if (folderAssetIds.contains(asset.id) || !seen.add(asset.id)) {
        return;
      }
      assets.add(asset);
    }

    for (final asset in widget.state.assets) {
      if (assetIds.contains(asset.id) ||
          sourceImageIds.contains(asset.imageId)) {
        addAsset(asset);
      }
    }
    for (final folder in widget.state.folders) {
      for (final asset in folder.assets) {
        if (assetIds.contains(asset.id)) {
          addAsset(asset);
        }
      }
    }
    return _orderedAssetsForDisplay(assets);
  }

  List<StoryboardFolder> _foldersForResourceGroup(
    StoryboardResourceGroup group,
  ) {
    final folderIds = group.folderIds.toSet();
    return [
      for (final folder in widget.state.folders)
        if (folderIds.contains(folder.id))
          StoryboardFolder(
            id: folder.id,
            name: folder.name,
            path: folder.path,
            assets: _orderedAssetsForDisplay(folder.assets),
          ),
    ];
  }

  List<StoryboardCutAsset> _directAssetsForResourceGroup(
    StoryboardResourceGroup group,
  ) {
    final assetIds = group.assetIds.toSet();
    return _orderedAssetsForDisplay([
      for (final asset in widget.state.assets)
        if (assetIds.contains(asset.id)) asset,
      for (final folder in widget.state.folders)
        for (final asset in folder.assets)
          if (assetIds.contains(asset.id)) asset,
    ]);
  }

  List<StoryboardCutAsset> _orderedAssetsForDisplay(
    Iterable<StoryboardCutAsset> assets,
  ) {
    final result = assets.toList()
      ..sort((first, second) {
        final byIndex = first.indexNo.compareTo(second.indexNo);
        if (byIndex != 0) {
          return byIndex;
        }
        final bySource = first.sourceName.compareTo(second.sourceName);
        return bySource != 0 ? bySource : first.id.compareTo(second.id);
      });
    return _assetOrderAscending ? result : result.reversed.toList();
  }

  List<String> _rootResourceNodeKeys({
    required List<StoryboardFolder> ungroupedFolders,
    required Iterable<String> ungroupedSourceIds,
  }) {
    final validKeys = <String>[
      for (final group in widget.state.resourceGroups)
        if (group.parentGroupId == null)
          StoryboardResourceNodeRef.group(group.id).key,
      for (final folder in ungroupedFolders)
        StoryboardResourceNodeRef.folder(folder.id).key,
      for (final sourceId in ungroupedSourceIds)
        StoryboardResourceNodeRef.source(sourceId).key,
    ];
    return _displayResourceNodeKeys(
      _orderedResourceNodeKeys(widget.state.resourceRootOrder, validKeys),
    );
  }

  List<String> _childResourceNodeKeys(StoryboardResourceGroup group) {
    final validKeys = <String>[
      for (final childGroup in widget.state.resourceGroups)
        if (childGroup.parentGroupId == group.id)
          StoryboardResourceNodeRef.group(childGroup.id).key,
      for (final folderId in group.folderIds)
        StoryboardResourceNodeRef.folder(folderId).key,
      for (final sourceImageId in group.sourceImageIds)
        StoryboardResourceNodeRef.source(sourceImageId).key,
    ];
    return _displayResourceNodeKeys(
      _orderedResourceNodeKeys(group.childOrder, validKeys),
    );
  }

  List<String> _displayResourceNodeKeys(Iterable<String> canonicalKeys) {
    final canonical = canonicalKeys.toList();
    final canonicalSet = canonical.toSet();
    final pinned = [
      for (final nodeKey in _pinnedResourceNodeKeys)
        if (canonicalSet.contains(nodeKey)) nodeKey,
    ];
    final pinnedSet = pinned.toSet();
    final unpinned = [
      for (final nodeKey in canonical)
        if (!pinnedSet.contains(nodeKey)) nodeKey,
    ];
    return [
      ...pinned,
      if (_assetOrderAscending) ...unpinned else ...unpinned.reversed,
    ];
  }

  List<String> _orderedResourceNodeKeys(
    Iterable<String> preferred,
    Iterable<String> valid,
  ) {
    final validSet = valid.toSet();
    final result = <String>[];
    final seen = <String>{};
    for (final key in preferred) {
      if (validSet.contains(key) && seen.add(key)) {
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

  List<Widget> _buildResourceNodes({
    required List<String> nodeKeys,
    required String sequencePrefix,
    required String? parentGroupId,
    required Set<String> usedIds,
    required Set<String> previewIds,
  }) {
    final widgets = <Widget>[];
    for (var index = 0; index < nodeKeys.length; index++) {
      final node = StoryboardResourceNodeRef.tryParse(nodeKeys[index]);
      if (node == null) {
        continue;
      }
      final sequence = sequencePrefix.isEmpty
          ? '${index + 1}'
          : '$sequencePrefix.${index + 1}';
      switch (node.kind) {
        case StoryboardResourceNodeKind.group:
          final group = widget.state.resourceGroups
              .cast<StoryboardResourceGroup?>()
              .firstWhere(
                (candidate) => candidate?.id == node.id,
                orElse: () => null,
              );
          if (group == null) {
            continue;
          }
          final childKeys = _childResourceNodeKeys(group);
          final directAssets = _directAssetsForResourceGroup(group);
          widgets.add(
            _ResourceGroupSection(
              group: group,
              sequence: sequence,
              pinned: _pinnedResourceNodeKeys.contains(node.key),
              parentGroupId: parentGroupId,
              siblingKeys: nodeKeys,
              headerAssets: _assetsForResourceGroup(group),
              headerFolders: _foldersForResourceGroup(group),
              childGroupCount: childKeys
                  .map(StoryboardResourceNodeRef.tryParse)
                  .where(
                    (child) => child?.kind == StoryboardResourceNodeKind.group,
                  )
                  .length,
              directAssets: directAssets,
              assetGridKey: _locatedGridKeyFor(directAssets),
              focusedAssetId: _locatedAssetId,
              childNodes: _buildResourceNodes(
                nodeKeys: childKeys,
                sequencePrefix: sequence,
                parentGroupId: group.id,
                usedIds: usedIds,
                previewIds: previewIds,
              ),
              usedIds: usedIds,
              previewIds: previewIds,
              previewAdding: _rangeAdding,
              thumbnailSize: _thumbSize,
              onToggleExpanded: () =>
                  widget.onToggleResourceGroupExpanded(group.id),
              onTogglePinned: () => _toggleResourcePinned(node.key),
              onToggleAsset: _toggleAsset,
              onRemoveAsset: _removeAsset,
              onRangeHover: _updateRangeTarget,
              onCreateAssetResourceGroup: (_) =>
                  unawaited(_createCheckedResourceGroup()),
              onMoveNode: _moveDroppedResource,
              onRename: () => unawaited(_renameResourceGroup(group)),
            ),
          );
          break;
        case StoryboardResourceNodeKind.folder:
          final folder = widget.state.folders
              .cast<StoryboardFolder?>()
              .firstWhere(
                (candidate) => candidate?.id == node.id,
                orElse: () => null,
              );
          if (folder == null) {
            continue;
          }
          final displayFolder = StoryboardFolder(
            id: folder.id,
            name: folder.name,
            path: folder.path,
            assets: _orderedAssetsForDisplay(folder.assets),
          );
          widgets.add(
            _AssetFolderGroup(
              folder: displayFolder,
              sequence: sequence,
              pinned: _pinnedResourceNodeKeys.contains(node.key),
              parentGroupId: parentGroupId,
              siblingKeys: nodeKeys,
              expanded: _expandedFolders.contains(folder.id),
              usedIds: usedIds,
              previewIds: previewIds,
              previewAdding: _rangeAdding,
              thumbnailSize: _thumbSize,
              assetGridKey: _locatedGridKeyFor(displayFolder.assets),
              focusedAssetId: _locatedAssetId,
              onToggleExpanded: () => _toggleFolderExpanded(folder.id),
              onTogglePinned: () => _toggleResourcePinned(node.key),
              onToggleAsset: _toggleAsset,
              onRemoveAsset: _removeAsset,
              onDeleteAsset: (asset) =>
                  unawaited(widget.onDeleteFolderAsset(asset)),
              onOpenDirectory: () => widget.onOpenFolderDirectory(folder),
              onDeleteFolder: () => widget.onDeleteFolder(folder),
              onRangeHover: _updateRangeTarget,
              onCreateAssetResourceGroup: (_) =>
                  unawaited(_createCheckedResourceGroup()),
              onDropAsset: (asset) =>
                  widget.onCopyAssetToFolder(asset, folder.id),
              onDropPaths: (paths) =>
                  widget.onCopyPathsToFolder(paths, folder.id),
              onMoveNode: _moveDroppedResource,
            ),
          );
          break;
        case StoryboardResourceNodeKind.source:
          final directAssetIds = {
            for (final group in widget.state.resourceGroups) ...group.assetIds,
          };
          final assets = _orderedAssetsForDisplay([
            for (final asset in widget.state.assets)
              if (asset.imageId == node.id &&
                  !directAssetIds.contains(asset.id))
                asset,
          ]);
          if (assets.isEmpty) {
            continue;
          }
          widgets.add(
            _AssetGroup(
              sequence: sequence,
              pinned: _pinnedResourceNodeKeys.contains(node.key),
              parentGroupId: parentGroupId,
              siblingKeys: nodeKeys,
              title: assets.first.sourceName,
              assets: assets,
              expanded: _expandedSources.contains(node.id),
              usedIds: usedIds,
              previewIds: previewIds,
              previewAdding: _rangeAdding,
              thumbnailSize: _thumbSize,
              assetGridKey: _locatedGridKeyFor(assets),
              focusedAssetId: _locatedAssetId,
              onToggleExpanded: () => _toggleExpanded(node.id),
              onTogglePinned: () => _toggleResourcePinned(node.key),
              onToggleAsset: _toggleAsset,
              onRemoveAsset: _removeAsset,
              onRangeHover: _updateRangeTarget,
              onCreateAssetResourceGroup: (_) =>
                  unawaited(_createCheckedResourceGroup()),
              onDeleteGroup: () => widget.onDeleteGroup(node.id),
              onMoveNode: _moveDroppedResource,
            ),
          );
          break;
      }
    }
    return widgets;
  }

  void _moveDroppedResource(
    _ResourceNodeDragData data,
    _ResourceNodeDragData target,
    String? targetParentGroupId,
    List<String> siblingKeys,
    _ResourceDropPlacement placement,
  ) {
    if (data.nodeKey == target.nodeKey) {
      return;
    }
    if (placement == _ResourceDropPlacement.inside) {
      widget.onMoveResourceNode(data.nodeKey, targetGroupId: target.id);
      return;
    }
    String? beforeNodeKey;
    if (placement == _ResourceDropPlacement.before) {
      beforeNodeKey = target.nodeKey;
    } else {
      final targetIndex = siblingKeys.indexOf(target.nodeKey);
      if (targetIndex >= 0 && targetIndex + 1 < siblingKeys.length) {
        beforeNodeKey = siblingKeys[targetIndex + 1];
      }
    }
    widget.onMoveResourceNode(
      data.nodeKey,
      targetGroupId: targetParentGroupId,
      beforeNodeKey: beforeNodeKey,
    );
  }

  Future<void> _renameResourceGroup(StoryboardResourceGroup group) async {
    var name = group.name;
    final nextName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名编组文件夹'),
        content: TextFormField(
          initialValue: group.name,
          autofocus: true,
          decoration: const InputDecoration(labelText: '编组名称'),
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(name),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || nextName == null) {
      return;
    }
    widget.onRenameResourceGroup(group.id, nextName);
  }

  void _toggleExpanded(String source) {
    setState(() {
      if (!_expandedSources.remove(source)) {
        _expandedSources.add(source);
      }
      _rangeTargetAssetId = null;
    });
    _saveUiState();
  }

  void _toggleFolderExpanded(String folderId) {
    setState(() {
      if (!_expandedFolders.remove(folderId)) {
        _expandedFolders.add(folderId);
      }
      _rangeTargetAssetId = null;
    });
    _saveUiState();
  }

  void _setAllResourcesExpanded({
    required bool expanded,
    required Iterable<String> sourceIds,
    required Iterable<String> folderIds,
  }) {
    setState(() {
      _expandedSources
        ..clear()
        ..addAll(expanded ? sourceIds : const <String>[]);
      _expandedFolders
        ..clear()
        ..addAll(expanded ? folderIds : const <String>[]);
      _rangeTargetAssetId = null;
    });
    for (final group in widget.state.resourceGroups) {
      if (group.expanded != expanded) {
        widget.onToggleResourceGroupExpanded(group.id);
      }
    }
    _saveUiState();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_isShiftKey(event.logicalKey)) {
      return false;
    }
    if (event is KeyDownEvent) {
      if (!_shiftPressed) {
        setState(() => _shiftPressed = true);
      }
      return false;
    }
    if (event is KeyUpEvent && !_isShiftPressed()) {
      _commitRangeSelection();
      setState(() {
        _shiftPressed = false;
        _rangeTargetAssetId = null;
      });
    }
    return false;
  }

  bool _isShiftKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight;
  }

  bool _isShiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_isControlPressed()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final direction = event.scrollDelta.dy < 0 ? 1 : -1;
      setState(() {
        _thumbSize = (_thumbSize + direction * _thumbStep)
            .clamp(_minThumbSize, _maxThumbSize)
            .toDouble();
      });
      _saveUiState();
    });
  }

  void _toggleThumbSizeSlider() {
    setState(() => _showThumbSizeSlider = !_showThumbSizeSlider);
    _saveUiState();
  }

  void _setThumbSize(double size) {
    final nextSize = size.clamp(_minThumbSize, _maxThumbSize).toDouble();
    if ((_thumbSize - nextSize).abs() < 0.1) {
      return;
    }
    setState(() => _thumbSize = nextSize);
    _saveUiState();
  }

  bool _isControlPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
  }

  void _toggleAsset(StoryboardCutAsset asset) {
    final willUse = !widget.state.usedAssetIds.contains(asset.id);
    setState(() {
      _rangeAnchorAssetId = asset.id;
      _rangeTargetAssetId = null;
      _rangeAdding = willUse;
    });
    widget.onToggleAsset(asset);
  }

  void _removeAsset(StoryboardCutAsset asset) {
    setState(() {
      _rangeAnchorAssetId = asset.id;
      _rangeTargetAssetId = null;
      _rangeAdding = false;
    });
    widget.onRemoveAsset(asset.id);
  }

  void _updateRangeTarget(StoryboardCutAsset asset) {
    if (_rangeAnchorAssetId == null || !(_shiftPressed || _isShiftPressed())) {
      return;
    }
    if (_rangeTargetAssetId == asset.id) {
      return;
    }
    setState(() => _rangeTargetAssetId = asset.id);
  }

  void _commitRangeSelection() {
    if (_rangeAnchorAssetId == null || _rangeTargetAssetId == null) {
      return;
    }
    final groups = <String, List<StoryboardCutAsset>>{};
    for (final asset in _ungroupedAssets()) {
      groups.putIfAbsent(asset.imageId, () => []).add(asset);
    }
    final rangeAssets = _rangeAssets(
      _visibleAssets(
        groups,
        _ungroupedFolders(),
        resourceGroups: widget.state.resourceGroups,
      ),
    );
    if (rangeAssets.isEmpty) {
      return;
    }
    widget.onSetAssetsUsed(rangeAssets, _rangeAdding);
  }

  List<StoryboardCutAsset> _visibleAssets(
    Map<String, List<StoryboardCutAsset>> groups,
    List<StoryboardFolder> folders, {
    List<StoryboardResourceGroup> resourceGroups = const [],
  }) {
    final groupsById = {for (final group in resourceGroups) group.id: group};
    final foldersById = {
      for (final folder in widget.state.folders) folder.id: folder,
    };
    final directAssetIds = {
      for (final group in resourceGroups) ...group.assetIds,
    };
    final result = <StoryboardCutAsset>[];
    final seenAssetIds = <String>{};
    void addAssets(Iterable<StoryboardCutAsset> assets) {
      for (final asset in assets) {
        if (seenAssetIds.add(asset.id)) {
          result.add(asset);
        }
      }
    }

    void visitNodes(List<String> nodeKeys) {
      for (final key in nodeKeys) {
        final node = StoryboardResourceNodeRef.tryParse(key);
        if (node == null) {
          continue;
        }
        switch (node.kind) {
          case StoryboardResourceNodeKind.group:
            final group = groupsById[node.id];
            if (group != null && group.expanded) {
              addAssets(_directAssetsForResourceGroup(group));
              visitNodes(_childResourceNodeKeys(group));
            }
            break;
          case StoryboardResourceNodeKind.folder:
            final folder = foldersById[node.id];
            if (folder != null && _expandedFolders.contains(folder.id)) {
              addAssets(_orderedAssetsForDisplay(folder.assets));
            }
            break;
          case StoryboardResourceNodeKind.source:
            if (_expandedSources.contains(node.id)) {
              addAssets(
                _orderedAssetsForDisplay(
                  widget.state.assets.where(
                    (asset) =>
                        asset.imageId == node.id &&
                        !directAssetIds.contains(asset.id),
                  ),
                ),
              );
            }
            break;
        }
      }
    }

    visitNodes(
      _rootResourceNodeKeys(
        ungroupedFolders: folders,
        ungroupedSourceIds: groups.keys,
      ),
    );
    return result;
  }

  Set<String> _previewAssetIds(List<StoryboardCutAsset> visibleAssets) {
    return _rangeAssets(visibleAssets).map((asset) => asset.id).toSet();
  }

  List<StoryboardCutAsset> _rangeAssets(
    List<StoryboardCutAsset> visibleAssets,
  ) {
    final anchorId = _rangeAnchorAssetId;
    final targetId = _rangeTargetAssetId;
    if (anchorId == null || targetId == null) {
      return const [];
    }
    final anchorIndex = visibleAssets.indexWhere(
      (asset) => asset.id == anchorId,
    );
    final targetIndex = visibleAssets.indexWhere(
      (asset) => asset.id == targetId,
    );
    if (anchorIndex < 0 || targetIndex < 0) {
      return const [];
    }
    final start = math.min(anchorIndex, targetIndex);
    final end = math.max(anchorIndex, targetIndex);
    return visibleAssets.sublist(start, end + 1);
  }
}

class _AssetSidebarHeader extends StatelessWidget {
  const _AssetSidebarHeader({
    required this.compact,
    required this.allExpanded,
    required this.canToggleAll,
    required this.assetOrderAscending,
    required this.groupModeEnabled,
    required this.onToggleAll,
    required this.onToggleAssetOrder,
    required this.onGroupModeChanged,
    required this.onCreateFolder,
    required this.onRefresh,
    required this.onCollapse,
  });

  final bool compact;
  final bool allExpanded;
  final bool canToggleAll;
  final bool assetOrderAscending;
  final bool groupModeEnabled;
  final VoidCallback onToggleAll;
  final VoidCallback onToggleAssetOrder;
  final ValueChanged<bool> onGroupModeChanged;
  final VoidCallback onCreateFolder;
  final Future<void> Function() onRefresh;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      '裁切资源',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    );
    final toggleAll = Tooltip(
      message: allExpanded ? '收纳全部' : '展开全部',
      child: TextButton.icon(
        key: const ValueKey('resource-expand-collapse-all'),
        onPressed: canToggleAll ? onToggleAll : null,
        icon: Icon(
          allExpanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
          size: 18,
        ),
        label: Text(allExpanded ? '收纳' : '展开'),
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
    final toggleOrder = Tooltip(
      message: assetOrderAscending ? '显示顺序：当前正序，点击切换为倒序' : '显示顺序：当前倒序，点击切换为正序',
      child: TextButton.icon(
        key: const ValueKey('resource-display-order-toggle'),
        onPressed: onToggleAssetOrder,
        icon: Icon(
          assetOrderAscending
              ? Icons.arrow_downward_rounded
              : Icons.arrow_upward_rounded,
          size: 17,
        ),
        label: Text(assetOrderAscending ? '正序' : '倒序'),
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
    final actions = <Widget>[
      _ResourceGroupModeToggle(
        enabled: groupModeEnabled,
        onChanged: onGroupModeChanged,
      ),
      const SizedBox(width: 4),
      _CompactHeaderButton(
        tooltip: '新建文件夹',
        onPressed: onCreateFolder,
        icon: Icons.create_new_folder_rounded,
      ),
      _CompactHeaderButton(
        tooltip: '刷新资源',
        onPressed: onRefresh,
        icon: Icons.refresh_rounded,
      ),
      _CompactHeaderButton(
        tooltip: '收起裁切资源',
        onPressed: onCollapse,
        icon: Icons.keyboard_double_arrow_left_rounded,
      ),
    ];
    if (!compact) {
      return Row(
        children: [
          Expanded(child: title),
          toggleAll,
          toggleOrder,
          ...actions,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: title),
            toggleAll,
            toggleOrder,
          ],
        ),
        Row(children: [const Spacer(), ...actions]),
      ],
    );
  }
}

class _CompactHeaderButton extends StatelessWidget {
  const _CompactHeaderButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }
}

class _ResourcePinButton extends StatelessWidget {
  const _ResourcePinButton({
    required this.nodeKey,
    required this.pinned,
    required this.onPressed,
  });

  final String nodeKey;
  final bool pinned;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: pinned ? '取消置顶' : '置顶文件夹',
      child: IconButton(
        key: ValueKey('resource-pin-$nodeKey'),
        onPressed: onPressed,
        icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
        iconSize: 17,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        style: IconButton.styleFrom(
          foregroundColor: pinned ? scheme.primary : scheme.onSurfaceVariant,
          backgroundColor: pinned
              ? scheme.primaryContainer.withValues(alpha: 0.62)
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
    );
  }
}

enum _ResourceDropPlacement { before, inside, after }

typedef _ResourceNodeDropCallback =
    void Function(
      _ResourceNodeDragData data,
      _ResourceNodeDragData target,
      String? targetParentGroupId,
      List<String> siblingKeys,
      _ResourceDropPlacement placement,
    );

class _ResourceNodeDragData {
  const _ResourceNodeDragData({
    required this.kind,
    required this.id,
    required this.label,
  });

  factory _ResourceNodeDragData.group(StoryboardResourceGroup group) {
    return _ResourceNodeDragData(
      kind: StoryboardResourceNodeKind.group,
      id: group.id,
      label: group.name,
    );
  }

  factory _ResourceNodeDragData.folder(StoryboardFolder folder) {
    return _ResourceNodeDragData(
      kind: StoryboardResourceNodeKind.folder,
      id: folder.id,
      label: folder.name,
    );
  }

  factory _ResourceNodeDragData.source(String id, String label) {
    return _ResourceNodeDragData(
      kind: StoryboardResourceNodeKind.source,
      id: id,
      label: label,
    );
  }

  final StoryboardResourceNodeKind kind;
  final String id;
  final String label;

  String get nodeKey => StoryboardResourceNodeRef(kind: kind, id: id).key;
}

class _ResourceNodeDraggable extends StatelessWidget {
  const _ResourceNodeDraggable({required this.data, required this.child});

  final _ResourceNodeDragData data;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Draggable<_ResourceNodeDragData>(
      key: ValueKey('resource-node-draggable-${data.nodeKey}'),
      data: data,
      maxSimultaneousDrags: 1,
      rootOverlay: true,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _ResourceNodeDragFeedback(data: data),
      childWhenDragging: Opacity(opacity: 0.48, child: child),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }
}

class _ResourceNodeDragFeedback extends StatelessWidget {
  const _ResourceNodeDragFeedback({required this.data});

  final _ResourceNodeDragData data;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              data.kind == StoryboardResourceNodeKind.source
                  ? Icons.image_rounded
                  : Icons.folder_rounded,
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                data.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResourceNodeDropTarget extends StatefulWidget {
  const _ResourceNodeDropTarget({
    required this.target,
    required this.parentGroupId,
    required this.siblingKeys,
    required this.onDrop,
    required this.child,
  });

  final _ResourceNodeDragData target;
  final String? parentGroupId;
  final List<String> siblingKeys;
  final _ResourceNodeDropCallback onDrop;
  final Widget child;

  @override
  State<_ResourceNodeDropTarget> createState() =>
      _ResourceNodeDropTargetState();
}

class _ResourceNodeDropTargetState extends State<_ResourceNodeDropTarget> {
  _ResourceDropPlacement _placement = _ResourceDropPlacement.before;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<_ResourceNodeDragData>(
      key: ValueKey('resource-node-drop-${widget.target.nodeKey}'),
      onWillAcceptWithDetails: (details) =>
          details.data.nodeKey != widget.target.nodeKey,
      onMove: (details) => _updatePlacement(details.data, details.offset),
      onLeave: (_) {
        if (mounted) {
          setState(() => _placement = _ResourceDropPlacement.before);
        }
      },
      onAcceptWithDetails: (details) {
        _updatePlacement(details.data, details.offset, rebuild: false);
        widget.onDrop(
          details.data,
          widget.target,
          widget.parentGroupId,
          widget.siblingKeys,
          _placement,
        );
      },
      builder: (context, candidates, _) {
        final highlighted = candidates.isNotEmpty;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            if (highlighted)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: _placement == _ResourceDropPlacement.inside
                          ? Border.all(color: scheme.primary, width: 2)
                          : null,
                    ),
                  ),
                ),
              ),
            if (highlighted && _placement != _ResourceDropPlacement.inside)
              Positioned(
                left: 2,
                right: 2,
                top: _placement == _ResourceDropPlacement.before ? -2 : null,
                bottom: _placement == _ResourceDropPlacement.after ? -2 : null,
                child: IgnorePointer(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _updatePlacement(
    _ResourceNodeDragData data,
    Offset globalOffset, {
    bool rebuild = true,
  }) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) {
      return;
    }
    final local = renderBox.globalToLocal(globalOffset);
    final ratio = (local.dy / renderBox.size.height).clamp(0.0, 1.0);
    final next =
        widget.target.kind == StoryboardResourceNodeKind.group &&
            ratio >= 0.25 &&
            ratio <= 0.75
        ? _ResourceDropPlacement.inside
        : ratio < 0.5
        ? _ResourceDropPlacement.before
        : _ResourceDropPlacement.after;
    if (next == _placement) {
      return;
    }
    if (rebuild && mounted) {
      setState(() => _placement = next);
    } else {
      _placement = next;
    }
  }
}

class _ResourceSequenceBadge extends StatelessWidget {
  const _ResourceSequenceBadge({required this.sequence});

  final String sequence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '顺序 $sequence · 可拖拽排序',
      child: Container(
        key: ValueKey('resource-sequence-$sequence'),
        constraints: const BoxConstraints(minWidth: 25),
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.42)),
        ),
        child: Text(
          sequence,
          style: TextStyle(
            color: scheme.primary,
            fontSize: sequence.length > 3 ? 9 : 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _ResourceGroupSection extends StatelessWidget {
  const _ResourceGroupSection({
    required this.group,
    required this.sequence,
    required this.pinned,
    required this.parentGroupId,
    required this.siblingKeys,
    required this.headerAssets,
    required this.headerFolders,
    required this.childGroupCount,
    required this.directAssets,
    required this.assetGridKey,
    required this.focusedAssetId,
    required this.childNodes,
    required this.usedIds,
    required this.previewIds,
    required this.previewAdding,
    required this.thumbnailSize,
    required this.onToggleExpanded,
    required this.onTogglePinned,
    required this.onToggleAsset,
    required this.onRemoveAsset,
    required this.onRangeHover,
    required this.onCreateAssetResourceGroup,
    required this.onMoveNode,
    required this.onRename,
  });

  final StoryboardResourceGroup group;
  final String sequence;
  final bool pinned;
  final String? parentGroupId;
  final List<String> siblingKeys;
  final List<StoryboardCutAsset> headerAssets;
  final List<StoryboardFolder> headerFolders;
  final int childGroupCount;
  final List<StoryboardCutAsset> directAssets;
  final Key? assetGridKey;
  final String? focusedAssetId;
  final List<Widget> childNodes;
  final Set<String> usedIds;
  final Set<String> previewIds;
  final bool previewAdding;
  final double thumbnailSize;
  final VoidCallback onToggleExpanded;
  final VoidCallback onTogglePinned;
  final ValueChanged<StoryboardCutAsset> onToggleAsset;
  final ValueChanged<StoryboardCutAsset> onRemoveAsset;
  final ValueChanged<StoryboardCutAsset> onRangeHover;
  final ValueChanged<StoryboardCutAsset> onCreateAssetResourceGroup;
  final _ResourceNodeDropCallback onMoveNode;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final hasExpandedContent = directAssets.isNotEmpty || childNodes.isNotEmpty;
    final dragData = _ResourceNodeDragData.group(group);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResourceNodeDropTarget(
            target: dragData,
            parentGroupId: parentGroupId,
            siblingKeys: siblingKeys,
            onDrop: onMoveNode,
            child: _ResourceNodeDraggable(
              data: dragData,
              child: _ResourceGroupHeader(
                group: group,
                sequence: sequence,
                pinned: pinned,
                assets: headerAssets,
                folders: headerFolders,
                childGroupCount: childGroupCount,
                usedIds: usedIds,
                onTap: onToggleExpanded,
                onTogglePinned: onTogglePinned,
                onRename: onRename,
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: group.expanded && hasExpandedContent
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8, left: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...childNodes,
                  if (childNodes.isNotEmpty && directAssets.isNotEmpty)
                    const SizedBox(height: 4),
                  if (directAssets.isNotEmpty)
                    ViewportLazyGrid(
                      key: assetGridKey,
                      itemCount: directAssets.length,
                      itemExtent: thumbnailSize,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      itemBuilder: (context, index) {
                        final asset = directAssets[index];
                        return _AssetThumb(
                          asset: asset,
                          used: usedIds.contains(asset.id),
                          rangePreviewed: previewIds.contains(asset.id),
                          rangeAdding: previewAdding,
                          focused: asset.id == focusedAssetId,
                          size: thumbnailSize,
                          onTap: () => onToggleAsset(asset),
                          onSecondaryTap: () => onRemoveAsset(asset),
                          onCreateResourceGroup: () =>
                              onCreateAssetResourceGroup(asset),
                          onRangeHover: () => onRangeHover(asset),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceGroupModeToggle extends StatelessWidget {
  const _ResourceGroupModeToggle({
    required this.enabled,
    required this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? '关闭裁切资源编组模式' : '开启裁切资源编组模式',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!enabled),
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                key: const ValueKey('resource-group-mode-toggle'),
                value: enabled,
                onChanged: (value) => onChanged(value ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const Text('编组'),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceGroupSelectionScope extends InheritedWidget {
  const _ResourceGroupSelectionScope({
    required this.enabled,
    required this.selectedSourceImageIds,
    required this.selectedFolderIds,
    required this.onSourceCheckedChanged,
    required this.onFolderCheckedChanged,
    required super.child,
  });

  final bool enabled;
  final Set<String> selectedSourceImageIds;
  final Set<String> selectedFolderIds;
  final void Function(String sourceImageId, bool checked)
  onSourceCheckedChanged;
  final void Function(String folderId, bool checked) onFolderCheckedChanged;

  static _ResourceGroupSelectionScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_ResourceGroupSelectionScope>();
  }

  @override
  bool updateShouldNotify(_ResourceGroupSelectionScope oldWidget) {
    return oldWidget.enabled != enabled ||
        !setEquals(oldWidget.selectedSourceImageIds, selectedSourceImageIds) ||
        !setEquals(oldWidget.selectedFolderIds, selectedFolderIds);
  }
}

class _ResourceGroupHeader extends StatelessWidget {
  const _ResourceGroupHeader({
    required this.group,
    required this.sequence,
    required this.pinned,
    required this.assets,
    required this.folders,
    required this.childGroupCount,
    required this.usedIds,
    required this.onTap,
    required this.onTogglePinned,
    required this.onRename,
  });

  final StoryboardResourceGroup group;
  final String sequence;
  final bool pinned;
  final List<StoryboardCutAsset> assets;
  final List<StoryboardFolder> folders;
  final int childGroupCount;
  final Set<String> usedIds;
  final VoidCallback onTap;
  final VoidCallback onTogglePinned;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final directAssetCount = assets.length;
    final folderAssetCount = folders.fold<int>(
      0,
      (total, folder) => total + folder.assets.length,
    );
    final usedCount =
        assets.where((asset) => usedIds.contains(asset.id)).length +
        folders.fold<int>(
          0,
          (total, folder) =>
              total +
              folder.assets.where((asset) => usedIds.contains(asset.id)).length,
        );
    final parts = <String>[
      if (childGroupCount > 0) '$childGroupCount 个子编组',
      if (folders.isNotEmpty) '${folders.length} 个文件夹',
      if (directAssetCount > 0) '$directAssetCount 张图片',
      if (childGroupCount == 0 &&
          folders.isEmpty &&
          directAssetCount == 0 &&
          folderAssetCount == 0)
        '暂无资源',
    ];
    final summary = [
      parts.join(' · '),
      if (usedCount > 0) '已用 $usedCount',
    ].join(' · ');

    return Tooltip(
      message: group.expanded ? '收起编组' : '展开编组',
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: group.expanded
                ? scheme.secondaryContainer.withValues(alpha: 0.5)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: group.expanded
                  ? scheme.secondary.withValues(alpha: 0.5)
                  : scheme.outlineVariant.withValues(alpha: 0.62),
            ),
          ),
          child: Row(
            children: [
              _ResourceSequenceBadge(sequence: sequence),
              const SizedBox(width: 7),
              _ResourceGroupPreview(assets: assets, folders: folders),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _ResourcePinButton(
                nodeKey: StoryboardResourceNodeRef.group(group.id).key,
                pinned: pinned,
                onPressed: onTogglePinned,
              ),
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: group.expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final action = await showMenu<_ResourceGroupContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(
          value: _ResourceGroupContextAction.rename,
          child: Row(
            children: [
              Icon(Icons.edit_rounded, size: 18),
              SizedBox(width: 10),
              Text('重命名'),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _ResourceGroupContextAction.rename:
        onRename();
    }
  }
}

class _ResourceGroupPreview extends StatelessWidget {
  const _ResourceGroupPreview({required this.assets, required this.folders});

  final List<StoryboardCutAsset> assets;
  final List<StoryboardFolder> folders;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final asset = _previewAsset();
    if (asset == null) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          Icons.folder_copy_rounded,
          color: scheme.onSecondaryContainer,
        ),
      );
    }
    final imageProvider = previewFileImageProvider(
      path: asset.path,
      logicalWidth: 42,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 256,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: imageProvider,
        width: 42,
        height: 42,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }

  StoryboardCutAsset? _previewAsset() {
    if (assets.isNotEmpty) {
      return assets.first;
    }
    for (final folder in folders) {
      if (folder.assets.isNotEmpty) {
        return folder.assets.first;
      }
    }
    return null;
  }
}

class _ThumbnailSizeControl extends StatelessWidget {
  const _ThumbnailSizeControl({
    required this.size,
    required this.min,
    required this.max,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onChanged,
  });

  final double size;
  final double min;
  final double max;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.48)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Tooltip(
                  message: '缩略图尺寸',
                  child: IconButton(
                    isSelected: expanded,
                    onPressed: onToggleExpanded,
                    icon: const Icon(Icons.photo_size_select_large_rounded),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '缩略图 ${size.round()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 160),
              crossFadeState: expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Slider(
                key: const ValueKey('asset-thumbnail-size-slider'),
                value: size,
                min: min,
                max: max,
                divisions: (max - min).round(),
                label: '${size.round()}',
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetFolderGroup extends StatefulWidget {
  const _AssetFolderGroup({
    required this.folder,
    required this.sequence,
    required this.pinned,
    required this.parentGroupId,
    required this.siblingKeys,
    required this.expanded,
    required this.usedIds,
    required this.previewIds,
    required this.previewAdding,
    required this.thumbnailSize,
    required this.assetGridKey,
    required this.focusedAssetId,
    required this.onToggleExpanded,
    required this.onTogglePinned,
    required this.onToggleAsset,
    required this.onRemoveAsset,
    required this.onDeleteAsset,
    required this.onOpenDirectory,
    required this.onDeleteFolder,
    required this.onRangeHover,
    required this.onCreateAssetResourceGroup,
    required this.onDropAsset,
    required this.onDropPaths,
    required this.onMoveNode,
  });

  final StoryboardFolder folder;
  final String sequence;
  final bool pinned;
  final String? parentGroupId;
  final List<String> siblingKeys;
  final bool expanded;
  final Set<String> usedIds;
  final Set<String> previewIds;
  final bool previewAdding;
  final double thumbnailSize;
  final Key? assetGridKey;
  final String? focusedAssetId;
  final VoidCallback onToggleExpanded;
  final VoidCallback onTogglePinned;
  final ValueChanged<StoryboardCutAsset> onToggleAsset;
  final ValueChanged<StoryboardCutAsset> onRemoveAsset;
  final ValueChanged<StoryboardCutAsset> onDeleteAsset;
  final VoidCallback onOpenDirectory;
  final VoidCallback onDeleteFolder;
  final ValueChanged<StoryboardCutAsset> onRangeHover;
  final ValueChanged<StoryboardCutAsset> onCreateAssetResourceGroup;
  final ValueChanged<StoryboardCutAsset> onDropAsset;
  final ValueChanged<Iterable<String>> onDropPaths;
  final _ResourceNodeDropCallback onMoveNode;

  @override
  State<_AssetFolderGroup> createState() => _AssetFolderGroupState();
}

class _AssetFolderGroupState extends State<_AssetFolderGroup> {
  final _canvasDropTargetKey = GlobalKey();
  _StoryboardFolderDropCoordinator? _folderDropCoordinator;
  bool _externalDragging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coordinator = _StoryboardFolderDropScope.maybeOf(context);
    if (identical(_folderDropCoordinator, coordinator)) return;
    _unregisterCanvasDropTarget();
    _folderDropCoordinator = coordinator;
    _folderDropCoordinator?.addListener(_handleFolderDropChanged);
    _registerCanvasDropTarget();
  }

  @override
  void didUpdateWidget(covariant _AssetFolderGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder.id != widget.folder.id) {
      _folderDropCoordinator?.unregisterTarget(oldWidget.folder.id);
    }
    _registerCanvasDropTarget();
  }

  @override
  void dispose() {
    _unregisterCanvasDropTarget();
    super.dispose();
  }

  void _registerCanvasDropTarget() {
    _folderDropCoordinator?.registerTarget(
      folderId: widget.folder.id,
      contains: _containsCanvasDragPosition,
      onDrop: (assets) => widget.onDropPaths(
        assets.map((asset) => asset.path).toList(growable: false),
      ),
    );
  }

  void _unregisterCanvasDropTarget() {
    final coordinator = _folderDropCoordinator;
    if (coordinator == null) return;
    coordinator
      ..removeListener(_handleFolderDropChanged)
      ..unregisterTarget(widget.folder.id);
    _folderDropCoordinator = null;
  }

  bool _containsCanvasDragPosition(Offset globalPosition) {
    final renderObject = _canvasDropTargetKey.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return false;
    }
    final localPosition = renderObject.globalToLocal(globalPosition);
    return (Offset.zero & renderObject.size).contains(localPosition);
  }

  void _handleFolderDropChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final canvasDragging =
        _folderDropCoordinator?.hoveredFolderId == widget.folder.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: KeyedSubtree(
        key: _canvasDropTargetKey,
        child: DropTarget(
          enable: DesktopDropTargetScope.enabledOf(context),
          onDragEntered: (_) => setState(() => _externalDragging = true),
          onDragExited: (_) => setState(() => _externalDragging = false),
          onDragDone: (details) {
            setState(() => _externalDragging = false);
            widget.onDropPaths(details.files.map((file) => file.path));
          },
          child: DragTarget<StoryboardCutAsset>(
            onWillAcceptWithDetails: (_) => true,
            onAcceptWithDetails: (details) => widget.onDropAsset(details.data),
            builder: (context, candidateData, _) {
              final highlighted =
                  canvasDragging ||
                  _externalDragging ||
                  candidateData.isNotEmpty;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ResourceNodeDropTarget(
                    target: _ResourceNodeDragData.folder(widget.folder),
                    parentGroupId: widget.parentGroupId,
                    siblingKeys: widget.siblingKeys,
                    onDrop: widget.onMoveNode,
                    child: _ResourceNodeDraggable(
                      data: _ResourceNodeDragData.folder(widget.folder),
                      child: _FolderHeader(
                        folder: widget.folder,
                        sequence: widget.sequence,
                        pinned: widget.pinned,
                        expanded: widget.expanded,
                        highlighted: highlighted,
                        usedIds: widget.usedIds,
                        onTap: widget.onToggleExpanded,
                        onTogglePinned: widget.onTogglePinned,
                        onOpenDirectory: widget.onOpenDirectory,
                        onDeleteFolder: widget.onDeleteFolder,
                      ),
                    ),
                  ),
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 180),
                    crossFadeState: widget.expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    firstChild: const SizedBox.shrink(),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: widget.folder.assets.isEmpty
                          ? _EmptyFolderHint(highlighted: highlighted)
                          : ViewportLazyGrid(
                              key: widget.assetGridKey,
                              itemCount: widget.folder.assets.length,
                              itemExtent: widget.thumbnailSize,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              itemBuilder: (context, index) {
                                final asset = widget.folder.assets[index];
                                return _AssetThumb(
                                  asset: asset,
                                  used: widget.usedIds.contains(asset.id),
                                  rangePreviewed: widget.previewIds.contains(
                                    asset.id,
                                  ),
                                  rangeAdding: widget.previewAdding,
                                  focused: asset.id == widget.focusedAssetId,
                                  size: widget.thumbnailSize,
                                  onTap: () => widget.onToggleAsset(asset),
                                  onSecondaryTap: () =>
                                      widget.onRemoveAsset(asset),
                                  onDelete: () => widget.onDeleteAsset(asset),
                                  onCreateResourceGroup: () =>
                                      widget.onCreateAssetResourceGroup(asset),
                                  onRangeHover: () =>
                                      widget.onRangeHover(asset),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    required this.folder,
    required this.sequence,
    required this.pinned,
    required this.expanded,
    required this.highlighted,
    required this.usedIds,
    required this.onTap,
    required this.onTogglePinned,
    required this.onOpenDirectory,
    required this.onDeleteFolder,
  });

  final StoryboardFolder folder;
  final String sequence;
  final bool pinned;
  final bool expanded;
  final bool highlighted;
  final Set<String> usedIds;
  final VoidCallback onTap;
  final VoidCallback onTogglePinned;
  final VoidCallback onOpenDirectory;
  final VoidCallback onDeleteFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groupSelection = _ResourceGroupSelectionScope.maybeOf(context);
    final groupModeEnabled = groupSelection?.enabled ?? false;
    final groupChecked =
        groupSelection?.selectedFolderIds.contains(folder.id) ?? false;
    final usedCount = folder.assets
        .where((asset) => usedIds.contains(asset.id))
        .length;
    final borderColor = highlighted
        ? scheme.primary.withValues(alpha: 0.82)
        : expanded
        ? scheme.primary.withValues(alpha: 0.45)
        : scheme.outlineVariant.withValues(alpha: 0.62);
    return Tooltip(
      message: '拖入图片保存到文件夹',
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          key: ValueKey('storyboard-folder-drop-highlight-${folder.id}'),
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: highlighted
                ? scheme.primaryContainer.withValues(alpha: 0.72)
                : expanded
                ? scheme.primaryContainer.withValues(alpha: 0.42)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: highlighted ? 2 : 1),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.38),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : const [],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                _ResourceSequenceBadge(sequence: sequence),
                const SizedBox(width: 7),
                if (groupModeEnabled) ...[
                  Checkbox(
                    key: ValueKey(
                      'resource-group-folder-checkbox-${folder.id}',
                    ),
                    value: groupChecked,
                    onChanged: (value) => groupSelection
                        ?.onFolderCheckedChanged(folder.id, value ?? false),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    checkColor: scheme.onPrimary,
                    fillColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? scheme.primary
                          : scheme.surfaceContainerHighest;
                    }),
                    side: BorderSide(color: scheme.onSurface, width: 2),
                  ),
                  const SizedBox(width: 4),
                ],
                if (!groupModeEnabled) ...[
                  _FolderPreview(folder: folder),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        usedCount == 0
                            ? '${folder.assets.length} 张图片'
                            : '${folder.assets.length} 张图片 · 已用 $usedCount',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _ResourcePinButton(
                  nodeKey: StoryboardResourceNodeRef.folder(folder.id).key,
                  pinned: pinned,
                  onPressed: onTogglePinned,
                ),
                if (constraints.maxWidth >= 230)
                  IconButton(
                    key: ValueKey('delete-storyboard-folder-${folder.id}'),
                    tooltip: '删除文件夹',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 20,
                      height: 24,
                    ),
                    onPressed: onDeleteFolder,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 15,
                      color: scheme.error,
                    ),
                  ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final action = await showMenu<_FolderContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: const [
        PopupMenuItem<_FolderContextAction>(
          value: _FolderContextAction.openDirectory,
          child: Row(
            children: [
              Icon(Icons.folder_open_rounded, size: 18),
              SizedBox(width: 10),
              Text('打开目录'),
            ],
          ),
        ),
        PopupMenuItem<_FolderContextAction>(
          value: _FolderContextAction.deleteFolder,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 18),
              SizedBox(width: 10),
              Text('删除文件夹'),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _FolderContextAction.openDirectory:
        onOpenDirectory();
      case _FolderContextAction.deleteFolder:
        onDeleteFolder();
    }
  }
}

class _FolderPreview extends StatelessWidget {
  const _FolderPreview({required this.folder});

  final StoryboardFolder folder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (folder.assets.isEmpty) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.folder_rounded, color: scheme.onSecondaryContainer),
      );
    }
    final imageProvider = previewFileImageProvider(
      path: folder.assets.first.path,
      logicalWidth: 42,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 256,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: imageProvider,
        width: 42,
        height: 42,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }
}

class _EmptyFolderHint extends StatelessWidget {
  const _EmptyFolderHint({required this.highlighted});

  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: highlighted
            ? scheme.primaryContainer.withValues(alpha: 0.56)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted
              ? scheme.primary.withValues(alpha: 0.74)
              : scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Text(
        '空文件夹',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AssetGroup extends StatelessWidget {
  const _AssetGroup({
    required this.sequence,
    required this.pinned,
    required this.parentGroupId,
    required this.siblingKeys,
    required this.title,
    required this.assets,
    required this.expanded,
    required this.usedIds,
    required this.previewIds,
    required this.previewAdding,
    required this.thumbnailSize,
    required this.assetGridKey,
    required this.focusedAssetId,
    required this.onToggleExpanded,
    required this.onTogglePinned,
    required this.onToggleAsset,
    required this.onRemoveAsset,
    required this.onRangeHover,
    required this.onCreateAssetResourceGroup,
    required this.onDeleteGroup,
    required this.onMoveNode,
  });

  final String sequence;
  final bool pinned;
  final String? parentGroupId;
  final List<String> siblingKeys;
  final String title;
  final List<StoryboardCutAsset> assets;
  final bool expanded;
  final Set<String> usedIds;
  final Set<String> previewIds;
  final bool previewAdding;
  final double thumbnailSize;
  final Key? assetGridKey;
  final String? focusedAssetId;
  final VoidCallback onToggleExpanded;
  final VoidCallback onTogglePinned;
  final ValueChanged<StoryboardCutAsset> onToggleAsset;
  final ValueChanged<StoryboardCutAsset> onRemoveAsset;
  final ValueChanged<StoryboardCutAsset> onRangeHover;
  final ValueChanged<StoryboardCutAsset> onCreateAssetResourceGroup;
  final VoidCallback onDeleteGroup;
  final _ResourceNodeDropCallback onMoveNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firstAsset = assets.first;
    final groupSelection = _ResourceGroupSelectionScope.maybeOf(context);
    final groupModeEnabled = groupSelection?.enabled ?? false;
    final groupChecked =
        groupSelection?.selectedSourceImageIds.contains(firstAsset.imageId) ??
        false;
    final usedCount = assets
        .where((asset) => usedIds.contains(asset.id))
        .length;
    final dragData = _ResourceNodeDragData.source(firstAsset.imageId, title);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResourceNodeDropTarget(
            target: dragData,
            parentGroupId: parentGroupId,
            siblingKeys: siblingKeys,
            onDrop: onMoveNode,
            child: _ResourceNodeDraggable(
              data: dragData,
              child: Tooltip(
                message: expanded ? '收起裁切资源' : '展开裁切资源',
                child: InkWell(
                  onTap: onToggleExpanded,
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: expanded
                          ? scheme.primaryContainer.withValues(alpha: 0.42)
                          : scheme.surfaceContainerHighest.withValues(
                              alpha: 0.38,
                            ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: expanded
                            ? scheme.primary.withValues(alpha: 0.45)
                            : scheme.outlineVariant.withValues(alpha: 0.62),
                      ),
                    ),
                    child: Row(
                      children: [
                        _ResourceSequenceBadge(sequence: sequence),
                        const SizedBox(width: 7),
                        if (groupModeEnabled) ...[
                          Checkbox(
                            key: ValueKey(
                              'resource-group-source-checkbox-${firstAsset.imageId}',
                            ),
                            value: groupChecked,
                            onChanged: (value) =>
                                groupSelection?.onSourceCheckedChanged(
                                  firstAsset.imageId,
                                  value ?? false,
                                ),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            checkColor: scheme.onPrimary,
                            fillColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              return states.contains(WidgetState.selected)
                                  ? scheme.primary
                                  : scheme.surfaceContainerHighest;
                            }),
                            side: BorderSide(color: scheme.onSurface, width: 2),
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (!groupModeEnabled) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(
                              File(firstAsset.path),
                              width: 36,
                              height: 36,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                usedCount == 0
                                    ? '${assets.length} 张裁切图'
                                    : '${assets.length} 张裁切图 · 已用 $usedCount',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        _ResourcePinButton(
                          nodeKey: StoryboardResourceNodeRef.source(
                            firstAsset.imageId,
                          ).key,
                          pinned: pinned,
                          onPressed: onTogglePinned,
                        ),
                        const SizedBox(width: 2),
                        AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (!groupModeEnabled) ...[
                          const SizedBox(width: 2),
                          Tooltip(
                            message: '删除这组裁切资源',
                            child: IconButton(
                              onPressed: onDeleteGroup,
                              icon: const Icon(Icons.delete_outline_rounded),
                              iconSize: 18,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 30,
                                height: 30,
                              ),
                              style: IconButton.styleFrom(
                                foregroundColor: scheme.error,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(7),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ViewportLazyGrid(
                key: assetGridKey,
                itemCount: assets.length,
                itemExtent: thumbnailSize,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                itemBuilder: (context, index) {
                  final asset = assets[index];
                  return _AssetThumb(
                    asset: asset,
                    used: usedIds.contains(asset.id),
                    rangePreviewed: previewIds.contains(asset.id),
                    rangeAdding: previewAdding,
                    focused: asset.id == focusedAssetId,
                    size: thumbnailSize,
                    onTap: () => onToggleAsset(asset),
                    onSecondaryTap: () => onRemoveAsset(asset),
                    onCreateResourceGroup: () =>
                        onCreateAssetResourceGroup(asset),
                    onRangeHover: () => onRangeHover(asset),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({
    required this.asset,
    required this.used,
    required this.rangePreviewed,
    required this.rangeAdding,
    this.focused = false,
    required this.size,
    required this.onTap,
    required this.onSecondaryTap,
    this.onDelete,
    required this.onCreateResourceGroup,
    required this.onRangeHover,
  });

  final StoryboardCutAsset asset;
  final bool used;
  final bool rangePreviewed;
  final bool rangeAdding;
  final bool focused;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onSecondaryTap;
  final VoidCallback? onDelete;
  final VoidCallback onCreateResourceGroup;
  final VoidCallback onRangeHover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imageProvider = previewFileImageProvider(
      path: asset.path,
      logicalWidth: math.max(1, size - 6),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 512,
    );
    final groupSelection = _ResourceGroupSelectionScope.maybeOf(context);
    final groupModeEnabled = groupSelection?.enabled ?? false;
    final previewColor = rangeAdding ? scheme.primary : scheme.error;
    final fillColor = focused
        ? scheme.tertiaryContainer.withValues(alpha: 0.88)
        : used
        ? scheme.primaryContainer.withValues(alpha: 0.75)
        : rangePreviewed
        ? previewColor.withValues(alpha: 0.22)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.42);
    final borderColor = focused
        ? scheme.tertiary
        : used
        ? scheme.primary.withValues(alpha: 0.58)
        : rangePreviewed
        ? previewColor.withValues(alpha: 0.92)
        : scheme.outlineVariant.withValues(alpha: 0.6);
    final thumb = Tooltip(
      message: used ? '右键打开菜单' : '点击加入画布',
      child: MouseRegion(
        onEnter: (_) => onRangeHover(),
        onHover: (_) => onRangeHover(),
        child: GestureDetector(
          onTap: onTap,
          onSecondaryTapDown: (details) =>
              _showAssetMenu(context, details.globalPosition),
          child: AnimatedContainer(
            key: ValueKey('asset-thumb-${asset.id}'),
            duration: const Duration(milliseconds: 180),
            width: size,
            height: size,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: borderColor,
                width: focused
                    ? 3
                    : rangePreviewed
                    ? 2
                    : 1,
              ),
              boxShadow: focused || used || rangePreviewed
                  ? [
                      BoxShadow(
                        color:
                            (focused
                                    ? scheme.tertiary
                                    : rangePreviewed
                                    ? previewColor
                                    : scheme.primary)
                                .withValues(alpha: focused ? 0.42 : 0.18),
                        blurRadius: focused ? 24 : 16,
                        spreadRadius: focused ? 2 : 0,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image(
                    image: imageProvider,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
                if (focused)
                  Positioned(
                    left: 3,
                    top: 3,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: scheme.tertiary,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Icon(
                        Icons.my_location_rounded,
                        key: ValueKey('asset-located-${asset.id}'),
                        size: 14,
                        color: scheme.onTertiary,
                      ),
                    ),
                  ),
                if (!groupModeEnabled && rangePreviewed)
                  Positioned(
                    left: 3,
                    top: 3,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: previewColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Icon(
                        rangeAdding ? Icons.add_rounded : Icons.remove_rounded,
                        size: 14,
                        color: rangeAdding ? scheme.onPrimary : scheme.onError,
                      ),
                    ),
                  ),
                if (onDelete != null)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: Tooltip(
                      message: '删除图片',
                      child: IconButton(
                        key: ValueKey('delete-folder-asset-${asset.id}'),
                        onPressed: onDelete,
                        icon: const Icon(Icons.close_rounded),
                        iconSize: 14,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 22,
                          height: 22,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.error.withValues(alpha: 0.92),
                          foregroundColor: scheme.onError,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 3,
                  bottom: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.64),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '${asset.indexNo}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Draggable<StoryboardCutAsset>(
      data: asset,
      maxSimultaneousDrags: 1,
      feedback: _AssetDragFeedback(asset: asset, size: size),
      childWhenDragging: Opacity(opacity: 0.55, child: thumb),
      child: thumb,
    );
  }

  Future<void> _showAssetMenu(BuildContext context, Offset position) async {
    final groupSelection = _ResourceGroupSelectionScope.maybeOf(context);
    final canCreateGroup =
        groupSelection?.enabled == true &&
        groupSelection!.selectedSourceImageIds.contains(asset.imageId);
    final action = await showImageFileContextMenu<_ResourceContextAction>(
      context,
      globalPosition: position,
      imagePath: asset.path,
      leadingActions: [
        ImageFileContextMenuAction(
          value: _ResourceContextAction.toggleUse,
          icon: used
              ? Icons.remove_circle_outline_rounded
              : Icons.add_photo_alternate_rounded,
          label: used ? '取消使用' : '加入画布',
        ),
        if (canCreateGroup)
          const ImageFileContextMenuAction(
            value: _ResourceContextAction.createGroup,
            icon: Icons.folder_copy_rounded,
            label: '编组',
          ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _ResourceContextAction.toggleUse:
        if (used) {
          onSecondaryTap();
        } else {
          onTap();
        }
        break;
      case _ResourceContextAction.createGroup:
        onCreateResourceGroup();
        break;
    }
  }
}

class _AssetDragFeedback extends StatelessWidget {
  const _AssetDragFeedback({required this.asset, required this.size});

  final StoryboardCutAsset asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final imageProvider = previewFileImageProvider(
      path: asset.path,
      logicalWidth: math.max(1, size - 6),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 512,
    );
    return Material(
      color: Colors.transparent,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: RepaintBoundary(
            child: Image(
              image: imageProvider,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryboardCanvas extends StatelessWidget {
  const _StoryboardCanvas({
    required this.state,
    required this.onManageBoards,
    required this.onAddBoard,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleLock,
    required this.onMove,
    required this.onMoveItems,
    required this.onPlaceAsset,
    required this.onRemove,
    required this.onFlipHorizontal,
    required this.onFlipVertical,
    required this.onEditImage,
    required this.onLocateAsset,
    required this.onPickReplacementImage,
    required this.onDropReplacementImages,
    required this.onCaptionChanged,
    required this.onRowCaptionChanged,
    required this.showOriginalStoryboard,
    required this.originalPathForItem,
    required this.onCompareImage,
  });

  final StoryboardState state;
  final VoidCallback onManageBoards;
  final VoidCallback onAddBoard;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onToggleLock;
  final void Function(int from, int to) onMove;
  final void Function(Set<String> assetIds, int to) onMoveItems;
  final void Function(StoryboardCutAsset asset, int slotIndex) onPlaceAsset;
  final ValueChanged<String> onRemove;
  final ValueChanged<int> onFlipHorizontal;
  final ValueChanged<int> onFlipVertical;
  final ValueChanged<StoryboardItem> onEditImage;
  final ValueChanged<StoryboardItem> onLocateAsset;
  final ValueChanged<StoryboardItem> onPickReplacementImage;
  final void Function(StoryboardItem item, Iterable<String> paths)
  onDropReplacementImages;
  final void Function(int index, String caption) onCaptionChanged;
  final void Function(int rowIndex, String caption) onRowCaptionChanged;
  final bool showOriginalStoryboard;
  final String? Function(StoryboardItem item) originalPathForItem;
  final ValueChanged<StoryboardItem> onCompareImage;

  @override
  Widget build(BuildContext context) {
    final board = state.selectedBoard;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: board == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tab_unselected_rounded,
                    size: 48,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '当前没有打开的画板',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '关闭页签不会删除画板，可从画板管理中重新打开。',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onManageBoards,
                        icon: const Icon(Icons.dashboard_customize_outlined),
                        label: const Text('画板管理'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        onPressed: onAddBoard,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('新画板'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 520;
                      final title = Text(
                        board.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      );
                      final historyActions = _StoryboardHistoryActions(
                        canUndo: canUndo,
                        canRedo: canRedo,
                        locked: board.locked,
                        onUndo: onUndo,
                        onRedo: onRedo,
                        onToggleLock: onToggleLock,
                      );
                      if (compact) {
                        return SizedBox(
                          height: 32,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned.fill(
                                right: 102,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: title,
                                ),
                              ),
                              Positioned(right: 0, child: historyActions),
                            ],
                          ),
                        );
                      }
                      return Row(
                        children: [
                          Expanded(flex: 2, child: title),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: Text(
                              '${board.width} x ${board.height} · ${board.rows} x ${board.columns} · ${board.portraitMode ? '竖屏单列' : '横屏宫格'} · 间距 ${board.gap.round()}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            flex: 2,
                            child: Text(
                              state.message,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(width: 6),
                          historyActions,
                        ],
                      );
                    },
                  ),
                ),
                Expanded(
                  child: _StoryboardCanvasViewport(
                    board: board,
                    reorderAnimationToken: state.reorderAnimationToken,
                    onMove: onMove,
                    onMoveItems: onMoveItems,
                    onPlaceAsset: onPlaceAsset,
                    onRemove: onRemove,
                    onFlipHorizontal: onFlipHorizontal,
                    onFlipVertical: onFlipVertical,
                    onEditImage: onEditImage,
                    onLocateAsset: onLocateAsset,
                    onPickReplacementImage: onPickReplacementImage,
                    onDropReplacementImages: onDropReplacementImages,
                    onCaptionChanged: onCaptionChanged,
                    onRowCaptionChanged: onRowCaptionChanged,
                    showOriginalStoryboard: showOriginalStoryboard,
                    originalPathForItem: originalPathForItem,
                    onCompareImage: onCompareImage,
                  ),
                ),
              ],
            ),
    );
  }
}

class _StoryboardHistoryActions extends StatelessWidget {
  const _StoryboardHistoryActions({
    required this.canUndo,
    required this.canRedo,
    required this.locked,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleLock,
  });

  final bool canUndo;
  final bool canRedo;
  final bool locked;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onToggleLock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      height: 32,
      child: Row(
        children: [
          _button(
            tooltip: '撤销 (Ctrl+Z)',
            key: const ValueKey('storyboard-undo'),
            onPressed: canUndo ? onUndo : null,
            icon: Icons.undo_rounded,
          ),
          _button(
            tooltip: '恢复 (Ctrl+Y / Ctrl+Shift+Z)',
            key: const ValueKey('storyboard-redo'),
            onPressed: canRedo ? onRedo : null,
            icon: Icons.redo_rounded,
          ),
          _button(
            tooltip: locked ? '解锁画板' : '锁定画板',
            onPressed: onToggleLock,
            icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
            foregroundColor: locked
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            backgroundColor: locked
                ? scheme.primaryContainer.withValues(alpha: 0.86)
                : Colors.transparent,
          ),
        ],
      ),
    );
  }

  Widget _button({
    required String tooltip,
    Key? key,
    required VoidCallback? onPressed,
    required IconData icon,
    Color? foregroundColor,
    Color? backgroundColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 32,
        child: IconButton(
          key: key,
          onPressed: onPressed,
          icon: Icon(icon),
          iconSize: 19,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(32),
            maximumSize: const Size.square(32),
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryboardCanvasViewport extends StatefulWidget {
  const _StoryboardCanvasViewport({
    required this.board,
    required this.reorderAnimationToken,
    required this.onMove,
    required this.onMoveItems,
    required this.onPlaceAsset,
    required this.onRemove,
    required this.onFlipHorizontal,
    required this.onFlipVertical,
    required this.onEditImage,
    required this.onLocateAsset,
    required this.onPickReplacementImage,
    required this.onDropReplacementImages,
    required this.onCaptionChanged,
    required this.onRowCaptionChanged,
    required this.showOriginalStoryboard,
    required this.originalPathForItem,
    required this.onCompareImage,
  });

  final StoryboardBoard board;
  final int reorderAnimationToken;
  final void Function(int from, int to) onMove;
  final void Function(Set<String> assetIds, int to) onMoveItems;
  final void Function(StoryboardCutAsset asset, int slotIndex) onPlaceAsset;
  final ValueChanged<String> onRemove;
  final ValueChanged<int> onFlipHorizontal;
  final ValueChanged<int> onFlipVertical;
  final ValueChanged<StoryboardItem> onEditImage;
  final ValueChanged<StoryboardItem> onLocateAsset;
  final ValueChanged<StoryboardItem> onPickReplacementImage;
  final void Function(StoryboardItem item, Iterable<String> paths)
  onDropReplacementImages;
  final void Function(int index, String caption) onCaptionChanged;
  final void Function(int rowIndex, String caption) onRowCaptionChanged;
  final bool showOriginalStoryboard;
  final String? Function(StoryboardItem item) originalPathForItem;
  final ValueChanged<StoryboardItem> onCompareImage;

  @override
  State<_StoryboardCanvasViewport> createState() =>
      _StoryboardCanvasViewportState();
}

class _StoryboardCanvasViewportState extends State<_StoryboardCanvasViewport> {
  static const _minZoom = 0.1;
  static const _panStartSlop = 3.0;
  static const _zoomPresets = [
    0.1,
    0.25,
    0.5,
    0.75,
    1.0,
    1.5,
    2.0,
    3.0,
    4.0,
    6.0,
    8.0,
  ];

  double _zoom = 1;
  Offset _panOffset = Offset.zero;
  int? _panPointer;
  Offset? _panStartPosition;
  Offset? _lastPanPosition;
  bool _isPanning = false;
  bool _showZoomControls = false;
  Timer? _zoomControlsHideTimer;

  @override
  void didUpdateWidget(covariant _StoryboardCanvasViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.board.id != widget.board.id) {
      _zoomControlsHideTimer?.cancel();
      _showZoomControls = false;
      _resetView();
    }
  }

  @override
  void dispose() {
    _zoomControlsHideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          math.max(1.0, constraints.maxWidth),
          math.max(1.0, constraints.maxHeight),
        );
        final scale = _scaleForZoom(viewportSize, _zoom);
        final canvasSize = Size(
          widget.board.width * scale,
          widget.board.height * scale,
        );
        final canvasTopLeft = _canvasTopLeft(viewportSize, canvasSize);

        return Listener(
          key: const ValueKey('storyboard-canvas-viewport'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) => _handlePointerSignal(event, viewportSize),
          onPointerDown: (event) =>
              _handlePointerDown(event, canvasTopLeft, scale, canvasSize),
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: MouseRegion(
            cursor: _isPanning
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab,
            child: SizedBox.expand(
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: canvasTopLeft.dx,
                      top: canvasTopLeft.dy,
                      width: canvasSize.width,
                      height: canvasSize.height,
                      child: _buildScaledCanvas(scale),
                    ),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _showZoomControls
                            ? KeyedSubtree(
                                key: const ValueKey('canvas-zoom-controls'),
                                child: _CanvasZoomControls(
                                  zoom: _zoom,
                                  presets: _zoomPresets,
                                  onZoomOut: () => _zoomTo(
                                    _zoom / 1.25,
                                    viewportSize: viewportSize,
                                  ),
                                  onZoomIn: () => _zoomTo(
                                    _zoom * 1.25,
                                    viewportSize: viewportSize,
                                  ),
                                  onFit: _fitView,
                                  onPresetSelected: (zoom) =>
                                      _zoomTo(zoom, viewportSize: viewportSize),
                                ),
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('canvas-zoom-controls-hidden'),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildScaledCanvas(double scale) {
    final logicalSize = Size(
      widget.board.width.toDouble(),
      widget.board.height.toDouble(),
    );
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: logicalSize.width,
        maxWidth: logicalSize.width,
        minHeight: logicalSize.height,
        maxHeight: logicalSize.height,
        child: Transform.scale(
          alignment: Alignment.topLeft,
          scale: scale,
          child: SizedBox.fromSize(
            size: logicalSize,
            child: _buildCanvas(scale),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(double previewScale) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final titleHeight = StoryboardBoard.titleHeightFor(
      widget.board.captionFontSize,
    );
    return Container(
      padding: EdgeInsets.all(widget.board.gap),
      decoration: BoxDecoration(
        color: canvasColors.background,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 24,
          ),
        ],
      ),
      child: Column(
        children: [
          _StoryboardCanvasTitle(board: widget.board, height: titleHeight),
          SizedBox(height: widget.board.gap),
          Expanded(
            child: _CanvasGrid(
              board: widget.board,
              reorderAnimationToken: widget.reorderAnimationToken,
              scale: 1,
              previewScale: previewScale,
              onMove: widget.onMove,
              onMoveItems: widget.onMoveItems,
              onPlaceAsset: widget.onPlaceAsset,
              onRemove: widget.onRemove,
              onFlipHorizontal: widget.onFlipHorizontal,
              onFlipVertical: widget.onFlipVertical,
              onEditImage: widget.onEditImage,
              onLocateAsset: widget.onLocateAsset,
              onPickReplacementImage: widget.onPickReplacementImage,
              onDropReplacementImages: widget.onDropReplacementImages,
              onCaptionChanged: widget.onCaptionChanged,
              onRowCaptionChanged: widget.onRowCaptionChanged,
              showOriginalStoryboard: widget.showOriginalStoryboard,
              originalPathForItem: widget.originalPathForItem,
              onCompareImage: widget.onCompareImage,
            ),
          ),
        ],
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event, Size viewportSize) {
    if (event is! PointerScrollEvent) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _zoomBy(
        factor,
        focalPoint: event.localPosition,
        viewportSize: viewportSize,
      );
    });
  }

  void _handlePointerDown(
    PointerDownEvent event,
    Offset canvasTopLeft,
    double scale,
    Size canvasSize,
  ) {
    if (event.kind != PointerDeviceKind.mouse) {
      return;
    }
    final isMiddleButton = (event.buttons & kMiddleMouseButton) != 0;
    final isPrimaryButton = (event.buttons & kPrimaryMouseButton) != 0;
    if (!isMiddleButton && !isPrimaryButton) {
      return;
    }
    if (!isMiddleButton &&
        !_canStartPanning(
          event.localPosition,
          canvasTopLeft,
          scale,
          canvasSize,
        )) {
      return;
    }
    _panPointer = event.pointer;
    _panStartPosition = event.localPosition;
    _lastPanPosition = event.localPosition;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _panPointer || _lastPanPosition == null) {
      return;
    }
    final startPosition = _panStartPosition ?? _lastPanPosition!;
    if (!_isPanning &&
        (event.localPosition - startPosition).distance < _panStartSlop) {
      return;
    }
    final delta = event.localPosition - _lastPanPosition!;
    if (delta == Offset.zero) {
      return;
    }
    setState(() {
      _lastPanPosition = event.localPosition;
      _panOffset += delta;
      _isPanning = true;
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    _stopPanning(event.pointer);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _stopPanning(event.pointer);
  }

  void _stopPanning(int pointer) {
    if (pointer != _panPointer) {
      return;
    }
    _panPointer = null;
    _panStartPosition = null;
    _lastPanPosition = null;
    if (!_isPanning) {
      return;
    }
    setState(() => _isPanning = false);
  }

  void _zoomBy(
    double factor, {
    required Offset focalPoint,
    required Size viewportSize,
  }) {
    final requestedZoom = _zoom * factor;
    if (!requestedZoom.isFinite || requestedZoom <= 0) {
      return;
    }
    final nextZoom = math.max(_minZoom, requestedZoom).toDouble();
    if ((nextZoom - _zoom).abs() < 0.001) {
      return;
    }

    final oldCanvasSize = _canvasSizeForZoom(viewportSize, _zoom);
    final nextCanvasSize = _canvasSizeForZoom(viewportSize, nextZoom);
    final viewportCenter = Offset(
      viewportSize.width / 2,
      viewportSize.height / 2,
    );
    final focalFromCenter = focalPoint - viewportCenter;
    final oldVector = focalFromCenter - _panOffset;
    final widthRatio = nextCanvasSize.width / oldCanvasSize.width;
    final heightRatio = nextCanvasSize.height / oldCanvasSize.height;

    _zoomControlsHideTimer?.cancel();
    setState(() {
      _zoom = nextZoom;
      _showZoomControls = true;
      if (nextZoom <= _minZoom + 0.001) {
        _panOffset = Offset.zero;
        _panPointer = null;
        _panStartPosition = null;
        _lastPanPosition = null;
        _isPanning = false;
      } else {
        _panOffset = Offset(
          focalFromCenter.dx - oldVector.dx * widthRatio,
          focalFromCenter.dy - oldVector.dy * heightRatio,
        );
      }
    });
    _scheduleZoomControlsHide();
  }

  void _zoomTo(double zoom, {required Size viewportSize}) {
    if (!zoom.isFinite || zoom <= 0) {
      return;
    }
    final nextZoom = math.max(_minZoom, zoom).toDouble();
    if ((nextZoom - _zoom).abs() < 0.001) {
      return;
    }
    _zoomBy(
      nextZoom / _zoom,
      focalPoint: Offset(viewportSize.width / 2, viewportSize.height / 2),
      viewportSize: viewportSize,
    );
  }

  bool _canStartPanning(
    Offset viewportPosition,
    Offset canvasTopLeft,
    double scale,
    Size canvasSize,
  ) {
    final canvasPosition = viewportPosition - canvasTopLeft;
    if (canvasPosition.dx < 0 ||
        canvasPosition.dy < 0 ||
        canvasPosition.dx > canvasSize.width ||
        canvasPosition.dy > canvasSize.height) {
      return true;
    }

    final padding = widget.board.gap * scale;
    final titleHeight =
        StoryboardBoard.titleHeightFor(widget.board.captionFontSize) * scale;
    final gridTop = padding + titleHeight + padding;
    final gridPosition = canvasPosition - Offset(padding, gridTop);
    final gridSize = Size(
      math.max(1.0, canvasSize.width - padding * 2),
      math.max(1.0, canvasSize.height - gridTop - padding),
    );
    if (gridPosition.dx < 0 ||
        gridPosition.dy < 0 ||
        gridPosition.dx > gridSize.width ||
        gridPosition.dy > gridSize.height) {
      return true;
    }
    if (widget.board.items.isEmpty) {
      return true;
    }

    final metrics = _StoryboardGridMetrics.fromBoard(
      board: widget.board,
      scale: scale,
      size: gridSize,
    );
    if (metrics.rowCaptionRects.any((rect) => rect.contains(gridPosition))) {
      return false;
    }
    for (final item in widget.board.items) {
      if (item.slotIndex < 0 || item.slotIndex >= metrics.slotRects.length) {
        continue;
      }
      if (metrics.slotRects[item.slotIndex].contains(gridPosition)) {
        return false;
      }
    }
    return true;
  }

  double _scaleForZoom(Size viewportSize, double zoom) {
    final fitScale = math.min(
      viewportSize.width / math.max(1, widget.board.width),
      viewportSize.height / math.max(1, widget.board.height),
    );
    return fitScale * zoom;
  }

  Size _canvasSizeForZoom(Size viewportSize, double zoom) {
    final scale = _scaleForZoom(viewportSize, zoom);
    return Size(widget.board.width * scale, widget.board.height * scale);
  }

  Offset _canvasTopLeft(Size viewportSize, Size canvasSize) {
    return Offset(
          (viewportSize.width - canvasSize.width) / 2,
          (viewportSize.height - canvasSize.height) / 2,
        ) +
        _panOffset;
  }

  void _resetView() {
    _zoom = 1;
    _panOffset = Offset.zero;
    _panPointer = null;
    _panStartPosition = null;
    _lastPanPosition = null;
    _isPanning = false;
  }

  void _fitView() {
    _zoomControlsHideTimer?.cancel();
    setState(() {
      _resetView();
      _showZoomControls = true;
    });
    _scheduleZoomControlsHide();
  }

  void _scheduleZoomControlsHide() {
    _zoomControlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_showZoomControls) {
        return;
      }
      setState(() => _showZoomControls = false);
    });
  }
}

class _StoryboardCanvasTitle extends StatelessWidget {
  const _StoryboardCanvasTitle({required this.board, required this.height});

  final StoryboardBoard board;
  final double height;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return SizedBox(
      key: const ValueKey('storyboard-board-title'),
      width: double.infinity,
      height: height,
      child: Align(
        alignment: _titleAlignment(board.titleAlignment),
        child: Text(
          board.name.trim().isEmpty ? '画板' : board.name.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: _titleTextAlign(board.titleAlignment),
          style: TextStyle(
            color: canvasColors.text,
            fontFamily: board.captionFontFamily,
            fontSize: StoryboardBoard.titleFontSizeFor(board.captionFontSize),
            height: 1.2,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

Alignment _titleAlignment(StoryboardTitleAlignment alignment) {
  return switch (alignment) {
    StoryboardTitleAlignment.left => Alignment.centerLeft,
    StoryboardTitleAlignment.center => Alignment.center,
    StoryboardTitleAlignment.right => Alignment.centerRight,
  };
}

TextAlign _titleTextAlign(StoryboardTitleAlignment alignment) {
  return switch (alignment) {
    StoryboardTitleAlignment.left => TextAlign.left,
    StoryboardTitleAlignment.center => TextAlign.center,
    StoryboardTitleAlignment.right => TextAlign.right,
  };
}

class _CanvasZoomControls extends StatelessWidget {
  const _CanvasZoomControls({
    required this.zoom,
    required this.presets,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
    required this.onPresetSelected,
  });

  final double zoom;
  final List<double> presets;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFit;
  final ValueChanged<double> onPresetSelected;

  @override
  Widget build(BuildContext context) {
    final label = '${(zoom * 100).round()}%';
    return Material(
      color: Colors.black.withValues(alpha: 0.68),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ZoomIconButton(
              tooltip: '缩小',
              icon: Icons.remove_rounded,
              onPressed: onZoomOut,
            ),
            PopupMenuButton<double>(
              tooltip: '缩放比例',
              onSelected: onPresetSelected,
              itemBuilder: (context) => [
                for (final preset in presets)
                  PopupMenuItem(
                    value: preset,
                    child: Text('${(preset * 100).round()}%'),
                  ),
              ],
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 58,
                  minHeight: 32,
                  maxHeight: 32,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: Text(
                      label,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _ZoomIconButton(
              tooltip: '放大',
              icon: Icons.add_rounded,
              onPressed: onZoomIn,
            ),
            _ZoomIconButton(
              tooltip: '适配',
              icon: Icons.fit_screen_rounded,
              onPressed: onFit,
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomIconButton extends StatelessWidget {
  const _ZoomIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        style: IconButton.styleFrom(
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
      ),
    );
  }
}

class _StoryboardGridMetrics {
  const _StoryboardGridMetrics({
    required this.slotRects,
    required this.rowCaptionRects,
  });

  final List<Rect> slotRects;
  final List<Rect> rowCaptionRects;

  factory _StoryboardGridMetrics.fromBoard({
    required StoryboardBoard board,
    required double scale,
    required Size size,
  }) {
    final gap = board.gap * scale;
    final columns = math.max(1, board.columns);
    final rows = math.max(1, board.rows);
    final slotWidth = math.max(
      1.0,
      (size.width - gap * (columns - 1)) / columns,
    );
    final rowBandHeight = math.max(
      1.0,
      (size.height - gap * (rows - 1)) / rows,
    );
    final rowCaptionsVisible =
        board.storyDescriptionEnabled && board.rowDescriptionEnabled;
    final rowCaptionHeight = rowCaptionsVisible
        ? _rowCaptionHeight(board, scale, rowBandHeight)
        : 0.0;
    final rowCaptionGap = rowCaptionHeight > 0
        ? math.max(4.0, math.min(8.0, gap * 0.45))
        : 0.0;
    final slotHeight = math.max(
      1.0,
      rowBandHeight - rowCaptionHeight - rowCaptionGap,
    );
    return _StoryboardGridMetrics(
      slotRects: [
        for (var index = 0; index < board.slotCount; index++)
          Rect.fromLTWH(
            (index % columns) * (slotWidth + gap),
            (index ~/ columns) * (rowBandHeight + gap),
            slotWidth,
            slotHeight,
          ),
      ],
      rowCaptionRects: [
        if (rowCaptionsVisible)
          for (var rowIndex = 0; rowIndex < rows; rowIndex++)
            Rect.fromLTWH(
              0,
              rowIndex * (rowBandHeight + gap) + slotHeight + rowCaptionGap,
              size.width,
              rowCaptionHeight,
            ),
      ],
    );
  }

  static double _rowCaptionHeight(
    StoryboardBoard board,
    double scale,
    double rowBandHeight,
  ) {
    final captionFontSize = _scaledCaptionFontSize(board, scale);
    final preferred =
        StoryboardBoard.maxRowCaptionHeight(
          width: board.width.toDouble(),
          gap: board.gap,
          rows: board.rows,
          rowCaptions: board.rowCaptions,
          fontSize: board.captionFontSize,
        ) *
        scale;
    final minimum = _captionTextFieldMinHeight(captionFontSize);
    return math.min(
      math.max(preferred, minimum),
      math.max(0.0, rowBandHeight - 28),
    );
  }
}

class _RowDividerPainter extends CustomPainter {
  const _RowDividerPainter({
    required this.rows,
    required this.rowBandHeight,
    required this.gap,
    required this.color,
    required this.style,
    required this.scale,
  });

  final int rows;
  final double rowBandHeight;
  final double gap;
  final Color color;
  final StoryboardDividerStyle style;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(0.8, math.min(2.0, 1.2 * scale))
      ..strokeCap = StrokeCap.round;
    for (var rowIndex = 0; rowIndex < rows - 1; rowIndex++) {
      final y = (rowIndex + 1) * rowBandHeight + (rowIndex + 0.5) * gap;
      if (style == StoryboardDividerStyle.solid) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        continue;
      }
      final dashWidth = math.max(4.0, 10 * scale);
      final dashGap = math.max(3.0, 7 * scale);
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(size.width, x + dashWidth), y),
          paint,
        );
        x += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RowDividerPainter oldDelegate) {
    return rows != oldDelegate.rows ||
        rowBandHeight != oldDelegate.rowBandHeight ||
        gap != oldDelegate.gap ||
        color != oldDelegate.color ||
        style != oldDelegate.style ||
        scale != oldDelegate.scale;
  }
}

class _CanvasGrid extends ConsumerStatefulWidget {
  const _CanvasGrid({
    required this.board,
    required this.reorderAnimationToken,
    required this.scale,
    required this.previewScale,
    required this.onMove,
    required this.onMoveItems,
    required this.onPlaceAsset,
    required this.onRemove,
    required this.onFlipHorizontal,
    required this.onFlipVertical,
    required this.onEditImage,
    required this.onLocateAsset,
    required this.onPickReplacementImage,
    required this.onDropReplacementImages,
    required this.onCaptionChanged,
    required this.onRowCaptionChanged,
    required this.showOriginalStoryboard,
    required this.originalPathForItem,
    required this.onCompareImage,
  });

  final StoryboardBoard board;
  final int reorderAnimationToken;
  final double scale;
  final double previewScale;
  final void Function(int from, int to) onMove;
  final void Function(Set<String> assetIds, int to) onMoveItems;
  final void Function(StoryboardCutAsset asset, int slotIndex) onPlaceAsset;
  final ValueChanged<String> onRemove;
  final ValueChanged<int> onFlipHorizontal;
  final ValueChanged<int> onFlipVertical;
  final ValueChanged<StoryboardItem> onEditImage;
  final ValueChanged<StoryboardItem> onLocateAsset;
  final ValueChanged<StoryboardItem> onPickReplacementImage;
  final void Function(StoryboardItem item, Iterable<String> paths)
  onDropReplacementImages;
  final void Function(int index, String caption) onCaptionChanged;
  final void Function(int rowIndex, String caption) onRowCaptionChanged;
  final bool showOriginalStoryboard;
  final String? Function(StoryboardItem item) originalPathForItem;
  final ValueChanged<StoryboardItem> onCompareImage;

  @override
  ConsumerState<_CanvasGrid> createState() => _CanvasGridState();
}

class _CanvasGridState extends ConsumerState<_CanvasGrid> {
  static const _selectionStateKey = 'storyboardCanvasSelectionState';
  static const _tileAnimationDuration = Duration(milliseconds: 190);
  static const _reorderAnimationDuration = Duration(milliseconds: 620);
  static const _reorderAnimationClearDelay = Duration(milliseconds: 720);
  static const _quickActionHideDelay = Duration(milliseconds: 140);

  final _stackKey = GlobalKey();
  int? _dragFromSlot;
  int? _hoverSlot;
  int? _externalHoverSlot;
  final ValueNotifier<Offset?> _dragTopLeft = ValueNotifier(null);
  Offset? _pendingDragPointerDelta;
  Offset? _dragPointerDelta;
  final _selectedAssetIds = <String>{};
  Set<String> _dragAssetIds = const {};
  Map<String, Offset> _dragOffsetsByAssetId = const {};
  bool _shiftBrushActive = false;
  bool _shiftBrushAdding = true;
  bool _dropCommitScheduled = false;
  bool _imageDragButtonAllowed = true;
  Set<String> _reorderAnimatedAssetIds = const {};
  int _reorderAnimationGeneration = 0;
  Timer? _quickActionHideTimer;
  String? _quickActionAssetId;
  _StoryboardFolderDropCoordinator? _folderDropCoordinator;

  @override
  void initState() {
    super.initState();
    _restoreSelectionState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _folderDropCoordinator = _StoryboardFolderDropScope.maybeOf(context);
  }

  @override
  void dispose() {
    _folderDropCoordinator?.cancel();
    _cancelQuickActionHide();
    _dragTopLeft.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CanvasGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.board.id != widget.board.id) {
      _folderDropCoordinator?.cancel();
      _cancelQuickActionHide();
      _quickActionAssetId = null;
      _restoreSelectionState();
      _reorderAnimatedAssetIds = const {};
      _reorderAnimationGeneration++;
      _externalHoverSlot = null;
    }
    if (oldWidget.reorderAnimationToken != widget.reorderAnimationToken) {
      _startReorderAnimation(oldWidget.board, widget.board);
    }
    if (!oldWidget.board.locked && widget.board.locked) {
      _folderDropCoordinator?.cancel();
      _resetDragState();
      _externalHoverSlot = null;
      _cancelQuickActionHide();
      _quickActionAssetId = null;
    }
    final draggingSlot = _dragFromSlot;
    if (draggingSlot != null && widget.board.itemAtSlot(draggingSlot) == null) {
      _folderDropCoordinator?.cancel();
      _resetDragState();
    }
    final validAssetIds = widget.board.items
        .map((item) => item.asset.id)
        .toSet();
    _selectedAssetIds.removeWhere(
      (assetId) => !validAssetIds.contains(assetId),
    );
    final quickActionAssetId = _quickActionAssetId;
    if (quickActionAssetId != null &&
        !validAssetIds.contains(quickActionAssetId)) {
      _cancelQuickActionHide();
      _quickActionAssetId = null;
    }
    if (_selectedAssetIds.isEmpty) {
      _saveSelectionState();
    }
  }

  void _startReorderAnimation(
    StoryboardBoard previousBoard,
    StoryboardBoard nextBoard,
  ) {
    final movedAssetIds = _movedAssetIds(previousBoard, nextBoard);
    _reorderAnimationGeneration++;
    if (movedAssetIds.isEmpty) {
      _reorderAnimatedAssetIds = const {};
      return;
    }
    _reorderAnimatedAssetIds = movedAssetIds;
    final generation = _reorderAnimationGeneration;
    Future<void>.delayed(_reorderAnimationClearDelay, () {
      if (!mounted || generation != _reorderAnimationGeneration) {
        return;
      }
      setState(() => _reorderAnimatedAssetIds = const {});
    });
  }

  Set<String> _movedAssetIds(
    StoryboardBoard previousBoard,
    StoryboardBoard nextBoard,
  ) {
    final previousSlots = {
      for (final item in previousBoard.items) item.asset.id: item.slotIndex,
    };
    return {
      for (final item in nextBoard.items)
        if (previousSlots[item.asset.id] != null &&
            previousSlots[item.asset.id] != item.slotIndex)
          item.asset.id,
    };
  }

  void _restoreSelectionState() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(_selectionStateKey);
      if (raw == null || raw.trim().isEmpty) {
        _selectedAssetIds.clear();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        _selectedAssetIds.clear();
        return;
      }
      final boardId = decoded['boardId']?.toString();
      final validAssetIds = widget.board.items
          .map((item) => item.asset.id)
          .toSet();
      final assetIds = _jsonStringSet(
        decoded['selectedAssetIds'],
      ).where(validAssetIds.contains).toSet();
      final legacyAssetId = decoded['selectedAssetId']?.toString();
      if (assetIds.isEmpty &&
          legacyAssetId != null &&
          validAssetIds.contains(legacyAssetId)) {
        assetIds.add(legacyAssetId);
      }
      if (boardId != widget.board.id || assetIds.isEmpty) {
        _selectedAssetIds.clear();
        return;
      }
      _selectedAssetIds
        ..clear()
        ..addAll(assetIds);
    } catch (_) {
      _selectedAssetIds.clear();
    }
  }

  void _saveSelectionState() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(
            _selectionStateKey,
            jsonEncode({
              'boardId': widget.board.id,
              'selectedAssetIds': _selectedAssetIds.toList()..sort(),
            }),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  Set<String> _jsonStringSet(Object? value) {
    if (value is! List) {
      return const <String>{};
    }
    return {for (final item in value) item?.toString() ?? ''}..remove('');
  }

  @override
  Widget build(BuildContext context) {
    final gap = widget.board.gap * widget.scale;
    final dividerColor = StoryboardCanvasStyle.of(
      context,
    ).mutedText.withValues(alpha: widget.board.rowDividerOpacity);
    final showItemCaptions =
        widget.board.storyDescriptionEnabled &&
        !widget.board.rowDescriptionEnabled;
    final showRowCaptions =
        widget.board.storyDescriptionEnabled &&
        widget.board.rowDescriptionEnabled;
    final captionFontSize = _scaledCaptionFontSize(widget.board, widget.scale);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(1, widget.board.columns);
        final rows = math.max(1, widget.board.rows);
        final slotWidth = math.max(
          1.0,
          (constraints.maxWidth - gap * (columns - 1)) / columns,
        );
        final rowBandHeight = math.max(
          1.0,
          (constraints.maxHeight - gap * (rows - 1)) / rows,
        );
        final rowCaptionHeight = showRowCaptions
            ? _rowCaptionHeight(rowBandHeight)
            : 0.0;
        final rowCaptionGap = rowCaptionHeight > 0
            ? math.max(4.0, math.min(8.0, gap * 0.45))
            : 0.0;
        final slotHeight = math.max(
          1.0,
          rowBandHeight - rowCaptionHeight - rowCaptionGap,
        );
        final itemCaptionHeight = showItemCaptions
            ? _itemCaptionHeight(rowBandHeight)
            : 0.0;
        final slotRects = [
          for (var index = 0; index < widget.board.slotCount; index++)
            _slotRect(
              index,
              slotWidth,
              slotHeight,
              gap,
              columns,
              rowBandHeight,
            ),
        ];
        final normalItems = <StoryboardItem>[];
        final draggedItems = <StoryboardItem>[];
        for (final item in widget.board.items) {
          if (item.slotIndex < 0 || item.slotIndex >= widget.board.slotCount) {
            continue;
          }
          if (_dragAssetIds.contains(item.asset.id)) {
            draggedItems.add(item);
          } else {
            normalItems.add(item);
          }
        }
        normalItems.sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
        final displaySlots = _displaySlotsFor(normalItems);
        StoryboardItem? selectedItem;
        if (!_isDragging && _selectedAssetIds.length == 1) {
          final selectedAssetId = _selectedAssetIds.first;
          for (final item in widget.board.items) {
            if (!item.resourceRemoved &&
                item.asset.id == selectedAssetId &&
                item.slotIndex >= 0 &&
                item.slotIndex < widget.board.slotCount) {
              selectedItem = item;
              break;
            }
          }
        }
        final occupiedDisplaySlots = {
          for (final item in normalItems) displaySlots[item.asset.id]!,
        };

        final canvas = Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            if (widget.board.rowDividerEnabled && rows > 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RowDividerPainter(
                      rows: rows,
                      rowBandHeight: rowBandHeight,
                      gap: gap,
                      color: dividerColor,
                      style: widget.board.rowDividerStyle,
                      scale: widget.scale,
                    ),
                  ),
                ),
              ),
            for (var index = 0; index < widget.board.slotCount; index++)
              Positioned.fromRect(
                rect: slotRects[index],
                child: _buildAssetDropTarget(
                  slotIndex: index,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _clearSelection,
                    child: occupiedDisplaySlots.contains(index)
                        ? const SizedBox.expand()
                        : _EmptyStoryboardSlot(
                            index: index,
                            highlighted:
                                _hoverSlot == index ||
                                _externalHoverSlot == index,
                          ),
                  ),
                ),
              ),
            for (final item in normalItems)
              _buildPositionedNormalItem(
                item: item,
                displaySlot: displaySlots[item.asset.id]!,
                slotRects: slotRects,
                showCaption: showItemCaptions,
                captionHeight: itemCaptionHeight,
                captionFontSize: captionFontSize,
              ),
            if (showRowCaptions)
              for (var rowIndex = 0; rowIndex < rows; rowIndex++)
                Positioned.fromRect(
                  rect: _rowCaptionRect(
                    rowIndex,
                    constraints.maxWidth,
                    slotHeight,
                    rowCaptionGap,
                    rowCaptionHeight,
                    gap,
                    rowBandHeight,
                  ),
                  child: _RowCaptionField(
                    rowIndex: rowIndex,
                    value: widget.board.rowCaptionAt(rowIndex),
                    fontFamily: widget.board.captionFontFamily,
                    fontSize: captionFontSize,
                    enabled: !widget.board.locked,
                    onChanged: (caption) =>
                        widget.onRowCaptionChanged(rowIndex, caption),
                  ),
                ),
            for (final draggedItem in draggedItems)
              _PositionedStoryboardItem(
                key: ValueKey('storyboard-item-${draggedItem.asset.id}'),
                rect: slotRects[draggedItem.slotIndex],
                dragTopLeft: _dragTopLeft,
                relativeOffset:
                    _dragOffsetsByAssetId[draggedItem.asset.id] ?? Offset.zero,
                duration: Duration.zero,
                curve: Curves.easeOutCubic,
                child: _buildItemTarget(
                  item: draggedItem,
                  displaySlot: draggedItem.slotIndex,
                  slotRects: slotRects,
                  showCaption: showItemCaptions,
                  captionHeight: itemCaptionHeight,
                  captionFontSize: captionFontSize,
                ),
              ),
            if (selectedItem != null && !widget.board.locked)
              _SelectedImageToolbarPositioner(
                rect: slotRects[displaySlots[selectedItem.asset.id]!],
                maxWidth: constraints.maxWidth,
                child: _quickActionAssetId == selectedItem.asset.id
                    ? MouseRegion(
                        onEnter: (_) => _cancelQuickActionHide(),
                        onExit: (_) =>
                            _scheduleQuickActionHide(selectedItem!.asset.id),
                        child: _ImageQuickActions(
                          flipHorizontal: selectedItem.flipHorizontal,
                          flipVertical: selectedItem.flipVertical,
                          onFlipHorizontal: () =>
                              widget.onFlipHorizontal(selectedItem!.slotIndex),
                          onFlipVertical: () =>
                              widget.onFlipVertical(selectedItem!.slotIndex),
                          onEditImage: () => widget.onEditImage(selectedItem!),
                          onLocateAsset: () =>
                              widget.onLocateAsset(selectedItem!),
                          onPickReplacementImage: () =>
                              widget.onPickReplacementImage(selectedItem!),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        );
        if (widget.board.locked) {
          return canvas;
        }
        return DropTarget(
          enable: DesktopDropTargetScope.enabledOf(context),
          key: const ValueKey('storyboard-canvas-file-drop-target'),
          onDragEntered: (details) =>
              _updateExternalHoverSlot(details.localPosition, slotRects),
          onDragUpdated: (details) =>
              _updateExternalHoverSlot(details.localPosition, slotRects),
          onDragExited: (_) {
            if (_externalHoverSlot != null) {
              setState(() => _externalHoverSlot = null);
            }
          },
          onDragDone: (details) {
            final slotIndex = _slotAtPosition(details.localPosition, slotRects);
            if (_externalHoverSlot != null) {
              setState(() => _externalHoverSlot = null);
            }
            if (slotIndex != null && occupiedDisplaySlots.contains(slotIndex)) {
              return;
            }
            unawaited(
              ref
                  .read(storyboardControllerProvider)
                  .importPathsToSelectedBoard(
                    details.files.map((file) => file.path),
                  ),
            );
          },
          child: canvas,
        );
      },
    );
  }

  void _updateExternalHoverSlot(Offset position, List<Rect> slotRects) {
    final slotIndex = _slotAtPosition(position, slotRects);
    if (_externalHoverSlot != slotIndex) {
      setState(() => _externalHoverSlot = slotIndex);
    }
  }

  int? _slotAtPosition(Offset position, List<Rect> slotRects) {
    for (var index = 0; index < slotRects.length; index++) {
      if (slotRects[index].contains(position)) {
        return index;
      }
    }
    return null;
  }

  Widget _buildPositionedNormalItem({
    required StoryboardItem item,
    required int displaySlot,
    required List<Rect> slotRects,
    required bool showCaption,
    required double captionHeight,
    required double captionFontSize,
  }) {
    final reorderAnimating = _reorderAnimatedAssetIds.contains(item.asset.id);
    final child = _buildItemTarget(
      item: item,
      displaySlot: displaySlot,
      slotRects: slotRects,
      showCaption: showCaption,
      captionHeight: captionHeight,
      captionFontSize: captionFontSize,
    );
    return _PositionedStoryboardItem(
      key: ValueKey('storyboard-item-${item.asset.id}'),
      rect: slotRects[displaySlot],
      duration: reorderAnimating
          ? _reorderAnimationDuration
          : _tileAnimationDuration,
      curve: reorderAnimating ? Curves.easeInOutCubic : Curves.easeOutCubic,
      child: reorderAnimating
          ? _StoryboardReorderPulse(
              token: widget.reorderAnimationToken,
              duration: _reorderAnimationDuration,
              child: child,
            )
          : child,
    );
  }

  Widget _buildItemTarget({
    required StoryboardItem item,
    required int displaySlot,
    required List<Rect> slotRects,
    required bool showCaption,
    required double captionHeight,
    required double captionFontSize,
  }) {
    final highlighted = _hoverSlot == displaySlot;
    final externalHighlighted = _externalHoverSlot == displaySlot;
    Widget tile = _StoryboardTile(
      item: item,
      index: displaySlot,
      previewLogicalWidth: slotRects[displaySlot].width * widget.previewScale,
      highlighted: highlighted,
      showCaption: showCaption,
      captionHeight: captionHeight,
      captionFontFamily: widget.board.captionFontFamily,
      captionFontSize: captionFontSize,
      selected: _selectedAssetIds.contains(item.asset.id),
      showImageQuickActions:
          !item.resourceRemoved && _quickActionAssetId == item.asset.id,
      showOriginalStoryboard: widget.showOriginalStoryboard,
      originalPath: widget.originalPathForItem(item),
      onCompareImage: () => widget.onCompareImage(item),
      onSelect: () => _selectItem(item.asset.id),
      onRemove: widget.board.locked
          ? null
          : () => widget.onRemove(item.asset.id),
      captionEnabled: !widget.board.locked,
      onCaptionChanged: (caption) =>
          widget.onCaptionChanged(item.slotIndex, caption),
      imageBuilder: widget.board.locked || item.resourceRemoved
          ? null
          : (context, child) => _buildDraggableImage(
              item: item,
              currentRect: slotRects[displaySlot],
              slotRects: slotRects,
              child: child,
            ),
    );
    if (externalHighlighted) {
      tile = _StoryboardReplacementDropGlow(
        key: ValueKey('storyboard-replacement-glow-${item.asset.id}'),
        child: tile,
      );
    }
    final target = _buildAssetDropTarget(
      slotIndex: displaySlot,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox.expand(child: tile),
      ),
    );
    if (widget.board.locked) {
      return target;
    }
    return DropTarget(
      enable: DesktopDropTargetScope.enabledOf(context),
      key: ValueKey('storyboard-replacement-drop-${item.asset.id}'),
      onDragEntered: (_) {
        if (_externalHoverSlot != displaySlot) {
          setState(() => _externalHoverSlot = displaySlot);
        }
      },
      onDragExited: (_) {
        if (_externalHoverSlot == displaySlot) {
          setState(() => _externalHoverSlot = null);
        }
      },
      onDragDone: (details) {
        if (_externalHoverSlot == displaySlot) {
          setState(() => _externalHoverSlot = null);
        }
        widget.onDropReplacementImages(
          item,
          details.files.map((file) => file.path),
        );
      },
      child: target,
    );
  }

  Widget _buildAssetDropTarget({
    required int slotIndex,
    required Widget child,
  }) {
    if (widget.board.locked) {
      return child;
    }
    return DragTarget<StoryboardCutAsset>(
      onWillAcceptWithDetails: (_) {
        if (_hoverSlot != slotIndex) {
          setState(() => _hoverSlot = slotIndex);
        }
        return true;
      },
      onLeave: (_) {
        if (_dragFromSlot == null && _hoverSlot == slotIndex) {
          setState(() => _hoverSlot = null);
        }
      },
      onAcceptWithDetails: (details) {
        widget.onPlaceAsset(details.data, slotIndex);
        setState(() {
          _hoverSlot = null;
          _selectedAssetIds.clear();
        });
        _saveSelectionState();
      },
      builder: (context, _, _) => child,
    );
  }

  Widget _buildDraggableImage({
    required StoryboardItem item,
    required Rect currentRect,
    required List<Rect> slotRects,
    required Widget child,
  }) {
    return Tooltip(
      message: '拖拽排序，或拖入左侧裁切资源文件夹',
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        onEnter: (_) {
          _keepQuickActionMenuVisible(item.asset.id);
          _applyShiftBrush(item.asset.id);
        },
        onHover: (_) {
          _keepQuickActionMenuVisible(item.asset.id);
          _applyShiftBrush(item.asset.id);
        },
        onExit: (_) => _scheduleQuickActionHide(item.asset.id),
        child: Listener(
          onPointerDown: (event) => _handleImageDragPointerDown(event, item),
          onPointerUp: (_) => _resetImageDragButtonGuard(),
          onPointerCancel: (_) => _resetImageDragButtonGuard(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTap: () {
              if (_isShiftPressed() || _isControlPressed()) {
                _selectItem(item.asset.id);
                return;
              }
              _selectItem(item.asset.id);
              _showQuickActionMenuFor(item.asset.id);
            },
            onPanDown: (details) => _prepareDrag(details, currentRect),
            onPanStart: (details) =>
                _startDrag(details, item, currentRect, slotRects),
            onPanUpdate: (details) => _updateDrag(details, slotRects),
            onPanEnd: (_) => _finishDrag(),
            onPanCancel: _cancelDrag,
            child: child,
          ),
        ),
      ),
    );
  }

  double _rowCaptionHeight(double rowBandHeight) {
    final captionFontSize = _scaledCaptionFontSize(widget.board, widget.scale);
    final preferred =
        StoryboardBoard.maxRowCaptionHeight(
          width: widget.board.width.toDouble(),
          gap: widget.board.gap,
          rows: widget.board.rows,
          rowCaptions: widget.board.rowCaptions,
          fontSize: widget.board.captionFontSize,
        ) *
        widget.scale;
    final minimum = _captionTextFieldMinHeight(captionFontSize);
    return math.min(
      math.max(preferred, minimum),
      math.max(0.0, rowBandHeight - 28),
    );
  }

  double _itemCaptionHeight(double rowBandHeight) {
    final captionFontSize = _scaledCaptionFontSize(widget.board, widget.scale);
    final preferred =
        StoryboardBoard.maxItemCaptionHeight(
          width: widget.board.width.toDouble(),
          gap: widget.board.gap,
          columns: widget.board.columns,
          items: widget.board.items,
          fontSize: widget.board.captionFontSize,
        ) *
        widget.scale;
    final minimum = _captionTextFieldMinHeight(captionFontSize);
    return math.min(
      math.max(preferred, minimum),
      math.max(0.0, rowBandHeight - 28),
    );
  }

  void _startDrag(
    DragStartDetails details,
    StoryboardItem item,
    Rect currentRect,
    List<Rect> slotRects,
  ) {
    if (!_imageDragButtonAllowed) {
      return;
    }
    _cancelQuickActionHide();
    final box = _stackKey.currentContext?.findRenderObject();
    if (box is! RenderBox) {
      return;
    }
    final pointer = box.globalToLocal(details.globalPosition);
    final pointerDelta =
        _pendingDragPointerDelta ?? pointer - currentRect.topLeft;
    final dragAssetIds = _selectedAssetIds.contains(item.asset.id)
        ? {..._selectedAssetIds}
        : {item.asset.id};
    final dragOffsets = <String, Offset>{};
    for (final candidate in widget.board.items) {
      if (!dragAssetIds.contains(candidate.asset.id) ||
          candidate.slotIndex < 0 ||
          candidate.slotIndex >= slotRects.length) {
        continue;
      }
      dragOffsets[candidate.asset.id] =
          slotRects[candidate.slotIndex].topLeft - currentRect.topLeft;
    }
    _folderDropCoordinator?.begin(
      assets: [
        for (final candidate in widget.board.items)
          if (dragAssetIds.contains(candidate.asset.id)) candidate.asset,
      ],
      globalPosition: details.globalPosition,
    );
    _dragTopLeft.value = pointer - pointerDelta;
    setState(() {
      _dragFromSlot = item.slotIndex;
      _hoverSlot = _slotIndexAt(pointer, slotRects) ?? item.slotIndex;
      _pendingDragPointerDelta = null;
      _dragPointerDelta = pointerDelta;
      _dragAssetIds = dragAssetIds;
      _dragOffsetsByAssetId = dragOffsets;
      _quickActionAssetId = null;
      _selectedAssetIds
        ..clear()
        ..addAll(dragAssetIds);
    });
  }

  void _updateDrag(DragUpdateDetails details, List<Rect> slotRects) {
    final box = _stackKey.currentContext?.findRenderObject();
    final pointerDelta = _dragPointerDelta;
    if (box is! RenderBox ||
        pointerDelta == null ||
        _dragFromSlot == null ||
        _dragAssetIds.isEmpty) {
      return;
    }
    final pointer = box.globalToLocal(details.globalPosition);
    final targetSlot = _slotIndexAt(pointer, slotRects);
    _folderDropCoordinator?.update(details.globalPosition);
    _dragTopLeft.value = pointer - pointerDelta;
    if (targetSlot != null && targetSlot != _hoverSlot) {
      setState(() => _hoverSlot = targetSlot);
    }
  }

  void _finishDrag() {
    final fromSlot = _dragFromSlot;
    final targetSlot = _hoverSlot;
    final copiedToFolder = _folderDropCoordinator?.complete() ?? false;
    if (copiedToFolder) {
      _clearDrag();
      _saveSelectionState();
      return;
    }
    if (fromSlot == null || targetSlot == null || fromSlot == targetSlot) {
      _clearDrag();
      _saveSelectionState();
      return;
    }
    if (_dropCommitScheduled) {
      return;
    }
    final dragAssetIds = {..._dragAssetIds};
    setState(() => _dropCommitScheduled = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_dropCommitScheduled) {
        return;
      }
      if (dragAssetIds.length <= 1) {
        widget.onMove(fromSlot, targetSlot);
      } else {
        widget.onMoveItems(dragAssetIds, targetSlot);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _resetDragState();
        _selectedAssetIds
          ..clear()
          ..addAll(dragAssetIds);
      });
      _saveSelectionState();
    });
  }

  void _selectItem(String assetId) {
    if (_isShiftPressed()) {
      return;
    }
    if (_isControlPressed()) {
      setState(() {
        if (!_selectedAssetIds.remove(assetId)) {
          _selectedAssetIds.add(assetId);
        }
        _pendingDragPointerDelta = null;
      });
      _saveSelectionState();
      return;
    }
    if (_selectedAssetIds.length == 1 && _selectedAssetIds.contains(assetId)) {
      if (_pendingDragPointerDelta != null) {
        setState(() => _pendingDragPointerDelta = null);
      }
      return;
    }
    setState(() {
      _selectedAssetIds
        ..clear()
        ..add(assetId);
      _pendingDragPointerDelta = null;
    });
    _saveSelectionState();
  }

  void _prepareDrag(DragDownDetails details, Rect currentRect) {
    if (!_imageDragButtonAllowed) {
      return;
    }
    final box = _stackKey.currentContext?.findRenderObject();
    if (box is RenderBox) {
      final pointer = box.globalToLocal(details.globalPosition);
      _pendingDragPointerDelta = pointer - currentRect.topLeft;
    }
  }

  void _handleImageDragPointerDown(
    PointerDownEvent event,
    StoryboardItem item,
  ) {
    _imageDragButtonAllowed =
        event.kind != PointerDeviceKind.mouse ||
        event.buttons == kPrimaryMouseButton;
    if (_imageDragButtonAllowed &&
        event.kind == PointerDeviceKind.mouse &&
        _isShiftPressed()) {
      _beginShiftBrush(item.asset.id);
      _imageDragButtonAllowed = false;
    }
    if (_imageDragButtonAllowed) {
      return;
    }
    _pendingDragPointerDelta = null;
  }

  void _resetImageDragButtonGuard() {
    _imageDragButtonAllowed = true;
    if (_shiftBrushActive) {
      _shiftBrushActive = false;
      _saveSelectionState();
    }
  }

  void _beginShiftBrush(String assetId) {
    _shiftBrushActive = true;
    _shiftBrushAdding = !_selectedAssetIds.contains(assetId);
    _applyShiftBrush(assetId);
  }

  void _applyShiftBrush(String assetId) {
    if (!_shiftBrushActive || !_isShiftPressed()) {
      return;
    }
    if (_shiftBrushAdding && _selectedAssetIds.contains(assetId)) {
      return;
    }
    if (!_shiftBrushAdding && !_selectedAssetIds.contains(assetId)) {
      return;
    }
    setState(() {
      if (_shiftBrushAdding) {
        _selectedAssetIds.add(assetId);
      } else {
        _selectedAssetIds.remove(assetId);
      }
      _pendingDragPointerDelta = null;
    });
  }

  bool _isShiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  bool _isControlPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
  }

  void _clearSelection() {
    if (_selectedAssetIds.isEmpty) {
      _hideQuickActionMenu();
      return;
    }
    _cancelQuickActionHide();
    setState(() {
      _selectedAssetIds.clear();
      _pendingDragPointerDelta = null;
      _quickActionAssetId = null;
    });
    _saveSelectionState();
  }

  void _showQuickActionMenuFor(String assetId) {
    _cancelQuickActionHide();
    if (_quickActionAssetId == assetId) {
      return;
    }
    setState(() => _quickActionAssetId = assetId);
  }

  void _keepQuickActionMenuVisible(String assetId) {
    if (_quickActionAssetId != assetId) {
      return;
    }
    _cancelQuickActionHide();
  }

  void _scheduleQuickActionHide(String assetId) {
    if (_quickActionAssetId != assetId) {
      return;
    }
    _cancelQuickActionHide();
    _quickActionHideTimer = Timer(_quickActionHideDelay, () {
      if (!mounted || _quickActionAssetId != assetId) {
        return;
      }
      setState(() => _quickActionAssetId = null);
    });
  }

  void _hideQuickActionMenu() {
    _cancelQuickActionHide();
    if (_quickActionAssetId == null || !mounted) {
      return;
    }
    setState(() => _quickActionAssetId = null);
  }

  void _cancelQuickActionHide() {
    _quickActionHideTimer?.cancel();
    _quickActionHideTimer = null;
  }

  void _clearDrag() {
    if (!mounted || !_isDragging) {
      return;
    }
    setState(_resetDragState);
  }

  void _cancelDrag() {
    _folderDropCoordinator?.cancel();
    _clearDrag();
    _saveSelectionState();
  }

  void _resetDragState() {
    _dragFromSlot = null;
    _hoverSlot = null;
    _dragTopLeft.value = null;
    _pendingDragPointerDelta = null;
    _dragPointerDelta = null;
    _dragAssetIds = const {};
    _dragOffsetsByAssetId = const {};
    _shiftBrushActive = false;
    _dropCommitScheduled = false;
    _imageDragButtonAllowed = true;
  }

  bool get _isDragging {
    return _dragFromSlot != null ||
        _hoverSlot != null ||
        _dragTopLeft.value != null ||
        _dragAssetIds.isNotEmpty ||
        _dragPointerDelta != null;
  }

  Map<String, int> _displaySlotsFor(List<StoryboardItem> normalItems) {
    final targetSlot = _hoverSlot;
    if (_dragAssetIds.isEmpty || targetSlot == null) {
      return {for (final item in normalItems) item.asset.id: item.slotIndex};
    }
    final normalItemCount = normalItems.length;
    final targetIndex = targetSlot.clamp(0, normalItemCount).toInt();
    return {
      for (var index = 0; index < normalItems.length; index++)
        normalItems[index].asset.id: index >= targetIndex
            ? index + _dragAssetIds.length
            : index,
    };
  }

  Rect _slotRect(
    int index,
    double slotWidth,
    double slotHeight,
    double gap,
    int columns,
    double rowBandHeight,
  ) {
    return Rect.fromLTWH(
      (index % columns) * (slotWidth + gap),
      (index ~/ columns) * (rowBandHeight + gap),
      slotWidth,
      slotHeight,
    );
  }

  Rect _rowCaptionRect(
    int rowIndex,
    double width,
    double slotHeight,
    double rowCaptionGap,
    double rowCaptionHeight,
    double gap,
    double rowBandHeight,
  ) {
    return Rect.fromLTWH(
      0,
      rowIndex * (rowBandHeight + gap) + slotHeight + rowCaptionGap,
      width,
      rowCaptionHeight,
    );
  }

  int? _slotIndexAt(Offset point, List<Rect> slotRects) {
    for (var index = 0; index < slotRects.length; index++) {
      if (slotRects[index].contains(point)) {
        return index;
      }
    }
    if (slotRects.isEmpty) {
      return null;
    }
    var bounds = slotRects.first;
    for (final rect in slotRects.skip(1)) {
      bounds = bounds.expandToInclude(rect);
    }
    if (!bounds.inflate(widget.board.gap * widget.scale).contains(point)) {
      return null;
    }
    var closestIndex = 0;
    var closestDistance = double.infinity;
    for (var index = 0; index < slotRects.length; index++) {
      final distance = (slotRects[index].center - point).distanceSquared;
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = index;
      }
    }
    return closestIndex;
  }
}

double _scaledCaptionFontSize(StoryboardBoard board, double scale) {
  return math
      .max(6.0, math.min(18.0, board.captionFontSize * scale))
      .toDouble();
}

double _captionTextFieldVerticalPadding(double fontSize) {
  return math.max(3.0, math.min(7.0, fontSize * 0.35)).toDouble();
}

double _captionTextFieldMinHeight(double fontSize) {
  final verticalPadding = _captionTextFieldVerticalPadding(fontSize);
  return math.max(28.0, fontSize * 1.25 + verticalPadding * 2 + 6).toDouble();
}

class _PositionedStoryboardItem extends StatelessWidget {
  const _PositionedStoryboardItem({
    super.key,
    required this.rect,
    required this.duration,
    required this.curve,
    required this.child,
    this.dragTopLeft,
    this.relativeOffset = Offset.zero,
  });

  static final ValueNotifier<Offset?> _idleTopLeft = ValueNotifier(null);

  final Rect rect;
  final Duration duration;
  final Curve curve;
  final Widget child;
  final ValueListenable<Offset?>? dragTopLeft;
  final Offset relativeOffset;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Offset?>(
      valueListenable: dragTopLeft ?? _idleTopLeft,
      child: child,
      builder: (context, dragPosition, child) {
        final topLeft = dragTopLeft == null || dragPosition == null
            ? rect.topLeft
            : dragPosition + relativeOffset;
        return AnimatedPositioned(
          duration: duration,
          curve: curve,
          left: topLeft.dx,
          top: topLeft.dy,
          width: rect.width,
          height: rect.height,
          child: child!,
        );
      },
    );
  }
}

class _StoryboardReorderPulse extends StatelessWidget {
  const _StoryboardReorderPulse({
    required this.token,
    required this.duration,
    required this.child,
  });

  final int token;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('storyboard-reorder-pulse-$token'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final canvasColors = StoryboardCanvasStyle.of(context);
        final pulse = math.sin(value * math.pi).clamp(0.0, 1.0).toDouble();
        return Transform.scale(
          scale: 1 + pulse * 0.035,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: canvasColors.accent.withValues(alpha: 0.18 * pulse),
                  blurRadius: 24 * pulse,
                  spreadRadius: 2 * pulse,
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: canvasColors.accent.withValues(
                            alpha: 0.42 * pulse,
                          ),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _StoryboardReplacementDropGlow extends StatefulWidget {
  const _StoryboardReplacementDropGlow({super.key, required this.child});

  final Widget child;

  @override
  State<_StoryboardReplacementDropGlow> createState() =>
      _StoryboardReplacementDropGlowState();
}

class _StoryboardReplacementDropGlowState
    extends State<_StoryboardReplacementDropGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 920),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final pulse = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: 1 + pulse * 0.008,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: canvasColors.accent.withValues(
                    alpha: 0.22 + pulse * 0.2,
                  ),
                  blurRadius: 14 + pulse * 14,
                  spreadRadius: 1 + pulse * 2,
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: canvasColors.accent.withValues(
                          alpha: 0.035 + pulse * 0.045,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: canvasColors.accent.withValues(
                            alpha: 0.62 + pulse * 0.28,
                          ),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReferenceImageDropGlow extends StatefulWidget {
  const _ReferenceImageDropGlow({super.key, required this.child});

  final Widget child;

  @override
  State<_ReferenceImageDropGlow> createState() =>
      _ReferenceImageDropGlowState();
}

class _ReferenceImageDropGlowState extends State<_ReferenceImageDropGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final pulse = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: 1 + pulse * 0.004,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.16 + pulse * 0.16),
                  blurRadius: 12 + pulse * 12,
                  spreadRadius: pulse * 1.5,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _SelectedImageToolbarPositioner extends StatelessWidget {
  const _SelectedImageToolbarPositioner({
    required this.rect,
    required this.maxWidth,
    required this.child,
  });

  static const _width = 210.0;
  static const _height = 36.0;

  final Rect rect;
  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final maxLeft = math.max(0.0, maxWidth - _width);
    final left = (rect.center.dx - _width / 2).clamp(0.0, maxLeft).toDouble();
    final top = math.max(4.0, rect.top - _height - 8);
    return Positioned(
      left: left,
      top: top,
      width: _width,
      height: _height,
      child: child,
    );
  }
}

class _ImageQuickActions extends StatelessWidget {
  const _ImageQuickActions({
    required this.flipHorizontal,
    required this.flipVertical,
    required this.onFlipHorizontal,
    required this.onFlipVertical,
    required this.onEditImage,
    required this.onLocateAsset,
    required this.onPickReplacementImage,
  });

  final bool flipHorizontal;
  final bool flipVertical;
  final VoidCallback onFlipHorizontal;
  final VoidCallback onFlipVertical;
  final VoidCallback onEditImage;
  final VoidCallback onLocateAsset;
  final VoidCallback onPickReplacementImage;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ImageQuickActionButton(
              tooltip: '修改图片',
              selected: false,
              icon: Icons.auto_fix_high_rounded,
              onPressed: onEditImage,
            ),
            _ImageQuickActionButton(
              tooltip: '替换图片',
              selected: false,
              icon: Icons.image_search_rounded,
              onPressed: onPickReplacementImage,
            ),
            _ImageQuickActionButton(
              tooltip: '打开图片路径',
              selected: false,
              icon: Icons.folder_open_rounded,
              onPressed: onLocateAsset,
            ),
            _ImageQuickActionButton(
              tooltip: '水平翻转',
              selected: flipHorizontal,
              icon: Icons.swap_horiz_rounded,
              onPressed: onFlipHorizontal,
            ),
            _ImageQuickActionButton(
              tooltip: '垂直翻转',
              selected: flipVertical,
              icon: Icons.swap_vert_rounded,
              onPressed: onFlipVertical,
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageQuickActionButton extends StatelessWidget {
  const _ImageQuickActionButton({
    required this.tooltip,
    required this.selected,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final bool selected;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 30),
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? canvasColors.accent.withValues(alpha: 0.28)
              : Colors.transparent,
          foregroundColor: selected ? canvasColors.accent : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
      ),
    );
  }
}

class _ImageEditDialog extends StatefulWidget {
  const _ImageEditDialog({
    required this.controller,
    required this.item,
    required this.initialModel,
    required this.initialAspectRatio,
    required this.initialImageSize,
    required this.onPreferencesChanged,
  });

  final StoryboardController controller;
  final StoryboardItem item;
  final String initialModel;
  final String initialAspectRatio;
  final String initialImageSize;
  final ValueChanged<StoryboardImageEditPreferences>? onPreferencesChanged;

  @override
  State<_ImageEditDialog> createState() => _ImageEditDialogState();
}

class _ImageEditDialogState extends State<_ImageEditDialog> {
  static const _imageTypeGroup = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
  );

  late final TextEditingController _promptController;
  late String _model;
  late String _aspectRatio;
  late String _imageSize;
  String _quality = 'auto';
  final _referenceImagePaths = <String>[];
  bool _isSuggesting = false;
  bool _isReferenceDragging = false;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _model =
        ImageGenerationModelCatalog.values.contains(widget.initialModel.trim())
        ? widget.initialModel.trim()
        : 'nano-banana-fast';
    _aspectRatio = widget.initialAspectRatio;
    _imageSize = widget.initialImageSize;
    _normalizeSelections();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  List<String> get _activeAspectRatios {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    if (descriptor?.isApiMart ?? false) {
      return descriptor!.aspectRatios;
    }
    if (GptImageGenerationPreset.isModel(_model)) {
      return GptImageGenerationPreset.getAspectRatioOptions(_model);
    }
    return ImageGenerationModelCatalog.defaultAspectRatios;
  }

  List<String> get _activeImageSizes {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    if (descriptor?.isApiMart ?? false) {
      return descriptor!.resolutions;
    }
    if (GptImageGenerationPreset.usesResolutionDropdown(_model)) {
      return GptImageGenerationPreset.getImageSizeOptions(_model, _aspectRatio);
    }
    return ImageGenerationModelCatalog.defaultImageSizes;
  }

  Map<String, String>? get _activeImageSizeLabels {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    if (descriptor?.isApiMart ?? false) {
      return {
        for (final resolution in descriptor!.resolutions)
          resolution: resolution == 'auto' ? '自动' : resolution,
      };
    }
    if (GptImageGenerationPreset.usesResolutionDropdown(_model)) {
      return GptImageGenerationPreset.getResolutionLabels(_model, _aspectRatio);
    }
    return null;
  }

  bool get _showQuality {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    return (descriptor?.isApiMart ?? false)
        ? descriptor!.supportsQuality
        : GptImageGenerationPreset.supportsQuality(_model);
  }

  List<String> get _activeQualityOptions {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    if (descriptor?.isApiMart ?? false) {
      return descriptor!.qualities;
    }
    return GptImageGenerationPreset.qualityOptions;
  }

  bool get _busy => _isSuggesting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceFile = File(widget.item.asset.path);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_fix_high_rounded),
          SizedBox(width: 8),
          Text('修改图片'),
        ],
      ),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 150,
                      height: 104,
                      child: Image.file(
                        sourceFile,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.broken_image_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                      controller: _promptController,
                      minLines: 4,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '提示词',
                        prefixIcon: Icon(Icons.edit_note_rounded),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 300,
                    child: ImageGenerationModelSelector(
                      key: const ValueKey('storyboard-image-model-field'),
                      value: _model,
                      enabled: !_busy,
                      requireReferenceSupport: true,
                      onChanged: _setModel,
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: _DialogSelect(
                      label: '比例',
                      value: _aspectRatio,
                      values: _activeAspectRatios,
                      onChanged: _setAspectRatio,
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: _DialogSelect(
                      label:
                          _activeImageSizes.any(
                            (item) => item.toLowerCase() != 'auto',
                          )
                          ? '分辨率'
                          : '尺寸',
                      value: _imageSize,
                      values: _activeImageSizes,
                      labels: _activeImageSizeLabels,
                      onChanged: _setImageSize,
                    ),
                  ),
                  if (_showQuality)
                    SizedBox(
                      width: 150,
                      child: _DialogSelect(
                        label: '质量',
                        value: _quality,
                        values: _activeQualityOptions,
                        labels: GptImageGenerationPreset.qualityLabels,
                        onChanged: _setQuality,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              DropTarget(
                key: const ValueKey(
                  'storyboard-image-edit-reference-drop-target',
                ),
                enable: DesktopDropTargetScope.enabledOf(context) && !_busy,
                onDragEntered: (_) {
                  if (!_isReferenceDragging) {
                    setState(() => _isReferenceDragging = true);
                  }
                },
                onDragExited: (_) {
                  if (_isReferenceDragging) {
                    setState(() => _isReferenceDragging = false);
                  }
                },
                onDragDone: (details) {
                  setState(() => _isReferenceDragging = false);
                  _addReferenceImagePaths(
                    details.files.map((file) => file.path),
                    fromDrop: true,
                  );
                },
                child: _buildReferenceDropArea(context),
              ),
              if (_statusText.isNotEmpty || _isSuggesting) ...[
                const SizedBox(height: 12),
                ValueListenableBuilder<StoryboardState>(
                  valueListenable: widget.controller,
                  builder: (context, state, _) {
                    final liveStatus =
                        _isSuggesting && state.message.trim().isNotEmpty
                        ? state.message.trim()
                        : _statusText;
                    if (liveStatus.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _DialogStatusPanel(
                      text: liveStatus,
                      showSpinner: _isSuggesting,
                      showProgress: _isSuggesting && state.isAnalyzing,
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: const Icon(Icons.auto_fix_high_rounded),
          label: const Text('生成'),
        ),
      ],
    );
  }

  Future<void> _pickReferenceImages() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final files = await container
        .read(desktopFileDialogServiceProvider)
        .openFiles(
          source: 'storyboard.image_edit_reference',
          acceptedTypeGroups: const [_imageTypeGroup],
          initialDirectory: container
              .read(projectDirectoriesProvider)
              .imports
              .path,
        );
    if (!mounted || files.isEmpty) {
      return;
    }
    _addReferenceImagePaths(files.map((file) => file.path));
  }

  void _addReferenceImagePaths(
    Iterable<String> paths, {
    bool fromDrop = false,
  }) {
    final validPaths = paths
        .map((path) => path.trim())
        .where(
          (path) =>
              path.isNotEmpty &&
              _isReplacementImagePath(path) &&
              File(path).existsSync(),
        )
        .toList(growable: false);
    final addedPaths = validPaths
        .where((path) => !_referenceImagePaths.contains(path))
        .toList(growable: false);
    setState(() {
      _referenceImagePaths.addAll(addedPaths);
      if (fromDrop) {
        _statusText = addedPaths.isNotEmpty
            ? '已拖入 ${addedPaths.length} 张参考图'
            : validPaths.isNotEmpty
            ? '参考图已存在，无需重复添加'
            : '请拖入 PNG、JPG、WEBP 或 BMP 图片';
      }
    });
  }

  Widget _buildReferenceDropArea(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _isReferenceDragging
            ? scheme.primaryContainer.withValues(alpha: 0.42)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _isReferenceDragging
              ? scheme.primary.withValues(alpha: 0.9)
              : scheme.outlineVariant.withValues(alpha: 0.7),
          width: _isReferenceDragging ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickReferenceImages,
                icon: const Icon(Icons.add_photo_alternate_rounded),
                label: const Text('上传参考图'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: Text(
                    _isReferenceDragging ? '松开即可添加为参考图' : '或从资源管理器直接拖入图片',
                    key: ValueKey(_isReferenceDragging),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _isReferenceDragging
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: _isReferenceDragging
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _suggestPrompt,
                icon: _isSuggesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_isSuggesting ? '分析中...' : '自动提示词'),
              ),
            ],
          ),
          if (_referenceImagePaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (
                  var index = 0;
                  index < _referenceImagePaths.length;
                  index++
                )
                  _buildReferenceThumbnail(
                    context,
                    _referenceImagePaths[index],
                    index,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    if (_isReferenceDragging) {
      content = _ReferenceImageDropGlow(
        key: const ValueKey('storyboard-image-edit-reference-drop-glow'),
        child: content,
      );
    }
    return content;
  }

  Widget _buildReferenceThumbnail(
    BuildContext context,
    String path,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              Tooltip(
                message: '点击全屏浏览',
                child: InkWell(
                  key: ValueKey('image-edit-reference-$index'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showReferencePreview(index),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 112,
                      height: 76,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.contain,
                        cacheWidth: 224,
                        cacheHeight: 152,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.broken_image_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 3,
                top: 3,
                child: IconButton.filled(
                  tooltip: '移除参考图',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _referenceImagePaths.remove(path);
                          });
                        },
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            p.basename(path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Future<void> _showReferencePreview(int initialIndex) {
    final paths = List<String>.of(_referenceImagePaths);
    return showFullscreenZoomGallery<String>(
      context: context,
      items: paths,
      initialIndex: initialIndex,
      itemBuilder: (_, path) => Image.file(File(path), fit: BoxFit.contain),
      labelBuilder: (path, index, total) =>
          '${p.basename(path)} · ${index + 1} / $total',
    );
  }

  Future<void> _suggestPrompt() async {
    setState(() {
      _isSuggesting = true;
      _statusText = '正在分析当前分镜...';
    });
    try {
      final suggestion = await widget.controller.suggestImageEditPromptForItem(
        widget.item,
      );
      if (!mounted) {
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('修改建议'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(suggestion.advice),
                  const SizedBox(height: 12),
                  SelectableText(suggestion.prompt),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('接受'),
              ),
            ],
          );
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (accepted == true) {
          _promptController.text = suggestion.prompt;
          _statusText = '已填入自动提示词';
        } else {
          _statusText = '';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusText = '自动提示词失败：$error';
      });
    } finally {
      if (mounted) {
        setState(() => _isSuggesting = false);
      }
    }
  }

  void _generate() {
    final accepted = widget.controller.enqueueReplacementForItem(
      item: widget.item,
      prompt: _promptController.text,
      model: _model,
      aspectRatio: _aspectRatio,
      imageSize: _imageSize,
      quality: _quality,
      extraReferenceImagePaths: _referenceImagePaths,
    );
    if (accepted) {
      _persistPreferences();
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _statusText = widget.controller.value.message;
    });
  }

  void _setModel(String model) {
    setState(() {
      _model = model;
      _normalizeSelections();
    });
    _persistPreferences();
  }

  void _setAspectRatio(String aspectRatio) {
    setState(() {
      _aspectRatio = aspectRatio;
      _normalizeSelections();
    });
    _persistPreferences();
  }

  void _setImageSize(String imageSize) {
    setState(() {
      _imageSize = imageSize;
      _normalizeSelections();
    });
    _persistPreferences();
  }

  void _setQuality(String quality) {
    setState(() {
      _quality = GptImageGenerationPreset.normalizeQuality(quality);
    });
  }

  void _persistPreferences() {
    widget.onPreferencesChanged?.call(
      StoryboardImageEditPreferences(
        model: _model,
        aspectRatio: _aspectRatio,
        imageSize: _imageSize,
      ),
    );
  }

  void _normalizeSelections() {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(_model);
    if (descriptor?.isApiMart ?? false) {
      _aspectRatio = _normalizeCatalogSelection(
        _aspectRatio,
        descriptor!.aspectRatios,
      );
      _imageSize = _normalizeCatalogSelection(
        _imageSize,
        descriptor.resolutions,
      );
      _quality = descriptor.supportsQuality
          ? _normalizeCatalogSelection(_quality, descriptor.qualities)
          : 'auto';
      return;
    }
    if (GptImageGenerationPreset.isModel(_model)) {
      _aspectRatio = GptImageGenerationPreset.normalizeAspectRatio(
        _aspectRatio,
      );
      _imageSize = GptImageGenerationPreset.normalizeImageSize(
        model: _model,
        aspectRatio: _aspectRatio,
        value: _imageSize,
      );
      _quality = GptImageGenerationPreset.normalizeQuality(_quality);
      return;
    }

    if (!ImageGenerationModelCatalog.defaultAspectRatios.contains(
      _aspectRatio,
    )) {
      _aspectRatio = 'auto';
    }
    final normalizedSize = _imageSize.toUpperCase();
    _imageSize =
        ImageGenerationModelCatalog.defaultImageSizes.contains(normalizedSize)
        ? normalizedSize
        : '1K';
    _quality = 'auto';
  }

  String _normalizeCatalogSelection(String value, List<String> options) {
    final normalized = value.trim().toLowerCase();
    for (final option in options) {
      if (option.toLowerCase() == normalized) {
        return option;
      }
    }
    return options.first;
  }
}

class _DialogStatusPanel extends StatelessWidget {
  const _DialogStatusPanel({
    required this.text,
    required this.showSpinner,
    required this.showProgress,
  });

  final String text;
  final bool showSpinner;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (showSpinner) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (showProgress) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }
}

class _DialogSelect extends StatelessWidget {
  const _DialogSelect({
    super.key,
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
    this.labels,
    this.enabled = true,
  });

  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;
  final Map<String, String>? labels;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final safeValue = values.contains(value) ? value : values.first;
    return DropdownButtonFormField<String>(
      initialValue: safeValue,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in values)
          DropdownMenuItem(
            value: item,
            child: Text(labels?[item] ?? item, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled
          ? (value) {
              if (value != null) {
                onChanged(value);
              }
            }
          : null,
    );
  }
}

class _EmptyStoryboardSlot extends StatelessWidget {
  const _EmptyStoryboardSlot({required this.index, required this.highlighted});

  final int index;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final borderColor = highlighted
        ? canvasColors.accent
        : canvasColors.slotBorder;
    return AnimatedContainer(
      key: ValueKey('storyboard-empty-slot-$index'),
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: canvasColors.slotBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: highlighted ? 2 : 1),
      ),
      child: Center(
        child: Text(
          '${index + 1}',
          style: TextStyle(
            color: canvasColors.mutedText,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _RowCaptionField extends StatelessWidget {
  const _RowCaptionField({
    required this.rowIndex,
    required this.value,
    required this.fontFamily,
    required this.fontSize,
    required this.enabled,
    required this.onChanged,
  });

  final int rowIndex;
  final String value;
  final String fontFamily;
  final double fontSize;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _CaptionTextField(
      value: value,
      hintText: '第 ${rowIndex + 1} 行描述',
      minLines: 1,
      maxLines: null,
      fontFamily: fontFamily,
      fontSize: fontSize,
      enabled: enabled,
      onChanged: onChanged,
    );
  }
}

class _CaptionTextField extends StatefulWidget {
  const _CaptionTextField({
    required this.value,
    required this.hintText,
    required this.minLines,
    required this.maxLines,
    required this.fontFamily,
    required this.fontSize,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final String hintText;
  final int minLines;
  final int? maxLines;
  final String fontFamily;
  final double fontSize;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<_CaptionTextField> createState() => _CaptionTextFieldState();
}

class _CaptionTextFieldState extends State<_CaptionTextField> {
  static const _commitDelay = Duration(milliseconds: 350);

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  Timer? _commitTimer;
  String? _pendingValue;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _CaptionTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pendingValue = _pendingValue;
    if (pendingValue != null) {
      if (widget.value == pendingValue) {
        _commitTimer?.cancel();
        _commitTimer = null;
        _pendingValue = null;
      }
      return;
    }
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _flushPendingValue();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _commitTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleTextChanged(String value) {
    _pendingValue = value;
    _commitTimer?.cancel();
    _commitTimer = Timer(_commitDelay, _flushPendingValue);
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _flushPendingValue();
    }
  }

  void _flushPendingValue() {
    _commitTimer?.cancel();
    _commitTimer = null;
    final pendingValue = _pendingValue;
    if (pendingValue == null) {
      return;
    }
    _pendingValue = null;
    if (pendingValue != widget.value) {
      widget.onChanged(pendingValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final verticalPadding = _captionTextFieldVerticalPadding(widget.fontSize);
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      enabled: widget.enabled,
      textAlignVertical: TextAlignVertical.top,
      strutStyle: StrutStyle(
        fontSize: widget.fontSize,
        height: 1.25,
        forceStrutHeight: true,
      ),
      style: TextStyle(
        fontSize: widget.fontSize,
        height: 1.25,
        color: canvasColors.text,
        fontFamily: widget.fontFamily,
      ),
      decoration: InputDecoration(
        constraints: BoxConstraints(
          minHeight: _captionTextFieldMinHeight(widget.fontSize),
        ),
        isDense: true,
        hintText: widget.hintText,
        hintStyle: TextStyle(color: canvasColors.mutedText),
        filled: true,
        fillColor: canvasColors.imageBackground,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: canvasColors.slotBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: canvasColors.accent),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: verticalPadding,
        ),
      ),
      onChanged: widget.enabled ? _handleTextChanged : null,
      onFieldSubmitted: widget.enabled ? (_) => _flushPendingValue() : null,
    );
  }
}

class _StoryboardTile extends StatelessWidget {
  const _StoryboardTile({
    required this.item,
    required this.index,
    required this.previewLogicalWidth,
    required this.highlighted,
    required this.showCaption,
    required this.captionHeight,
    required this.captionFontFamily,
    required this.captionFontSize,
    required this.selected,
    required this.showImageQuickActions,
    required this.showOriginalStoryboard,
    required this.originalPath,
    required this.onCompareImage,
    required this.onSelect,
    required this.onRemove,
    required this.captionEnabled,
    required this.onCaptionChanged,
    this.imageBuilder,
  });

  final StoryboardItem item;
  final int index;
  final double previewLogicalWidth;
  final bool highlighted;
  final bool showCaption;
  final double captionHeight;
  final String captionFontFamily;
  final double captionFontSize;
  final bool selected;
  final bool showImageQuickActions;
  final bool showOriginalStoryboard;
  final String? originalPath;
  final VoidCallback onCompareImage;
  final VoidCallback onSelect;
  final VoidCallback? onRemove;
  final bool captionEnabled;
  final ValueChanged<String> onCaptionChanged;
  final Widget Function(BuildContext context, Widget child)? imageBuilder;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final emphasized = highlighted || selected;
    final borderColor = emphasized
        ? canvasColors.accent
        : canvasColors.slotBorder;
    final image = item.resourceRemoved
        ? const _RemovedStoryboardResourcePlaceholder()
        : _StoryboardTileImage(
            item: item,
            index: index,
            previewLogicalWidth: previewLogicalWidth,
            showDragHandle: imageBuilder != null && showImageQuickActions,
            showOriginalStoryboard: showOriginalStoryboard,
            originalPath: originalPath,
          );
    return Listener(
      onPointerDown: (event) => _storyboardTilePointerDowns[event.pointer] = (
        assetId: item.asset.id,
        position: event.position,
      ),
      onPointerMove: (event) {
        final down = _storyboardTilePointerDowns[event.pointer];
        if (down != null && (event.position - down.position).distance > 5) {
          _storyboardTilePointerDowns.remove(event.pointer);
        }
      },
      onPointerUp: (event) {
        final down = _storyboardTilePointerDowns.remove(event.pointer);
        if (down == null) return;
        final now = DateTime.now();
        final previous = _storyboardTileTapStamps[down.assetId];
        if (previous != null &&
            now.difference(previous.time).inMilliseconds < 360 &&
            (down.position - previous.position).distance < 24) {
          onCompareImage();
        }
        _storyboardTileTapStamps[down.assetId] = (
          time: now,
          position: down.position,
        );
      },
      onPointerCancel: (event) =>
          _storyboardTilePointerDowns.remove(event.pointer),
      child: GestureDetector(
        onTap: onSelect,
        onSecondaryTap: onRemove,
        child: AnimatedContainer(
          key: ValueKey('storyboard-tile-content-${item.asset.id}'),
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: canvasColors.tileBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: emphasized ? 2 : 1),
            boxShadow: emphasized
                ? [
                    BoxShadow(
                      color: canvasColors.accent.withValues(alpha: 0.18),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tileImage = imageBuilder == null
                  ? image
                  : imageBuilder!(context, image);
              final maxImageHeight = showCaption
                  ? math.max(0.0, constraints.maxHeight - captionHeight)
                  : constraints.maxHeight;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxImageHeight),
                    child: tileImage,
                  ),
                  if (showCaption)
                    Expanded(
                      child: Center(
                        child: SizedBox(
                          key: ValueKey('storyboard-caption-$index'),
                          height: captionHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _CaptionSequencePrefix(
                                number: index + 1,
                                fontSize: captionFontSize,
                              ),
                              Expanded(
                                child: _CaptionTextField(
                                  value: item.caption,
                                  hintText: '描述文本',
                                  minLines: 1,
                                  maxLines: null,
                                  fontFamily: captionFontFamily,
                                  fontSize: captionFontSize,
                                  enabled: captionEnabled,
                                  onChanged: onCaptionChanged,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RemovedStoryboardResourcePlaceholder extends StatelessWidget {
  const _RemovedStoryboardResourcePlaceholder();

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return DecoratedBox(
      key: const ValueKey('storyboard-resource-removed-placeholder'),
      decoration: BoxDecoration(
        color: canvasColors.imageBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: canvasColors.mutedText.withValues(alpha: 0.48),
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined, size: 28),
            SizedBox(height: 6),
            Text('资源已移除'),
            SizedBox(height: 3),
            Text('右键移除占位符后，可添加新资源'),
          ],
        ),
      ),
    );
  }
}

class _CaptionSequenceBadge extends StatelessWidget {
  const _CaptionSequenceBadge({required this.number, required this.fontSize});

  final int number;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final height = math.max(24.0, fontSize * 1.7);
    final width = math.max(28.0, math.min(44.0, fontSize * 2.0));
    return Container(
      key: ValueKey('caption-sequence-$number'),
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: canvasColors.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: canvasColors.accent.withValues(alpha: 0.38)),
      ),
      child: Text(
        '$number',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: canvasColors.text,
          fontSize: math.max(10.0, fontSize * 0.72),
          height: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CaptionSequencePrefix extends ConsumerWidget {
  const _CaptionSequencePrefix({required this.number, required this.fontSize});

  final int number;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ValueListenable<AppSettings>? settingsController;
    try {
      settingsController = ref.watch(settingsControllerProvider);
    } catch (_) {
      // 独立组件测试未注入设置时保持旧行为。
    }
    if (settingsController == null) {
      return _buildPrefix(enabled: true);
    }
    return ValueListenableBuilder<AppSettings>(
      valueListenable: settingsController,
      builder: (context, settings, _) =>
          _buildPrefix(enabled: settings.storyboardCaptionNumberEnabled),
    );
  }

  Widget _buildPrefix({required bool enabled}) {
    if (!enabled) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionSequenceBadge(number: number, fontSize: fontSize),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _StoryboardTileImage extends ConsumerWidget {
  const _StoryboardTileImage({
    required this.item,
    required this.index,
    required this.previewLogicalWidth,
    required this.showDragHandle,
    required this.showOriginalStoryboard,
    required this.originalPath,
  });

  final StoryboardItem item;
  final int index;
  final double previewLogicalWidth;
  final bool showDragHandle;
  final bool showOriginalStoryboard;
  final String? originalPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsController = _watchSettingsController(ref);
    if (settingsController == null) {
      return _buildImage(
        context,
        numberEnabled: false,
        numberPosition: CutImageNumberPosition.topLeft,
        numberBackgroundOpacity:
            AppSettings.defaultCutImageNumberBackgroundOpacity,
        numberTextScale: AppSettings.defaultCutImageNumberTextScale,
      );
    }
    return ValueListenableBuilder<AppSettings>(
      valueListenable: settingsController,
      builder: (context, settings, _) {
        return _buildImage(
          context,
          numberEnabled: settings.cutImageNumberEnabled,
          numberPosition: settings.cutImageNumberPosition,
          numberBackgroundOpacity: settings.cutImageNumberBackgroundOpacity,
          numberTextScale: settings.cutImageNumberTextScale,
        );
      },
    );
  }

  ValueListenable<AppSettings>? _watchSettingsController(WidgetRef ref) {
    try {
      return ref.watch(settingsControllerProvider);
    } catch (_) {
      return null;
    }
  }

  Widget _buildImage(
    BuildContext context, {
    required bool numberEnabled,
    required CutImageNumberPosition numberPosition,
    required double numberBackgroundOpacity,
    required double numberTextScale,
  }) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final imageProvider = previewFileImageProvider(
      path: showOriginalStoryboard && originalPath?.isNotEmpty == true
          ? originalPath!
          : item.asset.path,
      logicalWidth: previewLogicalWidth,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 1536,
    );
    return _StoryboardAspectRatioImage(
      imageProvider: imageProvider,
      imageKey: showOriginalStoryboard
          ? ValueKey('storyboard-image-${item.asset.id}-original')
          : ValueKey('storyboard-image-${item.asset.id}'),
      frameKey: ValueKey('storyboard-image-frame-${item.asset.id}'),
      builder: (image) => RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: canvasColors.imageBackground,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(
                    item.flipHorizontal ? -1.0 : 1.0,
                    item.flipVertical ? -1.0 : 1.0,
                    1.0,
                  ),
                  child: RepaintBoundary(child: image),
                ),
              ),
              if (numberEnabled)
                _StoryboardImageNumberBadge(
                  number: index + 1,
                  position: numberPosition,
                  backgroundOpacity: numberBackgroundOpacity,
                  textScale: numberTextScale,
                ),
              if (showDragHandle)
                Positioned(
                  right: 6,
                  top:
                      numberEnabled &&
                          numberPosition == CutImageNumberPosition.topRight
                      ? null
                      : 6,
                  bottom:
                      numberEnabled &&
                          numberPosition == CutImageNumberPosition.topRight
                      ? 6
                      : null,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                    ),
                    child: const Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryboardAspectRatioImage extends StatefulWidget {
  const _StoryboardAspectRatioImage({
    required this.imageProvider,
    required this.imageKey,
    required this.frameKey,
    required this.builder,
  });

  final ImageProvider<Object> imageProvider;
  final Key imageKey;
  final Key frameKey;
  final Widget Function(Widget image) builder;

  @override
  State<_StoryboardAspectRatioImage> createState() =>
      _StoryboardAspectRatioImageState();
}

class _StoryboardAspectRatioImageState
    extends State<_StoryboardAspectRatioImage> {
  static const _fallbackAspectRatio = StoryboardBoard.defaultImageAspectRatio;

  late final ImageStreamListener _imageStreamListener;
  ImageStream? _imageStream;
  double _aspectRatio = _fallbackAspectRatio;

  @override
  void initState() {
    super.initState();
    _imageStreamListener = ImageStreamListener(_handleImageFrame);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _StoryboardAspectRatioImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) {
      _aspectRatio = _fallbackAspectRatio;
      _resolveImage();
    }
  }

  void _resolveImage() {
    final stream = widget.imageProvider.resolve(
      createLocalImageConfiguration(context),
    );
    if (_imageStream?.key == stream.key) {
      return;
    }
    _imageStream?.removeListener(_imageStreamListener);
    _imageStream = stream..addListener(_imageStreamListener);
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    final image = imageInfo.image;
    if (image.height <= 0) {
      return;
    }
    final nextAspectRatio = image.width / image.height;
    if ((_aspectRatio - nextAspectRatio).abs() < 0.001 || !mounted) {
      return;
    }
    setState(() => _aspectRatio = nextAspectRatio);
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageStreamListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        var frameWidth = availableWidth;
        var frameHeight = frameWidth / _aspectRatio;
        if (constraints.maxHeight.isFinite &&
            frameHeight > constraints.maxHeight) {
          frameHeight = constraints.maxHeight;
          frameWidth = frameHeight * _aspectRatio;
        }
        return SizedBox(
          width: availableWidth,
          height: frameHeight,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: frameWidth,
              height: frameHeight,
              child: AspectRatio(
                key: widget.frameKey,
                aspectRatio: _aspectRatio,
                child: widget.builder(
                  Image(
                    key: widget.imageKey,
                    image: widget.imageProvider,
                    fit: BoxFit.contain,
                    alignment: Alignment.topCenter,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StoryboardImageNumberBadge extends StatelessWidget {
  const _StoryboardImageNumberBadge({
    required this.number,
    required this.position,
    required this.backgroundOpacity,
    required this.textScale,
  });

  final int number;
  final CutImageNumberPosition position;
  final double backgroundOpacity;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = math.min(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final opacity = backgroundOpacity.clamp(0.0, 1.0).toDouble();
        final fontScale = textScale.clamp(0.7, 1.6).toDouble();
        final baseBadgeSize = shortestSide.clamp(16.0, 34.0).toDouble();
        final maxBadgeSize = math.max(16.0, shortestSide * 0.56);
        final badgeSize = (baseBadgeSize * fontScale)
            .clamp(12.0, maxBadgeSize)
            .toDouble();
        final margin = math.max(5.0, badgeSize * 0.28);
        final alignment = switch (position) {
          CutImageNumberPosition.topLeft => Alignment.topLeft,
          CutImageNumberPosition.bottomLeft => Alignment.bottomLeft,
          CutImageNumberPosition.topRight => Alignment.topRight,
          CutImageNumberPosition.bottomRight => Alignment.bottomRight,
          CutImageNumberPosition.center => Alignment.center,
        };
        return Align(
          key: ValueKey('storyboard-image-number-$number'),
          alignment: alignment,
          child: Padding(
            padding: EdgeInsets.all(
              position == CutImageNumberPosition.center ? 0 : margin,
            ),
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: opacity),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black.withValues(alpha: 0.42)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 8,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$number',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xFF161616),
                    fontSize: badgeSize * 0.48,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StoryboardInspector extends StatefulWidget {
  const _StoryboardInspector({
    required this.controller,
    required this.expandedSections,
    required this.onToggleSection,
    required this.onExportBoardImages,
    required this.onExportShiyinBridge,
    required this.onImportShiyinBridge,
    required this.showOriginalStoryboard,
    required this.canShowOriginalStoryboard,
    required this.onToggleOriginalStoryboard,
    required this.onCollapse,
  });

  final StoryboardController controller;
  final Set<_StoryboardInspectorSection> expandedSections;
  final ValueChanged<_StoryboardInspectorSection> onToggleSection;
  final Future<void> Function(StoryboardBoard board) onExportBoardImages;
  final Future<void> Function(StoryboardBoard board) onExportShiyinBridge;
  final Future<void> Function(StoryboardBoard board) onImportShiyinBridge;
  final bool showOriginalStoryboard;
  final bool canShowOriginalStoryboard;
  final ValueChanged<bool> onToggleOriginalStoryboard;
  final VoidCallback onCollapse;

  @override
  State<_StoryboardInspector> createState() => _StoryboardInspectorState();
}

class _StoryboardInspectorState extends State<_StoryboardInspector> {
  static const _fontFamilies = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'SimHei',
    'SimSun',
    'Arial',
    'Times New Roman',
  ];

  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _rowsController = TextEditingController();
  final _columnsController = TextEditingController();
  final _nameController = TextEditingController();
  String _aspectExpansionRatio =
      StoryboardController.defaultFrameTransformationAspectRatio;
  String _aspectExpansionImageSize =
      StoryboardController.defaultFrameTransformationImageSize;
  String _lineArtRatio =
      StoryboardController.defaultFrameTransformationAspectRatio;
  String _lineArtImageSize =
      StoryboardController.defaultFrameTransformationImageSize;
  StoryboardLineArtStyle _lineArtStyle = StoryboardLineArtStyle.pencil;
  bool _isExportingBoardImages = false;
  bool _isExportingShiyinBridge = false;
  bool _isImportingShiyinBridge = false;

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    _rowsController.dispose();
    _columnsController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final board = state.selectedBoard;
    final scheme = Theme.of(context).colorScheme;
    if (board == null) {
      return const SizedBox.shrink();
    }
    final locked = board.locked;
    final analyzeActive = state.isVisionTaskActiveFor(
      board.id,
      StoryboardVisionTaskKind.analyze,
    );
    final analyzeQueued = state.isVisionTaskQueuedFor(
      board.id,
      StoryboardVisionTaskKind.analyze,
    );
    final reorderActive = state.isVisionTaskActiveFor(
      board.id,
      StoryboardVisionTaskKind.reorder,
    );
    final reorderQueued = state.isVisionTaskQueuedFor(
      board.id,
      StoryboardVisionTaskKind.reorder,
    );
    if (_widthController.text != '${board.width}') {
      _widthController.text = '${board.width}';
    }
    if (_heightController.text != '${board.height}') {
      _heightController.text = '${board.height}';
    }
    if (_rowsController.text != '${board.effectiveConfiguredRows}') {
      _rowsController.text = '${board.effectiveConfiguredRows}';
    }
    if (_columnsController.text != '${board.effectiveConfiguredColumns}') {
      _columnsController.text = '${board.effectiveConfiguredColumns}';
    }
    if (_nameController.text != board.name) {
      _nameController.text = board.name;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: ListView(
        key: const ValueKey('storyboard-inspector-list'),
        children: [
          SizedBox(
            height: 40,
            child: Stack(
              children: [
                Positioned.fill(
                  right: 40,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '画板参数',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 2,
                  child: IconButton(
                    tooltip: '收起画板参数',
                    onPressed: widget.onCollapse,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            enabled: !locked,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '画板名称',
              prefixIcon: const Icon(Icons.edit_note_rounded),
              suffixIcon: IconButton(
                tooltip: '应用画板名称',
                onPressed: locked
                    ? null
                    : () => widget.controller.renameSelectedBoard(
                        _nameController.text,
                      ),
                icon: const Icon(Icons.check_rounded),
              ),
            ),
            onSubmitted: widget.controller.renameSelectedBoard,
          ),
          const SizedBox(height: 10),
          Text('标题对齐', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          _CompactSegmentedControl<StoryboardTitleAlignment>(
            key: const ValueKey('storyboard-title-alignment-segmented'),
            options: [
              for (final alignment in StoryboardTitleAlignment.values)
                (value: alignment, label: alignment.label),
            ],
            selected: board.titleAlignment,
            onChanged: locked ? null : widget.controller.setTitleAlignment,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  state.isAnalyzing ||
                      _isExportingBoardImages ||
                      board.visibleItemCount == 0
                  ? null
                  : () => _exportBoardImages(board),
              icon: _isExportingBoardImages
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.drive_folder_upload_rounded),
              label: Text(_isExportingBoardImages ? '正在导出...' : '导出画板图片'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  state.isAnalyzing ||
                      _isExportingShiyinBridge ||
                      board.visibleItemCount == 0
                  ? null
                  : () async {
                      setState(() => _isExportingShiyinBridge = true);
                      try {
                        await widget.onExportShiyinBridge(board);
                      } finally {
                        if (mounted) {
                          setState(() => _isExportingShiyinBridge = false);
                        }
                      }
                    },
              icon: _isExportingShiyinBridge
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(_isExportingShiyinBridge ? '正在发送到画布...' : '发送到画布'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  state.isAnalyzing ||
                      _isImportingShiyinBridge ||
                      _isExportingShiyinBridge
                  ? null
                  : () async {
                      setState(() => _isImportingShiyinBridge = true);
                      try {
                        await widget.onImportShiyinBridge(board);
                      } finally {
                        if (mounted) {
                          setState(() => _isImportingShiyinBridge = false);
                        }
                      }
                    },
              icon: _isImportingShiyinBridge
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.move_to_inbox_rounded),
              label: Text(_isImportingShiyinBridge ? '正在接收回传...' : '接收无限画布回传'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: state.isAnalyzing || locked
                  ? null
                  : () => _confirmClearCurrentBoard(board),
              icon: const Icon(Icons.delete_sweep_rounded),
              label: const Text('清空当前画板'),
            ),
          ),
          const SizedBox(height: 10),
          _StoryboardInspectorSectionPanel(
            title: '扩展画幅',
            icon: Icons.open_in_full_rounded,
            expanded: _sectionExpanded(
              _StoryboardInspectorSection.aspectExpansion,
            ),
            onToggle: () => widget.onToggleSection(
              _StoryboardInspectorSection.aspectExpansion,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _InspectorSettingLine(
                  icon: Icons.auto_awesome_rounded,
                  label: '模型',
                  value: ImageGenerationModelCatalog.labelFor(
                    StoryboardController.frameTransformationModel,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _DialogSelect(
                        key: const ValueKey(
                          'storyboard-aspect-expansion-ratio',
                        ),
                        label: '目标比例',
                        value: _aspectExpansionRatio,
                        values: StoryboardController
                            .frameTransformationAspectRatios,
                        enabled: !locked && !state.isGeneratingImage,
                        onChanged: (value) =>
                            setState(() => _aspectExpansionRatio = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DialogSelect(
                        key: const ValueKey('storyboard-aspect-expansion-size'),
                        label: '分辨率',
                        value: _aspectExpansionImageSize,
                        values:
                            StoryboardController.frameTransformationImageSizes,
                        enabled: !locked && !state.isGeneratingImage,
                        onChanged: (value) =>
                            setState(() => _aspectExpansionImageSize = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const _InspectorSettingLine(
                  icon: Icons.crop_free_rounded,
                  label: '扩展方式',
                  value: '保留原图，只补画外',
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  key: const ValueKey('storyboard-aspect-expansion-button'),
                  onPressed:
                      locked ||
                          state.isGeneratingImage ||
                          board.visibleItemCount == 0
                      ? null
                      : () => widget.controller
                            .enqueueAspectExpansionForSelectedBoard(
                              aspectRatio: _aspectExpansionRatio,
                              imageSize: _aspectExpansionImageSize,
                            ),
                  icon: state.isGeneratingImage
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_full_rounded),
                  label: Text(
                    state.isGeneratingImage ? '图片任务进行中...' : '一键扩展当前画板',
                  ),
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '生成线稿分镜',
            icon: Icons.draw_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.lineArt),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.lineArt),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _InspectorSettingLine(
                  icon: Icons.auto_awesome_rounded,
                  label: '模型',
                  value: ImageGenerationModelCatalog.labelFor(
                    StoryboardController.frameTransformationModel,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _DialogSelect(
                        key: const ValueKey('storyboard-line-art-ratio'),
                        label: '目标比例',
                        value: _lineArtRatio,
                        values: StoryboardController
                            .frameTransformationAspectRatios,
                        enabled: !locked && !state.isGeneratingImage,
                        onChanged: (value) =>
                            setState(() => _lineArtRatio = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DialogSelect(
                        key: const ValueKey('storyboard-line-art-size'),
                        label: '分辨率',
                        value: _lineArtImageSize,
                        values:
                            StoryboardController.frameTransformationImageSizes,
                        enabled: !locked && !state.isGeneratingImage,
                        onChanged: (value) =>
                            setState(() => _lineArtImageSize = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('线稿风格', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                _CompactSegmentedControl<StoryboardLineArtStyle>(
                  key: const ValueKey('storyboard-line-art-style-segmented'),
                  options: [
                    for (final style in StoryboardLineArtStyle.values)
                      (value: style, label: style.label),
                  ],
                  selected: _lineArtStyle,
                  onChanged: locked || state.isGeneratingImage
                      ? null
                      : (style) => setState(() => _lineArtStyle = style),
                ),
                const SizedBox(height: 8),
                const _InspectorSettingLine(
                  icon: Icons.accessibility_new_rounded,
                  label: '人物',
                  value: '统一无特征中性人偶',
                ),
                const SizedBox(height: 6),
                const _InspectorSettingLine(
                  icon: Icons.filter_alt_off_rounded,
                  label: '画面净化',
                  value: '移除非叙事干扰',
                ),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  key: const ValueKey('storyboard-original-frame-switch'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: widget.showOriginalStoryboard,
                  title: const Text('查看原故事板'),
                  subtitle: Text(
                    widget.canShowOriginalStoryboard
                        ? '显示生成前保留的视频帧'
                        : '当前画板暂无可恢复的原视频帧',
                  ),
                  onChanged: widget.canShowOriginalStoryboard
                      ? widget.onToggleOriginalStoryboard
                      : null,
                ),
                const SizedBox(height: 4),
                FilledButton.icon(
                  key: const ValueKey('storyboard-line-art-button'),
                  onPressed:
                      locked ||
                          state.isGeneratingImage ||
                          board.visibleItemCount == 0
                      ? null
                      : () => widget.controller
                            .enqueueLineArtStoryboardForSelectedBoard(
                              aspectRatio: _lineArtRatio,
                              imageSize: _lineArtImageSize,
                              style: _lineArtStyle,
                            ),
                  icon: state.isGeneratingImage
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.draw_rounded),
                  label: Text(
                    state.isGeneratingImage ? '图片任务进行中...' : '生成当前画板线稿',
                  ),
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '高清重绘',
            icon: Icons.high_quality_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.redraw),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.redraw),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _InspectorSettingLine(
                  icon: Icons.auto_awesome_rounded,
                  label: '模型',
                  value: ImageGenerationModelCatalog.labelFor(
                    StoryboardController.highDefinitionRedrawModel,
                  ),
                ),
                const SizedBox(height: 6),
                _InspectorSettingLine(
                  icon: Icons.crop_16_9_rounded,
                  label: '比例',
                  value: widget.controller.projectAspectRatioLabel,
                ),
                const SizedBox(height: 6),
                const _InspectorSettingLine(
                  icon: Icons.hd_rounded,
                  label: '分辨率',
                  value: StoryboardController.highDefinitionRedrawImageSize,
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  key: const ValueKey('storyboard-hd-redraw-button'),
                  onPressed:
                      locked ||
                          state.isGeneratingImage ||
                          board.visibleItemCount == 0
                      ? null
                      : widget
                            .controller
                            .enqueueHighDefinitionRedrawForSelectedBoard,
                  icon: state.isGeneratingImage
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.high_quality_rounded),
                  label: Text(
                    state.isGeneratingImage ? '重绘进行中...' : '高清重绘当前画板',
                  ),
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '自动解析',
            icon: Icons.auto_awesome_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.analysis),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.analysis),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: locked || analyzeActive || analyzeQueued
                      ? null
                      : widget.controller.analyzeSelectedBoardWithVision,
                  icon: analyzeActive
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded),
                  label: Text(
                    analyzeActive
                        ? '正在解析...'
                        : analyzeQueued
                        ? '已排队解析'
                        : '自动解析故事板',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed:
                      locked ||
                          reorderActive ||
                          reorderQueued ||
                          board.visibleItemCount < 2
                      ? null
                      : widget.controller.reorderSelectedBoardByVisionAnalysis,
                  icon: reorderActive
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.low_priority_rounded),
                  label: Text(
                    reorderActive
                        ? '正在重排序...'
                        : reorderQueued
                        ? '已排队重排序'
                        : '自动重排序',
                  ),
                ),
                if (state.isAnalyzing) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: state.isCancellingAnalysis
                        ? null
                        : widget.controller.cancelVisionAnalysis,
                    icon: const Icon(Icons.cancel_rounded),
                    label: Text(
                      state.isCancellingAnalysis ? '正在取消...' : '取消当前任务',
                    ),
                  ),
                ],
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '图片编号',
            icon: Icons.format_list_numbered_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.number),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.number),
            child: Consumer(
              builder: (context, ref, _) {
                final settingsController = ref.watch(
                  settingsControllerProvider,
                );
                return ValueListenableBuilder(
                  valueListenable: settingsController,
                  builder: (context, settings, _) {
                    return CutImageNumberControls(
                      enabled: settings.cutImageNumberEnabled,
                      position: settings.cutImageNumberPosition,
                      backgroundOpacity:
                          settings.cutImageNumberBackgroundOpacity,
                      textScale: settings.cutImageNumberTextScale,
                      captionNumberEnabled:
                          settings.storyboardCaptionNumberEnabled,
                      onEnabledChanged:
                          settingsController.setCutImageNumberEnabled,
                      onPositionChanged:
                          settingsController.setCutImageNumberPosition,
                      onBackgroundOpacityChanged: settingsController
                          .previewCutImageNumberBackgroundOpacity,
                      onBackgroundOpacityChangeEnd:
                          settingsController.setCutImageNumberBackgroundOpacity,
                      onTextScaleChanged:
                          settingsController.previewCutImageNumberTextScale,
                      onTextScaleChangeEnd:
                          settingsController.setCutImageNumberTextScale,
                      onCaptionNumberEnabledChanged:
                          settingsController.setStoryboardCaptionNumberEnabled,
                    );
                  },
                );
              },
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '多宫格布局',
            icon: Icons.grid_view_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.layout),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.layout),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  key: const ValueKey('storyboard-portrait-mode-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('竖屏模式'),
                  subtitle: Text(
                    board.portraitMode ? '每行只显示 1 张图，行数随图片自动调整' : '使用多行多列宫格布局',
                  ),
                  value: board.portraitMode,
                  onChanged: locked ? null : widget.controller.setPortraitMode,
                ),
                const SizedBox(height: 8),
                Text(
                  board.isAutoExpandedFromConfiguredLayout
                      ? '设置 ${board.effectiveConfiguredRows} x ${board.effectiveConfiguredColumns} · 当前 ${board.rows} x ${board.columns} · ${board.slotCount} 格'
                      : '${board.rows} x ${board.columns} · ${board.slotCount} 格',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('storyboard-layout-rows-field'),
                        controller: _rowsController,
                        enabled: !locked && !board.portraitMode,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '行数'),
                        onChanged: _applyRowsAndAdaptColumns,
                        onSubmitted: _applyRowsAndAdaptColumns,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('storyboard-layout-columns-field'),
                        controller: _columnsController,
                        enabled: !locked && !board.portraitMode,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '列数'),
                        onChanged: _applyColumnsAndAdaptRows,
                        onSubmitted: _applyColumnsAndAdaptRows,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '画板尺寸',
            icon: Icons.aspect_ratio_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.size),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.size),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('宽度为准，高度自动适配'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PresetButton(
                      label: '宽度 1920',
                      onTap: locked
                          ? null
                          : () => widget.controller.setResolution(
                              1920,
                              board.height,
                            ),
                    ),
                    _PresetButton(
                      label: '宽度 1080',
                      onTap: locked
                          ? null
                          : () => widget.controller.setResolution(
                              1080,
                              board.height,
                            ),
                    ),
                    _PresetButton(
                      label: '宽度 1280',
                      onTap: locked
                          ? null
                          : () => widget.controller.setResolution(
                              1280,
                              board.height,
                            ),
                    ),
                    _PresetButton(
                      label: '宽度 2480',
                      onTap: locked
                          ? null
                          : () => widget.controller.setResolution(
                              2480,
                              board.height,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _widthController,
                        enabled: !locked,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '宽度'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _heightController,
                        readOnly: true,
                        decoration: const InputDecoration(labelText: '高度（自动）'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: locked
                      ? null
                      : () {
                          widget.controller.setResolution(
                            int.tryParse(_widthController.text) ?? board.width,
                            board.height,
                          );
                        },
                  icon: const Icon(Icons.aspect_ratio_rounded),
                  label: const Text('应用画板宽度'),
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '间距与分割线',
            icon: Icons.space_bar_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.spacing),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.spacing),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前间距：${board.gap.round()}'),
                Slider(
                  value: board.gap,
                  min: 0,
                  max: 64,
                  divisions: 16,
                  label: '${board.gap.round()}',
                  onChanged: locked ? null : widget.controller.setGap,
                ),
                const Divider(height: 24),
                SwitchListTile(
                  key: const ValueKey('row-divider-enabled-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: board.rowDividerEnabled,
                  title: const Text('行分割线'),
                  subtitle: const Text('在每两行的等距间隔中心绘制分割线'),
                  onChanged: locked
                      ? null
                      : widget.controller.setRowDividerEnabled,
                ),
                const SizedBox(height: 8),
                _CompactSegmentedControl<StoryboardDividerStyle>(
                  options: [
                    for (final style in StoryboardDividerStyle.values)
                      (value: style, label: style.label),
                  ],
                  selected: board.rowDividerStyle,
                  onChanged: locked || !board.rowDividerEnabled
                      ? null
                      : widget.controller.setRowDividerStyle,
                ),
                const SizedBox(height: 12),
                Text('透明度：${(board.rowDividerOpacity * 100).round()}%'),
                Slider(
                  key: const ValueKey('row-divider-opacity-slider'),
                  value: board.rowDividerOpacity,
                  min: 0.05,
                  max: 1,
                  divisions: 19,
                  label: '${(board.rowDividerOpacity * 100).round()}%',
                  onChanged: locked || !board.rowDividerEnabled
                      ? null
                      : widget.controller.setRowDividerOpacity,
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '描述显示',
            icon: Icons.notes_rounded,
            expanded: _sectionExpanded(
              _StoryboardInspectorSection.descriptions,
            ),
            onToggle: () => widget.onToggleSection(
              _StoryboardInspectorSection.descriptions,
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: board.storyDescriptionEnabled,
                  title: const Text('故事描述'),
                  subtitle: const Text('关闭后隐藏所有文本框并释放图片空间'),
                  onChanged: locked
                      ? null
                      : widget.controller.setStoryDescriptionEnabled,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: board.rowDescriptionEnabled,
                  title: const Text('逐行描述'),
                  subtitle: const Text('开启后每一行只显示一个文本输入框'),
                  onChanged: locked
                      ? null
                      : widget.controller.setRowDescriptionEnabled,
                ),
              ],
            ),
          ),
          _StoryboardInspectorSectionPanel(
            title: '描述字体',
            icon: Icons.font_download_rounded,
            expanded: _sectionExpanded(_StoryboardInspectorSection.typography),
            onToggle: () =>
                widget.onToggleSection(_StoryboardInspectorSection.typography),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _fontFamilies.contains(board.captionFontFamily)
                      ? board.captionFontFamily
                      : _fontFamilies.first,
                  decoration: const InputDecoration(
                    labelText: '描述字体',
                    prefixIcon: Icon(Icons.font_download_rounded),
                  ),
                  items: [
                    for (final fontFamily in _fontFamilies)
                      DropdownMenuItem(
                        value: fontFamily,
                        child: Text(fontFamily),
                      ),
                  ],
                  onChanged: locked
                      ? null
                      : (fontFamily) {
                          if (fontFamily != null) {
                            widget.controller.setCaptionFontFamily(fontFamily);
                          }
                        },
                ),
                const SizedBox(height: 12),
                Text('字体大小：${board.captionFontSize.round()}'),
                Slider(
                  value: board.captionFontSize,
                  min: 12,
                  max: 48,
                  divisions: 36,
                  label: '${board.captionFontSize.round()}',
                  onChanged: locked
                      ? null
                      : widget.controller.setCaptionFontSize,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _sectionExpanded(_StoryboardInspectorSection section) {
    return widget.expandedSections.contains(section);
  }

  void _applyRowsAndAdaptColumns(String value) {
    final rows = int.tryParse(value);
    if (rows == null) {
      return;
    }
    widget.controller.setRowsAndAdaptColumns(rows);
  }

  void _applyColumnsAndAdaptRows(String value) {
    final columns = int.tryParse(value);
    if (columns == null) {
      return;
    }
    widget.controller.setColumnsAndAdaptRows(columns);
  }

  Future<void> _exportBoardImages(StoryboardBoard board) async {
    setState(() => _isExportingBoardImages = true);
    try {
      await widget.onExportBoardImages(board);
    } finally {
      if (mounted) {
        setState(() => _isExportingBoardImages = false);
      }
    }
  }

  Future<void> _confirmClearCurrentBoard(StoryboardBoard board) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('清空当前画板'),
          content: Text('确定清空「${board.name}」吗？画板内图片和描述会一并移除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.delete_sweep_rounded),
              label: const Text('清空'),
            ),
          ],
        );
      },
    );
    if (!mounted || confirmed != true) {
      return;
    }
    widget.controller.clearSelectedBoard();
  }
}

class _InspectorSettingLine extends StatelessWidget {
  const _InspectorSettingLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 7),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      ],
    );
  }
}

class _StoryboardInspectorSectionPanel extends StatelessWidget {
  const _StoryboardInspectorSectionPanel({
    required this.title,
    required this.icon,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final IconData icon;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.36),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCollapsibleContent(
            expanded: expanded,
            child: Padding(
              key: const ValueKey('expanded-section-content'),
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactSegmentedControl<T> extends StatelessWidget {
  const _CompactSegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < options.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(child: _buildOption(context, options[index])),
        ],
      ],
    );
  }

  Widget _buildOption(BuildContext context, ({T value, String label}) option) {
    final selectedOption = option.value == selected;
    final onPressed = onChanged == null ? null : () => onChanged!(option.value);
    final style = selectedOption
        ? FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          )
        : OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          );
    final label = Text(
      option.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    return selectedOption
        ? FilledButton(onPressed: onPressed, style: style, child: label)
        : OutlinedButton(onPressed: onPressed, style: style, child: label);
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.crop_landscape_rounded, size: 16),
      onPressed: onTap,
    );
  }
}

class _BoardBar extends StatelessWidget {
  const _BoardBar({
    required this.state,
    required this.onSelect,
    required this.onAdd,
    required this.onDuplicate,
    required this.onManage,
    required this.onClose,
  });

  final StoryboardState state;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onDuplicate;
  final VoidCallback onManage;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('storyboard-board-bar'),
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final board in state.openBoards)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _BoardChip(
                        board: board,
                        selected: board.id == state.selectedBoard?.id,
                        onSelect: () => onSelect(board.id),
                        onClose: () => onClose(board.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('open-board-manager'),
            onPressed: onManage,
            icon: const Icon(Icons.dashboard_customize_outlined),
            label: const Text('画板管理'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('duplicate-storyboard-board'),
            onPressed: state.selectedBoard == null ? null : onDuplicate,
            icon: const Icon(Icons.copy_rounded),
            label: const Text('复制画板'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新画板'),
          ),
        ],
      ),
    );
  }
}

class _BoardChip extends StatelessWidget {
  const _BoardChip({
    required this.board,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final StoryboardBoard board;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 34,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.88)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? scheme.primary.withValues(alpha: 0.36)
              : scheme.outlineVariant.withValues(alpha: 0.52),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(8),
            ),
            onTap: onSelect,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Text(
                board.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
          ),
          Tooltip(
            message: '关闭画板页签',
            child: IconButton(
              key: ValueKey('close-board-${board.id}'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}
