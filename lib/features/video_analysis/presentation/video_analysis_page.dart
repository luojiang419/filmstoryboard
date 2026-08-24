import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/widgets/adaptive_video_viewport.dart';
import '../../../core/widgets/desktop_drop_target_scope.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../projects/application/project_aspect_controller.dart';
import '../../projects/domain/project_aspect_ratio.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../storyboard/domain/storyboard_models.dart';
import '../application/video_analysis_controller.dart';
import '../data/analysis_report_export_service.dart';
import '../domain/video_analysis_models.dart';

class VideoAnalysisPage extends ConsumerStatefulWidget {
  const VideoAnalysisPage({super.key, this.onOpenStoryboard});

  final VoidCallback? onOpenStoryboard;

  @override
  ConsumerState<VideoAnalysisPage> createState() => _VideoAnalysisPageState();
}

class _VideoAnalysisPageState extends ConsumerState<VideoAnalysisPage> {
  static const _videoTypes = XTypeGroup(
    label: '视频',
    extensions: ['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'],
  );
  static const _videoExtensions = {
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
    '.webm',
    '.m4v',
  };

  var _isDraggingOver = false;

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('video_analysis.page');
    final controller = ref.watch(videoAnalysisControllerProvider);
    final storyboardController = ref.watch(storyboardControllerProvider);
    final projectAspectController = ref.watch(projectAspectControllerProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            controller.undoFrameRemoval,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): controller.redoFrameRemoval,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            controller.redoFrameRemoval,
      },
      child: Focus(
        autofocus: true,
        child: DropTarget(
          enable: DesktopDropTargetScope.enabledOf(context),
          key: const ValueKey('video-analysis-drop-target'),
          onDragEntered: (_) => setState(() => _isDraggingOver = true),
          onDragExited: (_) => setState(() => _isDraggingOver = false),
          onDragDone: (details) => _handleDroppedVideos(
            context,
            controller,
            details.files.map((file) => file.path).toList(),
          ),
          child: ValueListenableBuilder<VideoAnalysisState>(
            valueListenable: controller,
            builder: (context, state, _) =>
                ValueListenableBuilder<StoryboardState>(
                  valueListenable: storyboardController,
                  builder: (context, storyboardState, _) => ColoredBox(
                    key: const ValueKey('video-analysis-page'),
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _Toolbar(
                                controller: controller,
                                projectAspectController:
                                    projectAspectController,
                                state: state,
                                storyboardBusy: storyboardState.isAnalyzing,
                                onImport: () => _pickVideo(context, controller),
                                onStartAnalysis: () =>
                                    _chooseAnalysisMode(context, controller),
                                onReanalyze: state.summary == null
                                    ? null
                                    : () => _confirmReanalyze(
                                        context,
                                        controller,
                                      ),
                                onExport: state.summary == null
                                    ? null
                                    : () => _chooseReportFormat(
                                        context,
                                        controller,
                                      ),
                                onGenerateStoryboard: state.frames.isNotEmpty
                                    ? () => _generateStoryboard(context)
                                    : null,
                              ),
                              if (state.isBusy ||
                                  state.isPaused ||
                                  storyboardState.isAnalyzing) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value:
                                      storyboardState.isAnalyzing ||
                                          state.totalProgress <= 0
                                      ? null
                                      : state.completedProgress /
                                            state.totalProgress,
                                ),
                              ],
                              if (state.message.isNotEmpty ||
                                  state.errorMessage.isNotEmpty ||
                                  storyboardState.isAnalyzing) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    storyboardState.isAnalyzing
                                        ? storyboardState.message
                                        : state.errorMessage.isNotEmpty
                                        ? state.errorMessage
                                        : state.message,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: state.errorMessage.isNotEmpty
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
                                child: state.videos.isEmpty
                                    ? _EmptyState(
                                        onImport: () =>
                                            _pickVideo(context, controller),
                                      )
                                    : LayoutBuilder(
                                        builder: (context, constraints) {
                                          if (constraints.maxWidth < 900) {
                                            return _CompactWorkspace(
                                              controller: controller,
                                              state: state,
                                            );
                                          }
                                          return _WideWorkspace(
                                            controller: controller,
                                            state: state,
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                        if (_isDraggingOver)
                          Positioned.fill(
                            child: _VideoDropOverlay(isBusy: state.isBusy),
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

  Future<void> _pickVideo(
    BuildContext context,
    VideoAnalysisController controller,
  ) async {
    final results = await ref
        .read(desktopFileDialogServiceProvider)
        .openFiles(
          source: 'video_analysis.pick_video',
          acceptedTypeGroups: const [_videoTypes],
          initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
        );
    if (results.isEmpty) {
      return;
    }
    await controller.importVideos(
      results.map((result) => File(result.path)).toList(),
    );
  }

  Future<void> _handleDroppedVideos(
    BuildContext context,
    VideoAnalysisController controller,
    List<String> paths,
  ) async {
    if (mounted) {
      setState(() => _isDraggingOver = false);
    }
    if (controller.value.isBusy) {
      _showDropMessage(context, '当前正在处理视频，请完成后再拖入添加');
      return;
    }
    final files = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty && _isSupportedVideoPath(path))
        .map(File.new)
        .toList(growable: false);
    if (files.isEmpty) {
      _showDropMessage(context, '未找到支持的视频文件，可拖入 mp4、mov、mkv、avi、webm 或 m4v');
      return;
    }
    final ignoredCount = paths.length - files.length;
    if (ignoredCount > 0) {
      _showDropMessage(
        context,
        '已添加 ${files.length} 个视频，忽略 $ignoredCount 个非视频文件',
      );
    }
    await controller.importVideos(files);
  }

  void _showDropMessage(BuildContext context, String message) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static bool _isSupportedVideoPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) {
      return false;
    }
    return _videoExtensions.contains(path.substring(dot).toLowerCase());
  }

  Future<void> _chooseAnalysisMode(
    BuildContext context,
    VideoAnalysisController controller,
  ) async {
    final action = await showDialog<_AnalysisStartAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开始视频解析'),
        content: const Text(
          '解析当前视频会重新处理当前选中的视频；解析全部视频会处理所有未完成的视频帧，并跳过已经解析完成的帧。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AnalysisStartAction.all),
            child: const Text('解析全部视频'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AnalysisStartAction.current),
            child: const Text('解析当前视频'),
          ),
        ],
      ),
    );
    switch (action) {
      case _AnalysisStartAction.all:
        await controller.startAnalysis(allVideos: true);
      case _AnalysisStartAction.current:
        await controller.startAnalysis(forceAll: true);
      case null:
        return;
    }
  }

  Future<void> _confirmReanalyze(
    BuildContext context,
    VideoAnalysisController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新解析全部视频帧？'),
        content: const Text('已有帧级、镜头级和视频级结果会被新结果更新，原始视频帧不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重新解析'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.startAnalysis(forceAll: true);
    }
  }

  Future<void> _chooseReportFormat(
    BuildContext context,
    VideoAnalysisController controller,
  ) async {
    final format = await showDialog<AnalysisReportFormat>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择分析报告格式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in AnalysisReportFormat.values)
              ListTile(
                leading: Icon(switch (item) {
                  AnalysisReportFormat.xlsx => Icons.table_view_rounded,
                  AnalysisReportFormat.pdf => Icons.picture_as_pdf_rounded,
                  AnalysisReportFormat.png => Icons.image_rounded,
                  AnalysisReportFormat.jpg => Icons.photo_rounded,
                }),
                title: Text(item.label),
                subtitle: Text(switch (item) {
                  AnalysisReportFormat.xlsx => '四个工作表，可继续编辑',
                  AnalysisReportFormat.pdf => '多页视觉报告',
                  AnalysisReportFormat.png => '按报告页输出无损图片',
                  AnalysisReportFormat.jpg => '按报告页输出高质量图片',
                }),
                onTap: () => Navigator.of(context).pop(item),
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
    if (format != null) {
      await controller.exportReport(format);
    }
  }

  Future<void> _generateStoryboard(BuildContext context) async {
    final videoController = ref.read(videoAnalysisControllerProvider);
    final generated = await videoController
        .generateStoryboardForSelectedVideo();
    if (!context.mounted) {
      return;
    }
    if (generated) {
      widget.onOpenStoryboard?.call();
    }
  }
}

