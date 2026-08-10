import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../application/video_generation_controller.dart';
import '../data/kling_cli_models.dart';
import '../domain/kling_duration_matcher.dart';
import '../domain/source_video_preview_range.dart';
import '../domain/video_generation_models.dart';

class VideoGenerationPage extends StatelessWidget {
  const VideoGenerationPage({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
    child: VideoGenerationWorkspace(showScriptSelector: true),
  );
}

class VideoGenerationWorkspace extends ConsumerStatefulWidget {
  const VideoGenerationWorkspace({
    super.key,
    this.scriptId,
    this.showScriptSelector = false,
    this.externalizeWorkPanel = false,
  });

  final String? scriptId;
  final bool showScriptSelector;
  final bool externalizeWorkPanel;

  @override
  ConsumerState<VideoGenerationWorkspace> createState() =>
      _VideoGenerationWorkspaceState();
}

class _VideoGenerationWorkspaceState
    extends ConsumerState<VideoGenerationWorkspace> {
  static const _workPanelDefaultWidth = 360.0;
  static const _workPanelMinWidth = 280.0;
  static const _workspaceMinWidth = 520.0;
  static const _workPanelCollapsedWidth = 52.0;
  static const _resizeHandleWidth = 10.0;

  String _taskFilter = 'all';
  bool _loginPromptShown = false;
  bool _loginPromptOpen = false;
  bool _loginWaitDialogOpen = false;
  var _workPanelWidth = _workPanelDefaultWidth;
  var _workPanelCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(videoGenerationControllerProvider);
    _syncRequestedScript(controller);
    return ValueListenableBuilder<VideoGenerationState>(
      valueListenable: controller,
      builder: (context, state, _) {
        _scheduleLoginPrompt(state, controller);
        if (state.scripts.isEmpty) {
          return const Center(child: Text('还没有可生成视频的拍摄脚本'));
        }
        final visibleTasks = state.tasks.where((task) {
          return switch (_taskFilter) {
            'completed' =>
              task.status == VideoGenerationTaskStatus.completed ||
                  task.status == VideoGenerationTaskStatus.partialCompleted,
            'active' => !task.status.isTerminal,
            'failed' =>
              task.status == VideoGenerationTaskStatus.failed ||
                  task.status == VideoGenerationTaskStatus.canceled ||
                  task.status == VideoGenerationTaskStatus.timedOut,
            _ => true,
          };
        }).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(
              state: state,
              controller: controller,
              showScriptSelector: widget.showScriptSelector,
              taskFilter: _taskFilter,
              onTaskFilterChanged: (filter) {
                if (filter != null) setState(() => _taskFilter = filter);
              },
              onLogin: () => _runKlingLoginAuthorization(controller),
              onGenerateAll: () => _confirmBatch(context, state, controller),
            ),
            if (state.isLoadingEnvironment || state.isBusy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (state.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(state.message, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (state.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                state.errorMessage,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final table = _GenerationTable(
                    state: state.copyWith(tasks: visibleTasks),
                    controller: controller,
                    onGenerateShot: (shot) =>
                        _confirmShot(context, state, controller, shot),
                  );
                  if (widget.externalizeWorkPanel) {
                    return table;
                  }
                  final panel = _WorkManagementPanel(
                    state: state,
                    controller: controller,
                    collapsed: _workPanelCollapsed,
                    onToggleCollapsed: () => setState(
                      () => _workPanelCollapsed = !_workPanelCollapsed,
                    ),
                  );
                  if (constraints.maxWidth < 1040) {
                    return Column(
                      children: [
                        Expanded(child: table),
                        const Divider(height: 1),
                        SizedBox(height: 300, child: panel),
                      ],
                    );
                  }
                  final maximumWidth = math.max(
                    _workPanelMinWidth,
                    constraints.maxWidth -
                        _workspaceMinWidth -
                        _resizeHandleWidth,
                  );
                  final panelWidth = _workPanelWidth
                      .clamp(_workPanelMinWidth, maximumWidth)
                      .toDouble();
                  return Row(
                    children: [
                      Expanded(child: table),
                      _VideoGenerationRightPanelResizeHandle(
                        key: const ValueKey(
                          'video-generation-work-panel-resize-handle',
                        ),
                        enabled: !_workPanelCollapsed,
                        onDrag: (delta) => setState(() {
                          _workPanelWidth = (panelWidth - delta)
                              .clamp(_workPanelMinWidth, maximumWidth)
                              .toDouble();
                        }),
                      ),
                      SizedBox(
                        width: _workPanelCollapsed
                            ? _workPanelCollapsedWidth
                            : panelWidth,
                        child: panel,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _syncRequestedScript(VideoGenerationController controller) {
    final scriptId = widget.scriptId;
    if (scriptId == null ||
        scriptId.isEmpty ||
        controller.value.selectedScriptId == scriptId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.selectScript(scriptId);
    });
  }

  void _scheduleLoginPrompt(
    VideoGenerationState state,
    VideoGenerationController controller,
  ) {
    if (controller.usesConfiguredVideoGenerationApi) return;
    if (_loginPromptShown ||
        _loginPromptOpen ||
        state.isLoadingEnvironment ||
        state.environment?.isReady != true ||
        state.identity != null ||
        state.loginAuthorizationStatus ==
            KlingLoginAuthorizationStatus.waiting) {
      return;
    }
    _loginPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_promptKlingLogin(controller));
    });
  }

  Future<void> _promptKlingLogin(VideoGenerationController controller) async {
    if (_loginPromptOpen) return;
    _loginPromptOpen = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要登录可灵账号'),
        content: const Text('视频生成功能需要连接可灵账号。点击“确定登录”后将打开浏览器，请在浏览器中完成授权登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            key: const ValueKey('confirm-kling-login'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定登录'),
          ),
        ],
      ),
    );
    _loginPromptOpen = false;
    if (confirmed == true && mounted) {
      await _runKlingLoginAuthorization(controller);
    }
  }

  Future<void> _runKlingLoginAuthorization(
    VideoGenerationController controller,
  ) async {
    final authorization = controller.startLoginAuthorization();
    unawaited(_showKlingLoginWaitDialog(controller));
    final result = await authorization;
    if (!mounted) return;
    if (_loginWaitDialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _loginWaitDialogOpen = false;
    }
    if (result == KlingLoginAuthorizationStatus.failed ||
        result == KlingLoginAuthorizationStatus.timedOut) {
      await _showKlingLoginResultDialog(controller);
    }
  }

  Future<void> _showKlingLoginWaitDialog(
    VideoGenerationController controller,
  ) async {
    _loginWaitDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<VideoGenerationState>(
        valueListenable: controller,
        builder: (context, state, _) => AlertDialog(
          title: const Text('等待可灵授权完成'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 16),
                Text(
                  state.loginAuthorizationMessage.isEmpty
                      ? '浏览器已打开。请在浏览器中完成登录授权，完成后软件会自动继续。'
                      : state.loginAuthorizationMessage,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.cancelLoginAuthorization();
                Navigator.pop(dialogContext);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: controller.reopenLoginBrowser,
              child: const Text('重新打开浏览器'),
            ),
          ],
        ),
      ),
    );
    _loginWaitDialogOpen = false;
  }

