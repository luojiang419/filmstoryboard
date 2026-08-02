import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/widgets/viewport_lazy_grid.dart';

void main() {
  testWidgets('大量缩略图只构建父滚动视口附近的行', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 260,
            child: SingleChildScrollView(
              child: ViewportLazyGrid(
                itemCount: 1000,
                itemExtent: 50,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                itemBuilder: (context, index) => ColoredBox(
                  key: ValueKey('lazy-item-$index'),
                  color: Colors.blue,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initiallyBuilt = find.byType(ColoredBox).evaluate().length;
    expect(initiallyBuilt, greaterThan(0));
    expect(initiallyBuilt, lessThan(100));
    expect(find.byKey(const ValueKey('lazy-item-999')), findsNothing);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1800),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('lazy-item-0')), findsNothing);
    expect(find.byType(ColoredBox).evaluate().length, lessThan(100));
  });
}
