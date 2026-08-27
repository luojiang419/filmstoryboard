import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../core/performance/performance_probe.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../../../core/widgets/desktop_drop_target_scope.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../../core/widgets/value_listenable_selector_builder.dart';
import '../../../core/widgets/viewport_lazy_grid.dart';
import '../application/grid_cut_controller.dart';
import '../domain/grid_cut_models.dart';

enum _CutLineAxis { vertical, horizontal }

enum _GridCutInspectorSection { metrics, layout, results }

const _canvasTopRulerHeight = 38.0;
const _canvasLeftRulerWidth = 58.0;
const _cropLineHitSlop = 14.0;

GridCutState _gridCutState(GridCutState state) => state;

bool _sameGridCutToolbarState(GridCutState previous, GridCutState next) {
  return previous.isBusy == next.isBusy && previous.message == next.message;
}

bool _sameGridCutSidebarState(GridCutState previous, GridCutState next) {
  if (previous.selectedImageId != next.selectedImageId ||
      previous.isBusy != next.isBusy ||
      previous.images.length != next.images.length ||
      previous.taskGroups.length != next.taskGroups.length ||
      !_sameStrings(previous.taskOrder, next.taskOrder)) {
    return false;
  }
  for (var index = 0; index < previous.images.length; index++) {
    final oldImage = previous.images[index];
    final newImage = next.images[index];
    if (oldImage.id != newImage.id ||
        oldImage.taskId != newImage.taskId ||
        oldImage.originalName != newImage.originalName ||
        oldImage.storedPath != newImage.storedPath ||
        oldImage.layout != newImage.layout) {
      return false;
    }
  }
  for (var index = 0; index < previous.taskGroups.length; index++) {
    final oldGroup = previous.taskGroups[index];
    final newGroup = next.taskGroups[index];
    if (oldGroup.id != newGroup.id ||
        oldGroup.name != newGroup.name ||
        oldGroup.expanded != newGroup.expanded ||
        !_sameStrings(oldGroup.imageIds, newGroup.imageIds)) {
      return false;
    }
  }
  return true;
}

bool _sameGridCutCanvasState(GridCutState previous, GridCutState next) {
  return identical(previous.selectedImage, next.selectedImage) &&
      previous.isDraggingOver == next.isDraggingOver;
}

bool _sameGridCutInspectorState(GridCutState previous, GridCutState next) {
  return identical(previous.selectedImage, next.selectedImage) &&
      identical(previous.images, next.images) &&
      previous.isBusy == next.isBusy;
}

bool _sameStrings(List<String> previous, List<String> next) {
  if (previous.length != next.length) {
    return false;
  }
  for (var index = 0; index < previous.length; index++) {
    if (previous[index] != next[index]) {
      return false;
    }
  }
  return true;
}

class GridCutPage extends ConsumerStatefulWidget {
  const GridCutPage({super.key});

  @override
  ConsumerState<GridCutPage> createState() => _GridCutPageState();
}

/// 可嵌入其它工作区的多宫格裁切画布。
///
/// 视频分析页使用它复用原裁切交互，不再打开独立的兼容工具窗口。
class GridCutCanvasPanel extends StatefulWidget {
  const GridCutCanvasPanel({super.key, required this.controller});

  final GridCutController controller;

  @override
  State<GridCutCanvasPanel> createState() => _GridCutCanvasPanelState();
}

class _GridCutCanvasPanelState extends State<GridCutCanvasPanel> {
  int? _anchorCellIndex;
  final _activeLineAxes = <_CutLineAxis>{};
  final _lineColor = const Color(0xFFFFD54F);
  final _lineStrokeWidth = 2.2;

  @override
  Widget build(BuildContext context) {
    return ValueListenableSelectorBuilder<GridCutState, GridCutState>(
      valueListenable: widget.controller,
      selector: _gridCutState,
      equals: _sameGridCutCanvasState,
      builder: (context, state, _) => _CanvasPanel(
        state: state,
        anchorCellIndex: _anchorCellIndex,
        activeLineAxes: _activeLineAxes,
        lineColor: _lineColor,
        lineStrokeWidth: _lineStrokeWidth,
        onAnchorChanged: (index) => setState(() => _anchorCellIndex = index),
        onSelectCell: widget.controller.toggleCell,
        onLayoutCommit: widget.controller.commitLayout,
        onToggleLineAxis: _toggleLineAxis,
        onVerticalRulerTap: widget.controller.insertVerticalLine,
        onHorizontalRulerTap: widget.controller.insertHorizontalLine,
      ),
    );
  }

  void _toggleLineAxis(_CutLineAxis axis) {
    setState(() {
      if (!_activeLineAxes.add(axis)) {
        _activeLineAxes.remove(axis);
      }
    });
  }
}

/// 可嵌入其它工作区的多宫格裁切参数检查器。
class GridCutInspectorPanel extends StatefulWidget {
  const GridCutInspectorPanel({
    super.key,
    required this.controller,
    this.onCollapse,
  });

  final GridCutController controller;
  final VoidCallback? onCollapse;

  @override
  State<GridCutInspectorPanel> createState() => _GridCutInspectorPanelState();
}

class _GridCutInspectorPanelState extends State<GridCutInspectorPanel> {
  final _expandedSections = <_GridCutInspectorSection>{
    _GridCutInspectorSection.metrics,
    _GridCutInspectorSection.layout,
    _GridCutInspectorSection.results,
  };
  Color _lineColor = const Color(0xFFFFD54F);
  double _lineStrokeWidth = 2.2;

  @override
  Widget build(BuildContext context) {
    return ValueListenableSelectorBuilder<GridCutState, GridCutState>(
      valueListenable: widget.controller,
      selector: _gridCutState,
      equals: _sameGridCutInspectorState,
      builder: (context, state, _) => _InspectorPanel(
        controller: widget.controller,
        state: state,
        expandedSections: _expandedSections,
        onToggleSection: _toggleSection,
        lineColor: _lineColor,
        lineStrokeWidth: _lineStrokeWidth,
        onLineColorChanged: (color) => setState(() => _lineColor = color),
        onLineStrokeWidthChanged: (width) =>
            setState(() => _lineStrokeWidth = width),
        onImport: widget.controller.pickImages,
        onCollapse: widget.onCollapse ?? () {},
      ),
    );
  }

  void _toggleSection(_GridCutInspectorSection section) {
    setState(() {
      if (!_expandedSections.add(section)) {
        _expandedSections.remove(section);
      }
    });
  }
}

class _GridCutPageState extends ConsumerState<GridCutPage> {
  static const _uiStateKey = 'gridCutPageUiState';
  static const _imageSidebarWidth = 240.0;
  static const _inspectorPanelWidth = 300.0;
  static const _collapsedPanelWidth = 44.0;

  int? _anchorCellIndex;
  final _activeLineAxes = <_CutLineAxis>{};
  final _expandedInspectorSections = <_GridCutInspectorSection>{};
  Color _lineColor = const Color(0xFFFFD54F);
  double _lineStrokeWidth = 2.2;
  bool _imageSidebarExpanded = true;
  bool _inspectorPanelExpanded = true;

