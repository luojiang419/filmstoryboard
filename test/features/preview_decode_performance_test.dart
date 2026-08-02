import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/core/widgets/fullscreen_zoom_gallery.dart';
import 'package:filmstoryboard/features/exporter/presentation/exporter_page.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/story_design/application/story_design_controller.dart';
import 'package:filmstoryboard/features/story_design/domain/story_design_models.dart';
import 'package:filmstoryboard/features/story_design/presentation/story_design_page.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  test('导出预览槽位映射只构建一次索引并保留首次槽位', () {
    final first = _item(id: 'first', slotIndex: 3);
    final duplicate = _item(id: 'duplicate', slotIndex: 3);
    final second = _item(id: 'second', slotIndex: 7);

    final itemsBySlot = buildExporterPreviewSlotItems([
      first,
      duplicate,
      second,
    ]);

    expect(itemsBySlot, hasLength(2));
    expect(itemsBySlot[3], same(first));
    expect(itemsBySlot[7], same(second));
  });

  test('设计结果路径由 Grid 统一生成且保持顺序', () {
    final results = [
      _result(id: 'first', path: 'first.png'),
      _result(id: 'second', path: 'second.png'),
    ];

    expect(buildStoryDesignResultPaths(results), ['first.png', 'second.png']);
  });

  testWidgets('导出页缩略图受限解码且范围选择、右键取消和内嵌预览正常', (tester) async {
    tester.view
      ..physicalSize = const Size(1200, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final fixture = await _createFixture(tester, 'export_preview_');
    final imageFile = await _writeImage(tester, fixture.root, 'board.png');
    final storyboardController = StoryboardController(
      database: fixture.database,
    );
    storyboardController.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset',
        imageId: 'image',
        sourceName: 'board.png',
        path: imageFile.path,
        indexNo: 1,
      ),
    ], true);
    storyboardController.addBoard();
    final boards = storyboardController.value.boards;
    addTearDown(() async {
      storyboardController.dispose();
      await fixture.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          settingsControllerProvider.overrideWithValue(
            fixture.settingsController,
          ),
          storyboardControllerProvider.overrideWithValue(storyboardController),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ExporterPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final thumbnailWidths = _resizeWidthsForPath(tester, imageFile.path);
    expect(thumbnailWidths, isNotEmpty);
    expect(thumbnailWidths.every((width) => width <= 192), isTrue);

    final firstBoard = find.byKey(ValueKey('export-board-${boards[0].id}'));
    final secondBoard = find.byKey(ValueKey('export-board-${boards[1].id}'));
    await tester.tap(firstBoard);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已选择 1 个故事板'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(secondBoard);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已选择 2 个故事板'), findsOneWidget);

    await tester.tap(secondBoard, buttons: kSecondaryMouseButton);
    await tester.pump();
    expect(find.text('已选择 1 个故事板'), findsOneWidget);

    await tester.tap(firstBoard);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(firstBoard);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('exporter-board-preview-${boards[0].id}')),
      findsOneWidget,
    );
    final previewWidths = _resizeWidthsForPath(tester, imageFile.path);
    expect(previewWidths.reduce((a, b) => a > b ? a : b), greaterThan(192));
  });

  testWidgets('浅色模式导出预览舞台背景使用浅色主题', (tester) async {
    tester.view
      ..physicalSize = const Size(1200, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final theme = AppTheme.light();
    final fixture = await _createFixture(tester, 'light_export_preview_');
    final storyboardController = StoryboardController(
      database: fixture.database,
    );
    final board = storyboardController.value.selectedBoard!;
    addTearDown(() async {
      storyboardController.dispose();
      await fixture.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          settingsControllerProvider.overrideWithValue(
            fixture.settingsController,
          ),
          storyboardControllerProvider.overrideWithValue(storyboardController),
        ],
        child: MaterialApp(
          theme: theme,
          home: const Scaffold(body: ExporterPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boardCard = find.byKey(ValueKey('export-board-${board.id}'));
    await tester.tap(boardCard);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(boardCard);
    await tester.pumpAndSettle();

    final stage = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('exporter-preview-stage')),
    );
    expect(stage.color, theme.colorScheme.surface);
    expect(stage.color, isNot(const Color(0xFF080C10)));
  });

  testWidgets('导出页双击进入竖屏预览并支持 Esc 和返回按钮', (tester) async {
    tester.view
      ..physicalSize = const Size(1200, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final fixture = await _createFixture(tester, 'portrait_export_preview_');
    final imageFile = await _writeImage(tester, fixture.root, 'portrait.png');
    final asset = StoryboardCutAsset(
      id: 'portrait-asset',
      imageId: 'portrait-image',
      sourceName: 'portrait.png',
      path: imageFile.path,
      indexNo: 1,
    );
    final items = [
      StoryboardItem(asset: asset, caption: '竖屏说明文本', slotIndex: 0),
    ];
    final board = StoryboardBoard(
      id: 'portrait-board',
      name: '竖屏画板',
      width: 1920,
      height: StoryboardBoard.heightForLayout(
        width: 1920,
        rows: 30,
        columns: 1,
        items: items,
        portraitMode: true,
      ),
      rows: 30,
      columns: 1,
      gap: 18,
      items: items,
      portraitMode: true,
    );
    final storyboardController = StoryboardController(
      database: fixture.database,
    );
    storyboardController.value = storyboardController.value.copyWith(
      assets: [asset],
      boards: [board],
      selectedBoardId: board.id,
    );
    addTearDown(() async {
      storyboardController.dispose();
      await fixture.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          settingsControllerProvider.overrideWithValue(
            fixture.settingsController,
          ),
          storyboardControllerProvider.overrideWithValue(storyboardController),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ExporterPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boardCard = find.byKey(ValueKey('export-board-${board.id}'));
    await tester.tap(boardCard);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(boardCard);
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('exporter-board-preview-${board.id}')),
      findsOneWidget,
    );
    expect(find.text('导出预览'), findsOneWidget);
    expect(find.text('竖屏说明文本'), findsOneWidget);
    expect(find.text('已选择 1 个故事板'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('exporter-board-browser')),
      findsOneWidget,
    );

    await tester.tap(boardCard);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(boardCard);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('exporter-preview-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('exporter-board-browser')),
      findsOneWidget,
    );
  });

  testWidgets('设计分镜缩略图受限解码且勾选、删除、全屏和右键正常', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final fixture = await _createFixture(tester, 'design_preview_');
    final firstFile = await _writeImage(tester, fixture.root, 'first.png');
    final secondFile = await _writeImage(tester, fixture.root, 'second.png');
    final gridCutController = GridCutController(
      directories: fixture.directories,
      database: fixture.database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    final storyDesignController = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: gridCutController,
    );
    storyDesignController.value = storyDesignController.value.copyWith(
      referenceImagePaths: [firstFile.path],
      results: [
        _result(id: 'first', path: firstFile.path),
        _result(id: 'second', path: secondFile.path),
      ],
    );
    addTearDown(() async {
      storyDesignController.dispose();
      gridCutController.dispose();
      await fixture.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(fixture.database),
          storyDesignControllerProvider.overrideWithValue(
            storyDesignController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryDesignPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstWidths = _resizeWidthsForPath(tester, firstFile.path);
    final secondWidths = _resizeWidthsForPath(tester, secondFile.path);
    expect(firstWidths, contains(128));
    expect(secondWidths, isNotEmpty);
    expect(secondWidths.every((width) => width < 1024), isTrue);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(storyDesignController.value.results.first.selected, isFalse);

    final secondImage = _imageForPath(secondFile.path).first;
    await tester.tap(secondImage);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(secondImage);
    await tester.pumpAndSettle();
    final gallery = tester.widget<FullscreenZoomGallery<String>>(
      find.byType(FullscreenZoomGallery<String>),
    );
    expect(gallery.items, [firstFile.path, secondFile.path]);
    final fullscreenWidths = _resizeWidthsForPath(tester, secondFile.path);
    expect(fullscreenWidths.reduce((a, b) => a > b ? a : b), greaterThan(512));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(
      _imageForPath(secondFile.path).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('打开目录'), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('移除结果').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(storyDesignController.value.results, hasLength(1));
  });
}

StoryboardItem _item({required String id, required int slotIndex}) {
  return StoryboardItem(
    asset: StoryboardCutAsset(
      id: id,
      imageId: id,
      sourceName: '$id.png',
      path: '$id.png',
      indexNo: slotIndex,
    ),
    caption: '',
    slotIndex: slotIndex,
  );
}

StoryDesignResult _result({required String id, required String path}) {
  return StoryDesignResult(
    id: id,
    path: path,
    remoteUrl: '',
    prompt: 'prompt',
    model: 'nano-banana-fast',
    aspectRatio: '1:1',
    imageSize: '1K',
    quality: 'auto',
    createdAt: DateTime(2026),
  );
}

Finder _imageForPath(String path) {
  return find.byWidgetPredicate((widget) {
    if (widget is! Image || widget.image is! ResizeImage) {
      return false;
    }
    final provider = widget.image as ResizeImage;
    return provider.imageProvider is FileImage &&
        (provider.imageProvider as FileImage).file.path == path;
  });
}

List<int> _resizeWidthsForPath(WidgetTester tester, String path) {
  return tester
      .widgetList<Image>(_imageForPath(path))
      .map((image) => (image.image as ResizeImage).width!)
      .toList();
}

Future<File> _writeImage(
  WidgetTester tester,
  Directory root,
  String name,
) async {
  late final File file;
  await tester.runAsync(() async {
    file = File('${root.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(base64Decode(_onePixelPng));
  });
  return file;
}

Future<_Fixture> _createFixture(WidgetTester tester, String prefix) async {
  late final Directory root;
  late final AppDirectories directories;
  late final AppDatabase database;
  late final SettingsController settingsController;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp(prefix);
    directories = await AppDirectories.create(executableDirectory: root);
    database = await AppDatabase.open(directories.databaseFile);
    final repository = SettingsRepository(database, directories);
    settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
  });
  return _Fixture(
    root: root,
    directories: directories,
    database: database,
    settingsController: settingsController,
  );
}

class _Fixture {
  const _Fixture({
    required this.root,
    required this.directories,
    required this.database,
    required this.settingsController,
  });

  final Directory root;
  final AppDirectories directories;
  final AppDatabase database;
  final SettingsController settingsController;

  Future<void> dispose() async {
    settingsController.dispose();
    database.dispose();
    await root.delete(recursive: true);
  }
}
