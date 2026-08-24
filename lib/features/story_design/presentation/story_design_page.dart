import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/widgets/desktop_drop_target_scope.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../../core/widgets/image_file_context_menu.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../../core/widgets/value_listenable_selector_builder.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../shooting_script/application/shooting_asset_library_controller.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/presentation/widgets/image_generation_model_selector.dart';
import '../application/story_design_controller.dart';
import '../domain/story_design_models.dart';

StoryDesignState _storyDesignState(StoryDesignState state) => state;

bool _sameDesignInputState(StoryDesignState previous, StoryDesignState next) {
  return previous.prompt == next.prompt &&
      previous.model == next.model &&
      previous.aspectRatio == next.aspectRatio &&
      previous.imageSize == next.imageSize &&
      previous.quality == next.quality &&
      identical(previous.referenceImagePaths, next.referenceImagePaths) &&
      previous.batchCount == next.batchCount &&
      previous.gridCount == next.gridCount &&
      previous.portraitGrid == next.portraitGrid &&
      previous.isGenerating == next.isGenerating &&
      previous.completedCount == next.completedCount &&
      previous.totalCount == next.totalCount &&
      previous.failedCount == next.failedCount &&
      previous.message == next.message;
}

bool _sameDesignResultState(StoryDesignState previous, StoryDesignState next) {
  return identical(previous.results, next.results) &&
      identical(previous.generationTasks, next.generationTasks);
}

const _designAssetTypes = [
  ReplicateAssetType.character,
  ReplicateAssetType.product,
  ReplicateAssetType.scene,
  ReplicateAssetType.prop,
  ReplicateAssetType.reference,
  ReplicateAssetType.other,
];

enum _DesignResultMenuAction { addAsAsset }

class StoryDesignPage extends ConsumerStatefulWidget {
  const StoryDesignPage({super.key, this.onOpenGridCutPage});

  final VoidCallback? onOpenGridCutPage;

  @override
  ConsumerState<StoryDesignPage> createState() => _StoryDesignPageState();
}

class _StoryDesignPageState extends ConsumerState<StoryDesignPage> {
  static const _inputPanelWidthKey = 'storyDesignInputPanelWidth';
  static const _defaultInputPanelWidth = 360.0;
  static const _minInputPanelWidth = 300.0;
  static const _compactInputPanelWidth = 240.0;
  static const _maxInputPanelWidth = 560.0;
  static const _minResultPanelWidth = 320.0;
  static const _compactResultPanelWidth = 180.0;
  static const _panelGap = 12.0;
  static const _resizeHandleWidth = 12.0;

