import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/storyboard/presentation/storyboard_page.dart';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  testWidgets('故事板描述输入停止后仅提交一次且失焦立即提交', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDatabase database;
    late final File imageFile;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('caption_performance_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      imageFile = File('${root.path}${Platform.pathSeparator}frame.png');
      await imageFile.writeAsBytes(base64Decode(_onePixelPng));
    });

    final controller = StoryboardController(database: database);
    controller.setAssetsUsed([
      StoryboardCutAsset(
        id: 'caption-asset',
        imageId: 'caption-image',
        sourceName: 'frame.png',
        path: imageFile.path,
        indexNo: 1,
      ),
    ], true);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storyboardControllerProvider.overrideWithValue(controller)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var notificationCount = 0;
    controller.addListener(() => notificationCount++);
    final originalSnapshot = database.getSetting('storyboardWorkspaceSnapshot');
    final captionField = find.byType(TextFormField);

    await tester.enterText(captionField, 'a');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(captionField, 'ab');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(captionField, 'abc');
    await tester.pump(const Duration(milliseconds: 349));

    expect(controller.value.selectedBoard!.items.single.caption, isEmpty);
    expect(notificationCount, 0);
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      originalSnapshot,
    );

    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value.selectedBoard!.items.single.caption, 'abc');
    expect(notificationCount, 1);
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      originalSnapshot,
    );
    controller.flushWorkspaceSnapshot();
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      isNot(originalSnapshot),
    );

    notificationCount = 0;
    await tester.enterText(captionField, '最终描述');
    controller.flushWorkspaceSnapshot();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(controller.value.selectedBoard!.items.single.caption, '最终描述');
    expect(notificationCount, 1);
    await tester.pump(const Duration(milliseconds: 100));

    notificationCount = 0;
    final snapshotBeforeSlider = database.getSetting(
      'storyboardWorkspaceSnapshot',
    );
    controller
      ..setGap(20)
      ..setGap(22)
      ..setGap(24);

    expect(controller.value.selectedBoard!.gap, 24);
    expect(notificationCount, 3, reason: '滑块预览仍应实时刷新画布');
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      snapshotBeforeSlider,
    );

    await tester.pump(const Duration(milliseconds: 299));
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      snapshotBeforeSlider,
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      database.getSetting('storyboardWorkspaceSnapshot'),
      isNot(snapshotBeforeSlider),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
