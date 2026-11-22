import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';
import 'video_file_picker.dart';

typedef VideoFilePicker = Future<RemoteSelectedVideoFile?> Function();

class VideoAnalysisPage extends StatelessWidget {
  const VideoAnalysisPage({
    super.key,
    required this.controller,
    this.pickFile = pickVideoFile,
  });

  final RemoteAppController controller;
  final VideoFilePicker pickFile;

  @override
  Widget build(BuildContext context) {
    if (!controller.videoAnalysisAvailable) {
      return const _UnavailableState();
    }
    return Column(
      children: [
        _PageHeader(controller: controller, pickFile: pickFile),
        if (controller.videoCommandBusy)
          const LinearProgressIndicator(minHeight: 2),
        if (controller.uploadingFileName.isNotEmpty)
          _UploadProgress(controller: controller),
        Expanded(
          child: controller.videos.isEmpty
              ? _EmptyState(controller: controller, pickFile: pickFile)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final desktop = constraints.maxWidth >= 900;
                    return desktop
                        ? Row(
                            children: [
                              SizedBox(
                                width: 286,
                                child: _VideoList(
                                  controller: controller,
                                  horizontal: false,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: _VideoDetailPane(controller: controller),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              SizedBox(
                                height: 112,
                                child: _VideoList(
                                  controller: controller,
                                  horizontal: true,
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: _VideoDetailPane(controller: controller),
                              ),
                            ],
                          );
                  },
                ),
        ),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.controller, required this.pickFile});

  final RemoteAppController controller;
  final VideoFilePicker pickFile;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '视频解析',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${controller.videos.length} 个参考视频 · 抽帧和视觉解析均由本机执行',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('refresh-video-analysis'),
          tooltip: '刷新视频解析状态',
          onPressed: controller.videoCommandBusy
              ? null
              : controller.refreshVideoAnalysis,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          key: const ValueKey('upload-video'),
          onPressed:
              controller.canEdit &&
                  controller.videoUploadsAvailable &&
                  !controller.videoCommandBusy
              ? () async {
                  final file = await pickFile();
                  if (file != null) await controller.uploadVideo(file);
                }
              : null,
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text('上传视频'),
        ),
      ],
    ),
  );
}

class _UploadProgress extends StatelessWidget {
  const _UploadProgress({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.uploadTotalBytes;
    final value = total <= 0
        ? null
        : (controller.uploadedBytes / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Semantics(
        label: '正在上传 ${controller.uploadingFileName}',
        child: LinearProgressIndicator(value: value, minHeight: 6),
      ),
    );
  }
}

class _VideoList extends StatelessWidget {
  const _VideoList({required this.controller, required this.horizontal});

  final RemoteAppController controller;
  final bool horizontal;

