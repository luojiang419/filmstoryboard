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
    expect(source, contains("VideoGenerationTaskStatus.running => '视频生成中'"));
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
}
