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
    expect(find.widgetWithText(TextField, '人物拿起产品并看向镜头'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(ValueKey('replicate-shot-replica-thumbnail-${shot.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('script-frame-gallery-image-1-复刻帧')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('replicate-new-next-assets')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('replicate-new-prepare-assets-step')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('replicate-user-instructions-${shot.id}')),
      findsOneWidget,
    );
    expect(find.text('全局风格'), findsOneWidget);
    expect(find.text('资产库'), findsOneWidget);
    expect(find.text('生成参数设置'), findsOneWidget);
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('collapsed-shot-asset-row-${shot.id}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('expand-all-shot-scripts')),
      findsOneWidget,
    );
    expect(find.text('人物拿起产品并看向镜头'), findsNothing);
    expect(find.text('镜头 01'), findsNothing);
    expect(find.text('原视频帧'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('expand-all-shot-scripts')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('collapse-all-shot-scripts')),
      findsOneWidget,
    );
    expect(find.text('人物拿起产品并看向镜头'), findsOneWidget);
    expect(find.text('镜头 01'), findsOneWidget);
    expect(find.text('原视频帧'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collapse-all-shot-scripts')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsNothing,
    );
    expect(find.text('人物拿起产品并看向镜头'), findsNothing);
    expect(find.text('镜头 01'), findsNothing);
    expect(find.text('原视频帧'), findsNothing);
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
    await tester.pumpAndSettle();
    await tester.drag(assetScroll, const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('shot-asset-visual-row-${shot.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('upload-asset-character')),
      findsOneWidget,
    );
    expect(find.text('角色'), findsOneWidget);
    await tester.tap(find.text('生成参数设置'));
    await tester.pumpAndSettle();
    expect(find.text('一键复刻默认生成参数'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('replicate-generation-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('replicate-generation-aspect-ratio')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('replicate-generation-resolution')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('replicate-generation-model')));
    await tester.pumpAndSettle();
    expect(find.text('选择图片生成模型'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('image-model-provider-grsai')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image-model-family-nano-banana')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
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
    await tester.pump(const Duration(milliseconds: 220));
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
    expect(find.text('来源：故事板原图'), findsOneWidget);
    final videoMenu = find.byKey(ValueKey('generated-video-menu-${shot.id}'));
    expect(videoMenu, findsNothing);
    final generateButton = find.byKey(
      ValueKey('generated-video-generate-button-${shot.id}'),
    );
    expect(generateButton, findsOneWidget);
    expect(tester.widget<FilledButton>(generateButton).onPressed, isNotNull);

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
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-generation-source-gallery-image-1')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump(const Duration(milliseconds: 50));
  });
}
