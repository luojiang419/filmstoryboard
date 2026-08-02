import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../data/video_analysis_repository.dart';
import '../domain/video_analysis_models.dart';

class VideoAnalysisRunResult {
  const VideoAnalysisRunResult({
    required this.completedCount,
    required this.failedCount,
    required this.summary,
    this.interrupted = false,
  });

  final int completedCount;
  final int failedCount;
  final VideoSummary? summary;
  final bool interrupted;
}

class VideoFrameAnalysisFieldMapper {
  const VideoFrameAnalysisFieldMapper._();

  static Map<String, String> fromVision(VisionImageAnalysis analysis) => {
    'caption': analysis.caption,
    'detail': analysis.detail,
    'scene': analysis.scene,
    'props': analysis.props,
    'people': analysis.people,
    'expression': analysis.expression,
    'bodyAction': analysis.bodyAction,
    'movementTrend': analysis.movementTrend,
    'cameraMovement': analysis.cameraMovement,
    'shotSize': analysis.shotSize,
    'composition': analysis.composition,
    'subjectDirection': analysis.subjectDirection,
    'gazeDirection': analysis.gazeDirection,
    'actionStage': analysis.actionStage,
    'spatialRelation': analysis.spatialRelation,
    'chronologyCue': analysis.chronologyCue,
    'cameraAngle': analysis.cameraAngle,
    'visualFocus': analysis.visualFocus,
    'lightingMood': analysis.lightingMood,
    'colorPalette': analysis.colorPalette,
    'narrativeFunction': analysis.narrativeFunction,
    'transitionHint': analysis.transitionHint,
  };
}

class VideoAnalysisService {
  VideoAnalysisService({
    required this.repository,
    VisionStoryboardService? visionService,
    Uuid uuid = const Uuid(),
  }) : visionService = visionService ?? VisionStoryboardService(),
       _uuid = uuid;

  final VideoAnalysisRepository repository;
  final VisionStoryboardService visionService;
  final Uuid _uuid;

