import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../video_analysis/data/ffmpeg_frame_extractor.dart';
import '../domain/generated_video_trim_range.dart';
import '../domain/video_generation_models.dart';
import '../domain/video_timeline_snapshot.dart';

typedef VideoTimelineMetadataProbe = Future<VideoMetadata> Function(File file);

class VideoTimelineXmlExportService {
  const VideoTimelineXmlExportService({
    this.frameRate = const VideoTimelineFrameRate.standard(30),
    this.width = 1920,
    this.height = 1080,
  });

  final VideoTimelineFrameRate frameRate;
  final int width;
  final int height;

  Future<File> export({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
    required Directory outputDirectory,
    VideoTimelineMetadataProbe? metadataProbe,
    DateTime? exportedAt,
  }) async {
    final snapshot = await buildSnapshot(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: fileForTask,
      metadataProbe: metadataProbe,
      generatedAt: exportedAt,
    );
    await outputDirectory.create(recursive: true);
    final output = _uniqueOutputFile(
      directory: outputDirectory,
      scriptName: script.name,
      exportedAt: exportedAt ?? DateTime.now(),
    );
    await output.writeAsString(_xmeml(snapshot));
    return output;
  }

  Future<VideoTimelineSnapshot> buildSnapshot({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
    VideoTimelineMetadataProbe? metadataProbe,
    DateTime? generatedAt,
  }) async {
    final initialClips = timelineClips(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: fileForTask,
    );
    if (initialClips.isEmpty) {
      throw const VideoTimelineXmlExportException('暂无可导出的完成视频');
    }
    final probe = metadataProbe ?? const FfmpegFrameExtractor().probe;
    final metadataByTaskId = <String, VideoMetadata>{};
    for (final clip in initialClips) {
      try {
        metadataByTaskId[clip.task.id] = await probe(clip.file);
      } catch (error) {
        throw VideoTimelineXmlExportException(
          '读取时间线素材规格失败：${p.basename(clip.file.path)}：$error',
        );
      }
    }
    final metadata = metadataByTaskId[initialClips.first.task.id]!;
    final resolved = VideoTimelineXmlExportService(
      frameRate: VideoTimelineFrameRate.fromFramesPerSecond(metadata.frameRate),
      width: metadata.displayWidth > 0 ? metadata.displayWidth : width,
      height: metadata.displayHeight > 0 ? metadata.displayHeight : height,
    );
    final clips = resolved.timelineClips(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: fileForTask,
      metadataByTaskId: metadataByTaskId,
    );
    final snapshotClips = <VideoTimelineSnapshotClip>[];
    for (final clip in clips) {
      final sourceMetadata = metadataByTaskId[clip.task.id]!;
      final range = resolved._resolvedTrimRange(
        clip.task.trimRange,
        sourceMetadata,
      );
      final sourceFrameRate =
          sourceMetadata.frameRate.isFinite && sourceMetadata.frameRate > 0
          ? sourceMetadata.frameRate
          : resolved.frameRate.framesPerSecond;
      final sourceFrameCount = sourceMetadata.frameCount > 0
          ? sourceMetadata.frameCount
          : _framesAtRate(range.sourceDuration.inMilliseconds, sourceFrameRate);
      final stat = clip.file.statSync();
      snapshotClips.add(
        VideoTimelineSnapshotClip(
          shotId: clip.shot.id,
          shotNumber: clip.shot.shotNumber,
          timelineShotNumber: clip.timelineShotNumber,
          taskId: clip.task.id,
          filePath: clip.file.absolute.path,
          fileSize: stat.size,
          fileModifiedAtMs: stat.modified.millisecondsSinceEpoch,
          sourceDurationMs: range.sourceDuration.inMilliseconds,
          trimInMs: range.inPoint.inMilliseconds,
          trimOutMs: range.outPoint.inMilliseconds,
          sourceDurationFrames: clip.sourceDurationFrames,
          sourceInFrame: clip.sourceInFrame,
          sourceOutFrame: clip.sourceOutFrame,
          recordStartFrame: clip.startFrame,
          recordEndFrame: clip.endFrame,
          sourceWidth: sourceMetadata.displayWidth > 0
              ? sourceMetadata.displayWidth
              : resolved.width,
          sourceHeight: sourceMetadata.displayHeight > 0
              ? sourceMetadata.displayHeight
              : resolved.height,
          sourceFrameRate: sourceFrameRate,
          sourceFrameCount: sourceFrameCount,
          hasAudio: sourceMetadata.hasAudio,
        ),
      );
    }
    return VideoTimelineSnapshot(
      scriptId: script.id,
      scriptName: script.name,
      width: resolved.width,
      height: resolved.height,
      frameRate: resolved.frameRate,
      clips: List.unmodifiable(snapshotClips),
      generatedAt: generatedAt ?? DateTime.now(),
    );
  }

