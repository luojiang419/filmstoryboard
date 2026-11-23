import 'dart:convert';

import 'package:crypto/crypto.dart';

class VideoTimelineFrameRate {
  const VideoTimelineFrameRate.standard(int framesPerSecond)
    : framesPerSecond = framesPerSecond * 1.0,
      timebase = framesPerSecond,
      isNtsc = false;

  const VideoTimelineFrameRate._({
    required this.framesPerSecond,
    required this.timebase,
    required this.isNtsc,
  });

  factory VideoTimelineFrameRate.fromFramesPerSecond(double value) {
    if (!value.isFinite || value <= 0) {
      return const VideoTimelineFrameRate.standard(30);
    }
    for (final timebase in const [24, 30, 48, 60, 120]) {
      final ntscValue = timebase * 1000 / 1001;
      if ((value - ntscValue).abs() < 0.02) {
        return VideoTimelineFrameRate._(
          framesPerSecond: ntscValue,
          timebase: timebase,
          isNtsc: true,
        );
      }
    }
    final timebase = value.round().clamp(1, 120).toInt();
    return VideoTimelineFrameRate._(
      framesPerSecond: timebase * 1.0,
      timebase: timebase,
      isNtsc: false,
    );
  }

  final double framesPerSecond;
  final int timebase;
  final bool isNtsc;

  Map<String, Object> toJson() => {
    'framesPerSecond': framesPerSecond,
    'timebase': timebase,
    'ntsc': isNtsc,
  };
}

class VideoTimelineSnapshotClip {
  const VideoTimelineSnapshotClip({
    required this.shotId,
    required this.shotNumber,
    required this.timelineShotNumber,
    required this.taskId,
    required this.filePath,
    required this.fileSize,
    required this.fileModifiedAtMs,
    required this.sourceDurationMs,
    required this.trimInMs,
    required this.trimOutMs,
    required this.sourceDurationFrames,
    required this.sourceInFrame,
    required this.sourceOutFrame,
    required this.recordStartFrame,
    required this.recordEndFrame,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceFrameRate,
    this.sourceFrameCount = 0,
    required this.hasAudio,
  });

  final String shotId;
  final int shotNumber;
  final int timelineShotNumber;
  final String taskId;
  final String filePath;
  final int fileSize;
  final int fileModifiedAtMs;
  final int sourceDurationMs;
  final int trimInMs;
  final int trimOutMs;
  final int sourceDurationFrames;
  final int sourceInFrame;
  final int sourceOutFrame;
  final int recordStartFrame;
  final int recordEndFrame;
  final int sourceWidth;
  final int sourceHeight;
  final double sourceFrameRate;
  final int sourceFrameCount;
  final bool hasAudio;

  Map<String, Object> toJson() => {
    'shotId': shotId,
    'shotNumber': shotNumber,
    'timelineShotNumber': timelineShotNumber,
    'taskId': taskId,
    'filePath': filePath,
    'fileSize': fileSize,
    'fileModifiedAtMs': fileModifiedAtMs,
    'sourceDurationMs': sourceDurationMs,
    'trimInMs': trimInMs,
    'trimOutMs': trimOutMs,
    'sourceDurationFrames': sourceDurationFrames,
    'sourceInFrame': sourceInFrame,
    'sourceOutFrame': sourceOutFrame,
    'recordStartFrame': recordStartFrame,
    'recordEndFrame': recordEndFrame,
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
    'sourceFrameRate': sourceFrameRate,
    'sourceFrameCount': sourceFrameCount,
    'hasAudio': hasAudio,
  };
}

class VideoTimelineSnapshot {
  VideoTimelineSnapshot({
    required this.scriptId,
    required this.scriptName,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.clips,
    required this.generatedAt,
  }) : revision = _revisionFor(
         scriptId: scriptId,
         scriptName: scriptName,
         width: width,
         height: height,
         frameRate: frameRate,
         clips: clips,
       );

  static const schemaVersion = 1;

  final String scriptId;
  final String scriptName;
  final int width;
  final int height;
  final VideoTimelineFrameRate frameRate;
  final List<VideoTimelineSnapshotClip> clips;
  final DateTime generatedAt;
  final String revision;

  int get totalFrames => clips.isEmpty ? 0 : clips.last.recordEndFrame;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'scriptId': scriptId,
    'scriptName': scriptName,
    'revision': revision,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'timeline': {
      'width': width,
      'height': height,
      'frameRate': frameRate.toJson(),
      'totalFrames': totalFrames,
    },
    'clips': clips.map((clip) => clip.toJson()).toList(growable: false),
  };

  static String _revisionFor({
    required String scriptId,
    required String scriptName,
    required int width,
    required int height,
    required VideoTimelineFrameRate frameRate,
    required List<VideoTimelineSnapshotClip> clips,
  }) {
    final payload = <String, Object>{
      'schemaVersion': schemaVersion,
      'scriptId': scriptId,
      'scriptName': scriptName,
      'timeline': {
        'width': width,
        'height': height,
        'frameRate': frameRate.toJson(),
      },
      'clips': clips.map((clip) => clip.toJson()).toList(growable: false),
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }
}
