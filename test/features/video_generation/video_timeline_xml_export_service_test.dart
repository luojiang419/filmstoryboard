import 'dart:io';

import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/ffmpeg_frame_extractor.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/data/video_timeline_xml_export_service.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('时间线 XML 导出每镜最新可用版本及其 I/O 范围', () async {
    final root = await Directory.systemTemp.createTemp('timeline-xml-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final oldFile = File(p.join(root.path, 'shot001-old.mp4'))
      ..writeAsBytesSync([1]);
    final latestFile = File(p.join(root.path, 'shot001-latest.mp4'))
      ..writeAsBytesSync([2]);
    final secondFile = File(p.join(root.path, '镜头002 成片.mp4'))
      ..writeAsBytesSync([3]);
    final thirdOldFile = File(p.join(root.path, 'shot003-old.mp4'))
      ..writeAsBytesSync([4]);
    final thirdMissingFile = File(p.join(root.path, 'shot003-missing.mp4'));
    final now = DateTime.utc(2026, 8, 7, 9);
    final script = _script(id: 'script-1', name: '脚本 <A>&B');
    final shots = [
      _shot(id: 'shot-2', scriptId: script.id, shotNumber: 2),
      _shot(id: 'shot-1', scriptId: script.id, shotNumber: 1),
      _shot(id: 'shot-3', scriptId: script.id, shotNumber: 3),
    ];
    final tasks = [
      _task(
        id: 'old',
        scriptId: script.id,
        shotId: 'shot-1',
        localPath: oldFile.path,
        durationSeconds: 4,
        status: VideoGenerationTaskStatus.completed,
        createdAt: now,
        completedAt: now.add(const Duration(minutes: 10)),
      ),
      _task(
        id: 'latest',
        scriptId: script.id,
        shotId: 'shot-1',
        localPath: latestFile.path,
        durationSeconds: 5,
        sourceDurationMs: 5200,
        trimInMs: 400,
        trimOutMs: 4600,
        status: VideoGenerationTaskStatus.completed,
        createdAt: now.add(const Duration(minutes: 1)),
        completedAt: now.add(const Duration(minutes: 1)),
      ),
      _task(
        id: 'third-old',
        scriptId: script.id,
        shotId: 'shot-3',
        localPath: thirdOldFile.path,
        durationSeconds: 9,
        status: VideoGenerationTaskStatus.completed,
        createdAt: now.add(const Duration(minutes: 2)),
        completedAt: now.add(const Duration(minutes: 2)),
      ),
      _task(
        id: 'failed',
        scriptId: script.id,
        shotId: 'shot-2',
        localPath: secondFile.path,
        durationSeconds: 8,
        status: VideoGenerationTaskStatus.failed,
        createdAt: now.add(const Duration(minutes: 3)),
        completedAt: now.add(const Duration(minutes: 3)),
      ),
      _task(
        id: 'partial',
        scriptId: script.id,
        shotId: 'shot-2',
        localPath: secondFile.path,
        durationSeconds: 3,
        status: VideoGenerationTaskStatus.partialCompleted,
        createdAt: now.add(const Duration(minutes: 4)),
        completedAt: now.add(const Duration(minutes: 4)),
      ),
      _task(
        id: 'third-missing',
        scriptId: script.id,
        shotId: 'shot-3',
        localPath: thirdMissingFile.path,
        durationSeconds: 6,
        status: VideoGenerationTaskStatus.completed,
        createdAt: now.add(const Duration(minutes: 5)),
        completedAt: now.add(const Duration(minutes: 5)),
      ),
    ];
    final service = const VideoTimelineXmlExportService();

    final clips = service.timelineClips(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: (task) => File(task.localPath),
    );

    expect(clips.map((clip) => clip.task.id), [
      'latest',
      'partial',
      'third-old',
    ]);
    expect(clips.map((clip) => clip.startFrame), [0, 126, 216]);
    expect(clips.map((clip) => clip.endFrame), [126, 216, 486]);
    expect(clips.first.sourceDurationFrames, 156);
    expect(clips.first.sourceInFrame, 12);
    expect(clips.first.sourceOutFrame, 138);
    expect(clips.first.durationFrames, 126);

    final file = await service.export(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: (task) => File(task.localPath),
      outputDirectory: root,
      metadataProbe: (file) async => VideoMetadata(
        durationMs: switch (p.basename(file.path)) {
          '镜头002 成片.mp4' => 3000,
          'shot003-old.mp4' => 9000,
          _ => 5200,
        },
        frameRate: 30,
        width: 1920,
        height: 1080,
        hasAudio: true,
      ),
    );
    final xml = await file.readAsString();

    expect(file.path, endsWith('时间线-脚本 _A_&B.xml'));
    expect(xml, contains('<xmeml version="5">'));
    expect(xml, contains('<name>脚本 &lt;A&gt;&amp;B</name>'));
    expect(xml, contains('<start>0</start>'));
    expect(xml, contains('<duration>156</duration>'));
    expect(xml, contains('<in>12</in>'));
    expect(xml, contains('<out>138</out>'));
    expect(xml, contains('<end>126</end>'));
    expect(xml, contains('<start>126</start>'));
    expect(xml, contains('<end>216</end>'));
    expect(xml, contains('<start>216</start>'));
    expect(xml, contains('<end>486</end>'));
    expect(xml, contains(_expectedPremierePathUrl(latestFile)));
    expect(xml, contains(_expectedPremierePathUrl(secondFile)));
    expect(xml, isNot(contains('<pathurl>file:///')));
    expect(xml, isNot(contains('shot001-old.mp4')));
    expect(xml, contains('shot003-old.mp4'));
    expect(xml, isNot(contains('shot003-missing.mp4')));
  });

  test('Resolve 快照按真实媒体时长收紧源出点并保持片段连续', () async {
    final root = await Directory.systemTemp.createTemp('timeline-frame-clamp-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final files = [
      File(p.join(root.path, 'shot-1.mp4'))..writeAsBytesSync([1]),
      File(p.join(root.path, 'shot-2.mp4'))..writeAsBytesSync([2]),
      File(p.join(root.path, 'shot-3.mp4'))..writeAsBytesSync([3]),
    ];
    final script = _script(id: 'script-clamp', name: '帧边界测试');
    final shots = [
      _shot(id: 'shot-1', scriptId: script.id, shotNumber: 1),
      _shot(id: 'shot-2', scriptId: script.id, shotNumber: 2),
      _shot(id: 'shot-3', scriptId: script.id, shotNumber: 3),
    ];
    final tasks = [
      _task(
        id: 'task-1',
        scriptId: script.id,
        shotId: 'shot-1',
        localPath: files[0].path,
        durationSeconds: 4,
        sourceDurationMs: 4482,
        trimInMs: 1023,
        trimOutMs: 3828,
      ),
      _task(
        id: 'task-2',
        scriptId: script.id,
        shotId: 'shot-2',
        localPath: files[1].path,
        durationSeconds: 7,
        sourceDurationMs: 7323,
        trimOutMs: 7323,
      ),
      _task(
        id: 'task-3',
        scriptId: script.id,
        shotId: 'shot-3',
        localPath: files[2].path,
        durationSeconds: 3,
      ),
    ];
    final durations = <String, int>{
      files[0].path: 4458,
      files[1].path: 7292,
      files[2].path: 3042,
    };

    final snapshot = await const VideoTimelineXmlExportService().buildSnapshot(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: (task) => File(task.localPath),
      metadataProbe: (file) async => VideoMetadata(
        durationMs: durations[file.path]!,
        frameRate: 24,
        width: 1280,
        height: 736,
        hasAudio: true,
      ),
    );

    expect(snapshot.clips.map((clip) => clip.recordStartFrame), [0, 67, 242]);
    expect(snapshot.clips.map((clip) => clip.recordEndFrame), [67, 242, 314]);
    expect(snapshot.clips[1].trimOutMs, 7292);
    expect(snapshot.clips[1].sourceDurationFrames, 175);
    expect(snapshot.clips[1].sourceOutFrame, 175);
    expect(snapshot.clips[1].sourceFrameCount, 175);
    for (var index = 1; index < snapshot.clips.length; index++) {
      expect(
        snapshot.clips[index].recordStartFrame,
        snapshot.clips[index - 1].recordEndFrame,
      );
    }
  });

  test('合并镜头组只导出组首最终视频而不带入组内历史视频', () async {
    final root = await Directory.systemTemp.createTemp('timeline-groups-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final script = _script(id: 'script-groups', name: '六组拍摄脚本');
    final ranges = [
      [1, 2, 3],
      [4, 5, 6],
      [7, 8, 9],
      [10],
      [11, 12, 13],
      [14, 15, 16, 17],
    ];
    final shots = <ScriptShot>[
      for (final range in ranges)
        for (var index = 0; index < range.length; index++)
          _shot(
            id: 'shot-${range[index]}',
            scriptId: script.id,
            shotNumber: range[index],
            continuesFromPrevious: index > 0,
            continuesToNext: index < range.length - 1,
          ),
    ];
    final now = DateTime.utc(2026, 8, 9, 8);
    const versionByShot = {1: 18, 4: 11, 7: 12, 10: 12, 11: 11, 14: 11};
    final tasks = <VideoGenerationTask>[];
    final filesByShot = <int, File>{};
    for (final shot in shots) {
      final version = versionByShot[shot.shotNumber] ?? 1;
      final file = File(
        p.join(
          root.path,
          '镜头${shot.shotNumber.toString().padLeft(3, '0')}-v$version.mp4',
        ),
      )..writeAsBytesSync([shot.shotNumber]);
      filesByShot[shot.shotNumber] = file;
      tasks.add(
        _task(
          id: 'task-${shot.shotNumber}',
          scriptId: script.id,
          shotId: shot.id,
          localPath: file.path,
          createdAt: now.add(Duration(minutes: shot.shotNumber)),
        ),
      );
    }

    final clips = const VideoTimelineXmlExportService().timelineClips(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: (task) => File(task.localPath),
    );

    expect(clips.map((clip) => clip.shot.shotNumber), [1, 4, 7, 10, 11, 14]);
    expect(clips.map((clip) => clip.timelineShotNumber), [1, 2, 3, 4, 5, 6]);
    expect(clips.map((clip) => clip.task.id), [
      'task-1',
      'task-4',
      'task-7',
      'task-10',
      'task-11',
      'task-14',
    ]);

    final output = await const VideoTimelineXmlExportService().export(
      script: script,
      shots: shots,
      tasks: tasks,
      fileForTask: (task) => File(task.localPath),
      outputDirectory: root,
      metadataProbe: (_) async => const VideoMetadata(
        durationMs: 15000,
        frameRate: 30,
        width: 1920,
        height: 1080,
        hasAudio: true,
      ),
    );
    final xml = await output.readAsString();
    for (final shotNumber in versionByShot.keys) {
      final expected =
          '镜头${shotNumber.toString().padLeft(3, '0')}-v${versionByShot[shotNumber]}.mp4';
      expect(
        RegExp('<name>$expected</name>').allMatches(xml),
        hasLength(2),
        reason: '旧项目的剪辑名与媒体名必须保留原文件名',
      );
    }
    for (final file in filesByShot.values) {
      expect(file.existsSync(), isTrue, reason: '导出时不得迁移或重命名任何旧成片');
    }
    expect(xml, isNot(contains('<name>镜头 4 ·')));
    expect(
      xml,
      contains(_expectedPremierePathUrl(filesByShot[4]!)),
      reason: 'pathurl 必须继续指向旧项目原成片',
    );
  });

  test('没有本地完成视频时不生成空时间线', () async {
    final root = await Directory.systemTemp.createTemp('timeline-empty-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final script = _script(id: 'script-1', name: '空时间线');
    final service = const VideoTimelineXmlExportService();

    expect(
      () => service.export(
        script: script,
        shots: [_shot(id: 'shot-1', scriptId: script.id, shotNumber: 1)],
        tasks: [
          _task(
            id: 'failed',
            scriptId: script.id,
            shotId: 'shot-1',
            localPath: p.join(root.path, 'failed.mp4'),
            status: VideoGenerationTaskStatus.failed,
          ),
        ],
        fileForTask: (task) => File(task.localPath),
        outputDirectory: root,
      ),
      throwsA(isA<VideoTimelineXmlExportException>()),
    );
  });

  test('导出 XML 使用首个有效素材规格并按版本避免覆盖', () async {
    final root = await Directory.systemTemp.createTemp('timeline-spec-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final source = File(p.join(root.path, 'portrait.mp4'))
      ..writeAsBytesSync([1]);
    final script = _script(id: 'script-spec', name: '竖屏脚本');
    final shot = _shot(id: 'shot-spec', scriptId: script.id, shotNumber: 1);
    final task = _task(
      id: 'task-spec',
      scriptId: script.id,
      shotId: shot.id,
      localPath: source.path,
      durationSeconds: 5,
      sourceDurationMs: 5000,
      trimInMs: 1000,
      trimOutMs: 4000,
    );
    const metadata = VideoMetadata(
      durationMs: 5000,
      frameRate: 24000 / 1001,
      width: 1920,
      height: 1080,
      hasAudio: true,
      rotationDegrees: 90,
    );
    final exportedAt = DateTime(2026, 8, 12, 14, 30, 25);
    const service = VideoTimelineXmlExportService();

    final first = await service.export(
      script: script,
      shots: [shot],
      tasks: [task],
      fileForTask: (_) => source,
      outputDirectory: root,
      metadataProbe: (_) async => metadata,
      exportedAt: exportedAt,
    );
    final second = await service.export(
      script: script,
      shots: [shot],
      tasks: [task],
      fileForTask: (_) => source,
      outputDirectory: root,
      metadataProbe: (_) async => metadata,
      exportedAt: exportedAt,
    );
    final third = await service.export(
      script: script,
      shots: [shot],
      tasks: [task],
      fileForTask: (_) => source,
      outputDirectory: root,
      metadataProbe: (_) async => metadata,
      exportedAt: exportedAt,
    );
    final xml = await first.readAsString();

    expect(p.basename(first.path), '时间线-竖屏脚本.xml');
    expect(p.basename(second.path), '时间线-竖屏脚本-V002-20260812-143025.xml');
    expect(p.basename(third.path), '时间线-竖屏脚本-V003-20260812-143025.xml');
    expect(xml, contains('<timebase>24</timebase><ntsc>TRUE</ntsc>'));
    expect(xml, contains('<width>1080</width>'));
    expect(xml, contains('<height>1920</height>'));
    expect(xml, contains('<in>24</in>'));
    expect(xml, contains('<out>96</out>'));
  });
}

ShootingScript _script({required String id, required String name}) {
  final now = DateTime.utc(2026, 8, 7);
  return ShootingScript(
    id: id,
    name: name,
    sourceStoryboardId: null,
    sourceVideoId: null,
    status: ShootingScriptStatus.active,
    version: 1,
    createdAt: now,
    updatedAt: now,
  );
}

ScriptShot _shot({
  required String id,
  required String scriptId,
  required int shotNumber,
  bool continuesFromPrevious = false,
  bool continuesToNext = false,
}) {
  return ScriptShot(
    id: id,
    scriptId: scriptId,
    shotNumber: shotNumber,
    durationSeconds: 4,
    framePath: '',
    visual: '',
    content: '',
    shotSize: '',
    cameraMovement: '',
    cameraNotes: '',
    continuesFromPrevious: continuesFromPrevious,
    continuesToNext: continuesToNext,
    scene: '',
    productCode: '',
    productStyling: '',
    dialogue: '',
    sound: '',
    prompt: '',
    status: ProcessingStatus.completed,
    updatedAt: DateTime.utc(2026, 8, 7),
  );
}

VideoGenerationTask _task({
  required String id,
  required String scriptId,
  required String shotId,
  required String localPath,
  VideoGenerationTaskStatus status = VideoGenerationTaskStatus.completed,
  int durationSeconds = 4,
  int sourceDurationMs = 0,
  int trimInMs = 0,
  int trimOutMs = 0,
  DateTime? completedAt,
  DateTime? createdAt,
}) {
  final now = completedAt ?? DateTime.utc(2026, 8, 7);
  return VideoGenerationTask(
    id: id,
    scriptId: scriptId,
    shotId: shotId,
    model: 'test-model',
    durationSeconds: durationSeconds,
    sourceDurationMs: sourceDurationMs,
    trimInMs: trimInMs,
    trimOutMs: trimOutMs,
    promptMode: VideoPromptMode.klingOptimized,
    prompt: 'prompt',
    status: status,
    localPath: localPath,
    createdAt: createdAt ?? now,
    updatedAt: now,
    completedAt: completedAt,
  );
}

String _expectedPremierePathUrl(File file) {
  if (!Platform.isWindows) {
    return Uri.file(file.absolute.path).toString();
  }
  final normalized = file.absolute.path.replaceAll('\\', '/');
  final match = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (match == null) {
    return Uri.file(file.absolute.path, windows: true).toString();
  }
  final encodedPath = match
      .group(2)!
      .split('/')
      .map(Uri.encodeComponent)
      .join('/');
  return 'file://localhost/${match.group(1)}%3A/$encodedPath';
}
