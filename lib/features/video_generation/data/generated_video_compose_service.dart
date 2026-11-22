import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shooting_script/domain/shooting_script_models.dart';
import '../../video_analysis/data/ffmpeg_frame_extractor.dart';
import '../../video_analysis/data/ffmpeg_tool_resolver.dart';
import 'video_timeline_xml_export_service.dart';

typedef GeneratedVideoProbe = Future<VideoMetadata> Function(File video);

class GeneratedVideoComposeService {
  const GeneratedVideoComposeService({
    this.frameRate = 30,
    this.ffmpegExecutable = 'ffmpeg',
    FfmpegProcessRunner? runner,
    FfmpegToolResolver? toolResolver,
    GeneratedVideoProbe? probe,
  }) : _runner = runner ?? const FfmpegProcessRunner(),
       _toolResolver = toolResolver,
       _probe = probe;

  final int frameRate;
  final String ffmpegExecutable;
  final FfmpegProcessRunner _runner;
  final FfmpegToolResolver? _toolResolver;
  final GeneratedVideoProbe? _probe;

  Future<File> export({
    required ShootingScript script,
    required List<VideoTimelineExportClip> clips,
    required Directory outputDirectory,
    required int width,
    required int height,
  }) async {
    if (clips.isEmpty) {
      throw const GeneratedVideoComposeException('暂无可导出的完成视频');
    }
    if (width <= 0 || height <= 0) {
      throw const GeneratedVideoComposeException('导出视频画幅无效');
    }

    await outputDirectory.create(recursive: true);
    final output = _uniqueOutputFile(outputDirectory, script.name);
    final temporary = File(
      p.join(
        outputDirectory.path,
        '${p.basenameWithoutExtension(output.path)}.partial.mp4',
      ),
    );
    if (temporary.existsSync()) {
      await temporary.delete();
    }

    try {
      final metadata = <VideoMetadata>[];
      for (final clip in clips) {
        metadata.add(await _probeVideo(clip.file));
      }
      final executable = await _resolveFfmpegExecutable();
      final result = await _runner(
        executable,
        buildArguments(
          clips: clips,
          metadata: metadata,
          outputFile: temporary,
          width: width,
          height: height,
        ),
      );
      if (result.exitCode != 0) {
        throw GeneratedVideoComposeException(
          'FFmpeg 拼接视频失败：${_conciseError(result.stderr)}',
        );
      }
      if (!temporary.existsSync() || temporary.lengthSync() == 0) {
        throw const GeneratedVideoComposeException('FFmpeg 未生成有效的视频文件');
      }
      return temporary.rename(output.path);
    } on GeneratedVideoComposeException {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    } on Object catch (error) {
      if (temporary.existsSync()) await temporary.delete();
      throw GeneratedVideoComposeException('导出视频失败：$error');
    }
  }

  List<String> buildArguments({
    required List<VideoTimelineExportClip> clips,
    required List<VideoMetadata> metadata,
    required File outputFile,
    required int width,
    required int height,
  }) {
    if (clips.isEmpty || metadata.length != clips.length) {
      throw const GeneratedVideoComposeException('视频片段与媒体信息不匹配');
    }

    final filters = <String>[];
    for (var index = 0; index < clips.length; index++) {
      final clip = clips[index];
      final inSeconds = clip.sourceInFrame / frameRate;
      final outSeconds = clip.sourceOutFrame / frameRate;
      final durationSeconds = clip.durationFrames / frameRate;
      final input = '$index';
      filters.add(
        '[$input:v:0]trim=start=${_seconds(inSeconds)}:'
        'end=${_seconds(outSeconds)},setpts=PTS-STARTPTS,'
        'scale=$width:$height:force_original_aspect_ratio=decrease,'
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black,'
        'setsar=1,fps=$frameRate,format=yuv420p[v$index]',
      );
      if (metadata[index].hasAudio) {
        filters.add(
          '[$input:a:0]atrim=start=${_seconds(inSeconds)}:'
          'end=${_seconds(outSeconds)},asetpts=PTS-STARTPTS,'
          'aresample=48000,aformat=sample_fmts=fltp:'
          'channel_layouts=stereo,apad=whole_dur=${_seconds(durationSeconds)},'
          'atrim=duration=${_seconds(durationSeconds)}[a$index]',
        );
      } else {
        filters.add(
          'anullsrc=channel_layout=stereo:sample_rate=48000,'
          'atrim=duration=${_seconds(durationSeconds)},'
          'asetpts=PTS-STARTPTS[a$index]',
        );
      }
    }
    final concatInputs = [
      for (var index = 0; index < clips.length; index++) '[v$index][a$index]',
    ].join();
    filters.add('${concatInputs}concat=n=${clips.length}:v=1:a=1[vout][aout]');

    return [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      for (final clip in clips) ...['-i', clip.file.path],
      '-filter_complex',
      filters.join(';'),
      '-map',
      '[vout]',
      '-map',
      '[aout]',
      '-c:v',
      'libx264',
      '-preset',
      'medium',
      '-crf',
      '18',
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      '-ar',
      '48000',
      '-movflags',
      '+faststart',
      outputFile.path,
    ];
  }

  Future<VideoMetadata> _probeVideo(File video) {
    final probe = _probe;
    if (probe != null) return probe(video);
    return FfmpegFrameExtractor(toolResolver: _toolResolver).probe(video);
  }

  Future<String> _resolveFfmpegExecutable() {
    if (!_runner.usesDefaultProcess) {
      return Future.value(ffmpegExecutable);
    }
    return (_toolResolver ?? const FfmpegToolResolver()).resolveFfmpeg(
      ffmpegExecutable,
    );
  }

  File _uniqueOutputFile(Directory directory, String scriptName) {
    final safeName = _safeName(scriptName);
    var suffix = 1;
    while (true) {
      final marker = suffix == 1 ? '' : '-$suffix';
      final candidate = File(p.join(directory.path, '成片-$safeName$marker.mp4'));
      if (!candidate.existsSync()) return candidate;
      suffix++;
    }
  }

  String _safeName(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return normalized.isEmpty ? '拍摄脚本' : normalized;
  }

  String _seconds(double value) => value.toStringAsFixed(3);

  String _conciseError(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return '未知错误';
    return normalized.length <= 600
        ? normalized
        : '${normalized.substring(0, 600)}…';
  }
}

class GeneratedVideoComposeException implements Exception {
  const GeneratedVideoComposeException(this.message);

  final String message;

  @override
  String toString() => message;
}
