import 'dart:io';

import '../../remote_access/domain/remote_video_analysis_models.dart';
import '../domain/video_analysis_models.dart';
import 'video_analysis_controller.dart';

class VideoAnalysisRemoteSource implements RemoteVideoAnalysisSource {
  VideoAnalysisRemoteSource(this._controller);

  final VideoAnalysisController _controller;

  @override
  List<RemoteVideoRecord> get videos => _controller.value.videos
      .map((video) => _videoRecord(video))
      .toList(growable: false);

  @override
  RemoteVideoOperationProgress get operationProgress =>
      RemoteVideoOperationProgress(
        current: _controller.value.completedProgress,
        total: _controller.value.totalProgress,
        message: _controller.value.message,
      );

  @override
  RemoteVideoDetailRecord? videoById(String videoId) {
    final state = _controller.snapshotForVideo(videoId);
    final video = state.selectedVideo;
    if (video == null) return null;
    final analysisByFrame = {
      for (final analysis in state.frameAnalyses) analysis.frameId: analysis,
    };
    return RemoteVideoDetailRecord(
      video: _videoRecord(video),
      frames: state.frames
          .map((frame) => _frameRecord(frame, analysisByFrame[frame.id]))
          .toList(growable: false),
      shots: state.shots.map(_shotRecord).toList(growable: false),
      marketingAnalyses: state.marketingAnalyses
          .map(_marketingRecord)
          .toList(growable: false),
      summary: state.summary == null ? null : _summaryRecord(state.summary!),
      isAnalyzing: state.isAnalyzing,
      isPaused: state.isPaused,
      completedProgress: state.completedProgress,
      totalProgress: state.totalProgress,
      message: state.message,
      errorMessage: state.errorMessage,
      canUndoFrameRemoval: _controller.canUndoFrameRemovalFor(videoId),
      canRedoFrameRemoval: _controller.canRedoFrameRemovalFor(videoId),
    );
  }

  @override
  Future<RemoteVideoImportResult> importVideo(
    File file, {
    required String fileName,
  }) async {
    final previousIds = _controller.value.videos
        .map((video) => video.id)
        .toSet();
    await _controller.importUploadedVideo(file, fileName: fileName);
    final imported = _controller.value.videos
        .where((video) => !previousIds.contains(video.id))
        .firstOrNull;
    if (imported == null) {
      throw RemoteVideoAnalysisSourceException(
        'video_import_failed',
        _controller.value.errorMessage.isEmpty
            ? '视频导入或候选帧提取未完成'
            : _controller.value.errorMessage,
      );
    }
    return RemoteVideoImportResult(videoId: imported.id);
  }

  @override
  Future<void> startAnalysis(
    String videoId, {
    bool retryFailedOnly = false,
  }) async {
    if (_controller.value.selectedVideoId != videoId) {
      _controller.selectVideo(videoId);
    }
    await _controller.startAnalysis(
      videoId: videoId,
      retryFailedOnly: retryFailedOnly,
    );
  }

  @override
  bool pauseAnalysis(String videoId) => _controller.pauseAnalysisFor(videoId);

  @override
  bool cancelAnalysis(String videoId) => _controller.cancelAnalysisFor(videoId);

  @override
  Future<bool> generateStoryboard(String videoId) =>
      _controller.generateStoryboardForVideo(videoId);

  @override
  bool removeFrame(String videoId, String frameId) =>
      _controller.removeFrameFor(videoId, frameId);

  @override
  bool undoFrameRemoval(String videoId) =>
      _controller.undoFrameRemovalFor(videoId);

  @override
  bool redoFrameRemoval(String videoId) =>
      _controller.redoFrameRemovalFor(videoId);

  @override
  void addListener(void Function() listener) =>
      _controller.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      _controller.removeListener(listener);

  RemoteVideoRecord _videoRecord(SourceVideo video) => RemoteVideoRecord(
    id: video.id,
    fileName: video.fileName,
    durationMs: video.durationMs,
    frameRate: video.frameRate,
    width: video.width,
    height: video.height,
    displayWidth: video.displayWidth,
    displayHeight: video.displayHeight,
    rotationDegrees: video.rotationDegrees,
    hasAudio: video.hasAudio,
    frameCount: video.frameCount,
    successfulFrames: video.successfulFrames,
    failedFrames: video.failedFrames,
    status: video.status.name,
    errorMessage: video.errorMessage,
    createdAt: video.createdAt,
    updatedAt: video.updatedAt,
    localPath: _controller.resolveVideo(video).path,
  );

  RemoteVideoFrameRecord _frameRecord(
    VideoFrame frame,
    VideoFrameAnalysis? analysis,
  ) => RemoteVideoFrameRecord(
    id: frame.id,
    index: frame.index,
    timestampMs: frame.timestampMs,
    width: frame.width,
    height: frame.height,
    sharpness: frame.sharpness,
    brightness: frame.brightness,
    motionScore: frame.motionScore,
    isFocus: frame.isFocus,
    isSelected: frame.isSelected,
    status: frame.status.name,
    errorMessage: frame.errorMessage,
    createdAt: frame.createdAt,
    localPath: _controller.resolveFrame(frame).path,
    analysis: analysis == null
        ? null
        : RemoteVideoFrameAnalysisRecord(
            id: analysis.id,
            sequenceNo: analysis.sequenceNo,
            dimensions: Map.unmodifiable(analysis.dimensions),
            status: analysis.status.name,
            errorMessage: analysis.errorMessage,
            updatedAt: analysis.updatedAt,
          ),
  );

  static RemoteVideoShotRecord _shotRecord(VideoShot shot) =>
      RemoteVideoShotRecord(
        id: shot.id,
        shotNumber: shot.shotNumber,
        startMs: shot.startMs,
        endMs: shot.endMs,
        primaryFrameId: shot.primaryFrameId,
        frameIds: List.unmodifiable(shot.frameIds),
        description: shot.description,
        storyFlow: shot.storyFlow,
        status: shot.status.name,
      );

  static RemoteVideoAnalysisRecord _marketingRecord(
    MarketingAnalysis analysis,
  ) => RemoteVideoAnalysisRecord(
    id: analysis.id,
    scope: analysis.scope,
    dimensions: Map.unmodifiable(analysis.dimensions),
    status: analysis.status.name,
    errorMessage: analysis.errorMessage,
    updatedAt: analysis.updatedAt,
  );

  static RemoteVideoSummaryRecord _summaryRecord(VideoSummary summary) =>
      RemoteVideoSummaryRecord(
        id: summary.id,
        fields: Map.unmodifiable(summary.fields),
        status: summary.status.name,
        errorMessage: summary.errorMessage,
        updatedAt: summary.updatedAt,
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