  @override
  Widget build(BuildContext context) => ListView.separated(
    key: const ValueKey('remote-video-list'),
    padding: const EdgeInsets.all(12),
    scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
    itemCount: controller.videos.length,
    separatorBuilder: (_, _) =>
        SizedBox(width: horizontal ? 10 : 0, height: horizontal ? 0 : 8),
    itemBuilder: (context, index) {
      final video = controller.videos[index];
      final selected = controller.selectedVideo?.video.id == video.id;
      return SizedBox(
        width: horizontal ? 238 : null,
        child: Card(
          margin: EdgeInsets.zero,
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: InkWell(
            key: ValueKey('remote-video-${video.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => controller.selectVideo(video.id),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    video.isPortrait
                        ? Icons.stay_current_portrait_rounded
                        : Icons.movie_outlined,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_duration(video.durationMs)} · ${video.frameCount} 帧',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  _StatusDot(status: video.status),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _VideoDetailPane extends StatelessWidget {
  const _VideoDetailPane({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final detail = controller.selectedVideo;
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final frame = controller.selectedVideoFrame;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showInspector = constraints.maxWidth >= 1060;
        final workspace = SingleChildScrollView(
          key: const ValueKey('remote-video-detail'),
          padding: const EdgeInsets.all(20),
          child: _VideoWorkspaceContent(controller: controller, detail: detail),
        );
        final inspector = _FrameInspector(
          frame: frame,
          detail: detail,
          embedded: !showInspector,
        );
        if (!showInspector) {
          return SingleChildScrollView(
            key: const ValueKey('remote-video-detail'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _VideoWorkspaceContent(controller: controller, detail: detail),
                const SizedBox(height: 16),
                inspector,
              ],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: workspace),
            const VerticalDivider(width: 1),
            SizedBox(
              key: const ValueKey('video-frame-analysis-sidebar'),
              width: 390,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: inspector,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _VideoWorkspaceContent extends StatelessWidget {
  const _VideoWorkspaceContent({
    required this.controller,
    required this.detail,
  });

  final RemoteAppController controller;
  final RemoteVideoDetail detail;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1040),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VideoSummaryCard(controller: controller, detail: detail),
          if (controller.videoTasks.isNotEmpty) ...[
            const SizedBox(height: 16),
            _TaskPanel(controller: controller),
          ],
          const SizedBox(height: 18),
          _CandidateFramesSection(controller: controller, detail: detail),
        ],
      ),
    ),
  );
}

class _CandidateFramesSection extends StatelessWidget {
  const _CandidateFramesSection({
    required this.controller,
    required this.detail,
  });

  final RemoteAppController controller;
  final RemoteVideoDetail detail;

  @override
  Widget build(BuildContext context) {
    final state = detail.analysisState;
    final canWrite = controller.canEdit && !controller.videoCommandBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '候选帧 · ${detail.frames.length}',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            IconButton(
              key: const ValueKey('undo-video-frame-removal'),
              tooltip: '撤销移除候选帧',
              onPressed: canWrite && state.canUndoFrameRemoval
                  ? controller.undoVideoFrameRemoval
                  : null,
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              key: const ValueKey('redo-video-frame-removal'),
              tooltip: '再次移除候选帧',
              onPressed: canWrite && state.canRedoFrameRemoval
                  ? controller.redoVideoFrameRemoval
                  : null,
              icon: const Icon(Icons.redo_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (detail.frames.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(22),
              child: Text('尚无候选帧。视频导入任务完成后会自动显示。'),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth >= 900
                  ? 4
                  : constraints.maxWidth >= 620
                  ? 3
                  : 2;
              return GridView.builder(
                key: const ValueKey('remote-video-frame-grid'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: detail.frames.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.03,
                ),
                itemBuilder: (context, index) => _FrameCard(
                  controller: controller,
                  frame: detail.frames[index],
                  selected:
                      detail.frames[index].id ==
                      controller.selectedVideoFrameId,
                ),
              );
            },
          ),
      ],
    );
  }
}

class _VideoSummaryCard extends StatelessWidget {
  const _VideoSummaryCard({required this.controller, required this.detail});

  final RemoteAppController controller;
  final RemoteVideoDetail detail;

  @override
  Widget build(BuildContext context) {
    final video = detail.video;
    final state = detail.analysisState;
    final canWrite = controller.canEdit && !controller.videoCommandBusy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 14,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  video.fileName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                Chip(
                  label: Text(
                    '${video.displayWidth}×${video.displayHeight} · ${video.isPortrait ? '竖屏' : '横屏'}',
                  ),
                ),
                Chip(label: Text('${video.frameRate.toStringAsFixed(2)} fps')),
                Chip(label: Text(video.hasAudio ? '含音轨' : '无音轨')),
              ],
            ),
            if (state.message.isNotEmpty || state.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                state.errorMessage.isNotEmpty
                    ? state.errorMessage
                    : state.message,
                style: TextStyle(
                  color: state.errorMessage.isNotEmpty
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ],
            if (state.isAnalyzing || state.isPaused || state.total > 0) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: state.total <= 0
                    ? null
                    : (state.current / state.total).clamp(0.0, 1.0),
              ),
              const SizedBox(height: 5),
              Text('${state.current}/${state.total} 帧'),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                FilledButton.icon(
                  key: const ValueKey('analyze-video'),
                  onPressed: canWrite && !state.isAnalyzing
                      ? controller.startSelectedVideoAnalysis
                      : null,
                  icon: Icon(
                    state.isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.auto_awesome_rounded,
                  ),
                  label: Text(state.isPaused ? '继续解析' : '开始解析'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('pause-video-analysis'),
                  onPressed: canWrite && state.isAnalyzing
                      ? controller.pauseSelectedVideoAnalysis
                      : null,
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('暂停'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('cancel-video-analysis'),
                  onPressed: canWrite && state.isAnalyzing
                      ? controller.cancelSelectedVideoAnalysis
                      : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('取消'),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('generate-video-storyboard'),
                  onPressed: canWrite && !state.isAnalyzing
                      ? controller.generateSelectedVideoStoryboard
                      : null,
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('生成故事板'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskPanel extends StatelessWidget {
  const _TaskPanel({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      initiallyExpanded: controller.videoTasks.any((task) => !task.terminal),
      leading: const Icon(Icons.sync_rounded),
      title: const Text('本机任务'),
      subtitle: Text('${controller.videoTasks.length} 条可恢复记录'),
      children: [
        for (final task in controller.videoTasks.take(6))
          ListTile(
            key: ValueKey('remote-task-${task.id}'),
            leading: _TaskIcon(status: task.status),
            title: Text(_taskLabel(task.kind)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.errorMessage.isNotEmpty
                      ? task.errorMessage
                      : task.message,
                ),
                if (!task.terminal)
                  LinearProgressIndicator(value: task.progress),
              ],
            ),
            trailing: task.cancellable && controller.canEdit
                ? IconButton(
                    tooltip: '取消任务',
                    onPressed: () => controller.cancelRemoteTask(task.id),
                    icon: const Icon(Icons.close_rounded),
                  )
                : null,
          ),
      ],
    ),
  );
}

class _FrameCard extends StatelessWidget {
  const _FrameCard({
    required this.controller,
    required this.frame,
    required this.selected,
  });

  final RemoteAppController controller;
  final RemoteVideoFrame frame;
  final bool selected;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
    child: InkWell(
      key: ValueKey('remote-frame-${frame.id}'),
      onTap: () => controller.selectVideoFrame(frame.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _RemoteFrameImage(
                  controller: controller,
                  mediaId: frame.mediaId,
                ),
                if (controller.canEdit)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: Colors.black.withValues(alpha: .62),
                      shape: const CircleBorder(),
                      child: IconButton(
                        key: ValueKey('remove-video-frame-${frame.id}'),
                        tooltip: '移除候选帧',
                        visualDensity: VisualDensity.compact,
                        onPressed: controller.videoCommandBusy
                            ? null
                            : () => controller.removeVideoFrame(frame.id),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                if (frame.isFocus) ...[
                  const Icon(Icons.center_focus_strong_rounded, size: 15),
                  const SizedBox(width: 4),
                ],
                Expanded(child: Text(_duration(frame.timestampMs))),
                _StatusDot(status: frame.status),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _FrameInspector extends StatelessWidget {
  const _FrameInspector({
    required this.frame,
    required this.detail,
    required this.embedded,
  });

  final RemoteVideoFrame? frame;
  final RemoteVideoDetail detail;
  final bool embedded;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Icon(Icons.analytics_outlined),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '帧分析面板',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          if (!embedded)
            Tooltip(
              message: '固定右侧面板',
              child: Icon(
                Icons.vertical_split_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (frame == null)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text('选择候选帧后在这里查看结构化分析。'),
          ),
        )
      else
        _FrameAnalysisPanel(frame: frame!),
      if (detail.marketingAnalyses.isNotEmpty || detail.summary != null) ...[
        const SizedBox(height: 14),
        _OverallAnalysis(detail: detail),
      ],
    ],
  );
}

class _FrameAnalysisPanel extends StatelessWidget {
  const _FrameAnalysisPanel({required this.frame});

  final RemoteVideoFrame frame;

  @override
  Widget build(BuildContext context) {
    final dimensions = frame.analysis?.dimensions ?? const {};
    final groups = _groupFrameDimensions(dimensions);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前帧分析 · ${_duration(frame.timestampMs)}',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            Text(
              '清晰度 ${frame.sharpness.toStringAsFixed(2)} · 亮度 ${frame.brightness.toStringAsFixed(2)} · 动态 ${frame.motionScore.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 14),
            if (dimensions.isEmpty)
              const Text('该候选帧尚未完成视觉解析。')
            else
              for (final group in groups) ...[
                _AnalysisGroup(title: group.$1, values: group.$2),
                if (group != groups.last) const SizedBox(height: 14),
              ],
          ],
        ),
      ),
    );
  }

  static List<(String, Map<String, String>)> _groupFrameDimensions(
    Map<String, String> dimensions,
  ) {
    const definitions = <(String, List<String>)>[
      ('画面概述', ['caption', 'detail', 'scene', 'chronologyCue']),
      (
        '主体与动作',
        [
          'people',
          'expression',
          'props',
          'bodyAction',
          'movementTrend',
          'actionStage',
        ],
      ),
      (
        '镜头与构图',
        [
          'shotSize',
          'cameraMovement',
          'composition',
          'cameraAngle',
          'subjectDirection',
          'gazeDirection',
          'spatialRelation',
          'visualFocus',
        ],
      ),
      ('光影与风格', ['lightingMood', 'colorPalette']),
    ];
    final used = <String>{};
    final result = <(String, Map<String, String>)>[];
    for (final definition in definitions) {
      final values = <String, String>{};
      for (final key in definition.$2) {
        final value = dimensions[key]?.trim() ?? '';
        if (value.isEmpty) continue;
        used.add(key);
        values[key] = value;
      }
      if (values.isNotEmpty) result.add((definition.$1, values));
    }
    final remaining = <String, String>{
      for (final entry in dimensions.entries)
        if (!used.contains(entry.key) && entry.value.trim().isNotEmpty)
          entry.key: entry.value.trim(),
    };
    if (remaining.isNotEmpty) result.add(('其他分析', remaining));
    return result;
  }
}

class _AnalysisGroup extends StatelessWidget {
  const _AnalysisGroup({required this.title, required this.values});

  final String title;
  final Map<String, String> values;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
            for (final entry in values.entries) ...[
              const SizedBox(height: 9),
              Text(
                _dimensionLabel(entry.key),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(entry.value),
            ],
          ],
        ),
      ),
    );
  }

