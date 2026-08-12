import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import 'ffmpeg_tool_resolver.dart';

class FfmpegProcessResult {
  const FfmpegProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef FfmpegRun =
    Future<FfmpegProcessResult> Function(
      String executable,
      List<String> arguments,
    );

class FfmpegProcessRunner {
  const FfmpegProcessRunner({FfmpegRun? run})
    : _run = run ?? _runProcess,
      usesDefaultProcess = run == null;

  final FfmpegRun _run;
  final bool usesDefaultProcess;

  Future<FfmpegProcessResult> call(String executable, List<String> arguments) =>
      _run(executable, arguments);

  static Future<FfmpegProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    return FfmpegProcessResult(
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }
}

class VideoMetadata {
  const VideoMetadata({
    required this.durationMs,
    required this.frameRate,
    required this.width,
    required this.height,
    required this.hasAudio,
    this.frameCount = 0,
    this.rotationDegrees = 0,
  });

  final int durationMs;
  final double frameRate;
  final int width;
  final int height;
  final bool hasAudio;
  final int frameCount;
  final int rotationDegrees;

  bool get hasQuarterTurn => rotationDegrees == 90 || rotationDegrees == 270;

  int get displayWidth => hasQuarterTurn ? height : width;

  int get displayHeight => hasQuarterTurn ? width : height;

  double get displayAspectRatio => displayWidth > 0 && displayHeight > 0
      ? displayWidth / displayHeight
      : 16 / 9;

  bool get isPortrait => displayHeight > displayWidth;
}

class ExtractedFrame {
  const ExtractedFrame({
    required this.index,
    required this.timestampMs,
    required this.file,
  });

  final int index;
  final int timestampMs;
  final File file;
}

class FfmpegFrameExtractor {
  const FfmpegFrameExtractor({
    this.ffmpegExecutable = 'ffmpeg',
    this.ffprobeExecutable = 'ffprobe',
    FfmpegProcessRunner? runner,
    FfmpegToolResolver? toolResolver,
  }) : _runner = runner ?? const FfmpegProcessRunner(),
       _toolResolver = toolResolver;

  final String ffmpegExecutable;
  final String ffprobeExecutable;
  final FfmpegProcessRunner _runner;
  final FfmpegToolResolver? _toolResolver;

  List<String> buildProbeArguments(String videoPath) => [
    '-v',
    'error',
    '-print_format',
    'json',
    '-show_entries',
    'stream=codec_type,width,height,r_frame_rate,avg_frame_rate,duration,nb_frames:'
        'stream_tags=rotate:stream_side_data=rotation:format=duration',
    videoPath,
  ];

  List<String> buildExtractArguments({
    required String videoPath,
    required String outputPattern,
    Duration interval = const Duration(seconds: 1),
    VideoFrameExtractionStrategy strategy =
        VideoFrameExtractionStrategy.intervalOnly,
    double sceneThreshold = 0.3,
  }) {
    final seconds = interval.inMilliseconds / 1000;
    final filter = switch (strategy) {
      VideoFrameExtractionStrategy.perFrame => 'showinfo',
      VideoFrameExtractionStrategy.sceneAndInterval =>
        'select=eq(n\\,0)+gt(scene\\,${sceneThreshold.toStringAsFixed(2)})+'
            'gte(t-prev_selected_t\\,${seconds.toStringAsFixed(3)}),showinfo',
      VideoFrameExtractionStrategy.intervalOnly ||
      VideoFrameExtractionStrategy.highFidelity => 'fps=1/$seconds',
    };
    return [
      '-hide_banner',
      '-loglevel',
      strategy == VideoFrameExtractionStrategy.sceneAndInterval ||
              strategy == VideoFrameExtractionStrategy.perFrame
          ? 'info'
          : 'error',
      '-i',
      videoPath,
      '-vf',
      filter,
      if (strategy == VideoFrameExtractionStrategy.sceneAndInterval ||
          strategy == VideoFrameExtractionStrategy.perFrame) ...[
        '-fps_mode',
        'vfr',
      ],
      '-q:v',
      '2',
      '-start_number',
      '0',
      outputPattern,
    ];
  }

