import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../domain/video_generation_models.dart';

class VideoTimelineXmlExportService {
  const VideoTimelineXmlExportService({this.frameRate = 30});

  final int frameRate;

  Future<File> export({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
    required Directory outputDirectory,
  }) async {
    final clips = timelineClips(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: fileForTask,
    );
    if (clips.isEmpty) {
      throw const VideoTimelineXmlExportException('暂无可导出的完成视频');
    }
    await outputDirectory.create(recursive: true);
    final output = File(
      p.join(outputDirectory.path, '时间线-${_safeName(script.name)}.xml'),
    );
    await output.writeAsString(_xmeml(script: script, clips: clips));
    return output;
  }

  List<VideoTimelineExportClip> timelineClips({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<VideoGenerationTask> tasks,
    required File Function(VideoGenerationTask task) fileForTask,
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
      final durationFrames = (task.durationSeconds * frameRate).clamp(
        1,
        86400 * frameRate,
      );
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
    if (candidates.isEmpty) return null;
    final latest = candidates.last;
    if (!_isExportableStatus(latest.status)) return null;
    if (!fileForTask(latest).existsSync()) return null;
    return latest;
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

  String _xmeml({
    required ShootingScript script,
    required List<VideoTimelineExportClip> clips,
  }) {
    final totalFrames = clips.fold<int>(
      0,
      (total, clip) => total + clip.durationFrames,
    );
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<xmeml version="5">
  <sequence id="sequence-1">
    <name>${_xml(script.name)}</name>
    <duration>$totalFrames</duration>
    ${_rateXml()}
    <media>
      <video>
        <format>
          <samplecharacteristics>
            ${_rateXml()}
            <width>1920</width>
            <height>1080</height>
            <anamorphic>FALSE</anamorphic>
            <pixelaspectratio>square</pixelaspectratio>
            <fielddominance>none</fielddominance>
          </samplecharacteristics>
        </format>
        <track>
${clips.asMap().entries.map((entry) => _clipXml(entry.key, entry.value)).join('\n')}
        </track>
      </video>
    </media>
  </sequence>
</xmeml>
'''
        .trimLeft();
  }

  String _clipXml(int index, VideoTimelineExportClip clip) {
    final id = index + 1;
    final name = p.basename(clip.file.path);
    return '''
          <clipitem id="clipitem-$id">
            <name>${_xml(name)}</name>
            <duration>${clip.durationFrames}</duration>
            ${_rateXml()}
            <start>${clip.startFrame}</start>
            <end>${clip.endFrame}</end>
            <in>0</in>
            <out>${clip.durationFrames}</out>
            <file id="file-$id">
              <name>${_xml(name)}</name>
              <pathurl>${_xml(_premierePathUrl(clip.file))}</pathurl>
              ${_rateXml()}
              <duration>${clip.durationFrames}</duration>
              <media>
                <video>
                  <samplecharacteristics>
                    ${_rateXml()}
                    <width>1920</width>
                    <height>1080</height>
                    <anamorphic>FALSE</anamorphic>
                    <pixelaspectratio>square</pixelaspectratio>
                    <fielddominance>none</fielddominance>
                  </samplecharacteristics>
                </video>
              </media>
            </file>
          </clipitem>''';
  }

  String _rateXml() =>
      '<rate><timebase>$frameRate</timebase><ntsc>FALSE</ntsc></rate>';

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
  });

  final ScriptShot shot;
  final VideoGenerationTask task;
  final File file;
  final int timelineShotNumber;
  final int startFrame;
  final int endFrame;
  final int durationFrames;
}

class VideoTimelineXmlExportException implements Exception {
  const VideoTimelineXmlExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
