import 'package:filmstoryboard/app/window_fullscreen_controller.dart';
import 'package:filmstoryboard/app/window_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WindowTitleBar hides while the app is fullscreen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WindowFullscreenScope(
          isFullscreen: true,
          child: Scaffold(body: WindowTitleBar()),
        ),
      ),
    );

    expect(tester.getSize(find.byType(WindowTitleBar)).height, 0);
  });

  testWidgets('WindowFullscreenController tolerates missing window plugin', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: WindowFullscreenController(child: SizedBox())),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f11);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
