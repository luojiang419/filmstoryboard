import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_controller.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/presentation/video_analysis_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
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
    expect(find.text('松开添加视频'), findsOneWidget);

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
    expect(find.text('已添加 1 个视频，忽略 1 个非视频文件'), findsOneWidget);
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
        files: [DropItemFile(p.join(root.path, 'cover.png'))],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(videoController.importedPaths, isEmpty);
    expect(
      find.text('未找到支持的视频文件，可拖入 mp4、mov、mkv、avi、webm 或 m4v'),
      findsOneWidget,
    );
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required AppDatabase database,
  required AppDirectories directories,
  required SettingsController settingsController,
  required StoryboardController storyboardController,
  required _RecordingVideoAnalysisController videoController,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        projectDirectoriesProvider.overrideWithValue(directories),
        settingsControllerProvider.overrideWithValue(settingsController),
        storyboardControllerProvider.overrideWithValue(storyboardController),
        videoAnalysisControllerProvider.overrideWithValue(videoController),
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
