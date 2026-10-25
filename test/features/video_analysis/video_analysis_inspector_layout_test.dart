import 'dart:math' as math;

import 'package:filmstoryboard/features/video_analysis/presentation/video_analysis_inspector_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final panelSize in [
    const Size(216, 240),
    const Size(286, 480),
    const Size(376, 720),
  ]) {
    for (final ratio in [480 / 864, 16 / 9, 1.0]) {
      testWidgets('检查器 $panelSize / $ratio 最大化等比预览并保留详情', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: panelSize.width,
                  height: panelSize.height,
                  child: VideoAnalysisInspectorLayout(
                    aspectRatio: ratio,
                    preview: const ColoredBox(color: Colors.blue),
                    details: ListView(
                      key: const ValueKey('details'),
                      padding: EdgeInsets.zero,
                      children: [
                        const Text('镜头帧 #1'),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('设为焦点帧'),
                        ),
                        for (var i = 0; i < 40; i++) Text('解析维度 $i'),
                        const Text('视频级摘要'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final preview = tester.getRect(
          find.byKey(const ValueKey('analysis-inspector-preview-viewport')),
        );
        final details = tester.getRect(find.byKey(const ValueKey('details')));
        final contentHeight = panelSize.height - 12;
        final availableHeight =
            contentHeight - math.min(224.0, contentHeight / 2);
        expect(preview.width / preview.height, closeTo(ratio, 0.001));
        expect(preview.width, lessThanOrEqualTo(panelSize.width));
        expect(preview.height, lessThanOrEqualTo(availableHeight + 0.001));
        // 至少有一边触及边界，防止预览再次缩成中央小图。
        expect(
          (preview.width - panelSize.width).abs() < 0.001 ||
              (preview.height - availableHeight).abs() < 0.001,
          isTrue,
        );
        expect(details.top, greaterThan(preview.bottom));
        expect(details.bottom, closeTo(panelSize.height, 0.001));
        expect(find.text('设为焦点帧').hitTestable(), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('视频级摘要'),
          200,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('details')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('视频级摘要').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