  List<VideoTimelineExportClip> timelineClips({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
    Map<String, VideoMetadata> metadataByTaskId = const {},
  }) {
    final groups = ScriptShotGroup.group(shots);
    var cursor = 0;
    final clips = <VideoTimelineExportClip>[];
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final group = groups[groupIndex];
      final shot = group.shots.first;
      final task = _latestTaskVersion(
        scriptId: script.id,
        shotId: shot.id,
        tasks: tasks,
        fileForTask: fileForTask,
      );
      if (task == null) continue;
      final trimRange = _resolvedTrimRange(
        task.trimRange,
        metadataByTaskId[task.id],
      );
      final sourceDurationFrames = _framesFromMilliseconds(
        trimRange.sourceDuration.inMilliseconds,
      );
      final sourceInFrame = _framesFromMilliseconds(
        trimRange.inPoint.inMilliseconds,
        allowZero: true,
      ).clamp(0, sourceDurationFrames - 1);
      final sourceOutFrame = _framesFromMilliseconds(
        trimRange.outPoint.inMilliseconds,
      ).clamp(sourceInFrame + 1, sourceDurationFrames);
      final durationFrames = sourceOutFrame - sourceInFrame;
      final file = fileForTask(task);
      clips.add(
        VideoTimelineExportClip(
          shot: shot,
          task: task,
          file: file,
          timelineShotNumber: groupIndex + 1,
          startFrame: cursor,
          endFrame: cursor + durationFrames,
          durationFrames: durationFrames,
          sourceDurationFrames: sourceDurationFrames,
          sourceInFrame: sourceInFrame,
          sourceOutFrame: sourceOutFrame,
        ),
      );
      cursor += durationFrames;
    }
    return clips;
  }

  VideoGenerationTask? _latestTaskVersion({
    required String scriptId,
    required String shotId,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
  }) {
    final candidates =
        tasks
            .where((task) => task.scriptId == scriptId && task.shotId == shotId)
            .toList()
          ..sort(_compareTaskVersion);
    for (final candidate in candidates.reversed) {
      if (!_isExportableStatus(candidate.status)) continue;
      if (!fileForTask(candidate).existsSync()) continue;
      return candidate;
    }
    return null;
  }

  int _framesFromMilliseconds(int milliseconds, {bool allowZero = false}) {
    final frames = (milliseconds * frameRate.framesPerSecond / 1000).round();
    return frames.clamp(
      allowZero ? 0 : 1,
      (86400 * frameRate.framesPerSecond).round(),
    );
  }

  GeneratedVideoTrimRange _resolvedTrimRange(
    GeneratedVideoTrimRange requested,
    VideoMetadata? metadata,
  ) {
    final probedDurationMs = metadata?.durationMs ?? 0;
    if (probedDurationMs <= 0) return requested;
    return GeneratedVideoTrimRange.fromMilliseconds(
      sourceDurationMs: probedDurationMs,
      trimInMs: requested.inPoint.inMilliseconds,
      trimOutMs: requested.outPoint.inMilliseconds,
      fallbackDurationMs: probedDurationMs,
    );
  }

  static int _framesAtRate(int milliseconds, double framesPerSecond) {
    if (!framesPerSecond.isFinite || framesPerSecond <= 0) return 1;
    return (milliseconds * framesPerSecond / 1000).round().clamp(1, 2147483647);
  }

  int _compareTaskVersion(
    VideoGenerationTask first,
    VideoGenerationTask second,
  ) {
    final firstTime = first.createdAt;
    final secondTime = second.createdAt;
    final byTime = firstTime.compareTo(secondTime);
    return byTime != 0 ? byTime : first.id.compareTo(second.id);
  }

  bool _isExportableStatus(VideoGenerationTaskStatus status) =>
      status == VideoGenerationTaskStatus.completed ||
      status == VideoGenerationTaskStatus.partialCompleted;

  String _xmeml(VideoTimelineSnapshot snapshot) {
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<xmeml version="5">
  <sequence id="sequence-1">
    <name>${_xml(snapshot.scriptName)}</name>
    <duration>${snapshot.totalFrames}</duration>
    ${_rateXml(snapshot.frameRate)}
    <media>
      <video>
        <format>
          <samplecharacteristics>
            ${_rateXml(snapshot.frameRate)}
            <width>${snapshot.width}</width>
            <height>${snapshot.height}</height>
            <anamorphic>FALSE</anamorphic>
            <pixelaspectratio>square</pixelaspectratio>
            <fielddominance>none</fielddominance>
          </samplecharacteristics>
        </format>
        <track>
${snapshot.clips.asMap().entries.map((entry) => _clipXml(entry.key, entry.value, snapshot.frameRate)).join('\n')}
        </track>
      </video>
    </media>
  </sequence>
</xmeml>
'''
        .trimLeft();
  }

  String _clipXml(
    int index,
    VideoTimelineSnapshotClip clip,
    VideoTimelineFrameRate timelineFrameRate,
  ) {
    final id = index + 1;
    final file = File(clip.filePath);
    final name = p.basename(file.path);
    return '''
          <clipitem id="clipitem-$id">
            <name>${_xml(name)}</name>
            <duration>${clip.sourceDurationFrames}</duration>
            ${_rateXml(timelineFrameRate)}
            <start>${clip.recordStartFrame}</start>
            <end>${clip.recordEndFrame}</end>
            <in>${clip.sourceInFrame}</in>
            <out>${clip.sourceOutFrame}</out>
            <file id="file-$id">
              <name>${_xml(name)}</name>
              <pathurl>${_xml(_premierePathUrl(file))}</pathurl>
              ${_rateXml(timelineFrameRate)}
              <duration>${clip.sourceDurationFrames}</duration>
              <media>
                <video>
                  <samplecharacteristics>
                    ${_rateXml(timelineFrameRate)}
                    <width>${clip.sourceWidth}</width>
                    <height>${clip.sourceHeight}</height>
                    <anamorphic>FALSE</anamorphic>
                    <pixelaspectratio>square</pixelaspectratio>
                    <fielddominance>none</fielddominance>
                  </samplecharacteristics>
                </video>
              </media>
            </file>
          </clipitem>''';
  }

  String _rateXml(VideoTimelineFrameRate value) =>
      '<rate><timebase>${value.timebase}</timebase>'
      '<ntsc>${value.isNtsc ? 'TRUE' : 'FALSE'}</ntsc></rate>';

  File _uniqueOutputFile({
    required Directory directory,
    required String scriptName,
    required DateTime exportedAt,
  }) {
    final safeName = _safeName(scriptName);
    final baseName = '时间线-$safeName';
    final original = File(p.join(directory.path, '$baseName.xml'));
    if (!original.existsSync()) return original;

    var highestVersion = 1;
    final versionPattern = RegExp(
      '^${RegExp.escape(baseName)}-V(\\d+)-\\d{8}-\\d{6}\\.xml\$',
      caseSensitive: false,
    );
    if (directory.existsSync()) {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final match = versionPattern.firstMatch(p.basename(entity.path));
        if (match == null) continue;
        final version = int.tryParse(match.group(1) ?? '');
        if (version != null && version > highestVersion) {
          highestVersion = version;
        }
      }
    }
    final version = highestVersion + 1;
    final timestamp = _timestamp(exportedAt);
    return File(
      p.join(
        directory.path,
        '$baseName-V${version.toString().padLeft(3, '0')}-$timestamp.xml',
      ),
    );
  }

  String _timestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}'
        '${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  String _premierePathUrl(File file) {
    final uri = Uri.file(file.absolute.path).toString();
    if (!Platform.isWindows) return uri;
    return uri.replaceFirstMapped(
      RegExp(r'^file:///([A-Za-z]):/'),
      (match) => 'file://localhost/${match.group(1)}%3A/',
    );
  }

  String _safeName(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return normalized.isEmpty ? '拍摄脚本' : normalized;
  }

  String _xml(String value) => value
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class VideoTimelineExportClip {
  const VideoTimelineExportClip({
    required this.shot,
    required this.task,
    required this.file,
    required this.timelineShotNumber,
    required this.startFrame,
    required this.endFrame,
    required this.durationFrames,
    required this.sourceDurationFrames,
    required this.sourceInFrame,
    required this.sourceOutFrame,
  });

  final ScriptShot shot;
  final VideoGenerationTask task;
  final File file;
  final int timelineShotNumber;
  final int startFrame;
  final int endFrame;
  final int durationFrames;
  final int sourceDurationFrames;
  final int sourceInFrame;
  final int sourceOutFrame;
}

class VideoTimelineXmlExportException implements Exception {
  const VideoTimelineXmlExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
