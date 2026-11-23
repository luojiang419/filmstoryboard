import 'package:filmstoryboard/core/widgets/value_listenable_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('只在选中的切片变化时重建', (tester) async {
    final notifier = ValueNotifier<_TestState>(
      const _TestState(value: 1, progress: 0),
    );
    var builds = 0;
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableSelector<_TestState, int>(
          valueListenable: notifier,
          selector: (state) => state.value,
          builder: (context, value, child) {
            builds++;
            return Text('$value');
          },
        ),
      ),
    );
    expect(builds, 1);

    notifier.value = const _TestState(value: 1, progress: 1);
    await tester.pump();
    expect(builds, 1);

    notifier.value = const _TestState(value: 2, progress: 1);
    await tester.pump();
    expect(builds, 2);
    expect(find.text('2'), findsOneWidget);
  });
}

class _TestState {
  const _TestState({required this.value, required this.progress});

  final int value;
  final int progress;
}
