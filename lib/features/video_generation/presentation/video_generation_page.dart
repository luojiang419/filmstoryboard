import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_availability_cache.dart';
import '../../../core/widgets/adaptive_video_viewport.dart';
import '../../../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../application/video_generation_controller.dart';
import '../data/cli_dependency_installer.dart';
import '../data/kling_cli_models.dart';
import '../data/libtv_cli_models.dart';
import '../domain/kling_duration_matcher.dart';
import '../domain/generated_video_trim_range.dart';
import '../domain/source_video_preview_range.dart';
import '../domain/video_generation_models.dart';
import 'widgets/generated_video_trim_editor.dart';
import 'widgets/generated_video_trim_timeline.dart';

enum _TimelineExportAction { exportXml, sendToDaVinci }

class VideoGenerationPage extends StatelessWidget {
  const VideoGenerationPage({super.key});

  @override
  Widget build(BuildContext context) => const CollapsiblePanelShortcutScope(
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: VideoGenerationWorkspace(showScriptSelector: true),
    ),
  );
}

class VideoGenerationWorkspace extends ConsumerStatefulWidget {
  const VideoGenerationWorkspace({
    super.key,
    this.scriptId,
    this.showScriptSelector = false,
    this.externalizeWorkPanel = false,
    this.uiStateKey = 'videoGenerationPageUiState',
  });

  final String? scriptId;
  final bool showScriptSelector;
  final bool externalizeWorkPanel;
  final String uiStateKey;

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
  bool _installPromptShown = false;
  bool _installPromptOpen = false;
  bool _installWaitDialogOpen = false;
  bool _installFlowOpen = false;
  String _installPromptProvider = '';
  bool _loginPromptShown = false;
  bool _loginPromptOpen = false;
  bool _loginWaitDialogOpen = false;
  String _loginPromptProvider = '';
  var _workPanelWidth = _workPanelDefaultWidth;
  var _workPanelCollapsed = false;
  final _fileAvailabilityCache = FileAvailabilityCache();

  @override
  void initState() {
    super.initState();
    _restoreUiState();
  }