  Future<VideoAnalysisRunResult> analyzeFrames({
    required AppSettings settings,
    required SourceVideo video,
    required List<VideoFrame> frames,
    File Function(VideoFrame frame)? resolveFrame,
    void Function(int completed, int total)? onProgress,
    void Function(VideoFrameAnalysis analysis)? onFrameCompleted,
    bool Function()? shouldContinue,
  }) async {
    var completed = 0;
    var failed = 0;
    for (var index = 0; index < frames.length; index++) {
      if (shouldContinue?.call() == false) {
        return VideoAnalysisRunResult(
          completedCount: completed,
          failedCount: failed,
          summary: repository.getVideoSummary(video.id),
          interrupted: true,
        );
      }
      final frame = frames[index];
      final now = DateTime.now().toUtc();
      try {
        final analysis = await visionService.analyzeImage(
          settings: settings,
          imageFile: resolveFrame?.call(frame) ?? File(frame.path),
          sequenceNo: index + 1,
          rowIndex: 0,
          columnIndex: index,
          allowThinking: settings.videoAnalysisThinkingEnabled,
        );
        final record = VideoFrameAnalysis(
          id: '${video.id}-${frame.id}',
          videoId: video.id,
          frameId: frame.id,
          sequenceNo: frame.index + 1,
          dimensions: VideoFrameAnalysisFieldMapper.fromVision(analysis),
          rawResponse: analysis.rawResponse,
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: DateTime.now().toUtc(),
        );
        repository
          ..upsertVideoFrameAnalysis(record)
          ..upsertVideoFrame(
            frame.copyWith(
              status: ProcessingStatus.completed,
              errorMessage: '',
            ),
          );
        onFrameCompleted?.call(record);
        completed++;
      } catch (error) {
        if (shouldContinue?.call() == false) {
          return VideoAnalysisRunResult(
            completedCount: completed,
            failedCount: failed,
            summary: repository.getVideoSummary(video.id),
            interrupted: true,
          );
        }
        failed++;
        final record = VideoFrameAnalysis(
          id: '${video.id}-${frame.id}',
          videoId: video.id,
          frameId: frame.id,
          sequenceNo: frame.index + 1,
          dimensions: const {},
          rawResponse: '',
          status: ProcessingStatus.failed,
          errorMessage: '$error',
          createdAt: now,
          updatedAt: DateTime.now().toUtc(),
        );
        repository
          ..upsertVideoFrameAnalysis(record)
          ..upsertVideoFrame(
            frame.copyWith(
              status: ProcessingStatus.failed,
              errorMessage: '$error',
            ),
          );
        onFrameCompleted?.call(record);
      }
      onProgress?.call(index + 1, frames.length);
    }

    if (shouldContinue?.call() == false) {
      return VideoAnalysisRunResult(
        completedCount: completed,
        failedCount: failed,
        summary: repository.getVideoSummary(video.id),
        interrupted: true,
      );
    }

    final storedAnalyses = repository
        .listVideoFrameAnalyses(video.id)
        .where((item) => item.status == ProcessingStatus.completed)
        .toList();
    final analyses = storedAnalyses.map(_visionFromStored).toList();
    final totalFailed = repository
        .listVideoFrameAnalyses(video.id)
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    final summary = await _saveSummary(video, settings, analyses, totalFailed);
    final allFrames = repository.listVideoFrames(video.id);
    _saveShots(video, allFrames, storedAnalyses);
    await _saveMarketingAnalysis(
      video,
      settings,
      allFrames,
      storedAnalyses,
      summary,
      analyses,
    );
    repository.upsertSourceVideo(
      video.copyWith(
        successfulFrames: storedAnalyses.length,
        failedFrames: totalFailed,
        status: totalFailed == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        errorMessage: totalFailed == 0 ? '' : '$totalFailed 个帧解析失败',
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    return VideoAnalysisRunResult(
      completedCount: completed,
      failedCount: failed,
      summary: summary,
    );
  }

  VisionImageAnalysis _visionFromStored(VideoFrameAnalysis analysis) {
    String value(String key) => analysis.dimensions[key] ?? '';
    return VisionImageAnalysis(
      caption: value('caption'),
      detail: value('detail'),
      scene: value('scene'),
      props: value('props'),
      people: value('people'),
      expression: value('expression'),
      bodyAction: value('bodyAction'),
      movementTrend: value('movementTrend'),
      cameraMovement: value('cameraMovement'),
      shotSize: value('shotSize'),
      composition: value('composition'),
      subjectDirection: value('subjectDirection'),
      gazeDirection: value('gazeDirection'),
      actionStage: value('actionStage'),
      spatialRelation: value('spatialRelation'),
      chronologyCue: value('chronologyCue'),
      cameraAngle: value('cameraAngle'),
      visualFocus: value('visualFocus'),
      lightingMood: value('lightingMood'),
      colorPalette: value('colorPalette'),
      narrativeFunction: value('narrativeFunction'),
      transitionHint: value('transitionHint'),
      rawResponse: analysis.rawResponse,
    );
  }

  void _saveShots(
    SourceVideo video,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> analyses,
  ) {
    final analysisByFrame = {for (final item in analyses) item.frameId: item};
    final focusFrames = frames
        .where(
          (frame) =>
              (frame.isFocus || frame.isSelected) &&
              analysisByFrame.containsKey(frame.id),
        )
        .toList();
    repository.deleteVideoShots(video.id);
    final now = DateTime.now().toUtc();
    for (var index = 0; index < focusFrames.length; index++) {
      final frame = focusFrames[index];
      final analysis = analysisByFrame[frame.id]!;
      repository.upsertVideoShot(
        VideoShot(
          id: '${video.id}-shot-${index + 1}',
          videoId: video.id,
          shotNumber: index + 1,
          startMs: frame.timestampMs,
          endMs: index + 1 < focusFrames.length
              ? focusFrames[index + 1].timestampMs
              : video.durationMs,
          primaryFrameId: frame.id,
          frameIds: [frame.id],
          description: analysis.dimensions['caption'] ?? '',
          storyFlow:
              analysis.dimensions['narrativeFunction'] ??
              analysis.dimensions['detail'] ??
              '',
          status: ProcessingStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  Future<void> _saveMarketingAnalysis(
    SourceVideo video,
    AppSettings settings,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> storedAnalyses,
    VideoSummary summary,
    List<VisionImageAnalysis> visionAnalyses,
  ) async {
    String joinField(String key, {int limit = 6}) {
      final values = storedAnalyses
          .map((item) => item.dimensions[key]?.trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(limit)
          .toList();
      return values.join('；');
    }

    final openingFrameIds = frames
        .where((frame) => frame.timestampMs <= 3000)
        .map((frame) => frame.id)
        .toSet();
    final opening = storedAnalyses
        .where((item) => openingFrameIds.contains(item.frameId))
        .map((item) => item.dimensions['caption']?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .join('；');
    const pending = '画面信息不足，需人工确认';
    final dimensions = <String, String>{
      '开场类型': storedAnalyses.isEmpty
          ? pending
          : (storedAnalyses.first.dimensions['narrativeFunction'] ?? '画面建立'),
      '黄金3秒内容': opening.isEmpty ? pending : opening,
      '留存钩子': joinField('visualFocus').isEmpty
          ? pending
          : joinField('visualFocus'),
      '视频结构': summary.fields['outline'] ?? pending,
      '镜头节奏': frames.length < 2
          ? pending
          : '共 ${frames.length} 个候选帧，平均间隔约 '
                '${(video.durationMs / (frames.length - 1) / 1000).toStringAsFixed(1)} 秒',
      '信息密度': '成功解析 ${storedAnalyses.length} 个焦点帧',
      '出现时间': joinField('props').isEmpty ? pending : '见镜头道具与产品字段',
      '产品展示方式': joinField('props').isEmpty ? pending : joinField('props'),
      '卖点表达': pending,
      '场景': joinField('scene').isEmpty ? pending : joinField('scene'),
      '画面风格': joinField('lightingMood').isEmpty
          ? pending
          : joinField('lightingMood'),
      '色彩': joinField('colorPalette').isEmpty
          ? pending
          : joinField('colorPalette'),
      '刺激点': joinField('visualFocus').isEmpty
          ? pending
          : joinField('visualFocus'),
      '购买理由': pending,
      'CTA': pending,
      '福利': pending,
      '评论引导': pending,
    };
    var rawResponse = summary.rawResponse;
    var marketingStatus = summary.status;
    var marketingError = summary.errorMessage;
    try {
      final modelResult = await visionService.analyzeVideoDimensions(
        settings: settings,
        analyses: visionAnalyses,
        summary: summary.fields,
        allowThinking: settings.videoAnalysisThinkingEnabled,
      );
      for (final entry in modelResult.dimensions.entries) {
        if (entry.value.trim().isNotEmpty) {
          dimensions[entry.key] = entry.value.trim();
        }
      }
      rawResponse = modelResult.rawResponse;
    } catch (error) {
      marketingStatus = ProcessingStatus.partial;
      marketingError = '多维度分析使用本地可追溯结果：$error';
    }
    final now = DateTime.now().toUtc();
    repository.upsertMarketingAnalysis(
      MarketingAnalysis(
        id: '${video.id}-video-dimensions',
        videoId: video.id,
        scope: 'video',
        dimensions: dimensions,
        rawResponse: rawResponse,
        status: marketingStatus,
        errorMessage: marketingError,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<VideoSummary> _saveSummary(
    SourceVideo video,
    AppSettings settings,
    List<VisionImageAnalysis> analyses,
    int failedCount,
  ) async {
    final now = DateTime.now().toUtc();
    if (analyses.isEmpty) {
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: const {'outline': '', 'content': ''},
        rawResponse: '',
        status: ProcessingStatus.failed,
        errorMessage: '没有成功的帧解析结果',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    }
    try {
      final result = await visionService.summarizeStoryboard(
        settings: settings,
        analyses: analyses,
        allowThinking: settings.videoAnalysisThinkingEnabled,
      );
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: {
          'outline': result.outline,
          'content': result.content,
          'scenes': result.scenes,
          'props': result.props,
        },
        rawResponse: result.rawResponse,
        status: failedCount == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        errorMessage: failedCount == 0 ? '' : '$failedCount 个帧解析失败',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    } catch (error) {
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: {
          'outline': composeVisionAnalysesOutline(analyses),
          'content': composeVisionAnalysesDescription(analyses),
        },
        rawResponse: '',
        status: failedCount == 0
            ? ProcessingStatus.partial
            : ProcessingStatus.failed,
        errorMessage: '$error',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    }
  }
}
