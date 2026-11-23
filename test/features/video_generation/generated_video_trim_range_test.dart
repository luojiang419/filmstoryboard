import 'package:filmstoryboard/features/video_generation/domain/generated_video_trim_range.dart';
import 'package:test/test.dart';

void main() {
  test('旧任务默认使用完整请求时长', () {
    final range = GeneratedVideoTrimRange.fromMilliseconds(
      sourceDurationMs: 0,
      trimInMs: 0,
      trimOutMs: 0,
      fallbackDurationMs: 5000,
    );

    expect(range.inPoint, Duration.zero);
    expect(range.outPoint, const Duration(seconds: 5));
    expect(range.duration, const Duration(seconds: 5));
    expect(range.isFullRange, isTrue);
  });

  test('非法历史 IO 点会被夹在真实视频时长内', () {
    final range = GeneratedVideoTrimRange.fromMilliseconds(
      sourceDurationMs: 4200,
      trimInMs: 9000,
      trimOutMs: 300,
      fallbackDurationMs: 5000,
    );

    expect(range.inPoint, const Duration(milliseconds: 4199));
    expect(range.outPoint, const Duration(milliseconds: 4200));
    expect(range.duration, const Duration(milliseconds: 1));
    expect(range.isFullRange, isFalse);
  });
}
