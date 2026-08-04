import 'package:filmstoryboard/core/widgets/middle_drag_auto_scroll.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('鼠标中键按住拖拽会显示锚点并持续滚动', (tester) async {
    final middleDragController = MiddleDragAutoScrollController();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: MiddleDragScrollBehavior(
          controller: middleDragController,
        ),
        home: MiddleDragAutoScroll(
          controller: middleDragController,
          child: SizedBox(
            width: 420,
            height: 260,
            child: ListView.builder(
              controller: scrollController,
              itemExtent: 48,
              itemCount: 40,
              itemBuilder: (context, index) => Text('item-$index'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('middle-drag-scroll-anchor')),
      findsOneWidget,
    );

    await gesture.moveBy(const Offset(0, 140));
    await tester.pump(const Duration(milliseconds: 80));

    expect(scrollController.offset, greaterThan(0));

    await gesture.up();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('middle-drag-scroll-anchor')),
      findsNothing,
    );
  });
}
