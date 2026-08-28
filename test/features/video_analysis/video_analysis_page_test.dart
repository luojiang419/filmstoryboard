import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_controller.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/presentation/video_analysis_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('视频帧网格会为4比5竖屏保留更高的卡片比例', () {
    final landscape = videoFrameCardAspectRatio(16 / 9);
    final portrait = videoFrameCardAspectRatio(4 / 5);

    expect(portrait, lessThan(landscape));
    expect(portrait, closeTo(230 / (230 / (4 / 5) + 42), 0.001));
  });

  test('视频帧网格只计算视口与预加载行的索引范围', () {
    final range = videoFrameGridVisibleRange(
      itemCount: 100,
      crossAxisCount: 4,
      rowHeight: 100,
      viewportTop: 250,
      viewportBottom: 550,
      overscanRows: 1,
    );

    expect(range.firstIndex, 4);
    expect(range.lastIndex, 31);
    expect(range.isEmpty, isFalse);

    final empty = videoFrameGridVisibleRange(
      itemCount: 0,
      crossAxisCount: 4,
      rowHeight: 100,
      viewportTop: 0,
      viewportBottom: 400,
    );
    expect(empty.isEmpty, isTrue);
  });

  testWidgets('视频解析页拖入视频文件会复用导入链路并过滤非视频', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final StoryboardController storyboardController;
    late final _RecordingVideoAnalysisController videoController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('video_analysis_drop_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final settingsRepository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: settingsRepository,
        initialSettings: settingsRepository.load(),
      );
      storyboardController = StoryboardController(
        database: database,
        directories: directories,
        settingsController: settingsController,
      );
      videoController = _RecordingVideoAnalysisController(
        directories: directories,
        settingsController: settingsController,
        repository: VideoAnalysisRepository(database),
      );
    });
    addTearDown(() async {
      videoController.dispose();
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await _pumpPage(
      tester,
      database: database,
      directories: directories,
      settingsController: settingsController,
      storyboardController: storyboardController,
      videoController: videoController,
    );

    var dropTarget = tester.widget<DropTarget>(
      find.byKey(const ValueKey('video-analysis-drop-target')),
    );
    dropTarget.onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(find.text('松开添加视频或图片'), findsOneWidget);

    final videoPath = p.join(root.path, 'reference.MP4');
    final notePath = p.join(root.path, 'note.txt');
    dropTarget = tester.widget<DropTarget>(
      find.byKey(const ValueKey('video-analysis-drop-target')),
    );
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(videoPath), DropItemFile(notePath)],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(videoController.importedPaths, [p.normalize(videoPath)]);
    expect(find.text('已添加 1 个视频和 0 张图片，忽略 1 个不支持文件'), findsOneWidget);
  });

  testWidgets('视频解析页拖入非视频文件会提示支持格式', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final StoryboardController storyboardController;
    late final _RecordingVideoAnalysisController videoController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('video_analysis_drop_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final settingsRepository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: settingsRepository,
        initialSettings: settingsRepository.load(),
      );
      storyboardController = StoryboardController(
        database: database,
        directories: directories,
        settingsController: settingsController,
      );
      videoController = _RecordingVideoAnalysisController(
        directories: directories,
        settingsController: settingsController,
        repository: VideoAnalysisRepository(database),
      );
    });
    addTearDown(() async {
      videoController.dispose();
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await _pumpPage(
      tester,
      database: database,
      directories: directories,
      settingsController: settingsController,
      storyboardController: storyboardController,
      videoController: videoController,
    );

    final dropTarget = tester.widget<DropTarget>(
      find.byKey(const ValueKey('video-analysis-drop-target')),
    );
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(p.join(root.path, 'cover.zip'))],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(videoController.importedPaths, isEmpty);
    expect(
      find.text(
        '未找到支持的视频或图片文件，可拖入 mp4、mov、mkv、avi、webm、m4v、png、jpg、jpeg、webp 或 bmp',
      ),
      findsOneWidget,
    );
  });

  testWidgets('视频解析页导入图片后切换到多宫格裁切检查器', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final SettingsController settingsController;
    late final StoryboardController storyboardController;
    late final _RecordingVideoAnalysisController videoController;
    late final GridCutController gridCutController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('video_analysis_grid_cut_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final settingsRepository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: settingsRepository,
        initialSettings: settingsRepository.load(),
      );
      storyboardController = StoryboardController(
        database: database,
        directories: directories,
        settingsController: settingsController,
      );
      videoController = _RecordingVideoAnalysisController(
        directories: directories,
        settingsController: settingsController,
        repository: VideoAnalysisRepository(database),
      );
      gridCutController = GridCutController(
        directories: directories,
        database: database,
        detectionService: const GridDetectionService(),
        cropService: const GridCropService(),
      );
      final imagePath = p.join(root.path, 'grid.png');
      final image = img.Image(width: 100, height: 100);
      img.fill(image, color: img.ColorRgb8(40, 80, 120));
      await File(imagePath).writeAsBytes(img.encodePng(image));
      await gridCutController.importPaths([imagePath]);
    });
    addTearDown(() async {
      gridCutController.dispose();
      videoController.dispose();
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    expect(gridCutController.value.images, isNotEmpty);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpPage(
      tester,
      database: database,
      directories: directories,
      settingsController: settingsController,
      storyboardController: storyboardController,
      videoController: videoController,
      gridCutController: gridCutController,
    );
    expect(
      find.byKey(const ValueKey('video-analysis-source-tabs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-analysis-source-tab-images')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('video-analysis-source-tab-videos')),
    );
    await tester.pump();
    expect(find.text('参考视频'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('video-analysis-source-tab-images')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('grid-cut-inspector-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('grid-cut-canvas-viewport')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('grid-cut-action-export-selected')),
      findsOneWidget,
    );
    expect(find.text('裁切参数'), findsOneWidget);
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required AppDatabase database,
  required AppDirectories directories,
  required SettingsController settingsController,
  required StoryboardController storyboardController,
  required _RecordingVideoAnalysisController videoController,
  GridCutController? gridCutController,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        projectDatabaseProvider.overrideWithValue(database),
        projectDirectoriesProvider.overrideWithValue(directories),
        settingsControllerProvider.overrideWithValue(settingsController),
        storyboardControllerProvider.overrideWithValue(storyboardController),
        videoAnalysisControllerProvider.overrideWithValue(videoController),
        if (gridCutController != null)
          gridCutControllerProvider.overrideWithValue(gridCutController),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: SizedBox(width: 1000, height: 700, child: VideoAnalysisPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _RecordingVideoAnalysisController extends VideoAnalysisController {
  _RecordingVideoAnalysisController({
    required super.directories,
    required super.settingsController,
    required super.repository,
  });

  final importedPaths = <String>[];

  @override
  Future<void> importVideos(List<File> files) async {
    importedPaths.addAll(files.map((file) => p.normalize(file.path)));
    value = value.copyWith(message: '测试导入 ${files.length} 个视频');
  }
}
