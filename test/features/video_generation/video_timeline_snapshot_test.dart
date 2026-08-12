import 'package:filmstoryboard/features/video_generation/domain/video_timeline_snapshot.dart';
import 'package:test/test.dart';

void main() {
  test('快照修订号忽略生成时间但跟踪素材与 IO 点', () {
    final first = _snapshot(generatedAt: DateTime.utc(2026, 8, 12, 10));
    final later = _snapshot(generatedAt: DateTime.utc(2026, 8, 12, 11));
    final trimmed = _snapshot(
      generatedAt: DateTime.utc(2026, 8, 12, 11),
      trimInMs: 600,
    );

    expect(first.revision, later.revision);
    expect(first.revision, isNot(trimmed.revision));
    expect(first.toJson()['generatedAt'], '2026-08-12T10:00:00.000Z');
    expect(first.toJson()['revision'], first.revision);
  });

  test('NTSC 帧率映射为正确 timebase', () {
    final rate = VideoTimelineFrameRate.fromFramesPerSecond(24000 / 1001);

    expect(rate.timebase, 24);
    expect(rate.isNtsc, isTrue);
    expect(rate.framesPerSecond, closeTo(23.976, 0.001));
  });
}

VideoTimelineSnapshot _snapshot({
  required DateTime generatedAt,
  int trimInMs = 500,
}) => VideoTimelineSnapshot(
  scriptId: 'script-1',
  scriptName: '拍摄脚本',
  width: 1920,
  height: 1080,
  frameRate: const VideoTimelineFrameRate.standard(30),
  generatedAt: generatedAt,
  clips: [
    VideoTimelineSnapshotClip(
      shotId: 'shot-1',
      shotNumber: 1,
      timelineShotNumber: 1,
      taskId: 'task-1',
      filePath: r'G:\project\shot-1.mp4',
      fileSize: 1024,
      fileModifiedAtMs: 1000,
      sourceDurationMs: 5000,
      trimInMs: trimInMs,
      trimOutMs: 4500,
      sourceDurationFrames: 150,
      sourceInFrame: 15,
      sourceOutFrame: 135,
      recordStartFrame: 0,
      recordEndFrame: 120,
      sourceWidth: 1920,
      sourceHeight: 1080,
      sourceFrameRate: 30,
      hasAudio: true,
    ),
  ],
);
