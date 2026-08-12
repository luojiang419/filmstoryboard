import 'dart:io';

import 'package:flutter/foundation.dart';

class RemoteVideoRecord {
  const RemoteVideoRecord({
    required this.id,
    required this.fileName,
    required this.durationMs,
    required this.frameRate,
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.rotationDegrees,
    required this.hasAudio,
    required this.frameCount,
    required this.successfulFrames,
    required this.failedFrames,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.localPath,
  });

  final String id;
  final String fileName;
  final int durationMs;
  final double frameRate;
  final int width;
  final int height;
  final int displayWidth;
  final int displayHeight;
  final int rotationDegrees;
  final bool hasAudio;
  final int frameCount;
  final int successfulFrames;
  final int failedFrames;
  final String status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 仅用于注册当前工程媒体白名单，禁止直接序列化到远程响应。
  final String localPath;
}

class RemoteVideoFrameRecord {
  const RemoteVideoFrameRecord({
    required this.id,
    required this.index,
    required this.timestampMs,
    required this.width,
    required this.height,
    required this.sharpness,
    required this.brightness,
    required this.motionScore,
    required this.isFocus,
    required this.isSelected,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.localPath,
    required this.analysis,
  });

  final String id;
  final int index;
  final int timestampMs;
  final int width;
  final int height;
  final double sharpness;
  final double brightness;
  final double motionScore;
  final bool isFocus;
  final bool isSelected;
  final String status;
  final String errorMessage;
  final DateTime createdAt;
  final String localPath;
  final RemoteVideoFrameAnalysisRecord? analysis;
}

class RemoteVideoFrameAnalysisRecord {
  const RemoteVideoFrameAnalysisRecord({
    required this.id,
    required this.sequenceNo,
    required this.dimensions,
    required this.status,
    required this.errorMessage,
    required this.updatedAt,
  });

  final String id;
  final int sequenceNo;
  final Map<String, String> dimensions;
  final String status;
  final String errorMessage;
  final DateTime updatedAt;
}

class RemoteVideoShotRecord {
  const RemoteVideoShotRecord({
    required this.id,
    required this.shotNumber,
    required this.startMs,
    required this.endMs,
    required this.primaryFrameId,
    required this.frameIds,
    required this.description,
    required this.storyFlow,
    required this.status,
  });

  final String id;
  final int shotNumber;
  final int startMs;
  final int endMs;
  final String? primaryFrameId;
  final List<String> frameIds;
  final String description;
  final String storyFlow;
  final String status;
}

class RemoteVideoAnalysisRecord {
  const RemoteVideoAnalysisRecord({
    required this.id,
    required this.scope,
    required this.dimensions,
    required this.status,
    required this.errorMessage,
    required this.updatedAt,
  });

  final String id;
  final String scope;
  final Map<String, String> dimensions;
  final String status;
  final String errorMessage;
  final DateTime updatedAt;
}

class RemoteVideoSummaryRecord {
  const RemoteVideoSummaryRecord({
    required this.id,
    required this.fields,
    required this.status,
    required this.errorMessage,
    required this.updatedAt,
  });

  final String id;
  final Map<String, String> fields;
  final String status;
  final String errorMessage;
  final DateTime updatedAt;
}

class RemoteVideoDetailRecord {
  const RemoteVideoDetailRecord({
    required this.video,
    required this.frames,
    required this.shots,
    required this.marketingAnalyses,
    required this.summary,
    required this.isAnalyzing,
    required this.isPaused,
    required this.completedProgress,
    required this.totalProgress,
    required this.message,
    required this.errorMessage,
    this.canUndoFrameRemoval = false,
    this.canRedoFrameRemoval = false,
  });

  final RemoteVideoRecord video;
  final List<RemoteVideoFrameRecord> frames;
  final List<RemoteVideoShotRecord> shots;
  final List<RemoteVideoAnalysisRecord> marketingAnalyses;
  final RemoteVideoSummaryRecord? summary;
  final bool isAnalyzing;
  final bool isPaused;
  final int completedProgress;
  final int totalProgress;
  final String message;
  final String errorMessage;
  final bool canUndoFrameRemoval;
  final bool canRedoFrameRemoval;
}

class RemoteVideoImportResult {
  const RemoteVideoImportResult({required this.videoId});

  final String videoId;
}

class RemoteVideoOperationProgress {
  const RemoteVideoOperationProgress({
    required this.current,
    required this.total,
    required this.message,
  });

  final int current;
  final int total;
  final String message;
}

class RemoteVideoAnalysisSourceException implements Exception {
  const RemoteVideoAnalysisSourceException(this.code, this.message);

  final String code;
  final String message;
}

abstract interface class RemoteVideoAnalysisSource implements Listenable {
  List<RemoteVideoRecord> get videos;

  RemoteVideoOperationProgress get operationProgress;

  RemoteVideoDetailRecord? videoById(String videoId);

  Future<RemoteVideoImportResult> importVideo(
    File file, {
    required String fileName,
  });

  Future<void> startAnalysis(String videoId, {bool retryFailedOnly = false});

  bool pauseAnalysis(String videoId);

  bool cancelAnalysis(String videoId);

  Future<bool> generateStoryboard(String videoId);

  bool removeFrame(String videoId, String frameId);

  bool undoFrameRemoval(String videoId);

  bool redoFrameRemoval(String videoId);
}
