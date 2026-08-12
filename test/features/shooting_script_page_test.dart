import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
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
    late String navigationTargetId;
    late int navigationTargetNumber;
    late String matchingShotId;
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
      final matchingShot = shootingController.addShot()!;
      matchingShotId = matchingShot.id;
      shootingController.updateShot(
        matchingShot.copyWith(content: '女模特拿起产品并看向镜头'),
      );
      for (var index = 0; index < 7; index++) {
        final shot = shootingController.addShot()!;
        final updated = shot.copyWith(
          content: '外置面板导航镜头 ${shot.shotNumber}',
          scene: '外置面板测试场景',
          cameraMovement: '固定',
        );
        shootingController.updateShot(updated);
        navigationTargetId = updated.id;
        navigationTargetNumber = updated.shotNumber;
      }
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
      final assetSource = await File(
        'assets/branding/app_icon_512.png',
      ).copy('${root.path}/female-model.png');
      await assetLibraryController.importItem(
        sourcePath: assetSource.path,
        type: ReplicateAssetType.character,
        name: '女模特',
        description: '黄色上衣模特',
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

    replicateController.moveToStep(ReplicateStep.confirmShots);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWithValue(settingsController),
          appDatabaseProvider.overrideWithValue(database),
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
    expect(find.byKey(const ValueKey('confirm-story-panel')), findsOneWidget);
    expect(
      find.byKey(ValueKey('new-shot-row-$navigationTargetId')),
      findsNothing,
    );
    final targetDescription = find.byKey(
      ValueKey(
        'confirm-story-description-$navigationTargetNumber-$navigationTargetNumber',
      ),
    );
    await tester.scrollUntilVisible(
      targetDescription,
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('confirm-story-list')),
        matching: find.byType(Scrollable),
      ),
    );
    final storyDescriptionLink = tester.widget<InkWell>(targetDescription);
    expect(storyDescriptionLink.onTap, isNotNull);
    storyDescriptionLink.onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(
      find.byKey(ValueKey('new-shot-row-$navigationTargetId')),
      findsOneWidget,
    );
    replicateController.moveToStep(ReplicateStep.prepareAssets);
    await tester.pump(const Duration(milliseconds: 260));
    expect(
      find.byKey(const ValueKey('prepare-assets-right-asset-library-panel')),
      findsOneWidget,
    );
    expect(find.text('资产库'), findsOneWidget);
    expect(find.text('上传资产'), findsNothing);
    expect(find.text('按描述生成'), findsNothing);
    expect(find.text('女模特'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('script-auto-match-assets')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(assetBindingController.value.links, hasLength(1));
    expect(assetBindingController.value.links.single.shotId, matchingShotId);
    expect(assetBindingController.value.links.single.confirmed, isTrue);
    expect(
      assetBindingController.value.links.single.matchSource,
      ScriptAssetMatchSource.rule,
    );
    await tester.tap(
      find.byKey(const ValueKey('manage-prepare-assets-library')),
    );
    await tester.pumpAndSettle();
    expect(find.text('资产管理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asset-manager-upload-assets')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('asset-manager-generate-from-description')),
      findsOneWidget,
    );
    expect(find.text('上传资产'), findsOneWidget);
    expect(find.text('按描述生成'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    replicateController.moveToStep(ReplicateStep.confirmShots);
    await tester.pump(const Duration(milliseconds: 260));
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

  testWidgets('确认镜头页状态回写不改变文本框中间光标与中文组合区', (tester) async {
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
    late String shotId;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('shooting_script_cursor_');
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
      shootingController.createEmpty(name: '光标回归脚本');
      final shot = shootingController.addShot()!;
      shotId = shot.id;
      shootingController.updateShot(
        shot.copyWith(content: '人物展示产品', freeCreationDescription: '甲乙'),
      );
      final workflowRepository = ShootingScriptWorkflowRepository(database);
      replicateController = ReplicateController(
        repository: ReplicateRepository(database),
        shootingScriptController: shootingController,
        directories: directories,
        settingsController: settingsController,
        workflowRepository: workflowRepository,
        enforceFreeCreationMode: true,
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

    replicateController.moveToStep(ReplicateStep.confirmShots);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWithValue(settingsController),
          appDatabaseProvider.overrideWithValue(database),
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

    final descriptionField = find.byKey(
      ValueKey('free-creation-description-$shotId'),
    );
    expect(descriptionField, findsOneWidget);
    await tester.showKeyboard(descriptionField);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '甲中乙',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    var editable = tester.widget<EditableText>(
      find.descendant(
        of: descriptionField,
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, '甲中乙');
    expect(
      editable.controller.selection,
      const TextSelection.collapsed(offset: 2),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '甲中候选乙',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    editable = tester.widget<EditableText>(
      find.descendant(
        of: descriptionField,
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, '甲中候选乙');
    expect(editable.controller.selection.baseOffset, 4);
    expect(
      editable.controller.value.composing,
      const TextRange(start: 2, end: 4),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '甲中选乙',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    expect(
      shootingController.value.shots.single.freeCreationDescription,
      '甲中选乙',
    );
    editable = tester.widget<EditableText>(
      find.descendant(
        of: descriptionField,
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.selection.baseOffset, 3);

    final storyField = find.byKey(
      const ValueKey('free-creation-story-override-field'),
    );
    expect(storyField, findsOneWidget);
    await tester.showKeyboard(storyField);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '故事中间文本',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    editable = tester.widget<EditableText>(
      find.descendant(of: storyField, matching: find.byType(EditableText)),
    );
    expect(editable.controller.text, '故事中间文本');
    expect(editable.controller.selection.baseOffset, 4);
    replicateController.updateFreeCreationStoryOverride('外部刷新文本');
    await tester.pump();
    editable = tester.widget<EditableText>(
      find.descendant(of: storyField, matching: find.byType(EditableText)),
    );
    expect(
      editable.controller.text,
      '故事中间文本',
      reason: '输入框聚焦期间到达的状态刷新不能覆盖本地草稿',
    );
    expect(
      editable.controller.selection.baseOffset,
      4,
      reason: '输入框聚焦期间到达的状态刷新不能重置中间光标',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(
      replicateController.value.run?.freeCreationStoryOverride,
      '故事中间文本',
      reason: '输入框失焦时应由本地草稿覆盖编辑期间到达的旧状态',
    );
  });
}
