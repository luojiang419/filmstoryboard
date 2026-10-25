import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/widgets/adaptive_video_viewport.dart';
import '../../../core/widgets/preview_file_image.dart';

/// 预览与详情共享有限高度，窗口缩小时仍保留可操作的详情区域。
class VideoAnalysisInspectorLayout extends StatelessWidget {
  const VideoAnalysisInspectorLayout({
    super.key,
    required this.aspectRatio,
    required this.preview,
    required this.details,
  });

  final double aspectRatio;
  final Widget preview;
  final Widget details;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = constraints.maxHeight < 240 ? 6.0 : 12.0;
        final availableHeight = math.max(0.0, constraints.maxHeight - gap);
        final detailsHeight = math.min(224.0, availableHeight / 2);
        final size = constrainedVideoSize(
          maxWidth: constraints.maxWidth,
          maxHeight: availableHeight - detailsHeight,
          aspectRatio: aspectRatio,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SizedBox(
                key: const ValueKey('analysis-inspector-preview-viewport'),
                width: size.width,
                height: size.height,
                child: preview,
              ),
            ),
            SizedBox(height: gap),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

/// 选中帧直接使用抽帧图，避免暂停视频纹理的内部缩放影响检查画面。
class VideoAnalysisFramePreview extends StatelessWidget {
  const VideoAnalysisFramePreview({
    super.key,
    required this.path,
    required this.onOpenVideo,
  });

  final String path;
  final VoidCallback onOpenVideo;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '点击全屏预览视频',
      child: Semantics(
        button: true,
        label: '全屏预览当前镜头视频',
        child: InkWell(
          onTap: onOpenVideo,
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PreviewFileImage(
                    key: ValueKey(path),
                    path: path,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Center(child: Text('镜头帧加载失败，点击预览原视频')),
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
      ),
    );
  }
}