  late final TextEditingController _promptController;
  final _promptFocusNode = FocusNode();
  double _inputPanelWidth = _defaultInputPanelWidth;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(storyDesignControllerProvider);
    _promptController = TextEditingController(text: controller.value.prompt);
    _inputPanelWidth = _loadInputPanelWidth();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('story_design.page');
    final controller = ref.watch(storyDesignControllerProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inputPanelWidth = _clampInputPanelWidth(
            _inputPanelWidth,
            constraints.maxWidth,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: inputPanelWidth,
                child:
                    ValueListenableSelectorBuilder<
                      StoryDesignState,
                      StoryDesignState
                    >(
                      valueListenable: controller,
                      selector: _storyDesignState,
                      equals: _sameDesignInputState,
                      builder: (context, state, _) {
                        if (!_promptFocusNode.hasFocus &&
                            _promptController.text != state.prompt) {
                          _promptController.text = state.prompt;
                        }
                        return _DesignInputPanel(
                          controller: controller,
                          state: state,
                          promptController: _promptController,
                          promptFocusNode: _promptFocusNode,
                        );
                      },
                    ),
              ),
              const SizedBox(width: _panelGap),
              _DesignPanelResizer(
                width: _resizeHandleWidth,
                onDrag: (delta) =>
                    _resizeInputPanel(delta, constraints.maxWidth),
                onDragEnd: _saveInputPanelWidth,
              ),
              const SizedBox(width: _panelGap),
              Expanded(
                child:
                    ValueListenableSelectorBuilder<
                      StoryDesignState,
                      StoryDesignState
                    >(
                      valueListenable: controller,
                      selector: _storyDesignState,
                      equals: _sameDesignResultState,
                      builder: (context, state, _) => _DesignResultPanel(
                        controller: controller,
                        state: state,
                        onOpenGridCutPage: widget.onOpenGridCutPage,
                        onAddAsAsset: _addResultAsAsset,
                      ),
                    ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _resizeInputPanel(double delta, double availableWidth) {
    setState(() {
      _inputPanelWidth = _clampInputPanelWidth(
        _inputPanelWidth + delta,
        availableWidth,
      );
    });
  }

  double _loadInputPanelWidth() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(_inputPanelWidthKey);
      return double.tryParse(raw ?? '') ?? _defaultInputPanelWidth;
    } catch (_) {
      return _defaultInputPanelWidth;
    }
  }

  void _saveInputPanelWidth() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(_inputPanelWidthKey, _inputPanelWidth.toStringAsFixed(1));
    } catch (_) {
      // 轻量测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  double _clampInputPanelWidth(double width, double availableWidth) {
    final chromeWidth = _panelGap * 2 + _resizeHandleWidth;
    final contentWidth = math.max(0.0, availableWidth - chromeWidth);
    final isCompact = contentWidth < _minInputPanelWidth + _minResultPanelWidth;
    final compactInputMin = math.min(_compactInputPanelWidth, contentWidth);
    final minWidth = isCompact
        ? math.min(
            _minInputPanelWidth,
            math.max(compactInputMin, contentWidth * 0.55),
          )
        : _minInputPanelWidth;
    final resultReserve = isCompact
        ? math.min(
            _minResultPanelWidth,
            math.max(_compactResultPanelWidth, contentWidth * 0.38),
          )
        : _minResultPanelWidth;
    final maxWidth = math.max(
      minWidth,
      math.min(_maxInputPanelWidth, contentWidth - resultReserve),
    );
    return width.clamp(minWidth, maxWidth).toDouble();
  }

  Future<void> _addResultAsAsset(StoryDesignResult result) async {
    final file = File(result.path);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('结果图片文件不存在')));
      return;
    }
    await _showDesignAssetDialog(result);
  }

  Future<void> _importDesignResultAsset(
    StoryDesignResult result,
    _DesignAssetEditorResult asset,
  ) async {
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.clear();
    await FileImage(File(result.path)).evict();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final imported = await ref
        .read(shootingAssetLibraryControllerProvider)
        .importItem(
          sourcePath: result.path,
          type: asset.type,
          name: asset.name,
          description: asset.description,
        );
    if (!mounted || imported == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已添加为资产：${imported.name}')));
  }

  Future<void> _showDesignAssetDialog(StoryDesignResult result) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DesignAssetDialog(
        result: result,
        onConfirm: (asset) => _importDesignResultAsset(result, asset),
      ),
    );
  }
}

class _DesignAssetDialog extends StatefulWidget {
  const _DesignAssetDialog({required this.result, required this.onConfirm});

  final StoryDesignResult result;
  final Future<void> Function(_DesignAssetEditorResult asset) onConfirm;

  @override
  State<_DesignAssetDialog> createState() => _DesignAssetDialogState();
}