  @override
  void initState() {
    super.initState();
    _restoreUiState();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('grid_cut.page');
    final controller = ref.watch(gridCutControllerProvider);
    final content = Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: DropTarget(
        enable: DesktopDropTargetScope.enabledOf(context),
        onDragEntered: (_) => controller.setDraggingOver(true),
        onDragExited: (_) => controller.setDraggingOver(false),
        onDragDone: (details) {
          controller
            ..setDraggingOver(false)
            ..importPaths(details.files.map((file) => file.path).toList());
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              ValueListenableSelectorBuilder<GridCutState, GridCutState>(
                valueListenable: controller,
                selector: _gridCutState,
                equals: _sameGridCutToolbarState,
                builder: (context, state, _) =>
                    _Toolbar(controller: controller, state: state),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CollapsiblePanelRegistration(
                      expanded: _imageSidebarExpanded,
                      onExpandedChanged: _setImageSidebarExpanded,
                      child: const SizedBox.shrink(),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: _imageSidebarExpanded
                          ? _imageSidebarWidth
                          : _collapsedPanelWidth,
                      child: _imageSidebarExpanded
                          ? ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: _imageSidebarWidth,
                                maxWidth: _imageSidebarWidth,
                                child:
                                    ValueListenableSelectorBuilder<
                                      GridCutState,
                                      GridCutState
                                    >(
                                      valueListenable: controller,
                                      selector: _gridCutState,
                                      equals: _sameGridCutSidebarState,
                                      builder: (context, state, _) =>
                                          _ImageSidebar(
                                            state: state,
                                            onSelect: controller.selectImage,
                                            onRemove: state.isBusy
                                                ? null
                                                : controller.removeImageTask,
                                            onClear:
                                                state.isBusy ||
                                                    state.images.isEmpty
                                                ? null
                                                : controller.clearImageTasks,
                                            onGroup: controller.groupImageTasks,
                                            onToggleGroupExpanded: controller
                                                .toggleTaskGroupExpanded,
                                            onMoveNode: controller.moveTaskNode,
                                            onCollapse: () =>
                                                _setImageSidebarExpanded(false),
                                          ),
                                    ),
                              ),
                            )
                          : _CollapsedGridCutRail(
                              tooltip: '展开图片任务',
                              label: '图片任务',
                              icon: Icons.photo_library_rounded,
                              arrowIcon:
                                  Icons.keyboard_double_arrow_right_rounded,
                              quarterTurns: 3,
                              onExpand: () => _setImageSidebarExpanded(true),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child:
                          ValueListenableSelectorBuilder<
                            GridCutState,
                            GridCutState
                          >(
                            valueListenable: controller,
                            selector: _gridCutState,
                            equals: _sameGridCutCanvasState,
                            builder: (context, state, _) => _CanvasPanel(
                              state: state,
                              anchorCellIndex: _anchorCellIndex,
                              activeLineAxes: _activeLineAxes,
                              lineColor: _lineColor,
                              lineStrokeWidth: _lineStrokeWidth,
                              onAnchorChanged: (index) =>
                                  _anchorCellIndex = index,
                              onSelectCell: controller.toggleCell,
                              onLayoutCommit: controller.commitLayout,
                              onToggleLineAxis: _toggleLineAxis,
                              onVerticalRulerTap: controller.insertVerticalLine,
                              onHorizontalRulerTap:
                                  controller.insertHorizontalLine,
                            ),
                          ),
                    ),
                    const SizedBox(width: 12),
                    CollapsiblePanelRegistration(
                      expanded: _inspectorPanelExpanded,
                      onExpandedChanged: _setInspectorPanelExpanded,
                      child: const SizedBox.shrink(),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: _inspectorPanelExpanded
                          ? _inspectorPanelWidth
                          : _collapsedPanelWidth,
                      child: _inspectorPanelExpanded
                          ? ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerRight,
                                minWidth: _inspectorPanelWidth,
                                maxWidth: _inspectorPanelWidth,
                                child:
                                    ValueListenableSelectorBuilder<
                                      GridCutState,
                                      GridCutState
                                    >(
                                      valueListenable: controller,
                                      selector: _gridCutState,
                                      equals: _sameGridCutInspectorState,
                                      builder: (context, state, _) =>
                                          _InspectorPanel(
                                            controller: controller,
                                            state: state,
                                            expandedSections:
                                                _expandedInspectorSections,
                                            onToggleSection:
                                                _toggleInspectorSection,
                                            lineColor: _lineColor,
                                            lineStrokeWidth: _lineStrokeWidth,
                                            onLineColorChanged: _setLineColor,
                                            onLineStrokeWidthChanged:
                                                _setLineStrokeWidth,
                                            onCollapse: () =>
                                                _setInspectorPanelExpanded(
                                                  false,
                                                ),
                                          ),
                                    ),
                              ),
                            )
                          : _CollapsedGridCutRail(
                              tooltip: '展开裁切参数',
                              label: '裁切参数',
                              icon: Icons.tune_rounded,
                              arrowIcon:
                                  Icons.keyboard_double_arrow_left_rounded,
                              quarterTurns: 1,
                              onExpand: () => _setInspectorPanelExpanded(true),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return CollapsiblePanelShortcutScope(child: content);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final taskNavigationDirection = _taskNavigationDirection(event.logicalKey);
    if (taskNavigationDirection != 0 && !_isTextInputFocused()) {
      final handled = ref
          .read(gridCutControllerProvider)
          .selectAdjacentImage(taskNavigationDirection);
      if (handled) {
        setState(() => _anchorCellIndex = null);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  int _taskNavigationDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      return -1;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      return 1;
    }
    return 0;
  }

  bool _isTextInputFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) {
      return false;
    }
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _toggleLineAxis(_CutLineAxis axis) {
    setState(() {
      if (!_activeLineAxes.remove(axis)) {
        _activeLineAxes.add(axis);
      }
    });
    _saveUiState();
  }

  void _setLineColor(Color color) {
    if (_lineColor == color) {
      return;
    }
    setState(() => _lineColor = color);
    _saveUiState();
  }

  void _setLineStrokeWidth(double width) {
    final nextWidth = width.clamp(1.0, 6.0).toDouble();
    if ((_lineStrokeWidth - nextWidth).abs() < 0.01) {
      return;
    }
    setState(() => _lineStrokeWidth = nextWidth);
    _saveUiState();
  }

  void _toggleInspectorSection(_GridCutInspectorSection section) {
    setState(() {
      if (!_expandedInspectorSections.remove(section)) {
        _expandedInspectorSections.add(section);
      }
    });
    _saveUiState();
  }

  void _setImageSidebarExpanded(bool expanded) {
    if (_imageSidebarExpanded == expanded) {
      return;
    }
    setState(() => _imageSidebarExpanded = expanded);
    _saveUiState();
  }

  void _setInspectorPanelExpanded(bool expanded) {
    if (_inspectorPanelExpanded == expanded) {
      return;
    }
    setState(() => _inspectorPanelExpanded = expanded);
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
      _activeLineAxes
        ..clear()
        ..addAll(
          _axesFromJson(
            decoded['activeLineAxes'],
            legacyValue: decoded['activeLineAxis'],
          ),
        );
      _lineColor = Color(
        _jsonInt(decoded['lineColor'], const Color(0xFFFFD54F).toARGB32()),
      );
      _lineStrokeWidth = _jsonDouble(
        decoded['lineStrokeWidth'],
        2.2,
      ).clamp(1.0, 6.0).toDouble();
      _expandedInspectorSections
        ..clear()
        ..addAll(_sectionSetFromJson(decoded['expandedInspectorSections']));
      _imageSidebarExpanded = _jsonBool(decoded['imageSidebarExpanded'], true);
      _inspectorPanelExpanded = _jsonBool(
        decoded['inspectorPanelExpanded'],
        true,
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
              'activeLineAxes':
                  _activeLineAxes.map((axis) => axis.name).toList()..sort(),
              'lineColor': _lineColor.toARGB32(),
              'lineStrokeWidth': _lineStrokeWidth,
              'expandedInspectorSections':
                  _expandedInspectorSections
                      .map((section) => section.name)
                      .toList()
                    ..sort(),
              'imageSidebarExpanded': _imageSidebarExpanded,
              'inspectorPanelExpanded': _inspectorPanelExpanded,
            }),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  Set<_CutLineAxis> _axesFromJson(Object? value, {Object? legacyValue}) {
    final names = <String>{};
    if (value is List) {
      names.addAll(value.map((item) => item?.toString() ?? ''));
    }
    final legacyName = legacyValue?.toString();
    if (legacyName != null && legacyName.isNotEmpty) {
      names.add(legacyName);
    }
    return {
      for (final axis in _CutLineAxis.values)
        if (names.contains(axis.name)) axis,
    };
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

  Set<_GridCutInspectorSection> _sectionSetFromJson(Object? value) {
    if (value is! List) {
      return const {};
    }
    final names = value.map((item) => item?.toString()).toSet();
    return {
      for (final section in _GridCutInspectorSection.values)
        if (names.contains(section.name)) section,
    };
  }
}

class _CollapsedGridCutRail extends StatelessWidget {
  const _CollapsedGridCutRail({
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.arrowIcon,
    required this.quarterTurns,
    required this.onExpand,
  });

  final String tooltip;
  final String label;
  final IconData icon;
  final IconData arrowIcon;
  final int quarterTurns;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
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
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 10),
              RotatedBox(
                quarterTurns: quarterTurns,
                child: Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Icon(arrowIcon, color: scheme.onSurfaceVariant, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.state});

  final GridCutController controller;
  final GridCutState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: state.isBusy ? null : controller.pickImages,
            icon: const Icon(Icons.add_photo_alternate_rounded),
            label: const Text('添加图片'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: state.isBusy ? null : controller.pasteImages,
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('粘贴图片'),
          ),
          const SizedBox(width: 14),
          if (state.isBusy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (state.isBusy) const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorActionBar extends StatelessWidget {
  const _InspectorActionBar({
    required this.controller,
    required this.state,
    this.onImport,
  });

  final GridCutController controller;
  final GridCutState state;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('grid-cut-inspector-actions'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onImport != null) ...[
            OutlinedButton.icon(
              key: const ValueKey('grid-cut-action-import'),
              onPressed: state.isBusy ? null : onImport,
              icon: const Icon(Icons.add_photo_alternate_rounded),
              label: const Text('导入图片'),
            ),
            const SizedBox(height: 10),
          ],
          OutlinedButton.icon(
            key: const ValueKey('grid-cut-action-export-all'),
            onPressed: state.isBusy || state.images.isEmpty
                ? null
                : controller.exportAllImages,
            icon: const Icon(Icons.auto_awesome_motion_rounded),
            label: const Text('批量自动裁切'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('grid-cut-action-export-selected'),
            onPressed: state.isBusy || state.selectedImage == null
                ? null
                : controller.exportSelectedImage,
            icon: const Icon(Icons.file_download_rounded),
            label: const Text('裁切多宫格图片'),
          ),
        ],
      ),
    );
  }
}

enum _ImageTaskContextAction { group, copy, openDirectory }

class _ImageSidebar extends StatefulWidget {
  const _ImageSidebar({
    required this.state,
    required this.onSelect,
    required this.onRemove,
    required this.onClear,
    required this.onGroup,
    required this.onToggleGroupExpanded,
    required this.onMoveNode,
    required this.onCollapse,
  });