  Future<void> _showKlingLoginResultDialog(
    VideoGenerationController controller,
  ) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未检测到授权完成'),
        content: const Text(
          '如果浏览器授权页已关闭或没有完成登录，可以重新打开浏览器继续授权；也可以稍后在视频生成页点击“登录可灵”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新登录'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) {
      await _runKlingLoginAuthorization(controller);
    }
  }

  Future<void> _confirmBatch(
    BuildContext context,
    VideoGenerationState state,
    VideoGenerationController controller,
  ) async {
    final shots = controller.generationTargets();
    if (shots.isEmpty) return;
    if (controller.usesConfiguredVideoGenerationApi) {
      final config = controller.activeVideoGenerationApiConfig;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认批量生成'),
          content: Text(
            '镜头数：${shots.length}\n'
            'API：${config?.name ?? '视频生成 API'}\n'
            '模型：${controller.activeVideoGenerationApiModel}\n\n'
            '${controller.videoApiParameterSummary}\n\n'
            '任务会提交到当前默认视频生成 API。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-video-api-batch'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认生成'),
            ),
          ],
        ),
      );
      if (confirmed == true) await controller.generateAll();
      return;
    }
    final model = _selectedModel(state);
    if (model == null) return;
    final mappings = [
      for (final shot in shots)
        '${shot.shotNumber}号 ${controller.desiredDurationFor(shot).toStringAsFixed(1)}s→${const KlingDurationMatcher().forModel(desiredSeconds: controller.desiredDurationFor(shot), model: model)}s',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认批量付费生成'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('镜头数：${shots.length}'),
              if (controller.startEndFrameModeEnabled)
                const Text('首尾帧模式：已开启，手动配对按一条请求计费'),
              Text('模型：${model.model}'),
              Text('当前灵感值：${state.account?.availableCredits ?? '未知'}'),
              const SizedBox(height: 8),
              Text('时长映射：${mappings.join('，')}'),
              const SizedBox(height: 12),
              const Text('本次只确认这一批；失败、取消或超时不会自动重新扣费提交。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-paid-video-batch'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认付费生成'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.generateAll();
  }

  Future<void> _confirmShot(
    BuildContext context,
    VideoGenerationState state,
    VideoGenerationController controller,
    ScriptShot shot,
  ) async {
    if (controller.usesConfiguredVideoGenerationApi) {
      final config = controller.activeVideoGenerationApiConfig;
      final sequence = controller.actionSequenceFor(shot);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            sequence.hasDistinctTail
                ? '确认生成动作组 ${sequence.head.shotNumber}–${sequence.tail.shotNumber}'
                : '确认生成镜头 ${shot.shotNumber}',
          ),
          content: Text(
            'API：${config?.name ?? '视频生成 API'}\n'
            '模型：${controller.activeVideoGenerationApiModel}\n'
            '时长：${controller.desiredDurationFor(shot).toStringAsFixed(1)}s\n'
            '${sequence.hasDistinctTail ? '尾帧：镜头 ${sequence.tail.shotNumber}\n' : ''}\n'
            '${controller.videoApiParameterSummary}\n\n'
            '任务会提交到当前默认视频生成 API。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: ValueKey('confirm-video-api-shot-${shot.id}'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认生成'),
            ),
          ],
        ),
      );
      if (confirmed == true) await controller.generateShot(shot);
      return;
    }
    final model = _selectedModel(state);
    if (model == null) return;
    final duration = const KlingDurationMatcher().forModel(
      desiredSeconds: controller.desiredDurationFor(shot),
      model: model,
    );
    final sequence = controller.actionSequenceFor(shot);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          sequence.hasDistinctTail
              ? '确认生成动作组 ${sequence.head.shotNumber}–${sequence.tail.shotNumber}'
              : '确认生成镜头 ${shot.shotNumber}',
        ),
        content: Text(
          '模型：${model.model}\n时长：${controller.desiredDurationFor(shot).toStringAsFixed(1)}s → ${duration}s\n'
          '${sequence.hasDistinctTail ? '尾帧：镜头 ${sequence.tail.shotNumber}\n' : ''}'
          '当前灵感值：${state.account?.availableCredits ?? '未知'}\n\n'
          '该操作会消耗灵感值，失败或超时不会自动重新提交。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: ValueKey('confirm-paid-video-shot-${shot.id}'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认付费生成'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.generateShot(shot);
  }

  KlingModelSpec? _selectedModel(VideoGenerationState state) {
    final name = state.profile?.model;
    for (final model in state.identity?.imageToVideoModels ?? const []) {
      if (model.model == name) return model;
    }
    return null;
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.controller,
    required this.showScriptSelector,
    required this.taskFilter,
    required this.onTaskFilterChanged,
    required this.onLogin,
    required this.onGenerateAll,
  });

  final VideoGenerationState state;
  final VideoGenerationController controller;
  final bool showScriptSelector;
  final String taskFilter;
  final ValueChanged<String?> onTaskFilterChanged;
  final VoidCallback onLogin;
  final VoidCallback onGenerateAll;

  @override
  Widget build(BuildContext context) {
    final models =
        state.identity?.imageToVideoModels ?? const <KlingModelSpec>[];
    final selectedModel = models
        .where((model) => model.model == state.profile?.model)
        .firstOrNull;
    final selectedVideoApiAspectRatio = controller.selectedVideoApiAspectRatio;
    final selectedVideoApiResolution = controller.selectedVideoApiResolution;
    final videoApiResolutions = controller.videoApiResolutionsForAspect(
      selectedVideoApiAspectRatio,
    );
    final selectedVideoApiSteps = controller.selectedVideoApiSteps;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (showScriptSelector)
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const ValueKey('video-generation-script-selector'),
                  initialValue: state.selectedScriptId,
                  decoration: const InputDecoration(
                    labelText: '拍摄脚本',
                    isDense: true,
                  ),
                  items: [
                    for (final script in state.scripts)
                      DropdownMenuItem(
                        value: script.id,
                        child: Text(script.name),
                      ),
                  ],
                  onChanged: state.isBusy
                      ? null
                      : (value) {
                          if (value != null) controller.selectScript(value);
                        },
                ),
              ),
            if (showScriptSelector)
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const ValueKey('video-generation-history-filter'),
                  initialValue: taskFilter,
                  decoration: const InputDecoration(
                    labelText: '历史任务筛选',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部任务')),
                    DropdownMenuItem(value: 'completed', child: Text('已完成')),
                    DropdownMenuItem(value: 'active', child: Text('进行中/可恢复')),
                    DropdownMenuItem(value: 'failed', child: Text('失败/取消/超时')),
                  ],
                  onChanged: onTaskFilterChanged,
                ),
              ),
            _StatusChip(
              icon:
                  controller.usesConfiguredVideoGenerationApi ||
                      state.environment?.isReady == true
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              label: controller.usesConfiguredVideoGenerationApi
                  ? '视频 API'
                  : state.environment?.isReady == true
                  ? 'CLI ${state.environment!.klingVersion}'
                  : '环境未就绪',
            ),
            if (controller.startEndFrameModeEnabled)
              const _StatusChip(icon: Icons.science_outlined, label: '首尾帧模式'),
            if (!controller.usesConfiguredVideoGenerationApi)
              _StatusChip(
                icon: state.identity == null
                    ? Icons.login_rounded
                    : Icons.account_circle_outlined,
                label: state.identity == null
                    ? '未登录'
                    : '${state.account?.membershipDescription ?? '已登录'} · ${state.account?.availableCredits ?? 0} 灵感值',
              ),
            if (!controller.usesConfiguredVideoGenerationApi &&
                state.identity == null)
              OutlinedButton.icon(
                onPressed: state.isLoadingEnvironment ? null : onLogin,
                icon: const Icon(Icons.login_rounded),
                label: const Text('登录可灵'),
              ),
            if (models.isNotEmpty)
              SizedBox(
                width: 250,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const ValueKey('video-generation-model-selector'),
                  initialValue: state.profile?.model,
                  decoration: const InputDecoration(
                    labelText: '图生视频模型',
                    isDense: true,
                  ),
                  items: [
                    for (final model in models)
                      DropdownMenuItem(
                        value: model.model,
                        child: Text(
                          model.model,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: state.isBusy
                      ? null
                      : (value) {
                          if (value != null) controller.selectModel(value);
                        },
                ),
              ),
            if (controller.usesConfiguredVideoGenerationApi)
              _StatusChip(
                icon: Icons.smart_display_outlined,
                label: controller.activeVideoGenerationApiModel,
              ),
            if (controller.usesConfiguredVideoGenerationApi)
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey(
                    'video-api-aspect-ratio-$selectedVideoApiAspectRatio',
                  ),
                  initialValue: selectedVideoApiAspectRatio,
                  decoration: const InputDecoration(
                    labelText: '生成比例',
                    isDense: true,
                  ),
                  items: [
                    for (final aspectRatio in controller.videoApiAspectRatios)
                      DropdownMenuItem(
                        value: aspectRatio,
                        child: Text(aspectRatio),
                      ),
                  ],
                  onChanged: state.isBusy
                      ? null
                      : (value) {
                          if (value != null) {
                            controller.updateVideoApiAspectRatio(value);
                          }
                        },
                ),
              ),
            if (controller.usesConfiguredVideoGenerationApi)
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey(
                    'video-api-resolution-$selectedVideoApiAspectRatio-$selectedVideoApiResolution',
                  ),
                  initialValue:
                      videoApiResolutions.contains(selectedVideoApiResolution)
                      ? selectedVideoApiResolution
                      : videoApiResolutions.firstOrNull,
                  decoration: const InputDecoration(
                    labelText: '分辨率',
                    isDense: true,
                  ),
                  items: [
                    for (final resolution in videoApiResolutions)
                      DropdownMenuItem(
                        value: resolution,
                        child: Text(
                          resolution,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: state.isBusy
                      ? null
                      : (value) {
                          if (value != null) {
                            controller.updateVideoApiResolution(value);
                          }
                        },
                ),
              ),
            if (controller.usesConfiguredVideoGenerationApi)
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  key: ValueKey('video-api-steps-$selectedVideoApiSteps'),
                  initialValue: selectedVideoApiSteps,
                  decoration: const InputDecoration(
                    labelText: '步数',
                    isDense: true,
                  ),
                  items: [
                    for (var steps = 4; steps <= 30; steps++)
                      DropdownMenuItem(value: steps, child: Text('$steps')),
                  ],
                  onChanged: state.isBusy
                      ? null
                      : (value) {
                          if (value != null) {
                            controller.updateVideoApiSteps(value);
                          }
                        },
                ),
              ),
            if (selectedModel != null)
              for (final argument in selectedModel.arguments)
                if (argument.name != 'prompt' &&
                    argument.name != 'duration' &&
                    argument.allowedValues.isNotEmpty)
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue:
                          state.profile?.parameters[argument.name] ??
                          argument.defaultValue,
                      decoration: InputDecoration(
                        labelText: argument.name,
                        isDense: true,
                      ),
                      items: [
                        for (final value in argument.allowedValues)
                          DropdownMenuItem(value: value, child: Text(value)),
                      ],
                      onChanged: state.isBusy
                          ? null
                          : (value) {
                              if (value != null) {
                                controller.updateParameter(
                                  argument.name,
                                  value,
                                );
                              }
                            },
                    ),
                  ),
            OutlinedButton.icon(
              onPressed: controller.openOutputDirectory,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('打开视频目录'),
            ),
            FilledButton.icon(
              key: const ValueKey('generate-all-videos'),
              onPressed:
                  state.isBusy ||
                      (!controller.usesConfiguredVideoGenerationApi &&
                          state.identity == null)
                  ? null
                  : onGenerateAll,
              icon: const Icon(Icons.movie_creation_outlined),
              label: const Text('一键生成全部'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('export-timeline-xml'),
              onPressed: state.isBusy || !controller.canExportTimelineXml
                  ? null
                  : controller.exportTimelineXml,
              icon: const Icon(Icons.account_tree_outlined),
              label: const Text('导出时间线'),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoGenerationExternalWorkPanel extends ConsumerStatefulWidget {
  const VideoGenerationExternalWorkPanel({
    super.key,
    this.scriptId,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final String? scriptId;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  ConsumerState<VideoGenerationExternalWorkPanel> createState() =>
      _VideoGenerationExternalWorkPanelState();
}

class _VideoGenerationExternalWorkPanelState
    extends ConsumerState<VideoGenerationExternalWorkPanel> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(videoGenerationControllerProvider);
    _syncRequestedScript(controller);
    return ValueListenableBuilder<VideoGenerationState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.scripts.isEmpty) {
          return const Center(child: Text('还没有可生成视频的拍摄脚本'));
        }
        return _WorkManagementPanel(
          state: state,
          controller: controller,
          collapsed: widget.collapsed,
          onToggleCollapsed: widget.onToggleCollapsed,
        );
      },
    );
  }

  void _syncRequestedScript(VideoGenerationController controller) {
    final scriptId = widget.scriptId;
    if (scriptId == null ||
        scriptId.isEmpty ||
        controller.value.selectedScriptId == scriptId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.selectScript(scriptId);
    });
  }
}

