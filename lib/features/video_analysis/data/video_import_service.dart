import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/services/workspace_directories.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/video_analysis_models.dart';
import 'ffmpeg_frame_extractor.dart';

class VideoImportResult {
  const VideoImportResult({required this.video, required this.frameFiles});

  final SourceVideo video;
  final List<ExtractedFrame> frameFiles;
}

class VideoImportService {
  VideoImportService({
    required this.directories,
    FfmpegFrameExtractor? extractor,
    Uuid uuid = const Uuid(),
  }) : _extractor = extractor ?? const FfmpegFrameExtractor(),
       _uuid = uuid;

  final WorkspaceDirectories directories;
  final FfmpegFrameExtractor _extractor;
  final Uuid _uuid;

  Future<VideoImportResult> importVideo(
    File source, {
    Duration frameInterval = const Duration(seconds: 1),
    VideoFrameExtractionStrategy strategy =
        VideoFrameExtractionStrategy.sceneAndInterval,
    double sceneThreshold = 0.3,
  }) async {
    if (!source.existsSync()) {
      throw StateError('视频文件不存在：${source.path}');
    }
    final id = _uuid.v4();
    final fileName = p.basename(source.path);
    final directoryName = '${_safeStem(fileName)}-${id.substring(0, 8)}';
    final videoDirectory = Directory(
      p.join(directories.videos.path, directoryName),
    );
    final framesDirectory = Directory(
      p.join(directories.frames.path, directoryName),
    );
    await videoDirectory.create(recursive: true);
    await framesDirectory.create(recursive: true);
    final target = File(p.join(videoDirectory.path, fileName));
    try {
      await source.copy(target.path);

      final now = DateTime.now().toUtc();
      final metadata = await _extractor.probe(target);
      final extractedFrames = await _extractor.extract(
        video: target,
        outputDirectory: framesDirectory,
        interval: frameInterval,
        strategy: strategy,
        sceneThreshold: sceneThreshold,
      );
      final frames = <ExtractedFrame>[];
      for (final frame in extractedFrames) {
        final renamed = await frame.file.rename(
          p.join(
            framesDirectory.path,
            '${(frame.index + 1).toString().padLeft(5, '0')}-'
            '${_timestampName(frame.timestampMs)}.jpg',
          ),
        );
        frames.add(
          ExtractedFrame(
            index: frame.index,
            timestampMs: frame.timestampMs,
            file: renamed,
          ),
        );
      }
      return VideoImportResult(
        video: SourceVideo(
          id: id,
          originalPath: source.absolute.path,
          fileName: fileName,
          storedPath: p
              .join('videos', directoryName, fileName)
              .replaceAll('\\', '/'),
          durationMs: metadata.durationMs,
          frameRate: metadata.frameRate,
          width: metadata.width,
          height: metadata.height,
          hasAudio: metadata.hasAudio,
          frameCount: frames.length,
          successfulFrames: frames.length,
          failedFrames: 0,
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: DateTime.now().toUtc(),
        ),
        frameFiles: frames,
      );
    } catch (_) {
      if (videoDirectory.existsSync()) {
        await videoDirectory.delete(recursive: true);
      }
      if (framesDirectory.existsSync()) {
        await framesDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  static String _safeStem(String fileName) {
    final stem = p.basenameWithoutExtension(fileName).trim();
    final safe = stem.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    return safe.isEmpty ? 'video' : safe;
  }

  static String _timestampName(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '${minutes}m${seconds}s${millis}ms';
  }
}
