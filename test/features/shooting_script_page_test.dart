import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/presentation/shooting_script_page.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_controller.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('拍摄脚本页导出分镜图片弹窗区分原分镜图和复刻分镜图', (tester) async {
    tester.view
      ..physicalSize = const Size(1280, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    late Directory root;
    late AppDirectories directories;
    late AppDatabase database;
    late SettingsController settingsController;
    late ShootingScriptController shootingController;
    late ReplicateController replicateController;
    late ShootingAssetLibraryController assetLibraryController;
    late ShootingScriptAssetBindingController assetBindingController;
    late ShootingScriptAnalysisController scriptAnalysisController;
    late StoryboardController storyboardController;
    late VideoAnalysisController videoController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('shooting_script_page_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      final settingsRepository = SettingsRepository(database, directories);
      settingsController = SettingsController(
        repository: settingsRepository,
        initialSettings: settingsRepository.load(),
      );
      shootingController = ShootingScriptController(
        repository: ShootingScriptRepository(database),
        directories: directories,
      );
      shootingController.createEmpty(name: '导出弹窗脚本');
      shootingController.addShot();
      final workflowRepository = ShootingScriptWorkflowRepository(database);
      replicateController = ReplicateController(
        repository: ReplicateRepository(database),
        shootingScriptController: shootingController,
        directories: directories,
        settingsController: settingsController,
        workflowRepository: workflowRepository,
      );
      assetLibraryController = ShootingAssetLibraryController(
        repository: ShootingAssetLibraryRepository(
          database: database,
          directories: directories,
        ),
        directories: directories,
      );
      assetBindingController = ShootingScriptAssetBindingController(
        shootingScriptController: shootingController,
        libraryController: assetLibraryController,
        repository: workflowRepository,
        settingsController: settingsController,
      );
      scriptAnalysisController = ShootingScriptAnalysisController(
        shootingScriptController: shootingController,
        repository: workflowRepository,
        settingsController: settingsController,
      );
      storyboardController = StoryboardController(
        database: database,
        directories: directories,
        settingsController: settingsController,
      );
      videoController = VideoAnalysisController(
        directories: directories,
        settingsController: settingsController,
        repository: VideoAnalysisRepository(database),
        storyboardController: storyboardController,
        shootingScriptController: shootingController,
        scriptAnalysisController: scriptAnalysisController,
      );
    });
    addTearDown(() async {
      videoController.dispose();
      storyboardController.dispose();
      scriptAnalysisController.dispose();
      assetBindingController.dispose();
      assetLibraryController.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWithValue(settingsController),
          shootingScriptControllerProvider.overrideWithValue(
            shootingController,
          ),
          replicateControllerProvider.overrideWithValue(replicateController),
          shootingAssetLibraryControllerProvider.overrideWithValue(
            assetLibraryController,
          ),
          scriptAnalysisControllerProvider.overrideWithValue(
            scriptAnalysisController,
          ),
          scriptAssetBindingControllerProvider.overrideWithValue(
            assetBindingController,
          ),
          storyboardControllerProvider.overrideWithValue(storyboardController),
          videoAnalysisControllerProvider.overrideWithValue(videoController),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ShootingScriptPage()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('shooting-script-page')), findsOneWidget);
    expect(find.text('导出分镜图片'), findsOneWidget);
    expect(find.text('导出原图'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('export-shooting-script-originals')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.text('导出分镜图片'), findsNWidgets(2));
    expect(find.text('导出原分镜图'), findsOneWidget);
    expect(find.text('导出复刻分镜图'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('export-original-storyboard-images')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('export-replicated-storyboard-images')),
      findsOneWidget,
    );
  });
}
