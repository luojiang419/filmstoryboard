import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storyboard_grid_app/app/app_theme.dart';
import 'package:storyboard_grid_app/core/database/app_database.dart';
import 'package:storyboard_grid_app/core/providers/app_providers.dart';
import 'package:storyboard_grid_app/core/services/app_directories.dart';
import 'package:storyboard_grid_app/features/grid_cut/application/grid_cut_controller.dart';
import 'package:storyboard_grid_app/features/grid_cut/data/grid_crop_service.dart';
import 'package:storyboard_grid_app/features/grid_cut/data/grid_detection_service.dart';
import 'package:storyboard_grid_app/features/settings/application/settings_controller.dart';
import 'package:storyboard_grid_app/features/settings/data/settings_repository.dart';
import 'package:storyboard_grid_app/features/story_design/application/story_design_controller.dart';
import 'package:storyboard_grid_app/features/story_design/presentation/story_design_page.dart';
import 'package:storyboard_grid_app/features/storyboard/data/image_generation_service.dart';

void main() {
  testWidgets('设计分镜图左栏可拖拽且矮窗口仍显示生成按钮', (tester) async {
    tester.view
      ..physicalSize = const Size(900, 500)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    late final Directory root;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final GridCutController gridCutController;
    late final StoryDesignController storyDesignController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('story_design_page_');
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      gridCutController = GridCutController(
        directories: directories,
        database: database,
        detectionService: const GridDetectionService(),
        cropService: const GridCropService(),
      );
      storyDesignController = StoryDesignController(
        directories: directories,
        settingsController: settingsController,
        gridCutController: gridCutController,
      );
    });
    addTearDown(() async {
      storyDesignController.dispose();
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyDesignControllerProvider.overrideWithValue(
            storyDesignController,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryDesignPage()),
        ),
      ),
    );
    await tester.pump();

    final generateButton = find.text('生成图片');
    expect(generateButton, findsOneWidget);
    final referencePanelTitle = find.text('参考图');
    final promptField = find.byKey(const ValueKey('story-design-prompt-field'));
    expect(referencePanelTitle, findsOneWidget);
    expect(promptField, findsOneWidget);
    expect(
      tester.getTopLeft(referencePanelTitle).dy,
      lessThan(tester.getTopLeft(promptField).dy),
    );

    final parametersToggle = find.byKey(
      const ValueKey('story-design-parameters-toggle'),
    );
    final gridCountField = find.byKey(
      const ValueKey('story-design-grid-count-field'),
    );
    expect(parametersToggle, findsOneWidget);
    expect(find.text('1 张 · 无宫格'), findsOneWidget);
    expect(gridCountField, findsNothing);

    await tester.ensureVisible(parametersToggle);
    await tester.pump();
    await tester.tap(parametersToggle);
    await tester.pump();
    expect(gridCountField, findsOneWidget);
    final portraitGridSwitch = find.byKey(
      const ValueKey('story-design-portrait-grid-switch'),
    );
    expect(portraitGridSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(portraitGridSwitch).onChanged, isNull);
    final batchPosition = tester.getTopLeft(
      find.byKey(const ValueKey('story-design-batch-count-field')),
    );
    final gridPosition = tester.getTopLeft(gridCountField);
    expect(
      batchPosition.dy < gridPosition.dy ||
          (batchPosition.dy == gridPosition.dy &&
              batchPosition.dx < gridPosition.dx),
      isTrue,
    );

    await tester.ensureVisible(gridCountField);
    await tester.tap(gridCountField);
    await tester.pumpAndSettle();
    expect(find.text('无'), findsWidgets);
    for (final count in [4, 6, 9, 12, 16, 24]) {
      expect(find.text('$count 宫格'), findsWidgets);
    }
    await tester.tap(find.text('24 宫格').last);
    await tester.pumpAndSettle();
    expect(storyDesignController.value.gridCount, 24);
    expect(
      tester.widget<SwitchListTile>(portraitGridSwitch).onChanged,
      isNotNull,
    );
    await tester.tap(portraitGridSwitch);
    await tester.pump();
    expect(storyDesignController.value.portraitGrid, isTrue);
    expect(find.text('24 行 × 1 列，每行 1 个分镜'), findsOneWidget);

    await tester.tap(gridCountField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('无').last);
    await tester.pumpAndSettle();
    expect(storyDesignController.value.gridCount, 0);
    expect(storyDesignController.value.portraitGrid, isFalse);
    expect(tester.widget<SwitchListTile>(portraitGridSwitch).onChanged, isNull);
    expect(find.text('选择宫格数量后可用'), findsOneWidget);

    final pageRect = tester.getRect(find.byType(StoryDesignPage));
    final buttonRect = tester.getRect(generateButton);
    expect(buttonRect.bottom, lessThanOrEqualTo(pageRect.bottom));

    final resizeHandle = find.byTooltip('拖拽调整左侧面板宽度');
    expect(resizeHandle, findsOneWidget);
    final initialHandleCenter = tester.getCenter(resizeHandle);
    await tester.drag(resizeHandle, const Offset(120, 0));
    await tester.pump();
    final movedHandleCenter = tester.getCenter(resizeHandle);
    expect(movedHandleCenter.dx, greaterThan(initialHandleCenter.dx + 80));
    final savedWidth = double.parse(
      database.getSetting('storyDesignInputPanelWidth')!,
    );
    expect(savedWidth, greaterThan(430));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyDesignControllerProvider.overrideWithValue(
            storyDesignController,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryDesignPage()),
        ),
      ),
    );
    await tester.pump();

    final restoredHandleCenter = tester.getCenter(resizeHandle);
    expect(restoredHandleCenter.dx, greaterThan(initialHandleCenter.dx + 80));
  });

  testWidgets('生成按钮可连续点击并在右侧显示独立计时任务卡片', (tester) async {
    tester.view
      ..physicalSize = const Size(1200, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    late final Directory root;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final GridCutController gridCutController;
    late final StoryDesignController storyDesignController;
    final imageService = _BlockingStoryDesignImageService();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('story_design_concurrent_');
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(
        database,
        directories,
        imageGenerationDefaultsText:
            '4. `builtin-grsai-image`\nkey: test-image-key\n模型：nano-banana-fast',
      );
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      gridCutController = GridCutController(
        directories: directories,
        database: database,
        detectionService: const GridDetectionService(),
        cropService: const GridCropService(),
      );
      storyDesignController = StoryDesignController(
        directories: directories,
        settingsController: settingsController,
        gridCutController: gridCutController,
        imageGenerationService: imageService,
      )..setPrompt('下雪氛围');
    });
    addTearDown(() async {
      storyDesignController.dispose();
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyDesignControllerProvider.overrideWithValue(
            storyDesignController,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryDesignPage()),
        ),
      ),
    );
    await tester.pump();

    final generateButton = find.byKey(
      const ValueKey('story-design-generate-button'),
    );
    expect(tester.widget<FilledButton>(generateButton).onPressed, isNotNull);

    await tester.tap(generateButton);
    await tester.pump();
    await tester.tap(generateButton);
    await tester.pump();

    expect(imageService.callCount, 2);
    expect(storyDesignController.value.activeTaskCount, 2);
    expect(tester.widget<FilledButton>(generateButton).onPressed, isNotNull);
    final taskCards = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('story-design-task-') &&
          !key.value.startsWith('story-design-task-timer-');
    });
    expect(taskCards, findsNWidgets(2));
    expect(find.text('生成中'), findsNWidgets(2));

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    final timers = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('story-design-task-timer-');
    });
    expect(timers, findsNWidgets(2));
    expect(
      timers.evaluate().map((element) => (element.widget as Text).data),
      everyElement(isNot('00:00')),
    );
  });
}

class _BlockingStoryDesignImageService extends ImageGenerationService {
  final _requests = <ImageGenerationRequest>[];

  int get callCount => _requests.length;

  @override
  Future<ImageGenerationResult> generateTextToImage(
    ImageGenerationRequest request,
  ) {
    _requests.add(request);
    return Completer<ImageGenerationResult>().future;
  }

  @override
  void close() {}
}
