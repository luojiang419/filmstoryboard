import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/features/storyboard/presentation/widgets/image_generation_model_selector.dart';

void main() {
  testWidgets('服务商和模型系列抽屉均保持同级单开', (tester) async {
    tester.view
      ..physicalSize = const Size(900, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    var selected = 'nano-banana-fast';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Center(
                child: SizedBox(
                  width: 420,
                  child: ImageGenerationModelSelector(
                    key: const ValueKey('test-model-selector'),
                    value: selected,
                    onChanged: (value) => setState(() => selected = value),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-model-selector')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('image-model-family-nano-banana')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-model-option-nano-banana-fast')),
      findsOneWidget,
    );

    final apiMartProvider = find.byKey(
      const ValueKey('image-model-provider-apimart'),
    );
    await tester.scrollUntilVisible(
      apiMartProvider,
      320,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(apiMartProvider);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('image-model-family-nano-banana')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('image-model-family-apimart-nano-banana')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('image-model-family-apimart-nano-banana')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey(
          'image-model-option-apimart:gemini-3.1-flash-image-preview',
        ),
      ),
      findsOneWidget,
    );

    final apiMartGptFamily = find.byKey(
      const ValueKey('image-model-family-apimart-gpt-image'),
    );
    await tester.scrollUntilVisible(
      apiMartGptFamily,
      280,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(apiMartGptFamily);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey(
          'image-model-option-apimart:gemini-3.1-flash-image-preview',
        ),
      ),
      findsNothing,
    );
    final apiMartGpt2 = find.byKey(
      const ValueKey('image-model-option-apimart:gpt-image-2'),
    );
    expect(apiMartGpt2, findsOneWidget);

    await tester.ensureVisible(apiMartGpt2);
    await tester.tap(apiMartGpt2);
    await tester.pumpAndSettle();
    expect(selected, 'apimart:gpt-image-2');
    expect(find.text('选择图片生成模型'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('test-model-selector')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('image-model-family-apimart-gpt-image')),
      findsOneWidget,
    );
    final grsaiProvider = find.byKey(
      const ValueKey('image-model-provider-grsai'),
    );
    await tester.scrollUntilVisible(
      grsaiProvider,
      -260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, 260));
    await tester.pumpAndSettle();
    await tester.tap(grsaiProvider);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('image-model-family-apimart-gpt-image')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('image-model-family-gpt-image')),
      findsOneWidget,
    );
  });

  testWidgets('图片修改模式隐藏不支持参考图的模型系列', (tester) async {
    tester.view
      ..physicalSize = const Size(900, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageGenerationModelSelector(
            key: const ValueKey('reference-model-selector'),
            value: 'nano-banana-fast',
            requireReferenceSupport: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('reference-model-selector')));
    await tester.pumpAndSettle();
    final apiMartProvider = find.byKey(
      const ValueKey('image-model-provider-apimart'),
    );
    await tester.scrollUntilVisible(
      apiMartProvider,
      320,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(apiMartProvider);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('image-model-family-apimart-imagen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('image-model-family-apimart-z-image')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('image-model-family-apimart-wan-image')),
      findsOneWidget,
    );
  });
}