  @override
  void dispose() {
    _fileAvailabilityCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('video_generation.workspace');
    final controller = ref.watch(videoGenerationControllerProvider);
    _syncRequestedScript(controller);
    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ValueListenableBuilder<VideoGenerationState>(
        valueListenable: controller,
        builder: (context, state, _) {
          _scheduleCliInstallPrompt(state, controller);
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
                onInstall: () => _promptCliInstall(controller),
                onLogin: () => _runCliLoginAuthorization(controller),
                onGenerateAll: () => _confirmBatch(context, state, controller),
              ),
              if (state.isLoadingEnvironment || state.isBusy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 3),
              ],
              if (state.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
                    final previewTask = state.selectedPreviewTask;
                    final previewFile = previewTask == null
                        ? null
                        : controller.generatedVideoFileFor(previewTask);
                    final workspaceContent =
                        previewTask != null &&
                            _videoFileExists(context, previewFile)
                        ? _WorkVideoTrimPreview(
                            state: state,
                            controller: controller,
                            task: previewTask,
                            file: previewFile!,
                          )
                        : table;
                    if (widget.externalizeWorkPanel) {
                      return workspaceContent;
                    }
                    final panel = _WorkManagementPanel(
                      state: state,
                      controller: controller,
                      collapsed: _workPanelCollapsed,
                      onToggleCollapsed: _toggleWorkPanel,
                    );
                    final registeredPanel = CollapsiblePanelRegistration(
                      expanded: !_workPanelCollapsed,
                      onExpandedChanged: _setWorkPanelExpanded,
                      child: panel,
                    );
                    if (constraints.maxWidth < 1040) {
                      return Column(
                        children: [
                          Expanded(child: workspaceContent),
                          const Divider(height: 1),
                          SizedBox(height: 300, child: registeredPanel),
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
                        Expanded(child: workspaceContent),
                        _VideoGenerationRightPanelResizeHandle(
                          key: const ValueKey(
                            'video-generation-work-panel-resize-handle',
                          ),
                          enabled: !_workPanelCollapsed,
                          onDragEnd: _saveUiState,
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
                          child: registeredPanel,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _toggleWorkPanel() {
    _setWorkPanelExpanded(_workPanelCollapsed);
  }

  void _setWorkPanelExpanded(bool expanded) {
    if (_workPanelCollapsed == !expanded) {
      return;
    }
    setState(() => _workPanelCollapsed = !expanded);
    _saveUiState();
  }

  void _restoreUiState() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(widget.uiStateKey);
      if (raw == null || raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      _workPanelWidth = _jsonDouble(
        decoded['workPanelWidth'],
        _workPanelDefaultWidth,
      ).clamp(_workPanelMinWidth, 720).toDouble();
      _workPanelCollapsed = _jsonBool(decoded['workPanelCollapsed'], false);
    } catch (_) {
      return;
    }
  }

  void _saveUiState() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(
            widget.uiStateKey,
            jsonEncode({
              'workPanelWidth': _workPanelWidth,
              'workPanelCollapsed': _workPanelCollapsed,
            }),
          );
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
    if (!controller.usesCliVideoGeneration) return;
    final provider = controller.activeCliProviderName;
    if (_loginPromptProvider != provider) {
      _loginPromptProvider = provider;
      _loginPromptShown = false;
    }
    if (_loginPromptShown ||
        _loginPromptOpen ||
        _installFlowOpen ||
        state.isLoadingEnvironment ||
        !controller.shouldRequestActiveCliLogin ||
        state.loginAuthorizationStatus ==
            KlingLoginAuthorizationStatus.waiting) {
      return;
    }
    _loginPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_promptCliLogin(controller));
    });
  }

  void _scheduleCliInstallPrompt(
    VideoGenerationState state,
    VideoGenerationController controller,
  ) {
    if (!controller.usesCliVideoGeneration) return;
    final provider = controller.activeCliProviderName;
    if (_installPromptProvider != provider) {
      _installPromptProvider = provider;
      _installPromptShown = false;
    }
    if (_installPromptShown ||
        _installPromptOpen ||
        _installFlowOpen ||
        state.isLoadingEnvironment ||
        !controller.shouldRequestActiveCliInstall) {
      return;
    }
    _installPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_promptCliInstall(controller));
    });
  }

  Future<void> _promptCliInstall(VideoGenerationController controller) async {
    if (_installPromptOpen || _installFlowOpen) return;
    _installPromptOpen = true;
    var selectedRegion = controller.configuredKlingInstallRegion;
    final usesLibTv = controller.usesLibTvCli;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('安装${controller.activeCliProviderName} CLI'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  usesLibTv
                      ? '未检测到 LibTV CLI。软件将运行安装包内置的 LibTV 官方安装脚本；LibTV 不需要 npm。'
                      : '未检测到可灵 CLI。软件会检查 Node.js 18+ 和 npm；缺失时先通过 winget 安装 Node.js LTS，再安装所选区域的可灵官方 CLI 包。',
                ),
                if (!usesLibTv) ...[
                  const SizedBox(height: 16),
                  const Text('选择账号所在区域（两个版本不会同时安装）：'),
                  const SizedBox(height: 8),
                  SegmentedButton<KlingCliInstallRegion>(
                    segments: const [
                      ButtonSegment(
                        value: KlingCliInstallRegion.china,
                        label: Text('中国区'),
                      ),
                      ButtonSegment(
                        value: KlingCliInstallRegion.global,
                        label: Text('海外区'),
                      ),
                    ],
                    selected: selectedRegion == null
                        ? const <KlingCliInstallRegion>{}
                        : {selectedRegion!},
                    emptySelectionAllowed: true,
                    onSelectionChanged: (selection) => setDialogState(() {
                      selectedRegion = selection.isEmpty
                          ? null
                          : selection.first;
                    }),
                  ),
                ],
                const SizedBox(height: 16),
                const Text('安装完成后会自动打开浏览器，授权仍需由你本人在浏览器中确认。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              key: ValueKey(
                usesLibTv ? 'confirm-libtv-install' : 'confirm-kling-install',
              ),
              onPressed: !usesLibTv && selectedRegion == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('自动安装并登录'),
            ),
          ],
        ),
      ),
    );
    _installPromptOpen = false;
    if (confirmed == true && mounted) {
      await _runCliInstall(controller, selectedRegion);
    }
  }

  Future<void> _runCliInstall(
    VideoGenerationController controller,
    KlingCliInstallRegion? region,
  ) async {
    if (_installFlowOpen) return;
    _installFlowOpen = true;
    final installation = controller.installActiveCli(klingRegion: region);
    unawaited(_showCliInstallWaitDialog(controller));
    final installed = await installation;
    if (!mounted) return;
    if (_installWaitDialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _installWaitDialogOpen = false;
    }
    _installFlowOpen = false;
    if (installed) {
      await _runCliLoginAuthorization(controller);
    } else {
      await _showCliInstallResultDialog(controller);
    }
  }

  Future<void> _showCliInstallWaitDialog(
    VideoGenerationController controller,
  ) async {
    _installWaitDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<VideoGenerationState>(
        valueListenable: controller,
        builder: (context, state, _) => AlertDialog(
          title: Text('正在安装${controller.activeCliProviderName} CLI'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 16),
                Text(
                  state.cliInstallMessage.isEmpty
                      ? '正在准备安装命令…'
                      : state.cliInstallMessage,
                ),
                const SizedBox(height: 8),
                const Text('请勿关闭软件；系统安装程序可能会短暂弹出。'),
              ],
            ),
          ),
        ),
      ),
    );
    _installWaitDialogOpen = false;
  }

  Future<void> _showCliInstallResultDialog(
    VideoGenerationController controller,
  ) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${controller.activeCliProviderName} CLI 安装失败'),
        content: Text(
          controller.value.errorMessage.isEmpty
              ? '没有检测到安装完成，可以重试。'
              : controller.value.errorMessage,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新安装'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) await _promptCliInstall(controller);
  }

  Future<void> _promptCliLogin(VideoGenerationController controller) async {
    if (_loginPromptOpen) return;
    _loginPromptOpen = true;
    final provider = controller.activeCliProviderName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('需要登录$provider账号'),
        content: Text('视频生成功能需要连接$provider账号。点击“确定登录”后将打开浏览器，请在浏览器中完成授权登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            key: ValueKey(
              controller.usesLibTvCli
                  ? 'confirm-libtv-login'
                  : 'confirm-kling-login',
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定登录'),
          ),
        ],
      ),
    );
    _loginPromptOpen = false;
    if (confirmed == true && mounted) {
      await _runCliLoginAuthorization(controller);
    }
  }

  Future<void> _runCliLoginAuthorization(
    VideoGenerationController controller,
  ) async {
    final authorization = controller.startLoginAuthorization();
    unawaited(_showCliLoginWaitDialog(controller));
    final result = await authorization;
    if (!mounted) return;
    if (_loginWaitDialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _loginWaitDialogOpen = false;
    }
    if (result == KlingLoginAuthorizationStatus.failed ||
        result == KlingLoginAuthorizationStatus.timedOut) {
      await _showCliLoginResultDialog(controller);
    }
  }

  Future<void> _showCliLoginWaitDialog(
    VideoGenerationController controller,
  ) async {
    _loginWaitDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<VideoGenerationState>(
        valueListenable: controller,
        builder: (context, state, _) => AlertDialog(
          title: Text('等待${controller.activeCliProviderName}授权完成'),
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

  Future<void> _showCliLoginResultDialog(
    VideoGenerationController controller,
  ) async {
    final provider = controller.activeCliProviderName;
    final retry = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未检测到授权完成'),
        content: Text(
          '如果浏览器授权页已关闭或没有完成登录，可以重新打开浏览器继续授权；也可以稍后在视频生成页点击“登录$provider”。',
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
      await _runCliLoginAuthorization(controller);
    }
  }

  Future<void> _confirmBatch(
    BuildContext context,
    VideoGenerationState state,
    VideoGenerationController controller,
  ) async {
    final shots = controller.generationTargets();
    if (shots.isEmpty) return;
    if (controller.usesConfiguredVideoGenerationApi ||
        controller.usesLibTvCli) {
      final config = controller.activeVideoGenerationApiConfig;
      final usesLibTv = controller.usesLibTvCli;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认批量生成'),
          content: Text(
            '镜头数：${shots.length}\n'
            '${usesLibTv ? 'CLI' : 'API'}：${config?.name ?? controller.activeVideoBackendName}\n'
            '模型：${controller.activeVideoGenerationApiModel}\n\n'
            '${usesLibTv ? controller.libTvParameterSummary : controller.videoApiParameterSummary}\n\n'
            '${usesLibTv ? '任务会写入当前脚本专属的 LibTV 画布，并按镜号顺序执行。' : '任务会提交到当前默认视频生成 API。'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: ValueKey(
                usesLibTv ? 'confirm-libtv-batch' : 'confirm-video-api-batch',
              ),
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
    if (controller.usesConfiguredVideoGenerationApi ||
        controller.usesLibTvCli) {
      final config = controller.activeVideoGenerationApiConfig;
      final usesLibTv = controller.usesLibTvCli;
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
            '${usesLibTv ? 'CLI' : 'API'}：${config?.name ?? controller.activeVideoBackendName}\n'
            '模型：${controller.activeVideoGenerationApiModel}\n'
            '时长：${controller.desiredDurationFor(shot).toStringAsFixed(1)}s\n'
            '${sequence.hasDistinctTail ? '参考范围：镜头 ${sequence.head.shotNumber}–${sequence.tail.shotNumber}\n' : ''}\n'
            '${usesLibTv ? controller.libTvParameterSummary : controller.videoApiParameterSummary}\n\n'
            '${usesLibTv ? '任务会写入当前脚本专属的 LibTV 画布并同步等待终态。' : '任务会提交到当前默认视频生成 API。'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: ValueKey(
                usesLibTv
                    ? 'confirm-libtv-shot-${shot.id}'
                    : 'confirm-video-api-shot-${shot.id}',
              ),
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
          '${sequence.hasDistinctTail ? '参考范围：镜头 ${sequence.head.shotNumber}–${sequence.tail.shotNumber}\n' : ''}'
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
    required this.onInstall,
    required this.onLogin,
    required this.onGenerateAll,
  });

  final VideoGenerationState state;
  final VideoGenerationController controller;
  final bool showScriptSelector;
  final String taskFilter;
  final ValueChanged<String?> onTaskFilterChanged;
  final VoidCallback onInstall;
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
    final canGenerateAny = controller.generationTargets().isNotEmpty;
    final hasBlockingNonGenerationWork = state.isBusy && !state.isGeneratingAll;
    final usesCli = controller.usesCliVideoGeneration;
    final cliConnected = controller.activeCliAccountConnected;
    final libTvAccountLabel = state.libTvAccount == null
        ? '未登录'
        : (state.libTvAccount!.nickname.trim().isNotEmpty
              ? state.libTvAccount!.nickname
              : state.libTvAccount!.accountName);
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
                      controller.activeCliEnvironmentReady
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              label: controller.usesConfiguredVideoGenerationApi
                  ? '视频 API'
                  : controller.activeCliEnvironmentReady
                  ? '${controller.activeCliProviderName} CLI ${controller.activeCliVersion}'
                  : '环境未就绪',
            ),
            if (usesCli)
              _StatusChip(
                icon: !cliConnected
                    ? Icons.login_rounded
                    : Icons.account_circle_outlined,
                label: !cliConnected
                    ? '未登录'
                    : controller.usesLibTvCli
                    ? libTvAccountLabel
                    : '${state.account?.membershipDescription ?? '已登录'} · ${state.account?.availableCredits ?? 0} 灵感值',
              ),
            if (usesCli && !controller.activeCliEnvironmentReady)
              OutlinedButton.icon(
                onPressed: state.isLoadingEnvironment ? null : onInstall,
                icon: const Icon(Icons.download_rounded),
                label: Text('安装${controller.activeCliProviderName} CLI'),
              )
            else if (usesCli && !cliConnected)
              OutlinedButton.icon(
                onPressed: state.isLoadingEnvironment ? null : onLogin,
                icon: const Icon(Icons.login_rounded),
                label: Text('登录${controller.activeCliProviderName}'),
              ),
            if (!controller.usesLibTvCli && models.isNotEmpty)
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
            if (controller.usesLibTvCli && controller.libTvModels.isNotEmpty)
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey(
                    'libtv-model-${controller.selectedLibTvModelKey}',
                  ),
                  initialValue: controller.selectedLibTvModelKey.isEmpty
                      ? null
                      : controller.selectedLibTvModelKey,
                  decoration: const InputDecoration(
                    labelText: 'LibTV 视频模型',
                    isDense: true,
                  ),
                  items: [
                    for (final model in controller.libTvModels)
                      DropdownMenuItem(
                        value: model.modelKey,
                        child: Text(
                          model.modelName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: state.isBusy || state.isLoadingLibTvModel
                      ? null
                      : (modelKey) {
                          if (modelKey != null) {
                            unawaited(controller.selectLibTvModel(modelKey));
                          }
                        },
                ),
              ),
            if (controller.usesLibTvCli && controller.libTvModeTypes.isNotEmpty)
              SizedBox(
                width: 175,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey(
                    'libtv-mode-${controller.selectedLibTvModeType}',
                  ),
                  initialValue: controller.selectedLibTvModeType.isEmpty
                      ? null
                      : controller.selectedLibTvModeType,
                  decoration: const InputDecoration(
                    labelText: '生成模式',
                    isDense: true,
                  ),
                  items: [
                    for (final modeType in controller.libTvModeTypes)
                      DropdownMenuItem(
                        value: modeType,
                        child: Text(controller.libTvModeTypeLabel(modeType)),
                      ),
                  ],
                  onChanged: state.isBusy || state.isLoadingLibTvModel
                      ? null
                      : (modeType) {
                          if (modeType != null) {
                            controller.updateLibTvModeType(modeType);
                          }
                        },
                ),
              ),
            if (controller.usesLibTvCli)
              for (final parameter in controller.libTvParameterSpecs)
                _LibTvParameterField(
                  controller: controller,
                  parameter: parameter,
                  enabled: !state.isBusy && !state.isLoadingLibTvModel,
                ),
            if (controller.usesLibTvCli && state.libTvModel != null)
              _StatusChip(
                icon: Icons.timer_outlined,
                label:
                    '时长 ${controller.libTvDurationMin}–${controller.libTvDurationMax} 秒（按镜头） · 每镜头 ${controller.selectedLibTvCount} 条',
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
                  hasBlockingNonGenerationWork ||
                      !canGenerateAny ||
                      (usesCli && !cliConnected)
                  ? null
                  : onGenerateAll,
              icon: const Icon(Icons.movie_creation_outlined),
              label: const Text('一键生成全部'),
            ),
            PopupMenuButton<_TimelineExportAction>(
              key: const ValueKey('export-timeline-menu'),
              enabled: !state.isBusy && controller.canExportTimelineXml,
              tooltip: '导出或发送时间线',
              onSelected: (action) {
                switch (action) {
                  case _TimelineExportAction.exportXml:
                    unawaited(controller.exportTimelineXml());
                    break;
                  case _TimelineExportAction.sendToDaVinci:
                    unawaited(controller.sendTimelineToDaVinci());
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  key: ValueKey('export-timeline-xml'),
                  value: _TimelineExportAction.exportXml,
                  child: ListTile(
                    leading: Icon(Icons.account_tree_outlined),
                    title: Text('导出 XML 时间线'),
                  ),
                ),
                PopupMenuItem(
                  key: ValueKey('send-timeline-to-davinci'),
                  value: _TimelineExportAction.sendToDaVinci,
                  child: ListTile(
                    leading: Icon(Icons.send_rounded),
                    title: Text('发送到达芬奇'),
                  ),
                ),
              ],
              child: IgnorePointer(
                child: OutlinedButton.icon(
                  onPressed: !state.isBusy && controller.canExportTimelineXml
                      ? () {}
                      : null,
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text('导出时间线'),
                ),
              ),
            ),
            FilledButton.tonalIcon(
              key: const ValueKey('export-composed-video'),
              onPressed: state.isBusy || !controller.canExportVideo
                  ? null
                  : controller.exportVideo,
              icon: const Icon(Icons.video_file_outlined),
              label: const Text('导出视频'),
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
  final _fileAvailabilityCache = FileAvailabilityCache();

  @override
  void dispose() {
    _fileAvailabilityCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(videoGenerationControllerProvider);
    _syncRequestedScript(controller);
    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ValueListenableBuilder<VideoGenerationState>(
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
      ),
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
    this.onDragEnd,
  });

  final bool enabled;
  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;

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
        onHorizontalDragEnd: enabled ? (_) => onDragEnd?.call() : null,
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
                      const SizedBox(width: 4),
                      TextButton.icon(
                        key: const ValueKey('clean-invalid-generated-works'),
                        onPressed:
                            state.isBusy || controller.invalidWorkTaskCount == 0
                            ? null
                            : controller.cleanInvalidWorks,
                        icon: const Icon(Icons.cleaning_services_outlined),
                        label: const Text('清理'),
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
        initiallyExpanded: _shouldExpandWorkGroup(context, group, controller),
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
    final hasLocalVideo = _videoFileExists(context, file);
    final isActive = _isActiveVideoTask(task);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return GestureDetector(
      key: ValueKey('work-management-video-context-menu-${task.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: hasLocalVideo
          ? () => controller.selectWorkPreviewTask(task)
          : null,
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
                        range: task.trimRange,
                        onTap: () => controller.selectWorkPreviewTask(task),
                        onFullscreen: () => _showFullscreenGeneratedVideo(
                          context,
                          file,
                          range: task.trimRange,
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
    final overlayState = Overlay.of(context);
    final hasFile = await FileAvailabilityScope.of(context).checkNow(file.path);
    if (!context.mounted || !overlayState.mounted) return;
    final overlay = overlayState.context.findRenderObject()! as RenderBox;
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
          enabled: hasFile,
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.folder_open_rounded),
            title: Text('打开路径'),
          ),
        ),
        PopupMenuItem(
          value: _WorkVideoMenuAction.saveAs,
          enabled: hasFile,
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
    final location = await ProviderScope.containerOf(context, listen: false)
        .read(desktopFileDialogServiceProvider)
        .getSaveLocation(
          source: 'video_generation.work_management_save_as',
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

class _WorkVideoTrimPreview extends StatelessWidget {
  const _WorkVideoTrimPreview({
    required this.state,
    required this.controller,
    required this.task,
    required this.file,
  });

  final VideoGenerationState state;
  final VideoGenerationController controller;
  final VideoGenerationTask task;
  final File file;

  @override
  Widget build(BuildContext context) {
    final shot = state.shots
        .where((shot) => shot.id == task.shotId)
        .firstOrNull;
    final canPrevious = controller.canNavigateWorkPreview(-1);
    final canNext = controller.canNavigateWorkPreview(1);
    final theme = Theme.of(context);
    return Focus(
      key: const ValueKey('work-management-large-preview-focus'),
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          controller.closeWorkPreview();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft && canPrevious) {
          controller.navigateWorkPreview(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight && canNext) {
          controller.navigateWorkPreview(1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DecoratedBox(
        key: ValueKey('work-management-large-preview-${task.id}'),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey('work-preview-previous-shot'),
                    tooltip: '上一个镜头（←）',
                    onPressed: canPrevious
                        ? () => controller.navigateWorkPreview(-1)
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shot == null
                              ? '作品预览'
                              : '镜头 ${shot.shotNumber} · 作品预览',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '${task.model} · '
                          '${formatVideoTimecode(task.trimRange.inPoint)}–'
                          '${formatVideoTimecode(task.trimRange.outPoint)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    key: const ValueKey('work-preview-next-shot'),
                    tooltip: '下一个镜头（→）',
                    onPressed: canNext
                        ? () => controller.navigateWorkPreview(1)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('close-work-management-large-preview'),
                    tooltip: '退出预览（Esc）',
                    onPressed: controller.closeWorkPreview,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GeneratedVideoTrimEditor(
                  key: ValueKey('work-preview-io-editor-${task.id}'),
                  file: file,
                  initialRange: task.trimRange,
                  onChanged: (range) =>
                      controller.updateTaskTrimRange(task, range),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  BuildContext context,
  _WorkVideoShotGroup group,
  VideoGenerationController controller,
) {
  final latest = group.entries.last.task;
  if (_isActiveVideoTask(latest)) return true;
  return _videoFileExists(context, controller.generatedVideoFileFor(latest));
}

bool _videoFileExists(BuildContext context, File? file) {
  if (file == null || file.path.trim().isEmpty) return false;
  return FileAvailabilityScope.of(
    context,
  ).exists(file.path, defaultValue: true);
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
                        enabled: true,
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
                _videoFileExists(context, thumbnail) ? '按 IO 点预览' : '预览源视频',
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
        .where((shot) => _videoFileExists(context, fileForShot(shot)))
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
    final hasFile = _videoFileExists(context, file);
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
                      fit: BoxFit.contain,
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
    final hasLocalVideo = _videoFileExists(context, localFile);
    final isGenerating = latest != null && _isActiveVideoTask(latest);
    final canGenerate =
        controller.canGenerateShot(owner) &&
        !controller.isGenerationActiveFor(owner);
    return _Cell(
      child: _VideoShotCellLayout(
        shot: shot,
        slotName: 'generated',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 150,
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
                      range: latest.trimRange,
                      onFullscreen: () => _showFullscreenGeneratedVideo(
                        context,
                        localFile,
                        range: latest.trimRange,
                        title: '镜头 ${shot.shotNumber} · 生成视频',
                      ),
                    )
                  else
                    _GeneratedVideoPlaceholder(
                      icon: latest == null
                          ? Icons.movie_creation_outlined
                          : Icons.hourglass_top_rounded,
                      message: latest == null
                          ? '尚未生成'
                          : '状态：${latest.status.name}',
                      action: latest == null
                          ? FilledButton.icon(
                              key: ValueKey(
                                'generated-video-generate-button-${shot.id}',
                              ),
                              onPressed: enabled && canGenerate
                                  ? onGenerate
                                  : null,
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
                            latest?.status ==
                                VideoGenerationTaskStatus.failed &&
                            (latest!.resultWithoutWatermarkUrl.isNotEmpty ||
                                latest.resultUrl.isNotEmpty),
                        canContinueQuery:
                            !isGroupContinuation &&
                            latest?.status ==
                                VideoGenerationTaskStatus.timedOut &&
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
                                  range: latest!.trimRange,
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
                              if (latest != null) {
                                await _rename(context, latest);
                              }
                              break;
                            case 'delete':
                              if (latest != null) {
                                await _delete(context, latest);
                              }
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
            if (!isGroupContinuation && hasLocalVideo && latest != null) ...[
              const SizedBox(height: 6),
              Text(
                'I ${_formatDuration(latest.trimRange.inPoint)}  ·  '
                'O ${_formatDuration(latest.trimRange.outPoint)}  ·  '
                '${_formatDuration(latest.trimRange.duration)}',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: ValueKey('generated-video-io-button-${latest.id}'),
                onPressed: () => _editTrim(context, latest, localFile!),
                icon: const Icon(Icons.content_cut_rounded),
                label: Text(latest.trimRange.isFullRange ? 'I/O' : 'I/O 已裁剪'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editTrim(
    BuildContext context,
    VideoGenerationTask task,
    File file,
  ) => showGeneratedVideoTrimEditor(
    context,
    title: '镜头 ${controller.generationOwnerFor(shot).shotNumber} · 设置 I/O 点',
    file: file,
    initialRange: task.trimRange,
    onChanged: (range) => controller.updateTaskTrimRange(task, range),
  );

  Future<void> _download(BuildContext context, VideoGenerationTask task) async {
    final source = File(task.localPath);
    if (!await source.exists() || !context.mounted) return;
    final location = await ProviderScope.containerOf(context, listen: false)
        .read(desktopFileDialogServiceProvider)
        .getSaveLocation(
          source: 'video_generation.generated_video_download',
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

  Future<void> _history(BuildContext context, List<VideoGenerationTask> tasks) {
    final fileAvailabilityCache = FileAvailabilityScope.of(context);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => FileAvailabilityScope(
        cache: fileAvailabilityCache,
        child: AlertDialog(
          title: Text(
            '镜头 ${controller.generationOwnerFor(shot).shotNumber} 历史版本',
          ),
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
                  onOpen: _videoFileExists(context, file)
                      ? () => _showFullscreenGeneratedVideo(
                          context,
                          file,
                          range: task.trimRange,
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
      ),
    );
  }

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
  var _thumbnailCheckStarted = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_thumbnailCheckStarted) return;
    _thumbnailCheckStarted = true;
    unawaited(_openThumbnailIfAvailable());
  }

  Future<void> _openThumbnailIfAvailable() async {
    final available = await FileAvailabilityScope.of(
      context,
    ).checkNow(widget.file.path);
    if (available && mounted) await _openThumbnail();
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
    final hasFile = _videoFileExists(context, widget.file);
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
            AdaptiveVideoViewport(
              player: _player,
              maxHeight: 190,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasFile && _thumbnailError.isEmpty)
                    Video(
                      controller: _videoController,
                      controls: null,
                      fit: BoxFit.contain,
                    )
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
                    '${widget.task.status.name}',
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
    required this.range,
    this.onTap,
    required this.onFullscreen,
  });

  final File file;
  final GeneratedVideoTrimRange range;
  final VoidCallback? onTap;
  final VoidCallback onFullscreen;

  @override
  State<_InlineGeneratedVideoPlayer> createState() =>
      _InlineGeneratedVideoPlayerState();
}

class _InlineGeneratedVideoPlayerState
    extends State<_InlineGeneratedVideoPlayer> {
  late final Player _player;
  late final VideoController _videoController;
  late final FocusNode _keyboardFocusNode;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Duration _position = Duration.zero;
  var _playing = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _keyboardFocusNode = FocusNode();
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    _positionSubscription = _player.stream.position.listen(_handlePosition);
    _position = widget.range.inPoint;
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant _InlineGeneratedVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      unawaited(_open());
    } else if (oldWidget.range.inPoint != widget.range.inPoint ||
        oldWidget.range.outPoint != widget.range.outPoint) {
      unawaited(_applyRange());
    }
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.file.path), play: false);
      await _applyRange();
      if (mounted) {
        setState(() => _error = '');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '视频加载失败：$error');
    }
  }

  Future<void> _applyRange() async {
    await _player.pause();
    await _player.seek(widget.range.inPoint);
    if (mounted) setState(() => _position = widget.range.inPoint);
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

  Future<void> _toggle() async {
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.space &&
        _error.isEmpty) {
      unawaited(_toggle());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTap() {
    _keyboardFocusNode.requestFocus();
    final action = widget.onTap;
    if (action != null) {
      action();
    } else {
      unawaited(_toggle());
    }
  }

  @override
  void dispose() {
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    _keyboardFocusNode.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    key: ValueKey('generated-video-inline-keyboard-${widget.file.path}'),
    focusNode: _keyboardFocusNode,
    onKeyEvent: _handleKeyEvent,
    child: AdaptiveVideoViewport(
      player: _player,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_error.isEmpty)
                Video(
                  controller: _videoController,
                  controls: null,
                  fit: BoxFit.contain,
                )
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
                    onTap: _handleTap,
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
                  key: ValueKey(
                    'generated-video-fullscreen-${widget.file.path}',
                  ),
                  tooltip: '全屏播放',
                  onPressed: widget.onFullscreen,
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ),
            ],
          ),
        ),
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
  const _FullscreenGeneratedVideo({
    required this.file,
    required this.range,
    required this.title,
  });

  final File file;
  final GeneratedVideoTrimRange range;
  final String title;

  @override
  State<_FullscreenGeneratedVideo> createState() =>
      _FullscreenGeneratedVideoState();
}

class _FullscreenGeneratedVideoState extends State<_FullscreenGeneratedVideo> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _positionSubscription;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _positionSubscription = _player.stream.position.listen((position) {
      if (position >= widget.range.outPoint) {
        unawaited(_player.pause());
        unawaited(_player.seek(widget.range.inPoint));
      }
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(
        Media(
          widget.file.path,
          start: widget.range.inPoint,
          end: widget.range.outPoint,
        ),
        play: true,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '视频播放失败：$error');
    }
  }

  Future<void> _togglePlayback() async {
    if (_player.state.playing) {
      await _player.pause();
      return;
    }
    final position = _player.state.position;
    if (position < widget.range.inPoint || position >= widget.range.outPoint) {
      await _player.seek(widget.range.inPoint);
    }
    await _player.play();
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    key: const ValueKey('generated-video-fullscreen-keyboard-scope'),
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.space && _error.isEmpty) {
          unawaited(_togglePlayback());
          return KeyEventResult.handled;
        }
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
                    ? Video(controller: _videoController, fit: BoxFit.contain)
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
  required GeneratedVideoTrimRange range,
  required String title,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black,
  builder: (_) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: _FullscreenGeneratedVideo(file: file, range: range, title: title),
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

class _LibTvParameterField extends StatelessWidget {
  const _LibTvParameterField({
    required this.controller,
    required this.parameter,
    required this.enabled,
  });

  final VideoGenerationController controller;
  final LibTvModelParameterSpec parameter;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final value = controller.selectedLibTvParameterValue(parameter);
    final label = parameter.group == LibTvParameterGroup.advanced
        ? '高级 · ${parameter.displayName}'
        : parameter.displayName;
    if (parameter.isSwitch) {
      final selected = const {
        '1',
        'true',
        'on',
        'yes',
      }.contains(value.toLowerCase());
      return SizedBox(
        width: 145,
        child: DropdownButtonFormField<bool>(
          key: ValueKey('libtv-parameter-${parameter.key}-$selected'),
          initialValue: selected,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: const [
            DropdownMenuItem(value: true, child: Text('开启')),
            DropdownMenuItem(value: false, child: Text('关闭')),
          ],
          onChanged: !enabled
              ? null
              : (selected) {
                  if (selected != null) {
                    controller.updateLibTvSwitchParameter(parameter, selected);
                  }
                },
        ),
      );
    }
    final options = parameter.options.isNotEmpty
        ? parameter.options
        : _numericLibTvOptions(parameter);
    if (options.isNotEmpty) {
      return SizedBox(
        width: 155,
        child: DropdownButtonFormField<String>(
          isExpanded: true,
          key: ValueKey('libtv-parameter-${parameter.key}-$value'),
          initialValue: value,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: [
            for (final option in options)
              DropdownMenuItem(
                value: option.value,
                child: Text(option.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: !enabled
              ? null
              : (selected) {
                  if (selected != null) {
                    controller.updateLibTvParameter(parameter, selected);
                  }
                },
        ),
      );
    }
    return SizedBox(
      width: 175,
      child: TextFormField(
        key: ValueKey('libtv-parameter-${parameter.key}-$value'),
        initialValue: value,
        enabled: enabled,
        keyboardType: parameter.hasNumericRange
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          helperText: parameter.hasNumericRange
              ? '${parameter.min}–${parameter.max}'
              : null,
        ),
        onFieldSubmitted: (value) =>
            controller.updateLibTvParameter(parameter, value),
      ),
    );
  }
}

List<LibTvParameterOption> _numericLibTvOptions(
  LibTvModelParameterSpec parameter,
) {
  if (!parameter.hasNumericRange) return const [];
  final min = parameter.min!;
  final max = parameter.max!;
  final step = parameter.step ?? 1;
  if (step <= 0) return const [];
  final count = ((max - min) / step).floor() + 1;
  if (count <= 0 || count > 30) return const [];
  return [
    for (var index = 0; index < count; index += 1)
      _numericLibTvOption(min + step * index),
  ];
}

LibTvParameterOption _numericLibTvOption(num value) {
  final text = value == value.roundToDouble()
      ? '${value.toInt()}'
      : value
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
  return LibTvParameterOption(value: text, label: text);
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
    return Focus(
      key: const ValueKey('source-range-preview-keyboard-scope'),
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.space &&
            _error.isEmpty) {
          unawaited(_togglePlayback());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AlertDialog(
        title: const Text('原视频 IO 点预览'),
        content: SizedBox(
          width: 820,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveVideoViewport(
                player: _player,
                initialAspectRatio: widget.range.aspectRatio,
                maxHeight: 520,
                child: _error.isEmpty
                    ? Video(
                        controller: _videoController,
                        controls: null,
                        fit: BoxFit.contain,
                      )
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
      ),
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
