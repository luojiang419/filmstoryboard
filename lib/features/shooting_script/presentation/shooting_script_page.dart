import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_availability_cache.dart';
import '../../../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../../../core/widgets/desktop_drop_target_scope.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/data/seedance_prompt_generation_service.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../replicate/presentation/replicate_page.dart';
import '../../replicate/presentation/replicate_shot_navigation_controller.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../video_analysis/application/video_analysis_controller.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../application/shooting_asset_library_controller.dart';
import '../application/shooting_script_controller.dart';
import '../domain/shooting_asset_library_models.dart';
import '../domain/shooting_script_models.dart';

class ShootingScriptPage extends ConsumerStatefulWidget {
  const ShootingScriptPage({super.key});

  static const _assetTypes = XTypeGroup(
    label: '视频资产',
    extensions: [
      'png',
      'jpg',
      'jpeg',
      'webp',
      'bmp',
      'gif',
      'mp4',
      'mov',
      'mkv',
      'avi',
      'webm',
      'mp3',
      'wav',
      'm4a',
      'aac',
      'flac',
      'ogg',
    ],
  );

  @override
  ConsumerState<ShootingScriptPage> createState() => _ShootingScriptPageState();
}

class _ShootingScriptPageState extends ConsumerState<ShootingScriptPage> {
  static const _uiStateKey = 'shootingScriptPageUiState';
  static const _stepPanelCollapsedKey = 'shootingScriptStepPanelCollapsed';
  static const _collapsedPanelWidth = 56.0;
  static const _minimumScriptPanelWidth = 220.0;
  static const _minimumStepPanelWidth = 260.0;
  static const _minimumWorkspaceWidth = 360.0;
  static const _panelGap = 8.0;
  static const _resizeHandleWidth = 10.0;

  var _scriptPanelWidth = 280.0;
  var _stepPanelWidth = 330.0;
  var _scriptPanelCollapsed = false;
  var _stepPanelCollapsed = false;
  final _shotNavigationController = ReplicateShotNavigationController();
  final _fileAvailabilityCache = FileAvailabilityCache();

  @override
  void initState() {
    super.initState();
    _restoreUiState();
  }

