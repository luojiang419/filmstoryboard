import 'package:filmstoryboard/core/widgets/collapsible_panel_shortcut_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ctrl+B collapses all expanded panels and expands mixed panels', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _ShortcutHarness()));

    expect(find.text('left:expanded'), findsOneWidget);
    expect(find.text('right:expanded'), findsOneWidget);

    await _pressControlB(tester);
    await tester.pump();

    expect(find.text('left:collapsed'), findsOneWidget);
    expect(find.text('right:collapsed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('toggle-left')));
    await tester.pump();
    expect(find.text('left:expanded'), findsOneWidget);
    expect(find.text('right:collapsed'), findsOneWidget);

    await _pressControlB(tester);
    await tester.pump();

    expect(find.text('left:expanded'), findsOneWidget);
    expect(find.text('right:expanded'), findsOneWidget);
  });

  testWidgets('Ctrl+B still works while a text field owns focus', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _ShortcutHarness()));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await _pressControlB(tester);
    await tester.pump();

    expect(find.text('left:collapsed'), findsOneWidget);
    expect(find.text('right:collapsed'), findsOneWidget);
  });
}

Future<void> _pressControlB(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

class _ShortcutHarness extends StatefulWidget {
  const _ShortcutHarness();

  @override
  State<_ShortcutHarness> createState() => _ShortcutHarnessState();
}

class _ShortcutHarnessState extends State<_ShortcutHarness> {
  var _leftExpanded = true;
  var _rightExpanded = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CollapsiblePanelShortcutScope(
        child: Column(
          children: [
            const TextField(),
            CollapsiblePanelRegistration(
              expanded: _leftExpanded,
              onExpandedChanged: (expanded) =>
                  setState(() => _leftExpanded = expanded),
              child: Text(_leftExpanded ? 'left:expanded' : 'left:collapsed'),
            ),
            CollapsiblePanelRegistration(
              expanded: _rightExpanded,
              onExpandedChanged: (expanded) =>
                  setState(() => _rightExpanded = expanded),
              child: Text(
                _rightExpanded ? 'right:expanded' : 'right:collapsed',
              ),
            ),
            TextButton(
              key: const ValueKey('toggle-left'),
              onPressed: () => setState(() => _leftExpanded = !_leftExpanded),
              child: const Text('toggle left'),
            ),
          ],
        ),
      ),
    );
  }
}
