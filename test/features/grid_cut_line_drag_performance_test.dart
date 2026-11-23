import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/grid_cut/presentation/grid_cut_page.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';

void main() {
  testWidgets('裁切线拖动释放后提交且右键可直接删除', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final File imageFile;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('grid_line_drag_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      imageFile = File('${root.path}${Platform.pathSeparator}frame.png');
      final source = img.Image(width: 120, height: 80);
      img.fill(source, color: img.ColorRgb8(120, 160, 200));
      await imageFile.writeAsBytes(img.encodePng(source));
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final controller = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    await tester.runAsync(() => controller.importPaths([imageFile.path]));
    controller.setEvenGrid(1, 2);
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          gridCutControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SizedBox(width: 900, height: 640, child: GridCutPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var notificationCount = 0;
    controller.addListener(() => notificationCount++);
    final originalLayout = controller.value.selectedImage!.layout;
    final originalSnapshot = database.getSetting('gridCutWorkspaceSnapshot');
    final canvas = find.byKey(const ValueKey('grid-cut-crop-canvas'));
    final canvasRect = tester.getRect(canvas);
    final linePosition = Offset(canvasRect.center.dx, canvasRect.center.dy);

    final gesture = await tester.startGesture(
      linePosition,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();

    expect(controller.value.selectedImage!.layout, same(originalLayout));
    expect(notificationCount, 0);
    expect(database.getSetting('gridCutWorkspaceSnapshot'), originalSnapshot);

    await gesture.up();
    expect(notificationCount, 1);
    expect(controller.value.selectedImage!.layout, isNot(same(originalLayout)));
    expect(database.getSetting('gridCutWorkspaceSnapshot'), originalSnapshot);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      database.getSetting('gridCutWorkspaceSnapshot'),
      isNot(originalSnapshot),
    );

    await tester.pumpAndSettle();
    notificationCount = 0;
    final committedLayout = controller.value.selectedImage!.layout;
    final committedSnapshot = database.getSetting('gridCutWorkspaceSnapshot');
    final committedLinePosition = Offset(
      canvasRect.left +
          canvasRect.width *
              committedLayout.xLines[1] /
              committedLayout.imageWidth,
      canvasRect.center.dy,
    );
    final cancelledGesture = await tester.startGesture(
      committedLinePosition,
      kind: PointerDeviceKind.mouse,
    );
    await cancelledGesture.moveBy(const Offset(-16, 0));
    await tester.pump();
    await cancelledGesture.cancel();
    await tester.pump();

    expect(notificationCount, 0);
    expect(controller.value.selectedImage!.layout, same(committedLayout));
    expect(database.getSetting('gridCutWorkspaceSnapshot'), committedSnapshot);

    await tester.tapAt(committedLinePosition, buttons: kSecondaryMouseButton);
    await tester.pump();

    final removedLayout = controller.value.selectedImage!.layout;
    expect(removedLayout.xLines, [0, removedLayout.imageWidth]);
    expect(removedLayout.columns, 1);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
