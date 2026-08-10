import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shooting_script/domain/shooting_script_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';

class SourceVideoPreviewRange {
  const SourceVideoPreviewRange({
    required this.sourceVideo,
    required this.inPoint,
    required this.outPoint,
    this.thumbnailFile,
  });

  final File sourceVideo;
  final Duration inPoint;
  final Duration outPoint;
  final File? thumbnailFile;

  Duration get duration => outPoint - inPoint;

  static SourceVideoPreviewRange aroundFrame({
    required File sourceVideo,
    required int timestampMs,
    required int sourceDurationMs,
    double paddingSeconds = 1.5,
    File? thumbnailFile,
  }) {
    if (sourceDurationMs <= 0) {
      throw ArgumentError.value(sourceDurationMs, 'sourceDurationMs', '必须大于 0');
    }
    final paddingMs = (paddingSeconds.clamp(0.1, 30) * 1000).round();
    final normalizedTimestamp = timestampMs.clamp(0, sourceDurationMs);
    final startMs = (normalizedTimestamp - paddingMs).clamp(
      0,
      sourceDurationMs,
    );
    final endMs = (normalizedTimestamp + paddingMs).clamp(0, sourceDurationMs);
    return SourceVideoPreviewRange(
      sourceVideo: sourceVideo,
      inPoint: Duration(milliseconds: startMs),
      outPoint: Duration(milliseconds: endMs),
      thumbnailFile: thumbnailFile,
    );
  }
}

class SourceVideoPreviewResolver {
  const SourceVideoPreviewResolver();

  SourceVideoPreviewRange? resolve({
    required SourceVideo video,
    required List<VideoFrame> frames,
    required ScriptShot shot,
    ScriptShot? endShot,
    required Directory workspaceRoot,
    double paddingSeconds = 1.5,
  }) {
    final sourceVideo = _firstExistingFile([
      video.storedPath,
      video.originalPath,
    ], workspaceRoot);
    if (sourceVideo == null || video.durationMs <= 0) return null;

    final frame = _matchingFrame(frames, shot, workspaceRoot);
    final rangeEndShot = endShot;
    if (frame != null && rangeEndShot != null) {
      final endFrame = _matchingFrame(frames, rangeEndShot, workspaceRoot);
      final startMs = frame.timestampMs.clamp(0, video.durationMs);
      final endMs = endFrame?.timestampMs.clamp(0, video.durationMs);
      if (endMs != null && endMs > startMs) {
        return SourceVideoPreviewRange(
          sourceVideo: sourceVideo,
          inPoint: Duration(milliseconds: startMs),
          outPoint: Duration(milliseconds: endMs),
          thumbnailFile: _firstExistingFile([frame.path], workspaceRoot),
        );
      }
    }
    return SourceVideoPreviewRange.aroundFrame(
      sourceVideo: sourceVideo,
      timestampMs: frame?.timestampMs ?? 0,
      sourceDurationMs: video.durationMs,
      paddingSeconds: paddingSeconds,
      thumbnailFile: frame == null
          ? null
          : _firstExistingFile([frame.path], workspaceRoot),
    );
  }

  static VideoFrame? _matchingFrame(
    List<VideoFrame> frames,
    ScriptShot shot,
    Directory workspaceRoot,
  ) {
    final frameId = shot.sourceVideoFrameId?.trim() ?? '';
    if (frameId.isNotEmpty) {
      for (final frame in frames) {
        if (frame.id == frameId) return frame;
      }
    }

    final shotFramePath = _absolutePath(shot.framePath, workspaceRoot);
    if (shotFramePath.isNotEmpty) {
      for (final frame in frames) {
        if (_samePath(
          _absolutePath(frame.path, workspaceRoot),
          shotFramePath,
        )) {
          return frame;
        }
      }
    }

    final ordered = [...frames]
      ..sort((first, second) => first.index.compareTo(second.index));
    final focusFrames = ordered.where((frame) => frame.isFocus).toList();
    final candidates = focusFrames.isEmpty ? ordered : focusFrames;
    final index = shot.shotNumber - 1;
    return index >= 0 && index < candidates.length ? candidates[index] : null;
  }

  static File? _firstExistingFile(List<String> paths, Directory workspaceRoot) {
    for (final path in paths) {
      final absolute = _absolutePath(path, workspaceRoot);
      if (absolute.isEmpty) continue;
      final file = File(absolute);
      if (file.existsSync()) return file;
    }
    return null;
  }

  static String _absolutePath(String value, Directory workspaceRoot) {
    final normalized = value.trim().replaceAll('/', Platform.pathSeparator);
    if (normalized.isEmpty) return '';
    return p.normalize(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(workspaceRoot.path, normalized),
    );
  }

  static bool _samePath(String first, String second) {
    if (Platform.isWindows) return first.toLowerCase() == second.toLowerCase();
    return first == second;
  }
}
