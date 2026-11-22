import 'dart:io';

import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/ffmpeg_frame_extractor.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/data/generated_video_compose_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_timeline_xml_export_service.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('按镜头顺序和 I/O 范围构造 H.264/AAC 拼接并为空音轨补静音', () async {
    final root = await Directory.systemTemp.createTemp('compose-video-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final firstFile = File(p.join(root.path, 'shot-1.mp4'))
      ..writeAsBytesSync([1]);
    final secondFile = File(p.join(root.path, 'shot-2.mp4'))
      ..writeAsBytesSync([2]);
    final script = _script('脚本<A>');
    final clips = [
      _clip(
        script: script,
        id: 'first',
        shotNumber: 1,
        file: firstFile,
        startFrame: 0,
        sourceDurationFrames: 156,
        sourceInFrame: 12,
        sourceOutFrame: 138,
      ),
      _clip(
        script: script,
        id: 'second',
        shotNumber: 2,
        file: secondFile,
        startFrame: 126,
        sourceDurationFrames: 90,
        sourceInFrame: 0,
        sourceOutFrame: 90,
      ),
    ];
    File(p.join(root.path, '成片-脚本_A_.mp4')).writeAsBytesSync([9]);
    String? executable;
    List<String>? arguments;
    final service = GeneratedVideoComposeService(
      ffmpegExecutable: 'test-ffmpeg',
      probe: (video) async => VideoMetadata(
        durationMs: 5200,
        frameRate: 30,
        width: 1920,
        height: 1080,
        hasAudio: video.path == firstFile.path,
      ),
      runner: FfmpegProcessRunner(
        run: (receivedExecutable, receivedArguments) async {
          executable = receivedExecutable;
          arguments = receivedArguments;
          await File(receivedArguments.last).writeAsBytes([7, 8, 9]);
          return const FfmpegProcessResult(exitCode: 0, stdout: '', stderr: '');
        },
      ),
    );

    final output = await service.export(
      script: script,
      clips: clips,
      outputDirectory: root,
      width: 1080,
      height: 1920,
    );

    expect(executable, 'test-ffmpeg');
    expect(p.basename(output.path), '成片-脚本_A_-2.mp4');
    expect(output.readAsBytesSync(), [7, 8, 9]);
    expect(arguments, containsAllInOrder(['-i', firstFile.path]));
    expect(arguments, containsAllInOrder(['-i', secondFile.path]));
    final filter = arguments![arguments!.indexOf('-filter_complex') + 1];
    expect(filter, contains('[0:v:0]trim=start=0.400:end=4.600'));
    expect(filter, contains('scale=1080:1920'));
    expect(filter, contains('[0:a:0]atrim=start=0.400:end=4.600'));
    expect(filter, contains('apad=whole_dur=4.200'));
    expect(
      filter,
      contains('anullsrc=channel_layout=stereo:sample_rate=48000'),
    );
    expect(filter, contains('atrim=duration=3.000'));
    expect(filter, contains('concat=n=2:v=1:a=1[vout][aout]'));
    expect(arguments, containsAllInOrder(['-c:v', 'libx264']));
    expect(arguments, containsAllInOrder(['-c:a', 'aac']));
    expect(
      root.listSync().whereType<File>().map((file) => p.basename(file.path)),
      isNot(contains(contains('.partial.mp4'))),
    );
  });

  test('FFmpeg 失败时删除未完成文件并返回简洁错误', () async {
    final root = await Directory.systemTemp.createTemp('compose-failure-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, 'source.mp4'))..writeAsBytesSync([1]);
    final script = _script('失败用例');
    final service = GeneratedVideoComposeService(
      probe: (_) async => const VideoMetadata(
        durationMs: 4000,
        frameRate: 30,
        width: 1920,
        height: 1080,
        hasAudio: true,
      ),
      runner: FfmpegProcessRunner(
        run: (_, arguments) async {
          await File(arguments.last).writeAsBytes([1]);
          return const FfmpegProcessResult(
            exitCode: 1,
            stdout: '',
            stderr: 'encoder failed',
          );
        },
      ),
    );

    await expectLater(
      service.export(
        script: script,
        clips: [
          _clip(
            script: script,
            id: 'failed',
            shotNumber: 1,
            file: source,
            startFrame: 0,
            sourceDurationFrames: 120,
            sourceInFrame: 0,
            sourceOutFrame: 120,
          ),
        ],
        outputDirectory: root,
        width: 1920,
        height: 1080,
      ),
      throwsA(
        isA<GeneratedVideoComposeException>().having(
          (error) => error.message,
          'message',
          contains('encoder failed'),
        ),
      ),
    );
    expect(
      root.listSync().whereType<File>().map((file) => p.basename(file.path)),
      isNot(contains(contains('.partial.mp4'))),
    );
    expect(File(p.join(root.path, '成片-失败用例.mp4')).existsSync(), isFalse);
  });
}

ShootingScript _script(String name) {
  final now = DateTime.utc(2026, 8, 12);
  return ShootingScript(
    id: 'script-1',
    name: name,
    sourceStoryboardId: null,
    sourceVideoId: null,
    status: ShootingScriptStatus.active,
    version: 1,
    createdAt: now,
    updatedAt: now,
  );
}

VideoTimelineExportClip _clip({
  required ShootingScript script,
  required String id,
  required int shotNumber,
  required File file,
  required int startFrame,
  required int sourceDurationFrames,
  required int sourceInFrame,
  required int sourceOutFrame,
}) {
  final now = DateTime.utc(2026, 8, 12);
  final durationFrames = sourceOutFrame - sourceInFrame;
  final shot = ScriptShot(
    id: 'shot-$shotNumber',
    scriptId: script.id,
    shotNumber: shotNumber,
    durationSeconds: 4,
    framePath: '',
    visual: '',
    content: '',
    shotSize: '',
    cameraMovement: '',
    cameraNotes: '',
    scene: '',
    productCode: '',
    productStyling: '',
    dialogue: '',
    sound: '',
    prompt: '',
    status: ProcessingStatus.completed,
    updatedAt: now,
  );
  final task = VideoGenerationTask(
    id: id,
    scriptId: script.id,
    shotId: shot.id,
    model: 'test',
    durationSeconds: 4,
    promptMode: VideoPromptMode.klingOptimized,
    prompt: '',
    status: VideoGenerationTaskStatus.completed,
    localPath: file.path,
    createdAt: now,
    updatedAt: now,
  );
  return VideoTimelineExportClip(
    shot: shot,
    task: task,
    file: file,
    timelineShotNumber: shotNumber,
    startFrame: startFrame,
    endFrame: startFrame + durationFrames,
    durationFrames: durationFrames,
    sourceDurationFrames: sourceDurationFrames,
    sourceInFrame: sourceInFrame,
    sourceOutFrame: sourceOutFrame,
  );
}