  Future<VideoMetadata> probe(File video) async {
    final executable = await _resolveFfprobeExecutable();
    final result = await _runner(executable, buildProbeArguments(video.path));
    if (result.exitCode != 0) {
      throw StateError('FFprobe 读取视频信息失败：${result.stderr.trim()}');
    }
    try {
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      final streams = (json['streams'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final videoStream = streams.firstWhere(
        (stream) => stream['codec_type'] == 'video',
        orElse: () => <String, dynamic>{},
      );
      final format = json['format'] as Map<String, dynamic>? ?? const {};
      return VideoMetadata(
        durationMs: _durationMilliseconds(
          videoStream['duration'] ?? format['duration'],
        ),
        frameRate: _frameRate(
          videoStream['r_frame_rate'] ?? videoStream['avg_frame_rate'],
        ),
        width: _int(videoStream['width']),
        height: _int(videoStream['height']),
        hasAudio: streams.any((stream) => stream['codec_type'] == 'audio'),
        frameCount: _int(videoStream['nb_frames']),
        rotationDegrees: _rotationDegrees(videoStream),
      );
    } on FormatException catch (error) {
      throw StateError('FFprobe 返回数据格式无效：$error');
    }
  }

  static int _rotationDegrees(Map<String, dynamic> stream) {
    final sideData = stream['side_data_list'];
    if (sideData is List) {
      for (final item in sideData) {
        if (item is! Map) continue;
        final parsed = _number(item['rotation']);
        if (parsed != null) return _normalizeRotation(parsed.round());
      }
    }
    final tags = stream['tags'];
    if (tags is Map) {
      final parsed = _number(tags['rotate']);
      if (parsed != null) return _normalizeRotation(parsed.round());
    }
    return 0;
  }

  static num? _number(Object? value) {
    if (value is num) return value;
    return num.tryParse('$value'.trim());
  }

  static int _normalizeRotation(int degrees) {
    final normalized = ((degrees % 360) + 360) % 360;
    if (normalized >= 45 && normalized < 135) return 90;
    if (normalized >= 135 && normalized < 225) return 180;
    if (normalized >= 225 && normalized < 315) return 270;
    return 0;
  }

  Future<List<ExtractedFrame>> extract({
    required File video,
    required Directory outputDirectory,
    Duration interval = const Duration(seconds: 1),
    VideoFrameExtractionStrategy strategy =
        VideoFrameExtractionStrategy.intervalOnly,
    double sceneThreshold = 0.3,
  }) async {
    await outputDirectory.create(recursive: true);
    final pattern =
        '${outputDirectory.path}${Platform.pathSeparator}frame-%06d.jpg';
    final executable = await _resolveFfmpegExecutable();
    final result = await _runner(
      executable,
      buildExtractArguments(
        videoPath: video.path,
        outputPattern: pattern,
        interval: interval,
        strategy: strategy,
        sceneThreshold: sceneThreshold,
      ),
    );
    if (result.exitCode != 0) {
      throw StateError('FFmpeg 抽帧失败：${result.stderr.trim()}');
    }
    final files =
        outputDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.jpg'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final parsedTimestamps =
        strategy == VideoFrameExtractionStrategy.sceneAndInterval ||
            strategy == VideoFrameExtractionStrategy.perFrame
        ? _showInfoTimestamps(result.stderr)
        : const <int>[];
    final intervalMs = interval.inMilliseconds;
    return [
      for (var index = 0; index < files.length; index++)
        ExtractedFrame(
          index: index,
          timestampMs: index < parsedTimestamps.length
              ? parsedTimestamps[index]
              : index * intervalMs,
          file: files[index],
        ),
    ];
  }

  Future<String> _resolveFfmpegExecutable() {
    if (!_runner.usesDefaultProcess) {
      return Future.value(ffmpegExecutable);
    }
    return (_toolResolver ?? const FfmpegToolResolver()).resolveFfmpeg(
      ffmpegExecutable,
    );
  }

  Future<String> _resolveFfprobeExecutable() {
    if (!_runner.usesDefaultProcess) {
      return Future.value(ffprobeExecutable);
    }
    return (_toolResolver ?? const FfmpegToolResolver()).resolveFfprobe(
      ffprobeExecutable,
    );
  }

  static List<int> _showInfoTimestamps(String stderr) {
    final expression = RegExp(r'pts_time:([0-9]+(?:\.[0-9]+)?)');
    return [
      for (final match in expression.allMatches(stderr))
        ((double.tryParse(match.group(1) ?? '') ?? 0) * 1000).round(),
    ];
  }

  static int _durationMilliseconds(Object? value) {
    final seconds = double.tryParse('$value') ?? 0;
    return (seconds * 1000).round();
  }

  static double _frameRate(Object? value) {
    final text = '$value';
    if (text.contains('/')) {
      final parts = text.split('/');
      final numerator = double.tryParse(parts.first) ?? 0;
      final denominator = double.tryParse(parts.last) ?? 1;
      return denominator == 0 ? 0 : numerator / denominator;
    }
    return double.tryParse(text) ?? 0;
  }

  static int _int(Object? value) => int.tryParse('$value') ?? 0;
}