  static String _dimensionLabel(String key) => switch (key) {
    'caption' => '画面描述',
    'detail' => '细节',
    'scene' => '场景',
    'chronologyCue' => '时间线索',
    'people' => '人物',
    'expression' => '表情',
    'props' => '道具',
    'bodyAction' => '身体动作',
    'movementTrend' => '运动趋势',
    'actionStage' => '动作阶段',
    'shotSize' => '景别',
    'cameraMovement' => '运镜',
    'composition' => '构图',
    'cameraAngle' => '机位角度',
    'subjectDirection' => '主体方向',
    'gazeDirection' => '视线方向',
    'spatialRelation' => '空间关系',
    'visualFocus' => '视觉焦点',
    'lightingMood' => '光影氛围',
    'colorPalette' => '色彩方案',
    _ => key,
  };
}

class _OverallAnalysis extends StatelessWidget {
  const _OverallAnalysis({required this.detail});

  final RemoteVideoDetail detail;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '整片分析与总结',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          for (final analysis in detail.marketingAnalyses) ...[
            const SizedBox(height: 12),
            Text(
              analysis.scope.isEmpty ? '多维分析' : analysis.scope,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            _KeyValueWrap(values: analysis.dimensions),
          ],
          if (detail.summary != null) ...[
            const SizedBox(height: 14),
            const Divider(),
            const SizedBox(height: 8),
            _KeyValueWrap(values: detail.summary!.fields),
          ],
        ],
      ),
    ),
  );
}

