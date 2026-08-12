import '../domain/remote_events.dart';
import '../domain/remote_video_analysis_models.dart';
import 'remote_media_registry.dart';
import 'remote_task_registry.dart';
import 'remote_upload_registry.dart';
import 'remote_workspace_registry.dart';

class RemoteVideoAnalysisRegistry {
  RemoteVideoAnalysisRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    required RemoteMediaRegistry mediaRegistry,
    required RemoteUploadRegistry uploadRegistry,
    required RemoteTaskRegistry taskRegistry,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _uploadRegistry = uploadRegistry,
       _taskRegistry = taskRegistry;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final RemoteMediaRegistry _mediaRegistry;
  final RemoteUploadRegistry _uploadRegistry;
  final RemoteTaskRegistry _taskRegistry;
  final Map<String, String> _analysisTaskIds = {};

  RemoteVideoAnalysisSource? _source;
  String? _projectId;

  RemoteVideoAnalysisSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    return _source;
  }

  void attach(RemoteVideoAnalysisSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    source.addListener(_handleSourceChanged);
    _handleSourceChanged();
  }

  void detach({RemoteVideoAnalysisSource? source}) {
    if (source != null && !identical(source, _source)) return;
    _source?.removeListener(_handleSourceChanged);
    _source = null;
    _projectId = null;
    _analysisTaskIds.clear();
  }

  Map<String, Object?> collection() => {
    'items': [for (final video in _requireSource().videos) _videoJson(video)],
  };

  Map<String, Object?> detail(String videoId) {
    final detail = _requireVideo(videoId);
    return _detailJson(detail);
  }

  RemoteTaskSnapshot importUpload(String uploadId) {
    final currentSource = _requireSource();
    final upload = _uploadRegistry.claimCurrentProject(uploadId);
    if (upload == null) {
      throw const RemoteVideoAnalysisSourceException(
        'upload_not_found',
        '上传不存在、已被使用或不属于当前工程',
      );
    }
    return _taskRegistry.start(
      kind: 'videoImport',
      message: '等待导入视频并提取候选帧',
      runner: (execution) async {
        void reportProgress() {
          final progress = currentSource.operationProgress;
          execution.report(
            current: progress.current,
            total: progress.total,
            message: progress.message.isEmpty
                ? '正在导入 ${upload.fileName} 并提取候选帧'
                : progress.message,
          );
        }

        currentSource.addListener(reportProgress);
        reportProgress();
        try {
          final result = await currentSource.importVideo(
            upload.file,
            fileName: upload.fileName,
          );
          execution.report(current: 1, total: 1, message: '视频导入完成');
          return {
            'videoId': result.videoId,
            'video': _detailJson(_requireVideo(result.videoId)),
          };
        } finally {
          currentSource.removeListener(reportProgress);
          await _uploadRegistry.discard(upload);
        }
      },
    );
  }

  RemoteTaskSnapshot startAnalysis(
    String videoId, {
    bool retryFailedOnly = false,
  }) {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    final activeTaskId = _analysisTaskIds[videoId];
    final activeTask = activeTaskId == null
        ? null
        : _taskRegistry.getCurrentProject(activeTaskId);
    if (activeTask != null && !activeTask.terminal) return activeTask;
    late final RemoteTaskSnapshot task;
    task = _taskRegistry.start(
      kind: 'videoAnalysis',
      message: retryFailedOnly ? '等待重试失败帧' : '等待解析视频',
      onCancel: () => currentSource.cancelAnalysis(videoId),
      runner: (execution) async {
        void reportProgress() {
          final detail = currentSource.videoById(videoId);
          if (detail == null) return;
          execution.report(
            current: detail.completedProgress,
            total: detail.totalProgress,
            message: detail.message,
          );
        }

        currentSource.addListener(reportProgress);
        try {
          await currentSource.startAnalysis(
            videoId,
            retryFailedOnly: retryFailedOnly,
          );
          final detail = _requireVideo(videoId);
          execution.report(
            current: detail.completedProgress,
            total: detail.totalProgress,
            message: detail.message,
          );
          return {
            'videoId': videoId,
            'paused': detail.isPaused,
            'detail': _detailJson(detail),
          };
        } finally {
          currentSource.removeListener(reportProgress);
          if (_analysisTaskIds[videoId] == task.id) {
            _analysisTaskIds.remove(videoId);
          }
        }
      },
    );
    _analysisTaskIds[videoId] = task.id;
    return task;
  }

  Map<String, Object?> pauseAnalysis(String videoId) {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    if (!currentSource.pauseAnalysis(videoId)) {
      throw const RemoteVideoAnalysisSourceException(
        'video_not_analyzing',
        '该视频当前没有正在运行的解析任务',
      );
    }
    return _detailJson(_requireVideo(videoId));
  }

  Future<Map<String, Object?>> cancelAnalysis(String videoId) async {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    final taskId = _analysisTaskIds[videoId];
    final cancelled = currentSource.cancelAnalysis(videoId);
    if (taskId != null) await _taskRegistry.cancelCurrentProject(taskId);
    if (!cancelled && taskId == null) {
      throw const RemoteVideoAnalysisSourceException(
        'video_not_analyzing',
        '该视频当前没有正在运行的解析任务',
      );
    }
    return _detailJson(_requireVideo(videoId));
  }

  RemoteTaskSnapshot generateStoryboard(String videoId) {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    return _taskRegistry.start(
      kind: 'videoStoryboard',
      message: '等待生成故事板和拍摄脚本',
      runner: (execution) async {
        execution.report(current: 0, total: 1, message: '正在生成故事板和拍摄脚本');
        final generated = await currentSource.generateStoryboard(videoId);
        if (!generated) {
          throw const RemoteVideoAnalysisSourceException(
            'storyboard_not_generated',
            '没有生成新的故事板，请确认视频已完成候选帧提取',
          );
        }
        execution.report(current: 1, total: 1, message: '故事板和拍摄脚本已生成');
        return {'videoId': videoId, 'generated': true};
      },
    );
  }

  Map<String, Object?> removeFrame(String videoId, String frameId) {
    final currentSource = _requireSource();
    final detail = _requireVideo(videoId);
    if (!detail.frames.any((frame) => frame.id == frameId)) {
      throw const RemoteVideoAnalysisSourceException(
        'frame_not_found',
        '候选帧不存在或已被移除',
      );
    }
    if (!currentSource.removeFrame(videoId, frameId)) {
      throw const RemoteVideoAnalysisSourceException(
        'frame_remove_blocked',
        '当前视频正在处理，暂不能移除候选帧',
      );
    }
    return _detailJson(_requireVideo(videoId));
  }

  Map<String, Object?> undoFrameRemoval(String videoId) {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    if (!currentSource.undoFrameRemoval(videoId)) {
      throw const RemoteVideoAnalysisSourceException(
        'frame_history_empty',
        '当前视频没有可恢复的候选帧',
      );
    }
    return _detailJson(_requireVideo(videoId));
  }

  Map<String, Object?> redoFrameRemoval(String videoId) {
    final currentSource = _requireSource();
    _requireVideo(videoId);
    if (!currentSource.redoFrameRemoval(videoId)) {
      throw const RemoteVideoAnalysisSourceException(
        'frame_history_empty',
        '当前视频没有可再次移除的候选帧',
      );
    }
    return _detailJson(_requireVideo(videoId));
  }

  RemoteVideoAnalysisSource _requireSource() {
    final current = source;
    if (current == null) {
      throw const RemoteVideoAnalysisSourceException(
        'video_analysis_unavailable',
        '当前工程的视频解析控制器尚未就绪',
      );
    }
    return current;
  }

  RemoteVideoDetailRecord _requireVideo(String videoId) {
    final detail = _requireSource().videoById(videoId);
    if (detail == null) {
      throw const RemoteVideoAnalysisSourceException(
        'video_not_found',
        '视频不存在',
      );
    }
    return detail;
  }

  void _handleSourceChanged() {
    final current = source;
    final projectId = _projectId;
    if (current == null || projectId == null) return;
    _changeBus.publish(
      type: 'videos.changed',
      projectId: projectId,
      data: {'count': current.videos.length},
    );
  }

  Map<String, Object?> _videoJson(RemoteVideoRecord video) {
    final mediaId = _mediaRegistry.registerProjectFile(video.localPath);
    return {
      'id': video.id,
      'fileName': video.fileName,
      'durationMs': video.durationMs,
      'frameRate': video.frameRate,
      'width': video.width,
      'height': video.height,
      'displayWidth': video.displayWidth,
      'displayHeight': video.displayHeight,
      'rotationDegrees': video.rotationDegrees,
      'hasAudio': video.hasAudio,
      'frameCount': video.frameCount,
      'successfulFrames': video.successfulFrames,
      'failedFrames': video.failedFrames,
      'status': video.status,
      'errorMessage': video.errorMessage,
      if (mediaId != null) 'mediaUrl': '/api/v1/media/$mediaId/content',
      'createdAt': video.createdAt.toUtc().toIso8601String(),
      'updatedAt': video.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _detailJson(RemoteVideoDetailRecord detail) => {
    ..._videoJson(detail.video),
    'analysisState': {
      'isAnalyzing': detail.isAnalyzing,
      'isPaused': detail.isPaused,
      'progress': {
        'current': detail.completedProgress,
        'total': detail.totalProgress,
      },
      'message': detail.message,
      'errorMessage': detail.errorMessage,
      'canUndoFrameRemoval': detail.canUndoFrameRemoval,
      'canRedoFrameRemoval': detail.canRedoFrameRemoval,
    },
    'frames': [for (final frame in detail.frames) _frameJson(frame)],
    'shots': [for (final shot in detail.shots) _shotJson(shot)],
    'marketingAnalyses': [
      for (final analysis in detail.marketingAnalyses)
        {
          'id': analysis.id,
          'scope': analysis.scope,
          'dimensions': analysis.dimensions,
          'status': analysis.status,
          'errorMessage': analysis.errorMessage,
          'updatedAt': analysis.updatedAt.toUtc().toIso8601String(),
        },
    ],
    if (detail.summary != null)
      'summary': {
        'id': detail.summary!.id,
        'fields': detail.summary!.fields,
        'status': detail.summary!.status,
        'errorMessage': detail.summary!.errorMessage,
        'updatedAt': detail.summary!.updatedAt.toUtc().toIso8601String(),
      },
  };

  Map<String, Object?> _frameJson(RemoteVideoFrameRecord frame) {
    final mediaId = _mediaRegistry.registerProjectFile(frame.localPath);
    return {
      'id': frame.id,
      'index': frame.index,
      'timestampMs': frame.timestampMs,
      'width': frame.width,
      'height': frame.height,
      'sharpness': frame.sharpness,
      'brightness': frame.brightness,
      'motionScore': frame.motionScore,
      'isFocus': frame.isFocus,
      'isSelected': frame.isSelected,
      'status': frame.status,
      'errorMessage': frame.errorMessage,
      if (mediaId != null) 'mediaUrl': '/api/v1/media/$mediaId/content',
      'createdAt': frame.createdAt.toUtc().toIso8601String(),
      if (frame.analysis != null)
        'analysis': {
          'id': frame.analysis!.id,
          'sequenceNo': frame.analysis!.sequenceNo,
          'dimensions': frame.analysis!.dimensions,
          'status': frame.analysis!.status,
          'errorMessage': frame.analysis!.errorMessage,
          'updatedAt': frame.analysis!.updatedAt.toUtc().toIso8601String(),
        },
    };
  }

  static Map<String, Object?> _shotJson(RemoteVideoShotRecord shot) => {
    'id': shot.id,
    'shotNumber': shot.shotNumber,
    'startMs': shot.startMs,
    'endMs': shot.endMs,
    'primaryFrameId': shot.primaryFrameId,
    'frameIds': shot.frameIds,
    'description': shot.description,
    'storyFlow': shot.storyFlow,
    'status': shot.status,
  };

  void dispose() => detach();
}