  @override
  void dispose() {
    _shotNavigationController.dispose();
    _fileAvailabilityCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('shooting_script.page');
    final controller = ref.watch(shootingScriptControllerProvider);
    final replicateController = ref.watch(replicateControllerProvider);
    final assetLibraryController = ref.watch(
      shootingAssetLibraryControllerProvider,
    );
    final videoController = ref.watch(videoAnalysisControllerProvider);
    final storyboardController = ref.watch(storyboardControllerProvider);
    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ValueListenableBuilder<ShootingScriptState>(
        valueListenable: controller,
        builder: (context, state, _) => ValueListenableBuilder<ReplicateState>(
          valueListenable: replicateController,
          builder: (context, replicateState, _) =>
              ValueListenableBuilder<ShootingAssetLibraryState>(
                valueListenable: assetLibraryController,
                builder: (context, libraryState, _) => ColoredBox(
                  key: const ValueKey('shooting-script-page'),
                  color: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _PageHeader(
                          state: state,
                          controller: controller,
                          onExportStoryboardImages: () =>
                              _exportStoryboardImages(
                                context,
                                controller,
                                replicateController,
                              ),
                          onRename: () =>
                              _renameScript(context, controller, state),
                          onDelete: () =>
                              _deleteScript(context, controller, state),
                          onManageAssets: () => _openAssetManager(
                            context,
                            assetLibraryController,
                            replicateController,
                          ),
                        ),
                        if (state.message.isNotEmpty ||
                            state.errorMessage.isNotEmpty ||
                            replicateState.message.isNotEmpty ||
                            replicateState.errorMessage.isNotEmpty ||
                            libraryState.message.isNotEmpty ||
                            libraryState.errorMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _noticeText(state, replicateState, libraryState),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    state.errorMessage.isNotEmpty ||
                                        replicateState
                                            .errorMessage
                                            .isNotEmpty ||
                                        libraryState.errorMessage.isNotEmpty
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final sidebar = CollapsiblePanelRegistration(
                                expanded: !_scriptPanelCollapsed,
                                onExpandedChanged: _setScriptPanelExpanded,
                                child: _ScriptSidebar(
                                  state: state,
                                  controller: controller,
                                  collapsed: _scriptPanelCollapsed,
                                  onCreate: () =>
                                      _createScript(context, controller),
                                  onDeleteScript: (script) => _deleteScript(
                                    context,
                                    controller,
                                    state,
                                    script,
                                  ),
                                  onToggleCollapsed: _toggleScriptPanel,
                                  onCreateFromVideo: () =>
                                      controller.createFromVideo(
                                        video: videoController
                                            .value
                                            .selectedVideo!,
                                        frames: videoController.value.frames,
                                        videoShots: videoController.value.shots,
                                        analyses:
                                            videoController.value.frameAnalyses,
                                      ),
                                  canCreateFromVideo:
                                      videoController.value.selectedVideo !=
                                      null,
                                  onCreateFromStoryboard: () =>
                                      controller.createFromStoryboard(
                                        storyboardController
                                            .value
                                            .selectedBoard,
                                      ),
                                  canCreateFromStoryboard:
                                      storyboardController
                                          .value
                                          .selectedBoard !=
                                      null,
                                ),
                              );
                              if (constraints.maxWidth < 900) {
                                final workspace = ReplicatePage(
                                  key: const ValueKey(
                                    'shooting-script-workflow',
                                  ),
                                  embedded: true,
                                  onManageAssets: () => _openAssetManager(
                                    context,
                                    assetLibraryController,
                                    replicateController,
                                  ),
                                  shotNavigationController:
                                      _shotNavigationController,
                                  onOpenShootingScript: () {},
                                );
                                return Column(
                                  children: [
                                    SizedBox(
                                      height: _scriptPanelCollapsed ? 64 : 250,
                                      child: sidebar,
                                    ),
                                    const SizedBox(height: 12),
                                    Expanded(child: workspace),
                                  ],
                                );
                              }
                              final useOuterStepPanel =
                                  constraints.maxWidth >= 1100;
                              if (useOuterStepPanel) {
                                _restoreSharedStepPanelState();
                              }
                              final workspace = ReplicatePage(
                                key: const ValueKey('shooting-script-workflow'),
                                embedded: true,
                                externalizeStepRightPanel: useOuterStepPanel,
                                onManageAssets: () => _openAssetManager(
                                  context,
                                  assetLibraryController,
                                  replicateController,
                                ),
                                shotNavigationController:
                                    _shotNavigationController,
                                onOpenShootingScript: () {},
                              );
                              if (!useOuterStepPanel) {
                                final availableWidth =
                                    constraints.maxWidth -
                                    _panelGap -
                                    _resizeHandleWidth;
                                final maximumScriptWidth = math.max(
                                  _minimumScriptPanelWidth,
                                  availableWidth - _minimumWorkspaceWidth,
                                );
                                final scriptWidth = _scriptPanelCollapsed
                                    ? _collapsedPanelWidth
                                    : _scriptPanelWidth
                                          .clamp(
                                            _minimumScriptPanelWidth,
                                            maximumScriptWidth,
                                          )
                                          .toDouble();
                                return Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      width: scriptWidth,
                                      child: sidebar,
                                    ),
                                    _PanelResizeHandle(
                                      key: const ValueKey(
                                        'shooting-script-left-resize-handle',
                                      ),
                                      onDragEnd: _saveUiState,
                                      onDrag: _scriptPanelCollapsed
                                          ? null
                                          : (delta) => setState(() {
                                              _scriptPanelWidth =
                                                  (scriptWidth + delta)
                                                      .clamp(
                                                        _minimumScriptPanelWidth,
                                                        maximumScriptWidth,
                                                      )
                                                      .toDouble();
                                            }),
                                    ),
                                    const SizedBox(width: _panelGap),
                                    Expanded(child: workspace),
                                  ],
                                );
                              }
                              final availablePanels =
                                  constraints.maxWidth -
                                  _panelGap * 2 -
                                  _resizeHandleWidth * 2;
                              final minimumLeft = _scriptPanelCollapsed
                                  ? _collapsedPanelWidth
                                  : _minimumScriptPanelWidth;
                              final minimumRight = _stepPanelCollapsed
                                  ? _collapsedPanelWidth
                                  : _minimumStepPanelWidth;
                              final maximumRight = math.max(
                                minimumRight,
                                availablePanels -
                                    _minimumWorkspaceWidth -
                                    minimumLeft,
                              );
                              final stepPanelWidth = _stepPanelCollapsed
                                  ? _collapsedPanelWidth
                                  : _stepPanelWidth
                                        .clamp(
                                          _minimumStepPanelWidth,
                                          maximumRight,
                                        )
                                        .toDouble();
                              final maximumLeft = math.max(
                                minimumLeft,
                                availablePanels -
                                    _minimumWorkspaceWidth -
                                    stepPanelWidth,
                              );
                              final scriptWidth = _scriptPanelCollapsed
                                  ? _collapsedPanelWidth
                                  : _scriptPanelWidth
                                        .clamp(
                                          _minimumScriptPanelWidth,
                                          maximumLeft,
                                        )
                                        .toDouble();
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(width: scriptWidth, child: sidebar),
                                  _PanelResizeHandle(
                                    key: const ValueKey(
                                      'shooting-script-left-resize-handle',
                                    ),
                                    onDragEnd: _saveUiState,
                                    onDrag: _scriptPanelCollapsed
                                        ? null
                                        : (delta) => setState(() {
                                            _scriptPanelWidth =
                                                (scriptWidth + delta)
                                                    .clamp(
                                                      _minimumScriptPanelWidth,
                                                      maximumLeft,
                                                    )
                                                    .toDouble();
                                          }),
                                  ),
                                  const SizedBox(width: _panelGap),
                                  Expanded(child: workspace),
                                  const SizedBox(width: _panelGap),
                                  _PanelResizeHandle(
                                    key: const ValueKey(
                                      'shooting-script-step-right-resize-handle',
                                    ),
                                    onDragEnd: _saveUiState,
                                    onDrag: _stepPanelCollapsed
                                        ? null
                                        : (delta) => setState(() {
                                            _stepPanelWidth =
                                                (stepPanelWidth - delta)
                                                    .clamp(
                                                      _minimumStepPanelWidth,
                                                      maximumRight,
                                                    )
                                                    .toDouble();
                                          }),
                                  ),
                                  CollapsiblePanelRegistration(
                                    expanded: !_stepPanelCollapsed,
                                    onExpandedChanged: _setStepPanelExpanded,
                                    child: SizedBox(
                                      width: stepPanelWidth,
                                      child: ReplicateEmbeddedStepRightPanel(
                                        collapsed: _stepPanelCollapsed,
                                        shotNavigationController:
                                            _shotNavigationController,
                                        onManageAssets: () => _openAssetManager(
                                          context,
                                          assetLibraryController,
                                          replicateController,
                                        ),
                                        onToggleCollapsed: _toggleStepPanel,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }

  void _toggleScriptPanel() {
    _setScriptPanelExpanded(_scriptPanelCollapsed);
  }

  void _setScriptPanelExpanded(bool expanded) {
    if (_scriptPanelCollapsed == !expanded) {
      return;
    }
    setState(() => _scriptPanelCollapsed = !expanded);
    _saveUiState();
  }

  void _toggleStepPanel() {
    _setStepPanelExpanded(_stepPanelCollapsed);
  }

  void _setStepPanelExpanded(bool expanded) {
    if (_stepPanelCollapsed == !expanded) {
      return;
    }
    setState(() => _stepPanelCollapsed = !expanded);
    _saveUiState(syncSharedStepState: false);
  }

  void _restoreUiState() {
    try {
      final database = ref.read(appDatabaseProvider);
      final raw = database.getSetting(_uiStateKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          _scriptPanelWidth = _jsonDouble(
            decoded['scriptPanelWidth'],
            280,
          ).clamp(_minimumScriptPanelWidth, 720).toDouble();
          _stepPanelWidth = _jsonDouble(
            decoded['stepPanelWidth'],
            330,
          ).clamp(_minimumStepPanelWidth, 720).toDouble();
          _scriptPanelCollapsed = _jsonBool(
            decoded['scriptPanelCollapsed'],
            false,
          );
          _stepPanelCollapsed = _jsonBool(decoded['stepPanelCollapsed'], false);
        }
      }
      _restoreSharedStepPanelState();
    } catch (_) {
      return;
    }
  }

  void _restoreSharedStepPanelState() {
    try {
      final sharedStepPanelState = ref
          .read(appDatabaseProvider)
          .getSetting(_stepPanelCollapsedKey);
      if (sharedStepPanelState == 'true' || sharedStepPanelState == 'false') {
        _stepPanelCollapsed = sharedStepPanelState == 'true';
      }
    } catch (_) {
      return;
    }
  }

  void _saveUiState({bool syncSharedStepState = true}) {
    try {
      if (syncSharedStepState) {
        _restoreSharedStepPanelState();
      }
      ref.read(appDatabaseProvider)
        ..setSetting(
          _uiStateKey,
          jsonEncode({
            'scriptPanelWidth': _scriptPanelWidth,
            'stepPanelWidth': _stepPanelWidth,
            'scriptPanelCollapsed': _scriptPanelCollapsed,
            'stepPanelCollapsed': _stepPanelCollapsed,
          }),
        )
        ..setSetting(_stepPanelCollapsedKey, _stepPanelCollapsed.toString());
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  double _jsonDouble(Object? value, double fallback) {
    return value is num ? value.toDouble() : fallback;
  }

  bool _jsonBool(Object? value, bool fallback) {
    return value is bool ? value : fallback;
  }

  static String _noticeText(
    ShootingScriptState state,
    ReplicateState replicateState,
    ShootingAssetLibraryState libraryState,
  ) {
    for (final text in [
      state.errorMessage,
      replicateState.errorMessage,
      libraryState.errorMessage,
      state.message,
      replicateState.message,
      libraryState.message,
    ]) {
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  Future<void> _openAssetManager(
    BuildContext context,
    ShootingAssetLibraryController libraryController,
    ReplicateController replicateController,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => _AssetManagerPage(
          libraryController: libraryController,
          replicateController: replicateController,
          onPickFiles: _pickLibraryFiles,
          onManualAdd: _manualAddLibraryAsset,
          onGenerate: _generateLibraryAsset,
          onEdit: _editLibraryAsset,
        ),
      ),
    );
  }

  Future<List<XFile>> _pickLibraryFiles(
    BuildContext context,
    ReplicateAssetType type,
  ) async {
    return ref
        .read(desktopFileDialogServiceProvider)
        .openFiles(
          source: 'shooting_script.asset_library',
          acceptedTypeGroups: const [ShootingScriptPage._assetTypes],
          initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
        );
  }

  Future<void> _manualAddLibraryAsset(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  ) async {
    final result = await _showLibraryAssetEditor(
      context,
      title: '手动添加资产',
      initialType: type,
      allowTypeChange: true,
      includePath: true,
    );
    if (result == null || result.path.trim().isEmpty) {
      return;
    }
    await controller.importItem(
      sourcePath: result.path,
      type: result.type,
      name: result.name,
      description: result.description,
      aliases: result.aliases,
    );
  }

  Future<void> _generateLibraryAsset(
    BuildContext context,
    ShootingAssetLibraryController libraryController,
    ReplicateController replicateController,
    ReplicateAssetType initialType,
  ) async {
    final result = await _showLibraryAssetEditor(
      context,
      title: '按描述生成资产',
      initialType: initialType.isImageType
          ? initialType
          : ReplicateAssetType.character,
      allowTypeChange: true,
      includePath: false,
      imageTypesOnly: true,
      confirmLabel: '开始生成',
    );
    if (result == null || result.description.trim().isEmpty) return;
    final generated = await replicateController.generateImageAsset(
      type: result.type,
      name: result.name,
      description: result.description,
    );
    if (generated == null || generated.path.trim().isEmpty) return;
    await libraryController.importItem(
      sourcePath: generated.path,
      type: generated.type,
      name: generated.name,
      description: generated.description,
      aliases: result.aliases,
    );
  }

  Future<void> _editLibraryAsset(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ShootingAssetLibraryItem item,
  ) async {
    final result = await _showLibraryAssetEditor(
      context,
      title: '编辑资产',
      initialType: item.type,
      initialName: item.name,
      initialDescription: item.description,
      initialAliases: item.aliases.join(', '),
      initialPath: item.path,
      allowTypeChange: true,
      includePath: false,
    );
    if (result == null) {
      return;
    }
    controller.updateItem(
      item.copyWith(
        type: result.type,
        name: result.name,
        description: result.description,
        aliases: result.aliases,
      ),
    );
  }

  Future<_LibraryAssetEditorResult?> _showLibraryAssetEditor(
    BuildContext context, {
    required String title,
    required ReplicateAssetType initialType,
    String initialName = '',
    String initialDescription = '',
    String initialAliases = '',
    String initialPath = '',
    required bool allowTypeChange,
    required bool includePath,
    bool imageTypesOnly = false,
    String confirmLabel = '保存',
  }) async {
    var type = imageTypesOnly && !initialType.isImageType
        ? ReplicateAssetType.character
        : initialType;
    final nameController = TextEditingController(text: initialName);
    final descriptionController = TextEditingController(
      text: initialDescription,
    );
    final aliasesController = TextEditingController(text: initialAliases);
    final pathController = TextEditingController(text: initialPath);
    final result = await showDialog<_LibraryAssetEditorResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ReplicateAssetType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '资产类型'),
                  items: [
                    for (final item in ReplicateAssetType.values)
                      if (!imageTypesOnly || item.isImageType)
                        DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: allowTypeChange
                      ? (value) {
                          if (value != null) {
                            setDialogState(() => type = value);
                          }
                        }
                      : null,
                ),
                if (includePath) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: pathController,
                    decoration: const InputDecoration(labelText: '文件路径'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '资产名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '特征描述',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: aliasesController,
                  decoration: const InputDecoration(
                    labelText: '匹配别名（用逗号分隔）',
                    helperText: '用于故事板名称自动绑定，不参与视觉识别',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _LibraryAssetEditorResult(
                  type: type,
                  name: nameController.text.trim(),
                  description: descriptionController.text.trim(),
                  aliases: _parseAliases(aliasesController.text),
                  path: pathController.text.trim(),
                ),
              ),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    descriptionController.dispose();
    aliasesController.dispose();
    pathController.dispose();
    return result;
  }

  static List<String> _parseAliases(String value) => value
      .split(RegExp(r'[,，;；\n\r]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> _createScript(
    BuildContext context,
    ShootingScriptController controller,
  ) async {
    final name = await _askName(context, title: '新建拍摄脚本', initial: '新建脚本');
    if (name != null) {
      controller.createEmpty(name: name);
    }
  }

  Future<void> _exportStoryboardImages(
    BuildContext context,
    ShootingScriptController scriptController,
    ReplicateController replicateController,
  ) async {
    final choice = await showDialog<_StoryboardImageExportChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出分镜图片'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('export-original-storyboard-images'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('导出原分镜图'),
              onTap: () => Navigator.of(
                context,
              ).pop(_StoryboardImageExportChoice.original),
            ),
            ListTile(
              key: const ValueKey('export-replicated-storyboard-images'),
              leading: const Icon(Icons.auto_awesome_motion_rounded),
              title: const Text('导出复刻分镜图'),
              onTap: () => Navigator.of(
                context,
              ).pop(_StoryboardImageExportChoice.replicated),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    switch (choice) {
      case _StoryboardImageExportChoice.original:
        await scriptController.exportOriginalImages();
        break;
      case _StoryboardImageExportChoice.replicated:
        await replicateController.exportReplicatedImages();
        break;
    }
  }

  Future<void> _renameScript(
    BuildContext context,
    ShootingScriptController controller,
    ShootingScriptState state,
  ) async {
    final script = state.selectedScript;
    if (script == null) {
      return;
    }
    final name = await _askName(
      context,
      title: '重命名拍摄脚本',
      initial: script.name,
    );
    if (name != null) {
      controller.renameSelectedScript(name);
    }
  }

  Future<void> _deleteScript(
    BuildContext context,
    ShootingScriptController controller,
    ShootingScriptState state, [
    ShootingScript? targetScript,
  ]) async {
    final script = targetScript ?? state.selectedScript;
    if (script == null) {
      return;
    }
    final shotCount = script.id == state.selectedScriptId
        ? state.shots.length
        : null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除拍摄脚本？'),
        content: Text(
          shotCount == null
              ? '将删除“${script.name}”及其关联镜头。已导出的文件不会删除。'
              : '将删除“${script.name}”及其 $shotCount 个镜头。已导出的文件不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.deleteScript(script.id);
    }
  }

  Future<String?> _askName(
    BuildContext context, {
    required String title,
    required String initial,
  }) async {
    var enteredName = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(labelText: '脚本名称'),
          onChanged: (value) => enteredName = value,
          onSubmitted: (_) => Navigator.of(context).pop(enteredName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(enteredName),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result?.trim().isEmpty == true ? null : result?.trim();
  }
}

enum _StoryboardImageExportChoice { original, replicated }

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.state,
    required this.controller,
    required this.onExportStoryboardImages,
    required this.onRename,
    required this.onDelete,
    required this.onManageAssets,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final VoidCallback onExportStoryboardImages;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onManageAssets;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '拍摄脚本',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                state.selectedScript == null
                    ? '新建空脚本，或从当前视频/故事板生成'
                    : '${state.selectedScript!.name} · 版本 ${state.selectedScript!.version}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Flexible(
          flex: 3,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: state.selectedScript == null ? null : onRename,
                icon: const Icon(Icons.drive_file_rename_outline_rounded),
                label: const Text('重命名'),
              ),
              OutlinedButton.icon(
                onPressed: state.selectedScript == null
                    ? null
                    : controller.duplicateSelectedScript,
                icon: const Icon(Icons.copy_rounded),
                label: const Text('复制脚本'),
              ),
              OutlinedButton.icon(
                onPressed: state.selectedScript == null
                    ? null
                    : controller.toggleArchiveSelectedScript,
                icon: Icon(
                  state.selectedScript?.status == ShootingScriptStatus.archived
                      ? Icons.unarchive_rounded
                      : Icons.archive_outlined,
                ),
                label: Text(
                  state.selectedScript?.status == ShootingScriptStatus.archived
                      ? '恢复'
                      : '归档',
                ),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('export-shooting-script-xlsx'),
                onPressed: state.selectedScript == null || state.isExporting
                    ? null
                    : controller.exportXlsx,
                icon: const Icon(Icons.table_view_rounded),
                label: const Text('导出 XLSX'),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('export-shooting-script-originals'),
                onPressed:
                    state.selectedScript == null ||
                        state.isExporting ||
                        state.shots.isEmpty
                    ? null
                    : onExportStoryboardImages,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('导出分镜图片'),
              ),
              IconButton(
                tooltip: '打开脚本导出目录',
                onPressed: controller.openOutputDirectory,
                icon: const Icon(Icons.folder_open_rounded),
              ),
              IconButton(
                key: const ValueKey('manage-shooting-asset-library'),
                tooltip: '管理资产库',
                onPressed: onManageAssets,
                icon: const Icon(Icons.tune_rounded),
              ),
              IconButton(
                tooltip: '删除当前脚本',
                onPressed: state.selectedScript == null ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScriptSidebar extends StatelessWidget {
  const _ScriptSidebar({
    required this.state,
    required this.controller,
    required this.collapsed,
    required this.onCreate,
    required this.onDeleteScript,
    required this.onToggleCollapsed,
    required this.onCreateFromVideo,
    required this.canCreateFromVideo,
    required this.onCreateFromStoryboard,
    required this.canCreateFromStoryboard,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final bool collapsed;
  final VoidCallback onCreate;
  final ValueChanged<ShootingScript> onDeleteScript;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onCreateFromVideo;
  final bool canCreateFromVideo;
  final VoidCallback onCreateFromStoryboard;
  final bool canCreateFromStoryboard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: collapsed
          ? Center(
              child: IconButton(
                key: const ValueKey('expand-script-sidebar'),
                tooltip: '展开脚本列表',
                onPressed: onToggleCollapsed,
                icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '脚本列表',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('collapse-script-sidebar'),
                        tooltip: '折叠脚本列表',
                        onPressed: onToggleCollapsed,
                        icon: const Icon(
                          Icons.keyboard_double_arrow_left_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: state.scripts.isEmpty
                        ? const Center(child: Text('尚未创建脚本'))
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            itemCount: state.scripts.length,
                            onReorder: controller.reorderScripts,
                            itemBuilder: (context, index) {
                              final script = state.scripts[index];
                              return Padding(
                                key: ValueKey(script.id),
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _ScriptListCard(
                                  index: index,
                                  script: script,
                                  selected: script.id == state.selectedScriptId,
                                  onTap: () =>
                                      controller.selectScript(script.id),
                                  onDelete: () => onDeleteScript(script),
                                ),
                              );
                            },
                          ),
                  ),
                  const Divider(),
                  FilledButton.icon(
                    key: const ValueKey('create-empty-shooting-script'),
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('新建空脚本'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('create-shooting-script-from-video'),
                    onPressed: canCreateFromVideo ? onCreateFromVideo : null,
                    icon: const Icon(Icons.video_file_rounded),
                    label: const Text('从当前视频生成'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey(
                      'create-shooting-script-from-storyboard',
                    ),
                    onPressed: canCreateFromStoryboard
                        ? onCreateFromStoryboard
                        : null,
                    icon: const Icon(Icons.dashboard_customize_rounded),
                    label: const Text('从当前故事板生成'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ScriptListCard extends StatelessWidget {
  const _ScriptListCard({
    required this.index,
    required this.script,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final ShootingScript script;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = selected ? scheme.primary : scheme.outlineVariant;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.secondaryContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: selected ? 1.4 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                script.status == ShootingScriptStatus.archived
                    ? Icons.archive_outlined
                    : Icons.description_outlined,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      script.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text('v${script.version} · ${script.status.label}'),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除脚本',
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: '拖拽动态排序',
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
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

class _PanelResizeHandle extends StatelessWidget {
  const _PanelResizeHandle({super.key, required this.onDrag, this.onDragEnd});

  final ValueChanged<double>? onDrag;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: onDrag == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: onDrag == null
            ? null
            : (details) => onDrag!(details.delta.dx),
        onHorizontalDragEnd: onDrag == null ? null : (_) => onDragEnd?.call(),
        child: SizedBox(
          width: _ShootingScriptPageState._resizeHandleWidth,
          child: Center(
            child: Container(
              width: 1,
              height: double.infinity,
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetManagerPage extends StatefulWidget {
  const _AssetManagerPage({
    required this.libraryController,
    required this.replicateController,
    required this.onPickFiles,
    required this.onManualAdd,
    required this.onGenerate,
    required this.onEdit,
  });

  final ShootingAssetLibraryController libraryController;
  final ReplicateController replicateController;
  final Future<List<XFile>> Function(
    BuildContext context,
    ReplicateAssetType type,
  )
  onPickFiles;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  )
  onManualAdd;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController libraryController,
    ReplicateController replicateController,
    ReplicateAssetType type,
  )
  onGenerate;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ShootingAssetLibraryItem item,
  )
  onEdit;

  @override
  State<_AssetManagerPage> createState() => _AssetManagerPageState();
}

class _AssetManagerPageState extends State<_AssetManagerPage> {
  ReplicateAssetType _type = ReplicateAssetType.character;
  var _isOpeningFilePicker = false;
  var _isGeneratingAsset = false;
  var _isDraggingOver = false;

  Future<void> _pickFiles() async {
    if (_isOpeningFilePicker) {
      return;
    }
    setState(() => _isOpeningFilePicker = true);
    try {
      final files = await widget.onPickFiles(context, _type);
      await _openBatchImportDialog(files);
    } finally {
      if (mounted) {
        setState(() => _isOpeningFilePicker = false);
      }
    }
  }

  Future<void> _importDroppedFiles(DropDoneDetails details) async {
    setState(() => _isDraggingOver = false);
    await _openBatchImportDialog(details.files);
  }

  Future<void> _openBatchImportDialog(Iterable<XFile> files) async {
    final paths = files
        .map((file) => file.path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty || !mounted) {
      return;
    }
    final requests = await showDialog<List<_LibraryImportRequest>>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _BatchLibraryAssetImportDialog(paths: paths, initialType: _type),
    );
    if (requests == null || requests.isEmpty || !mounted) {
      return;
    }
    await widget.libraryController.importItems(requests);
  }

  Future<void> _generateAsset() async {
    if (_isGeneratingAsset || widget.replicateController.value.isBusy) return;
    setState(() => _isGeneratingAsset = true);
    try {
      await widget.onGenerate(
        context,
        widget.libraryController,
        widget.replicateController,
        _type,
      );
    } finally {
      if (mounted) setState(() => _isGeneratingAsset = false);
    }
  }

  Future<void> _replaceDroppedFile(
    ShootingAssetLibraryItem item,
    DropDoneDetails details,
  ) async {
    if (details.files.isEmpty) {
      return;
    }
    await widget.libraryController.replaceItemFile(
      id: item.id,
      sourcePath: details.files.first.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ShootingAssetLibraryState>(
      valueListenable: widget.libraryController,
      builder: (context, state, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: Focus(
          autofocus: true,
          child: DropTarget(
            enable: DesktopDropTargetScope.enabledOf(context),
            key: const ValueKey('asset-manager-drop-target'),
            onDragEntered: (_) => setState(() => _isDraggingOver = true),
            onDragExited: (_) => setState(() => _isDraggingOver = false),
            onDragDone: _importDroppedFiles,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('资产管理'),
                actions: [
                  IconButton(
                    tooltip: '打开资产目录',
                    onPressed: widget.libraryController.openLibraryDirectory,
                    icon: const Icon(Icons.folder_open_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              body: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 220,
                              child:
                                  DropdownButtonFormField<ReplicateAssetType>(
                                    initialValue: _type,
                                    decoration: const InputDecoration(
                                      labelText: '添加类型',
                                    ),
                                    items: [
                                      for (final item
                                          in ReplicateAssetType.values)
                                        DropdownMenuItem(
                                          value: item,
                                          child: Text(item.label),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        setState(() => _type = value);
                                      }
                                    },
                                  ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              key: const ValueKey(
                                'asset-manager-upload-assets',
                              ),
                              onPressed: _isOpeningFilePicker
                                  ? null
                                  : _pickFiles,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: const Text('上传资产'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () => widget.onManualAdd(
                                context,
                                widget.libraryController,
                                _type,
                              ),
                              icon: const Icon(Icons.edit_note_rounded),
                              label: const Text('手动添加'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonalIcon(
                              key: const ValueKey(
                                'asset-manager-generate-from-description',
                              ),
                              onPressed:
                                  _isGeneratingAsset ||
                                      widget.replicateController.value.isBusy
                                  ? null
                                  : _generateAsset,
                              icon: const Icon(Icons.auto_awesome_rounded),
                              label: Text(
                                _isGeneratingAsset ? '生成中…' : '按描述生成',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (state.isBusy ||
                            _isOpeningFilePicker ||
                            _isGeneratingAsset ||
                            widget.replicateController.value.isBusy)
                          const LinearProgressIndicator(minHeight: 3),
                        Expanded(
                          child: state.items.isEmpty
                              ? const Center(child: Text('暂无资产'))
                              : GridView.builder(
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 260,
                                        mainAxisExtent: 250,
                                        crossAxisSpacing: 12,
                                        mainAxisSpacing: 12,
                                      ),
                                  itemCount: state.items.length,
                                  itemBuilder: (context, index) {
                                    final item = state.items[index];
                                    return _ManagedLibraryAssetCard(
                                      item: item,
                                      onUse: () => widget.replicateController
                                          .importLibraryAsset(item),
                                      onEdit: () => widget.onEdit(
                                        context,
                                        widget.libraryController,
                                        item,
                                      ),
                                      onDelete: () => widget.libraryController
                                          .deleteItem(item.id),
                                      onReplace: (details) =>
                                          _replaceDroppedFile(item, details),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                  if (_isDraggingOver)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.08),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2,
                            ),
                          ),
                          child: const Center(child: Text('松开添加到资产库')),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _LibraryImportRequest = ({
  String sourcePath,
  ReplicateAssetType type,
  String name,
  String description,
  List<String> aliases,
});

class _PendingLibraryAssetEditor {
  _PendingLibraryAssetEditor({required this.path, required this.type})
    : nameController = TextEditingController(
        text: p.basenameWithoutExtension(path),
      ),
      descriptionController = TextEditingController(),
      aliasesController = TextEditingController();

  final String path;
  ReplicateAssetType type;
  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final TextEditingController aliasesController;

  void dispose() {
    nameController.dispose();
    descriptionController.dispose();
    aliasesController.dispose();
  }
}

class _BatchLibraryAssetImportDialog extends StatefulWidget {
  const _BatchLibraryAssetImportDialog({
    required this.paths,
    required this.initialType,
  });

  final List<String> paths;
  final ReplicateAssetType initialType;

  @override
  State<_BatchLibraryAssetImportDialog> createState() =>
      _BatchLibraryAssetImportDialogState();
}

class _BatchLibraryAssetImportDialogState
    extends State<_BatchLibraryAssetImportDialog> {
  late final List<_PendingLibraryAssetEditor> _editors = [
    for (final path in widget.paths)
      _PendingLibraryAssetEditor(path: path, type: widget.initialType),
  ];

  @override
  void dispose() {
    for (final editor in _editors) {
      editor.dispose();
    }
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(<_LibraryImportRequest>[
      for (final editor in _editors)
        (
          sourcePath: editor.path,
          type: editor.type,
          name: editor.nameController.text.trim(),
          description: editor.descriptionController.text.trim(),
          aliases: _parseLibraryAliases(editor.aliasesController.text),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('batch-asset-import-dialog'),
      title: Row(
        children: [
          const Expanded(child: Text('编辑待入库资产')),
          Text(
            '${_editors.length} 项',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 620,
        child: ListView.separated(
          itemCount: _editors.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final editor = _editors[index];
            return Card(
              key: ValueKey('batch-asset-item-$index'),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 190,
                      child: _PendingLibraryAssetPreview(
                        path: editor.path,
                        type: editor.type,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      p.basename(editor.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<ReplicateAssetType>(
                            key: ValueKey('batch-asset-type-$index'),
                            initialValue: editor.type,
                            decoration: const InputDecoration(
                              labelText: '资产类型',
                            ),
                            items: [
                              for (final type in ReplicateAssetType.values)
                                DropdownMenuItem(
                                  value: type,
                                  child: Text(type.label),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => editor.type = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: ValueKey('batch-asset-name-$index'),
                            controller: editor.nameController,
                            decoration: const InputDecoration(
                              labelText: '资产名称',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: ValueKey('batch-asset-description-$index'),
                      controller: editor.descriptionController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '特征描述',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: ValueKey('batch-asset-aliases-$index'),
                      controller: editor.aliasesController,
                      decoration: const InputDecoration(
                        labelText: '匹配别名（用逗号分隔）',
                        helperText: '用于故事板名称自动绑定，不参与视觉识别',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const ValueKey('batch-asset-import-submit'),
          onPressed: _submit,
          icon: const Icon(Icons.inventory_2_outlined),
          label: const Text('入库'),
        ),
      ],
    );
  }
}

class _PendingLibraryAssetPreview extends StatelessWidget {
  const _PendingLibraryAssetPreview({required this.path, required this.type});

  final String path;
  final ReplicateAssetType type;

  @override
  Widget build(BuildContext context) {
    if (!type.isImageType) {
      return _AssetTypeIcon(type);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Image(
        image: previewFileImageProvider(
          path: path,
          logicalWidth: 700,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          maxCacheWidth: 1400,
        ),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _AssetTypeIcon(type),
      ),
    );
  }
}

List<String> _parseLibraryAliases(String value) => value
    .split(RegExp(r'[,，;；\n\r]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

class _ManagedLibraryAssetCard extends StatelessWidget {
  const _ManagedLibraryAssetCard({
    required this.item,
    required this.onUse,
    required this.onEdit,
    required this.onDelete,
    required this.onReplace,
  });

  final ShootingAssetLibraryItem item;
  final VoidCallback onUse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<DropDoneDetails> onReplace;

  @override
  Widget build(BuildContext context) {
    return _LibraryAssetReplaceDropTarget(
      onReplace: onReplace,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _LibraryAssetPreview(item)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '资产操作',
                        onSelected: (action) => switch (action) {
                          'use' => onUse(),
                          'edit' => onEdit(),
                          'delete' => onDelete(),
                          _ => null,
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'use', child: Text('用于当前脚本')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ],
                  ),
                  Text(item.type.label),
                  Text(
                    item.description.isEmpty
                        ? p.basename(item.path)
                        : item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryAssetReplaceDropTarget extends StatefulWidget {
  const _LibraryAssetReplaceDropTarget({
    required this.child,
    required this.onReplace,
  });

  final Widget child;
  final ValueChanged<DropDoneDetails> onReplace;

  @override
  State<_LibraryAssetReplaceDropTarget> createState() =>
      _LibraryAssetReplaceDropTargetState();
}

class _LibraryAssetReplaceDropTargetState
    extends State<_LibraryAssetReplaceDropTarget> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      enable: DesktopDropTargetScope.enabledOf(context),
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        widget.onReplace(details);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                border: Border.all(color: scheme.primary, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(child: Text('松开替换资产图')),
            ),
        ],
      ),
    );
  }
}

class _LibraryAssetPreview extends StatelessWidget {
  const _LibraryAssetPreview(this.item);

  final ShootingAssetLibraryItem item;

  @override
  Widget build(BuildContext context) {
    final isImage =
        SeedancePromptGenerationService.mediaKind(
          ReplicateAsset(
            id: item.id,
            runId: '',
            type: item.type,
            name: item.name,
            description: item.description,
            path: item.path,
            referenceNumber: 0,
            status: ProcessingStatus.completed,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
          ),
        ) ==
        ReplicateMediaKind.image;
    if (isImage && item.path.isNotEmpty) {
      return Image(
        image: previewFileImageProvider(
          path: item.path,
          logicalWidth: 256,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          maxCacheWidth: 512,
        ),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _AssetTypeIcon(item.type),
      );
    }
    return _AssetTypeIcon(item.type);
  }
}

class _AssetTypeIcon extends StatelessWidget {
  const _AssetTypeIcon(this.type);

  final ReplicateAssetType type;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(child: Icon(type.icon, size: 38)),
  );
}

class _ScriptWorkspace extends StatefulWidget {
  const _ScriptWorkspace({
    required this.state,
    required this.controller,
    required this.onBatchEdit,
    required this.onPickFrame,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final VoidCallback onBatchEdit;
  final ValueChanged<ScriptShot> onPickFrame;

  @override
  State<_ScriptWorkspace> createState() => _ScriptWorkspaceState();
}

class _ScriptWorkspaceState extends State<_ScriptWorkspace> {
  final _horizontalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '官方模板字段 · 拖动镜号左侧手柄可排序',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed: widget.controller.addShot,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('插入镜头'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: state.shots.isEmpty ? null : widget.onBatchEdit,
                  icon: const Icon(Icons.playlist_add_check_rounded),
                  label: const Text('批量设置'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _horizontalController,
              thumbVisibility: true,
              notificationPredicate: (notification) => notification.depth == 0,
              child: SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: _ScriptTableRow.totalWidth,
                  child: Column(
                    children: [
                      const _ScriptTableHeader(),
                      Expanded(
                        child: state.shots.isEmpty
                            ? const Center(child: Text('当前脚本暂无镜头'))
                            : ReorderableListView.builder(
                                buildDefaultDragHandles: false,
                                itemCount: state.shots.length,
                                onReorder: widget.controller.reorderShots,
                                itemBuilder: (context, index) {
                                  final shot = state.shots[index];
                                  return _ScriptTableRow(
                                    key: ValueKey(shot.id),
                                    index: index,
                                    shot: shot,
                                    selected: shot.id == state.selectedShotId,
                                    controller: widget.controller,
                                    onPickFrame: () => widget.onPickFrame(shot),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 190,
            child: state.selectedShot == null
                ? const Center(child: Text('选择一个镜头查看原图位置'))
                : _ShotInspector(
                    shot: state.selectedShot!,
                    controller: widget.controller,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ScriptTableHeader extends StatelessWidget {
  const _ScriptTableHeader();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const Row(
        children: [
          _HeaderCell('镜号', 76),
          _HeaderCell('画面', 150),
          _HeaderCell('内容', 220),
          _HeaderCell('景别', 100),
          _HeaderCell('运镜', 110),
          _HeaderCell('构图', 180),
          _HeaderCell('机位', 140),
          _HeaderCell('光影/氛围', 200),
          _HeaderCell('色彩', 160),
          _HeaderCell('视觉焦点', 200),
          _HeaderCell('衔接', 200),
          _HeaderCell('摄影备注', 200),
          _HeaderCell('基地场景', 140),
          _HeaderCell('款号', 110),
          _HeaderCell('图片', 150),
          _HeaderCell('产品搭配', 170),
          _HeaderCell('操作', 104),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label, this.width);

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 42,
    child: Center(
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

class _ScriptTableRow extends StatelessWidget {
  const _ScriptTableRow({
    super.key,
    required this.index,
    required this.shot,
    required this.selected,
    required this.controller,
    required this.onPickFrame,
  });

  static const totalWidth = 2610.0;

  final int index;
  final ScriptShot shot;
  final bool selected;
  final ShootingScriptController controller;
  final VoidCallback onPickFrame;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: InkWell(
        onTap: () => controller.selectShot(shot.id),
        child: SizedBox(
          height: 116,
          child: Row(
            children: [
              SizedBox(
                width: 76,
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.drag_indicator_rounded),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        shot.shotNumber.toString().padLeft(2, '0'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 150,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child:
                            shot.framePath.isNotEmpty &&
                                FileAvailabilityScope.of(
                                  context,
                                ).exists(shot.framePath, defaultValue: true)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image(
                                  image: previewFileImageProvider(
                                    path: shot.framePath,
                                    logicalWidth: 138,
                                    devicePixelRatio:
                                        MediaQuery.devicePixelRatioOf(context),
                                  ),
                                  fit: BoxFit.contain,
                                ),
                              )
                            : const Icon(Icons.image_not_supported_outlined),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: IconButton.filledTonal(
                          tooltip: '选择原图',
                          visualDensity: VisualDensity.compact,
                          onPressed: onPickFrame,
                          icon: const Icon(Icons.edit_rounded, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _editor(220, '内容', shot.content, (value) {
                controller.updateShot(shot.copyWith(content: value));
              }),
              _editor(100, '景别', shot.shotSize, (value) {
                controller.updateShot(shot.copyWith(shotSize: value));
              }),
              _editor(110, '运镜', shot.cameraMovement, (value) {
                controller.updateShot(shot.copyWith(cameraMovement: value));
              }),
              _editor(180, '构图', shot.composition, (value) {
                controller.updateShot(shot.copyWith(composition: value));
              }),
              _editor(140, '机位', shot.cameraAngle, (value) {
                controller.updateShot(shot.copyWith(cameraAngle: value));
              }),
              _editor(200, '光影/氛围', shot.lightingMood, (value) {
                controller.updateShot(shot.copyWith(lightingMood: value));
              }),
              _editor(160, '色彩', shot.colorPalette, (value) {
                controller.updateShot(shot.copyWith(colorPalette: value));
              }),
              _editor(200, '视觉焦点', shot.visualFocus, (value) {
                controller.updateShot(shot.copyWith(visualFocus: value));
              }),
              _editor(200, '衔接', shot.transitionHint, (value) {
                controller.updateShot(shot.copyWith(transitionHint: value));
              }),
              _editor(200, '摄影备注', shot.cameraNotes, (value) {
                controller.updateShot(shot.copyWith(cameraNotes: value));
              }),
              _editor(140, '基地场景', shot.scene, (value) {
                controller.updateShot(shot.copyWith(scene: value));
              }),
              _editor(110, '款号', shot.productCode, (value) {
                controller.updateShot(shot.copyWith(productCode: value));
              }),
              _editor(150, '图片', shot.visual, (value) {
                controller.updateShot(shot.copyWith(visual: value));
              }),
              _editor(170, '产品搭配', shot.productStyling, (value) {
                controller.updateShot(shot.copyWith(productStyling: value));
              }),
              SizedBox(
                width: 104,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '复制镜头',
                      onPressed: () => controller.duplicateShot(shot.id),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                    IconButton(
                      tooltip: '删除分镜脚本',
                      onPressed: () => controller.deleteShot(shot.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor(
    double width,
    String label,
    String value,
    ValueChanged<String> onSaved,
  ) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: _CommitTextField(
        key: ValueKey('${shot.id}-$label'),
        initialValue: value,
        label: label,
        onSaved: onSaved,
      ),
    ),
  );
}

class _ShotInspector extends StatelessWidget {
  const _ShotInspector({required this.shot, required this.controller});

  final ScriptShot shot;
  final ShootingScriptController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1080,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 210,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        shot.framePath.isEmpty
                            ? '原图：未设置'
                            : '原图：${shot.framePath}',
                        maxLines: 6,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: shot.framePath.isEmpty
                          ? null
                          : () => controller.openShotOriginal(shot),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('打开原图位置'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommitTextField extends StatefulWidget {
  const _CommitTextField({
    super.key,
    required this.initialValue,
    required this.label,
    required this.onSaved,
  });

  final String initialValue;
  final String label;
  final ValueChanged<String> onSaved;

  @override
  State<_CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<_CommitTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _lastSaved = widget.initialValue;
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _CommitTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.initialValue != _controller.text) {
      _controller.text = widget.initialValue;
      _lastSaved = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      _commit();
    }
  }

  void _commit() {
    final current = _controller.text;
    if (current == _lastSaved) {
      return;
    }
    _lastSaved = current;
    widget.onSaved(current);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      maxLines: null,
      minLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => _commit(),
    );
  }
}

class _LibraryAssetEditorResult {
  const _LibraryAssetEditorResult({
    required this.type,
    required this.name,
    required this.description,
    this.aliases = const [],
    required this.path,
  });

  final ReplicateAssetType type;
  final String name;
  final String description;
  final List<String> aliases;
  final String path;
}

extension on ShootingScriptStatus {
  String get label => switch (this) {
    ShootingScriptStatus.draft => '草稿',
    ShootingScriptStatus.active => '使用中',
    ShootingScriptStatus.archived => '已归档',
  };
}

extension on ReplicateAssetType {
  String get label => switch (this) {
    ReplicateAssetType.character => '角色',
    ReplicateAssetType.product => '产品',
    ReplicateAssetType.scene => '场景',
    ReplicateAssetType.prop => '道具',
    ReplicateAssetType.video => '视频',
    ReplicateAssetType.audio => '音频',
    ReplicateAssetType.reference => '综合参考',
    ReplicateAssetType.other => '其他',
  };

  IconData get icon => switch (this) {
    ReplicateAssetType.character => Icons.person_outline_rounded,
    ReplicateAssetType.product => Icons.inventory_2_outlined,
    ReplicateAssetType.scene => Icons.landscape_outlined,
    ReplicateAssetType.prop => Icons.chair_outlined,
    ReplicateAssetType.video => Icons.movie_outlined,
    ReplicateAssetType.audio => Icons.audio_file_outlined,
    ReplicateAssetType.reference => Icons.collections_outlined,
    ReplicateAssetType.other => Icons.attach_file_rounded,
  };

  bool get isImageType => switch (this) {
    ReplicateAssetType.character ||
    ReplicateAssetType.product ||
    ReplicateAssetType.scene ||
    ReplicateAssetType.prop ||
    ReplicateAssetType.reference ||
    ReplicateAssetType.other => true,
    ReplicateAssetType.video || ReplicateAssetType.audio => false,
  };
}