  final GridCutState state;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onRemove;
  final VoidCallback? onClear;
  final void Function(String name, Iterable<String> imageIds) onGroup;
  final ValueChanged<String> onToggleGroupExpanded;
  final bool Function(
    String nodeKey, {
    String? targetGroupId,
    String? beforeNodeKey,
  })
  onMoveNode;
  final VoidCallback onCollapse;

  @override
  State<_ImageSidebar> createState() => _ImageSidebarState();
}

class _ImageSidebarState extends State<_ImageSidebar> {
  final _groupImageIds = <String>{};
  bool _groupModeEnabled = false;

  @override
  void didUpdateWidget(covariant _ImageSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validIds = widget.state.images.map((image) => image.id).toSet();
    _groupImageIds.removeWhere((id) => !validIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imagesById = {
      for (final image in widget.state.images) image.id: image,
    };
    final groupsById = {
      for (final group in widget.state.taskGroups) group.id: group,
    };
    final groupedIds = {
      for (final group in widget.state.taskGroups) ...group.imageIds,
    };
    final fallbackRootOrder = <String>[
      for (final group in widget.state.taskGroups)
        GridCutTaskNodeRef.group(group.id).key,
      for (final image in widget.state.images)
        if (!groupedIds.contains(image.id))
          GridCutTaskNodeRef.image(image.id).key,
    ];
    final rootOrder = widget.state.taskOrder.isEmpty
        ? fallbackRootOrder
        : widget.state.taskOrder;
    final sidebarItems = <Object>[];
    for (var rootIndex = 0; rootIndex < rootOrder.length; rootIndex++) {
      final node = GridCutTaskNodeRef.tryParse(rootOrder[rootIndex]);
      if (node == null) {
        continue;
      }
      final sequence = '${rootIndex + 1}';
      if (node.kind == GridCutTaskNodeKind.group) {
        final group = groupsById[node.id];
        if (group == null) {
          continue;
        }
        final childKeys = [
          for (final imageId in group.imageIds)
            if (imagesById.containsKey(imageId))
              GridCutTaskNodeRef.image(imageId).key,
        ];
        sidebarItems.add(
          _ImageTaskGroupHeaderItem(
            group: group,
            count: childKeys.length,
            sequence: sequence,
            siblingKeys: rootOrder,
          ),
        );
        if (group.expanded) {
          for (
            var childIndex = 0;
            childIndex < group.imageIds.length;
            childIndex++
          ) {
            final image = imagesById[group.imageIds[childIndex]];
            if (image != null) {
              sidebarItems.add(
                _ImageTaskItem(
                  image: image,
                  sequence: '$sequence.${childIndex + 1}',
                  parentGroupId: group.id,
                  siblingKeys: childKeys,
                ),
              );
            }
          }
        }
      } else {
        final image = imagesById[node.id];
        if (image != null) {
          sidebarItems.add(
            _ImageTaskItem(
              image: image,
              sequence: sequence,
              siblingKeys: rootOrder,
            ),
          );
        }
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '图片任务',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _TaskGroupModeToggle(
                  enabled: _groupModeEnabled,
                  onChanged: _setGroupModeEnabled,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '清空任务栏',
                  onPressed: widget.onClear,
                  icon: const Icon(Icons.clear_all_rounded, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
                IconButton(
                  tooltip: '收起图片任务',
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: widget.state.images.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        '将图片拖入操作区',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: sidebarItems.length,
                    itemBuilder: (context, index) {
                      final item = sidebarItems[index];
                      if (item is _ImageTaskGroupHeaderItem) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _TaskNodeDropTarget(
                            target: _TaskNodeDragData.group(item.group),
                            siblingKeys: item.siblingKeys,
                            onDrop: _moveDroppedTask,
                            child: _TaskNodeDraggable(
                              data: _TaskNodeDragData.group(item.group),
                              child: _ImageTaskGroupHeader(
                                group: item.group,
                                count: item.count,
                                sequence: item.sequence,
                                onTap: () =>
                                    widget.onToggleGroupExpanded(item.group.id),
                              ),
                            ),
                          ),
                        );
                      }
                      final taskItem = item as _ImageTaskItem;
                      final image = taskItem.image;
                      final selected =
                          image.id == widget.state.selectedImage?.id;
                      return _TaskNodeDropTarget(
                        target: _TaskNodeDragData.image(image),
                        parentGroupId: taskItem.parentGroupId,
                        siblingKeys: taskItem.siblingKeys,
                        onDrop: _moveDroppedTask,
                        child: _TaskNodeDraggable(
                          data: _TaskNodeDragData.image(image),
                          child: _ImageListTile(
                            image: image,
                            sequence: taskItem.sequence,
                            selected: selected,
                            groupModeEnabled: _groupModeEnabled,
                            groupChecked: _groupImageIds.contains(image.id),
                            onTap: () => _handleImageTap(image),
                            onGroupCheckedChanged: (checked) =>
                                _setGroupImageChecked(image.id, checked),
                            onSecondaryTapDown: (position) =>
                                _showImageContextMenu(position, image),
                            onRemove: widget.onRemove == null
                                ? null
                                : () => widget.onRemove!(image.id),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _handleImageTap(GridCutImage image) {
    widget.onSelect(image.id);
  }

  void _moveDroppedTask(
    _TaskNodeDragData data,
    _TaskNodeDragData target,
    String? targetParentGroupId,
    List<String> siblingKeys,
    _TaskDropPlacement placement,
  ) {
    if (data.nodeKey == target.nodeKey) {
      return;
    }
    if (placement == _TaskDropPlacement.inside) {
      widget.onMoveNode(data.nodeKey, targetGroupId: target.id);
      return;
    }
    String? beforeNodeKey;
    if (placement == _TaskDropPlacement.before) {
      beforeNodeKey = target.nodeKey;
    } else {
      final targetIndex = siblingKeys.indexOf(target.nodeKey);
      if (targetIndex >= 0 && targetIndex + 1 < siblingKeys.length) {
        beforeNodeKey = siblingKeys[targetIndex + 1];
      }
    }
    widget.onMoveNode(
      data.nodeKey,
      targetGroupId: targetParentGroupId,
      beforeNodeKey: beforeNodeKey,
    );
  }

  void _setGroupModeEnabled(bool enabled) {
    setState(() {
      _groupModeEnabled = enabled;
      if (!enabled) {
        _groupImageIds.clear();
      }
    });
  }

  void _setGroupImageChecked(String imageId, bool checked) {
    if (!_groupModeEnabled) {
      return;
    }
    setState(() {
      if (checked) {
        _groupImageIds.add(imageId);
      } else {
        _groupImageIds.remove(imageId);
      }
    });
  }

  void _showImageContextMenu(Offset position, GridCutImage image) {
    final groupIds = _groupModeEnabled && _groupImageIds.contains(image.id)
        ? {..._groupImageIds}
        : const <String>{};
    _showTaskContextMenu(
      position,
      groupImageIds: groupIds,
      imagePath: image.storedPath,
    );
  }

  Future<void> _showTaskContextMenu(
    Offset position, {
    Iterable<String> groupImageIds = const [],
    String? imagePath,
  }) async {
    final ids = groupImageIds.toSet();
    if (ids.isEmpty && imagePath == null) {
      return;
    }
    final action = await showMenu<_ImageTaskContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        if (ids.isNotEmpty)
          const PopupMenuItem(
            value: _ImageTaskContextAction.group,
            child: _TaskMenuItem(
              icon: Icons.drive_file_move_rounded,
              label: '编组',
            ),
          ),
        if (imagePath != null)
          const PopupMenuItem(
            value: _ImageTaskContextAction.copy,
            child: _TaskMenuItem(icon: Icons.copy_rounded, label: '复制'),
          ),
        if (imagePath != null)
          const PopupMenuItem(
            value: _ImageTaskContextAction.openDirectory,
            child: _TaskMenuItem(
              icon: Icons.folder_open_rounded,
              label: '打开目录',
            ),
          ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case _ImageTaskContextAction.group:
        final name = await _askGroupName();
        if (name == null || !mounted) {
          return;
        }
        widget.onGroup(name, ids);
        setState(() => _groupImageIds.clear());
        break;
      case _ImageTaskContextAction.copy:
        await _copyImageFile(imagePath!);
        break;
      case _ImageTaskContextAction.openDirectory:
        await _openImageDirectory(imagePath!);
        break;
    }
  }

  Future<String?> _askGroupName() {
    var name = '';
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('编组图片任务'),
          content: TextFormField(
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
              icon: const Icon(Icons.drive_file_move_rounded),
              label: const Text('编组'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copyImageFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      _showMessage('图片文件不存在');
      return;
    }
    final copied = await Pasteboard.writeFiles([file.path]);
    if (!mounted) {
      return;
    }
    if (copied) {
      _showMessage('已复制图片');
      return;
    }
    Pasteboard.writeText(file.path);
    _showMessage('已复制图片路径');
  }

  Future<void> _openImageDirectory(String path) async {
    final opened = await const FileExplorerService().revealFile(path);
    if (!mounted) {
      return;
    }
    if (!opened) {
      _showMessage('图片文件不存在');
    }
  }

  void _showMessage(String message) {
    // 操作结果不再通过底部横幅播报。
  }
}

class _ImageTaskGroupHeaderItem {
  const _ImageTaskGroupHeaderItem({
    required this.group,
    required this.count,
    required this.sequence,
    required this.siblingKeys,
  });

  final GridCutTaskGroup group;
  final int count;
  final String sequence;
  final List<String> siblingKeys;
}

class _ImageTaskItem {
  const _ImageTaskItem({
    required this.image,
    required this.sequence,
    this.parentGroupId,
    required this.siblingKeys,
  });

  final GridCutImage image;
  final String sequence;
  final String? parentGroupId;
  final List<String> siblingKeys;
}

enum _TaskDropPlacement { before, inside, after }

class _TaskNodeDragData {
  const _TaskNodeDragData({
    required this.kind,
    required this.id,
    required this.label,
  });

  factory _TaskNodeDragData.group(GridCutTaskGroup group) {
    return _TaskNodeDragData(
      kind: GridCutTaskNodeKind.group,
      id: group.id,
      label: group.name,
    );
  }

  factory _TaskNodeDragData.image(GridCutImage image) {
    return _TaskNodeDragData(
      kind: GridCutTaskNodeKind.image,
      id: image.id,
      label: image.originalName,
    );
  }

  final GridCutTaskNodeKind kind;
  final String id;
  final String label;

  String get nodeKey => GridCutTaskNodeRef(kind: kind, id: id).key;
}

class _TaskNodeDraggable extends StatelessWidget {
  const _TaskNodeDraggable({required this.data, required this.child});

  final _TaskNodeDragData data;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Draggable<_TaskNodeDragData>(
      key: ValueKey('task-node-draggable-${data.nodeKey}'),
      data: data,
      maxSimultaneousDrags: 1,
      rootOverlay: true,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TaskNodeDragFeedback(data: data),
      childWhenDragging: Opacity(opacity: 0.48, child: child),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }
}

class _TaskNodeDragFeedback extends StatelessWidget {
  const _TaskNodeDragFeedback({required this.data});

  final _TaskNodeDragData data;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
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
              data.kind == GridCutTaskNodeKind.group
                  ? Icons.folder_rounded
                  : Icons.image_rounded,
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
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

class _TaskNodeDropTarget extends StatefulWidget {
  const _TaskNodeDropTarget({
    required this.target,
    this.parentGroupId,
    required this.siblingKeys,
    required this.onDrop,
    required this.child,
  });

  final _TaskNodeDragData target;
  final String? parentGroupId;
  final List<String> siblingKeys;
  final void Function(
    _TaskNodeDragData data,
    _TaskNodeDragData target,
    String? targetParentGroupId,
    List<String> siblingKeys,
    _TaskDropPlacement placement,
  )
  onDrop;
  final Widget child;

  @override
  State<_TaskNodeDropTarget> createState() => _TaskNodeDropTargetState();
}

class _TaskNodeDropTargetState extends State<_TaskNodeDropTarget> {
  _TaskDropPlacement _placement = _TaskDropPlacement.before;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<_TaskNodeDragData>(
      key: ValueKey('task-node-drop-${widget.target.nodeKey}'),
      onWillAcceptWithDetails: (details) =>
          details.data.nodeKey != widget.target.nodeKey,
      onMove: (details) => _updatePlacement(details.data, details.offset),
      onLeave: (_) {
        if (mounted) {
          setState(() => _placement = _TaskDropPlacement.before);
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
                      border: _placement == _TaskDropPlacement.inside
                          ? Border.all(color: scheme.primary, width: 2)
                          : null,
                    ),
                  ),
                ),
              ),
            if (highlighted && _placement != _TaskDropPlacement.inside)
              Positioned(
                left: 2,
                right: 2,
                top: _placement == _TaskDropPlacement.before ? -2 : null,
                bottom: _placement == _TaskDropPlacement.after ? -2 : null,
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
    _TaskNodeDragData data,
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
        widget.target.kind == GridCutTaskNodeKind.group &&
            data.kind == GridCutTaskNodeKind.image &&
            ratio >= 0.25 &&
            ratio <= 0.75
        ? _TaskDropPlacement.inside
        : ratio < 0.5
        ? _TaskDropPlacement.before
        : _TaskDropPlacement.after;
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

class _TaskSequenceBadge extends StatelessWidget {
  const _TaskSequenceBadge({required this.sequence});

  final String sequence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '顺序 $sequence · 可拖拽排序',
      child: Container(
        key: ValueKey('task-sequence-$sequence'),
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

class _TaskGroupModeToggle extends StatelessWidget {
  const _TaskGroupModeToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? '关闭图片任务编组模式' : '开启图片任务编组模式',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!enabled),
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                key: const ValueKey('image-task-group-mode-toggle'),
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

class _ImageListTile extends StatelessWidget {
  const _ImageListTile({
    required this.image,
    required this.sequence,
    required this.selected,
    required this.groupModeEnabled,
    required this.groupChecked,
    required this.onTap,
    required this.onGroupCheckedChanged,
    required this.onSecondaryTapDown,
    required this.onRemove,
  });

  final GridCutImage image;
  final String sequence;
  final bool selected;
  final bool groupModeEnabled;
  final bool groupChecked;
  final VoidCallback onTap;
  final ValueChanged<bool> onGroupCheckedChanged;
  final ValueChanged<Offset> onSecondaryTapDown;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbnailProvider = previewFileImageProvider(
      path: image.storedPath,
      logicalWidth: 46,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 256,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: ValueKey('image-task-tile-${image.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        onSecondaryTapDown: (details) =>
            onSecondaryTapDown(details.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.78)
                : groupChecked
                ? scheme.secondaryContainer.withValues(alpha: 0.68)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.46)
                  : groupChecked
                  ? scheme.secondary.withValues(alpha: 0.8)
                  : Colors.transparent,
              width: groupChecked ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              _TaskSequenceBadge(sequence: sequence),
              const SizedBox(width: 7),
              if (groupModeEnabled) ...[
                Checkbox(
                  key: ValueKey('image-task-group-checkbox-${image.id}'),
                  value: groupChecked,
                  onChanged: (value) => onGroupCheckedChanged(value ?? false),
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
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image(
                  image: thumbnailProvider,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      image.originalName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? scheme.onPrimaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${image.layout.rows} x ${image.layout.columns} · ${image.selectedCells.length} 已选',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.72)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '移除任务',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline_rounded),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                style: IconButton.styleFrom(
                  foregroundColor: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageTaskGroupHeader extends StatelessWidget {
  const _ImageTaskGroupHeader({
    required this.group,
    required this.count,
    required this.sequence,
    required this.onTap,
  });

  final GridCutTaskGroup group;
  final int count;
  final String sequence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: group.expanded
              ? scheme.primaryContainer.withValues(alpha: 0.42)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: group.expanded
                ? scheme.primary.withValues(alpha: 0.45)
                : scheme.outlineVariant.withValues(alpha: 0.62),
          ),
        ),
        child: Row(
          children: [
            _TaskSequenceBadge(sequence: sequence),
            const SizedBox(width: 7),
            Icon(Icons.folder_rounded, color: scheme.onSurfaceVariant),
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
                    '$count 张图片任务',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
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
    );
  }
}

class _TaskMenuItem extends StatelessWidget {
  const _TaskMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
    );
  }
}

class _CanvasPanel extends StatelessWidget {
  const _CanvasPanel({
    required this.state,
    required this.anchorCellIndex,
    required this.activeLineAxes,
    required this.lineColor,
    required this.lineStrokeWidth,
    required this.onAnchorChanged,
    required this.onSelectCell,
    required this.onLayoutCommit,
    required this.onToggleLineAxis,
    required this.onVerticalRulerTap,
    required this.onHorizontalRulerTap,
  });

  final GridCutState state;
  final int? anchorCellIndex;
  final Set<_CutLineAxis> activeLineAxes;
  final Color lineColor;
  final double lineStrokeWidth;
  final ValueChanged<int> onAnchorChanged;
  final void Function(int index, {required bool selected, int? anchorIndex})
  onSelectCell;
  final ValueChanged<GridLayout> onLayoutCommit;
  final ValueChanged<_CutLineAxis> onToggleLineAxis;
  final ValueChanged<int> onVerticalRulerTap;
  final ValueChanged<int> onHorizontalRulerTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = state.selectedImage;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: state.isDraggingOver
              ? scheme.primary.withValues(alpha: 0.8)
              : scheme.outlineVariant.withValues(alpha: 0.48),
        ),
        boxShadow: state.isDraggingOver
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.2),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: image == null
          ? _DropHint(isDragging: state.isDraggingOver)
          : Padding(
              padding: const EdgeInsets.all(14),
              child: _ZoomableCropViewport(
                image: image,
                anchorCellIndex: anchorCellIndex,
                activeLineAxes: activeLineAxes,
                lineColor: lineColor,
                lineStrokeWidth: lineStrokeWidth,
                onAnchorChanged: onAnchorChanged,
                onSelectCell: onSelectCell,
                onLayoutCommit: onLayoutCommit,
                onToggleLineAxis: onToggleLineAxis,
                onVerticalRulerTap: onVerticalRulerTap,
                onHorizontalRulerTap: onHorizontalRulerTap,
              ),
            ),
    );
  }
}

class _ZoomableCropViewport extends StatefulWidget {
  const _ZoomableCropViewport({
    required this.image,
    required this.anchorCellIndex,
    required this.activeLineAxes,
    required this.lineColor,
    required this.lineStrokeWidth,
    required this.onAnchorChanged,
    required this.onSelectCell,
    required this.onLayoutCommit,
    required this.onToggleLineAxis,
    required this.onVerticalRulerTap,
    required this.onHorizontalRulerTap,
  });

  final GridCutImage image;
  final int? anchorCellIndex;
  final Set<_CutLineAxis> activeLineAxes;
  final Color lineColor;
  final double lineStrokeWidth;
  final ValueChanged<int> onAnchorChanged;
  final void Function(int index, {required bool selected, int? anchorIndex})
  onSelectCell;
  final ValueChanged<GridLayout> onLayoutCommit;
  final ValueChanged<_CutLineAxis> onToggleLineAxis;
  final ValueChanged<int> onVerticalRulerTap;
  final ValueChanged<int> onHorizontalRulerTap;

  @override
  State<_ZoomableCropViewport> createState() => _ZoomableCropViewportState();
}

class _ZoomableCropViewportState extends State<_ZoomableCropViewport> {
  static const _minZoom = 0.1;
  static const _maxZoom = 10.0;
  static const _panStartSlop = 3.0;
  static const _zoomPresets = [
    0.1,
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
    4.0,
    6.0,
    8.0,
    10.0,
  ];

  double _zoom = 1;
  Offset _panOffset = Offset.zero;
  int? _panPointer;
  Offset? _panStartPosition;
  Offset? _lastPanPosition;
  bool _isPanning = false;
  _RulerGuidePreview? _rulerGuidePreview;

  @override
  void didUpdateWidget(covariant _ZoomableCropViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id) {
      _resetView();
      _rulerGuidePreview = null;
      return;
    }
    final preview = _rulerGuidePreview;
    if (preview != null && !widget.activeLineAxes.contains(preview.axis)) {
      _rulerGuidePreview = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          math.max(1.0, constraints.maxWidth),
          math.max(1.0, constraints.maxHeight),
        );
        final canvasViewportOrigin = _canvasViewportOrigin();
        final canvasViewportSize = _canvasViewportSize(viewportSize);
        final scale = _scaleForZoom(viewportSize, _zoom);
        final imageSize = Size(
          widget.image.layout.imageWidth * scale,
          widget.image.layout.imageHeight * scale,
        );
        final canvasTopLeft = _canvasTopLeft(viewportSize, imageSize);

        return Listener(
          key: const ValueKey('grid-cut-canvas-viewport'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) => _handlePointerSignal(event, viewportSize),
          onPointerDown: (event) =>
              _handlePointerDown(event, canvasTopLeft, scale, imageSize),
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
                      width: imageSize.width,
                      height: imageSize.height,
                      child: _buildCanvas(scale: scale, imageSize: imageSize),
                    ),
                    if (_rulerGuidePreview != null)
                      Positioned.fill(
                        key: const ValueKey('grid-cut-ruler-guide-preview'),
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _RulerGuidePreviewPainter(
                              preview: _rulerGuidePreview!,
                              canvasTopLeft: canvasTopLeft,
                              imageSize: imageSize,
                              scale: scale,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ..._buildRulers(
                      scale: scale,
                      canvasViewportOrigin: canvasViewportOrigin,
                      canvasViewportSize: canvasViewportSize,
                      canvasTopLeft: canvasTopLeft,
                    ),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: KeyedSubtree(
                        key: const ValueKey('grid-cut-zoom-controls'),
                        child: _CanvasZoomControls(
                          zoom: _zoom,
                          presets: _zoomPresets,
                          onZoomOut: () =>
                              _zoomTo(_zoom / 1.25, viewportSize: viewportSize),
                          onZoomIn: () =>
                              _zoomTo(_zoom * 1.25, viewportSize: viewportSize),
                          onFit: () => setState(_resetView),
                          onPresetSelected: (zoom) =>
                              _zoomTo(zoom, viewportSize: viewportSize),
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

  Widget _buildCanvas({required double scale, required Size imageSize}) {
    return SizedBox(
      width: imageSize.width,
      height: imageSize.height,
      child: _CropCanvas(
        image: widget.image,
        scale: scale,
        defaultCursor: _isPanning
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        anchorCellIndex: widget.anchorCellIndex,
        onAnchorChanged: widget.onAnchorChanged,
        onSelectCell: widget.onSelectCell,
        onLayoutCommit: widget.onLayoutCommit,
        lineColor: widget.lineColor,
        lineStrokeWidth: widget.lineStrokeWidth,
      ),
    );
  }

  List<Widget> _buildRulers({
    required double scale,
    required Offset canvasViewportOrigin,
    required Size canvasViewportSize,
    required Offset canvasTopLeft,
  }) {
    final horizontalOffset = canvasTopLeft.dx - canvasViewportOrigin.dx;
    final verticalOffset = canvasTopLeft.dy - canvasViewportOrigin.dy;
    return [
      Positioned(
        left: 0,
        top: 0,
        width: _canvasLeftRulerWidth,
        height: _canvasTopRulerHeight,
        child: _RulerControls(
          activeLineAxes: widget.activeLineAxes,
          onToggleLineAxis: widget.onToggleLineAxis,
        ),
      ),
      Positioned(
        left: _canvasLeftRulerWidth,
        top: 0,
        width: canvasViewportSize.width,
        height: _canvasTopRulerHeight,
        child: _AxisRuler(
          axis: _CutLineAxis.vertical,
          imageLength: widget.image.layout.imageWidth,
          scale: scale,
          contentOffset: horizontalOffset,
          active: widget.activeLineAxes.contains(_CutLineAxis.vertical),
          onTap: widget.activeLineAxes.contains(_CutLineAxis.vertical)
              ? widget.onVerticalRulerTap
              : null,
          onHover: widget.activeLineAxes.contains(_CutLineAxis.vertical)
              ? (value) => _setRulerGuidePreview(_CutLineAxis.vertical, value)
              : null,
          onExit: () => _clearRulerGuidePreview(_CutLineAxis.vertical),
        ),
      ),
      Positioned(
        left: 0,
        top: _canvasTopRulerHeight,
        width: _canvasLeftRulerWidth,
        height: canvasViewportSize.height,
        child: _AxisRuler(
          axis: _CutLineAxis.horizontal,
          imageLength: widget.image.layout.imageHeight,
          scale: scale,
          contentOffset: verticalOffset,
          active: widget.activeLineAxes.contains(_CutLineAxis.horizontal),
          onTap: widget.activeLineAxes.contains(_CutLineAxis.horizontal)
              ? widget.onHorizontalRulerTap
              : null,
          onHover: widget.activeLineAxes.contains(_CutLineAxis.horizontal)
              ? (value) => _setRulerGuidePreview(_CutLineAxis.horizontal, value)
              : null,
          onExit: () => _clearRulerGuidePreview(_CutLineAxis.horizontal),
        ),
      ),
    ];
  }

  void _setRulerGuidePreview(_CutLineAxis axis, int imageValue) {
    final current = _rulerGuidePreview;
    if (current?.axis == axis && current?.imageValue == imageValue) {
      return;
    }
    setState(() {
      _rulerGuidePreview = _RulerGuidePreview(axis, imageValue);
    });
  }

  void _clearRulerGuidePreview(_CutLineAxis axis) {
    if (_rulerGuidePreview?.axis != axis) {
      return;
    }
    setState(() => _rulerGuidePreview = null);
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
    Size imageSize,
  ) {
    if (event.kind != PointerDeviceKind.mouse) {
      return;
    }
    final isMiddleButton = (event.buttons & kMiddleMouseButton) != 0;
    final isPrimaryButton = (event.buttons & kPrimaryMouseButton) != 0;
    if (!isMiddleButton && !isPrimaryButton) {
      return;
    }
    if (isPrimaryButton &&
        _isNearDraggableLine(
          event.localPosition,
          canvasTopLeft,
          scale,
          imageSize,
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
    final nextZoom = (_zoom * factor).clamp(_minZoom, _maxZoom).toDouble();
    if ((nextZoom - _zoom).abs() < 0.001) {
      return;
    }

    final oldImageSize = _imageSizeForZoom(viewportSize, _zoom);
    final nextImageSize = _imageSizeForZoom(viewportSize, nextZoom);
    final canvasViewportOrigin = _canvasViewportOrigin();
    final canvasViewportSize = _canvasViewportSize(viewportSize);
    final viewportCenter =
        canvasViewportOrigin +
        Offset(canvasViewportSize.width / 2, canvasViewportSize.height / 2);
    final focalFromCenter = focalPoint - viewportCenter;
    final oldVector = focalFromCenter - _panOffset;
    final widthRatio = nextImageSize.width / oldImageSize.width;
    final heightRatio = nextImageSize.height / oldImageSize.height;

    setState(() {
      _zoom = nextZoom;
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
  }

  void _zoomTo(double zoom, {required Size viewportSize}) {
    final nextZoom = zoom.clamp(_minZoom, _maxZoom).toDouble();
    if ((nextZoom - _zoom).abs() < 0.001) {
      return;
    }
    final canvasViewportOrigin = _canvasViewportOrigin();
    final canvasViewportSize = _canvasViewportSize(viewportSize);
    _zoomBy(
      nextZoom / _zoom,
      focalPoint:
          canvasViewportOrigin +
          Offset(canvasViewportSize.width / 2, canvasViewportSize.height / 2),
      viewportSize: viewportSize,
    );
  }

  bool _isNearDraggableLine(
    Offset viewportPosition,
    Offset canvasTopLeft,
    double scale,
    Size imageSize,
  ) {
    final canvasPosition = viewportPosition - canvasTopLeft;
    final layout = widget.image.layout;
    if (canvasPosition.dx < 0 ||
        canvasPosition.dy < 0 ||
        canvasPosition.dx > imageSize.width ||
        canvasPosition.dy > imageSize.height) {
      return false;
    }

    for (var i = 1; i < layout.xLines.length - 1; i++) {
      final distance = (canvasPosition.dx - layout.xLines[i] * scale).abs();
      if (distance <= _cropLineHitSlop) {
        return true;
      }
    }
    for (var i = 1; i < layout.yLines.length - 1; i++) {
      final distance = (canvasPosition.dy - layout.yLines[i] * scale).abs();
      if (distance <= _cropLineHitSlop) {
        return true;
      }
    }
    return false;
  }

  double _scaleForZoom(Size viewportSize, double zoom) {
    final canvasViewportSize = _canvasViewportSize(viewportSize);
    final fitScale = math.min(
      canvasViewportSize.width / widget.image.layout.imageWidth,
      canvasViewportSize.height / widget.image.layout.imageHeight,
    );
    return fitScale * zoom;
  }

  Size _imageSizeForZoom(Size viewportSize, double zoom) {
    final scale = _scaleForZoom(viewportSize, zoom);
    return Size(
      widget.image.layout.imageWidth * scale,
      widget.image.layout.imageHeight * scale,
    );
  }

  Offset _canvasTopLeft(Size viewportSize, Size imageSize) {
    final canvasViewportOrigin = _canvasViewportOrigin();
    final canvasViewportSize = _canvasViewportSize(viewportSize);
    return canvasViewportOrigin +
        Offset(
          (canvasViewportSize.width - imageSize.width) / 2,
          (canvasViewportSize.height - imageSize.height) / 2,
        ) +
        _panOffset;
  }

  Offset _canvasViewportOrigin() {
    return const Offset(_canvasLeftRulerWidth, _canvasTopRulerHeight);
  }

  Size _canvasViewportSize(Size viewportSize) {
    final origin = _canvasViewportOrigin();
    return Size(
      math.max(1.0, viewportSize.width - origin.dx),
      math.max(1.0, viewportSize.height - origin.dy),
    );
  }

  void _resetView() {
    _zoom = 1;
    _panOffset = Offset.zero;
    _panPointer = null;
    _panStartPosition = null;
    _lastPanPosition = null;
    _isPanning = false;
  }
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
              child: SizedBox(
                width: 58,
                height: 32,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
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

class _RulerControls extends StatelessWidget {
  const _RulerControls({
    required this.activeLineAxes,
    required this.onToggleLineAxis,
  });

  final Set<_CutLineAxis> activeLineAxes;
  final ValueChanged<_CutLineAxis> onToggleLineAxis;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _LineModeButton(
          active: activeLineAxes.contains(_CutLineAxis.vertical),
          tooltip: '添加竖向裁切线',
          icon: Icons.vertical_align_center_rounded,
          onPressed: () => onToggleLineAxis(_CutLineAxis.vertical),
        ),
        const SizedBox(width: 2),
        _LineModeButton(
          active: activeLineAxes.contains(_CutLineAxis.horizontal),
          tooltip: '添加横向裁切线',
          icon: Icons.horizontal_rule_rounded,
          onPressed: () => onToggleLineAxis(_CutLineAxis.horizontal),
        ),
      ],
    );
  }
}

class _LineModeButton extends StatelessWidget {
  const _LineModeButton({
    required this.active,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final bool active;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: active ? '退出$tooltip' : tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: 17,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        style: IconButton.styleFrom(
          foregroundColor: active ? scheme.onPrimaryContainer : scheme.primary,
          backgroundColor: active
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _AxisRuler extends StatelessWidget {
  const _AxisRuler({
    required this.axis,
    required this.imageLength,
    required this.scale,
    required this.contentOffset,
    required this.active,
    required this.onTap,
    required this.onHover,
    required this.onExit,
  });

  final _CutLineAxis axis;
  final int imageLength;
  final double scale;
  final double contentOffset;
  final bool active;
  final ValueChanged<int>? onTap;
  final ValueChanged<int>? onHover;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      key: ValueKey('grid-cut-ruler-${axis.name}'),
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.precise,
      onHover: onHover == null
          ? null
          : (event) => onHover!(_imageValueAt(event.localPosition)),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null
            ? null
            : (details) => onTap!(_imageValueAt(details.localPosition)),
        child: CustomPaint(
          painter: _AxisRulerPainter(
            axis: axis,
            imageLength: imageLength,
            scale: scale,
            contentOffset: contentOffset,
            active: active,
            color: scheme.primary,
            borderColor: scheme.outlineVariant,
            textColor: scheme.onSurfaceVariant,
            backgroundColor: scheme.surfaceContainerHighest.withValues(
              alpha: 0.76,
            ),
          ),
        ),
      ),
    );
  }

  int _imageValueAt(Offset localPosition) {
    final rawValue = axis == _CutLineAxis.vertical
        ? (localPosition.dx - contentOffset) / scale
        : (localPosition.dy - contentOffset) / scale;
    return rawValue.round().clamp(0, imageLength).toInt();
  }
}

class _RulerGuidePreview {
  const _RulerGuidePreview(this.axis, this.imageValue);

  final _CutLineAxis axis;
  final int imageValue;
}

class _RulerGuidePreviewPainter extends CustomPainter {
  const _RulerGuidePreviewPainter({
    required this.preview,
    required this.canvasTopLeft,
    required this.imageSize,
    required this.scale,
    required this.color,
  });

  final _RulerGuidePreview preview;
  final Offset canvasTopLeft;
  final Size imageSize;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = canvasTopLeft & imageSize;
    final visibleImageRect = imageRect.intersect(Offset.zero & size);
    if (visibleImageRect.isEmpty) {
      return;
    }
    final paint = Paint()
      ..color = color.withValues(alpha: 0.92)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final glowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.46)
      ..strokeWidth = 3.6
      ..style = PaintingStyle.stroke;

    canvas.save();
    canvas.clipRect(visibleImageRect);
    if (preview.axis == _CutLineAxis.vertical) {
      final x = canvasTopLeft.dx + preview.imageValue * scale;
      final start = Offset(x, imageRect.top);
      final end = Offset(x, imageRect.bottom);
      canvas.drawLine(start, end, glowPaint);
      canvas.drawLine(start, end, paint);
    } else {
      final y = canvasTopLeft.dy + preview.imageValue * scale;
      final start = Offset(imageRect.left, y);
      final end = Offset(imageRect.right, y);
      canvas.drawLine(start, end, glowPaint);
      canvas.drawLine(start, end, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RulerGuidePreviewPainter oldDelegate) {
    return oldDelegate.preview.axis != preview.axis ||
        oldDelegate.preview.imageValue != preview.imageValue ||
        oldDelegate.canvasTopLeft != canvasTopLeft ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.scale != scale ||
        oldDelegate.color != color;
  }
}

class _AxisRulerPainter extends CustomPainter {
  const _AxisRulerPainter({
    required this.axis,
    required this.imageLength,
    required this.scale,
    required this.contentOffset,
    required this.active,
    required this.color,
    required this.borderColor,
    required this.textColor,
    required this.backgroundColor,
  });

  final _CutLineAxis axis;
  final int imageLength;
  final double scale;
  final double contentOffset;
  final bool active;
  final Color color;
  final Color borderColor;
  final Color textColor;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = backgroundColor);
    canvas.drawRect(
      rect,
      Paint()
        ..color = active ? color.withValues(alpha: 0.72) : borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.4 : 1,
    );

    final isHorizontal = axis == _CutLineAxis.vertical;
    final axisLength = isHorizontal ? size.width : size.height;
    final majorStep = _majorTickStep(scale);
    final minorStep = math.max(1, majorStep ~/ 5);
    final longTick = isHorizontal ? size.height : size.width;
    final tickPaint = Paint()
      ..color = active ? color : borderColor
      ..strokeWidth = 1;
    final visibleStart = ((-contentOffset) / scale)
        .floor()
        .clamp(0, imageLength)
        .toInt();
    final visibleEnd = ((axisLength - contentOffset) / scale)
        .ceil()
        .clamp(0, imageLength)
        .toInt();
    final firstTick = (visibleStart ~/ minorStep) * minorStep;

    for (var value = firstTick; value <= visibleEnd; value += minorStep) {
      final position = value * scale + contentOffset;
      if (position < -1 || position > axisLength + 1) {
        continue;
      }
      final isMajor = value % majorStep == 0;
      final tickLength = isMajor ? longTick * 0.64 : longTick * 0.34;
      if (isHorizontal) {
        canvas.drawLine(
          Offset(position, size.height),
          Offset(position, size.height - tickLength),
          tickPaint,
        );
      } else {
        canvas.drawLine(
          Offset(size.width, position),
          Offset(size.width - tickLength, position),
          tickPaint,
        );
      }
      if (isMajor) {
        _paintLabel(canvas, '$value', position, size, isHorizontal);
      }
    }
  }

  void _paintLabel(
    Canvas canvas,
    String label,
    double position,
    Size size,
    bool isHorizontal,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = isHorizontal
        ? Offset(
            (position + 3).clamp(2, size.width - painter.width - 2).toDouble(),
            4,
          )
        : Offset(
            4,
            (position + 2)
                .clamp(2, size.height - painter.height - 2)
                .toDouble(),
          );
    painter.paint(canvas, offset);
  }

  int _majorTickStep(double scale) {
    final rough = math.max(1, (80 / scale).ceil());
    final magnitude = math.pow(10, rough.toString().length - 1).toInt();
    for (final base in const [1, 2, 5, 10]) {
      final step = base * magnitude;
      if (step >= rough) {
        return step;
      }
    }
    return magnitude * 10;
  }

  @override
  bool shouldRepaint(covariant _AxisRulerPainter oldDelegate) {
    return oldDelegate.axis != axis ||
        oldDelegate.imageLength != imageLength ||
        oldDelegate.scale != scale ||
        oldDelegate.contentOffset != contentOffset ||
        oldDelegate.active != active ||
        oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

class _DropHint extends StatelessWidget {
  const _DropHint({required this.isDragging});

  final bool isDragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedScale(
        scale: isDragging ? 1.03 : 1,
        duration: const Duration(milliseconds: 180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_photo_alternate_rounded,
              size: 54,
              color: scheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '拖拽图片到这里',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '也可以使用顶部按钮手动添加或粘贴剪贴板图片',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropCanvas extends StatefulWidget {
  const _CropCanvas({
    required this.image,
    required this.scale,
    required this.defaultCursor,
    required this.anchorCellIndex,
    required this.onAnchorChanged,
    required this.onSelectCell,
    required this.onLayoutCommit,
    required this.lineColor,
    required this.lineStrokeWidth,
  });

  final GridCutImage image;
  final double scale;
  final MouseCursor defaultCursor;
  final int? anchorCellIndex;
  final ValueChanged<int> onAnchorChanged;
  final void Function(int index, {required bool selected, int? anchorIndex})
  onSelectCell;
  final ValueChanged<GridLayout> onLayoutCommit;
  final Color lineColor;
  final double lineStrokeWidth;

  @override
  State<_CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<_CropCanvas> {
  _LineDragTarget? _hoverTarget;
  _LineDragTarget? _pendingDragTarget;
  _LineDragTarget? _dragTarget;
  GridLayout? _previewLayout;
  bool _pointerCancelled = false;

  GridLayout get _effectiveLayout => _previewLayout ?? widget.image.layout;

  @override
  void didUpdateWidget(covariant _CropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id) {
      _previewLayout = null;
      _pendingDragTarget = null;
      _dragTarget = null;
      _hoverTarget = null;
      return;
    }
    final preview = _previewLayout;
    if (preview != null && identical(widget.image.layout, preview)) {
      _previewLayout = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = _effectiveLayout;
    final imageProvider = previewFileImageProvider(
      path: widget.image.storedPath,
      logicalWidth: layout.imageWidth * widget.scale,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 2048,
    );
    return MouseRegion(
      cursor: _lineCursor(_dragTarget ?? _hoverTarget),
      onHover: (event) =>
          _setHoverTarget(_nearestDraggableLine(event.localPosition)),
      onExit: (_) => _setHoverTarget(null),
      child: GestureDetector(
        key: const ValueKey('grid-cut-crop-canvas'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) =>
            _selectCellAt(details.localPosition, selected: true),
        onSecondaryTapUp: (details) =>
            _handleSecondaryTap(details.localPosition),
        onPanDown: (details) {
          _pendingDragTarget = _nearestDraggableLine(details.localPosition);
        },
        onPanStart: (details) {
          final target =
              _pendingDragTarget ??
              _nearestDraggableLine(details.localPosition);
          if (target == null) {
            return;
          }
          setState(() => _dragTarget = target);
          _dragLineTo(target, details.localPosition);
        },
        onPanUpdate: (details) {
          final target = _dragTarget;
          if (target == null) {
            return;
          }
          _dragLineTo(target, details.localPosition);
        },
        onPanEnd: (_) {
          if (_pointerCancelled) {
            _pointerCancelled = false;
            _cancelLineDrag();
            return;
          }
          _finishLineDrag();
        },
        onPanCancel: () {
          _pointerCancelled = false;
          _cancelLineDrag();
        },
        child: Listener(
          onPointerDown: (_) => _pointerCancelled = false,
          onPointerCancel: (_) => _pointerCancelled = true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
              for (final cell in layout.cells())
                _CellHitRegion(
                  cell: cell,
                  scale: widget.scale,
                  selected: widget.image.selectedCells.contains(cell.index),
                ),
              CustomPaint(
                painter: _GridLinePainter(
                  layout: layout,
                  scale: widget.scale,
                  color: widget.lineColor,
                  strokeWidth: widget.lineStrokeWidth,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _setHoverTarget(_LineDragTarget? target) {
    if (_sameLineTarget(_hoverTarget, target)) {
      return;
    }
    setState(() => _hoverTarget = target);
  }

  void _finishLineDrag() {
    _pendingDragTarget = null;
    if (_dragTarget == null) {
      return;
    }
    setState(() => _dragTarget = null);
    final preview = _previewLayout;
    if (preview != null) {
      widget.onLayoutCommit(preview);
    }
  }

  void _cancelLineDrag() {
    _pendingDragTarget = null;
    if (_dragTarget == null && _previewLayout == null) {
      return;
    }
    setState(() {
      _dragTarget = null;
      _previewLayout = null;
    });
  }

  void _dragLineTo(_LineDragTarget target, Offset localPosition) {
    final layout = _effectiveLayout;
    if (target.axis == _CutLineAxis.vertical) {
      final imageX = (localPosition.dx / widget.scale)
          .round()
          .clamp(0, layout.imageWidth)
          .toInt();
      final result = layout.moveVerticalLineWithIndex(target.lineIndex, imageX);
      _applyLinePreview(target, result);
      return;
    }
    final imageY = (localPosition.dy / widget.scale)
        .round()
        .clamp(0, layout.imageHeight)
        .toInt();
    final result = layout.moveHorizontalLineWithIndex(target.lineIndex, imageY);
    _applyLinePreview(target, result);
  }

  void _applyLinePreview(_LineDragTarget target, GridLineMoveResult result) {
    final layoutChanged = !identical(result.layout, _effectiveLayout);
    final targetChanged = target.lineIndex != result.lineIndex;
    if (!layoutChanged && !targetChanged) {
      return;
    }
    setState(() {
      if (layoutChanged) {
        _previewLayout = result.layout;
      }
      if (targetChanged) {
        _dragTarget = _LineDragTarget(target.axis, result.lineIndex);
      }
    });
  }

  void _selectCellAt(Offset localPosition, {required bool selected}) {
    final cell = _cellAt(localPosition);
    if (cell == null) {
      return;
    }
    final shift = HardwareKeyboard.instance.logicalKeysPressed.any(
      (key) =>
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight,
    );
    widget.onSelectCell(
      cell.index,
      selected: selected,
      anchorIndex: shift ? widget.anchorCellIndex : null,
    );
    widget.onAnchorChanged(cell.index);
  }

  void _handleSecondaryTap(Offset localPosition) {
    final target = _nearestDraggableLine(localPosition);
    if (target == null) {
      _selectCellAt(localPosition, selected: false);
      return;
    }
    final layout = _effectiveLayout;
    final next = target.axis == _CutLineAxis.vertical
        ? layout.removeVerticalLine(target.lineIndex)
        : layout.removeHorizontalLine(target.lineIndex);
    if (identical(next, layout)) {
      return;
    }
    setState(() {
      _previewLayout = null;
      _pendingDragTarget = null;
      _dragTarget = null;
      _hoverTarget = null;
    });
    widget.onLayoutCommit(next);
  }

  GridCell? _cellAt(Offset localPosition) {
    final layout = _effectiveLayout;
    final imageX = localPosition.dx / widget.scale;
    final imageY = localPosition.dy / widget.scale;
    if (imageX < 0 ||
        imageY < 0 ||
        imageX > layout.imageWidth ||
        imageY > layout.imageHeight) {
      return null;
    }
    for (final cell in layout.cells()) {
      final right = cell.x + cell.width;
      final bottom = cell.y + cell.height;
      final isLastColumn = cell.column == layout.columns - 1;
      final isLastRow = cell.row == layout.rows - 1;
      final insideX =
          imageX >= cell.x &&
          (imageX < right || (isLastColumn && imageX <= right));
      final insideY =
          imageY >= cell.y &&
          (imageY < bottom || (isLastRow && imageY <= bottom));
      if (insideX && insideY) {
        return cell;
      }
    }
    return null;
  }

  _LineDragTarget? _nearestDraggableLine(Offset localPosition) {
    final layout = _effectiveLayout;
    _LineDragTarget? nearest;
    var nearestDistance = _cropLineHitSlop;

    for (var i = 1; i < layout.xLines.length - 1; i++) {
      final distance = (localPosition.dx - layout.xLines[i] * widget.scale)
          .abs();
      if (distance <= nearestDistance) {
        nearestDistance = distance;
        nearest = _LineDragTarget(_CutLineAxis.vertical, i);
      }
    }
    for (var i = 1; i < layout.yLines.length - 1; i++) {
      final distance = (localPosition.dy - layout.yLines[i] * widget.scale)
          .abs();
      if (distance <= nearestDistance) {
        nearestDistance = distance;
        nearest = _LineDragTarget(_CutLineAxis.horizontal, i);
      }
    }
    return nearest;
  }

  MouseCursor _lineCursor(_LineDragTarget? target) {
    if (target == null) {
      return widget.defaultCursor;
    }
    return target.axis == _CutLineAxis.vertical
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow;
  }

  bool _sameLineTarget(_LineDragTarget? a, _LineDragTarget? b) {
    return a?.axis == b?.axis && a?.lineIndex == b?.lineIndex;
  }
}

class _LineDragTarget {
  const _LineDragTarget(this.axis, this.lineIndex);

  final _CutLineAxis axis;
  final int lineIndex;
}

class _CellHitRegion extends StatelessWidget {
  const _CellHitRegion({
    required this.cell,
    required this.scale,
    required this.selected,
  });

  final GridCell cell;
  final double scale;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = cell.width * scale;
    final height = cell.height * scale;
    return Positioned(
      left: cell.x * scale,
      top: cell.y * scale,
      width: width,
      height: height,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.58)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

class _GridLinePainter extends CustomPainter {
  const _GridLinePainter({
    required this.layout,
    required this.scale,
    required this.color,
    required this.strokeWidth,
  });

  final GridLayout layout;
  final double scale;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = strokeWidth;
    for (final x in layout.xLines) {
      final dx = x * scale;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
    }
    for (final y in layout.yLines) {
      final dy = y * scale;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridLinePainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.scale != scale ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({
    required this.controller,
    required this.state,
    required this.expandedSections,
    required this.onToggleSection,
    required this.lineColor,
    required this.lineStrokeWidth,
    required this.onLineColorChanged,
    required this.onLineStrokeWidthChanged,
    this.onImport,
    required this.onCollapse,
  });

  final GridCutController controller;
  final GridCutState state;
  final Set<_GridCutInspectorSection> expandedSections;
  final ValueChanged<_GridCutInspectorSection> onToggleSection;
  final Color lineColor;
  final double lineStrokeWidth;
  final ValueChanged<Color> onLineColorChanged;
  final ValueChanged<double> onLineStrokeWidthChanged;
  final VoidCallback? onImport;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final image = state.selectedImage;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('grid-cut-inspector-panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '裁切参数',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '收起裁切参数',
                onPressed: onCollapse,
                icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: image == null
                ? Center(
                    child: Text(
                      '导入图片后可调整参数',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView(
                    key: const ValueKey('grid-cut-inspector-scroll'),
                    children: [
                      _GridCutCollapsibleSection(
                        title: '识别信息',
                        icon: Icons.analytics_rounded,
                        expanded: expandedSections.contains(
                          _GridCutInspectorSection.metrics,
                        ),
                        onToggle: () =>
                            onToggleSection(_GridCutInspectorSection.metrics),
                        child: Column(
                          children: [
                            _MetricLine(
                              label: '识别布局',
                              value:
                                  '${image.layout.rows} x ${image.layout.columns}',
                            ),
                            _MetricLine(
                              label: '置信度',
                              value: image.layout.usedFallback
                                  ? '回退等分'
                                  : '${(image.layout.confidence * 100).round()}%',
                            ),
                            _MetricLine(
                              label: '已选宫格',
                              value:
                                  '${image.selectedCells.length} / ${image.layout.cellCount}',
                            ),
                          ],
                        ),
                      ),
                      _GridCutCollapsibleSection(
                        title: '宫格布局',
                        icon: Icons.grid_view_rounded,
                        expanded: expandedSections.contains(
                          _GridCutInspectorSection.layout,
                        ),
                        onToggle: () =>
                            onToggleSection(_GridCutInspectorSection.layout),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _PresetButton(
                                  label: '2x2',
                                  onTap: () => controller.setEvenGrid(2, 2),
                                ),
                                _PresetButton(
                                  label: '3x3',
                                  onTap: () => controller.setEvenGrid(3, 3),
                                ),
                                _PresetButton(
                                  label: '4x3',
                                  onTap: () => controller.setEvenGrid(4, 3),
                                ),
                                _PresetButton(
                                  label: '5x4',
                                  onTap: () => controller.setEvenGrid(5, 4),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: image.selectedCells.isEmpty
                                  ? null
                                  : controller.clearCellSelection,
                              icon: const Icon(Icons.deselect_rounded),
                              label: const Text('清空'),
                            ),
                            const SizedBox(height: 12),
                            _LineStyleControls(
                              color: lineColor,
                              strokeWidth: lineStrokeWidth,
                              onColorChanged: onLineColorChanged,
                              onStrokeWidthChanged: onLineStrokeWidthChanged,
                            ),
                          ],
                        ),
                      ),
                      _GridCutCollapsibleSection(
                        title: '裁切结果',
                        icon: Icons.image_search_rounded,
                        expanded: expandedSections.contains(
                          _GridCutInspectorSection.results,
                        ),
                        onToggle: () =>
                            onToggleSection(_GridCutInspectorSection.results),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              onPressed: controller.openExportFolder,
                              icon: const Icon(Icons.folder_open_rounded),
                              label: const Text('打开导出文件夹'),
                            ),
                            const SizedBox(height: 10),
                            if (image.exportedPaths.isEmpty)
                              SizedBox(
                                height: 80,
                                child: Center(
                                  child: Text(
                                    '点击裁切多宫格图片后显示缩略图',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                            else
                              ViewportLazyGrid(
                                itemCount: image.exportedPaths.length,
                                crossAxisCount: 3,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                itemBuilder: (context, index) {
                                  final path = image.exportedPaths[index];
                                  return _ExportedThumb(
                                    path: path,
                                    onOpen: () => _openPreview(
                                      context,
                                      image.exportedPaths,
                                      index,
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _InspectorActionBar(
            controller: controller,
            state: state,
            onImport: onImport,
          ),
        ],
      ),
    );
  }

  void _openPreview(BuildContext context, List<String> paths, int index) {
    showFullscreenZoomGallery<String>(
      context: context,
      items: paths,
      initialIndex: index,
      itemBuilder: (context, path) =>
          Image.file(File(path), fit: BoxFit.contain),
    );
  }
}

class _GridCutCollapsibleSection extends StatelessWidget {
  const _GridCutCollapsibleSection({
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
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricLine extends StatelessWidget {
  const _MetricLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.grid_on_rounded, size: 16),
      onPressed: onTap,
    );
  }
}

class _LineStyleControls extends StatelessWidget {
  const _LineStyleControls({
    required this.color,
    required this.strokeWidth,
    required this.onColorChanged,
    required this.onStrokeWidthChanged,
  });

  static const _colors = [
    Color(0xFFFFD54F),
    Color(0xFF00E5FF),
    Color(0xFFFF4081),
    Color(0xFF76FF03),
    Color(0xFFFFFFFF),
    Color(0xFF111111),
  ];

  final Color color;
  final double strokeWidth;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onStrokeWidthChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '裁切线',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in _colors)
              Tooltip(
                message: '裁切线颜色',
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onColorChanged(option),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: option,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: option == color
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: option == color ? 2 : 1,
                      ),
                    ),
                    child: option == color
                        ? Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: _foregroundFor(option),
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.line_weight_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: strokeWidth,
                min: 1,
                max: 6,
                divisions: 10,
                label: strokeWidth.toStringAsFixed(1),
                onChanged: onStrokeWidthChanged,
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                strokeWidth.toStringAsFixed(1),
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static Color _foregroundFor(Color color) {
    final brightness = ThemeData.estimateBrightnessForColor(color);
    return brightness == Brightness.dark ? Colors.white : Colors.black;
  }
}

class _ExportedThumb extends StatelessWidget {
  const _ExportedThumb({required this.path, required this.onOpen});

  final String path;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imageProvider = previewFileImageProvider(
      path: path,
      logicalWidth: 160,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxCacheWidth: 512,
    );
    return Tooltip(
      message: '双击预览',
      child: GestureDetector(
        onDoubleTap: onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
            image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}
