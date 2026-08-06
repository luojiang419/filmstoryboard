import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/replicate/presentation/replicate_page.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/presentation/video_generation_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('一键复刻页展示四步流并复用严格四列视频工作区', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final File fixtureImage;
    late final File originalFrame;
    late final File replicatedFrame;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('replicate_page_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      fixtureImage = File('assets/branding/app_icon_512.png');
      originalFrame = fixtureImage;
      replicatedFrame = fixtureImage.absolute;
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '页面测试脚本');
    final shot = shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      content: '人物拿起产品并看向镜头',
      shotSize: '中景',
      framePath: originalFrame.path,
    );
    shootingController.updateShot(updatedShot);
    final replicateRepository = ReplicateRepository(database);
    final replicateController = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final videoGenerationController = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    final now = DateTime.now().toUtc();
    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'test-replicated-${shot.id}',
        runId: replicateController.value.run!.id,
        scriptShotId: shot.id,
        shotNumber: shot.shotNumber,
        originalFramePath: originalFrame.path,
        generatedFramePath: replicatedFrame.path,
        assetIds: const [],
        prompt: '',
        model: 'test',
        rawResponse: '',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );
    replicateController.refresh();
    expect(replicateController.value.replicatedImages, hasLength(1));
    expect(
      replicateController.value.replicatedImages.single.generatedFramePath,
      replicatedFrame.path,
    );
    expect(replicatedFrame.existsSync(), isTrue);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
    );
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final bindingController = ShootingScriptAssetBindingController(
      shootingScriptController: shootingController,
      libraryController: libraryController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
    );
    addTearDown(() async {
      bindingController.dispose();
      libraryController.dispose();
      analysisController.dispose();
      videoGenerationController.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          replicateControllerProvider.overrideWithValue(replicateController),
          videoGenerationControllerProvider.overrideWithValue(
            videoGenerationController,
          ),
          scriptAnalysisControllerProvider.overrideWithValue(
            analysisController,
          ),
          shootingAssetLibraryControllerProvider.overrideWithValue(
            libraryController,
          ),
          scriptAssetBindingControllerProvider.overrideWithValue(
            bindingController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ReplicatePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('replicate-page')), findsOneWidget);
    expect(find.text('确认镜头'), findsOneWidget);
    expect(find.text('准备资产'), findsOneWidget);
    expect(find.text('合成提示词'), findsOneWidget);
    expect(find.text('生成视频'), findsOneWidget);
    expect(find.text('原图'), findsAtLeastNWidgets(2));
    expect(find.text('复刻分镜'), findsOneWidget);
    expect(find.text('切换脚本模版'), findsOneWidget);
    expect(find.text('全部确认'), findsNothing);
    expect(find.text('清除确认'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.byKey(const ValueKey('replicate-new-confirm-shots-step')),
      findsOneWidget,
    );
    final durationField = find.descendant(
      of: find.byKey(ValueKey('shot-duration-${shot.id}')),
      matching: find.byType(TextField),
    );
    expect(durationField, findsOneWidget);
    await tester.enterText(durationField, '4.5s');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(shootingController.value.shots.single.durationSeconds, 4.5);
    final startEndSwitch = find.byKey(
      const ValueKey('video-start-end-frame-mode-switch'),
    );
    expect(startEndSwitch, findsOneWidget);
    expect(settingsController.value.videoStartEndFrameModeEnabled, isFalse);
    await tester.tap(startEndSwitch);
    await tester.pump();
    expect(settingsController.value.videoStartEndFrameModeEnabled, isTrue);
    expect(settingsRepository.load().videoStartEndFrameModeEnabled, isTrue);
    expect(find.text('首帧'), findsAtLeastNWidgets(1));
    expect(find.text('尾帧'), findsAtLeastNWidgets(1));
    expect(find.text('复刻首帧'), findsAtLeastNWidgets(1));
    expect(find.text('复刻尾帧'), findsAtLeastNWidgets(1));
    replicateController.selectStartFrame(shot.id);
    await tester.pump();
    expect(replicateController.pendingStartFrameShotId, shot.id);
    expect(find.widgetWithText(TextField, '人物拿起产品并看向镜头'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(ValueKey('replicate-shot-replica-thumbnail-${shot.id}')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-1-复刻帧')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('replicate-new-next-assets')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('replicate-new-prepare-assets-step')),
      findsOneWidget,
    );
    final prepareStep = find.byKey(
      const ValueKey('replicate-new-prepare-assets-step'),
    );
    expect(
      find.byKey(ValueKey('replicate-user-instructions-${shot.id}')),
      findsOneWidget,
    );
    expect(find.text('步骤 2 · 匹配资产图'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('prepare-assets-right-asset-library-panel')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('匹配资产图')),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('批量上传')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('全局风格')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('整体约束')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('生成参数设置')),
      findsNothing,
    );
    expect(find.text('参考资产入口'), findsOneWidget);
    expect(find.text('上传人物'), findsOneWidget);
    expect(find.text('按描述生成'), findsOneWidget);
    expect(find.text('添加参考图'), findsNothing);
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('prepare-asset-start-end-strip-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('collapsed-shot-asset-row-${shot.id}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('collapse-all-shot-scripts')),
      findsOneWidget,
    );
    expect(find.text('人物拿起产品并看向镜头'), findsAtLeastNWidgets(1));
    expect(find.text('镜头 01'), findsOneWidget);
    expect(find.text('首帧'), findsAtLeastNWidgets(1));
    expect(find.text('待尾帧'), findsAtLeastNWidgets(1));
    expect(find.text('复刻首帧'), findsAtLeastNWidgets(1));
    await tester.tap(find.byKey(const ValueKey('collapse-all-shot-scripts')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsNothing,
    );
    expect(find.text('人物拿起产品并看向镜头'), findsNothing);
    expect(find.text('镜头 01'), findsNothing);
    expect(find.text('待尾帧'), findsNothing);
    expect(
      find.byKey(ValueKey('toggle-shot-script-${shot.id}')),
      findsNothing,
      reason: '全部折叠应收起整个镜头列表，不能残留逐镜箭头',
    );
    replicateController.value = replicateController.value.copyWith(
      isBusy: true,
      message: '复刻进度 0/1，成功 0 个',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          replicateControllerProvider.overrideWithValue(replicateController),
          videoGenerationControllerProvider.overrideWithValue(
            videoGenerationController,
          ),
          scriptAnalysisControllerProvider.overrideWithValue(
            analysisController,
          ),
          shootingAssetLibraryControllerProvider.overrideWithValue(
            libraryController,
          ),
          scriptAssetBindingControllerProvider.overrideWithValue(
            bindingController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ReplicatePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(ValueKey('collapsed-shot-asset-row-${shot.id}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('replicate-running-status')),
      findsOneWidget,
      reason: '页面重建后仍应显示控制器中的一键复刻进度',
    );
    expect(find.text('复刻进度 0/1，成功 0 个'), findsOneWidget);
    replicateController.value = replicateController.value.copyWith(
      isBusy: false,
      message: '',
    );
    await tester.pump();
    final assetScroll = find.byKey(
      const ValueKey('replicate-asset-library-scroll'),
    );
    await tester.drag(assetScroll, const Offset(0, -800));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(assetScroll, const Offset(0, 800));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('asset-library-upload-reference')),
      findsOneWidget,
    );
    expect(find.text('上传人物'), findsOneWidget);
    final rightAssetPanel = find.byKey(
      const ValueKey('prepare-assets-right-asset-library-panel'),
    );
    expect(
      find.descendant(of: rightAssetPanel, matching: find.text('生成参数设置')),
      findsNothing,
    );
    expect(find.text('一键复刻默认生成参数'), findsNothing);
    expect(
      find.byKey(const ValueKey('replicate-generation-model')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('replicate-generation-aspect-ratio')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('replicate-generation-resolution')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    final source = File('${root.path}/character.png');
    await tester.runAsync(() async {
      await fixtureImage.copy(source.path);
      await replicateController.importAsset(
        sourcePath: source.path,
        type: ReplicateAssetType.character,
        name: '测试角色',
      );
    });
    await tester.pump(const Duration(milliseconds: 220));
    await tester.tap(find.byKey(const ValueKey('replicate-new-next-prompts')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
      findsOneWidget,
    );
    final promptTable = find.byKey(
      const ValueKey('compose-prompt-three-column-table'),
    );
    expect(promptTable, findsOneWidget);
    final promptTableWidget = tester.widget<Table>(promptTable);
    expect(promptTableWidget.children.first.children, hasLength(5));
    for (final header in const ['首帧', '尾帧', '复刻首帧', '复刻尾帧', '生成提示词']) {
      expect(
        find.descendant(of: promptTable, matching: find.text(header)),
        findsAtLeastNWidgets(1),
      );
    }
    expect(find.text('导出 XLSX'), findsOneWidget);
    expect(find.text('导出 TXT/JSON'), findsNothing);
    expect(
      find.descendant(of: promptTable, matching: find.text('人物拿起产品并看向镜头')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('toggle-shooting-script-template')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('replicate-compose-prompts-step')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('toggle-shooting-script-template')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
      findsOneWidget,
    );

    await replicateController.composeAllPrompts();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
        matching: find.text('人物拿起产品并看向镜头'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('toggle-shooting-script-template')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('replicate-compose-prompts-step')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('replicate-compose-prompts-step')),
        matching: find.text('人物拿起产品并看向镜头'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('toggle-shooting-script-template')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
      findsOneWidget,
    );
    database.executeStatement(
      'DELETE FROM replicated_shot_images WHERE script_shot_id = ?;',
      [shot.id],
    );
    replicateController.refresh();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(
      find.byKey(const ValueKey('new-go-video-generation')),
    );
    await tester.tap(find.byKey(const ValueKey('new-go-video-generation')));
    await tester.pump(const Duration(milliseconds: 220));
    final videoTable = find.byKey(
      const ValueKey('video-generation-four-column-table'),
    );
    expect(videoTable, findsOneWidget);
    final table = tester.widget<Table>(videoTable);
    expect(table.children.first.children, hasLength(4));
    for (final header in const ['原视频', '首帧图', '生成视频', '生成提示词']) {
      expect(
        find.descendant(of: videoTable, matching: find.text(header)),
        findsWidgets,
      );
    }
    final titleTopPositions = <double>[];
    final mediaTopPositions = <double>[];
    for (final slot in const ['original', 'source-image', 'generated']) {
      final title = find.byKey(ValueKey('video-$slot-shot-title-${shot.id}'));
      final media = find.byKey(ValueKey('video-$slot-media-${shot.id}'));
      expect(title, findsOneWidget);
      expect(media, findsOneWidget);
      expect(
        find.descendant(
          of: title,
          matching: find.text('镜头 ${shot.shotNumber}'),
        ),
        findsOneWidget,
      );
      expect(tester.widget<SizedBox>(title).height, 20);
      titleTopPositions.add(tester.getTopLeft(title).dy);
      mediaTopPositions.add(tester.getTopLeft(media).dy);
    }
    for (final top in titleTopPositions.skip(1)) {
      expect(top, closeTo(titleTopPositions.first, 0.01));
    }
    for (final top in mediaTopPositions.skip(1)) {
      expect(top, closeTo(mediaTopPositions.first, 0.01));
    }
    final videoMenu = find.byKey(ValueKey('generated-video-menu-${shot.id}'));
    expect(videoMenu, findsNothing);
    final generateButton = find.byKey(
      ValueKey('generated-video-generate-button-${shot.id}'),
    );
    expect(generateButton, findsOneWidget);

    tester.view.physicalSize = const Size(820, 700);
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('replicate-page')), findsOneWidget);
    expect(tester.takeException(), isNull);

    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'test-replicated-restored-${shot.id}',
        runId: replicateController.value.run!.id,
        scriptShotId: shot.id,
        shotNumber: shot.shotNumber,
        originalFramePath: originalFrame.path,
        generatedFramePath: replicatedFrame.path,
        assetIds: const [],
        prompt: '',
        model: 'test',
        rawResponse: '',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );
    replicateController.refresh();
    expect(replicateController.value.replicatedImages, hasLength(1));
    expect(videoGenerationController.value.replicatedImages, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoGenerationControllerProvider.overrideWithValue(
            videoGenerationController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: VideoGenerationPage()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('video-generation-script-selector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-generation-history-filter')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(ValueKey('video-generation-source-thumbnail-${shot.id}')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('video-generation-source-gallery-image-1')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pump(const Duration(milliseconds: 220));

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('准备资产步骤改为匹配资产图并移除全局规则入口', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('prepare_asset_panel_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '准备资产右栏测试');
    final shot = shootingController.addShot()!;
    shootingController.updateShot(shot.copyWith(content: '人物拿起产品并看向镜头'));
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    )..moveToStep(ReplicateStep.prepareAssets);
    final videoGenerationController = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final bindingController = ShootingScriptAssetBindingController(
      shootingScriptController: shootingController,
      libraryController: libraryController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    addTearDown(() async {
      bindingController.dispose();
      libraryController.dispose();
      analysisController.dispose();
      videoGenerationController.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          replicateControllerProvider.overrideWithValue(replicateController),
          videoGenerationControllerProvider.overrideWithValue(
            videoGenerationController,
          ),
          scriptAnalysisControllerProvider.overrideWithValue(
            analysisController,
          ),
          shootingAssetLibraryControllerProvider.overrideWithValue(
            libraryController,
          ),
          scriptAssetBindingControllerProvider.overrideWithValue(
            bindingController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ReplicatePage()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const ValueKey('replicate-new-prepare-assets-step')),
      findsOneWidget,
    );
    final prepareStep = find.byKey(
      const ValueKey('replicate-new-prepare-assets-step'),
    );
    expect(
      find.byKey(const ValueKey('prepare-assets-right-asset-library-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('prepare-assets-right-panel-resize-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('collapse-prepare-assets-right-panel')),
      findsOneWidget,
    );
    final preparePanelWidthBefore = tester
        .getSize(
          find.byKey(
            const ValueKey('prepare-assets-right-asset-library-panel'),
          ),
        )
        .width;
    await tester.drag(
      find.byKey(const ValueKey('prepare-assets-right-panel-resize-handle')),
      const Offset(-56, 0),
    );
    await tester.pump();
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey('prepare-assets-right-asset-library-panel'),
            ),
          )
          .width,
      greaterThan(preparePanelWidthBefore + 20),
    );
    await tester.tap(
      find.byKey(const ValueKey('collapse-prepare-assets-right-panel')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('expand-prepare-assets-right-panel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('expand-prepare-assets-right-panel')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('prepare-assets-right-asset-library-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(find.text('步骤 2 · 匹配资产图'), findsOneWidget);
    expect(
      find.descendant(of: prepareStep, matching: find.text('匹配资产图')),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.byKey(const ValueKey('asset-library-upload-reference')),
      findsOneWidget,
    );
    expect(find.text('上传人物'), findsOneWidget);
    expect(
      find.descendant(of: prepareStep, matching: find.text('批量上传')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('全局风格')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('整体约束')),
      findsNothing,
    );
    expect(
      find.descendant(of: prepareStep, matching: find.text('生成参数设置')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('prepare-assets-side-section-selector')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('replicate-generation-model')),
      findsNothing,
    );

    replicateController.moveToStep(ReplicateStep.composePrompts);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compose-prompt-three-column-table')),
      findsOneWidget,
    );
    final composeStep = find.byKey(
      const ValueKey('replicate-new-compose-prompts-step'),
    );
    expect(
      find.descendant(
        of: composeStep,
        matching: find.byKey(
          const ValueKey('prepare-assets-right-asset-library-panel'),
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: composeStep,
        matching: find.byKey(
          const ValueKey('compose-prompts-right-status-panel'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compose-prompts-right-panel-resize-handle')),
      findsOneWidget,
    );
    final composePanelWidthBefore = tester
        .getSize(
          find.byKey(const ValueKey('compose-prompts-right-status-panel')),
        )
        .width;
    await tester.drag(
      find.byKey(const ValueKey('compose-prompts-right-panel-resize-handle')),
      const Offset(-52, 0),
    );
    await tester.pump();
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('compose-prompts-right-status-panel')),
          )
          .width,
      greaterThan(composePanelWidthBefore + 20),
    );
    await tester.tap(
      find.byKey(const ValueKey('collapse-compose-prompts-right-panel')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('expand-compose-prompts-right-panel')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });

  test('准备资产上传人物入口使用单文件导入并等待异步完成', () {
    final source = File(
      'lib/features/replicate/presentation/replicate_page.dart',
    ).readAsStringSync();

    expect(source, contains('onImportLocalAsset: _importSingleAsset'));
    expect(source, contains('onImport: onImportLocalAsset'));
    expect(
      source,
      contains(
        'final Future<ReplicateAsset?> Function(ReplicateAssetType type) onImport;',
      ),
    );
    expect(
      source,
      contains(
        'final Future<void> Function(ReplicateAssetType type) onGenerate;',
      ),
    );
    expect(source, contains('Future<void> _runAction'));
    expect(source, contains('setState(() => _isRunningAction = true)'));
    expect(
      source,
      contains('if (mounted) setState(() => _isRunningAction = false)'),
    );
    expect(source, contains('await widget.onImport(_selectedType);'));
    expect(
      source,
      contains("_isRunningAction ? '处理中…' : '上传\${_selectedType.label}'"),
    );
    expect(source, contains('Future<XFile?> _pickAssetFile() async'));
    expect(
      source,
      contains(
        'return await openFile(acceptedTypeGroups: const [_assetTypes]);',
      ),
    );

    final newPrepareStart = source.indexOf('class _NewPrepareAssetsStep');
    final sidePanelStart = source.indexOf(
      'class _PrepareAssetLibrarySidePanel',
      newPrepareStart,
    );
    expect(newPrepareStart, greaterThanOrEqualTo(0));
    expect(sidePanelStart, greaterThan(newPrepareStart));
    final newPrepareSource = source.substring(newPrepareStart, sidePanelStart);
    expect(newPrepareSource, isNot(contains('required this.onImport,')));
    expect(
      newPrepareSource,
      isNot(contains('final ValueChanged<ReplicateAssetType> onImport')),
    );
  });

  testWidgets('确认镜头列表列宽可拖拽调整并从 settings 恢复', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('replicate_widths_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '列宽测试脚本');
    final shot = shootingController.addShot()!;
    shootingController.updateShot(shot.copyWith(content: '人物拿起产品并看向镜头'));
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final videoGenerationController = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final bindingController = ShootingScriptAssetBindingController(
      shootingScriptController: shootingController,
      libraryController: libraryController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    addTearDown(() async {
      bindingController.dispose();
      libraryController.dispose();
      analysisController.dispose();
      videoGenerationController.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    Future<void> pumpPage() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            settingsControllerProvider.overrideWithValue(settingsController),
            replicateControllerProvider.overrideWithValue(replicateController),
            videoGenerationControllerProvider.overrideWithValue(
              videoGenerationController,
            ),
            scriptAnalysisControllerProvider.overrideWithValue(
              analysisController,
            ),
            shootingAssetLibraryControllerProvider.overrideWithValue(
              libraryController,
            ),
            scriptAssetBindingControllerProvider.overrideWithValue(
              bindingController,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(body: ReplicatePage()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 220));
    }

    await pumpPage();

    final contentField = find.widgetWithText(TextField, '人物拿起产品并看向镜头');
    final contentResizeHandle = find.byKey(
      const ValueKey('confirm-shot-column-resize-content'),
    );
    expect(contentField, findsOneWidget);
    expect(contentResizeHandle, findsOneWidget);
    final beforeContentWidth = tester.getSize(contentField).width;
    await tester.drag(contentResizeHandle, const Offset(72, 0));
    await tester.pump();

    final afterContentWidth = tester.getSize(contentField).width;
    final contentWidthDelta = afterContentWidth - beforeContentWidth;
    expect(contentWidthDelta, greaterThan(20));
    final savedColumnWidths = database.getSetting(
      'replicateConfirmShotColumnWidths',
    );
    expect(savedColumnWidths, isNotNull);
    final decodedColumnWidths =
        jsonDecode(savedColumnWidths!) as Map<String, dynamic>;
    expect(decodedColumnWidths['content'], (680 + contentWidthDelta).round());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpPage();

    expect(tester.getSize(contentField).width, closeTo(afterContentWidth, 1));
  });

  testWidgets('构建脚本按连续镜头合并脚本与原视频帧范围', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('replicate_built_script_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '构建脚本测试');
    final first = shootingController.addShot()!;
    final second = shootingController.addShot()!;
    final third = shootingController.addShot()!;
    final framePath = File('assets/branding/app_icon_512.png').absolute.path;
    shootingController.updateShot(
      first.copyWith(
        framePath: framePath,
        scene: '棚拍场景',
        visual: '模特下半身入画',
        content: '镜头从模特下半身开始向上移动',
        shotSize: '全景',
        cameraMovement: '上升',
        movementTrend: '向上推进',
        actionStage: '准备',
        continuesToNext: true,
      ),
    );
    shootingController.updateShot(
      second.copyWith(
        framePath: framePath,
        scene: '棚拍场景',
        visual: '镜头继续上移至模特上半身',
        content: '镜头持续靠近模特',
        shotSize: '中景',
        cameraMovement: '推进',
        movementTrend: '继续上移',
        actionStage: '进行',
        continuesFromPrevious: true,
        continuesToNext: true,
      ),
    );
    shootingController.updateShot(
      third.copyWith(
        framePath: framePath,
        scene: '棚拍场景',
        visual: '镜头上升至模特脸部',
        content: '镜头看到模特的脸并完成推进',
        shotSize: '近景',
        cameraMovement: '推进',
        movementTrend: '上升完成',
        actionStage: '完成',
        continuesFromPrevious: true,
      ),
    );
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final videoGenerationController = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    final libraryController = ShootingAssetLibraryController(
      repository: ShootingAssetLibraryRepository(
        database: database,
        directories: directories,
      ),
      directories: directories,
    );
    final bindingController = ShootingScriptAssetBindingController(
      shootingScriptController: shootingController,
      libraryController: libraryController,
      repository: workflowRepository,
      settingsController: settingsController,
    );
    addTearDown(() async {
      bindingController.dispose();
      libraryController.dispose();
      analysisController.dispose();
      videoGenerationController.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          settingsControllerProvider.overrideWithValue(settingsController),
          replicateControllerProvider.overrideWithValue(replicateController),
          videoGenerationControllerProvider.overrideWithValue(
            videoGenerationController,
          ),
          scriptAnalysisControllerProvider.overrideWithValue(
            analysisController,
          ),
          shootingAssetLibraryControllerProvider.overrideWithValue(
            libraryController,
          ),
          scriptAssetBindingControllerProvider.overrideWithValue(
            bindingController,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ReplicatePage()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('confirm-story-panel')), findsOneWidget);
    expect(find.text('分镜故事'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-story-panel-resize-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('collapse-confirm-story-panel')),
      findsOneWidget,
    );
    final storyPanelWidthBefore = tester
        .getSize(find.byKey(const ValueKey('confirm-story-panel')))
        .width;
    await tester.drag(
      find.byKey(const ValueKey('confirm-story-panel-resize-handle')),
      const Offset(-48, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('confirm-story-panel'))).width,
      greaterThan(storyPanelWidthBefore + 20),
    );
    await tester.tap(
      find.byKey(const ValueKey('collapse-confirm-story-panel')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('expand-confirm-story-panel')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('expand-confirm-story-panel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('confirm-story-panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-story-group-1-3')),
      findsOneWidget,
    );
    expect(find.textContaining('全局故事围绕镜头从模特下半身开始'), findsOneWidget);
    expect(find.textContaining('运镜：升降推进镜头'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('built-shot-group-row-1-3')),
      findsOneWidget,
    );
    expect(find.text('升降推进镜头'), findsOneWidget);
    final originalRange = find.byKey(
      const ValueKey('built-shot-original-range-1-3'),
    );
    expect(originalRange, findsOneWidget);

    await tester.tap(originalRange);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-1-原视频帧')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-2-原视频帧')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭预览'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pump();
    expect(find.byKey(ValueKey('new-shot-row-${first.id}')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });
}