class _VideoGenerationRightPanelResizeHandle extends StatelessWidget {
  const _VideoGenerationRightPanelResizeHandle({
    super.key,
    required this.enabled,
    required this.onDrag,
  });

  final bool enabled;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: enabled
            ? (details) => onDrag(details.delta.dx)
            : null,
        child: SizedBox(
          width: _VideoGenerationWorkspaceState._resizeHandleWidth,
          child: Center(
            child: Container(
              width: 1,
              height: double.infinity,
              color: scheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkManagementPanel extends StatelessWidget {
  const _WorkManagementPanel({
    required this.state,
    required this.controller,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final VideoGenerationState state;
  final VideoGenerationController controller;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final groups = _orderedWorkVideoShotGroups(state);
    final workCount = groups.fold<int>(
      0,
      (total, group) => total + group.entries.length,
    );
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      key: const ValueKey('video-generation-work-management-panel'),
      decoration: BoxDecoration(color: colorScheme.surface),
      child: collapsed
          ? Column(
              children: [
                const SizedBox(height: 8),
                IconButton(
                  key: const ValueKey(
                    'expand-video-generation-work-management-panel',
                  ),
                  tooltip: '展开作品管理',
                  onPressed: onToggleCollapsed,
                  icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 1,
                    child: Center(
                      child: Text(
                        '作品管理',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '作品管理',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '$workCount 个作品',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey(
                          'collapse-video-generation-work-management-panel',
                        ),
                        tooltip: '折叠作品管理',
                        onPressed: onToggleCollapsed,
                        icon: const Icon(
                          Icons.keyboard_double_arrow_right_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: groups.isEmpty
                      ? const Center(child: Text('该脚本暂无生成作品'))
                      : ListView.separated(
                          key: const ValueKey(
                            'work-management-generated-shot-group-list',
                          ),
                          padding: const EdgeInsets.all(12),
                          itemCount: groups.length,
                          separatorBuilder: (context, _) => Divider(
                            height: 17,
                            thickness: 1,
                            color: colorScheme.outlineVariant.withValues(
                              alpha: 0.72,
                            ),
                          ),
                          itemBuilder: (context, index) {
                            final group = groups[index];
                            return _WorkManagementShotGroupTile(
                              key: ValueKey(
                                'work-management-shot-group-${group.shot.id}',
                              ),
                              group: group,
                              controller: controller,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _WorkManagementShotGroupTile extends StatelessWidget {
  const _WorkManagementShotGroupTile({
    super.key,
    required this.group,
    required this.controller,
  });

  final _WorkVideoShotGroup group;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final latest = group.entries.last;
    final entries = group.entries.reversed.toList(growable: false);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        key: PageStorageKey('work-management-shot-group-tile-${group.shot.id}'),
        initiallyExpanded: _shouldExpandWorkGroup(group, controller),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        title: Text(
          '镜头 ${group.shot.shotNumber}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${group.entries.length} 个版本 · 最新：${latest.task.status.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          Column(
            key: ValueKey(
              'work-management-shot-group-version-list-${group.shot.id}',
            ),
            children: [
              for (var index = 0; index < entries.length; index += 1) ...[
                _WorkManagementVideoItem(
                  key: ValueKey(
                    'work-management-video-task-${entries[index].task.id}',
                  ),
                  entry: entries[index],
                  controller: controller,
                ),
                if (index + 1 < entries.length) const SizedBox(height: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkManagementVideoItem extends StatelessWidget {
  const _WorkManagementVideoItem({
    super.key,
    required this.entry,
    required this.controller,
  });

  final _WorkVideoTaskEntry entry;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final task = entry.task;
    final shot = entry.shot;
    final file = controller.generatedVideoFileFor(task);
    final hasLocalVideo = file.existsSync();
    final isActive = _isActiveVideoTask(task);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return GestureDetector(
      key: ValueKey('work-management-video-context-menu-${task.id}'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details, task: task, file: file),
      child: Material(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '镜头 ${shot.shotNumber} · 版本 ${entry.version}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    task.status.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: hasLocalVideo
                    ? _InlineGeneratedVideoPlayer(
                        key: ValueKey(
                          'work-management-generated-video-player-${task.id}',
                        ),
                        file: file,
                        onFullscreen: () => _showFullscreenGeneratedVideo(
                          context,
                          file,
                          title:
                              '镜头 ${shot.shotNumber} · 作品版本 ${entry.version}',
                        ),
                      )
                    : _GeneratedVideoPlaceholder(
                        icon: isActive
                            ? Icons.hourglass_top_rounded
                            : Icons.videocam_off_rounded,
                        message: isActive
                            ? _activeVideoTaskLabel(task.status)
                            : _missingWorkVideoMessage(task),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                '${task.model} · ${task.durationSeconds}s · '
                '${task.createdAt.toLocal()}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
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
    TapDownDetails details, {
    required VideoGenerationTask task,
    required File file,
  }) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(details.globalPosition, details.globalPosition),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<_WorkVideoMenuAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: _WorkVideoMenuAction.openPath,
          enabled: file.existsSync(),
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.folder_open_rounded),
            title: Text('打开路径'),
          ),
        ),
        PopupMenuItem(
          value: _WorkVideoMenuAction.saveAs,
          enabled: file.existsSync(),
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.save_as_rounded),
            title: Text('另存为'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _WorkVideoMenuAction.delete,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('删除'),
          ),
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _WorkVideoMenuAction.openPath:
        await controller.revealGeneratedVideo(task);
      case _WorkVideoMenuAction.saveAs:
        await _saveAs(context, task, file);
      case _WorkVideoMenuAction.delete:
        await _confirmDelete(context, task);
    }
  }

  Future<void> _saveAs(
    BuildContext context,
    VideoGenerationTask task,
    File source,
  ) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'MP4 视频', extensions: ['mp4']),
      ],
      initialDirectory: source.parent.path,
      suggestedName: source.uri.pathSegments.isEmpty
          ? '生成视频.mp4'
          : source.uri.pathSegments.last,
      confirmButtonText: '保存',
      canCreateDirectories: true,
    );
    if (location == null) return;
    final saved = await controller.saveGeneratedVideoCopy(task, location.path);
    if (saved != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('视频已保存到：${saved.path}')));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    VideoGenerationTask task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除该作品？'),
        content: const Text('本地视频和对应任务记录会一并删除，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteTask(task);
  }
}

enum _WorkVideoMenuAction { openPath, saveAs, delete }

class _WorkVideoTaskEntry {
  const _WorkVideoTaskEntry({
    required this.shot,
    required this.task,
    required this.version,
  });

  final ScriptShot shot;
  final VideoGenerationTask task;
  final int version;
}

class _WorkVideoShotGroup {
  const _WorkVideoShotGroup({required this.shot, required this.entries});

  final ScriptShot shot;
  final List<_WorkVideoTaskEntry> entries;
}

List<_WorkVideoShotGroup> _orderedWorkVideoShotGroups(
  VideoGenerationState state,
) {
  final selectedScriptId = state.selectedScriptId;
  final groups = <_WorkVideoShotGroup>[];
  for (final shot in state.shots) {
    final tasks =
        state.tasks
            .where(
              (task) =>
                  task.shotId == shot.id &&
                  (selectedScriptId.isEmpty ||
                      task.scriptId == selectedScriptId),
            )
            .toList()
          ..sort((first, second) {
            final byCreatedAt = first.createdAt.compareTo(second.createdAt);
            return byCreatedAt != 0
                ? byCreatedAt
                : first.id.compareTo(second.id);
          });
    if (tasks.isEmpty) continue;
    final entries = <_WorkVideoTaskEntry>[];
    for (var index = 0; index < tasks.length; index += 1) {
      entries.add(
        _WorkVideoTaskEntry(shot: shot, task: tasks[index], version: index + 1),
      );
    }
    groups.add(_WorkVideoShotGroup(shot: shot, entries: entries));
  }
  return groups;
}

bool _shouldExpandWorkGroup(
  _WorkVideoShotGroup group,
  VideoGenerationController controller,
) {
  final latest = group.entries.last.task;
  if (_isActiveVideoTask(latest)) return true;
  return controller.generatedVideoFileFor(latest).existsSync();
}

String _missingWorkVideoMessage(VideoGenerationTask task) {
  if (task.localPath.trim().isEmpty) return '状态：${task.status.name}\n暂无本地视频';
  return '状态：${task.status.name}\n本地视频不可用';
}

class _GenerationTable extends StatelessWidget {
  const _GenerationTable({
    required this.state,
    required this.controller,
    required this.onGenerateShot,
  });

  final VideoGenerationState state;
  final VideoGenerationController controller;
  final ValueChanged<ScriptShot> onGenerateShot;

  @override
  Widget build(BuildContext context) {
    final groups = ScriptShotGroup.group(state.shots);
    return Scrollbar(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1670,
            child: Table(
              key: const ValueKey('video-generation-five-column-table'),
              border: TableBorder.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              columnWidths: const {
                0: FixedColumnWidth(320),
                1: FixedColumnWidth(320),
                2: FixedColumnWidth(110),
                3: FixedColumnWidth(380),
                4: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                TableRow(
                  children: [
                    const _HeaderCell('原视频帧'),
                    const _HeaderCell('复刻分镜图'),
                    const _HeaderCell('时长'),
                    const _HeaderCell('生成视频'),
                    const _HeaderCell('生成提示词'),
                  ],
                ),
                for (final group in groups)
                  TableRow(
                    children: [
                      _OriginalVideoCell(group: group, controller: controller),
                      _SourceImageCell(group: group, controller: controller),
                      _GenerationDurationCell(
                        shot: group.shots.first,
                        controller: controller,
                      ),
                      _GeneratedVideoCell(
                        shot: group.shots.first,
                        controller: controller,
                        enabled: !state.isGeneratingAll,
                        onGenerate: () => onGenerateShot(group.shots.first),
                      ),
                      _PromptCell(
                        shot: group.shots.first,
                        draft: state.drafts[group.shots.first.id],
                        controller: controller,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.all(12),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class _GenerationDurationCell extends StatefulWidget {
  const _GenerationDurationCell({required this.shot, required this.controller});

  final ScriptShot shot;
  final VideoGenerationController controller;

  @override
  State<_GenerationDurationCell> createState() =>
      _GenerationDurationCellState();
}

class _GenerationDurationCellState extends State<_GenerationDurationCell> {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;

  double get _duration => widget.controller.desiredDurationFor(widget.shot);

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _editableSeconds(_duration));
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _GenerationDurationCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_focusNode.hasFocus) return;
    final text = _editableSeconds(_duration);
    if (_textController.text != text) {
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _textController.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final seconds = double.tryParse(
      _textController.text.trim().replaceAll('秒', ''),
    );
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      _textController.text = _editableSeconds(_duration);
      return;
    }
    widget.controller.updateDesiredDurationFor(widget.shot, seconds);
  }

  @override
  Widget build(BuildContext context) => _Cell(
    child: Tooltip(
      message: '默认按画面内容自动判断；手动修改后，生成提示词中的秒数会同步更新。',
      child: TextField(
        key: ValueKey('video-duration-${widget.shot.id}'),
        controller: _textController,
        focusNode: _focusNode,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {
          _commit();
          _focusNode.unfocus();
        },
        decoration: const InputDecoration(
          isDense: true,
          labelText: '视频时长',
          suffixText: '秒',
          helperText: '默认可直接使用',
        ),
      ),
    ),
  );
}

String _editableSeconds(double seconds) => seconds == seconds.roundToDouble()
    ? '${seconds.toInt()}'
    : seconds.toStringAsFixed(1);

class _VideoShotCellLayout extends StatelessWidget {
  const _VideoShotCellLayout({
    required this.shot,
    required this.slotName,
    required this.child,
    this.title,
  });

  final ScriptShot shot;
  final String slotName;
  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        key: ValueKey('video-$slotName-shot-title-${shot.id}'),
        height: 20,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title ?? '镜头 ${shot.shotNumber}'),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        key: ValueKey('video-$slotName-media-${shot.id}'),
        width: double.infinity,
        child: child,
      ),
    ],
  );
}

class _OriginalVideoCell extends StatelessWidget {
  const _OriginalVideoCell({required this.group, required this.controller});

  final ScriptShotGroup group;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final shot = group.shots.first;
    final range = controller.sourcePreviewFor(
      shot,
      endShot: group.shots.length > 1 ? group.shots.last : null,
    );
    final thumbnail = range?.thumbnailFile;
    void openPreview() {
      if (range == null) return;
      showDialog<void>(
        context: context,
        builder: (_) => _SourceRangePreviewDialog(range: range),
      );
    }

    return _Cell(
      child: _VideoShotCellLayout(
        shot: shot,
        slotName: 'original',
        title: group.rangeLabel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VideoGroupFrameStrip(
              group: group,
              keyPrefix: 'original',
              emptyLabel: '原视频帧暂不可用',
              fileForShot: controller.videoFrameFileForShot,
              onOpen: (shot) => _showScriptShotGroupImageGallery(
                context,
                group: group,
                initialShotId: shot.id,
                label: '原视频帧',
                fileForShot: controller.videoFrameFileForShot,
              ),
            ),
            if (range != null) ...[
              const SizedBox(height: 6),
              Text(
                'I ${_formatDuration(range.inPoint)}  ·  O ${_formatDuration(range.outPoint)}  ·  ${_formatDuration(range.duration)}',
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: range == null ? null : openPreview,
              icon: const Icon(Icons.play_circle_outline_rounded),
              label: Text(
                thumbnail?.existsSync() == true ? '按 IO 点预览' : '预览源视频',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceImageCell extends StatelessWidget {
  const _SourceImageCell({required this.group, required this.controller});

  final ScriptShotGroup group;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final shot = group.shots.first;
    final completedCount = group.shots
        .where((item) => controller.replicatedImageFileForShot(item) != null)
        .length;
    return _Cell(
      child: _VideoShotCellLayout(
        shot: shot,
        slotName: 'source-image',
        title: group.rangeLabel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _VideoGroupFrameStrip(
              group: group,
              keyPrefix: 'replica',
              emptyLabel: '待复刻分镜',
              fileForShot: controller.replicatedImageFileForShot,
              onOpen: (shot) => _showScriptShotGroupImageGallery(
                context,
                group: group,
                initialShotId: shot.id,
                label: '复刻分镜图',
                fileForShot: controller.replicatedImageFileForShot,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              completedCount == group.shots.length
                  ? '来源：复刻分镜图 · 已完成'
                  : '来源：复刻分镜图 · $completedCount/${group.shots.length}',
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoGroupFrameStrip extends StatelessWidget {
  const _VideoGroupFrameStrip({
    required this.group,
    required this.keyPrefix,
    required this.emptyLabel,
    required this.fileForShot,
    required this.onOpen,
  });

  final ScriptShotGroup group;
  final String keyPrefix;
  final String emptyLabel;
  final File? Function(ScriptShot shot) fileForShot;
  final ValueChanged<ScriptShot> onOpen;

  @override
  Widget build(BuildContext context) {
    final shots = group.shots.take(3).toList(growable: false);
    final availableShots = group.shots
        .where((shot) => fileForShot(shot)?.existsSync() == true)
        .toList(growable: false);
    return Tooltip(
      message: '${group.rangeLabel} · $emptyLabel',
      child: InkWell(
        key: ValueKey(
          'video-generation-$keyPrefix-range-${group.startNumber}-${group.endNumber}',
        ),
        onTap: availableShots.isEmpty
            ? null
            : () => onOpen(availableShots.first),
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 150,
          child: Row(
            children: [
              for (final shot in shots)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _VideoGroupFrameThumbnail(
                      file: fileForShot(shot),
                      label: shot.shotNumber.toString(),
                      emptyLabel: emptyLabel,
                      onTap: () => onOpen(shot),
                    ),
                  ),
                ),
              if (group.shots.length > shots.length)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text('+${group.shots.length - shots.length}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoGroupFrameThumbnail extends StatelessWidget {
  const _VideoGroupFrameThumbnail({
    required this.file,
    required this.label,
    required this.emptyLabel,
    required this.onTap,
  });

  final File? file;
  final String label;
  final String emptyLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasFile = file?.existsSync() == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: hasFile ? onTap : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: hasFile
                  ? Image.file(
                      file!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Center(child: Text('$emptyLabel加载失败')),
                    )
                  : Center(
                      child: Text(
                        emptyLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
            ),
            Positioned(
              left: 5,
              bottom: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.66),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GeneratedVideoCell extends StatelessWidget {
  const _GeneratedVideoCell({
    required this.shot,
    required this.controller,
    required this.enabled,
    required this.onGenerate,
  });

  final ScriptShot shot;
  final VideoGenerationController controller;
  final bool enabled;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final owner = controller.generationOwnerFor(shot);
    final sequence = controller.actionSequenceFor(shot);
    final isGroupContinuation = owner.id != shot.id;
    final tasks = controller.tasksForShot(owner.id);
    final latest = tasks.where(_shouldKeepVideoTaskInCell).firstOrNull;
    final localFile = latest == null
        ? null
        : controller.generatedVideoFileFor(latest);
    final hasLocalVideo = localFile?.existsSync() == true;
    final canGenerate = controller.canGenerateShot(owner);
    final isGenerating = latest != null && _isActiveVideoTask(latest);
    return _Cell(
      child: _VideoShotCellLayout(
        shot: shot,
        slotName: 'generated',
        child: SizedBox(
          height: 214,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (isGroupContinuation)
                _GeneratedVideoPlaceholder(
                  icon: Icons.join_inner_rounded,
                  message:
                      '已并入镜头 ${sequence.head.shotNumber}–${sequence.tail.shotNumber} 的连续动作组\n由镜头 ${sequence.head.shotNumber} 统一生成',
                )
              else if (isGenerating)
                _GeneratingVideoProgress(
                  key: ValueKey('generated-video-progress-${latest.id}'),
                  task: latest,
                )
              else if (hasLocalVideo)
                _InlineGeneratedVideoPlayer(
                  key: ValueKey('generated-video-player-${latest!.id}'),
                  file: localFile!,
                  onFullscreen: () => _showFullscreenGeneratedVideo(
                    context,
                    localFile,
                    title: '镜头 ${shot.shotNumber} · 生成视频',
                  ),
                )
              else
                _GeneratedVideoPlaceholder(
                  icon: latest == null
                      ? Icons.movie_creation_outlined
                      : Icons.hourglass_top_rounded,
                  message: latest == null ? '尚未生成' : '状态：${latest.status.name}',
                  action: latest == null
                      ? FilledButton.icon(
                          key: ValueKey(
                            'generated-video-generate-button-${shot.id}',
                          ),
                          onPressed: enabled && canGenerate ? onGenerate : null,
                          icon: const Icon(Icons.movie_creation_outlined),
                          label: const Text('生成视频'),
                        )
                      : null,
                ),
              if (!isGroupContinuation &&
                  latest?.usedWatermarkedFallback == true)
                const Positioned(
                  left: 8,
                  bottom: 8,
                  child: _VideoNotice('已保存带水印结果'),
                ),
              if (!isGroupContinuation &&
                  !isGenerating &&
                  latest?.errorMessage.isNotEmpty == true)
                Positioned(
                  left: 8,
                  right: 52,
                  bottom: 8,
                  child: _VideoNotice(latest!.errorMessage, isError: true),
                ),
              if (latest != null || isGroupContinuation)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _GeneratedVideoMenu(
                    key: ValueKey('generated-video-menu-${shot.id}'),
                    enabled: enabled,
                    canGenerate: canGenerate,
                    hasLocalVideo: hasLocalVideo && !isGroupContinuation,
                    canCancel: !isGroupContinuation && isGenerating,
                    canRetryDownload:
                        !isGroupContinuation &&
                        latest?.status == VideoGenerationTaskStatus.failed &&
                        (latest!.resultWithoutWatermarkUrl.isNotEmpty ||
                            latest.resultUrl.isNotEmpty),
                    canContinueQuery:
                        !isGroupContinuation &&
                        latest?.status == VideoGenerationTaskStatus.timedOut &&
                        latest!.generationId.isNotEmpty,
                    hasHistory: tasks.isNotEmpty,
                    hasGenerated: latest != null,
                    onSelected: (action) async {
                      switch (action) {
                        case 'generate':
                          onGenerate();
                          break;
                        case 'fullscreen':
                          if (localFile != null) {
                            await _showFullscreenGeneratedVideo(
                              context,
                              localFile,
                              title: '镜头 ${owner.shotNumber} · 生成视频',
                            );
                          }
                          break;
                        case 'download':
                          if (latest != null) {
                            await _download(context, latest);
                          }
                          break;
                        case 'retry':
                          if (latest != null) {
                            await controller.retryDownload(latest);
                          }
                          break;
                        case 'continue_query':
                          if (latest != null) {
                            await controller.resumeTaskQuery(latest);
                          }
                          break;
                        case 'cancel':
                          if (latest != null) {
                            await controller.cancelTask(latest);
                          }
                          break;
                        case 'rename':
                          if (latest != null) await _rename(context, latest);
                          break;
                        case 'delete':
                          if (latest != null) await _delete(context, latest);
                          break;
                        case 'history':
                          await _history(context, tasks);
                          break;
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context, VideoGenerationTask task) async {
    final source = File(task.localPath);
    if (!source.existsSync()) return;
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'MP4 视频', extensions: ['mp4']),
      ],
      initialDirectory: source.parent.path,
      suggestedName: source.uri.pathSegments.isEmpty
          ? '生成视频.mp4'
          : source.uri.pathSegments.last,
      confirmButtonText: '保存',
      canCreateDirectories: true,
    );
    if (location == null) return;
    final saved = await controller.saveGeneratedVideoCopy(task, location.path);
    if (saved != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('视频已保存到：${saved.path}')));
    }
  }

  Future<void> _history(
    BuildContext context,
    List<VideoGenerationTask> tasks,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('镜头 ${controller.generationOwnerFor(shot).shotNumber} 历史版本'),
      content: SizedBox(
        width: 720,
        height: 520,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 340,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.18,
          ),
          itemCount: tasks.length,
          itemBuilder: (context, index) {
            final task = tasks[index];
            final file = controller.generatedVideoFileFor(task);
            return _HistoryVideoVersionCard(
              key: ValueKey('generated-video-history-card-${task.id}'),
              task: task,
              file: file,
              index: index,
              onOpen: file.existsSync()
                  ? () => _showFullscreenGeneratedVideo(
                      context,
                      file,
                      title: '镜头 ${shot.shotNumber} · 历史版本 ${index + 1}',
                    )
                  : null,
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _rename(BuildContext context, VideoGenerationTask task) async {
    final textController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名生成视频'),
        content: TextField(controller: textController, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (name != null) await controller.renameTask(task, name);
  }

  Future<void> _delete(BuildContext context, VideoGenerationTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除该生成版本？'),
        content: const Text('本地视频和任务历史会一并删除，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteTask(task);
  }
}

class _GeneratingVideoProgress extends StatelessWidget {
  const _GeneratingVideoProgress({super.key, required this.task});

  final VideoGenerationTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Icon(
                    Icons.hourglass_top_rounded,
                    color: scheme.onPrimaryContainer,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _activeVideoTaskLabel(task.status),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '视频生成通常需要几分钟，请保持页面打开',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GeneratedVideoPlaceholder extends StatelessWidget {
  const _GeneratedVideoPlaceholder({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

class _HistoryVideoVersionCard extends StatefulWidget {
  const _HistoryVideoVersionCard({
    super.key,
    required this.task,
    required this.file,
    required this.index,
    required this.onOpen,
  });

  final VideoGenerationTask task;
  final File file;
  final int index;
  final VoidCallback? onOpen;

  @override
  State<_HistoryVideoVersionCard> createState() =>
      _HistoryVideoVersionCardState();
}

class _HistoryVideoVersionCardState extends State<_HistoryVideoVersionCard> {
  late final Player _player;
  late final VideoController _videoController;
  var _thumbnailError = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    if (widget.file.existsSync()) unawaited(_openThumbnail());
  }

  Future<void> _openThumbnail() async {
    try {
      await _player.open(Media(widget.file.path), play: false);
      if (mounted) setState(() => _thumbnailError = '');
    } catch (error) {
      if (mounted) setState(() => _thumbnailError = '缩略图加载失败');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasFile = widget.file.existsSync();
    final canOpen = hasFile && widget.onOpen != null;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: canOpen ? widget.onOpen : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasFile && _thumbnailError.isEmpty)
                    Video(controller: _videoController, controls: null)
                  else
                    ColoredBox(
                      color: Colors.black.withValues(alpha: 0.82),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              hasFile
                                  ? Icons.video_file_rounded
                                  : Icons.videocam_off_rounded,
                              color: Colors.white70,
                              size: 34,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              hasFile ? _thumbnailError : '本地视频不可用',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (canOpen)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(7),
                          child: Icon(
                            Icons.fullscreen_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '版本 ${widget.index + 1} · ${widget.task.model} · '
                    '${widget.task.durationSeconds}s',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${widget.task.createdAt.toLocal()} · '
                    '${widget.task.status.name}'
                    '${widget.task.tailImagePath.isEmpty ? '' : ' · 首尾帧'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
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

class _InlineGeneratedVideoPlayer extends StatefulWidget {
  const _InlineGeneratedVideoPlayer({
    super.key,
    required this.file,
    required this.onFullscreen,
  });

  final File file;
  final VoidCallback onFullscreen;

  @override
  State<_InlineGeneratedVideoPlayer> createState() =>
      _InlineGeneratedVideoPlayerState();
}

class _InlineGeneratedVideoPlayerState
    extends State<_InlineGeneratedVideoPlayer> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<bool>? _playingSubscription;
  var _playing = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant _InlineGeneratedVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.file.path), play: false);
      if (mounted) setState(() => _error = '');
    } catch (error) {
      if (mounted) setState(() => _error = '视频加载失败：$error');
    }
  }

  Future<void> _toggle() => _playing ? _player.pause() : _player.play();

  @override
  void dispose() {
    unawaited(_playingSubscription?.cancel());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_error.isEmpty)
            Video(controller: _videoController, controls: null)
          else
            Center(
              child: Text(
                _error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          if (_error.isEmpty)
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('generated-video-play-${widget.file.path}'),
                onTap: _toggle,
                child: Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: _playing ? 0 : 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.64),
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              key: ValueKey('generated-video-fullscreen-${widget.file.path}'),
              tooltip: '全屏播放',
              onPressed: widget.onFullscreen,
              icon: const Icon(Icons.fullscreen_rounded),
            ),
          ),
        ],
      ),
    ),
  );
}

bool _isActiveVideoTask(VideoGenerationTask task) => switch (task.status) {
  VideoGenerationTaskStatus.draft ||
  VideoGenerationTaskStatus.submitting ||
  VideoGenerationTaskStatus.queued ||
  VideoGenerationTaskStatus.running => true,
  _ => false,
};

bool _shouldKeepVideoTaskInCell(VideoGenerationTask task) =>
    _isActiveVideoTask(task) ||
    task.status == VideoGenerationTaskStatus.completed ||
    task.status == VideoGenerationTaskStatus.partialCompleted ||
    task.status == VideoGenerationTaskStatus.failed ||
    task.status == VideoGenerationTaskStatus.timedOut;

String _activeVideoTaskLabel(VideoGenerationTaskStatus status) =>
    switch (status) {
      VideoGenerationTaskStatus.draft => '排队等待中',
      VideoGenerationTaskStatus.submitting => '正在提交生成任务',
      VideoGenerationTaskStatus.queued => '排队等待中',
      VideoGenerationTaskStatus.running => '视频生成中',
      _ => '视频生成中',
    };

class _VideoNotice extends StatelessWidget {
  const _VideoNotice(this.message, {this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Colors.black.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isError
              ? Theme.of(context).colorScheme.onErrorContainer
              : Colors.white,
          fontSize: 11,
        ),
      ),
    ),
  );
}

class _GeneratedVideoMenu extends StatelessWidget {
  const _GeneratedVideoMenu({
    super.key,
    required this.enabled,
    required this.canGenerate,
    required this.hasLocalVideo,
    required this.canCancel,
    required this.canRetryDownload,
    required this.canContinueQuery,
    required this.hasHistory,
    required this.hasGenerated,
    required this.onSelected,
  });

  final bool enabled;
  final bool canGenerate;
  final bool hasLocalVideo;
  final bool canCancel;
  final bool canRetryDownload;
  final bool canContinueQuery;
  final bool hasHistory;
  final bool hasGenerated;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.72),
    shape: const CircleBorder(),
    elevation: 4,
    child: PopupMenuButton<String>(
      tooltip: '视频操作',
      enabled: enabled,
      onSelected: onSelected,
      icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'generate',
          enabled: canGenerate,
          child: Text(hasGenerated ? '重新生成' : '生成视频'),
        ),
        if (hasLocalVideo)
          const PopupMenuItem(value: 'fullscreen', child: Text('全屏播放')),
        if (hasLocalVideo)
          const PopupMenuItem(value: 'download', child: Text('下载/另存为')),
        if (canCancel)
          const PopupMenuItem(value: 'cancel', child: Text('取消生成')),
        if (canRetryDownload)
          const PopupMenuItem(value: 'retry', child: Text('重新下载')),
        if (canContinueQuery)
          const PopupMenuItem(value: 'continue_query', child: Text('继续查询')),
        if (hasLocalVideo) ...[
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
        if (hasHistory)
          const PopupMenuItem(value: 'history', child: Text('历史版本')),
      ],
    ),
  );
}

class _FullscreenGeneratedVideo extends StatefulWidget {
  const _FullscreenGeneratedVideo({required this.file, required this.title});

  final File file;
  final String title;

  @override
  State<_FullscreenGeneratedVideo> createState() =>
      _FullscreenGeneratedVideoState();
}

class _FullscreenGeneratedVideoState extends State<_FullscreenGeneratedVideo> {
  late final Player _player;
  late final VideoController _videoController;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.file.path), play: true);
    } catch (error) {
      if (mounted) setState(() => _error = '视频播放失败：$error');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: _error.isEmpty
                    ? Video(controller: _videoController)
                    : Text(_error, style: const TextStyle(color: Colors.white)),
              ),
            ),
            Positioned(
              left: 16,
              top: 12,
              child: Text(
                widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            Positioned(
              right: 16,
              top: 8,
              child: IconButton.filledTonal(
                key: const ValueKey('close-generated-video-fullscreen'),
                tooltip: '退出全屏',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.fullscreen_exit_rounded),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showFullscreenGeneratedVideo(
  BuildContext context,
  File file, {
  required String title,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black,
  builder: (_) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: _FullscreenGeneratedVideo(file: file, title: title),
  ),
);

class _PromptCell extends StatefulWidget {
  const _PromptCell({
    required this.shot,
    required this.draft,
    required this.controller,
  });

  final ScriptShot shot;
  final VideoGenerationDraft? draft;
  final VideoGenerationController controller;

  @override
  State<_PromptCell> createState() => _PromptCellState();
}

class _PromptCellState extends State<_PromptCell> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.draft?.selectedPrompt ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _PromptCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prompt = widget.draft?.selectedPrompt ?? '';
    if (_textController.text == prompt) return;
    _textController.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    if (draft == null) return const _Cell(child: Text('提示词尚未准备'));
    return _Cell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<VideoPromptMode>(
            segments: const [
              ButtonSegment(
                value: VideoPromptMode.klingOptimized,
                label: Text('可灵'),
              ),
              ButtonSegment(
                value: VideoPromptMode.h3Optimized,
                label: Text('H3'),
              ),
              ButtonSegment(value: VideoPromptMode.original, label: Text('即梦')),
              ButtonSegment(value: VideoPromptMode.edited, label: Text('手工稿')),
            ],
            selected: {draft.promptMode},
            onSelectionChanged: (selection) => widget.controller
                .updatePromptMode(widget.shot.id, selection.first),
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('video-prompt-${widget.shot.id}'),
            controller: _textController,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              helperText: '编辑后自动切换为手工稿；历史提交文本不会改变',
            ),
            onChanged: (value) =>
                widget.controller.updateEditedPrompt(widget.shot.id, value),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(12), child: child);
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Chip(avatar: Icon(icon, size: 18), label: Text(label));
}

class _SourceRangePreviewDialog extends StatefulWidget {
  const _SourceRangePreviewDialog({required this.range});

  final SourceVideoPreviewRange range;

  @override
  State<_SourceRangePreviewDialog> createState() =>
      _SourceRangePreviewDialogState();
}

class _SourceRangePreviewDialogState extends State<_SourceRangePreviewDialog> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Duration _position = Duration.zero;
  var _playing = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _positionSubscription = _player.stream.position.listen(_handlePosition);
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(
        Media(
          widget.range.sourceVideo.path,
          start: widget.range.inPoint,
          end: widget.range.outPoint,
        ),
        play: false,
      );
      if (mounted) setState(() => _position = widget.range.inPoint);
      await _player.play();
    } catch (error) {
      if (mounted) setState(() => _error = '源视频预览失败：$error');
    }
  }

  void _handlePosition(Duration position) {
    if (position >= widget.range.outPoint) {
      unawaited(_player.pause());
      unawaited(_player.seek(widget.range.inPoint));
      if (mounted) setState(() => _position = widget.range.inPoint);
      return;
    }
    if (mounted) setState(() => _position = position);
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (_position < widget.range.inPoint ||
        _position >= widget.range.outPoint) {
      await _player.seek(widget.range.inPoint);
    }
    await _player.play();
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = (_position - widget.range.inPoint).inMilliseconds.clamp(
      0,
      widget.range.duration.inMilliseconds,
    );
    final progress = widget.range.duration.inMilliseconds == 0
        ? 0.0
        : elapsed / widget.range.duration.inMilliseconds;
    return AlertDialog(
      title: const Text('原视频 IO 点预览'),
      content: SizedBox(
        width: 820,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _error.isEmpty
                  ? Video(controller: _videoController, controls: null)
                  : Center(child: Text(_error)),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _error.isEmpty ? _togglePlayback : null,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'I ${_formatDuration(widget.range.inPoint)}  ·  '
                  '${_formatDuration(_position)}  ·  '
                  'O ${_formatDuration(widget.range.outPoint)}',
                ),
                const Spacer(),
                const Text('复用源文件，不产生片段文件'),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _SourceGalleryItem {
  const _SourceGalleryItem({
    required this.shotId,
    required this.shotNumber,
    required this.file,
    required this.label,
  });

  final String shotId;
  final int shotNumber;
  final File file;
  final String label;
}

Future<void> _showScriptShotGroupImageGallery(
  BuildContext context, {
  required ScriptShotGroup group,
  required String initialShotId,
  required String label,
  required File? Function(ScriptShot shot) fileForShot,
}) {
  final items = <_SourceGalleryItem>[];
  for (final shot in group.shots) {
    final file = fileForShot(shot);
    if (file == null) continue;
    items.add(
      _SourceGalleryItem(
        shotId: shot.id,
        shotNumber: shot.shotNumber,
        file: file,
        label: label,
      ),
    );
  }
  if (items.isEmpty) return Future<void>.value();
  final initialIndex = items.indexWhere((item) => item.shotId == initialShotId);
  return showFullscreenZoomGallery<_SourceGalleryItem>(
    context: context,
    items: items,
    initialIndex: initialIndex < 0 ? 0 : initialIndex,
    labelBuilder: (item, index, total) =>
        '镜头 ${item.shotNumber.toString().padLeft(2, '0')} · ${item.label} · ${index + 1}/$total',
    itemBuilder: (context, item) => Image.file(
      item.file,
      key: ValueKey('video-generation-source-gallery-image-${item.shotNumber}'),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Center(
        child: Text('参考图无法读取', style: TextStyle(color: Colors.white)),
      ),
    ),
  );
}

String _formatDuration(Duration duration) {
  final totalMilliseconds = duration.inMilliseconds;
  final minutes = totalMilliseconds ~/ 60000;
  final seconds = (totalMilliseconds % 60000) ~/ 1000;
  final milliseconds = totalMilliseconds % 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${milliseconds.toString().padLeft(3, '0')}';
}