class _DesignAssetDialogState extends State<_DesignAssetDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  var _type = ReplicateAssetType.reference;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: p.basenameWithoutExtension(widget.result.path),
    );
    _description = TextEditingController(text: widget.result.prompt);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加为资产'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<ReplicateAssetType>(
            key: const ValueKey('story-design-add-asset-type'),
            initialValue: _type,
            decoration: const InputDecoration(labelText: '资产类型'),
            items: [
              for (final item in _designAssetTypes)
                DropdownMenuItem(value: item, child: Text(item.label)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('story-design-add-asset-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: '资产名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('story-design-add-asset-description'),
            controller: _description,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '特征或备注',
              alignLabelWithHint: true,
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
      FilledButton.icon(
        key: const ValueKey('story-design-confirm-add-asset'),
        onPressed: () async {
          await widget.onConfirm(
            _DesignAssetEditorResult(
              type: _type,
              name: _name.text.trim(),
              description: _description.text.trim(),
            ),
          );
          if (context.mounted) Navigator.of(context).pop();
        },
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('添加资产'),
      ),
    ],
  );
}

class _DesignPanelResizer extends StatelessWidget {
  const _DesignPanelResizer({
    required this.width,
    required this.onDrag,
    required this.onDragEnd,
  });

  final double width;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '拖拽调整左侧面板宽度',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
          onHorizontalDragEnd: (_) => onDragEnd(),
          child: SizedBox(
            width: width,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const SizedBox(width: 3, height: 68),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesignInputPanel extends StatelessWidget {
  const _DesignInputPanel({
    required this.controller,
    required this.state,
    required this.promptController,
    required this.promptFocusNode,
  });

  final StoryDesignController controller;
  final StoryDesignState state;
  final TextEditingController promptController;
  final FocusNode promptFocusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: _DesignInputFields(
                controller: controller,
                state: state,
                promptController: promptController,
                promptFocusNode: promptFocusNode,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _DesignInputFooter(controller: controller, state: state),
        ],
      ),
    );
  }
}

class _DesignInputFields extends StatelessWidget {
  const _DesignInputFields({
    required this.controller,
    required this.state,
    required this.promptController,
    required this.promptFocusNode,
  });

  final StoryDesignController controller;
  final StoryDesignState state;
  final TextEditingController promptController;
  final FocusNode promptFocusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '设计分镜图',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        _ReferenceImagesPanel(controller: controller, state: state),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('story-design-prompt-field'),
          controller: promptController,
          focusNode: promptFocusNode,
          minLines: 7,
          maxLines: 10,
          textInputAction: TextInputAction.newline,
          decoration: const InputDecoration(
            labelText: '提示词',
            alignLabelWithHint: true,
            prefixIcon: Icon(Icons.edit_note_rounded),
          ),
          onChanged: controller.setPrompt,
        ),
        const SizedBox(height: 12),
        _GenerationParameters(controller: controller, state: state),
      ],
    );
  }
}

class _GenerationParameters extends StatefulWidget {
  const _GenerationParameters({required this.controller, required this.state});

  final StoryDesignController controller;
  final StoryDesignState state;

  @override
  State<_GenerationParameters> createState() => _GenerationParametersState();
}