enum _AnalysisStartAction { all, current }

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.projectAspectController,
    required this.state,
    required this.storyboardBusy,
    required this.onImport,
    required this.onStartAnalysis,
    required this.onReanalyze,
    required this.onExport,
    required this.onGenerateStoryboard,
  });

  final VideoAnalysisController controller;
  final ProjectAspectController projectAspectController;
  final VideoAnalysisState state;
  final bool storyboardBusy;
  final VoidCallback onImport;
  final VoidCallback onStartAnalysis;
  final VoidCallback? onReanalyze;
  final VoidCallback? onExport;
  final VoidCallback? onGenerateStoryboard;

  @override
  Widget build(BuildContext context) {
    final video = state.selectedVideo;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '视频解析',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                video == null
                    ? '导入参考视频后提取候选帧，再选择解析范围'
                    : '参考视频：${video.fileName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          flex: 3,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              ListenableBuilder(
                listenable: projectAspectController,
                builder: (context, _) {
                  final aspectState = projectAspectController.state;
                  return SizedBox(
                    width: 158,
                    child: DropdownButtonFormField<ProjectAspectMode>(
                      key: ValueKey(
                        'video-analysis-project-aspect-${aspectState.mode.name}',
                      ),
                      initialValue: aspectState.mode,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: '项目画幅 ${aspectState.effectiveRatio.label}',
                        isDense: true,
                      ),
                      items: [
                        for (final mode in ProjectAspectMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(mode.label),
                          ),
                      ],
                      onChanged: state.isBusy
                          ? null
                          : (mode) {
                              if (mode != null) {
                                projectAspectController.setMode(mode);
                              }
                            },
                    ),
                  );
                },
              ),
              IconButton(
                key: const ValueKey('video-analysis-undo'),
                tooltip: '撤销移除视频帧 (Ctrl+Z)',
                onPressed: state.isBusy || !controller.canUndoFrameRemoval
                    ? null
                    : controller.undoFrameRemoval,
                icon: const Icon(Icons.undo_rounded),
              ),
              IconButton(
                key: const ValueKey('video-analysis-redo'),
                tooltip: '恢复移除视频帧 (Ctrl+Y / Ctrl+Shift+Z)',
                onPressed: state.isBusy || !controller.canRedoFrameRemoval
                    ? null
                    : controller.redoFrameRemoval,
                icon: const Icon(Icons.redo_rounded),
              ),
              OutlinedButton.icon(
                key: const ValueKey('import-video'),
                onPressed: state.isBusy ? null : onImport,
                icon: const Icon(Icons.video_file_rounded),
                label: const Text('添加视频'),
              ),
              FilledButton.icon(
                key: const ValueKey('start-video-analysis'),
                onPressed: video == null || state.isBusy
                    ? state.isAnalyzing
                          ? controller.cancelAnalysis
                          : null
                    : state.isPaused
                    ? controller.resumeAnalysis
                    : onStartAnalysis,
                icon: Icon(
                  state.isAnalyzing
                      ? Icons.stop_circle_rounded
                      : state.isPaused
                      ? Icons.play_arrow_rounded
                      : Icons.auto_awesome_rounded,
                ),
                label: Text(
                  state.isAnalyzing
                      ? '取消解析'
                      : state.isPaused
                      ? '继续解析'
                      : '开始解析',
                ),
              ),
              OutlinedButton.icon(
                onPressed: state.isBusy
                    ? null
                    : () => controller.startAnalysis(retryFailedOnly: true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试失败'),
              ),
              OutlinedButton.icon(
                onPressed: state.isBusy ? null : onReanalyze,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('重新解析'),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('generate-video-storyboard'),
                onPressed: state.isBusy || storyboardBusy
                    ? null
                    : onGenerateStoryboard,
                icon: const Icon(Icons.dashboard_customize_rounded),
                label: const Text('生成故事板'),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('export-video-analysis-report'),
                onPressed: state.isBusy ? null : onExport,
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(
                  video == null
                      ? '导出分析报告'
                      : '导出 ${_shortName(video.fileName)} 分析报告',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _shortName(String value) {
    final dot = value.lastIndexOf('.');
    final name = dot <= 0 ? value : value.substring(0, dot);
    return name.length <= 12 ? name : '${name.substring(0, 12)}…';
  }
}

class _WideWorkspace extends StatefulWidget {
  const _WideWorkspace({required this.controller, required this.state});

  final VideoAnalysisController controller;
  final VideoAnalysisState state;

  @override
  State<_WideWorkspace> createState() => _WideWorkspaceState();
}

class _WideWorkspaceState extends State<_WideWorkspace> {
  static const _minimumLeftWidth = 180.0;
  static const _minimumRightWidth = 240.0;
  static const _minimumCenterWidth = 320.0;
  static const _panelGap = 12.0;
  static const _handleWidth = 10.0;

  var _leftWidth = 230.0;
  var _rightWidth = 310.0;
  var _leftExpanded = true;
  var _rightExpanded = true;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availablePanels =
            constraints.maxWidth - _panelGap * 2 - _handleWidth * 2;
        final maxSideWidth = math.max(
          _minimumLeftWidth,
          availablePanels - _minimumCenterWidth - _minimumRightWidth,
        );
        final rightWidth = _rightWidth
            .clamp(
              _minimumRightWidth,
              math.max(
                _minimumRightWidth,
                availablePanels - _minimumCenterWidth - _minimumLeftWidth,
              ),
            )
            .toDouble();
        final leftWidth = _leftWidth
            .clamp(
              _minimumLeftWidth,
              math.max(
                _minimumLeftWidth,
                availablePanels - _minimumCenterWidth - rightWidth,
              ),
            )
            .toDouble();
        final boundedRightWidth = rightWidth
            .clamp(
              _minimumRightWidth,
              math.max(
                _minimumRightWidth,
                availablePanels - _minimumCenterWidth - leftWidth,
              ),
            )
            .toDouble();
        final boundedLeftWidth = leftWidth
            .clamp(_minimumLeftWidth, math.max(_minimumLeftWidth, maxSideWidth))
            .toDouble();
        final effectiveLeftWidth = _leftExpanded ? boundedLeftWidth : 44.0;
        final effectiveRightWidth = _rightExpanded ? boundedRightWidth : 44.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: effectiveLeftWidth,
              child: _leftExpanded
                  ? _VideoSidebar(
                      controller: widget.controller,
                      state: widget.state,
                      onCollapse: () => setState(() => _leftExpanded = false),
                    )
                  : _CollapsedVideoPanelRail(
                      title: '参考视频',
                      icon: Icons.video_library_rounded,
                      onExpand: () => setState(() => _leftExpanded = true),
                    ),
            ),
            _PanelResizeHandle(
              key: const ValueKey('video-analysis-left-resize-handle'),
              onDrag: (delta) {
                setState(() {
                  _leftWidth = (boundedLeftWidth + delta)
                      .clamp(
                        _minimumLeftWidth,
                        math.max(
                          _minimumLeftWidth,
                          availablePanels -
                              _minimumCenterWidth -
                              effectiveRightWidth,
                        ),
                      )
                      .toDouble();
                });
              },
            ),
            const SizedBox(width: _panelGap),
            Expanded(
              child: _FrameWorkspace(
                controller: widget.controller,
                state: widget.state,
              ),
            ),
            const SizedBox(width: _panelGap),
            _PanelResizeHandle(
              key: const ValueKey('video-analysis-right-resize-handle'),
              onDrag: (delta) {
                setState(() {
                  _rightWidth = (boundedRightWidth - delta)
                      .clamp(
                        _minimumRightWidth,
                        math.max(
                          _minimumRightWidth,
                          availablePanels -
                              _minimumCenterWidth -
                              boundedLeftWidth,
                        ),
                      )
                      .toDouble();
                });
              },
            ),
            SizedBox(
              width: effectiveRightWidth,
              child: _rightExpanded
                  ? _AnalysisInspector(
                      controller: widget.controller,
                      state: widget.state,
                      onCollapse: () => setState(() => _rightExpanded = false),
                    )
                  : _CollapsedVideoPanelRail(
                      title: '解析检查器',
                      icon: Icons.analytics_outlined,
                      onExpand: () => setState(() => _rightExpanded = true),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _PanelResizeHandle extends StatelessWidget {
  const _PanelResizeHandle({super.key, required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: 10,
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

class _CompactWorkspace extends StatelessWidget {
  const _CompactWorkspace({required this.controller, required this.state});

  final VideoAnalysisController controller;
  final VideoAnalysisState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 150,
          child: _VideoSidebar(
            controller: controller,
            state: state,
            horizontal: true,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _FrameWorkspace(controller: controller, state: state),
        ),
      ],
    );
  }
}

class _VideoSidebar extends StatelessWidget {
  const _VideoSidebar({
    required this.controller,
    required this.state,
    this.horizontal = false,
    this.onCollapse,
  });

  final VideoAnalysisController controller;
  final VideoAnalysisState state;
  final bool horizontal;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = ListView.separated(
      scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
      itemCount: state.videos.length,
      separatorBuilder: (_, _) =>
          SizedBox(width: horizontal ? 8 : 0, height: horizontal ? 0 : 8),
      itemBuilder: (context, index) {
        final video = state.videos[index];
        final selected = video.id == state.selectedVideoId;
        return SizedBox(
          width: horizontal ? 230 : null,
          child: GestureDetector(
            onSecondaryTapUp: (details) =>
                _showVideoContextMenu(context, details.globalPosition, video),
            child: Card(
              color: selected ? scheme.primaryContainer : null,
              child: InkWell(
                key: ValueKey('source-video-${video.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => controller.selectVideo(video.id),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              video.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            key: ValueKey('remove-source-video-${video.id}'),
                            tooltip: '移除参考视频',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 28,
                              height: 28,
                            ),
                            onPressed: state.isBusy
                                ? null
                                : () => _confirmRemoveVideo(context, video),
                            icon: const Icon(Icons.close_rounded, size: 17),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatDuration(video.durationMs)} · '
                        '${video.displayWidth}×${video.displayHeight} · '
                        '${video.isPortrait ? '竖屏' : '横屏'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        '${video.frameCount} 帧 · ${_statusLabel(video.status)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return _Panel(
      title: '参考视频',
      onCollapse: onCollapse,
      collapseTooltip: '收起参考视频',
      child: list,
    );
  }

  Future<void> _showVideoContextMenu(
    BuildContext context,
    Offset position,
    SourceVideo video,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }
    final action = await showMenu<_VideoMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: _VideoMenuAction.openDirectory,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_rounded),
            title: Text('打开所在目录'),
          ),
        ),
      ],
    );
    if (action == _VideoMenuAction.openDirectory && context.mounted) {
      await _openVideoDirectory(context, video);
    }
  }

  Future<void> _openVideoDirectory(
    BuildContext context,
    SourceVideo video,
  ) async {
    final originalFile = File(video.originalPath);
    final storedFile = controller.resolveVideo(video);
    final directory = await originalFile.exists()
        ? originalFile.parent
        : storedFile.parent;
    final opened = await const FileExplorerService().openDirectory(
      directory.path,
    );
    if (!context.mounted) {
      return;
    }
    if (!opened) {
      return;
    }
  }

  Future<void> _confirmRemoveVideo(
    BuildContext context,
    SourceVideo video,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除参考视频'),
        content: Text('将移除「${video.fileName}」及软件生成的候选帧，原始视频文件不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.removeVideo(video.id);
    }
  }
}

enum _VideoMenuAction { openDirectory }

class _FrameWorkspace extends StatelessWidget {
  const _FrameWorkspace({required this.controller, required this.state});

  final VideoAnalysisController controller;
  final VideoAnalysisState state;

  @override
  Widget build(BuildContext context) {
    final frames = state.visibleFrames;
    final mediaAspectRatio =
        state.selectedVideo?.displayAspectRatio ??
        (frames.isEmpty || frames.first.width <= 0 || frames.first.height <= 0
            ? defaultVideoAspectRatio
            : frames.first.width / frames.first.height);
    return _Panel(
      title: '候选帧与镜头时间轴',
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final filter in VideoFrameFilter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(_filterLabel(filter)),
                            selected: state.filter == filter,
                            onSelected: (_) => controller.setFilter(filter),
                          ),
                        ),
                    ],
                  ),
                ),
                if (state.scenes.isNotEmpty)
                  SizedBox(
                    width: 150,
                    child: DropdownButton<String>(
                      key: const ValueKey('video-scene-filter'),
                      value: state.sceneFilter,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('全部场景')),
                        for (final scene in state.scenes)
                          DropdownMenuItem(
                            value: scene,
                            child: Text(
                              scene,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (scene) =>
                          controller.setSceneFilter(scene ?? ''),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: frames.isEmpty
                ? const Center(child: Text('当前筛选条件下没有视频帧'))
                : _ZoomableFrameGrid(
                    frames: frames,
                    mediaAspectRatio: mediaAspectRatio,
                    selectedFrameId: state.selectedFrameId,
                    controller: controller,
                  ),
          ),
          if (state.shots.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: state.shots.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ChoiceChip(
                      label: const Text('全部镜头'),
                      selected: state.shotFilterId.isEmpty,
                      onSelected: (_) => controller.setShotFilter(''),
                    );
                  }
                  final shot = state.shots[index - 1];
                  return ChoiceChip(
                    avatar: const Icon(Icons.movie_creation_outlined, size: 16),
                    label: Text('镜头 ${shot.shotNumber}'),
                    selected: state.shotFilterId == shot.id,
                    onSelected: (_) {
                      controller.setShotFilter(shot.id);
                      if (shot.primaryFrameId != null) {
                        controller.selectFrame(shot.primaryFrameId!);
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ZoomableFrameGrid extends StatefulWidget {
  const _ZoomableFrameGrid({
    required this.frames,
    required this.mediaAspectRatio,
    required this.selectedFrameId,
    required this.controller,
  });

  final List<VideoFrame> frames;
  final double mediaAspectRatio;
  final String? selectedFrameId;
  final VideoAnalysisController controller;

  @override
  State<_ZoomableFrameGrid> createState() => _ZoomableFrameGridState();
}

class _ZoomableFrameGridState extends State<_ZoomableFrameGrid> {
  late final TransformationController _transformationController;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = SizedBox(
          width: constraints.maxWidth,
          child: GridView.builder(
            key: const ValueKey('video-frame-grid'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              childAspectRatio: videoFrameCardAspectRatio(
                widget.mediaAspectRatio,
              ),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: widget.frames.length,
            itemBuilder: (context, index) => _FrameCard(
              controller: widget.controller,
              frame: widget.frames[index],
              selected: widget.frames[index].id == widget.selectedFrameId,
            ),
          ),
        );
        return Listener(
          key: const ValueKey('video-analysis-frame-zoom-viewport'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
              final current = _transformationController.value
                  .getMaxScaleOnAxis();
              final next = (current * factor).clamp(0.5, 4.0).toDouble();
              final scaleFactor = current <= 0 ? 1.0 : next / current;
              _transformationController.value =
                  _transformationController.value.clone()
                    ..scaleByDouble(scaleFactor, scaleFactor, scaleFactor, 1);
            });
          },
          child: Stack(
            children: [
              ClipRect(
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  constrained: false,
                  minScale: 0.5,
                  maxScale: 4,
                  boundaryMargin: const EdgeInsets.all(180),
                  child: grid,
                ),
              ),
              Positioned(
                right: 10,
                bottom: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.64),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '重置帧缩放',
                        onPressed: () => _transformationController.value =
                            Matrix4.identity(),
                        icon: const Icon(
                          Icons.fit_screen_rounded,
                          color: Colors.white,
                        ),
                      ),
                      ValueListenableBuilder<Matrix4>(
                        valueListenable: _transformationController,
                        builder: (context, matrix, _) => Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Text(
                            '${(matrix.getMaxScaleOnAxis() * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FrameCard extends StatelessWidget {
  const _FrameCard({
    required this.controller,
    required this.frame,
    required this.selected,
  });

  final VideoAnalysisController controller;
  final VideoFrame frame;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = controller.resolveFrame(frame);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('video-frame-${frame.id}'),
        onTap: () => controller.selectFrame(frame.id),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) => Image(
                      image: previewFileImageProvider(
                        path: file.path,
                        logicalWidth: constraints.maxWidth,
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _StatusBadge(status: frame.status),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filledTonal(
                      key: ValueKey('remove-video-frame-${frame.id}'),
                      tooltip: '移除视频帧',
                      onPressed: () => controller.removeFrame(frame.id),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
              child: Row(
                children: [
                  Text('#${frame.index + 1}'),
                  const Spacer(),
                  if (frame.isFocus)
                    Icon(
                      Icons.center_focus_strong,
                      size: 16,
                      color: scheme.primary,
                    ),
                  const SizedBox(width: 4),
                  Text(_formatDuration(frame.timestampMs)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double videoFrameCardAspectRatio(double mediaAspectRatio) {
  final safeRatio = mediaAspectRatio.isFinite && mediaAspectRatio > 0
      ? mediaAspectRatio
      : defaultVideoAspectRatio;
  const referenceWidth = 230.0;
  const metadataHeight = 42.0;
  return referenceWidth / (referenceWidth / safeRatio + metadataHeight);
}

class _AnalysisInspector extends StatelessWidget {
  const _AnalysisInspector({
    required this.controller,
    required this.state,
    this.onCollapse,
  });

  final VideoAnalysisController controller;
  final VideoAnalysisState state;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final video = state.selectedVideo;
    final frame = state.selectedFrame;
    final analysis = state.selectedFrameAnalysis;
    return _Panel(
      title: '解析检查器',
      onCollapse: onCollapse,
      collapseTooltip: '收起解析检查器',
      child: video == null
          ? const Center(child: Text('选择一条视频查看详情'))
          : ListView(
              children: [
                _VideoPreviewPane(
                  videoFile: controller.resolveVideo(video),
                  initialAspectRatio: video.displayAspectRatio,
                  initialPosition: Duration(
                    milliseconds: frame?.timestampMs ?? 0,
                  ),
                ),
                const SizedBox(height: 12),
                if (frame == null) ...[
                  const Text('选择一张视频帧查看详情'),
                ] else ...[
                  Text(
                    '镜头帧 #${frame.index + 1} · ${_formatDuration(frame.timestampMs)}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        label: Text(
                          '清晰度 ${frame.sharpness.toStringAsFixed(2)}',
                        ),
                      ),
                      Chip(
                        label: Text(
                          '亮度 ${frame.brightness.toStringAsFixed(2)}',
                        ),
                      ),
                      Chip(label: Text(_statusLabel(frame.status))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: frame.isFocus
                        ? null
                        : () => controller.setFocusFrame(frame.id),
                    icon: const Icon(Icons.center_focus_strong),
                    label: const Text('设为焦点帧'),
                  ),
                  const Divider(height: 24),
                ],
                if (frame != null && analysis == null)
                  const Text('该帧尚未解析')
                else if (frame != null &&
                    analysis?.status == ProcessingStatus.failed)
                  Text(
                    analysis!.errorMessage,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else if (analysis != null)
                  ..._analysisDimensionEntries(analysis).expand(
                    (entry) => [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _dimensionLabel(entry.key),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(entry.value),
                          ],
                        ),
                      ),
                      const _DashedSeparator(),
                    ],
                  ),
                if (state.summary != null) ...[
                  const SizedBox(height: 8),
                  const _DashedSeparator(),
                  const SizedBox(height: 8),
                  Text(
                    '视频级摘要',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(state.summary!.fields['outline'] ?? '暂无'),
                ],
              ],
            ),
    );
  }
}

class _DashedSeparator extends StatelessWidget {
  const _DashedSeparator();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 1,
      child: CustomPaint(
        painter: _DashedSeparatorPainter(
          Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _DashedSeparatorPainter extends CustomPainter {
  const _DashedSeparatorPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.7;
    const dashWidth = 4.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + dashWidth, size.width), size.height / 2),
        paint,
      );
      x += dashWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedSeparatorPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _VideoPreviewPane extends StatefulWidget {
  const _VideoPreviewPane({
    required this.videoFile,
    required this.initialAspectRatio,
    required this.initialPosition,
  });

  final File videoFile;
  final double initialAspectRatio;
  final Duration initialPosition;

  @override
  State<_VideoPreviewPane> createState() => _VideoPreviewPaneState();
}

class _VideoPreviewPaneState extends State<_VideoPreviewPane> {
  late final Player _player;
  late final VideoController _videoController;
  var _loadError = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _openVideo();
  }

  @override
  void didUpdateWidget(covariant _VideoPreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoFile.path != widget.videoFile.path) {
      _openVideo();
      return;
    }
    if (oldWidget.initialPosition != widget.initialPosition) {
      _seekPreview();
    }
  }

  Future<void> _openVideo() async {
    if (!await widget.videoFile.exists()) {
      if (mounted) setState(() => _loadError = '视频文件不存在');
      return;
    }
    try {
      if (!mounted) return;
      setState(() => _loadError = '');
      await _player.open(Media(widget.videoFile.path), play: false);
      await _seekPreview();
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = '视频预览加载失败：$error');
      }
    }
  }

  Future<void> _seekPreview() async {
    try {
      await _player.seek(widget.initialPosition);
      await _player.pause();
    } catch (_) {
      // 预览定位失败时保持当前帧，避免影响右侧解析信息。
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _loadError.isNotEmpty
          ? null
          : () => showDialog<void>(
              context: context,
              useSafeArea: false,
              builder: (_) => _FullscreenVideoDialog(
                videoFile: widget.videoFile,
                initialPosition: widget.initialPosition,
              ),
            ),
      child: AdaptiveVideoViewport(
        player: _player,
        initialAspectRatio: widget.initialAspectRatio,
        maxHeight: 440,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_loadError.isEmpty)
                  Video(controller: _videoController, fit: BoxFit.contain)
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _loadError,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.56),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(7),
                      child: Icon(
                        Icons.fullscreen_rounded,
                        size: 18,
                        color: Colors.white,
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
  }
}

class _FullscreenVideoDialog extends StatefulWidget {
  const _FullscreenVideoDialog({
    required this.videoFile,
    required this.initialPosition,
  });

  final File videoFile;
  final Duration initialPosition;

  @override
  State<_FullscreenVideoDialog> createState() => _FullscreenVideoDialogState();
}

class _FullscreenVideoDialogState extends State<_FullscreenVideoDialog> {
  late final Player _player;
  late final VideoController _videoController;
  late final FocusNode _focusNode;
  var _loadError = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _focusNode = FocusNode(debugLabel: 'fullscreen-video');
    _openVideo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _openVideo() async {
    try {
      await _player.open(Media(widget.videoFile.path), play: false);
      await _player.seek(widget.initialPosition);
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = '视频播放失败：$error');
      }
    }
  }

  Future<void> _seekBy(Duration offset) async {
    final next = _player.state.position + offset;
    final duration = _player.state.duration;
    final clamped = next < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && next > duration
        ? duration
        : next;
    await _player.seek(clamped);
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else if (key == LogicalKeyboardKey.space) {
      _player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -5));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 5));
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Material(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _loadError.isEmpty
                  ? Video(controller: _videoController, fit: BoxFit.contain)
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _loadError,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
            ),
            Positioned(
              top: 18,
              right: 18,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '退出全屏',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollapsedVideoPanelRail extends StatelessWidget {
  const _CollapsedVideoPanelRail({
    required this.title,
    required this.icon,
    required this.onExpand,
  });

  final String title;
  final IconData icon;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '展开$title',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onExpand,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 10),
              RotatedBox(
                quarterTurns: 3,
                child: Text(
                  title,
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

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    this.onCollapse,
    this.collapseTooltip,
  });

  final String title;
  final Widget child;
  final VoidCallback? onCollapse;
  final String? collapseTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (onCollapse != null)
                  IconButton(
                    key: ValueKey('collapse-video-panel-$title'),
                    tooltip: collapseTooltip ?? '收起面板',
                    visualDensity: VisualDensity.compact,
                    onPressed: onCollapse,
                    icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.video_file_rounded,
                  size: 52,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  '导入一条参考视频',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '软件会读取元数据，按场景变化和补帧间隔提取候选帧，再筛除模糊、曝光异常与重复画面。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('选择视频'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoDropOverlay extends StatelessWidget {
  const _VideoDropOverlay({required this.isBusy});

  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.scrim.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.primary, width: 2),
          ),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isBusy
                          ? Icons.hourglass_top_rounded
                          : Icons.video_file_rounded,
                      color: isBusy ? scheme.tertiary : scheme.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isBusy ? '当前正在处理视频' : '松开添加视频',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isBusy
                          ? '请等待导入或解析完成后再拖入新视频'
                          : '支持 mp4、mov、mkv、avi、webm、m4v',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final ProcessingStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      ProcessingStatus.completed => scheme.primary,
      ProcessingStatus.failed => scheme.error,
      ProcessingStatus.running || ProcessingStatus.retrying => scheme.tertiary,
      _ => scheme.onSurfaceVariant,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          _statusLabel(status),
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

String _formatDuration(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  final millis = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$millis';
}

String _statusLabel(ProcessingStatus status) => switch (status) {
  ProcessingStatus.pending => '待处理',
  ProcessingStatus.running => '处理中',
  ProcessingStatus.completed => '已完成',
  ProcessingStatus.partial => '部分完成',
  ProcessingStatus.failed => '失败',
  ProcessingStatus.retrying => '重试中',
};

String _filterLabel(VideoFrameFilter filter) => switch (filter) {
  VideoFrameFilter.all => '全部',
  VideoFrameFilter.focus => '焦点帧',
  VideoFrameFilter.pending => '待解析',
  VideoFrameFilter.failed => '失败',
};

List<MapEntry<String, String>> _analysisDimensionEntries(
  VideoFrameAnalysis analysis,
) => analysis.dimensions.entries
    .where((entry) => entry.value.trim().isNotEmpty)
    .toList();

String _dimensionLabel(String key) =>
    const {
      'caption': '画面描述',
      'detail': '画面细节',
      'scene': '场景',
      'props': '道具/产品',
      'people': '人物',
      'expression': '人物神态',
      'bodyAction': '动作',
      'movementTrend': '运动趋势',
      'cameraMovement': '运镜',
      'shotSize': '景别',
      'composition': '构图',
      'subjectDirection': '主体方向',
      'gazeDirection': '视线方向',
      'actionStage': '动作阶段',
      'spatialRelation': '空间关系',
      'chronologyCue': '时间线索',
      'cameraAngle': '机位角度',
      'visualFocus': '视觉焦点',
      'lightingMood': '光线情绪',
      'colorPalette': '色彩',
      'narrativeFunction': '叙事功能',
      'transitionHint': '剪辑承接',
      'body_action': '动作',
      'movement_trend': '运动趋势',
      'camera_movement': '运镜',
      'shot_size': '景别',
      'subject_direction': '主体方向',
      'gaze_direction': '视线方向',
      'action_stage': '动作阶段',
      'spatial_relation': '空间关系',
      'chronology_cue': '时间线索',
      'camera_angle': '机位角度',
      'visual_focus': '视觉焦点',
      'lighting_mood': '光线情绪',
      'color_palette': '色彩',
      'narrative_function': '叙事功能',
      'transition_hint': '剪辑承接',
      'CTA': '行动号召',
    }[key] ??
    (key.runes.any((rune) => rune >= 0x4E00 && rune <= 0x9FFF) ? key : '其他分析项');
