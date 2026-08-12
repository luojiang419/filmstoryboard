import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/video_analysis/data/ffmpeg_frame_extractor.dart';
import 'package:filmstoryboard/features/video_analysis/data/ffmpeg_tool_resolver.dart';
import 'package:filmstoryboard/features/video_analysis/data/frame_quality_service.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_import_service.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('FFprobe 元数据解析和 FFmpeg 抽帧命令可注入测试执行器', () async {
    final root = await Directory.systemTemp.createTemp(
      'filmstoryboard-module-b-',
    );
    addTearDown(() => root.delete(recursive: true));
    final calls = <List<String>>[];
    final runner = FfmpegProcessRunner(
      run: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        if (executable == 'ffprobe') {
          return FfmpegProcessResult(
            exitCode: 0,
            stdout: jsonEncode({
              'format': {'duration': '12.5'},
              'streams': [
                {
                  'codec_type': 'video',
                  'width': 1920,
                  'height': 1080,
                  'r_frame_rate': '24/1',
                  'duration': '12.458333',
                  'nb_frames': '299',
                },
                {'codec_type': 'audio'},
              ],
            }),
            stderr: '',
          );
        }
        final pattern = arguments.last;
        final directory = Directory(
          pattern.substring(0, pattern.lastIndexOf(Platform.pathSeparator)),
        );
        await directory.create(recursive: true);
        await File(
          '${directory.path}${Platform.pathSeparator}frame-000000.jpg',
        ).writeAsBytes([1, 2, 3]);
        await File(
          '${directory.path}${Platform.pathSeparator}frame-000001.jpg',
        ).writeAsBytes([4, 5, 6]);
        return const FfmpegProcessResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
    final video = File('${root.path}${Platform.pathSeparator}source.mp4')
      ..writeAsStringSync('video');
    final extractor = FfmpegFrameExtractor(runner: runner);

    final metadata = await extractor.probe(video);
    final frames = await extractor.extract(
      video: video,
      outputDirectory: Directory('${root.path}${Platform.pathSeparator}frames'),
    );

    expect(metadata.durationMs, 12458);
    expect(metadata.frameRate, 24);
    expect(metadata.frameCount, 299);
    expect(metadata.hasAudio, isTrue);
    expect(metadata.rotationDegrees, 0);
    expect(metadata.displayWidth, 1920);
    expect(metadata.displayHeight, 1080);
    expect(frames.map((frame) => frame.timestampMs), [0, 1000]);
    expect(calls.first, containsAllInOrder(['-show_entries']));
    expect(
      calls.first[calls.first.indexOf('-show_entries') + 1],
      contains('stream_side_data=rotation'),
    );
    expect(calls.first, isNot(contains('-show_format')));
    expect(calls.first, isNot(contains('-show_streams')));
    expect(calls[1], containsAllInOrder(['-vf', 'fps=1/1.0', '-q:v', '2']));
  });

  test('FFprobe 会按 display matrix 旋转角计算视频实际显示尺寸', () async {
    final root = await Directory.systemTemp.createTemp(
      'filmstoryboard-portrait-metadata-',
    );
    addTearDown(() => root.delete(recursive: true));
    final video = File('${root.path}${Platform.pathSeparator}portrait.mp4')
      ..writeAsStringSync('video');
    final extractor = FfmpegFrameExtractor(
      runner: FfmpegProcessRunner(
        run: (_, _) async => FfmpegProcessResult(
          exitCode: 0,
          stdout: jsonEncode({
            'format': {'duration': '8'},
            'streams': [
              {
                'codec_type': 'video',
                'width': 1920,
                'height': 1080,
                'avg_frame_rate': '30/1',
                'side_data_list': [
                  {'side_data_type': 'Display Matrix', 'rotation': -90},
                ],
              },
            ],
          }),
          stderr: '',
        ),
      ),
    );

    final metadata = await extractor.probe(video);

    expect(metadata.rotationDegrees, 270);
    expect(metadata.displayWidth, 1080);
    expect(metadata.displayHeight, 1920);
    expect(metadata.isPortrait, isTrue);
    expect(metadata.displayAspectRatio, closeTo(9 / 16, 0.0001));
  });

  test('FFprobe 在没有 display matrix 时兼容 rotate 标签', () async {
    final root = await Directory.systemTemp.createTemp(
      'filmstoryboard-rotate-tag-',
    );
    addTearDown(() => root.delete(recursive: true));
    final video = File('${root.path}${Platform.pathSeparator}portrait.mov')
      ..writeAsStringSync('video');
    final extractor = FfmpegFrameExtractor(
      runner: FfmpegProcessRunner(
        run: (_, _) async => FfmpegProcessResult(
          exitCode: 0,
          stdout: jsonEncode({
            'format': {'duration': '5'},
            'streams': [
              {
                'codec_type': 'video',
                'width': 3840,
                'height': 2160,
                'r_frame_rate': '25/1',
                'tags': {'rotate': '90'},
              },
            ],
          }),
          stderr: '',
        ),
      ),
    );

    final metadata = await extractor.probe(video);

    expect(metadata.rotationDegrees, 90);
    expect(metadata.displayWidth, 2160);
    expect(metadata.displayHeight, 3840);
  });

  test('帧质量服务标记模糊、曝光异常和重复帧，不删除源帧', () {
    const service = FrameQualityService();
    final result = service.assess(
      sharpness: 0.1,
      brightness: 0.98,
      perceptualHash: 'same',
      knownHashes: {'same'},
    );
    expect(result.isFocus, isFalse);
    expect(result.isDuplicate, isTrue);
    expect(result.errorMessage, contains('清晰度'));
    expect(result.errorMessage, contains('曝光'));
    expect(result.errorMessage, contains('重复'));
  });

  test('找不到系统 FFmpeg 时会下载并缓存 Windows 工具', () async {
    final root = await Directory.systemTemp.createTemp('ffmpeg-tool-resolver-');
    addTearDown(() => root.delete(recursive: true));
    var downloadCount = 0;
    final resolver = FfmpegToolResolver(
      cacheDirectory: Directory('${root.path}${Platform.pathSeparator}tools'),
      checkSystemPath: false,
      isWindows: true,
      download: (url, destination) async {
        downloadCount++;
        final archive = Archive()
          ..addFile(ArchiveFile.bytes('ffmpeg-build/bin/ffmpeg.exe', [1, 2, 3]))
          ..addFile(
            ArchiveFile.bytes('ffmpeg-build/bin/ffprobe.exe', [4, 5, 6]),
          );
        await destination.writeAsBytes(ZipEncoder().encode(archive));
      },
    );

    final ffprobe = await resolver.resolveFfprobe('missing-ffprobe');
    final ffmpeg = await resolver.resolveFfmpeg('missing-ffmpeg');
    final secondFfprobe = await resolver.resolveFfprobe('missing-ffprobe');

    expect(File(ffprobe).existsSync(), isTrue);
    expect(File(ffmpeg).existsSync(), isTrue);
    expect(ffprobe, endsWith('ffprobe.exe'));
    expect(ffmpeg, endsWith('ffmpeg.exe'));
    expect(secondFfprobe, ffprobe);
    expect(downloadCount, 1);
  });

  test('场景变化加间隔补帧会使用 VFR 并读取真实时间戳', () async {
    final root = await Directory.systemTemp.createTemp('scene_extract_');
    addTearDown(() => root.delete(recursive: true));
    late List<String> extractArguments;
    final extractor = FfmpegFrameExtractor(
      runner: FfmpegProcessRunner(
        run: (executable, arguments) async {
          extractArguments = arguments;
          final pattern = arguments.last;
          final directory = Directory(
            pattern.substring(0, pattern.lastIndexOf(Platform.pathSeparator)),
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}${Platform.pathSeparator}frame-000000.jpg',
          ).writeAsBytes([1]);
          await File(
            '${directory.path}${Platform.pathSeparator}frame-000001.jpg',
          ).writeAsBytes([2]);
          return const FfmpegProcessResult(
            exitCode: 0,
            stdout: '',
            stderr:
                'showinfo pts_time:0.000 other\nshowinfo pts_time:4.320 other',
          );
        },
      ),
    );
    final video = File('${root.path}${Platform.pathSeparator}video.mp4')
      ..writeAsStringSync('video');

    final frames = await extractor.extract(
      video: video,
      outputDirectory: Directory('${root.path}${Platform.pathSeparator}frames'),
      strategy: VideoFrameExtractionStrategy.sceneAndInterval,
      sceneThreshold: 0.35,
    );

    expect(extractArguments, containsAllInOrder(['-fps_mode', 'vfr']));
    expect(extractArguments.join(' '), contains('gt(scene'));
    expect(frames.map((frame) => frame.timestampMs), [0, 4320]);
  });

  test('逐帧抽帧会导出全部帧并读取真实时间戳', () async {
    final root = await Directory.systemTemp.createTemp('per_frame_extract_');
    addTearDown(() => root.delete(recursive: true));
    late List<String> extractArguments;
    final extractor = FfmpegFrameExtractor(
      runner: FfmpegProcessRunner(
        run: (executable, arguments) async {
          extractArguments = arguments;
          final pattern = arguments.last;
          final directory = Directory(
            pattern.substring(0, pattern.lastIndexOf(Platform.pathSeparator)),
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}${Platform.pathSeparator}frame-000000.jpg',
          ).writeAsBytes([1]);
          await File(
            '${directory.path}${Platform.pathSeparator}frame-000001.jpg',
          ).writeAsBytes([2]);
          return const FfmpegProcessResult(
            exitCode: 0,
            stdout: '',
            stderr:
                'showinfo pts_time:0.000 other\nshowinfo pts_time:0.020 other',
          );
        },
      ),
    );
    final video = File('${root.path}${Platform.pathSeparator}video.mp4')
      ..writeAsStringSync('video');

    final frames = await extractor.extract(
      video: video,
      outputDirectory: Directory('${root.path}${Platform.pathSeparator}frames'),
      strategy: VideoFrameExtractionStrategy.perFrame,
    );

    expect(extractArguments, containsAllInOrder(['-vf', 'showinfo']));
    expect(extractArguments, containsAllInOrder(['-fps_mode', 'vfr']));
    expect(extractArguments.join(' '), isNot(contains('fps=1/')));
    expect(frames.map((frame) => frame.timestampMs), [0, 20]);
  });

  test('帧质量服务从真实图片计算清晰度、亮度和感知哈希', () async {
    final root = await Directory.systemTemp.createTemp('frame_metrics_');
    addTearDown(() => root.delete(recursive: true));
    final image = img.Image(width: 16, height: 16);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, x.isEven ? 255 : 0, y.isEven ? 255 : 0, 64);
      }
    }
    final file = File('${root.path}${Platform.pathSeparator}frame.png');
    await file.writeAsBytes(img.encodePng(image));

    final metrics = await const FrameQualityService().analyze(file);

    expect(metrics.width, 16);
    expect(metrics.height, 16);
    expect(metrics.sharpness, greaterThan(0));
    expect(metrics.brightness, inInclusiveRange(0, 1));
    expect(metrics.perceptualHash, hasLength(16));
  });

  test('视频导入按视频 ID 保存原视频和帧目录', () async {
    final root = await Directory.systemTemp.createTemp(
      'filmstoryboard-module-b-import-',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final source = File('${root.path}${Platform.pathSeparator}clip.mp4')
      ..writeAsStringSync('video');
    final extractor = FfmpegFrameExtractor(
      runner: FfmpegProcessRunner(
        run: (executable, arguments) async {
          if (executable == 'ffprobe') {
            return const FfmpegProcessResult(
              exitCode: 0,
              stdout:
                  '{"format":{"duration":"2"},"streams":[{"codec_type":"video","width":640,"height":360,"r_frame_rate":"30/1"}]}',
              stderr: '',
            );
          }
          final pattern = arguments.last;
          final directory = Directory(
            pattern.substring(0, pattern.lastIndexOf(Platform.pathSeparator)),
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}${Platform.pathSeparator}frame-000000.jpg',
          ).writeAsBytes([1]);
          return const FfmpegProcessResult(exitCode: 0, stdout: '', stderr: '');
        },
      ),
    );
    final result = await VideoImportService(
      directories: directories,
      extractor: extractor,
    ).importVideo(source);

    expect(result.video.storedPath, startsWith('videos/'));
    expect(result.video.frameCount, 1);
    expect(
      File(
        '${directories.root.path}${Platform.pathSeparator}'
        '${result.video.storedPath.replaceAll('/', Platform.pathSeparator)}',
      ).existsSync(),
      isTrue,
    );
    expect(result.video.storedPath, contains('clip-'));
    expect(result.frameFiles.single.file.existsSync(), isTrue);
  });
}