class _GenerationParametersState extends State<_GenerationParameters> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final imageSizeLabels = StoryDesignController.imageSizeLabelsFor(
      state.model,
      state.aspectRatio,
    );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            key: const ValueKey('story-design-parameters-toggle'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '生成参数',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    state.gridCount == 0
                        ? '${state.batchCount} 张 · 无宫格'
                        : '${state.batchCount} 张 · ${state.gridCount} 宫格${state.portraitGrid ? ' · 竖屏单列' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  ImageGenerationModelSelector(
                    key: const ValueKey('story-design-model-field'),
                    value: state.model,
                    enabled: true,
                    onChanged: controller.setModel,
                  ),
                  const SizedBox(height: 10),
                  _ResponsiveFormPair(
                    first: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: state.aspectRatio,
                      decoration: const InputDecoration(
                        labelText: '比例',
                        prefixIcon: Icon(Icons.aspect_ratio_rounded),
                      ),
                      items: [
                        for (final ratio
                            in StoryDesignController.aspectRatioOptionsFor(
                              state.model,
                            ))
                          DropdownMenuItem(
                            value: ratio,
                            child: Text(ratio, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (ratio) {
                        if (ratio != null) {
                          controller.setAspectRatio(ratio);
                        }
                      },
                    ),
                    second: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: state.imageSize,
                      decoration: const InputDecoration(
                        labelText: '尺寸',
                        prefixIcon: Icon(Icons.photo_size_select_large_rounded),
                      ),
                      items: [
                        for (final size
                            in StoryDesignController.imageSizeOptionsFor(
                              state.model,
                              state.aspectRatio,
                            ))
                          DropdownMenuItem(
                            value: size,
                            child: Text(
                              imageSizeLabels?[size] ?? size,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (size) {
                        if (size != null) {
                          controller.setImageSize(size);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('story-design-quality-field'),
                    isExpanded: true,
                    initialValue: state.quality,
                    decoration: const InputDecoration(
                      labelText: '质量',
                      prefixIcon: Icon(Icons.high_quality_rounded),
                    ),
                    items: [
                      for (final quality
                          in StoryDesignController.qualityOptionsFor(
                            state.model,
                          ))
                        DropdownMenuItem(
                          value: quality,
                          child: Text(
                            GptImageGenerationPreset.qualityLabels[quality] ??
                                quality,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged:
                        !StoryDesignController.supportsQuality(state.model)
                        ? null
                        : (quality) {
                            if (quality != null) {
                              controller.setQuality(quality);
                            }
                          },
                  ),
                  const SizedBox(height: 10),
                  _ResponsiveFormPair(
                    first: DropdownButtonFormField<int>(
                      key: const ValueKey('story-design-batch-count-field'),
                      isExpanded: true,
                      initialValue: state.batchCount,
                      decoration: const InputDecoration(
                        labelText: '批量数量',
                        prefixIcon: Icon(Icons.filter_9_plus_rounded),
                      ),
                      items: [
                        for (final count in StoryDesignController.batchOptions)
                          DropdownMenuItem(value: count, child: Text('$count')),
                      ],
                      onChanged: (count) {
                        if (count != null) {
                          controller.setBatchCount(count);
                        }
                      },
                    ),
                    second: DropdownButtonFormField<int>(
                      key: const ValueKey('story-design-grid-count-field'),
                      isExpanded: true,
                      initialValue: state.gridCount,
                      decoration: const InputDecoration(
                        labelText: '多宫格',
                        prefixIcon: Icon(Icons.grid_view_rounded),
                      ),
                      items: [
                        for (final count in StoryDesignController.gridOptions)
                          DropdownMenuItem(
                            value: count,
                            child: Text(count == 0 ? '无' : '$count 宫格'),
                          ),
                      ],
                      onChanged: (count) {
                        if (count != null) {
                          controller.setGridCount(count);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey('story-design-portrait-grid-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('竖屏多宫格'),
                    subtitle: Text(
                      state.gridCount == 0
                          ? '选择宫格数量后可用'
                          : state.portraitGrid
                          ? '${state.gridCount} 行 × 1 列，每行 1 个分镜'
                          : '使用常规多行多列宫格排列',
                    ),
                    value: state.portraitGrid,
                    onChanged: state.gridCount == 0
                        ? null
                        : controller.setPortraitGrid,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResponsiveFormPair extends StatelessWidget {
  const _ResponsiveFormPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 330) {
          return Column(children: [first, const SizedBox(height: 10), second]);
        }
        return Row(
          children: [
            Expanded(child: first),
            const SizedBox(width: 10),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _DesignInputFooter extends StatelessWidget {
  const _DesignInputFooter({required this.controller, required this.state});

  final StoryDesignController controller;
  final StoryDesignState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (state.isGenerating)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (state.isGenerating) const SizedBox(width: 8),
            Expanded(
              child: Text(
                state.isGenerating
                    ? '并发生成 ${state.activeTaskCount} 个任务 · ${state.message}'
                    : state.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('story-design-generate-button'),
            onPressed: controller.generate,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: const Text('生成图片'),
          ),
        ),
      ],
    );
  }
}

class _ReferenceImagesPanel extends StatefulWidget {
  const _ReferenceImagesPanel({required this.controller, required this.state});

  final StoryDesignController controller;
  final StoryDesignState state;

  @override
  State<_ReferenceImagesPanel> createState() => _ReferenceImagesPanelState();
}

class _ReferenceImagesPanelState extends State<_ReferenceImagesPanel> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final referenceBody = widget.state.referenceImagePaths.isEmpty
        ? SizedBox(
            height: 78,
            child: Center(
              child: Text(
                '可点击或直接拖入参考图',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        : SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.state.referenceImagePaths.length,
              separatorBuilder: (context, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final path = widget.state.referenceImagePaths[index];
                return _ReferenceThumb(
                  key: ValueKey('story-design-reference-$index'),
                  path: path,
                  onRemove: () => widget.controller.removeReferencePath(path),
                );
              },
            ),
          );
    return DropTarget(
      key: const ValueKey('story-design-reference-drop-target'),
      enable: DesktopDropTargetScope.enabledOf(context),
      onDragEntered: (_) {
        if (!_isDragging) {
          setState(() => _isDragging = true);
        }
      },
      onDragExited: (_) {
        if (_isDragging) {
          setState(() => _isDragging = false);
        }
      },
      onDragDone: (details) {
        if (_isDragging) {
          setState(() => _isDragging = false);
        }
        widget.controller.addReferencePaths(
          details.files.map((file) => file.path),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _isDragging
              ? scheme.primaryContainer.withValues(alpha: 0.42)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isDragging
                ? scheme.primary.withValues(alpha: 0.9)
                : scheme.outlineVariant.withValues(alpha: 0.36),
            width: _isDragging ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_library_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '参考图',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '添加参考图',
                  onPressed: widget.controller.pickReferenceImages,
                  icon: const Icon(Icons.add_photo_alternate_rounded),
                ),
                IconButton(
                  tooltip: '清空参考图',
                  onPressed: widget.state.referenceImagePaths.isEmpty
                      ? null
                      : widget.controller.clearReferencePaths,
                  icon: const Icon(Icons.clear_all_rounded),
                ),
              ],
            ),
            Stack(
              children: [
                referenceBody,
                if (_isDragging)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          '松开即可添加为参考图',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceThumb extends StatelessWidget {
  const _ReferenceThumb({
    super.key,
    required this.path,
    required this.onRemove,
  });

  final String path;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imageProvider = previewFileImageProvider(
      path: path,
      logicalWidth: 82,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    return SizedBox(
      width: 82,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  errorBuilder: (context, _, _) => ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_rounded),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: IconButton.filledTonal(
              tooltip: '移除参考图',
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 15),
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: scheme.surface.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesignResultPanel extends StatelessWidget {
  const _DesignResultPanel({
    required this.controller,
    required this.state,
    required this.onOpenGridCutPage,
    required this.onAddAsAsset,
  });

  final StoryDesignController controller;
  final StoryDesignState state;
  final VoidCallback? onOpenGridCutPage;
  final Future<void> Function(StoryDesignResult result) onAddAsAsset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visibleTasks = state.generationTasks
        .where((task) => !task.isSucceeded)
        .toList();
    return Container(
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
          _ResultToolbar(
            controller: controller,
            state: state,
            onOpenGridCutPage: onOpenGridCutPage,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: state.results.isEmpty && visibleTasks.isEmpty
                ? const _EmptyResults()
                : _ResultGrid(
                    controller: controller,
                    results: state.results,
                    tasks: visibleTasks,
                    onAddAsAsset: onAddAsAsset,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ResultToolbar extends StatelessWidget {
  const _ResultToolbar({
    required this.controller,
    required this.state,
    required this.onOpenGridCutPage,
  });

  final StoryDesignController controller;
  final StoryDesignState state;
  final VoidCallback? onOpenGridCutPage;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '生成中 ${state.activeTaskCount} · 结果 ${state.results.length} · 失败 ${state.failedCount}',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        OutlinedButton.icon(
          onPressed: controller.openGeneratedDirectory,
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('打开目录'),
        ),
        OutlinedButton.icon(
          onPressed: state.results.isEmpty ? null : controller.selectAllResults,
          icon: const Icon(Icons.select_all_rounded),
          label: const Text('全选'),
        ),
        OutlinedButton.icon(
          onPressed: state.selectedResultCount == 0
              ? null
              : controller.clearResultSelection,
          icon: const Icon(Icons.deselect_rounded),
          label: const Text('取消选择'),
        ),
        OutlinedButton.icon(
          onPressed: state.results.isEmpty ? null : controller.clearResults,
          icon: const Icon(Icons.delete_sweep_rounded),
          label: const Text('清空结果'),
        ),
        FilledButton.icon(
          onPressed: state.selectedResultCount == 0
              ? null
              : controller.addSelectedToCutPage,
          icon: const Icon(Icons.playlist_add_rounded),
          label: const Text('添加到裁切页'),
        ),
        FilledButton.tonalIcon(
          onPressed: onOpenGridCutPage,
          icon: const Icon(Icons.grid_view_rounded),
          label: const Text('去裁切页'),
        ),
      ],
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_search_rounded, size: 40, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            '生成任务和结果会显示在这里',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.controller,
    required this.results,
    required this.tasks,
    required this.onAddAsAsset,
  });

  final StoryDesignController controller;
  final List<StoryDesignResult> results;
  final List<StoryDesignGenerationTask> tasks;
  final Future<void> Function(StoryDesignResult result) onAddAsAsset;

  @override
  Widget build(BuildContext context) {
    final imagePaths = buildStoryDesignResultPaths(results);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 220)
            .floor()
            .clamp(1, 6)
            .toInt();
        return GridView.builder(
          itemCount: tasks.length + results.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.82,
          ),
          itemBuilder: (context, index) {
            if (index < tasks.length) {
              final task = tasks[index];
              return _GenerationTaskTile(
                key: ValueKey('story-design-task-${task.id}'),
                task: task,
                onDismiss: task.isRunning
                    ? null
                    : () => controller.dismissGenerationTask(task.id),
              );
            }
            final resultIndex = index - tasks.length;
            final result = results[resultIndex];
            return _ResultTile(
              key: ValueKey('story-design-result-${result.id}'),
              result: result,
              imagePaths: imagePaths,
              index: resultIndex,
              onSelected: (selected) =>
                  controller.toggleResultSelection(result.id, selected),
              onRemove: () => controller.removeResult(result.id),
              onAddAsAsset: () => onAddAsAsset(result),
            );
          },
        );
      },
    );
  }
}

class _GenerationTaskTile extends StatefulWidget {
  const _GenerationTaskTile({
    super.key,
    required this.task,
    required this.onDismiss,
  });

  final StoryDesignGenerationTask task;
  final VoidCallback? onDismiss;

  @override
  State<_GenerationTaskTile> createState() => _GenerationTaskTileState();
}

class _GenerationTaskTileState extends State<_GenerationTaskTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _GenerationTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.isRunning != widget.task.isRunning) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!widget.task.isRunning) {
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final task = widget.task;
    final elapsed = task.elapsedAt(DateTime.now());
    final isRunning = task.isRunning;
    final accent = isRunning ? scheme.primary : scheme.error;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.72), width: 1.5),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        isRunning
                            ? Icons.hourglass_top_rounded
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: accent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          isRunning ? '生成中' : '生成失败',
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        _formatGenerationDuration(elapsed),
                        key: ValueKey('story-design-task-timer-${task.id}'),
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (widget.onDismiss != null) const SizedBox(width: 30),
                    ],
                  ),
                  const Spacer(),
                  Center(
                    child: isRunning
                        ? SizedBox(
                            width: 38,
                            height: 38,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: accent,
                            ),
                          )
                        : Icon(
                            Icons.cloud_off_rounded,
                            size: 42,
                            color: accent,
                          ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    ImageGenerationModelCatalog.labelFor(task.model),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isRunning ? task.prompt : task.errorMessage,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isRunning ? scheme.onSurfaceVariant : accent,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${task.aspectRatio} · ${task.imageSize}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.onDismiss != null)
            Positioned(
              right: 6,
              top: 6,
              child: IconButton(
                tooltip: '移除失败任务',
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close_rounded, size: 18),
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    super.key,
    required this.result,
    required this.imagePaths,
    required this.index,
    required this.onSelected,
    required this.onRemove,
    required this.onAddAsAsset,
  });

  final StoryDesignResult result;
  final List<String> imagePaths;
  final int index;
  final ValueChanged<bool> onSelected;
  final VoidCallback onRemove;
  final Future<void> Function() onAddAsAsset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onDoubleTap: () => showFullscreenZoomGallery<String>(
        context: context,
        items: imagePaths,
        initialIndex: index,
        itemBuilder: (context, path) => _FullscreenResultImage(path: path),
      ),
      onSecondaryTapDown: (details) async {
        final action = await showImageFileContextMenu<_DesignResultMenuAction>(
          context,
          globalPosition: details.globalPosition,
          imagePath: result.path,
          leadingActions: const [
            ImageFileContextMenuAction(
              value: _DesignResultMenuAction.addAsAsset,
              icon: Icons.add_photo_alternate_outlined,
              label: '添加为资产',
            ),
          ],
        );
        if (action == _DesignResultMenuAction.addAsAsset) {
          await onAddAsAsset();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: result.selected
                ? scheme.primary.withValues(alpha: 0.72)
                : scheme.outlineVariant.withValues(alpha: 0.46),
            width: result.selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ResultPreviewImage(path: result.path),
              Positioned(
                left: 6,
                top: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Checkbox(
                    value: result.selected,
                    onChanged: (selected) => onSelected(selected ?? false),
                  ),
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: IconButton.filledTonal(
                  tooltip: '移除结果',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.surface.withValues(alpha: 0.82),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.9),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.basename(result.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                ImageGenerationModelCatalog.labelFor(
                                  result.model,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '用时 ${_formatGenerationDuration(result.generationDuration)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ],
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

String _formatGenerationDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainingSeconds = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainingSeconds.toString().padLeft(2, '0')}';
}

@visibleForTesting
List<String> buildStoryDesignResultPaths(Iterable<StoryDesignResult> results) =>
    [for (final result in results) result.path];

class _ResultPreviewImage extends StatelessWidget {
  const _ResultPreviewImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageProvider = previewFileImageProvider(
          path: path,
          logicalWidth: constraints.maxWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return RepaintBoundary(
          child: Image(
            image: imageProvider,
            fit: BoxFit.cover,
            errorBuilder: (context, _, _) => ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: const Center(child: Icon(Icons.broken_image_rounded)),
            ),
          ),
        );
      },
    );
  }
}

class _FullscreenResultImage extends StatelessWidget {
  const _FullscreenResultImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final imageProvider = previewFileImageProvider(
          path: path,
          logicalWidth: viewportWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return Image(image: imageProvider, fit: BoxFit.contain);
      },
    );
  }
}

class _DesignAssetEditorResult {
  const _DesignAssetEditorResult({
    required this.type,
    required this.name,
    required this.description,
  });

  final ReplicateAssetType type;
  final String name;
  final String description;
}

extension on ReplicateAssetType {
  String get label => switch (this) {
    ReplicateAssetType.character => '人物',
    ReplicateAssetType.product => '产品',
    ReplicateAssetType.scene => '场景',
    ReplicateAssetType.prop => '道具',
    ReplicateAssetType.video => '视频',
    ReplicateAssetType.audio => '音频',
    ReplicateAssetType.reference => '综合参考',
    ReplicateAssetType.other => '其他',
  };
}
