import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:storyboard_grid_app/app/app_theme.dart';
import 'package:storyboard_grid_app/app/window_title_bar.dart';
import 'package:storyboard_grid_app/core/database/app_database.dart';
import 'package:storyboard_grid_app/core/providers/app_providers.dart';
import 'package:storyboard_grid_app/core/services/app_directories.dart';
import 'package:storyboard_grid_app/core/services/file_explorer_service.dart';
import 'package:storyboard_grid_app/features/exporter/data/storyboard_export_service.dart';
import 'package:storyboard_grid_app/features/exporter/presentation/exporter_page.dart';
import 'package:storyboard_grid_app/features/grid_cut/application/grid_cut_controller.dart';
import 'package:storyboard_grid_app/features/grid_cut/data/grid_crop_service.dart';
import 'package:storyboard_grid_app/features/grid_cut/data/grid_detection_service.dart';
import 'package:storyboard_grid_app/features/grid_cut/domain/grid_cut_models.dart';
import 'package:storyboard_grid_app/features/grid_cut/presentation/grid_cut_page.dart';
import 'package:storyboard_grid_app/features/settings/application/settings_controller.dart';
import 'package:storyboard_grid_app/features/settings/data/settings_repository.dart';
import 'package:storyboard_grid_app/features/settings/presentation/settings_page.dart';
import 'package:storyboard_grid_app/features/storyboard/application/storyboard_controller.dart';
import 'package:storyboard_grid_app/features/storyboard/data/image_generation_service.dart';
import 'package:storyboard_grid_app/features/storyboard/domain/storyboard_canvas_style.dart';
import 'package:storyboard_grid_app/features/storyboard/domain/storyboard_models.dart';
import 'package:storyboard_grid_app/features/storyboard/presentation/storyboard_page.dart';