class _KeyValueWrap extends StatelessWidget {
  const _KeyValueWrap({required this.values});

  final Map<String, String> values;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final entry in values.entries)
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 360),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(entry.value),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _RemoteFrameImage extends StatelessWidget {
  const _RemoteFrameImage({required this.controller, required this.mediaId});

  final RemoteAppController controller;
  final String? mediaId;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.image_outlined)),
    );
    if (mediaId == null) return placeholder;
    return FutureBuilder<Uint8List>(
      future: controller.mediaBytes(mediaId!),
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            )
          : placeholder,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller, required this.pickFile});

  final RemoteAppController controller;
  final VideoFilePicker pickFile;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_file_outlined, size: 68),
          const SizedBox(height: 16),
          Text(
            '上传第一个参考视频',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text('视频会流式发送到当前工程，本机完成抽帧、解析和建板。'),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: controller.canEdit && controller.videoUploadsAvailable
                ? () async {
                    final file = await pickFile();
                    if (file != null) await controller.uploadVideo(file);
                  }
                : null,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('选择视频'),
          ),
        ],
      ),
    ),
  );
}

class _UnavailableState extends StatelessWidget {
  const _UnavailableState();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(28),
      child: Text('当前桌面端尚未开放视频解析能力。'),
    ),
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: switch (status) {
        'completed' || 'succeeded' => const Color(0xff43c78a),
        'failed' => Theme.of(context).colorScheme.error,
        'running' || 'retrying' => Theme.of(context).colorScheme.primary,
        _ => Theme.of(context).colorScheme.outline,
      },
      shape: BoxShape.circle,
    ),
  );
}

class _TaskIcon extends StatelessWidget {
  const _TaskIcon({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Icon(switch (status) {
    'succeeded' => Icons.check_circle_outline_rounded,
    'failed' => Icons.error_outline_rounded,
    'cancelled' => Icons.cancel_outlined,
    _ => Icons.sync_rounded,
  });
}

String _duration(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _taskLabel(String kind) => switch (kind) {
  'videoImport' => '视频导入与抽帧',
  'videoAnalysis' => '视频视觉解析',
  'videoStoryboard' => '故事板与拍摄脚本生成',
  _ => kind,
};
