import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/widgets/fullscreen_zoom_gallery.dart';
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
  });

  final String? scriptId;
  final bool showScriptSelector;

  @override
  ConsumerState<VideoGenerationWorkspace> createState() =>
      _VideoGenerationWorkspaceState();
}

class _VideoGenerationWorkspaceState
    extends ConsumerState<VideoGenerationWorkspace> {
  String _taskFilter = 'all';
  bool _loginPromptShown = false;
  bool _loginPromptOpen = false;
  bool _loginWaitDialogOpen = false;

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
              child: _GenerationTable(
                state: state.copyWith(tasks: visibleTasks),
                controller: controller,
                onGenerateShot: (shot) =>
                    _confirmShot(context, state, controller, shot),
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
                const Text('首尾帧模式：已开启，连续动作组按一条请求计费'),
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
              icon: state.environment?.isReady == true
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              label: state.environment?.isReady == true
                  ? 'CLI ${state.environment!.klingVersion}'
                  : '环境未就绪',
            ),
            if (controller.startEndFrameModeEnabled)
              const _StatusChip(icon: Icons.science_outlined, label: '首尾帧模式'),
            _StatusChip(
              icon: state.identity == null
                  ? Icons.login_rounded
                  : Icons.account_circle_outlined,
              label: state.identity == null
                  ? '未登录'
                  : '${state.account?.membershipDescription ?? '已登录'} · ${state.account?.availableCredits ?? 0} 灵感值',
            ),
            if (state.identity == null)
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
              label: const Text('打开目录'),
            ),
            FilledButton.icon(
              key: const ValueKey('generate-all-videos'),
              onPressed: state.isBusy || state.identity == null
                  ? null
                  : onGenerateAll,
              icon: const Icon(Icons.movie_creation_outlined),
              label: const Text('一键生成全部'),
            ),
          ],
        ),
      ),
    );
  }
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
    return Scrollbar(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1480,
            child: Table(
              key: const ValueKey('video-generation-four-column-table'),
              border: TableBorder.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              columnWidths: const {
                0: FixedColumnWidth(260),
                1: FixedColumnWidth(320),
                2: FixedColumnWidth(380),
                3: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                const TableRow(
                  children: [
                    _HeaderCell('原视频'),
                    _HeaderCell('首帧图'),
                    _HeaderCell('生成视频'),
                    _HeaderCell('生成提示词'),
                  ],
                ),
                for (final shot in state.shots)
                  TableRow(
                    children: [
                      _OriginalVideoCell(shot: shot, controller: controller),
                      _SourceImageCell(shot: shot, controller: controller),
                      _GeneratedVideoCell(
                        shot: shot,
                        controller: controller,
                        enabled: !state.isBusy,
                        onGenerate: () => onGenerateShot(shot),
                      ),
                      _PromptCell(
                        shot: shot,
                        draft: state.drafts[shot.id],
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

class _VideoShotCellLayout extends StatelessWidget {
  const _VideoShotCellLayout({
    required this.shot,
    required this.slotName,
    required this.child,
  });

  final ScriptShot shot;
  final String slotName;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        key: ValueKey('video-$slotName-shot-title-${shot.id}'),
        height: 20,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('镜头 ${shot.shotNumber}'),
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
  const _OriginalVideoCell({required this.shot, required this.controller});

  final ScriptShot shot;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final range = controller.sourcePreviewFor(shot);
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumbnail?.existsSync() == true)
              Tooltip(
                message: '点击播放原视频 IO 区间',
                child: InkWell(
                  key: ValueKey('source-video-thumbnail-${shot.id}'),
                  onTap: openPreview,
                  borderRadius: BorderRadius.circular(8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Image.file(
                          thumbnail!,
                          width: 230,
                          height: 130,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 230,
                            height: 130,
                            child: Center(child: Text('原视频缩略图加载失败')),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              Text(range == null ? '原视频不可用' : '原视频缩略图不可用'),
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
              label: const Text('按 IO 点预览'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceImageCell extends StatelessWidget {
  const _SourceImageCell({required this.shot, required this.controller});

  final ScriptShot shot;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
    final image = controller.replicatedImageFor(shot.id);
    final file = controller.sourceImageFileFor(shot);
    final usesReplicatedImage = controller.usesReplicatedImageFor(shot);
    return _Cell(
      child: _VideoShotCellLayout(
        shot: shot,
        slotName: 'source-image',
        child: file == null
            ? const Text('缺少首帧图\n当前镜头不可生成')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: usesReplicatedImage
                        ? '点击全屏浏览复刻分镜图'
                        : '点击全屏浏览故事板原图',
                    child: InkWell(
                      key: ValueKey(
                        'video-generation-source-thumbnail-${shot.id}',
                      ),
                      onTap: () =>
                          _showSourceImageGallery(context, controller, shot.id),
                      borderRadius: BorderRadius.circular(8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          file,
                          width: 280,
                          height: 150,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Text('首帧图预览失败'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    usesReplicatedImage
                        ? '来源：复刻分镜图 · ${image?.status.name ?? ''}'
                        : '来源：故事板原图',
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
    final latest = tasks.firstOrNull;
    final localFile = latest == null ? null : File(latest.localPath);
    final hasLocalVideo = localFile?.existsSync() == true;
    final canGenerate = controller.canGenerateShot(owner);
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
              Positioned(
                left: 8,
                top: 8,
                right: 52,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.66),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        isGroupContinuation
                            ? '首尾帧动作组'
                            : (latest == null
                                  ? '尚未生成'
                                  : '状态：${latest.status.name}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!isGroupContinuation &&
                  latest?.usedWatermarkedFallback == true)
                const Positioned(
                  left: 8,
                  bottom: 8,
                  child: _VideoNotice('已保存带水印结果'),
                ),
              if (!isGroupContinuation &&
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
                    canRetryDownload:
                        !isGroupContinuation &&
                        latest?.status == VideoGenerationTaskStatus.failed &&
                        (latest!.resultWithoutWatermarkUrl.isNotEmpty ||
                            latest.resultUrl.isNotEmpty),
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
                        case 'retry':
                          if (latest != null) {
                            await controller.retryDownload(latest);
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

  Future<void> _history(
    BuildContext context,
    List<VideoGenerationTask> tasks,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('镜头 ${controller.generationOwnerFor(shot).shotNumber} 历史版本'),
      content: SizedBox(
        width: 560,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, index) {
            final task = tasks[index];
            final file = File(task.localPath);
            return ListTile(
              title: Text('${task.model} · ${task.durationSeconds}s'),
              subtitle: Text(
                '${task.createdAt.toLocal()} · ${task.status.name}'
                '${task.tailImagePath.isEmpty ? '' : ' · 首尾帧'}',
              ),
              trailing: file.existsSync()
                  ? IconButton(
                      tooltip: '全屏播放',
                      onPressed: () => _showFullscreenGeneratedVideo(
                        context,
                        file,
                        title: '镜头 ${shot.shotNumber} · 历史版本 ${index + 1}',
                      ),
                      icon: const Icon(Icons.fullscreen_rounded),
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
    required this.canRetryDownload,
    required this.hasHistory,
    required this.hasGenerated,
    required this.onSelected,
  });

  final bool enabled;
  final bool canGenerate;
  final bool hasLocalVideo;
  final bool canRetryDownload;
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
        if (canRetryDownload)
          const PopupMenuItem(value: 'retry', child: Text('重新下载')),
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
            Center(child: Text(_error, textAlign: TextAlign.center)),
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
  Widget build(BuildContext context) => ColoredBox(
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

class _PromptCell extends StatelessWidget {
  const _PromptCell({
    required this.shot,
    required this.draft,
    required this.controller,
  });

  final ScriptShot shot;
  final VideoGenerationDraft? draft;
  final VideoGenerationController controller;

  @override
  Widget build(BuildContext context) {
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
                value: VideoPromptMode.original,
                label: Text('即梦原文'),
              ),
              ButtonSegment(value: VideoPromptMode.edited, label: Text('手工稿')),
            ],
            selected: {draft!.promptMode},
            onSelectionChanged: (selection) =>
                controller.updatePromptMode(shot.id, selection.first),
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey(
              'video-prompt-${shot.id}-${draft!.updatedAt.microsecondsSinceEpoch}',
            ),
            initialValue: draft!.selectedPrompt,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              helperText: '编辑后自动切换为手工稿；历史提交文本不会改变',
            ),
            onChanged: (value) => controller.updateEditedPrompt(shot.id, value),
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
      await _player.open(Media(widget.range.sourceVideo.path), play: false);
      await _player.seek(widget.range.inPoint);
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
    required this.shotNumber,
    required this.file,
    required this.label,
  });

  final int shotNumber;
  final File file;
  final String label;
}

Future<void> _showSourceImageGallery(
  BuildContext context,
  VideoGenerationController controller,
  String initialShotId,
) {
  final items = <_SourceGalleryItem>[];
  var initialIndex = 0;
  for (final shot in controller.value.shots) {
    final file = controller.sourceImageFileFor(shot);
    if (file == null) continue;
    if (shot.id == initialShotId) initialIndex = items.length;
    items.add(
      _SourceGalleryItem(
        shotNumber: shot.shotNumber,
        file: file,
        label: controller.usesReplicatedImageFor(shot) ? '复刻分镜图' : '故事板原图',
      ),
    );
  }
  return showFullscreenZoomGallery<_SourceGalleryItem>(
    context: context,
    items: items,
    initialIndex: initialIndex,
    labelBuilder: (item, index, total) =>
        '镜头 ${item.shotNumber.toString().padLeft(2, '0')} · ${item.label} · ${index + 1}/$total',
    itemBuilder: (context, item) => Image.file(
      item.file,
      key: ValueKey('video-generation-source-gallery-image-${item.shotNumber}'),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Center(
        child: Text('首帧图无法读取', style: TextStyle(color: Colors.white)),
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
