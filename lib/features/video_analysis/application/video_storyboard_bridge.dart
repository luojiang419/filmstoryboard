import '../../storyboard/domain/storyboard_models.dart';
import '../domain/video_analysis_models.dart';

class VideoStoryboardBuildResult {
  const VideoStoryboardBuildResult({
    required this.sourceId,
    required this.boardName,
    required this.images,
    required this.summary,
  });

  final String sourceId;
  final String boardName;
  final List<StoryboardExternalImage> images;
  final StoryboardSummary? summary;
}

class VideoStoryboardBridge {
  const VideoStoryboardBridge._();

  static VideoStoryboardBuildResult build({
    required SourceVideo video,
    required List<VideoFrame> frames,
    required List<VideoFrameAnalysis> frameAnalyses,
    required List<VideoShot> shots,
    required VideoSummary? summary,
    required String Function(VideoFrame frame) resolveFramePath,
  }) {
    final analysesByFrameId = {
      for (final analysis in frameAnalyses)
        if (analysis.status == ProcessingStatus.completed)
          analysis.frameId: analysis,
    };
    final shotsByFrameId = {
      for (final shot in shots)
        if (shot.primaryFrameId != null) shot.primaryFrameId!: shot,
    };
    final orderedFrames =
        frames
            .where((frame) => analysesByFrameId.containsKey(frame.id))
            .toList()
          ..sort((first, second) {
            final byIndex = first.index.compareTo(second.index);
            if (byIndex != 0) {
              return byIndex;
            }
            return first.timestampMs.compareTo(second.timestampMs);
          });

    return VideoStoryboardBuildResult(
      sourceId: 'video:${video.id}',
      boardName: '${_videoBaseName(video.fileName)} · 视频解析故事板',
      summary: _storyboardSummary(summary),
      images: [
        for (final frame in orderedFrames)
          StoryboardExternalImage(
            stableId: 'video-frame:${frame.id}',
            sourceName: video.fileName,
            path: resolveFramePath(frame),
            width: frame.width,
            height: frame.height,
            caption: _storyboardCaption(
              shotsByFrameId[frame.id],
              analysesByFrameId[frame.id],
            ),
          ),
      ],
    );
  }

  static StoryboardSummary? _storyboardSummary(VideoSummary? summary) {
    if (summary == null || summary.status == ProcessingStatus.failed) {
      return null;
    }
    final mapped = StoryboardSummary(
      outline: summary.fields['outline'] ?? '',
      content: summary.fields['content'] ?? '',
      scenes: summary.fields['scenes'] ?? '',
      props: summary.fields['props'] ?? '',
    );
    return mapped.isEmpty ? null : mapped;
  }

  static String _storyboardCaption(
    VideoShot? shot,
    VideoFrameAnalysis? analysis,
  ) {
    final dimensions = analysis?.dimensions ?? const <String, String>{};
    final composed = [
      dimensions['scene'],
      dimensions['shotSize'],
      dimensions['cameraMovement'],
      dimensions['bodyAction'],
    ].where((value) => value?.trim().isNotEmpty == true).join('；');
    final candidates = [
      dimensions['caption'],
      dimensions['narrativeFunction'],
      shot?.storyFlow,
      shot?.description,
      dimensions['detail'],
      composed,
    ];
    for (final candidate in candidates) {
      final value = candidate?.trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '视频解析镜头';
  }

  static String _videoBaseName(String value) {
    final dot = value.lastIndexOf('.');
    return dot <= 0 ? value : value.substring(0, dot);
  }
}
