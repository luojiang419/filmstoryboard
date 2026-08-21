import 'dart:io';

import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_catalog.dart';
import 'package:filmstoryboard/features/replicate/presentation/line_art_color_style_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('色彩预设以三列缩略图卡片显示并提供卡片菜单', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LineArtColorStyleCardAction? action;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: LineArtColorStylePicker(
                presets: LineArtColorStyleCatalog.builtInPresets,
                selectedId: 'natural_cinema',
                projectRoot: Directory.current,
                availableWidth: 960,
                onSelected: (_) {},
                onCreate: () {},
                onAction: (_, selectedAction) => action = selectedAction,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(
      const ValueKey('line-art-color-style-card-natural_cinema'),
    );
    final second = find.byKey(
      const ValueKey('line-art-color-style-card-warm_analog'),
    );
    final third = find.byKey(
      const ValueKey('line-art-color-style-card-blue_gold_twilight'),
    );
    final fourth = find.byKey(
      const ValueKey('line-art-color-style-card-tungsten_night'),
    );
    expect(first, findsOneWidget);
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getTopLeft(second).dy, tester.getTopLeft(third).dy);
    expect(
      tester.getTopLeft(fourth).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );

    await tester.tap(
      find.byKey(const ValueKey('line-art-color-style-menu-natural_cinema')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看来源与许可'));
    await tester.pumpAndSettle();
    expect(action, LineArtColorStyleCardAction.viewSource);
  });

  testWidgets('自定义编辑器校验必填项与HEX色板并返回草稿', (tester) async {
    LineArtColorStylePresetDraft? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                saved = await showLineArtColorStylePresetEditor(context);
              },
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('line-art-color-style-editor-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('save-line-art-color-style-preset')),
    );
    await tester.pump();
    expect(find.text('名称和英文色彩提示词不能为空'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('color-style-editor-name')),
      '高级红毯',
    );
    await tester.enterText(
      find.byKey(const ValueKey('color-style-editor-prompt')),
      'Preserve authorized colors and apply a restrained red-carpet grade.',
    );
    await tester.enterText(
      find.byKey(const ValueKey('color-style-editor-swatches')),
      '#581426, #B97870, #DBC5AC',
    );
    await tester.tap(
      find.byKey(const ValueKey('save-line-art-color-style-preset')),
    );
    await tester.pumpAndSettle();

    expect(saved?.name, '高级红毯');
    expect(saved?.swatches, ['#581426', '#B97870', '#DBC5AC']);
  });

  testWidgets('窄窗口把缩略图卡片降为单列且保持完整宽度', (tester) async {
    tester.view.physicalSize = const Size(430, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: LineArtColorStylePicker(
                presets: LineArtColorStyleCatalog.builtInPresets
                    .take(3)
                    .toList(),
                selectedId: 'natural_cinema',
                projectRoot: Directory.current,
                availableWidth: 390,
                onSelected: (_) {},
                onCreate: () {},
                onAction: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(
      const ValueKey('line-art-color-style-card-natural_cinema'),
    );
    final second = find.byKey(
      const ValueKey('line-art-color-style-card-warm_analog'),
    );
    expect(tester.getTopLeft(first).dx, tester.getTopLeft(second).dx);
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(tester.getSize(first).width, closeTo(390, 0.1));
  });
}
