import 'package:filmstoryboard/features/video_generation/domain/generated_video_trim_range.dart';
import 'package:filmstoryboard/features/video_generation/presentation/widgets/generated_video_trim_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('时间码按 30fps 输出 SMPTE 格式', () {
    expect(
      formatVideoTimecode(const Duration(milliseconds: 1234)),
      '00:00:01:07',
    );
    expect(
      formatVideoTimecode(const Duration(hours: 1, seconds: 2)),
      '01:00:02:00',
    );
  });

  testWidgets('IO 时间轴提供刻度、双拖拽点并按帧归一化', (tester) async {
    GeneratedVideoTrimRange? changed;
    GeneratedVideoTrimRange? committed;
    final seekPositions = <Duration>[];
    const initial = GeneratedVideoTrimRange(
      sourceDuration: Duration(seconds: 5),
      inPoint: Duration.zero,
      outPoint: Duration(seconds: 5),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GeneratedVideoTrimTimeline(
            range: initial,
            position: const Duration(seconds: 1),
            onSeek: seekPositions.add,
            onChanged: (range) => changed = range,
            onChangeEnd: (range) => committed = range,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('generated-video-io-timeline')), findsOne);
    final slider = tester.widget<RangeSlider>(
      find.byKey(const ValueKey('generated-video-io-range-slider')),
    );
    slider.onChanged!(const RangeValues(351, 4591));
    slider.onChangeEnd!(const RangeValues(351, 4591));

    expect(changed?.inPoint, const Duration(milliseconds: 363));
    expect(changed?.outPoint, const Duration(milliseconds: 4587));
    expect(committed?.inPoint, changed?.inPoint);
    expect(committed?.outPoint, changed?.outPoint);

    final seekArea = tester.getRect(
      find.byKey(const ValueKey('generated-video-io-seek-area')),
    );
    await tester.tapAt(
      Offset(seekArea.left + seekArea.width * 0.6, seekArea.top + 30),
    );
    expect(seekPositions.last, const Duration(seconds: 3));

    final gesture = await tester.startGesture(
      Offset(seekArea.left + seekArea.width * 0.2, seekArea.top + 30),
    );
    await gesture.moveTo(
      Offset(seekArea.left + seekArea.width * 0.45, seekArea.top + 30),
    );
    await tester.pump();
    await gesture.moveTo(
      Offset(seekArea.left + seekArea.width * 0.8, seekArea.top + 30),
    );
    await gesture.up();

    expect(seekPositions.length, greaterThanOrEqualTo(3));
    expect(seekPositions, contains(const Duration(milliseconds: 2250)));
    expect(seekPositions.last, const Duration(seconds: 4));
  });
}
