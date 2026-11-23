import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/widgets/value_listenable_selector_builder.dart';

void main() {
  testWidgets('非选中状态连续变化不会重建目标子树', (tester) async {
    final state = ValueNotifier<({int selected, int unrelated})>((
      selected: 1,
      unrelated: 0,
    ));
    addTearDown(state.dispose);
    var buildCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home:
            ValueListenableSelectorBuilder<
              ({int selected, int unrelated}),
              int
            >(
              valueListenable: state,
              selector: (value) => value.selected,
              builder: (context, selected, _) {
                buildCount++;
                return Text('$selected', textDirection: TextDirection.ltr);
              },
            ),
      ),
    );

    expect(buildCount, 1);
    for (var index = 1; index <= 100; index++) {
      state.value = (selected: 1, unrelated: index);
    }
    await tester.pump();

    expect(buildCount, 1);
    expect(find.text('1'), findsOneWidget);

    state.value = (selected: 2, unrelated: 100);
    await tester.pump();

    expect(buildCount, 2);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('自定义相等判断只在业务切片变化时重建', (tester) async {
    final state = ValueNotifier<_PanelState>(
      const _PanelState(title: '画板', revision: 0),
    );
    addTearDown(state.dispose);
    var buildCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableSelectorBuilder<_PanelState, _PanelState>(
          valueListenable: state,
          selector: (value) => value,
          equals: (previous, next) => previous.title == next.title,
          builder: (context, selected, _) {
            buildCount++;
            return Text(selected.title);
          },
        ),
      ),
    );

    state.value = const _PanelState(title: '画板', revision: 1);
    await tester.pump();
    expect(buildCount, 1);

    state.value = const _PanelState(title: '资源', revision: 2);
    await tester.pump();
    expect(buildCount, 2);
    expect(find.text('资源'), findsOneWidget);
  });

  testWidgets('折叠后卸载内容且重新展开后交互可用', (tester) async {
    var expanded = true;
    var taps = 0;
    late StateSetter setHostState;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return AnimatedCollapsibleContent(
              expanded: expanded,
              duration: const Duration(milliseconds: 20),
              child: FilledButton(
                key: const ValueKey('heavy-panel-action'),
                onPressed: () => taps++,
                child: const Text('执行'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('heavy-panel-action')));
    expect(taps, 1);

    setHostState(() => expanded = false);
    await tester.pump();
    expect(find.byKey(const ValueKey('heavy-panel-action')), findsNothing);

    setHostState(() => expanded = true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('heavy-panel-action')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('heavy-panel-action')));
    expect(taps, 2);
  });
}

class _PanelState {
  const _PanelState({required this.title, required this.revision});

  final String title;
  final int revision;
}
