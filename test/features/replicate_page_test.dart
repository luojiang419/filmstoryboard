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
import 'package:filmstoryboard/features/replicate/presentation/replicate_shot_navigation_controller.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
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
    final freeCreationSwitch = find.byKey(
      const ValueKey('free-creation-mode-switch'),
    );
    expect(freeCreationSwitch, findsOneWidget);
    expect(replicateController.value.run!.freeCreationEnabled, isFalse);
    await tester.tap(freeCreationSwitch);
    await tester.pump();
    expect(replicateController.value.run!.freeCreationEnabled, isTrue);
    expect(
      ReplicateRepository(
        database,
      ).getRun(replicateController.value.run!.id)?.freeCreationEnabled,
      isTrue,
    );
    final freeHeader = find.byKey(const ValueKey('free-creation-table-header'));
    expect(freeHeader, findsOneWidget);
    for (final label in const ['原视频帧范围', '复刻分镜范围', '剧情描述']) {
      expect(
        find.descendant(of: freeHeader, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: freeHeader, matching: find.text('提示词')),
      findsNothing,
    );
    final descriptionField = find.byKey(
      ValueKey('free-creation-description-${shot.id}'),
    );
    expect(descriptionField, findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pump();
    expect(find.textContaining('请先填写 1 个镜头组'), findsOneWidget);
    expect(replicateController.value.prompts, isEmpty);
    await tester.enterText(descriptionField, '节奏紧凑地展示人物拿起产品');
    await tester.pump();
    expect(
      shootingController.value.shots.single.freeCreationDescription,
      '节奏紧凑地展示人物拿起产品',
    );
    final storyField = find.byKey(
      const ValueKey('free-creation-story-override-field'),
    );
    expect(storyField, findsOneWidget);
    await tester.enterText(storyField, '人物在室内完成产品展示。');
    await tester.pump();
    expect(
      replicateController.value.run!.freeCreationStoryOverride,
      '人物在室内完成产品展示。',
    );
    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(replicateController.value.prompts, hasLength(1));
    expect(
      find.descendant(of: freeHeader, matching: find.text('提示词')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(
          'free-creation-prompt-${replicateController.value.prompts.single.id}',
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(ValueKey('replicate-shot-replica-thumbnail-${shot.id}')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-1-复刻分镜')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pump(const Duration(milliseconds: 300));
    replicateController.setFreeCreationEnabled(false);
    await tester.pump();

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
    expect(find.text('资产库'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manage-prepare-assets-library')),
      findsOneWidget,
    );
    expect(find.text('参考资产入口'), findsNothing);
    expect(find.text('上传人物'), findsNothing);
    expect(find.text('按描述生成'), findsNothing);
    expect(find.text('添加参考图'), findsNothing);
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('prepare-asset-original-frame-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('prepare-asset-replica-frame-${shot.id}')),
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
    expect(find.text('原视频帧'), findsAtLeastNWidgets(1));
    expect(find.text('复刻分镜'), findsAtLeastNWidgets(1));
    await tester.tap(
      find.byKey(ValueKey('prepare-asset-replica-frame-${shot.id}')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-1-复刻分镜')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pump(const Duration(milliseconds: 300));
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
      findsNothing,
    );
    expect(find.text('上传人物'), findsNothing);
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
    expect(promptTableWidget.children.first.children, hasLength(3));
    for (final header in const ['原视频帧', '复刻分镜图', '生成提示词']) {
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
      const ValueKey('video-generation-five-column-table'),
    );
    expect(videoTable, findsOneWidget);
    final table = tester.widget<Table>(videoTable);
    expect(table.children.first.children, hasLength(5));
    for (final header in const ['原视频帧', '复刻分镜图', '时长', '生成视频', '生成提示词']) {
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
      find.byKey(const ValueKey('video-generation-replica-range-1-1')),
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

  testWidgets('镜头风格在构建前选择并持久化且合成步骤只读显示', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('h3_prompt_style_page_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    await settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultMiniMaxVideoGenerationConfigId,
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: 'H3 风格页面测试');
    shootingController.addShot();
    final replicateRepository = ReplicateRepository(database);
    final replicateController = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final run = replicateController.value.run!;
    replicateRepository.upsertRun(
      run.copyWith(
        currentStep: ReplicateStep.confirmShots,
        confirmShotsStatus: ProcessingStatus.completed,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    replicateController.refresh();
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

    expect(
      replicateController.value.run?.currentStep,
      ReplicateStep.confirmShots,
    );
    expect(replicateController.usesOfficialH3PromptWriting, isTrue);
    expect(
      find.byKey(const ValueKey('build-camera-style-dropdown-general')),
      findsOneWidget,
    );
    expect(find.text('通用 H3'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('build-camera-style-dropdown-general')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('品牌宣传短片').last);
    await tester.pumpAndSettle();

    expect(settingsController.value.h3PromptStyleId, 'brand-promo');
    expect(settingsRepository.load().h3PromptStyleId, 'brand-promo');
    expect(
      find.byKey(const ValueKey('build-camera-style-dropdown-brand-promo')),
      findsOneWidget,
    );

    replicateRepository.upsertRun(
      replicateController.value.run!.copyWith(
        currentStep: ReplicateStep.composePrompts,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    replicateController.refresh();
    await tester.pump();

    final statusPanel = find.byKey(
      const ValueKey('compose-prompts-right-status-panel'),
    );
    expect(statusPanel, findsOneWidget);
    final statusScroll = find.descendant(
      of: statusPanel,
      matching: find.byType(Scrollable),
    );
    await tester.drag(statusScroll, const Offset(0, -420));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('selected-build-camera-style-summary')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: statusPanel,
        matching: find.byKey(
          const ValueKey('build-camera-style-dropdown-brand-promo'),
        ),
      ),
      findsNothing,
    );
    expect(find.textContaining('产品功能、使用场景与行动引导'), findsOneWidget);
    expect(
      find.textContaining('MiniMax-H3 / skills/brand-promo-video-generator'),
      findsOneWidget,
    );
    expect(find.textContaining('中文官方 Skill 已随软件内置'), findsOneWidget);
    expect(find.textContaining('完整 SKILL.cn.md 与全部必要引用文档'), findsOneWidget);
    expect(find.textContaining('最终 H3 提示词继续叠加成片风格锁'), findsOneWidget);
    expect(find.textContaining('返回确认镜头并重新构建'), findsOneWidget);

    await settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultKlingCliVideoGenerationConfigId,
    );
    replicateController.refresh();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('selected-build-camera-style-summary')),
      findsNothing,
    );
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
    shootingController.updateShot(shot.copyWith(content: '女模特拿起产品并看向镜头'));
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
    late final File librarySource;
    await tester.runAsync(() async {
      librarySource = File('${root.path}/female-model.png');
      await File('assets/branding/app_icon_512.png').copy(librarySource.path);
      await libraryController.importItem(
        sourcePath: librarySource.path,
        type: ReplicateAssetType.character,
        name: '女模特',
        description: '黄色上衣模特',
      );
    });
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

    var manageAssetsInvoked = false;
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
          home: Scaffold(
            body: ReplicatePage(
              onManageAssets: () => manageAssetsInvoked = true,
            ),
          ),
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
      findsNothing,
    );
    expect(find.text('上传人物'), findsNothing);
    expect(find.text('资产库'), findsOneWidget);
    expect(find.text('女模特'), findsOneWidget);
    expect(find.text('黄色上衣模特'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey(
          'prepare-asset-library-item-${libraryController.value.items.single.id}',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('manage-prepare-assets-library')),
    );
    await tester.pump();
    expect(manageAssetsInvoked, isTrue);
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
    expect(find.textContaining('本地结构化拼接'), findsAtLeastNWidgets(1));
    expect(
      find.byKey(const ValueKey('local-prompt-compiler-summary')),
      findsOneWidget,
    );
    expect(find.text('执行方式：本地结构化拼接'), findsOneWidget);
    expect(find.text('合成阶段视觉模型调用：0 次'), findsOneWidget);
    expect(find.textContaining('合成阶段视觉模型 0 次'), findsOneWidget);
    expect(find.text('结构化解析：0/1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('structured-prompt-context-fallback-notice')),
      findsOneWidget,
      reason: '旧项目缺少结构化上下文时应明确提示本地回退，不应隐藏触发网络调用',
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

  test('上传与描述生成入口迁入资产管理页面', () {
    final replicateSource = File(
      'lib/features/replicate/presentation/replicate_page.dart',
    ).readAsStringSync();
    final shootingSource = File(
      'lib/features/shooting_script/presentation/shooting_script_page.dart',
    ).readAsStringSync();

    expect(replicateSource, isNot(contains('class _AssetLibraryActionBar')));
    expect(
      replicateSource,
      contains("ValueKey('manage-prepare-assets-library')"),
    );
    expect(shootingSource, contains('asset-manager-upload-assets'));
    expect(shootingSource, contains('asset-manager-generate-from-description'));
    expect(
      shootingSource,
      contains('await WidgetsBinding.instance.endOfFrame'),
    );
    expect(shootingSource, contains('await widget.onPickFiles('));
    expect(shootingSource, contains('await widget.onGenerate('));

    final newPrepareStart = replicateSource.indexOf(
      'class _NewPrepareAssetsStep',
    );
    final sidePanelStart = replicateSource.indexOf(
      'class _PrepareAssetLibrarySidePanel',
      newPrepareStart,
    );
    expect(newPrepareStart, greaterThanOrEqualTo(0));
    expect(sidePanelStart, greaterThan(newPrepareStart));
    final newPrepareSource = replicateSource.substring(
      newPrepareStart,
      sidePanelStart,
    );
    expect(newPrepareSource, isNot(contains('required this.onImport,')));
    expect(newPrepareSource, isNot(contains('required this.onGenerate,')));
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

    await tester.tap(
      find.byKey(const ValueKey('collapse-confirm-story-panel')),
    );
    await tester.pump(const Duration(milliseconds: 220));

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
    final fourth = shootingController.addShot()!;
    final framePath = File('assets/branding/app_icon_512.png').absolute.path;
    shootingController.updateShot(
      first.copyWith(
        framePath: framePath,
        scene: '棚拍场景',
        visual: '模特下半身入画',
        content: '镜头从模特下半身开始向上移动',
        shotSize: '全景',
        cameraMovement: '上升',
        cameraNotes: '镜头目的：建立人物；速度曲线：先快后慢',
        composition: '起：下半身居中 → 落：面部近景居中',
        cameraAngle: '低机位抬升到眼平',
        visualFocus: '从服装轮廓转移到人物面部',
        transitionHint: '承接脚步动作后切入产品细节',
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
    shootingController.updateShot(
      fourth.copyWith(
        framePath: framePath,
        scene: '室外场景',
        visual: '模特背对城市天际线',
        content: '独立镜头展示模特背影',
        shotSize: '中景',
        cameraMovement: '固定',
      ),
    );
    final replicateRepository = ReplicateRepository(database);
    final replicateController = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final now = DateTime.now().toUtc();
    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'test-replicated-${fourth.id}',
        runId: replicateController.value.run!.id,
        scriptShotId: fourth.id,
        shotNumber: fourth.shotNumber,
        originalFramePath: framePath,
        generatedFramePath: framePath,
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
    final videoGenerationController = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = _SuccessfulBuildScriptAnalysisController(
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
    final shotNavigationController = ReplicateShotNavigationController();
    addTearDown(() async {
      shotNavigationController.dispose();
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

    Widget buildPage() => ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        settingsControllerProvider.overrideWithValue(settingsController),
        replicateControllerProvider.overrideWithValue(replicateController),
        videoGenerationControllerProvider.overrideWithValue(
          videoGenerationController,
        ),
        scriptAnalysisControllerProvider.overrideWithValue(analysisController),
        shootingAssetLibraryControllerProvider.overrideWithValue(
          libraryController,
        ),
        scriptAssetBindingControllerProvider.overrideWithValue(
          bindingController,
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ReplicatePage(
            shotNavigationController: shotNavigationController,
          ),
        ),
      ),
    );
    await tester.pumpWidget(buildPage());
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('script-auto-analyze-all')), findsNothing);
    expect(find.textContaining('先手动设置每个镜头的首帧和结束帧范围'), findsOneWidget);
    expect(find.textContaining('范围内全部图片按顺序合并为一次多图视觉请求'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('script-build-continuous-shots')),
      findsOneWidget,
    );
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
    expect(find.byKey(ValueKey('new-shot-row-${first.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('new-shot-row-${second.id}')), findsNothing);
    expect(find.byKey(ValueKey('new-shot-row-${third.id}')), findsNothing);
    expect(find.byKey(ValueKey('new-shot-row-${fourth.id}')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('replicate-shot-original-range-1-3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('replicate-shot-replica-range-1-3')),
      findsOneWidget,
    );
    expect(find.text('1（1-3）'), findsOneWidget);
    expect(find.text('2（4）'), findsOneWidget);
    expect(find.textContaining('全局故事从镜头从模特下半身开始'), findsOneWidget);
    expect(find.textContaining('运镜：升降推进镜头'), findsOneWidget);
    expect(find.text('生成反馈'), findsNothing, reason: '首稿生成前不应出现反馈列');

    await tester.tap(
      find.byKey(ValueKey('replicate-shot-original-thumbnail-${fourth.id}')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-4-原视频帧')),
      findsOneWidget,
      reason: '前方镜头被合并成组后，镜号 4 仍必须按稳定 ID 打开自身图片',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey('replicate-shot-replica-thumbnail-${fourth.id}')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-4-复刻分镜')),
      findsOneWidget,
      reason: '镜号 4 的复刻图片也必须打开镜号 4，而不是前一个镜头组',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pumpAndSettle();

    expect(replicateController.value.confirmedShots, hasLength(4));
    expect(
      replicateRepository.listPrompts(replicateController.value.run!.id),
      hasLength(2),
      reason: '自动拼接结果应先写入仓储',
    );
    expect(
      replicateController.value.prompts,
      hasLength(2),
      reason:
          '复刻状态：${replicateController.value.message}；错误：${replicateController.value.errorMessage}',
    );
    expect(
      replicateController.value.run?.composePromptsStatus,
      ProcessingStatus.completed,
    );
    expect(
      replicateController.value.run?.currentStep,
      ReplicateStep.confirmShots,
      reason: '自动拼接只准备检查结果，不应跳过准备资产步骤',
    );
    final untouchedPromptBefore = replicateController.value.prompts.singleWhere(
      (prompt) => prompt.scriptShotId == fourth.id,
    );
    replicateController.moveToStep(ReplicateStep.prepareAssets);
    await tester.pumpAndSettle();
    final builtFirst = replicateController.value.shots.firstWhere(
      (shot) => shot.id == first.id,
    );
    replicateController.updateShot(
      builtFirst.copyWith(replicationInstructions: '使用准备资产页的新产品'),
    );
    await tester.pump();
    expect(
      replicateController.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '资产替换要求变更后，合成提示词应标记为待重拼',
    );
    replicateController.moveToStep(ReplicateStep.confirmShots);
    await tester.pumpAndSettle();
    expect(
      find.text('生成反馈'),
      findsOneWidget,
      reason: '提示词待重拼不等于构建稿丢失，切页返回仍应显示反馈列',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(buildPage());
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('生成反馈'), findsOneWidget, reason: '已有首稿时重新进入确认镜头页仍应显示反馈列');
    expect(
      find.byKey(const ValueKey('built-shot-group-row-1-3')),
      findsOneWidget,
    );
    expect(find.text('导演运镜'), findsOneWidget);
    expect(find.text('画面描述'), findsOneWidget);
    expect(find.text('生成反馈'), findsOneWidget);
    expect(find.text('构图 / 机位'), findsOneWidget);
    expect(find.text('焦点 / 衔接'), findsOneWidget);
    expect(find.text('摄影备注'), findsOneWidget);
    expect(find.textContaining('起：下半身居中'), findsOneWidget);
    replicateRepository.replacePrompts(replicateController.value.run!.id, [
      untouchedPromptBefore,
    ]);
    replicateController.refresh();
    await tester.pump();
    expect(
      replicateController.value.prompts,
      hasLength(1),
      reason: '模拟局部重构前目标镜头提示词缺失的真实故障状态',
    );
    final feedbackField = find.byKey(
      ValueKey('generation-feedback-${first.id}'),
    );
    expect(feedbackField, findsOneWidget);
    await tester.enterText(feedbackField, '画面慢动作');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(feedbackField, '画面慢动作，人物表情');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(feedbackField, '画面慢动作，人物表情呆滞');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      analysisController.generationFeedbackUpdateCallCount,
      0,
      reason: '连续输入期间不应逐字保存并刷新整份镜头列表',
    );
    expect(shootingController.value.shots.first.generationFeedback, isEmpty);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      analysisController.generationFeedbackUpdateCallCount,
      1,
      reason: '停止输入后应仅合并保存一次生成反馈',
    );
    expect(find.text('根据反馈重构'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('script-build-continuous-shots')),
    );
    await tester.pumpAndSettle();
    expect(analysisController.feedbackBuildCallCount, 1);
    expect(analysisController.lastOnlyFeedbackGroups, isTrue);
    expect(analysisController.lastFeedbackShotIds, [first.id]);
    expect(
      shootingController.value.shots.first.generationFeedback,
      isEmpty,
      reason: '成功重构后测试控制器模拟清空已消费反馈',
    );
    final feedbackTextField = tester.widget<TextFormField>(
      find.descendant(of: feedbackField, matching: find.byType(TextFormField)),
    );
    expect(
      feedbackTextField.controller?.text,
      isEmpty,
      reason: '镜头状态清空后，界面输入控件必须立即同步为空',
    );
    expect(replicateController.value.prompts, hasLength(2));
    expect(
      replicateController.value.prompts
          .singleWhere((prompt) => prompt.scriptShotId == first.id)
          .prompt,
      isNotEmpty,
      reason: '目标提示词即使在重构前缺失，也必须自动补齐',
    );
    expect(
      replicateController.value.run?.composePromptsStatus,
      ProcessingStatus.completed,
    );
    expect(replicateController.value.run?.completedCount, 2);
    expect(replicateController.value.run?.totalCount, 2);
    final untouchedPromptAfter = replicateController.value.prompts.singleWhere(
      (prompt) => prompt.scriptShotId == fourth.id,
    );
    expect(untouchedPromptAfter.prompt, untouchedPromptBefore.prompt);
    expect(untouchedPromptAfter.rawResponse, untouchedPromptBefore.rawResponse);
    expect(untouchedPromptAfter.updatedAt, untouchedPromptBefore.updatedAt);
    expect(find.text('返回编辑'), findsOneWidget);
    final builtGroup = find.byKey(const ValueKey('built-shot-group-row-1-3'));
    expect(
      find.descendant(
        of: builtGroup,
        matching: find.textContaining('从服装轮廓转移到人物面部'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: builtGroup,
        matching: find.textContaining('镜头目的：建立人物'),
      ),
      findsOneWidget,
    );
    final originalRange = find.byKey(
      const ValueKey('built-shot-original-range-1-3'),
    );
    expect(originalRange, findsOneWidget);

    await tester.ensureVisible(originalRange);
    await tester.pumpAndSettle();
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

    expect(
      replicateController.moveToStep(ReplicateStep.composePrompts),
      isTrue,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('replicate-new-compose-prompts-step')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compose-prompt-three-column-table')),
      findsOneWidget,
    );
    expect(find.text('尚未合成提示词'), findsNothing);
    expect(replicateController.value.prompts, hasLength(2));
    expect(find.text('2/2 已合成'), findsOneWidget);
    expect(find.text('结构化解析：0/2'), findsOneWidget);
    final promptEditors = find.descendant(
      of: find.byKey(const ValueKey('compose-prompt-three-column-table')),
      matching: find.byType(TextField),
    );
    expect(promptEditors, findsNWidgets(2));
    for (final element in promptEditors.evaluate()) {
      expect((element.widget as TextField).controller?.text, isNotEmpty);
    }

    expect(replicateController.moveToStep(ReplicateStep.confirmShots), isTrue);
    await tester.pump();

    late ScriptShot navigationTarget;
    for (var index = 0; index < 8; index++) {
      final shot = shootingController.addShot()!;
      navigationTarget = shot.copyWith(
        content: '导航测试镜头 ${shot.shotNumber} 的描述文本',
        scene: '导航测试场景 ${shot.shotNumber}',
        cameraMovement: '固定',
      );
      shootingController.updateShot(navigationTarget);
    }
    replicateController.refresh();
    await tester.pump();

    final divider = tester.widget<Divider>(
      find.byKey(const ValueKey('confirm-story-divider-0')),
    );
    expect(divider.thickness, 1);
    expect(
      find.byKey(ValueKey('new-shot-row-${navigationTarget.id}')),
      findsNothing,
      reason: '导航前最末镜头应在左侧表格可视区域之外',
    );

    final targetDescription = find.byKey(
      ValueKey(
        'confirm-story-description-${navigationTarget.shotNumber}-${navigationTarget.shotNumber}',
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

    expect(shotNavigationController.requestedShotId, navigationTarget.id);

    expect(
      find.byKey(ValueKey('new-shot-row-${navigationTarget.id}')),
      findsOneWidget,
      reason: '点击右侧描述后，左侧表格应滚动并构建对应镜头行',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });
}

class _SuccessfulBuildScriptAnalysisController
    extends ShootingScriptAnalysisController {
  _SuccessfulBuildScriptAnalysisController({
    required super.shootingScriptController,
    required super.repository,
    required super.settingsController,
  }) : _shootingScriptController = shootingScriptController;

  final ShootingScriptController _shootingScriptController;
  int generationFeedbackUpdateCallCount = 0;
  int feedbackBuildCallCount = 0;
  bool lastOnlyFeedbackGroups = false;
  List<String> lastFeedbackShotIds = const [];

  @override
  void updateGenerationFeedback(String shotId, String feedback) {
    generationFeedbackUpdateCallCount++;
    super.updateGenerationFeedback(shotId, feedback);
  }

  @override
  Future<bool> buildScript({
    Map<String, String> imagePathOverrides = const {},
    bool requireImageOverrides = false,
    bool onlyFeedbackGroups = false,
  }) async {
    lastOnlyFeedbackGroups = onlyFeedbackGroups;
    if (onlyFeedbackGroups) {
      final feedbackShots = _shootingScriptController.value.shots
          .where((shot) => shot.generationFeedback.trim().isNotEmpty)
          .toList(growable: false);
      lastFeedbackShotIds = [for (final shot in feedbackShots) shot.id];
      feedbackBuildCallCount++;
      for (final shot in feedbackShots) {
        _shootingScriptController.updateShot(
          shot.copyWith(generationFeedback: ''),
        );
      }
    }
    return true;
  }
}
