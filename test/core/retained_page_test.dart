import 'package:filmstoryboard/core/widgets/retained_page.dart';
import 'package:filmstoryboard/core/widgets/value_listenable_selector.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'hidden page skips layout and notifications, resumes latest state',
    (tester) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      var layouts = 0;
      var builds = 0;
      final page = PageValueListenableBuilder<int>(
        valueListenable: value,
        builder: (context, value, _) {
          builds++;
          return _LayoutProbe(
            onLayout: () => layouts++,
            child: Text('$value', textDirection: TextDirection.ltr),
          );
        },
      );
      Widget host(bool active, double width) => Center(
        child: SizedBox(
          width: width,
          height: 100,
          child: RetainedPage(active: active, child: page),
        ),
      );
      await tester.pumpWidget(host(true, 300));
      await tester.pumpWidget(host(false, 300));
      final hiddenBuilds = builds;
      final hiddenLayouts = layouts;
      await tester.pumpWidget(host(true, 300));
      await tester.pumpWidget(host(false, 300));
      expect(
        builds,
        hiddenBuilds,
        reason: 'Switching unchanged pages must reuse the built subtree.',
      );
      for (var index = 1; index <= 100; index++) {
        value.value = index;
      }
      await tester.pumpWidget(host(false, 500));
      expect(builds, hiddenBuilds);
      expect(layouts, hiddenLayouts);
      await tester.pumpWidget(host(true, 500));
      expect(find.text('100'), findsOneWidget);
      expect(layouts, greaterThan(hiddenLayouts));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden retained page excludes focus and semantics', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RetainedPage(
          active: false,
          child: Focus(
            focusNode: focus,
            child: Semantics(
              label: 'hidden-editor',
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.onLayout, required super.child});
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) => _Probe(onLayout);
}

class _Probe extends RenderProxyBox {
  _Probe(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}