void main() {
  testWidgets('标题栏窗口按钮固定在右侧', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: SizedBox(width: 800, child: WindowTitleBar()),
        ),
      ),
    );

    final titleBarRect = tester.getRect(find.byType(WindowTitleBar));
    final closeButtonRect = tester.getRect(find.byTooltip('关闭'));
    expect(closeButtonRect.right, titleBarRect.right);
  });

  testWidgets('故事板拼图页面可以渲染', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
    });
    final controller = StoryboardController(database: database);
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
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );

    expect(find.text('裁切资源'), findsOneWidget);
    expect(find.text('画板 1'), findsWidgets);
    expect(find.text('画板参数'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storyboard-board-title')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('展开画板参数'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('storyboard-title-alignment-segmented')),
      findsOneWidget,
    );
    expect(
      controller.value.selectedBoard!.titleAlignment,
      StoryboardTitleAlignment.center,
    );
    expect(find.text('高清重绘'), findsOneWidget);
    await tester.tap(find.text('高清重绘'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini 3 Pro Image'), findsOneWidget);
    expect(find.text('16:9'), findsOneWidget);
    expect(find.text('2K'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storyboard-hd-redraw-button')),
      findsOneWidget,
    );
    await tester.tap(find.text('居右'));
    await tester.pumpAndSettle();
    expect(
      controller.value.selectedBoard!.titleAlignment,
      StoryboardTitleAlignment.right,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('storyboard-board-bar'))).bottom,
      lessThan(
        tester
            .getRect(find.byKey(const ValueKey('storyboard-canvas-viewport')))
            .top,
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自定义文件夹按目录编组且图片删除按钮不会触发左键添加', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final _SpyStoryboardController controller;
    late final StoryboardFolder folder;
    late final StoryboardCutAsset folderAsset;
    final fileExplorerService = _RecordingFileExplorerService();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final source = File(
        '${root.path}${Platform.pathSeparator}folder-frame.png',
      );
      await source.writeAsBytes(base64Decode(_onePixelPng));
      controller = _SpyStoryboardController(
        database: database,
        directories: directories,
      );
      await controller.createFolder('修改');
      folder = controller.value.folders.single;
      await controller.copyPathsToFolder(
        paths: [source.path],
        folderId: folder.id,
      );
      folderAsset = controller.value.folders.single.assets.single;
    });
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
          home: Scaffold(
            body: StoryboardPage(fileExplorerService: fileExplorerService),
          ),
        ),
      ),
    );

    expect(find.byTooltip('展开全部'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('resource-expand-collapse-all')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('收纳全部'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('resource-expand-collapse-all')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开全部'), findsOneWidget);

    await tester.tap(find.text('修改'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('打开目录'), findsOneWidget);
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();
    expect(fileExplorerService.openedPath, folder.path);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('resource-group-mode-toggle')));
    await tester.pump();
    final groupCheckbox = find.byKey(
      ValueKey('resource-group-folder-checkbox-${folder.id}'),
    );
    expect(groupCheckbox, findsOneWidget);
    expect(
      find.byKey(ValueKey('resource-group-checkbox-${folderAsset.id}')),
      findsNothing,
    );
    expect(groupCheckbox.hitTestable(), findsOneWidget);
    final groupCheckboxRect = tester.getRect(groupCheckbox);
    expect(groupCheckboxRect.width, greaterThan(0));
    expect(groupCheckboxRect.height, greaterThan(0));
    final groupCheckboxWidget = tester.widget<Checkbox>(groupCheckbox);
    expect(groupCheckboxWidget.side, isNotNull);
    final groupCheckboxFill = groupCheckboxWidget.fillColor?.resolve(
      const <WidgetState>{},
    );
    expect(groupCheckboxFill, isNotNull);
    expect(groupCheckboxFill!.a, greaterThan(0));
    await tester.tap(groupCheckbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(groupCheckbox).value, isTrue);
    expect(controller.toggleCount, 0);
    expect(controller.value.selectedBoard!.items, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('resource-group-create-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('新建编组'), findsOneWidget);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('新编组'), findsOneWidget);
    expect(controller.value.resourceGroups.single.expanded, isTrue);
    expect(find.byTooltip('收纳全部'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('resource-expand-collapse-all')),
    );
    await tester.pumpAndSettle();
    expect(controller.value.resourceGroups.single.expanded, isFalse);
    expect(find.byTooltip('展开全部'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('resource-expand-collapse-all')),
    );
    await tester.pumpAndSettle();
    expect(controller.value.resourceGroups.single.expanded, isTrue);
    fileExplorerService.openedPath = null;
    await tester.tap(find.text('修改'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('打开目录'), findsOneWidget);
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();
    expect(fileExplorerService.openedPath, folder.path);

    await tester.tap(find.byKey(const ValueKey('resource-group-mode-toggle')));
    await tester.pump();
    expect(groupCheckbox, findsNothing);

    await tester.tap(
      find.byKey(ValueKey('delete-folder-asset-${folderAsset.id}')),
    );
    await tester.pump();
    await tester.runAsync(() async {
      while (File(folderAsset.path).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await controller.refreshAssets();
    });
    await tester.pumpAndSettle();

    expect(controller.toggleCount, 0);
    expect(File(folderAsset.path).existsSync(), isFalse);
    expect(controller.value.folders.single.assets, isEmpty);
    expect(controller.value.selectedBoard!.items, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('多个总图片目录复选框会将来源及全部子图片归入编组', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    late final StoryboardController controller;
    const imageId = 'source-image-1';
    const secondImageId = 'source-image-2';
    const assetIds = ['source-asset-1', 'source-asset-2', 'source-asset-3'];
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_source_group_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final now = DateTime.now().toIso8601String();
      final paths = <String>[];
      for (var index = 0; index < assetIds.length; index++) {
        final file = File(
          '${root.path}${Platform.pathSeparator}source-cut-${index + 1}.png',
        );
        await file.writeAsBytes(base64Decode(_onePixelPng));
        paths.add(file.path);
      }
      database
        ..upsertImportedImage(
          id: imageId,
          originalPath: '${root.path}${Platform.pathSeparator}source-image.png',
          originalName: '001',
          storedPath: '${root.path}${Platform.pathSeparator}source-image.png',
          width: 100,
          height: 100,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'source-task-1',
          imageId: imageId,
          status: 'exported',
          rows: 1,
          columns: 2,
          confidence: 1,
        );
      for (var index = 0; index < 2; index++) {
        database.insertCutResult(
          id: assetIds[index],
          taskId: 'source-task-1',
          imageId: imageId,
          indexNo: index + 1,
          path: paths[index],
          x: index * 50,
          y: 0,
          width: 50,
          height: 100,
          selected: true,
        );
      }
      database
        ..upsertImportedImage(
          id: secondImageId,
          originalPath:
              '${root.path}${Platform.pathSeparator}source-image-2.png',
          originalName: '002',
          storedPath: '${root.path}${Platform.pathSeparator}source-image-2.png',
          width: 100,
          height: 100,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'source-task-2',
          imageId: secondImageId,
          status: 'exported',
          rows: 1,
          columns: 1,
          confidence: 1,
        )
        ..insertCutResult(
          id: assetIds.last,
          taskId: 'source-task-2',
          imageId: secondImageId,
          indexNo: 1,
          path: paths.last,
          x: 0,
          y: 0,
          width: 100,
          height: 100,
          selected: true,
        );
      controller = StoryboardController(database: database);
      await controller.refreshAssets();
    });
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
    await tester.tap(find.text('001'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-group-mode-toggle')));
    await tester.pump();

    final sourceCheckbox = find.byKey(
      const ValueKey('resource-group-source-checkbox-source-image-1'),
    );
    final secondSourceCheckbox = find.byKey(
      const ValueKey('resource-group-source-checkbox-source-image-2'),
    );
    expect(sourceCheckbox, findsOneWidget);
    expect(secondSourceCheckbox, findsOneWidget);
    for (final assetId in assetIds) {
      expect(
        find.byKey(ValueKey('resource-group-checkbox-$assetId')),
        findsNothing,
      );
    }
    await tester.tap(sourceCheckbox);
    await tester.tap(secondSourceCheckbox);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('resource-group-create-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '总图组');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final group = controller.value.resourceGroups.single;
    expect(group.name, '总图组');
    expect(group.sourceImageIds, [imageId, secondImageId]);
    expect(group.assetIds, isEmpty);
    for (final assetId in assetIds) {
      expect(find.byKey(ValueKey('asset-thumb-$assetId')), findsOneWidget);
    }

    final nestedSourceHeader = find.byKey(
      ValueKey(
        'resource-node-draggable-${StoryboardResourceNodeRef.source(imageId).key}',
      ),
    );
    expect(nestedSourceHeader, findsOneWidget);
    if (find
        .byKey(ValueKey('asset-thumb-${assetIds.first}'))
        .hitTestable()
        .evaluate()
        .isNotEmpty) {
      await tester.tap(nestedSourceHeader);
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(ValueKey('asset-thumb-${assetIds.first}')).hitTestable(),
      findsNothing,
    );
    await tester.tap(nestedSourceHeader);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('asset-thumb-${assetIds.first}')).hitTestable(),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切资源文件夹可拖入编组并按层级动态编号和右键重命名', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final StoryboardController controller;
    late final StoryboardFolder firstFolder;
    late final StoryboardFolder secondFolder;
    late final StoryboardResourceGroup group;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('resource_tree_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      controller = StoryboardController(
        database: database,
        directories: directories,
      );
      await controller.createFolder('文件夹一');
      await controller.createFolder('文件夹二');
      firstFolder = controller.value.folders.firstWhere(
        (folder) => folder.name == '文件夹一',
      );
      secondFolder = controller.value.folders.firstWhere(
        (folder) => folder.name == '文件夹二',
      );
      await controller.createResourceGroup(
        name: '父编组',
        folderIds: [firstFolder.id],
      );
      group = controller.value.resourceGroups.single;
    });
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

    expect(find.byKey(const ValueKey('resource-sequence-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('resource-sequence-2')), findsOneWidget);

    final source = find.byKey(
      ValueKey(
        'resource-node-draggable-${StoryboardResourceNodeRef.folder(secondFolder.id).key}',
      ),
    );
    final target = find.byKey(
      ValueKey(
        'resource-node-drop-${StoryboardResourceNodeRef.group(group.id).key}',
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(source));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final movedGroup = controller.value.resourceGroups.single;
    expect(
      movedGroup.folderIds,
      containsAll([firstFolder.id, secondFolder.id]),
    );
    expect(controller.value.resourceRootOrder, [
      StoryboardResourceNodeRef.group(group.id).key,
    ]);
    expect(find.byKey(const ValueKey('resource-sequence-2')), findsNothing);
    expect(find.byKey(const ValueKey('resource-sequence-1.2')), findsOneWidget);

    await tester.tap(find.text('父编组'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '镜头资料');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.value.resourceGroups.single.name, '镜头资料');
    expect(find.text('镜头资料'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切资源正倒序与文件夹置顶会持久化且置顶不受排序影响', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final StoryboardController controller;
    late final StoryboardFolder firstFolder;
    late final StoryboardFolder secondFolder;
    late final StoryboardFolder thirdFolder;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('resource_order_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      controller = StoryboardController(
        database: database,
        directories: directories,
      );
      await controller.createFolder('顺序一');
      await controller.createFolder('顺序二');
      await controller.createFolder('顺序三');
      firstFolder = controller.value.folders.firstWhere(
        (folder) => folder.name == '顺序一',
      );
      secondFolder = controller.value.folders.firstWhere(
        (folder) => folder.name == '顺序二',
      );
      thirdFolder = controller.value.folders.firstWhere(
        (folder) => folder.name == '顺序三',
      );
    });
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    Widget buildPage() {
      return ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      );
    }

    Finder folderNode(StoryboardFolder folder) => find.byKey(
      ValueKey(
        'resource-node-draggable-${StoryboardResourceNodeRef.folder(folder.id).key}',
      ),
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(folderNode(firstFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(secondFolder)).dy),
    );
    expect(
      tester.getTopLeft(folderNode(secondFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(thirdFolder)).dy),
    );

    await tester.tap(
      find.byKey(
        ValueKey(
          'resource-pin-${StoryboardResourceNodeRef.folder(secondFolder.id).key}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(folderNode(secondFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(firstFolder)).dy),
    );

    await tester.tap(
      find.byKey(const ValueKey('resource-display-order-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(
      tester.getTopLeft(folderNode(secondFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(thirdFolder)).dy),
    );
    expect(
      tester.getTopLeft(folderNode(thirdFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(firstFolder)).dy),
    );

    final saved =
        jsonDecode(database.getSetting('storyboardAssetSidebarUiState')!)
            as Map<String, dynamic>;
    expect(saved['assetOrderAscending'], isFalse);
    expect(
      saved['pinnedResourceNodeKeys'],
      contains(StoryboardResourceNodeRef.folder(secondFolder.id).key),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(
      tester.getTopLeft(folderNode(secondFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(thirdFolder)).dy),
    );
    expect(
      tester.getTopLeft(folderNode(thirdFolder)).dy,
      lessThan(tester.getTopLeft(folderNode(firstFolder)).dy),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板拼图页面浅色模式画布使用浅色动态背景', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });
    final controller = StoryboardController(database: database);
    final theme = AppTheme.light();
    final canvasColors = StoryboardCanvasStyle.fromColorScheme(
      theme.colorScheme,
    );
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
          theme: theme,
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );

    final canvasContainers = tester.widgetList<Container>(
      find.byType(Container),
    );
    final hasLightCanvas = canvasContainers.any((widget) {
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.color == canvasColors.background;
    });
    final hasLegacyDarkCanvas = canvasContainers.any((widget) {
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.color == StoryboardCanvasStyle.background;
    });

    expect(hasLightCanvas, isTrue);
    expect(hasLegacyDarkCanvas, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('画板栏关闭按钮只关闭页签并保留画板', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });
    final controller = StoryboardController(database: database);
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

    final boardId = controller.value.selectedBoard!.id;
    expect(find.byKey(const ValueKey('open-board-manager')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('close-board-$boardId')));
    await tester.pump();

    expect(controller.value.boards, hasLength(1));
    expect(controller.value.openBoardIds, isEmpty);
    expect(controller.value.selectedBoard, isNull);
    expect(find.text('当前没有打开的画板'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板键盘快捷键支持撤销恢复、循环切换和关闭当前画板', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_shortcuts_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });
    final controller = StoryboardController(database: database)..addBoard();
    final firstBoardId = controller.value.openBoardIds.first;
    final secondBoardId = controller.value.selectedBoardId!;
    controller.setGrid(2, 2);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storyboardControllerProvider.overrideWithValue(controller)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pump();

    await _sendControlShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(controller.value.selectedBoard!.rows, 3);
    expect(controller.value.selectedBoard!.columns, 3);

    await _sendControlShortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(controller.value.selectedBoard!.rows, 2);
    expect(controller.value.selectedBoard!.columns, 2);

    await _sendControlShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(controller.value.selectedBoard!.rows, 3);
    await _sendControlShortcut(tester, LogicalKeyboardKey.keyY);
    expect(controller.value.selectedBoard!.rows, 2);

    await _sendControlShortcut(tester, LogicalKeyboardKey.tab);
    expect(controller.value.selectedBoardId, firstBoardId);

    await _sendControlShortcut(tester, LogicalKeyboardKey.keyW);
    expect(controller.value.boards, hasLength(2));
    expect(controller.value.openBoardIds, [secondBoardId]);
    expect(controller.value.selectedBoardId, secondBoardId);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('左侧裁切资源真实拖入格子后可通过按钮撤销和恢复', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    late final StoryboardController controller;
    const imageId = 'drag-source-image';
    const assetId = 'drag-source-asset';
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_drag_undo_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final image = File(
        '${root.path}${Platform.pathSeparator}drag-source.png',
      );
      await image.writeAsBytes(base64Decode(_onePixelPng));
      final now = DateTime.now().toIso8601String();
      database
        ..upsertImportedImage(
          id: imageId,
          originalPath: image.path,
          originalName: '拖拽测试图',
          storedPath: image.path,
          width: 1,
          height: 1,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'drag-source-task',
          imageId: imageId,
          status: 'exported',
          rows: 1,
          columns: 1,
          confidence: 1,
        )
        ..insertCutResult(
          id: assetId,
          taskId: 'drag-source-task',
          imageId: imageId,
          indexNo: 1,
          path: image.path,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          selected: true,
        );
      controller = StoryboardController(database: database);
      await controller.refreshAssets();
    });
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
    await tester.tap(find.text('拖拽测试图'));
    await tester.pumpAndSettle();

    final source = find.byKey(const ValueKey('asset-thumb-drag-source-asset'));
    final target = find.byKey(const ValueKey('storyboard-empty-slot-0'));
    expect(source.hitTestable(), findsOneWidget);
    expect(target.hitTestable(), findsOneWidget);
    await tester.timedDragFrom(
      tester.getCenter(source),
      tester.getCenter(target) - tester.getCenter(source),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();

    expect(controller.value.selectedBoard!.itemAtSlot(0)?.asset.id, assetId);
    final undoButton = find.byKey(const ValueKey('storyboard-undo'));
    expect(tester.widget<IconButton>(undoButton).onPressed, isNotNull);
    await tester.tap(undoButton);
    await tester.pumpAndSettle();
    expect(controller.value.selectedBoard!.items, isEmpty);

    final redoButton = find.byKey(const ValueKey('storyboard-redo'));
    expect(tester.widget<IconButton>(redoButton).onPressed, isNotNull);
    await tester.tap(redoButton);
    await tester.pumpAndSettle();
    expect(controller.value.selectedBoard!.itemAtSlot(0)?.asset.id, assetId);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('画板管理支持搜索并双击重新打开关闭画板', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('board_manager_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });
    final controller = StoryboardController(database: database)..addBoard();
    final secondBoardId = controller.value.selectedBoard!.id;
    controller.closeBoard(secondBoardId);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storyboardControllerProvider.overrideWithValue(controller)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-board-manager')));
    await tester.pumpAndSettle();
    expect(find.text('画板管理'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('board-manager-search')),
      '画板 2',
    );
    await tester.pump();
    final card = find.byKey(ValueKey('board-manager-card-$secondBoardId'));
    expect(card, findsOneWidget);

    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(controller.value.openBoardIds, contains(secondBoardId));
    expect(controller.value.selectedBoardId, secondBoardId);
    expect(find.byKey(ValueKey('close-board-$secondBoardId')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板文本框会同步控制器回填描述', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    late final SettingsController settingsController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      final repository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
    });

    final imagePath = File(
      'assets${Platform.pathSeparator}branding${Platform.pathSeparator}app_icon_source.png',
    ).absolute.path;
    final controller = StoryboardController(database: database);
    controller.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: 'frame.png',
        path: imagePath,
        indexNo: 1,
      ),
    ], true);
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyboardControllerProvider.overrideWithValue(controller),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    controller.updateCaption(0, '视觉回填描述');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '短描述初始布局不应溢出');

    expect(find.byKey(const ValueKey('caption-sequence-1')), findsOneWidget);
    await settingsController.setStoryboardCaptionNumberEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('caption-sequence-1')), findsNothing);
    await settingsController.setStoryboardCaptionNumberEnabled(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('caption-sequence-1')), findsOneWidget);
    final storyboardImage = tester.widget<Image>(
      find.byKey(const ValueKey('storyboard-image-asset-1')),
    );
    expect(storyboardImage.alignment, Alignment.topCenter);
    final imageRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-image-asset-1')),
    );
    final captionRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-caption-0')),
    );
    final tileRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-asset-1')),
    );
    expect(
      imageRect.height,
      greaterThan(0),
      reason: 'image=$imageRect caption=$captionRect',
    );
    expect(imageRect.width / imageRect.height, greaterThan(0));
    final captionTopGap = captionRect.top - imageRect.bottom;
    final scaledTilePadding = imageRect.left - tileRect.left;
    final captionBottomGap =
        tileRect.bottom - scaledTilePadding - captionRect.bottom;
    expect(captionTopGap, greaterThanOrEqualTo(0));
    expect(
      (captionTopGap - captionBottomGap).abs(),
      lessThanOrEqualTo(1),
      reason: 'image=$imageRect tile=$tileRect caption=$captionRect',
    );
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '视觉回填描述');
    final shortCaptionHeight = tester
        .getSize(find.byType(TextFormField))
        .height;
    expect(shortCaptionHeight, greaterThan(0));
    final captionBox = tester.widget<SizedBox>(
      find.byKey(const ValueKey('storyboard-caption-0')),
    );
    expect(captionBox.height, isNotNull);

    final longCaption = List.filled(
      3,
      '阳光洒满街头，女模特背身伫立，手插牛仔短裤口袋，棕色单肩包随微风轻摆。',
    ).join('\n');
    controller.updateCaption(0, longCaption);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '长描述自适应布局不应溢出');

    final expandedEditable = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(expandedEditable.controller.text, longCaption);
    expect(expandedEditable.maxLines, isNull);
    final longCaptionHeight = tester.getSize(find.byType(TextFormField)).height;
    expect(longCaptionHeight, greaterThan(shortCaptionHeight));
    final boundedCaptionRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-caption-0')),
    );
    final boundedTileRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-asset-1')),
    );
    expect(
      boundedCaptionRect.bottom,
      lessThanOrEqualTo(boundedTileRect.bottom),
    );

    final viewport = find.byKey(const ValueKey('storyboard-canvas-viewport'));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(viewport),
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '滚轮缩放后布局不应溢出');
    await tester.tap(find.byTooltip('缩放比例'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10%'));
    await tester.pumpAndSettle();

    final scaledCaptionRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-caption-0')),
    );
    final scaledTileRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-asset-1')),
    );
    expect(scaledCaptionRect.bottom, lessThanOrEqualTo(scaledTileRect.bottom));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板卡片横向与纵向间隙一致', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });

    final imagePath = File(
      'assets${Platform.pathSeparator}branding${Platform.pathSeparator}app_icon_source.png',
    ).absolute.path;
    final controller = StoryboardController(database: database)..setGrid(2, 2);
    controller.setAssetsUsed([
      for (var index = 1; index <= 4; index++)
        StoryboardCutAsset(
          id: 'equal-gap-asset-$index',
          imageId: 'equal-gap-image-$index',
          sourceName: 'frame-$index.png',
          path: imagePath,
          indexNo: index,
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

    final firstRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-equal-gap-asset-1')),
    );
    final secondRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-equal-gap-asset-2')),
    );
    final thirdRect = tester.getRect(
      find.byKey(const ValueKey('storyboard-tile-content-equal-gap-asset-3')),
    );
    final horizontalGap = secondRect.left - firstRect.right;
    final verticalGap = thirdRect.top - firstRect.bottom;

    expect(horizontalGap, greaterThan(0));
    expect(verticalGap, closeTo(horizontalGap, 0.5));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板缩放可超过800%且指示器三秒后隐藏', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_zoom_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
    });
    final controller = StoryboardController(database: database);
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

    final viewport = find.byKey(const ValueKey('storyboard-canvas-viewport'));
    expect(find.byKey(const ValueKey('canvas-zoom-controls')), findsNothing);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(viewport),
        scrollDelta: const Offset(0, -240),
      ),
    );
    await tester.pump();

    final controls = find.byKey(const ValueKey('canvas-zoom-controls'));
    expect(controls, findsOneWidget);
    final viewportRect = tester.getRect(viewport);
    final controlsRect = tester.getRect(controls);
    expect(controlsRect.right, closeTo(viewportRect.right - 12, 0.5));
    expect(controlsRect.bottom, closeTo(viewportRect.bottom - 12, 0.5));

    await tester.tap(find.byTooltip('缩放比例'));
    await tester.pumpAndSettle();
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('300%'), findsOneWidget);
    expect(find.text('800%'), findsOneWidget);
    await tester.tap(find.text('800%'));
    await tester.pumpAndSettle();
    expect(find.text('800%'), findsOneWidget);
    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(find.text('1000%'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2900));
    expect(controls, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controls, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('左键点击图片区后显示悬浮菜单并可在移开后隐藏', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(
        database,
        directories,
        visionDefaultsText: 'url:127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
        imageGenerationDefaultsText:
            '4. `builtin-grsai-image`\nkey: test-image-key\n模型：nano-banana-fast',
      );
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      final image = File('${root.path}${Platform.pathSeparator}frame.png');
      await image.writeAsBytes(base64Decode(_onePixelPng));
      final invalidDrop = File(
        '${root.path}${Platform.pathSeparator}notes.txt',
      );
      await invalidDrop.writeAsString('not an image');
    });

    final imagePath = '${root.path}${Platform.pathSeparator}frame.png';
    final controller = StoryboardController(
      database: database,
      directories: directories,
      settingsController: settingsController,
    );
    controller.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: 'frame.png',
        path: imagePath,
        indexNo: 1,
      ),
    ], true);
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyboardControllerProvider.overrideWithValue(controller),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );

    expect(find.byTooltip('修改图片'), findsNothing);

    final imageFinder = find.byKey(const ValueKey('storyboard-image-asset-1'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(imageFinder));
    await tester.pump();

    await mouse.down(tester.getCenter(imageFinder));
    await mouse.up();
    await tester.pump();

    expect(find.byTooltip('修改图片'), findsOneWidget);
    expect(find.byTooltip('替换图片'), findsOneWidget);
    expect(find.byTooltip('打开图片路径'), findsOneWidget);

    await tester.tap(find.byTooltip('修改图片'));
    await tester.pumpAndSettle();

    expect(find.text('修改图片'), findsOneWidget);
    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('自动提示词'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await mouse.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byTooltip('修改图片'), findsNothing);

    final dropTargetFinder = find.byKey(
      const ValueKey('storyboard-replacement-drop-asset-1'),
    );
    var dropTarget = tester.widget<DropTarget>(dropTargetFinder);
    dropTarget.onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump(const Duration(milliseconds: 460));
    expect(
      find.byKey(const ValueKey('storyboard-replacement-glow-asset-1')),
      findsOneWidget,
    );

    dropTarget = tester.widget<DropTarget>(dropTargetFinder);
    dropTarget.onDragExited!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('storyboard-replacement-glow-asset-1')),
      findsNothing,
    );
    dropTarget = tester.widget<DropTarget>(dropTargetFinder);
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile('${root.path}${Platform.pathSeparator}notes.txt')],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();
    expect(find.text('请拖入 PNG、JPG、WEBP 或 BMP 图片'), findsOneWidget);
    expect(controller.value.selectedBoard!.itemAtSlot(0)!.asset.id, 'asset-1');

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('悬浮菜单可展开左栏并滚动定位到懒加载素材后突出显示', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    late final StoryboardController controller;
    const imageId = 'locate-source-image';
    const targetAssetId = 'locate-asset-24';
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_locate_asset_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final now = DateTime.now().toIso8601String();
      database
        ..upsertImportedImage(
          id: imageId,
          originalPath: '${root.path}${Platform.pathSeparator}source.png',
          originalName: '深层素材',
          storedPath: '${root.path}${Platform.pathSeparator}source.png',
          width: 100,
          height: 100,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'locate-source-task',
          imageId: imageId,
          status: 'exported',
          rows: 4,
          columns: 6,
          confidence: 1,
        );
      for (var index = 1; index <= 24; index++) {
        final file = File(
          '${root.path}${Platform.pathSeparator}locate-$index.png',
        );
        await file.writeAsBytes(base64Decode(_onePixelPng));
        database.insertCutResult(
          id: 'locate-asset-$index',
          taskId: 'locate-source-task',
          imageId: imageId,
          indexNo: index,
          path: file.path,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          selected: true,
        );
      }
      controller = StoryboardController(database: database);
      await controller.refreshAssets();
      controller.addOrRemoveAsset(
        controller.value.assets.firstWhere(
          (asset) => asset.id == targetAssetId,
        ),
      );
    });
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('asset-thumb-$targetAssetId')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('storyboard-image-$targetAssetId')),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('打开图片路径'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('asset-located-$targetAssetId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('asset-thumb-$targetAssetId')).hitTestable(),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('重启后定位画板图片会等待左侧资源恢复', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    late final StoryboardController controller;
    const imageId = 'restart-locate-source';
    const assetId = 'restart-locate-asset';
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'storyboard_restart_locate_asset_',
      );
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final image = File(
        '${Directory.current.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}branding${Platform.pathSeparator}app_icon_512.png',
      );
      expect(image.existsSync(), isTrue);
      final now = DateTime.now().toIso8601String();
      database
        ..upsertImportedImage(
          id: imageId,
          originalPath: image.path,
          originalName: '重启定位素材',
          storedPath: image.path,
          width: 1,
          height: 1,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'restart-locate-task',
          imageId: imageId,
          status: 'exported',
          rows: 1,
          columns: 1,
          confidence: 1,
        )
        ..insertCutResult(
          id: assetId,
          taskId: 'restart-locate-task',
          imageId: imageId,
          indexNo: 1,
          path: image.path,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          selected: true,
        );
      final firstController = StoryboardController(database: database);
      await firstController.refreshAssets();
      firstController.addOrRemoveAsset(firstController.value.assets.single);
      firstController.flushWorkspaceSnapshot();
      firstController.dispose();

      controller = StoryboardController(database: database);
      expect(controller.value.assets, isEmpty);
      expect(controller.value.selectedBoard!.items, hasLength(1));
    });
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('storyboard-image-$assetId')));
    await tester.pump();
    await tester.tap(find.byTooltip('打开图片路径'));
    await tester.runAsync(() async {
      for (
        var attempt = 0;
        attempt < 100 && controller.value.assets.isEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('asset-located-$assetId')),
      findsOneWidget,
    );
    expect(find.text('左侧栏中未找到该图片资源'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('替换图片从右键菜单取消使用后可撤回恢复', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final File replacementSource;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'storyboard_replace_remove_widget_',
      );
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      replacementSource = File(
        '${root.path}${Platform.pathSeparator}右键取消使用.png',
      );
      await replacementSource.writeAsBytes(
        img.encodePng(img.Image(width: 3, height: 2)),
      );
    });

    final controller = StoryboardController(
      database: database,
      directories: directories,
      settingsController: settingsController,
    );
    controller.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: '原图片.png',
        path: replacementSource.path,
        indexNo: 1,
      ),
    ], true);
    controller.updateCaption(0, '右键取消后恢复说明');
    controller.toggleItemFlipVertical(0);
    late final StoryboardItem replacement;
    await tester.runAsync(() async {
      final original = controller.value.selectedBoard!.itemAtSlot(0)!;
      expect(
        await controller.replaceItemImage(
          item: original,
          imagePath: replacementSource.path,
        ),
        isTrue,
      );
      replacement = controller.value.selectedBoard!.itemAtSlot(0)!;
      await replacementSource.delete();
    });
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyboardControllerProvider.overrideWithValue(controller),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('手动替换'));
    await tester.pumpAndSettle();
    final replacementThumb = find.byKey(
      ValueKey('asset-thumb-${replacement.asset.id}'),
    );
    expect(replacementThumb, findsOneWidget);
    await tester.tap(replacementThumb, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('取消使用'), findsOneWidget);

    await tester.tap(find.text('取消使用'));
    await tester.pumpAndSettle();
    expect(controller.value.selectedBoard!.items, isEmpty);
    expect(controller.value.message, '已取消使用图片，可撤回恢复（最多100步）');

    controller.undoSelectedBoard();
    await tester.pumpAndSettle();
    final restored = controller.value.selectedBoard!.itemAtSlot(0)!;
    expect(restored.asset.id, replacement.asset.id);
    expect(File(restored.asset.path).existsSync(), isTrue);
    expect(restored.caption, '右键取消后恢复说明');
    expect(restored.flipVertical, isTrue);

    controller.redoSelectedBoard();
    await tester.pumpAndSettle();
    expect(controller.value.selectedBoard!.items, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('点击生成会自动最小化并保留后台任务与面板参数', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
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
      final image = File('${root.path}${Platform.pathSeparator}frame.png');
      await image.writeAsBytes(base64Decode(_onePixelPng));
    });

    final imagePath = '${root.path}${Platform.pathSeparator}frame.png';
    final imageService = _BlockingWidgetImageGenerationService();
    final controller = StoryboardController(
      database: database,
      directories: directories,
      settingsController: settingsController,
      imageGenerationService: imageService,
    );
    controller.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-1',
        imageId: 'image-1',
        sourceName: 'frame.png',
        path: imagePath,
        indexNo: 1,
      ),
    ], true);
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
          storyboardControllerProvider.overrideWithValue(controller),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );

    final imageFinder = find.byKey(const ValueKey('storyboard-image-asset-1'));
    await tester.tap(imageFinder);
    await tester.pump();
    await tester.tap(find.byTooltip('修改图片'));
    await tester.pumpAndSettle();
    final promptField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '提示词',
    );
    await tester.enterText(promptField, '将背景改为沙滩');
    await tester.tap(find.text('生成'));
    await tester.pumpAndSettle();

    expect(imageService.started, isTrue);
    expect(find.text('修改图片'), findsNothing);
    expect(controller.value.isGeneratingImage, isTrue);
    final savedPreferences =
        jsonDecode(database.getSetting('storyboardImageEditPreferences')!)
            as Map<String, dynamic>;
    expect(savedPreferences['model'], 'nano-banana-fast');
    expect(savedPreferences['aspectRatio'], 'auto');
    expect(savedPreferences['imageSize'], '1K');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板图片未选中时首次拖拽首帧即跟手排序', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      for (var index = 1; index <= 2; index++) {
        final image = File(
          '${root.path}${Platform.pathSeparator}frame_$index.png',
        );
        await image.writeAsBytes(base64Decode(_onePixelPng));
      }
    });

    StoryboardCutAsset asset(int index) {
      return StoryboardCutAsset(
        id: 'asset-$index',
        imageId: 'image-$index',
        sourceName: 'frame_$index.png',
        path: '${root.path}${Platform.pathSeparator}frame_$index.png',
        indexNo: index,
      );
    }

    final controller = StoryboardController(database: database);
    controller.setAssetsUsed([asset(1), asset(2)], true);
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

    final firstItem = find.byKey(const ValueKey('storyboard-item-asset-1'));
    final secondItem = find.byKey(const ValueKey('storyboard-item-asset-2'));
    expect(firstItem, findsOneWidget);
    expect(secondItem, findsOneWidget);

    final dragStart = tester.getCenter(firstItem);
    final dragEnd = tester.getCenter(secondItem);
    final initialTopLeft = tester.getTopLeft(firstItem);
    final firstStep = Offset(
      (dragEnd.dx - dragStart.dx) * 0.25,
      (dragEnd.dy - dragStart.dy) * 0.25,
    );

    final gesture = await tester.startGesture(
      dragStart,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(firstStep);
    await tester.pump();

    expect(
      (tester.getTopLeft(firstItem) - initialTopLeft).distance,
      greaterThan(1),
    );

    await gesture.moveTo(dragEnd);
    await gesture.up();

    var items = controller.value.selectedBoard!.items;
    expect(items.first.asset.id, 'asset-1');
    expect(items.last.asset.id, 'asset-2');

    await tester.pump();
    await tester.pumpAndSettle();

    items = controller.value.selectedBoard!.items;
    expect(items.first.asset.id, 'asset-2');
    expect(items.last.asset.id, 'asset-1');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板图片选中后首次拖拽首帧即跟手排序', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      for (var index = 1; index <= 2; index++) {
        final image = File(
          '${root.path}${Platform.pathSeparator}frame_$index.png',
        );
        await image.writeAsBytes(base64Decode(_onePixelPng));
      }
    });

    StoryboardCutAsset asset(int index) {
      return StoryboardCutAsset(
        id: 'asset-$index',
        imageId: 'image-$index',
        sourceName: 'frame_$index.png',
        path: '${root.path}${Platform.pathSeparator}frame_$index.png',
        indexNo: index,
      );
    }

    final controller = StoryboardController(database: database);
    controller.setAssetsUsed([asset(1), asset(2)], true);
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

    final firstItem = find.byKey(const ValueKey('storyboard-item-asset-1'));
    final secondItem = find.byKey(const ValueKey('storyboard-item-asset-2'));
    expect(firstItem, findsOneWidget);
    expect(secondItem, findsOneWidget);

    await tester.tap(firstItem);
    await tester.pumpAndSettle();

    final dragStart = tester.getCenter(firstItem);
    final dragEnd = tester.getCenter(secondItem);
    final initialTopLeft = tester.getTopLeft(firstItem);
    final firstStep = Offset(
      (dragEnd.dx - dragStart.dx) * 0.25,
      (dragEnd.dy - dragStart.dy) * 0.25,
    );

    final gesture = await tester.startGesture(
      dragStart,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(firstStep);
    await tester.pump();

    expect(
      (tester.getTopLeft(firstItem) - initialTopLeft).distance,
      greaterThan(1),
    );

    await gesture.moveTo(dragEnd);
    await gesture.up();

    var items = controller.value.selectedBoard!.items;
    expect(items.first.asset.id, 'asset-1');
    expect(items.last.asset.id, 'asset-2');

    await tester.pump();
    await tester.pumpAndSettle();

    items = controller.value.selectedBoard!.items;
    expect(items.first.asset.id, 'asset-2');
    expect(items.last.asset.id, 'asset-1');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板图片中键拖动只平移画布不触发排序', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      for (var index = 1; index <= 2; index++) {
        final image = File(
          '${root.path}${Platform.pathSeparator}frame_$index.png',
        );
        await image.writeAsBytes(base64Decode(_onePixelPng));
      }
    });

    StoryboardCutAsset asset(int index) {
      return StoryboardCutAsset(
        id: 'asset-$index',
        imageId: 'image-$index',
        sourceName: 'frame_$index.png',
        path: '${root.path}${Platform.pathSeparator}frame_$index.png',
        indexNo: index,
      );
    }

    final controller = StoryboardController(database: database);
    controller.setAssetsUsed([asset(1), asset(2)], true);
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

    final firstItem = find.byKey(const ValueKey('storyboard-item-asset-1'));
    expect(firstItem, findsOneWidget);

    final dragStart = tester.getCenter(firstItem);
    final initialTopLeft = tester.getTopLeft(firstItem);
    final gesture = await tester.startGesture(
      dragStart,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await gesture.moveBy(const Offset(48, 32));
    await tester.pump();

    expect(
      (tester.getTopLeft(firstItem) - initialTopLeft).distance,
      greaterThan(1),
    );

    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();

    final items = controller.value.selectedBoard!.items;
    expect(items.first.asset.id, 'asset-1');
    expect(items.last.asset.id, 'asset-2');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板页面会渲染已保存的画板状态', (tester) async {
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final image = File('${root.path}${Platform.pathSeparator}frame.png');
      await image.writeAsBytes(base64Decode(_onePixelPng));
    });

    final imagePath = '${root.path}${Platform.pathSeparator}frame.png';
    final firstController = StoryboardController(database: database);
    firstController.setAssetsUsed([
      StoryboardCutAsset(
        id: 'asset-restore',
        imageId: 'image-restore',
        sourceName: 'frame.png',
        path: imagePath,
        indexNo: 1,
      ),
    ], true);
    firstController.updateCaption(0, '保存后的描述');
    firstController.dispose();

    final controller = StoryboardController(database: database);
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

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '保存后的描述');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板页面会恢复并写回界面状态', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      final repository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      database.setSetting(
        'storyboardPageUiState',
        jsonEncode({
          'assetSidebarWidth': 330,
          'inspectorExpanded': true,
          'inspectorExpandedSections': ['layout', 'spacing'],
        }),
      );
      database.setSetting(
        'storyboardAssetSidebarUiState',
        jsonEncode({'thumbSize': 360, 'showThumbSizeSlider': true}),
      );
    });
    final controller = StoryboardController(database: database);
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
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );

    expect(find.byTooltip('收起画板参数'), findsOneWidget);
    expect(find.text('自动重排序'), findsNothing);
    expect(find.text('导出画板图片'), findsOneWidget);
    expect(find.text('图片编号'), findsOneWidget);
    await tester.tap(find.text('图片编号').first);
    await tester.pumpAndSettle();
    expect(find.text('文本框编号'), findsOneWidget);
    final captionNumberSwitch = find.byKey(
      const ValueKey('storyboard-caption-number-switch'),
    );
    expect(captionNumberSwitch, findsOneWidget);
    expect(tester.widget<Switch>(captionNumberSwitch).value, isTrue);
    await tester.ensureVisible(captionNumberSwitch);
    await tester.pumpAndSettle();
    await tester.tap(captionNumberSwitch);
    await tester.pumpAndSettle();
    expect(settingsController.value.storyboardCaptionNumberEnabled, isFalse);
    await tester.drag(
      find.byKey(const ValueKey('storyboard-inspector-list')),
      const Offset(0, 96),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片编号').first);
    await tester.pumpAndSettle();
    expect(find.text('圆圈透明度'), findsNothing);
    expect(find.text('数字尺寸'), findsNothing);
    expect(find.text('应用宫格布局'), findsOneWidget);
    final portraitModeSwitch = find.byKey(
      const ValueKey('storyboard-portrait-mode-switch'),
    );
    expect(portraitModeSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(portraitModeSwitch).value, isFalse);
    await tester.ensureVisible(portraitModeSwitch);
    await tester.pumpAndSettle();
    await tester.tap(portraitModeSwitch);
    await tester.pumpAndSettle();
    expect(controller.value.selectedBoard!.portraitMode, isTrue);
    expect(controller.value.selectedBoard!.columns, 1);
    expect(find.text('每行只显示 1 张图，行数随图片自动调整'), findsOneWidget);
    expect(find.text('缩略图 360'), findsOneWidget);
    final thumbnailSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('asset-thumbnail-size-slider')),
    );
    expect(thumbnailSlider.value, 360);
    expect(thumbnailSlider.max, 360);
    final inspectorScrollable = find
        .descendant(
          of: find.byKey(const ValueKey('storyboard-inspector-list')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('间距与分割线'),
      240,
      scrollable: inspectorScrollable,
    );
    expect(find.text('间距与分割线'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('row-divider-enabled-switch')),
      findsOneWidget,
    );
    expect(find.text('实线'), findsOneWidget);
    expect(find.text('虚线'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('row-divider-opacity-slider')),
      180,
      scrollable: inspectorScrollable,
    );
    expect(
      find.byKey(const ValueKey('row-divider-opacity-slider')),
      findsOneWidget,
    );

    tester.state<ScrollableState>(inspectorScrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.drag(inspectorScrollable, const Offset(0, -120));
    await tester.pumpAndSettle();

    await tester.tap(find.text('多宫格布局'));
    await tester.pumpAndSettle();

    var saved =
        jsonDecode(database.getSetting('storyboardPageUiState')!)
            as Map<String, Object?>;
    expect(saved['inspectorExpandedSections'], isNot(contains('layout')));

    tester.state<ScrollableState>(inspectorScrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起画板参数'));
    await tester.pumpAndSettle();

    saved =
        jsonDecode(database.getSetting('storyboardPageUiState')!)
            as Map<String, Object?>;
    expect(saved['inspectorExpanded'], isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('故事板资源栏受限布局不会覆盖保存宽度', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('storyboard_widget_');
      database = await AppDatabase.open(
        File('${root.path}${Platform.pathSeparator}storyboard.sqlite'),
      );
      database.setSetting(
        'storyboardPageUiState',
        jsonEncode({'assetSidebarWidth': 680, 'inspectorExpanded': false}),
      );
    });
    final controller = StoryboardController(database: database);
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          storyboardControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: StoryboardPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sidebar = find.byKey(
      const ValueKey('storyboard-asset-sidebar-container'),
    );
    expect(tester.getSize(sidebar).width, 680);

    tester.view.physicalSize = const Size(720, 600);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, lessThan(680));

    final saved =
        jsonDecode(database.getSetting('storyboardPageUiState')!)
            as Map<String, Object?>;
    expect(saved['assetSidebarWidth'], 680);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切参数折叠状态会恢复并写回', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final File image;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('grid_cut_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      database.setSetting(
        'gridCutPageUiState',
        jsonEncode({
          'expandedInspectorSections': ['metrics'],
        }),
      );
      image = File('${root.path}${Platform.pathSeparator}frame.png');
      final source = img.Image(width: 20, height: 20);
      img.fill(source, color: img.ColorRgb8(120, 160, 200));
      await image.writeAsBytes(img.encodePng(source));
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final gridCutController = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    await tester.runAsync(() => gridCutController.importPaths([image.path]));
    gridCutController.toggleCell(0, selected: true);
    addTearDown(() async {
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          gridCutControllerProvider.overrideWithValue(gridCutController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: GridCutPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('识别信息'), findsOneWidget);

    await tester.tap(find.text('识别信息'));
    await tester.pumpAndSettle();

    final saved =
        jsonDecode(database.getSetting('gridCutPageUiState')!)
            as Map<String, Object?>;
    expect(saved['expandedInspectorSections'], isNot(contains('metrics')));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切页左右整栏折叠状态会恢复并写回', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('grid_cut_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      database.setSetting(
        'gridCutPageUiState',
        jsonEncode({
          'imageSidebarExpanded': false,
          'inspectorPanelExpanded': false,
        }),
      );
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final gridCutController = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    addTearDown(() async {
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          gridCutControllerProvider.overrideWithValue(gridCutController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SizedBox(width: 900, height: 620, child: GridCutPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('图片任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('裁切参数'));
    await tester.pumpAndSettle();

    final saved =
        jsonDecode(database.getSetting('gridCutPageUiState')!)
            as Map<String, Object?>;
    expect(saved['imageSidebarExpanded'], isTrue);
    expect(saved['inspectorPanelExpanded'], isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切操作按钮固定显示在裁切参数栏底部', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final File image;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('grid_cut_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      image = File('${root.path}${Platform.pathSeparator}frame.png');
      final source = img.Image(width: 60, height: 40);
      img.fill(source, color: img.ColorRgb8(120, 160, 200));
      await image.writeAsBytes(img.encodePng(source));
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final gridCutController = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    await tester.runAsync(() => gridCutController.importPaths([image.path]));
    addTearDown(() async {
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          gridCutControllerProvider.overrideWithValue(gridCutController),
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

    expect(find.text('批量自动裁切'), findsOneWidget);
    expect(find.text('裁切多宫格图片'), findsOneWidget);

    final inspectorRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-inspector-panel')),
    );
    final actionsRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-inspector-actions')),
    );
    final batchRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-action-export-all')),
    );
    final exportRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-action-export-selected')),
    );

    expect(actionsRect.left, greaterThanOrEqualTo(inspectorRect.left));
    expect(actionsRect.right, lessThanOrEqualTo(inspectorRect.right));
    expect(inspectorRect.bottom - actionsRect.bottom, lessThanOrEqualTo(18));
    expect((batchRect.left - exportRect.left).abs(), lessThanOrEqualTo(1));
    expect((batchRect.width - exportRect.width).abs(), lessThanOrEqualTo(1));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('裁切预览保留带数字标识的标尺且不再显示图片编号', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final File image;
    late final File secondImage;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('grid_cut_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      image = File('${root.path}${Platform.pathSeparator}frame.png');
      secondImage = File(
        '${root.path}${Platform.pathSeparator}frame-second.png',
      );
      final source = img.Image(width: 60, height: 40);
      img.fill(source, color: img.ColorRgb8(120, 160, 200));
      await image.writeAsBytes(img.encodePng(source));
      await secondImage.writeAsBytes(img.encodePng(source));
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final gridCutController = GridCutController(
      directories: directories,
      database: database,
      detectionService: const GridDetectionService(),
      cropService: const GridCropService(),
    );
    await tester.runAsync(
      () => gridCutController.importPaths([image.path, secondImage.path]),
    );
    addTearDown(() async {
      gridCutController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          gridCutControllerProvider.overrideWithValue(gridCutController),
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

    final previewStack = tester.widget<Stack>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Stack &&
                widget.children.any(_isCropCanvasPositioned) &&
                widget.children.where(_isAxisRulerPositioned).length == 2,
          )
          .first,
    );
    final canvasIndex = previewStack.children.indexWhere(
      _isCropCanvasPositioned,
    );
    final firstRulerIndex = previewStack.children.indexWhere(
      _isAxisRulerPositioned,
    );

    expect(canvasIndex, isNonNegative);
    expect(firstRulerIndex, greaterThan(canvasIndex));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_AxisRulerPainter',
      ),
      findsNWidgets(2),
    );
    expect(find.text('图片编号'), findsNothing);

    final cropViewportRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-canvas-viewport')),
    );
    final cropZoomRect = tester.getRect(
      find.byKey(const ValueKey('grid-cut-zoom-controls')),
    );
    expect(cropZoomRect.right, closeTo(cropViewportRect.right - 12, 0.5));
    expect(cropZoomRect.bottom, closeTo(cropViewportRect.bottom - 12, 0.5));

    await tester.tap(find.byTooltip('缩放比例'));
    await tester.pumpAndSettle();
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('1000%'), findsOneWidget);
    await tester.tap(find.text('10%'));
    await tester.pumpAndSettle();
    expect(find.text('10%'), findsOneWidget);
    await tester.tap(find.byTooltip('缩放比例'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('1000%'));
    await tester.tap(find.text('1000%'));
    await tester.pumpAndSettle();
    expect(find.text('1000%'), findsOneWidget);

    await tester.tap(find.byTooltip('添加竖向裁切线'));
    await tester.pump();
    final verticalRuler = find.byKey(const ValueKey('grid-cut-ruler-vertical'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(verticalRuler));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('grid-cut-ruler-guide-preview')),
      findsOneWidget,
    );

    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('grid-cut-canvas-viewport'))),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('grid-cut-ruler-guide-preview')),
      findsNothing,
    );
    await mouse.removePointer();

    final cellDecorations = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byWidgetPredicate(_isCellHitRegion),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .toList();
    expect(cellDecorations, isNotEmpty);
    for (final decoration in cellDecorations) {
      expect(decoration.color, Colors.transparent);
      expect(decoration.boxShadow, isNull);
    }

    gridCutController.setEvenGrid(2, 2);
    gridCutController.toggleCell(2, selected: true);
    await settingsController.setCutImageNumberEnabled(true);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_CellNumberBadge',
      ),
      findsNothing,
    );

    final firstImageId = gridCutController.value.images.first.id;
    final secondImageId = gridCutController.value.images.last.id;
    final selectedImageId = gridCutController.value.selectedImage!.id;
    await tester.tap(
      find.byKey(const ValueKey('image-task-group-mode-toggle')),
    );
    await tester.pump();
    final taskCheckbox = find.byKey(
      ValueKey('image-task-group-checkbox-$firstImageId'),
    );
    expect(taskCheckbox, findsOneWidget);
    expect(taskCheckbox.hitTestable(), findsOneWidget);
    final taskCheckboxRect = tester.getRect(taskCheckbox);
    expect(taskCheckboxRect.width, greaterThan(0));
    expect(taskCheckboxRect.height, greaterThan(0));
    final taskCheckboxWidget = tester.widget<Checkbox>(taskCheckbox);
    expect(taskCheckboxWidget.side, isNotNull);
    final taskCheckboxFill = taskCheckboxWidget.fillColor?.resolve(
      const <WidgetState>{},
    );
    expect(taskCheckboxFill, isNotNull);
    expect(taskCheckboxFill!.a, greaterThan(0));
    await tester.tap(taskCheckbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(taskCheckbox).value, isTrue);
    expect(gridCutController.value.selectedImage!.id, selectedImageId);
    await tester.tap(
      find.byKey(ValueKey('image-task-group-checkbox-$secondImageId')),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(ValueKey('image-task-tile-$firstImageId')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('编组'), findsNWidgets(2));
    await tester.tap(find.text('编组').last);
    await tester.pumpAndSettle();
    expect(find.text('编组图片任务'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '测试任务组');
    await tester.tap(find.text('编组').last);
    await tester.pumpAndSettle();
    expect(gridCutController.value.taskGroups, hasLength(1));
    expect(gridCutController.value.taskGroups.single.imageIds, [
      firstImageId,
      secondImageId,
    ]);
    expect(find.byKey(const ValueKey('task-sequence-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-sequence-1.1')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-sequence-1.2')), findsOneWidget);

    final secondTaskDrag = find.byKey(
      ValueKey(
        'task-node-draggable-${GridCutTaskNodeRef.image(secondImageId).key}',
      ),
    );
    final firstTaskDrop = find.byKey(
      ValueKey('task-node-drop-${GridCutTaskNodeRef.image(firstImageId).key}'),
    );
    final firstTaskRect = tester.getRect(firstTaskDrop);
    final taskGesture = await tester.startGesture(
      tester.getCenter(secondTaskDrag),
    );
    await taskGesture.moveTo(
      Offset(firstTaskRect.center.dx, firstTaskRect.top + 2),
    );
    await tester.pump();
    await taskGesture.up();
    await tester.pumpAndSettle();
    expect(gridCutController.value.taskGroups.single.imageIds, [
      secondImageId,
      firstImageId,
    ]);
    expect(
      tester
          .widgetList<Checkbox>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Checkbox &&
                  widget.key.toString().contains('image-task-group-checkbox-'),
            ),
          )
          .every((checkbox) => checkbox.value == false),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('导出页会恢复保存的格式和画板选择', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('exporter_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final storyboardController = StoryboardController(database: database);
    final boardId = storyboardController.value.selectedBoard!.id;
    database.setSetting(
      'exporterPageUiState',
      jsonEncode({
        'format': 'pdf',
        'selectedBoardIds': [boardId],
        'anchorIndex': 0,
      }),
    );
    addTearDown(() async {
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          storyboardControllerProvider.overrideWithValue(storyboardController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: ExporterPage()),
        ),
      ),
    );

    final segmented = tester.widget<SegmentedButton<StoryboardExportFormat>>(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<StoryboardExportFormat>,
      ),
    );
    expect(segmented.selected, {StoryboardExportFormat.pdf});
    expect(find.text('已选择 1 个故事板'), findsOneWidget);
    expect(find.text('导出到...'), findsOneWidget);
    expect(find.text('导出画板图片'), findsOneWidget);
    expect(find.text('导出拍摄脚本'), findsOneWidget);
    expect(find.text('打开默认导出位置'), findsOneWidget);

    final boardCard = find.byKey(ValueKey('export-board-$boardId'));
    await tester.tap(boardCard);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(find.text('已选择 0 个故事板'), findsOneWidget);

    await tester.tap(boardCard);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(find.text('已选择 1 个故事板'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置页非外观区块默认折叠并持久记忆展开状态', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('settings_widget_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(() async {
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('数据目录'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('数据目录'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedCrossFade &&
            widget.crossFadeState == CrossFadeState.showFirst,
      ),
      findsWidgets,
    );

    await tester.tap(find.text('数据目录'));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedCrossFade &&
            widget.crossFadeState == CrossFadeState.showSecond,
      ),
      findsOneWidget,
    );
    expect(find.text('imports'), findsOneWidget);
    expect(find.byTooltip('打开目录'), findsNWidgets(10));
    expect(
      jsonDecode(database.getSetting('settingsPageExpandedSections')!)
          as List<dynamic>,
      contains('dataDirectories'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('数据目录'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedCrossFade &&
            widget.crossFadeState == CrossFadeState.showSecond,
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置页软件更新区默认关闭自动更新开关', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('settings_update_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(() async {
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('软件更新'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件更新'));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(
      const ValueKey('auto-install-updates-switch'),
    );
    expect(switchFinder, findsOneWidget);
    expect(settingsController.value.autoInstallUpdates, isFalse);
    expect(find.text('GitHub 仓库地址'), findsNothing);
    expect(find.text('保存更新设置'), findsOneWidget);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(settingsController.value.autoInstallUpdates, isTrue);
    expect(database.getSetting('autoInstallUpdates'), 'true');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('图片生成服务商卡片独立保存且默认模型绑定对应服务商', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('settings_image_key_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });

    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(() async {
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('图片生成 API'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片生成 API'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('image-provider-card-default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-provider-card-grsai')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-provider-card-gemini')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-provider-card-apimart')),
      findsOneWidget,
    );

    final modelField = find.byKey(
      const ValueKey('image-generation-model-field'),
    );
    expect(modelField, findsOneWidget);
    expect(
      find.descendant(of: modelField, matching: find.byType(EditableText)),
      findsNothing,
    );

    await tester.scrollUntilVisible(
      modelField,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(modelField);
    await tester.pumpAndSettle();

    expect(find.text('选择图片生成模型'), findsOneWidget);
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
    await tester.tap(
      find.byKey(const ValueKey('image-model-family-apimart-nano-banana')),
    );
    await tester.pumpAndSettle();
    final apiMartModel = find.byKey(
      const ValueKey('image-model-option-apimart:gemini-3-pro-image-preview'),
    );
    await tester.ensureVisible(apiMartModel);
    await tester.tap(apiMartModel);
    await tester.pumpAndSettle();

    final saveDefault = find.byKey(
      const ValueKey('save-image-generation-default-model'),
    );
    await tester.ensureVisible(saveDefault);
    await tester.tap(saveDefault);
    await tester.pumpAndSettle();

    final grsaiUrl = find.byKey(
      const ValueKey('image-generation-api-base-url-field'),
    );
    await tester.ensureVisible(grsaiUrl);
    await tester.enterText(grsaiUrl, 'https://grsai.example.com');
    final grsaiKey = find.byKey(
      const ValueKey('image-generation-api-key-field'),
    );
    await tester.ensureVisible(grsaiKey);
    await tester.enterText(grsaiKey, 'image-key-123');
    final saveGrsai = find.byKey(
      const ValueKey('save-image-generation-grsai-settings'),
    );
    await tester.ensureVisible(saveGrsai);
    await tester.tap(saveGrsai);
    await tester.pumpAndSettle();

    final geminiUrl = find.byKey(
      const ValueKey('image-generation-gemini-api-base-url-field'),
    );
    await tester.ensureVisible(geminiUrl);
    await tester.enterText(geminiUrl, 'https://gemini.example.com');
    final geminiKey = find.byKey(
      const ValueKey('image-generation-gemini-api-key-field'),
    );
    await tester.ensureVisible(geminiKey);
    await tester.enterText(geminiKey, 'gemini-key-456');
    final saveGemini = find.byKey(
      const ValueKey('save-image-generation-gemini-settings'),
    );
    await tester.ensureVisible(saveGemini);
    await tester.tap(saveGemini);
    await tester.pumpAndSettle();

    final apiMartUrl = find.byKey(
      const ValueKey('image-generation-apimart-api-base-url-field'),
    );
    await tester.ensureVisible(apiMartUrl);
    await tester.enterText(apiMartUrl, 'https://api.apimart.ai/v1');
    final apiMartKey = find.byKey(
      const ValueKey('image-generation-apimart-api-key-field'),
    );
    await tester.ensureVisible(apiMartKey);
    await tester.enterText(apiMartKey, 'apimart-key-789');
    final saveApiMart = find.byKey(
      const ValueKey('save-image-generation-apimart-settings'),
    );
    await tester.ensureVisible(saveApiMart);
    await tester.tap(saveApiMart);
    await tester.pumpAndSettle();
    expect(
      find.text('APIMart 配置已保存，请求地址：https://api.apimart.ai'),
      findsOneWidget,
    );

    expect(
      settingsController.value.imageGenerationApiBaseUrl,
      'https://grsai.example.com',
    );
    expect(settingsController.value.imageGenerationApiKey, 'image-key-123');
    expect(
      settingsController.value.imageGenerationGeminiApiBaseUrl,
      'https://gemini.example.com',
    );
    expect(
      settingsController.value.imageGenerationGeminiApiKey,
      'gemini-key-456',
    );
    expect(
      settingsController.value.imageGenerationApiMartApiBaseUrl,
      'https://api.apimart.ai',
    );
    expect(
      settingsController.value.imageGenerationApiMartApiKey,
      'apimart-key-789',
    );
    expect(
      settingsController.value.imageGenerationModel,
      'apimart:gemini-3-pro-image-preview',
    );
    expect(database.getSetting('imageGenerationApiKey'), 'image-key-123');
    expect(
      database.getSetting('imageGenerationGeminiApiBaseUrl'),
      'https://gemini.example.com',
    );
    expect(
      database.getSetting('imageGenerationGeminiApiKey'),
      'gemini-key-456',
    );
    expect(
      database.getSetting('imageGenerationApiMartApiBaseUrl'),
      'https://api.apimart.ai',
    );
    expect(
      database.getSetting('imageGenerationApiMartApiKey'),
      'apimart-key-789',
    );
    expect(
      database.getSetting('imageGenerationModel'),
      'apimart:gemini-3-pro-image-preview',
    );
    expect(find.text('APIMart · Nano Banana Pro'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _sendControlShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

bool _isCropCanvasPositioned(Widget widget) {
  return widget is Positioned && _containsWidgetType(widget, '_CropCanvas');
}

bool _isAxisRulerPositioned(Widget widget) {
  return widget is Positioned && _containsWidgetType(widget, '_AxisRuler');
}

bool _isCellHitRegion(Widget widget) {
  return widget.runtimeType.toString() == '_CellHitRegion';
}

bool _containsWidgetType(Widget widget, String typeName) {
  if (widget.runtimeType.toString() == typeName) {
    return true;
  }
  if (widget is ProxyWidget) {
    return _containsWidgetType(widget.child, typeName);
  }
  if (widget is SingleChildRenderObjectWidget && widget.child != null) {
    return _containsWidgetType(widget.child!, typeName);
  }
  return false;
}

class _RecordingFileExplorerService extends FileExplorerService {
  String? openedPath;

  @override
  Future<bool> openDirectory(String path) async {
    openedPath = path;
    return true;
  }
}

class _SpyStoryboardController extends StoryboardController {
  _SpyStoryboardController({
    required super.database,
    required super.directories,
  });

  var toggleCount = 0;

  @override
  void addOrRemoveAsset(StoryboardCutAsset asset) {
    toggleCount++;
    super.addOrRemoveAsset(asset);
  }
}

class _BlockingWidgetImageGenerationService extends ImageGenerationService {
  final _blocker = Completer<ImageGenerationResult>();
  bool started = false;

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) {
    started = true;
    return _blocker.future;
  }

  @override
  void close() {}
}

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';
