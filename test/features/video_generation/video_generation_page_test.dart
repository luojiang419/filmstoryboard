import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('完成视频恢复格子内直接点击播放，生成中格子不使用持续动画', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync();

    expect(source, contains('class _InlineGeneratedVideoPlayer'));
    expect(
      source,
      contains("key: ValueKey('generated-video-player-\${latest!.id}')"),
    );
    expect(source, contains('generated-video-play-\${widget.file.path}'));
    expect(
      source,
      isNot(contains('class _GeneratedVideoCompletedPlaceholder')),
    );
    expect(source, isNot(contains('点击预览时才加载播放器')));
    expect(source, isNot(contains('CircularProgressIndicator')));
    expect(source, isNot(contains('Timer.periodic')));
    expect(source, contains('Future<void> _showFullscreenGeneratedVideo'));
    expect(source, contains('class _FullscreenGeneratedVideo'));
    expect(source, contains('LogicalKeyboardKey.escape'));
    expect(source, contains('KeyEventResult.handled'));
    expect(source, contains('class _HistoryVideoVersionCard'));
    expect(source, contains("GridView.builder"));
    expect(
      source,
      contains("key: ValueKey('generated-video-history-card-\${task.id}')"),
    );
    expect(source, contains('controller.generatedVideoFileFor(task)'));
    expect(source, contains('缩略图加载失败'));
    expect(source, contains('本地视频不可用'));
    expect(source, contains("VideoGenerationTaskStatus.running => '视频生成中'"));
    expect(source, contains("? '首帧图'"));
    expect(source, contains(": '复刻分镜图'"));
    expect(source, contains('来源：复刻分镜图'));
    expect(source, contains('来源：视频帧图'));
    expect(source, contains("value: 'continue_query'"));
    expect(source, contains("Text('继续查询')"));
    expect(source, contains('controller.resumeTaskQuery(latest)'));
    expect(source, contains('controller.generatedVideoFileFor(latest)'));
    expect(source, isNot(contains('File(latest.localPath)')));
    expect(source, isNot(contains('已等待')));
    expect(source, isNot(contains('generated-video-elapsed-')));
    expect(source, isNot(contains('String _formatElapsed')));
    expect(source, contains("VideoGenerationTaskStatus.queued => '排队等待中'"));
    expect(
      source,
      contains('tasks.where(_shouldKeepVideoTaskInCell).firstOrNull'),
    );
    expect(source, contains('bool _shouldKeepVideoTaskInCell'));
    final keepHelperStart = source.indexOf('bool _shouldKeepVideoTaskInCell');
    final labelHelperStart = source.indexOf(
      'String _activeVideoTaskLabel',
      keepHelperStart,
    );
    final keepHelper = source.substring(keepHelperStart, labelHelperStart);
    expect(
      keepHelper,
      isNot(contains('task.status == VideoGenerationTaskStatus.canceled')),
    );
    expect(
      source,
      isNot(contains("VideoGenerationTaskStatus.running => '正在生成视频'")),
    );
    expect(source, isNot(contains('正在启动隐藏 ComfyUI 后端并加载 H3 模型')));

    final progressBranch = source.indexOf('else if (isGenerating)');
    final completedBranch = source.indexOf('else if (hasLocalVideo)');
    expect(progressBranch, greaterThanOrEqualTo(0));
    expect(completedBranch, greaterThanOrEqualTo(0));
    expect(progressBranch, lessThan(completedBranch));
  });

  test('生成视频右侧作品管理面板按脚本镜头顺序复用本地播放器', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync();

    expect(
      source,
      contains("key: const ValueKey('video-generation-work-management-panel')"),
    );
    expect(source, contains("'video-generation-work-panel-resize-handle'"));
    expect(source, contains("'expand-video-generation-work-management-panel'"));
    expect(
      source,
      contains("'collapse-video-generation-work-management-panel'"),
    );
    expect(source, contains("SystemMouseCursors.resizeColumn"));
    expect(source, contains("final panel = _WorkManagementPanel("));
    expect(source, contains("class _WorkManagementPanel"));
    expect(source, contains("'作品管理'"));
    expect(
      source,
      contains("List<_WorkVideoTaskEntry> _orderedWorkVideoTaskEntries"),
    );
    expect(source, contains("for (final shot in state.shots)"));
    expect(source, contains("task.shotId == shot.id"));
    expect(source, contains("task.scriptId == selectedScriptId"));
    expect(source, contains("class _WorkManagementVideoItem"));
    expect(
      source,
      contains(
        "key: ValueKey(\n                        'work-management-generated-video-player-\${task.id}',",
      ),
    );
    expect(source, contains("file: file"));
    expect(source, contains("_showFullscreenGeneratedVideo("));
    expect(source, contains("_missingWorkVideoMessage(task)"));
    expect(source, contains("该脚本暂无生成作品"));

    final itemStart = source.indexOf('class _WorkManagementVideoItem');
    final entryStart = source.indexOf('class _WorkVideoTaskEntry', itemStart);
    expect(itemStart, greaterThanOrEqualTo(0));
    expect(entryStart, greaterThan(itemStart));
    final itemSource = source.substring(itemStart, entryStart);
    expect(itemSource, contains("_InlineGeneratedVideoPlayer("));
    expect(itemSource, isNot(contains('onGenerate')));
    expect(itemSource, isNot(contains('generateShot')));
  });
}
