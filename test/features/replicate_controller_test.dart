import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('从故事板生成新脚本后复刻工作区跟随新脚本', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_storyboard_selection_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '旧脚本');
    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final generated = shootingController.createFromStoryboard(
      const StoryboardBoard(
        id: 'board-1',
        name: '当前故事板',
        width: 1920,
        height: 1080,
        rows: 1,
        columns: 1,
        gap: 12,
        items: [
          StoryboardItem(
            asset: StoryboardCutAsset(
              id: 'asset-1',
              imageId: 'image-1',
              sourceName: 'shot.png',
              path: 'D:/shots/shot.png',
              indexNo: 1,
            ),
            caption: '人物拿起产品',
            slotIndex: 0,
          ),
        ],
      ),
    );

    expect(generated, isNotNull);
    expect(shootingController.value.selectedScriptId, generated!.id);
    expect(controller.value.selectedScriptId, generated.id);
    expect(controller.value.shots, hasLength(1));
    expect(controller.value.shots.single.content, '人物拿起产品');
  });

  test('合成提示词规则跟随当前视频模型切换格式和并发额度', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_compose_model_rule_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    expect(controller.composePromptModelLabel, '可灵');
    expect(controller.usesOfficialH3PromptWriting, isFalse);
    expect(
      controller.composePromptConcurrency,
      ReplicateController.klingComposePromptConcurrency,
    );

    await settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultMiniMaxVideoGenerationConfigId,
    );

    expect(controller.composePromptModelLabel, 'MiniMax H3');
    expect(controller.usesOfficialH3PromptWriting, isTrue);
    expect(
      controller.composePromptConcurrency,
      ReplicateController.defaultComposePromptConcurrency,
    );
    expect(
      controller.selectedH3PromptStyle,
      same(H3PromptStyle.general),
      reason: '旧设置必须默认使用通用 H3',
    );

    await settingsController.saveVideoGenerationApiConfig(
      const VideoGenerationApiConfig(
        id: 'jimeng-test',
        name: '即梦视频',
        baseUrl: 'https://example.test',
        apiKey: 'test',
        model: 'Seedance 2.0',
      ),
    );

    expect(controller.composePromptModelLabel, '即梦');
    expect(controller.usesOfficialH3PromptWriting, isFalse);
    expect(
      controller.composePromptConcurrency,
      ReplicateController.defaultComposePromptConcurrency,
    );

    await controller.selectH3PromptStyle('brand-promo');

    expect(controller.selectedH3PromptStyle, H3PromptStyle.general);
    expect(settingsController.value.h3PromptStyleId, H3PromptStyle.generalId);
    expect(settingsRepository.load().h3PromptStyleId, H3PromptStyle.generalId);
  });

  test('确认页手动镜头组的 H3 提示词包含整组帧和组内全部资产', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_manual_group_prompt_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
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
    )..createEmpty(name: '手动镜头组合成提示词');
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final frames = <File>[];
    for (var index = 1; index <= 3; index++) {
      frames.add(
        await File(
          '${root.path}/manual-group-frame-$index.png',
        ).writeAsBytes([137, 80, 78, 71, index]),
      );
    }
    final first = shootingController.addShot()!;
    final middle = shootingController.addShot()!;
    final tail = shootingController.addShot()!;
    for (final entry in [
      (shot: first, frame: frames[0], content: '人物开始拿起产品'),
      (shot: middle, frame: frames[1], content: '人物抬手展示产品'),
      (shot: tail, frame: frames[2], content: '人物完成展示动作'),
    ]) {
      shootingController.updateShot(
        entry.shot.copyWith(
          framePath: entry.frame.path,
          durationSeconds: 2,
          content: entry.content,
        ),
      );
    }
    expect(
      shootingController.setContinuousShotRange(
        startShotId: first.id,
        endShotId: tail.id,
      ),
      isTrue,
    );

    final now = DateTime.now().toUtc();
    final productFile = await File(
      '${root.path}/manual-group-product.png',
    ).writeAsBytes([1, 2, 3]);
    final sceneFile = await File(
      '${root.path}/manual-group-scene.png',
    ).writeAsBytes([4, 5, 6]);
    for (final asset in [
      ScriptAsset(
        id: 'manual-group-product',
        scriptId: first.scriptId,
        type: ReplicateAssetType.product,
        name: '透明水杯',
        description: '银色杯盖',
        path: productFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptAsset(
        id: 'manual-group-scene',
        scriptId: first.scriptId,
        type: ReplicateAssetType.scene,
        name: '白色展台',
        description: '银色台面',
        path: sceneFile.path,
        referenceNumber: 2,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertScriptAsset(asset);
    }
    for (final link in [
      ScriptShotAssetLink(
        shotId: middle.id,
        scriptAssetId: 'manual-group-product',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '中间镜头资产',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: tail.id,
        scriptAssetId: 'manual-group-scene',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '尾镜头资产',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertLink(link);
    }

    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await controller.composeAllPrompts(maxConcurrent: 1);

    expect(controller.value.prompts, hasLength(1));
    final prompt = controller.value.prompts.single;
    expect(prompt.scriptShotId, first.id);
    expect(
      prompt.assetIds,
      containsAll(['manual-group-product', 'manual-group-scene']),
    );
    expect(prompt.prompt, contains('@图片1至@图片3是同一连续镜头的顺序动作参考'));
    expect(prompt.prompt, contains('图片4：产品参考'));
    expect(prompt.prompt, contains('图片5：场景参考'));
    expect(prompt.prompt, isNot(contains('首帧参考图')));
    expect(prompt.prompt, isNot(contains('尾帧参考图')));
    expect(prompt.prompt, isNot(contains('只补足@图片1到@图片2之间')));

    await controller.regeneratePrompt(prompt.id);

    expect(controller.value.prompts, hasLength(1));
    expect(controller.value.prompts.single.prompt, contains('图片5：场景参考'));
  });

  test('三步复刻任务可恢复，素材编号删除后不复用并能导出提示词', () async {
    final root = await Directory.systemTemp.createTemp('replicate_flow_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final replicateRepository = ReplicateRepository(database);
    late ReplicateController controller;
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final script = shootingController.createEmpty(name: '夏日产品片');
    final shot = shootingController.addShot()!;
    final frame = File('${root.path}/source-frame.png');
    final frameImage = img.Image(width: 12, height: 8);
    img.fill(frameImage, color: img.ColorRgb8(40, 120, 200));
    await frame.writeAsBytes(img.encodePng(frameImage), flush: true);
    shootingController.updateShot(
      shot.copyWith(
        framePath: frame.path,
        content: '模特缓慢拿起玻璃杯并转向窗边',
        visual: '原视频帧里模特站在窗边展示玻璃杯',
        scene: '原视频窗边客厅',
        shotSize: '中景',
        cameraMovement: '缓慢推镜、横移',
        visualFocus: '原视频蓝色包装瓶',
        dialogue: '今天也要清爽一点',
        sound: '冰块碰撞声',
      ),
    );

    controller = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final initialGenerationModel = controller.value.run!.generationModel;
    final initialDescriptor = ImageGenerationCatalog.descriptorFor(
      initialGenerationModel,
    )!;
    final changedAspectRatio = initialDescriptor.aspectRatios.contains('1:1')
        ? '1:1'
        : initialDescriptor.aspectRatios.first;
    final changedImageSize = ImageGenerationCatalog.resolutionsFor(
      initialGenerationModel,
      changedAspectRatio,
    ).last;
    final changedQuality = initialDescriptor.qualities.last;
    controller.updateGenerationDefaults(
      aspectRatio: changedAspectRatio,
      imageSize: changedImageSize,
      quality: changedQuality,
    );
    expect(controller.value.run?.generationAspectRatio, changedAspectRatio);
    expect(controller.value.run?.generationImageSize, changedImageSize);
    expect(controller.value.run?.generationQuality, changedQuality);
    expect(controller.value.selectedScriptId, script.id);
    expect(
      controller.moveToStep(ReplicateStep.prepareAssets),
      isTrue,
      reason: '镜头步骤只需查阅，不再要求逐条点击确认',
    );

    final firstSource = File('${root.path}/first.png');
    await firstSource.writeAsBytes([137, 80, 78, 71], flush: true);
    final first = await controller.importAsset(
      sourcePath: firstSource.path,
      type: ReplicateAssetType.character,
      name: '女主角',
      description: '短发，浅色亚麻衬衫',
    );
    expect(first?.referenceNumber, 1);
    await controller.deleteAsset(first!.id);
    controller.dispose();

    controller = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.run?.confirmedShotIds, contains(shot.id));
    expect(controller.value.run?.generationAspectRatio, changedAspectRatio);
    expect(controller.value.run?.generationImageSize, changedImageSize);
    expect(controller.value.run?.generationQuality, changedQuality);

    final secondSource = File('${root.path}/second.png');
    await secondSource.writeAsBytes([137, 80, 78, 71, 13], flush: true);
    final second = await controller.importAsset(
      sourcePath: secondSource.path,
      type: ReplicateAssetType.product,
      name: '气泡水',
      description: '透明玻璃瓶，蓝色标签',
    );
    expect(second?.referenceNumber, 2);
    final secondAsset = second!;
    expect(controller.moveToStep(ReplicateStep.composePrompts), isTrue);
    replicateRepository.upsertPrompt(
      ShotPrompt(
        id: '${controller.value.run!.id}-prompt-${shot.id}',
        runId: controller.value.run!.id,
        shotNumber: shot.shotNumber,
        scriptShotId: shot.id,
        assetIds: [secondAsset.id],
        prompt: '旧版提示词：模特缓慢拿起玻璃杯并转向窗边，原视频蓝色包装瓶。',
        model: ReplicateController.promptModel,
        rawResponse: jsonEncode({
          'shotFingerprint': 'legacy-fingerprint',
          'sd2Prompt': '旧 SD2：原视频帧里模特站在窗边展示玻璃杯',
          'klingPrompt': '旧可灵：原视频窗边客厅，原视频蓝色包装瓶',
          'selectedPromptFormat': ShotPromptFormat.kling.name,
        }),
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    await controller.composeAllPrompts();
    expect(controller.value.prompts, hasLength(1));
    final prompt = controller.value.prompts.single.prompt;
    final generated = controller.value.prompts.single;
    expect(prompt, contains('图片1为起始画面与主体参考'));
    expect(controller.promptFormatFor(generated), ShotPromptFormat.kling);
    expect(controller.value.run?.completedCount, 1);
    expect(shootingController.value.shots.single.prompt, prompt);
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.kling),
      contains('图片1为起始画面与主体参考'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.h3),
      contains('【参考素材说明】'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.h3),
      contains('非叙事性音乐：'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.sd2),
      contains('图片2'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.sd2),
      contains('镜头1'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.sd2),
      contains('无字幕'),
    );
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.sd2),
      isNot(contains(secondAsset.id)),
    );
    for (final format in ShotPromptFormat.values) {
      final text = controller.promptTextFor(generated, format);
      expect(text, isNot(contains('模特缓慢拿起玻璃杯并转向窗边')));
      expect(text, isNot(contains('原视频帧里模特站在窗边展示玻璃杯')));
      expect(text, isNot(contains('原视频窗边客厅')));
      expect(text, isNot(contains('原视频蓝色包装瓶')));
    }
    final storedPrompt = replicateRepository
        .listPrompts(controller.value.run!.id)
        .single;
    expect(storedPrompt.prompt, generated.prompt);
    expect(storedPrompt.prompt, isNot(contains('旧版提示词')));
    expect(storedPrompt.prompt, isNot(contains('原视频蓝色包装瓶')));
    final storedRaw = jsonDecode(storedPrompt.rawResponse) as Map;
    expect(storedRaw['promptRulesVersion'], 19);
    expect(
      shootingController.value.shots.single.prompt,
      isNot(contains('旧版提示词')),
    );
    controller.selectPromptFormat(generated.id, ShotPromptFormat.kling);
    expect(controller.value.prompts.single.prompt, contains('图片1为起始画面与主体参考'));
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.kling,
    );
    controller.selectPromptFormat(generated.id, ShotPromptFormat.sd2);
    expect(controller.value.prompts.single.prompt, contains('图片2'));
    controller.selectPromptFormat(generated.id, ShotPromptFormat.h3);
    expect(controller.value.prompts.single.prompt, contains('【画面过程描述】'));

    final exported = await controller.exportPrompts();
    expect(exported, isNotNull);
    expect(exported!.xlsxFile.existsSync(), isTrue);
    expect(exported.xlsxFile.path.toLowerCase(), endsWith('.xlsx'));
    final exportedArchive = ZipDecoder().decodeBytes(
      await exported.xlsxFile.readAsBytes(),
    );
    final exportedSheet = utf8.decode(
      exportedArchive.findFile('xl/worksheets/sheet1.xml')!.content
          as List<int>,
    );
    expect(exportedSheet, contains('最终提示词'));
    expect(exportedSheet, contains('【参考素材说明】'));
    expect(exportedSheet, contains('图片2：产品参考'));
    expect(exportedSheet, isNot(contains('主体与素材定义')));
    expect(
      exportedArchive.files.where((file) => file.name.startsWith('xl/media/')),
      hasLength(1),
    );
    expect(exportedArchive.findFile('xl/drawings/drawing1.xml'), isNotNull);
    expect(
      exportedArchive.files.where(
        (file) => file.name.endsWith('.txt') || file.name.endsWith('.json'),
      ),
      isEmpty,
      reason: '合成提示词导出只应生成 XLSX',
    );

    controller.dispose();
    controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.prompts.single.prompt, contains('图片2'));
    expect(controller.value.run?.currentStep, ReplicateStep.confirmShots);

    final restoredShot = shootingController.value.shots.single;
    shootingController.updateShot(
      restoredShot.copyWith(content: '外部页面修改后的镜头内容'),
    );
    expect(
      controller.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '脚本内容变化后，旧提示词必须明确标记为待重新合成',
    );
    expect(
      controller.value.prompts,
      hasLength(1),
      reason: '镜头信息变化后仍应保留上一次成功提示词供用户查看',
    );
    final retainedPrompt = controller.value.prompts.single.prompt;
    expect(
      replicateRepository.listPrompts(controller.value.run!.id),
      hasLength(1),
      reason: '待重新合成状态不得删除数据库中的最后有效结果',
    );

    controller.dispose();
    controller = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.prompts.single.prompt, retainedPrompt);
    expect(
      controller.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '软件重启式恢复后既要保留旧结果，也要保留待重新合成提示',
    );
  });

  test('合成提示词纯拼接构建字段并剥离原视频帧服装和配饰描述', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_prompt_clean_source_visual_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load().copyWith(
        videoGenerationApiConfigs: const [
          VideoGenerationApiConfig(
            id: 'test-h3',
            name: '测试 H3',
            kind: VideoGenerationApiConfigKind.httpApi,
            baseUrl: 'http://127.0.0.1:7860',
            apiKey: '',
            model: 'minimax-h3-local',
          ),
        ],
        activeVideoGenerationApiConfigId: 'test-h3',
      ),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final replicateRepository = ReplicateRepository(database);
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final visionService = _RecordingVisionStoryboardService();
    final controller = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    shootingController.createEmpty(name: '产品复刻片');
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(
        shotSize: '中景',
        cameraMovement: '升降',
        composition: '主体位于画面中部偏右，品牌字 YERAD 居中叠加',
        cameraAngle: '眼平中景，水平视线',
        lightingMood: '柔和自然侧光，石墙明暗适中',
        colorPalette: '暖灰褐石墙为底，搭配深棕皮、彩色条纹与黑白软包',
        visualFocus: '白色阔腿裤、条纹衬衫、黑色皮质手提包',
        cameraNotes: '右手自然垂挂手提包对应的动作细节',
        transitionHint: '黑色皮质手提包掠过后切入下一镜',
        movementTrend: '彩色条纹与黑色软质手提包向画面左侧移动',
        actionStage: '白色阔腿裤和条纹衬衫进入展示阶段',
        sound: '黑色软质手提包、金属门锁产生的轻微接触声',
      ),
    );
    final now = DateTime.now().toUtc();
    workflowRepository.upsertAnalysis(
      ScriptShotAnalysisRecord(
        id: 'analysis-${shot.id}',
        shotId: shot.id,
        model: 'test-vlm',
        status: ProcessingStatus.completed,
        fieldSources: const {'content': 'model'},
        fieldConfidence: const {'content': 0.9},
        promptContext: const ScriptShotPromptContext(
          subject: {'people': '身穿白色阔腿裤和条纹衬衫的女模特', 'props': '黑色皮质手提包'},
          action: {'bodyAction': '抬手展示新品背包'},
          scene: {
            'subjectDirection': '身体面向画面右侧',
            'spatialRelation': '人物位于石墙前，背包位于身体右侧',
          },
          continuity: {'narrativeFunction': '广告产品记忆点'},
        ),
        promptContextSchemaVersion: 2,
        sourceImageFingerprint: 'sha256:replicated-frame',
        analysisRuleVersion: 2,
        rawResponse: '{}',
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final productSource = File('${root.path}/product.png');
    final productImage = img.Image(width: 8, height: 8);
    img.fill(productImage, color: img.ColorRgb8(20, 20, 20));
    await productSource.writeAsBytes(img.encodePng(productImage), flush: true);
    final product = await controller.importAsset(
      sourcePath: productSource.path,
      type: ReplicateAssetType.product,
      name: '新品背包',
      description: '纯黑通勤双肩包',
    );
    expect(product, isNotNull);
    final replicatedSource = File('${root.path}/replicated.png');
    final replicatedImage = img.Image(width: 8, height: 8);
    img.fill(replicatedImage, color: img.ColorRgb8(40, 80, 120));
    await replicatedSource.writeAsBytes(
      img.encodePng(replicatedImage),
      flush: true,
    );
    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: '${controller.value.run!.id}-replicated-${shot.id}',
        runId: controller.value.run!.id,
        scriptShotId: shot.id,
        shotNumber: shot.shotNumber,
        originalFramePath: '',
        generatedFramePath: replicatedSource.path,
        assetIds: [product!.id],
        prompt: '复刻分镜图生成提示词',
        model: 'test',
        rawResponse: '{}',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    controller.refresh();
    expect(controller.structuredPromptContextReadyCount, 1);
    expect(controller.structuredPromptContextMissingCount, 0);

    await controller.selectH3PromptStyle('minimalist-product-ad');

    await controller.composeAllPrompts();

    final generated = controller.value.prompts.single;
    expect(controller.promptFormatFor(generated), ShotPromptFormat.h3);
    expect(
      visionService.completionPrompts,
      isEmpty,
      reason: '合成阶段不得再次调用视觉模型分析图片或重写故事',
    );
    for (final format in ShotPromptFormat.values) {
      final text = controller.promptTextFor(generated, format);
      expect(text, isNot(contains('白色阔腿裤')));
      expect(text, isNot(contains('条纹衬衫')));
      expect(text, isNot(contains('黑色皮质手提包')));
      expect(text, isNot(contains('黑色软质手提包')));
      expect(text, isNot(contains('彩色条纹')));
      expect(text, isNot(contains('YERAD')));
      expect(text, contains('身体面向画面右侧'));
      expect(text, contains('人物位于石墙前'));
      if (format == ShotPromptFormat.sd2) {
        expect(text, contains('广告产品记忆点'));
      } else {
        expect(text, isNot(contains('广告产品记忆点')));
      }
    }
    expect(
      controller.promptTextFor(generated, ShotPromptFormat.kling),
      contains('中部偏右'),
    );
    final h3Prompt = controller.promptTextFor(generated, ShotPromptFormat.h3);
    expect(h3Prompt, isNot(contains('<think>')));
    expect(h3Prompt, startsWith('【参考素材说明】'));
    expect(_occurrences(h3Prompt, '【画面过程描述】'), 1);
    expect(_occurrences(h3Prompt, '【镜头叙事风格】'), 1);
    expect(_occurrences(h3Prompt, '【声音设计】'), 0);
    expect(_occurrences(h3Prompt, '非叙事性音乐：'), 1);
    expect(h3Prompt, contains('新品背包'));
    expect(h3Prompt, isNot(contains('new backpack')));
    expect(h3Prompt, isNot(contains('身穿和的')));
    expect(h3Prompt, isNot(contains('广告产品记忆点')));
    expect(h3Prompt, contains('产品本体颜色'));
    expect(h3Prompt, contains('3–5 个英文词'));
    final raw = jsonDecode(generated.rawResponse) as Map;
    expect(raw['promptSource'], 'localStructuredAssembler');
    expect(raw['assemblyMode'], 'concatenateConfirmedScriptFields');
    expect(raw['analysisStage'], 'buildScript');
    expect(raw['visionModelCalls'], 0);
    expect(raw['h3PromptStyleId'], 'minimalist-product-ad');
    expect(raw.containsKey('visionPromptSynthesis'), isFalse);

    await controller.selectH3PromptStyle('brand-promo');

    expect(
      controller.value.prompts,
      hasLength(1),
      reason: 'H3 风格变化后保留上一次提示词，状态标记为待重新合成',
    );
    expect(settingsRepository.load().h3PromptStyleId, 'brand-promo');
    await controller.composeAllPrompts();
    final brandPrompt = controller.value.prompts.single;
    final brandPromptText = controller.promptTextFor(
      brandPrompt,
      ShotPromptFormat.h3,
    );
    final brandPromptRaw = jsonDecode(brandPrompt.rawResponse) as Map;
    expect(brandPromptRaw['h3PromptStyleId'], 'brand-promo');
    expect(visionService.completionPrompts, isEmpty);
    expect(brandPromptText, contains('场景/意图'));
    expect(brandPromptText, contains('不虚构任何功能'));
    expect(brandPromptText, isNot(contains('3–5 个英文词')));
    expect(brandPromptText, isNot(h3Prompt));

    final storedAnalysis = workflowRepository.getAnalysis(shot.id)!;
    workflowRepository.upsertAnalysis(
      storedAnalysis.copyWith(
        promptContext: const ScriptShotPromptContext(
          subject: {'people': '女模特'},
          action: {'bodyAction': '转身展示新品背包侧面'},
          scene: {
            'subjectDirection': '身体面向画面左侧',
            'spatialRelation': '人物位于石墙前，背包位于身体左侧',
          },
          continuity: {'narrativeFunction': '突出背包侧面轮廓'},
        ),
        sourceImageFingerprint: 'sha256:updated-replicated-frame',
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    controller.refresh();

    expect(
      controller.value.prompts,
      hasLength(1),
      reason: '结构化解析上下文变化后保留上一次提示词',
    );
    expect(
      controller.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
    );

    await controller.composeAllPrompts();
    final refreshedPrompt = controller.value.prompts.single;
    expect(
      controller.promptTextFor(refreshedPrompt, ShotPromptFormat.h3),
      contains('面向画面左侧'),
    );

    await controller.regeneratePrompt(refreshedPrompt.id);
    final regeneratedPrompt = controller.value.prompts.single;
    expect(
      controller.promptTextFor(regeneratedPrompt, ShotPromptFormat.h3),
      startsWith('【参考素材说明】'),
      reason: '单条重新生成也必须只拼接本地结构化字段',
    );
    final regeneratedRaw = jsonDecode(regeneratedPrompt.rawResponse) as Map;
    expect(regeneratedRaw['visionModelCalls'], 0);
    expect(visionService.completionPrompts, isEmpty);

    controller.updateAsset(product.copyWith(description: '哑光黑硬挺通勤双肩包'));
    controller.refresh();

    expect(controller.value.prompts, hasLength(1), reason: '素材描述变化后保留上一次提示词');
  });

  test('50 个 H3 镜头零视觉调用并保持顺序与纯本地拼接性能', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_prompt_concurrency_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load().copyWith(
        videoGenerationApiConfigs: const [
          VideoGenerationApiConfig(
            id: 'test-h3',
            name: '测试 H3',
            kind: VideoGenerationApiConfigKind.httpApi,
            baseUrl: 'http://127.0.0.1:7860',
            apiKey: '',
            model: 'minimax-h3-local',
          ),
        ],
        activeVideoGenerationApiConfigId: 'test-h3',
      ),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final replicateRepository = ReplicateRepository(database);
    final visionService = _RecordingVisionStoryboardService();
    final controller = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    shootingController.createEmpty(name: '本地批量合成脚本');
    final shots = <ScriptShot>[];
    for (var index = 0; index < 50; index++) {
      final shot = shootingController.addShot()!;
      shootingController.updateShot(
        shot.copyWith(
          durationSeconds: 3,
          content: '镜头 ${index + 1}',
          cameraMovement: '固定',
        ),
      );
      shots.add(shootingController.value.shots.last);
    }
    for (final shot in shots) {
      final imageFile = File('${root.path}/replicated-${shot.shotNumber}.png')
        ..writeAsBytesSync([137, 80, 78, 71, shot.shotNumber]);
      replicateRepository.upsertReplicatedShotImage(
        ReplicatedShotImage(
          id: '${controller.value.run!.id}-replicated-${shot.id}',
          runId: controller.value.run!.id,
          scriptShotId: shot.id,
          shotNumber: shot.shotNumber,
          originalFramePath: '',
          generatedFramePath: imageFile.path,
          assetIds: const [],
          prompt: '复刻分镜图生成提示词',
          model: 'test',
          rawResponse: '{}',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
    controller.refresh();
    expect(
      controller.replicatedImageRecoveryScanCount,
      0,
      reason: '所有已记录路径都有效时不得扫描 generated_images',
    );

    final stopwatch = Stopwatch()..start();
    await controller.composeAllPrompts(maxConcurrent: 2);
    stopwatch.stop();

    expect(visionService.completionPrompts, isEmpty);
    expect(visionService.maxActiveCompletions, 0);
    expect(
      controller.value.prompts.map((prompt) => prompt.shotNumber),
      List.generate(50, (index) => index + 1),
    );
    expect(controller.value.run!.completedCount, 50);
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: '纯本地结构化编译 50 个镜头应在 3 秒内完成',
    );
    expect(controller.value.message, contains('MiniMax H3'));
    expect(controller.value.message, contains('拼接 50 个'));
    expect(controller.value.message, contains('视觉模型 0 次'));
    final raw = jsonDecode(controller.value.prompts.first.rawResponse) as Map;
    expect(raw['promptSource'], 'localStructuredAssembler');
    expect(raw['assemblyMode'], 'concatenateConfirmedScriptFields');
    expect(raw['visionModelCalls'], 0);
    expect(raw['videoModelPromptRule'], {
      'format': ShotPromptFormat.h3.name,
      'label': 'MiniMax H3',
    });

    final missingImage = controller.value.replicatedImages.first;
    final missingFile = File(missingImage.generatedFramePath);
    final recoveredFile = File(
      p.join(
        directories.generatedImages.path,
        'recovery',
        p.basename(missingFile.path),
      ),
    );
    await recoveredFile.parent.create(recursive: true);
    await missingFile.rename(recoveredFile.path);
    controller.refresh();
    expect(controller.replicatedImageRecoveryScanCount, 1);
    expect(
      controller.value.replicatedImages.first.generatedFramePath,
      recoveredFile.path,
    );
  });

  test('错峰批量复刻按镜号提交原帧和新资产并持久化结果', () async {
    final root = await Directory.systemTemp.createTemp('replicate_images_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load().copyWith(
        imageGenerationModel: ImageGenerationCatalog.models.first.id,
        imageGenerationApiConfigs: const [],
        activeImageGenerationApiConfigId: '',
      ),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '批量复刻脚本');
    final frame1 = File('${root.path}/frame-1.png')
      ..writeAsBytesSync([137, 80, 78, 71, 1]);
    final frame2 = File('${root.path}/frame-2.png')
      ..writeAsBytesSync([137, 80, 78, 71, 2]);
    final first = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(framePath: frame1.path, content: '人物手持原产品'),
    );
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      second.copyWith(framePath: frame2.path, content: '人物转身展示产品'),
    );
    final character = File('${root.path}/new-character.png')
      ..writeAsBytesSync([137, 80, 78, 71, 3]);
    final product = File('${root.path}/new-product.png')
      ..writeAsBytesSync([137, 80, 78, 71, 4]);
    final unboundProp = File('${root.path}/unbound-prop.png')
      ..writeAsBytesSync([137, 80, 78, 71, 5]);
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final now = DateTime.now().toUtc();
    const characterAssetId = 'bound-character';
    const productAssetId = 'bound-product';
    const unboundPropAssetId = 'unbound-prop';
    for (final asset in [
      ScriptAsset(
        id: characterAssetId,
        scriptId: shootingController.value.selectedScriptId,
        type: ReplicateAssetType.character,
        name: '新模特',
        description: '短发、白衬衫',
        path: character.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptAsset(
        id: productAssetId,
        scriptId: shootingController.value.selectedScriptId,
        type: ReplicateAssetType.product,
        name: '新产品',
        description: '白色瓶身，蓝色标签',
        path: product.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptAsset(
        id: unboundPropAssetId,
        scriptId: shootingController.value.selectedScriptId,
        type: ReplicateAssetType.prop,
        name: '未绑定道具',
        description: '不应提交',
        path: unboundProp.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertScriptAsset(asset);
    }
    for (final link in [
      ScriptShotAssetLink(
        shotId: first.id,
        scriptAssetId: characterAssetId,
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '测试绑定模特',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: first.id,
        scriptAssetId: productAssetId,
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '测试绑定产品',
        confirmed: true,
        locked: true,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: second.id,
        scriptAssetId: productAssetId,
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '测试绑定产品特写',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertLink(link);
    }
    final imageService = _RecordingImageGenerationService();
    final visionService = _RecordingVisionStoryboardService();
    var controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
      imageGenerationService: imageService,
      visionService: visionService,
    );
    final generationModel = controller.resolvedGenerationModel;
    final generationDescriptor = ImageGenerationCatalog.descriptorFor(
      generationModel,
    )!;
    final generationAspectRatio =
        generationDescriptor.aspectRatios.contains('1:1')
        ? '1:1'
        : generationDescriptor.aspectRatios.last;
    final generationImageSize = ImageGenerationCatalog.resolutionsFor(
      generationModel,
      generationAspectRatio,
    ).last;
    final generationQuality = generationDescriptor.qualities.last;
    controller.updateGenerationDefaults(
      aspectRatio: generationAspectRatio,
      imageSize: generationImageSize,
      quality: generationQuality,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      imageService.close();
      database.dispose();
      await root.delete(recursive: true);
    });
    final firstRequestStarted = Completer<void>();
    final releaseRequests = Completer<void>();
    imageService
      ..requestStarted = firstRequestStarted
      ..requestGate = releaseRequests.future;
    final replicateFuture = controller.replicateAllShots(
      stagger: const Duration(milliseconds: 20),
      maxConcurrent: 2,
    );
    await firstRequestStarted.future;

    final activeMessage = controller.value.message;
    controller.refresh();
    expect(controller.value.isBusy, isTrue, reason: '脚本或页面同步刷新不能清除正在执行的一键复刻状态');
    expect(controller.value.message, activeMessage);

    releaseRequests.complete();
    await replicateFuture;
    imageService
      ..requestStarted = null
      ..requestGate = null;

    expect(imageService.requests, hasLength(2));
    expect(
      imageService.requests.every(
        (request) => request.aspectRatio == generationAspectRatio,
      ),
      isTrue,
    );
    expect(
      imageService.requests.every(
        (request) => request.imageSize == generationImageSize,
      ),
      isTrue,
    );
    expect(
      imageService.requests.every(
        (request) => request.quality == generationQuality,
      ),
      isTrue,
    );
    expect(imageService.requests[0].referenceImagePaths.first, frame1.path);
    expect(imageService.requests[1].referenceImagePaths.first, frame2.path);
    expect(imageService.requests[0].referenceImagePaths, [
      frame1.path,
      character.path,
      product.path,
    ]);
    expect(imageService.requests[1].referenceImagePaths, [
      frame2.path,
      product.path,
    ]);
    expect(
      imageService.requests[0].referenceImagePaths,
      isNot(contains(unboundProp.path)),
    );
    expect(imageService.requests[0].prompt, contains('图片1'));
    expect(imageService.requests[0].prompt, contains('替换'));
    expect(visionService.analyzeCount, 2);
    expect(imageService.requests[0].prompt, contains('【视觉模型对原帧的结构维度解析】'));
    expect(imageService.requests[0].prompt, isNot(contains('女模特在窗边展示产品')));
    expect(imageService.requests[0].prompt, isNot(contains('蓝色包装瓶')));
    expect(imageService.requests[0].prompt, isNot(contains('叙事画面')));
    expect(imageService.requests[0].prompt, isNot(contains('画面细节')));
    expect(imageService.requests[0].prompt, contains('【Gemini 3 分镜图像指令】'));
    expect(imageService.requests[0].prompt, contains('图片1是本镜头唯一的构图母版'));
    expect(
      imageService.requests[0].prompt,
      contains('屏幕方向硬约束：以查看图片1时的画面左/右为唯一坐标系'),
    );
    expect(
      imageService.requests[0].prompt,
      contains('严禁水平镜像、左右颠倒、反向朝向或交换左右侧构图'),
    );
    expect(imageService.requests[0].prompt, contains('色彩锁定硬约束：以图片1可见的色彩风格'));
    expect(
      imageService.requests[0].prompt,
      contains('严禁根据图片2起的资产图、资产文字、镜头色彩字段'),
    );
    expect(imageService.requests[0].prompt, contains('产品主体必须清晰可辨'));
    expect(imageService.requests[0].prompt, contains('画面文字与标识零容忍硬约束'));
    expect(imageService.requests[0].prompt, contains('默认输出必须是纯净无字画面'));
    expect(imageService.requests[0].prompt, contains('底部字幕'));
    expect(imageService.requests[0].prompt, contains('严禁复制、临摹、变体重绘、替换或新增'));
    expect(
      imageService.requests[0].prompt,
      contains('所有文字、Logo、商标及可识别品牌标记必须移除'),
    );
    expect(imageService.requests[0].prompt, isNot(contains('额外 Logo 或无关文字')));
    expect(
      imageService.requests[0].prompt,
      endsWith('若用户已明确给出，只允许该段指定文本，其他文字与标识一律禁止。'),
    );
    expect(imageService.requests[0].prompt, contains('严禁复用其身份或外观'));
    expect(imageService.requests[0].prompt, contains('绑定资产硬约束'));
    expect(imageService.requests[1].prompt, isNot(contains('人物必须使用图片2')));
    expect(imageService.requests[0].prompt, isNot(contains('不要机械拼贴或照抄参考图版式')));
    expect(controller.value.replicatedImages, hasLength(2));
    expect(
      controller.value.replicatedImages.map((image) => image.status).toSet(),
      {ProcessingStatus.completed},
    );
    expect(
      controller.value.replicatedImages.every(
        (image) => File(image.generatedFramePath).existsSync(),
      ),
      isTrue,
    );
    expect(
      controller.value.replicatedImages.every(
        (image) => image.generatedFramePath.startsWith(
          directories.generatedImages.absolute.path,
        ),
      ),
      isTrue,
      reason: '复刻图必须写入工程的 generated_images 持久目录',
    );
    expect(
      controller.value.replicatedImages.every(
        (image) => File(image.generatedFramePath).existsSync(),
      ),
      isTrue,
    );

    final releaseManualRequests = Completer<void>();
    final firstManualRequestStarted = Completer<void>();
    imageService
      ..requestStarted = firstManualRequestStarted
      ..requestGate = releaseManualRequests.future;
    final firstManualFuture = controller.replicateShot(first.id);
    await firstManualRequestStarted.future;

    final secondManualRequestStarted = Completer<void>();
    imageService.requestStarted = secondManualRequestStarted;
    final secondManualFuture = controller.replicateShot(second.id);
    await Future.any([secondManualRequestStarted.future, secondManualFuture]);
    expect(
      secondManualRequestStarted.isCompleted,
      isTrue,
      reason: '首个手动复刻仍在运行时，第二个镜头必须立即提交到 API',
    );
    expect(controller.value.isBusy, isTrue);

    releaseManualRequests.complete();
    expect(await firstManualFuture, isTrue);
    expect(await secondManualFuture, isTrue);
    imageService
      ..requestStarted = null
      ..requestGate = null;
    expect(controller.value.isBusy, isFalse);

    visionService.resolvedPrompt = '清理后的最终提示词：使用新模特，不出现原人物的耳环、眼镜和帽子。';
    final firstShotForInstructions = shootingController.value.shots.firstWhere(
      (item) => item.id == first.id,
    );
    controller.updateShot(
      firstShotForInstructions.copyWith(
        replicationInstructions: '移除原人物的耳环、眼镜和帽子',
      ),
    );
    expect(
      controller.value.shots
          .firstWhere((item) => item.id == first.id)
          .replicationInstructions,
      '移除原人物的耳环、眼镜和帽子',
    );
    final instructedReplicateResult = await controller.replicateShot(first.id);
    expect(
      instructedReplicateResult,
      isTrue,
      reason: controller.value.errorMessage,
    );
    expect(visionService.completionPrompts, hasLength(1));
    expect(visionService.completionPrompts.single, contains('最高优先级'));
    expect(
      visionService.completionPrompts.single,
      contains('必须完整保留自动提示词中的“画面文字与标识零容忍硬约束”'),
    );
    expect(
      imageService.requests.last.prompt,
      startsWith(visionService.resolvedPrompt),
    );
    expect(imageService.requests.last.prompt, contains('【最终输出复核】'));
    expect(
      imageService.requests.last.prompt,
      endsWith('若用户已明确给出，只允许该段指定文本，其他文字与标识一律禁止。'),
    );

    visionService.resolvedPrompt = '使用新模特，画面标题仅写“夏日新品”。';
    final textSpecifiedShot = shootingController.value.shots.firstWhere(
      (item) => item.id == first.id,
    );
    controller.updateShot(
      textSpecifiedShot.copyWith(replicationInstructions: '在画面顶部写“夏日新品”'),
    );
    expect(await controller.replicateShot(first.id), isTrue);
    expect(visionService.completionPrompts.last, contains('在画面顶部写“夏日新品”'));
    expect(imageService.requests.last.prompt, contains('画面标题仅写“夏日新品”'));
    expect(
      imageService.requests.last.prompt,
      endsWith('若用户已明确给出，只允许该段指定文本，其他文字与标识一律禁止。'),
      reason: '用户指定文本时只开放该段文本，参考图中的其他文字与 Logo 仍必须禁止',
    );

    controller.dispose();
    controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      imageGenerationService: imageService,
    );
    expect(controller.value.replicatedImages, hasLength(2));
    expect(controller.value.replicatedImages.map((image) => image.shotNumber), [
      1,
      2,
    ]);
  });

  test('不同脚本的一键复刻互不阻塞', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_script_isolation_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load().copyWith(
        imageGenerationModel: ImageGenerationCatalog.models.first.id,
        imageGenerationApiConfigs: const [],
        activeImageGenerationApiConfigId: '',
      ),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final imageService = _RecordingImageGenerationService();
    final visionService = _RecordingVisionStoryboardService();
    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
      imageGenerationService: imageService,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      imageService.close();
      database.dispose();
      await root.delete(recursive: true);
    });

    final scriptA = shootingController.createEmpty(name: 'A 脚本');
    final frameA = File('${root.path}/frame-a.png')
      ..writeAsBytesSync([137, 80, 78, 71, 10]);
    final shotA = shootingController.addShot()!;
    shootingController.updateShot(
      shotA.copyWith(framePath: frameA.path, content: 'A 脚本镜头'),
    );
    final scriptB = shootingController.createEmpty(name: 'B 脚本');
    final frameB = File('${root.path}/frame-b.png')
      ..writeAsBytesSync([137, 80, 78, 71, 11]);
    final shotB = shootingController.addShot()!;
    shootingController.updateShot(
      shotB.copyWith(framePath: frameB.path, content: 'B 脚本镜头'),
    );

    final now = DateTime.now().toUtc();
    void bindAsset({
      required String scriptId,
      required String shotId,
      required String assetId,
      required String path,
    }) {
      workflowRepository.upsertScriptAsset(
        ScriptAsset(
          id: assetId,
          scriptId: scriptId,
          type: ReplicateAssetType.product,
          name: '替换产品 $assetId',
          description: '蓝色包装',
          path: path,
          referenceNumber: 1,
          status: ProcessingStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      );
      workflowRepository.upsertLink(
        ScriptShotAssetLink(
          shotId: shotId,
          scriptAssetId: assetId,
          matchSource: ScriptAssetMatchSource.manual,
          confidence: 1,
          matchReason: '测试绑定',
          confirmed: true,
          locked: true,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    final assetA = File('${root.path}/asset-a.png')
      ..writeAsBytesSync([137, 80, 78, 71, 12]);
    final assetB = File('${root.path}/asset-b.png')
      ..writeAsBytesSync([137, 80, 78, 71, 13]);
    bindAsset(
      scriptId: scriptA.id,
      shotId: shotA.id,
      assetId: 'asset-a',
      path: assetA.path,
    );
    bindAsset(
      scriptId: scriptB.id,
      shotId: shotB.id,
      assetId: 'asset-b',
      path: assetB.path,
    );

    controller.selectScript(scriptA.id);
    final runAId = controller.value.run!.id;
    final firstRequestStarted = Completer<void>();
    final releaseRequests = Completer<void>();
    imageService
      ..requestStarted = firstRequestStarted
      ..requestGate = releaseRequests.future;
    final replicateAFuture = controller.replicateAllShots(
      stagger: Duration.zero,
      maxConcurrent: 1,
    );
    await firstRequestStarted.future;
    expect(controller.value.isBusy, isTrue);
    expect(imageService.requests, hasLength(1));

    final secondRequestStarted = Completer<void>();
    imageService.requestStarted = secondRequestStarted;
    controller.selectScript(scriptB.id);
    final runBId = controller.value.run!.id;
    expect(controller.value.selectedScriptId, scriptB.id);
    expect(
      controller.value.isBusy,
      isFalse,
      reason: '切换到未运行的一键复刻脚本后不应继承 A 脚本 busy 状态',
    );

    final replicateBFuture = controller.replicateAllShots(
      stagger: Duration.zero,
      maxConcurrent: 1,
    );
    await secondRequestStarted.future;
    expect(imageService.requests, hasLength(2));
    expect(imageService.requests[0].referenceImagePaths.first, frameA.path);
    expect(imageService.requests[1].referenceImagePaths.first, frameB.path);
    expect(controller.value.isBusy, isTrue);

    releaseRequests.complete();
    await Future.wait([replicateAFuture, replicateBFuture]);
    imageService
      ..requestStarted = null
      ..requestGate = null;

    final repository = ReplicateRepository(database);
    expect(repository.listReplicatedShotImages(runAId), hasLength(1));
    expect(repository.listReplicatedShotImages(runBId), hasLength(1));
    expect(controller.value.selectedScriptId, scriptB.id);
    expect(controller.value.isBusy, isFalse);
  });

  test('自由创作剧情描述、全局故事和手改标记按任务持久化', () async {
    final root = await Directory.systemTemp.createTemp('free-creation-data-');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '自由创作脚本');
    final shot = shootingController.addShot()!;
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    database.executeStatement(
      'INSERT INTO storyboard_tasks(id, name, created_at, updated_at) '
      'VALUES(?, ?, ?, ?);',
      ['free-task', '自由创作故事板', now, now],
    );
    database.executeStatement(
      'INSERT INTO storyboard_boards('
      'id, task_id, name, width, height, columns, gap, created_at, updated_at'
      ') VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);',
      ['free-board', 'free-task', '画板', 1920, 1080, 1, 12, now, now],
    );
    database.executeStatement(
      'INSERT INTO vision_analysis_runs('
      'id, board_id, model, status, total_images, success_count, '
      'error_message, created_at, updated_at'
      ') VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'free-summary-run',
        'free-board',
        'test',
        'completed',
        1,
        1,
        '',
        now,
        now,
      ],
    );
    database.upsertStoryboardSummary(
      boardId: 'free-board',
      runId: 'free-summary-run',
      outline: '人物进入咖啡馆并拿起产品。',
      content: '镜头最后停在产品特写。',
      scenes: '暖色咖啡馆',
      props: '产品瓶',
      rawResponse: '{}',
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    controller.setFreeCreationEnabled(true);
    expect(controller.automaticFreeCreationStory, contains('人物进入咖啡馆'));
    expect(controller.effectiveFreeCreationStory, contains('产品特写'));
    expect(controller.validateFreeCreationDescriptions(), isTrue);
    expect(controller.missingFreeCreationDescriptionShotIds, [shot.id]);

    controller.updateFreeCreationDescription(shot.id, '人物快速拿起产品并停顿展示');
    controller.updateFreeCreationStoryOverride('人物在咖啡馆中完成产品介绍。');
    expect(controller.validateFreeCreationDescriptions(), isTrue);
    expect(
      ShootingScriptRepository(database)
          .listShots(shootingController.value.selectedScriptId)
          .single
          .freeCreationDescription,
      '人物快速拿起产品并停顿展示',
    );
    expect(
      repository.getRun(controller.value.run!.id)?.freeCreationStoryOverride,
      '人物在咖啡馆中完成产品介绍。',
    );

    final prompt = ShotPrompt(
      id: 'free-prompt',
      runId: controller.value.run!.id,
      scriptShotId: shot.id,
      shotNumber: shot.shotNumber,
      assetIds: const [],
      prompt: '初始提示词',
      model: 'MiniMax H3',
      rawResponse: '{}',
      status: ProcessingStatus.completed,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
    );
    repository.upsertPrompt(prompt);
    controller.refresh();
    controller.selectPromptFormatForAll(ShotPromptFormat.kling);
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.sd2,
      reason: '缺少目标模型原生版本时不得从其他模型文本自动派生',
    );
    expect(controller.value.prompts.single.prompt, '初始提示词');
    controller.updatePromptText(prompt.id, '用户修改后的六字段提示词');
    expect(
      repository.listPrompts(controller.value.run!.id).single.isUserEdited,
      isTrue,
    );

    controller.updateFreeCreationStoryOverride('');
    expect(controller.value.run!.freeCreationStoryOverride, isEmpty);
    expect(controller.effectiveFreeCreationStory, contains('暖色咖啡馆'));
  });

  test('自由创作仅使用参考图用户描述和技能并保持手改保护', () async {
    final root = await Directory.systemTemp.createTemp('free-creation-build-');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
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
    )..createEmpty(name: '自由创作整体理解');
    final firstFrame = await File(
      '${root.path}/frame-1.png',
    ).writeAsBytes([137, 80, 78, 71, 1]);
    final secondFrame = await File(
      '${root.path}/frame-2.png',
    ).writeAsBytes([137, 80, 78, 71, 2]);
    final productFile = await File(
      '${root.path}/product.png',
    ).writeAsBytes([137, 80, 78, 71, 3]);
    final first = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(
        sourceStoryboardAssetId: 'free-cut-1',
        framePath: firstFrame.path,
        freeCreationDescription: '品牌宣传短片：先快速推近人物手中产品，再减速停在瓶身细节',
        composition: '绝不能进入请求的旧构图',
        cameraNotes: '绝不能进入请求的旧摄影备注',
        continuesToNext: true,
      ),
    );
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      second.copyWith(
        sourceStoryboardAssetId: 'free-cut-2',
        framePath: secondFrame.path,
        continuesFromPrevious: true,
      ),
    );

    final now = DateTime.now().toUtc();
    final nowText = now.toIso8601String();
    database.executeStatement(
      'INSERT INTO imported_images('
      'id, original_path, original_name, stored_path, width, height, created_at'
      ') VALUES(?, ?, ?, ?, ?, ?, ?);',
      [
        'free-image',
        firstFrame.path,
        'frames.png',
        firstFrame.path,
        1920,
        1080,
        nowText,
      ],
    );
    database.executeStatement(
      'INSERT INTO cut_tasks('
      'id, image_id, status, rows, columns, confidence, created_at, updated_at'
      ') VALUES(?, ?, ?, ?, ?, ?, ?, ?);',
      ['free-cut-task', 'free-image', 'completed', 1, 2, 1.0, nowText, nowText],
    );
    for (final entry in [
      ('free-cut-1', firstFrame.path, 1),
      ('free-cut-2', secondFrame.path, 2),
    ]) {
      database.executeStatement(
        'INSERT INTO cut_results('
        'id, task_id, image_id, index_no, path, x, y, width, height, '
        'selected, created_at'
        ') VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          entry.$1,
          'free-cut-task',
          'free-image',
          entry.$3,
          entry.$2,
          0,
          0,
          960,
          1080,
          1,
          nowText,
        ],
      );
    }
    database.executeStatement(
      'INSERT INTO storyboard_tasks(id, name, created_at, updated_at) '
      'VALUES(?, ?, ?, ?);',
      ['free-build-task', '自由故事板', nowText, nowText],
    );
    database.executeStatement(
      'INSERT INTO storyboard_boards('
      'id, task_id, name, width, height, columns, gap, created_at, updated_at'
      ') VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'free-build-board',
        'free-build-task',
        '分镜',
        1920,
        1080,
        2,
        12,
        nowText,
        nowText,
      ],
    );
    for (final entry in [
      ('free-item-1', 'free-cut-1', 0, '人物从画面左侧拿起白色瓶子'),
      ('free-item-2', 'free-cut-2', 1, '白色瓶子进入中心特写并稳定停顿'),
    ]) {
      database.executeStatement(
        'INSERT INTO storyboard_items('
        'id, board_id, cut_result_id, position, caption, created_at'
        ') VALUES(?, ?, ?, ?, ?, ?);',
        [entry.$1, 'free-build-board', entry.$2, entry.$3, entry.$4, nowText],
      );
    }

    final workflowRepository = ShootingScriptWorkflowRepository(database);
    workflowRepository.upsertScriptAsset(
      ScriptAsset(
        id: 'free-product',
        scriptId: shootingController.value.selectedScriptId,
        type: ReplicateAssetType.product,
        name: '无字白色瓶子',
        description: '锁定哑光材质和细长比例',
        path: productFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    workflowRepository.upsertLink(
      ScriptShotAssetLink(
        shotId: first.id,
        scriptAssetId: 'free-product',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '用户确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final visionService = _RecordingVisionStoryboardService()
      ..completionResponses.addAll([
        _splitFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 7),
        _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 7),
      ]);
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    controller.setFreeCreationEnabled(true);
    controller.updateFreeCreationStoryOverride('人物在室内完成一次从动作到产品特写的连续展示。');
    controller.updatePromptRules(
      globalStyle: '绝不应进入自由请求的全局风格',
      constraints: '绝不应进入自由请求的制作边界',
    );
    controller.updateReplicationInstructions('绝不应进入自由请求的任务补充');

    final succeeded = await controller.buildFreeCreationPrompts(
      maxConcurrent: 1,
    );

    expect(
      succeeded,
      isTrue,
      reason: [
        controller.value.errorMessage,
        for (final prompt in controller.value.prompts) prompt.errorMessage,
      ].where((message) => message.isNotEmpty).join('；'),
    );
    expect(visionService.analyzeCount, 0);
    expect(visionService.completionPrompts, hasLength(2));
    expect(
      visionService.completionResponseTimeouts,
      everyElement(ReplicateController.freeCreationVisionRequestTimeout),
    );
    expect(visionService.completionCompressOversizedImages, everyElement(true));
    expect(
      visionService.completionImagePaths,
      everyElement([firstFrame.path, secondFrame.path]),
    );
    final firstRequest = visionService.completionPrompts.first;
    expect(firstRequest, contains('先快速推近人物手中产品'));
    expect(firstRequest, contains('当前目标镜头结构：单一连续镜头（最高优先级）'));
    expect(firstRequest, contains('同一物理连续镜头按时间顺序抽取的第 1 个动作阶段帧'));
    expect(firstRequest, contains('只允许一个 [Shot 1]，不得产生切镜或 [Shot 2+]'));
    expect(firstRequest, contains('播放速度规则（最高优先级）'));
    expect(firstRequest, contains('缓慢推近/平稳跟随/末段缓停'));
    expect(firstRequest, contains('<official_skill_file'));
    expect(firstRequest, isNot(contains('人物从画面左侧拿起白色瓶子')));
    expect(firstRequest, isNot(contains('白色瓶子进入中心特写')));
    expect(firstRequest, isNot(contains('室内完成一次从动作到产品特写')));
    expect(firstRequest, isNot(contains('无字白色瓶子')));
    expect(firstRequest, isNot(contains('锁定哑光材质和细长比例')));
    expect(firstRequest, isNot(contains('绝不应进入自由请求的全局风格')));
    expect(firstRequest, isNot(contains('绝不应进入自由请求的制作边界')));
    expect(firstRequest, isNot(contains('绝不应进入自由请求的任务补充')));
    expect(firstRequest, isNot(contains('绝不能进入请求的旧构图')));
    expect(firstRequest, isNot(contains('绝不能进入请求的旧摄影备注')));
    expect(visionService.completionPrompts.last, contains('这是唯一一次格式修复'));
    expect(
      visionService.completionPrompts.last,
      contains('单一连续镜头模式只允许 [Shot 1]'),
    );

    final prompt = controller.value.prompts.single;
    expect(prompt.status, ProcessingStatus.completed);
    expect(controller.promptFormatFor(prompt), ShotPromptFormat.h3);
    expect(prompt.prompt, startsWith('subject_definitions:'));
    expect(prompt.prompt, contains('7秒视频'));
    expect(prompt.isUserEdited, isFalse);
    expect(shootingController.value.shots.last.durationSeconds, 7);
    final raw = jsonDecode(prompt.rawResponse) as Map<String, dynamic>;
    expect(raw['h3Prompt'], startsWith('subject_definitions:'));
    expect(raw['klingPrompt'], isEmpty);
    expect(raw['sd2Prompt'], isEmpty);
    expect(raw['promptSource'], 'freeCreationReferenceVision');
    expect(raw['h3PromptStyleId'], 'brand-promo');
    expect(raw['videoSkillBackend'], 'minimaxH3');
    expect(raw['videoSkillAutomaticallySelected'], isTrue);
    expect(raw['formatRepairCount'], 1);
    expect(raw['referenceImagePaths'], [firstFrame.path, secondFrame.path]);
    expect(raw['shotStructureMode'], 'singleContinuousShot');
    expect(raw['slowMotionAuthorized'], isFalse);
    expect(
      raw['freeCreationContextMode'],
      'referenceImagesOptionalUserDescriptionAndSkill',
    );
    expect(raw['storyContextIncluded'], isFalse);
    expect(raw['linkedAssetImagesIncluded'], isFalse);
    expect(prompt.assetIds, isEmpty);

    controller.selectPromptFormat(prompt.id, ShotPromptFormat.kling);
    expect(
      controller.value.prompts.single.prompt,
      startsWith('subject_definitions:'),
    );
    controller.selectPromptFormat(prompt.id, ShotPromptFormat.h3);
    expect(
      controller.value.prompts.single.prompt,
      startsWith('subject_definitions:'),
    );
    controller.selectPromptFormat(prompt.id, ShotPromptFormat.sd2);
    expect(
      controller.value.prompts.single.prompt,
      startsWith('subject_definitions:'),
    );
    controller.selectPromptFormatForAll(ShotPromptFormat.kling);
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.h3,
    );
    expect(
      controller.value.prompts.single.prompt,
      startsWith('subject_definitions:'),
    );
    controller.selectPromptFormatForAll(ShotPromptFormat.h3);
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.h3,
    );
    expect(
      controller.value.prompts.single.prompt,
      startsWith('subject_definitions:'),
    );

    controller.updateFreeCreationStoryOverride('这段新分镜故事也不应使自由创作提示词失效。');
    workflowRepository.upsertScriptAsset(
      ScriptAsset(
        id: 'free-product',
        scriptId: shootingController.value.selectedScriptId,
        type: ReplicateAssetType.product,
        name: '修改后的资产名称',
        description: '修改后的资产描述也不参与自由创作构建',
        path: productFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    controller.refresh();
    expect(
      controller.value.run!.composePromptsStatus,
      ProcessingStatus.completed,
      reason: '分镜故事和资产变化不再使自由创作提示词失效',
    );

    controller.updatePromptText(prompt.id, '${prompt.prompt}\n用户手动补充');
    final completionCountBeforeRebuild = visionService.completionPrompts.length;
    await controller.buildFreeCreationPrompts(maxConcurrent: 1);
    expect(
      visionService.completionPrompts,
      hasLength(completionCountBeforeRebuild),
    );
    expect(controller.value.prompts.single.isUserEdited, isTrue);
    expect(controller.value.prompts.single.prompt, endsWith('用户手动补充'));

    final manuallyEditedPrompt = controller.value.prompts.single.prompt;
    visionService.completionResponses.addAll(['第一次仍然不合格', '修复后仍然不合格']);
    await controller.regeneratePrompt(prompt.id);
    expect(
      visionService.completionPrompts,
      hasLength(completionCountBeforeRebuild + 2),
      reason: '格式错误只允许首次生成加一次修复',
    );
    expect(controller.value.prompts.single.status, ProcessingStatus.failed);
    expect(controller.value.prompts.single.prompt, manuallyEditedPrompt);
    expect(controller.value.prompts.single.isUserEdited, isTrue);
  });

  test('自由创作允许空描述自动分析且构建前可彻底清空旧提示词', () async {
    final root = await Directory.systemTemp.createTemp(
      'free-creation-empty-description-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '空描述自动构建');
    final frame = await File(
      '${root.path}${Platform.pathSeparator}empty-description-frame.png',
    ).writeAsBytes([137, 80, 78, 71, 1]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(shot.copyWith(framePath: frame.path));
    final visionService = _RecordingVisionStoryboardService()
      ..completionResponses.addAll([
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 5),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 6),
      ]);
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    controller.setFreeCreationEnabled(true);

    expect(await controller.buildFreeCreationPrompts(maxConcurrent: 1), isTrue);
    expect(visionService.completionPrompts.single, contains('用户未提供描述'));
    expect(controller.value.prompts.single.prompt, contains('5秒视频'));

    await settingsController.saveVideoGenerationApiConfig(
      const VideoGenerationApiConfig(
        id: 'empty-description-jimeng',
        name: '即梦',
        baseUrl: 'https://example.test',
        apiKey: 'test',
        model: 'Seedance 2.0',
      ),
    );
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.kling,
      reason: '切换模型时不得把既有可灵提示词冒充成即梦版本',
    );
    expect(controller.value.prompts.single.prompt, contains('图片1'));
    expect(shootingController.value.shots.single.prompt, contains('图片1'));
    expect(
      controller.value.run!.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '目标模型缺少原生提示词时必须要求重新构建',
    );

    controller.updatePromptText(
      controller.value.prompts.single.id,
      '${controller.value.prompts.single.prompt}\n上一次手工内容',
    );
    expect(shootingController.value.shots.single.prompt, contains('上一次手工内容'));

    controller.clearPromptsBeforeBuild();

    expect(controller.value.prompts, isEmpty);
    expect(repository.listPrompts(controller.value.run!.id), isEmpty);
    expect(shootingController.value.shots.single.prompt, isEmpty);
    expect(
      controller.value.run!.composePromptsStatus,
      ProcessingStatus.pending,
    );

    expect(await controller.buildFreeCreationPrompts(maxConcurrent: 1), isTrue);
    expect(controller.value.prompts.single.prompt, contains('6秒视频'));
    expect(controller.value.prompts.single.prompt, contains('@图片 1'));
    expect(
      controller.promptFormatFor(controller.value.prompts.single),
      ShotPromptFormat.sd2,
    );
    expect(controller.value.prompts.single.prompt, isNot(contains('上一次手工内容')));
  });

  test('自由创作局部解析只重建当前组并在复刻完整后整组切换图源', () async {
    final root = await Directory.systemTemp.createTemp(
      'free-creation-single-group-rebuild-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '局部解析图源切换');
    final originalFrames = <File>[];
    final replicaFrames = <File>[];
    for (var index = 1; index <= 3; index++) {
      originalFrames.add(
        await File(
          p.join(root.path, 'original-$index.png'),
        ).writeAsBytes([137, 80, 78, 71, index]),
      );
      replicaFrames.add(
        await File(
          p.join(root.path, 'replica-$index.png'),
        ).writeAsBytes([137, 80, 78, 71, index + 10]),
      );
    }
    final shots = [
      for (var index = 0; index < 3; index++) shootingController.addShot()!,
    ];
    for (var index = 0; index < shots.length; index++) {
      shootingController.updateShot(
        shots[index].copyWith(
          framePath: originalFrames[index].path,
          freeCreationDescription: '镜头 ${index + 1}',
        ),
      );
    }
    expect(
      shootingController.setContinuousShotRange(
        startShotId: shots[0].id,
        endShotId: shots[1].id,
      ),
      isTrue,
    );

    final visionService = _RecordingVisionStoryboardService()
      ..completionResponses.addAll([
        _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 5),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 4),
        _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 6),
        _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 7),
      ]);
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
      enforceFreeCreationMode: true,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    expect(await controller.buildFreeCreationPrompts(maxConcurrent: 1), isTrue);
    expect(visionService.completionImagePaths, [
      [originalFrames[0].path, originalFrames[1].path],
      [originalFrames[2].path],
    ]);
    final untouchedPrompt = controller.value.prompts.firstWhere(
      (prompt) => prompt.scriptShotId == shots[2].id,
    );
    final now = DateTime.now().toUtc();
    repository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'replica-${shots[0].id}',
        runId: controller.value.run!.id,
        scriptShotId: shots[0].id,
        shotNumber: shots[0].shotNumber,
        originalFramePath: originalFrames[0].path,
        generatedFramePath: replicaFrames[0].path,
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
    controller.refresh();

    expect(
      await controller.buildFreeCreationPrompts(
        maxConcurrent: 1,
        onlyShotIds: {shots[0].id},
        overwriteUserEdited: true,
      ),
      isTrue,
    );
    expect(visionService.completionImagePaths.last, [
      originalFrames[0].path,
      originalFrames[1].path,
    ], reason: '同一镜头组的复刻图不完整时不得混用复刻图和原视频帧');
    expect(
      controller.value.prompts
          .firstWhere((prompt) => prompt.scriptShotId == shots[2].id)
          .updatedAt,
      untouchedPrompt.updatedAt,
      reason: '局部解析不能重建其他镜头组',
    );

    repository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'replica-${shots[1].id}',
        runId: controller.value.run!.id,
        scriptShotId: shots[1].id,
        shotNumber: shots[1].shotNumber,
        originalFramePath: originalFrames[1].path,
        generatedFramePath: replicaFrames[1].path,
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
    controller.refresh();

    expect(
      await controller.buildFreeCreationPrompts(
        maxConcurrent: 1,
        onlyShotIds: {shots[0].id},
        overwriteUserEdited: true,
      ),
      isTrue,
    );
    expect(visionService.completionImagePaths.last, [
      replicaFrames[0].path,
      replicaFrames[1].path,
    ]);
    final rebuiltPrompt = controller.value.prompts.firstWhere(
      (prompt) => prompt.scriptShotId == shots[0].id,
    );
    expect(rebuiltPrompt.prompt, contains('7秒视频'));
    expect(shootingController.value.shots.first.prompt, rebuiltPrompt.prompt);
    final raw = jsonDecode(rebuiltPrompt.rawResponse) as Map<String, dynamic>;
    expect(raw['referenceImagePaths'], [
      replicaFrames[0].path,
      replicaFrames[1].path,
    ]);
  });

  test('自由创作镜头范围变化后不复用首次构建的手改提示词', () async {
    final root = await Directory.systemTemp.createTemp(
      'free-creation-range-rebuild-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '自由创作范围重建');
    final frames = <File>[];
    for (var index = 1; index <= 3; index++) {
      frames.add(
        await File(
          '${root.path}${Platform.pathSeparator}range-$index.png',
        ).writeAsBytes([137, 80, 78, 71, index]),
      );
    }
    final shots = [
      for (var index = 0; index < 3; index++) shootingController.addShot()!,
    ];
    for (var index = 0; index < shots.length; index++) {
      shootingController.updateShot(
        shots[index].copyWith(
          framePath: frames[index].path,
          freeCreationDescription: '镜头 ${index + 1} 的当前剧情描述',
        ),
      );
    }
    expect(
      shootingController.setContinuousShotRange(
        startShotId: shots.first.id,
        endShotId: shots.last.id,
      ),
      isTrue,
    );

    final visionService = _RecordingVisionStoryboardService()
      ..completionResponses.addAll([
        _validFreeCreationH3Prompt(pictureCount: 3, durationSeconds: 7),
        _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 6),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 4),
      ]);
    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    controller.setFreeCreationEnabled(true);

    expect(await controller.buildFreeCreationPrompts(maxConcurrent: 1), isTrue);
    expect(controller.value.prompts, hasLength(1));
    expect(visionService.completionImagePaths, [
      [frames[0].path, frames[1].path, frames[2].path],
    ]);
    final firstPrompt = controller.value.prompts.single;
    controller.updatePromptText(
      firstPrompt.id,
      '${firstPrompt.prompt}\n旧范围用户手改内容',
    );
    expect(controller.value.prompts.single.isUserEdited, isTrue);

    expect(
      shootingController.setContinuousShotRange(
        startShotId: shots.first.id,
        endShotId: shots[1].id,
      ),
      isTrue,
    );
    expect(await controller.buildFreeCreationPrompts(maxConcurrent: 1), isTrue);

    expect(visionService.completionImagePaths, [
      [frames[0].path, frames[1].path, frames[2].path],
      [frames[0].path, frames[1].path],
      [frames[2].path],
    ]);
    expect(controller.value.prompts, hasLength(2));
    final rebuiltFirst = controller.value.prompts.firstWhere(
      (prompt) => prompt.scriptShotId == shots.first.id,
    );
    expect(rebuiltFirst.isUserEdited, isFalse);
    expect(rebuiltFirst.prompt, isNot(contains('旧范围用户手改内容')));
    final raw = jsonDecode(rebuiltFirst.rawResponse) as Map<String, dynamic>;
    expect(raw['referenceImageCount'], 2);
    expect(raw['shotStructureMode'], 'singleContinuousShot');
    final singleReferencePrompt = controller.value.prompts.firstWhere(
      (prompt) => prompt.scriptShotId == shots[2].id,
    );
    expect(
      (jsonDecode(singleReferencePrompt.rawResponse)
          as Map<String, dynamic>)['shotStructureMode'],
      'singleReference',
    );

    visionService.completionResponses.add(
      _validFreeCreationH3Prompt(pictureCount: 2, durationSeconds: 8),
    );
    shootingController.updateShot(
      shootingController.value.shots.first.copyWith(
        freeCreationDescription: '第一个镜头低角度跟随攀爬，随后硬切到第二个镜头的脚部近景。',
      ),
    );
    controller.refresh();
    expect(
      await controller.buildFreeCreationPrompts(
        maxConcurrent: 1,
        onlyShotIds: {shots.first.id},
        overwriteUserEdited: true,
      ),
      isTrue,
    );
    expect(
      visionService.completionPrompts.last,
      contains('用户明确要求多镜头；按用户文字组织镜头'),
    );
    expect(
      visionService.completionPrompts.last,
      isNot(contains('当前目标镜头结构：单一连续镜头（最高优先级）')),
    );
    final explicitMultiPrompt = controller.value.prompts.firstWhere(
      (prompt) => prompt.scriptShotId == shots.first.id,
    );
    expect(
      (jsonDecode(explicitMultiPrompt.rawResponse)
          as Map<String, dynamic>)['shotStructureMode'],
      'explicitMultiShot',
    );
    final explicitRaw =
        jsonDecode(explicitMultiPrompt.rawResponse) as Map<String, dynamic>;
    expect(explicitRaw['klingPrompt'], contains('8秒视频'));
    expect(explicitRaw['h3Prompt'], isEmpty);
  });

  test('不同拍摄脚本可并行构建且切换后恢复各自运行态', () async {
    final root = await Directory.systemTemp.createTemp(
      'parallel-script-builds-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );

    ShootingScript createScript(String name, String marker) {
      final script = shootingController.createEmpty(name: name);
      final frame = File('${root.path}/$marker.png')
        ..writeAsBytesSync([137, 80, 78, 71, marker.codeUnitAt(0)]);
      final shot = shootingController.addShot()!;
      shootingController.updateShot(
        shot.copyWith(
          framePath: frame.path,
          freeCreationDescription: '$marker 脚本独立剧情',
        ),
      );
      return script;
    }

    final scriptA = createScript('A 脚本', 'A');
    final scriptB = createScript('B 脚本', 'B');
    final release = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final visionService = _RecordingVisionStoryboardService()
      ..firstCompletionStarted = firstStarted
      ..secondCompletionStarted = secondStarted
      ..completionGate = release.future
      ..completionResponses.addAll([
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 7),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 8),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 7),
        _validFreeCreationH3Prompt(pictureCount: 1, durationSeconds: 8),
      ]);
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    controller.selectScript(scriptA.id);
    controller.setFreeCreationEnabled(true);
    final runAId = controller.value.run!.id;
    final buildA = controller.buildFreeCreationPrompts(maxConcurrent: 1);
    await firstStarted.future;
    expect(controller.isBuildActiveFor(scriptA.id), isTrue);
    expect(controller.value.isBusy, isTrue);

    controller.selectScript(scriptB.id);
    controller.setFreeCreationEnabled(true);
    final runBId = controller.value.run!.id;
    expect(controller.value.isBusy, isFalse);
    final buildB = controller.buildFreeCreationPrompts(maxConcurrent: 1);
    await secondStarted.future;
    expect(controller.isBuildActiveFor(scriptB.id), isTrue);
    expect(controller.value.isBusy, isTrue);

    controller.selectScript(scriptA.id);
    expect(controller.value.isBusy, isTrue);
    expect(controller.value.run!.id, runAId);
    controller.selectScript(scriptB.id);
    expect(controller.value.isBusy, isTrue);
    expect(controller.value.run!.id, runBId);

    release.complete();
    final results = await Future.wait([buildA, buildB]);
    expect(
      results,
      everyElement(isTrue),
      reason:
          'A: ${repository.listPrompts(runAId).map((item) => item.errorMessage).join(' | ')}; '
          'B: ${repository.listPrompts(runBId).map((item) => item.errorMessage).join(' | ')}',
    );

    expect(repository.listPrompts(runAId), hasLength(1));
    expect(repository.listPrompts(runBId), hasLength(1));
    expect(controller.isBuildActiveFor(scriptA.id), isFalse);
    expect(controller.isBuildActiveFor(scriptB.id), isFalse);
    expect(controller.value.selectedScriptId, scriptB.id);
    expect(controller.value.prompts.single.runId, runBId);
    expect(controller.value.isBusy, isFalse);
  });

  test('确认镜头可按整组排序和移除并同步关联镜号', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate-shot-group-actions-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '镜头组操作');
    final shots = [
      for (var index = 0; index < 4; index++) shootingController.addShot()!,
    ];
    for (var index = 0; index < shots.length; index++) {
      shootingController.updateShot(
        shots[index].copyWith(content: '镜头 ${index + 1}'),
      );
    }
    expect(
      shootingController.setContinuousShotRange(
        startShotId: shots[0].id,
        endShotId: shots[1].id,
      ),
      isTrue,
    );
    final repository = ReplicateRepository(database);
    final controller = ReplicateController(
      repository: repository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
      enforceFreeCreationMode: true,
    );
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });
    final runId = controller.value.run!.id;
    final now = DateTime.now().toUtc();
    for (final shot in [shots[0], shots[2]]) {
      repository.upsertPrompt(
        ShotPrompt(
          id: 'prompt-${shot.id}',
          runId: runId,
          shotNumber: shot.shotNumber,
          scriptShotId: shot.id == shots[0].id ? null : shot.id,
          assetIds: const [],
          prompt: '提示词 ${shot.shotNumber}',
          model: 'MiniMax H3',
          rawResponse: '{}',
          status: ProcessingStatus.completed,
          errorMessage: '',
          updatedAt: now,
        ),
      );
      repository.upsertReplicatedShotImage(
        ReplicatedShotImage(
          id: 'replica-${shot.id}',
          runId: runId,
          scriptShotId: shot.id,
          shotNumber: shot.shotNumber,
          originalFramePath: 'original-${shot.id}.png',
          generatedFramePath: 'replica-${shot.id}.png',
          assetIds: const [],
          prompt: '',
          model: 'test',
          rawResponse: '{}',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    controller.refresh();

    expect(controller.reorderShotGroups(0, 3), isTrue);
    expect(controller.value.shots.map((shot) => shot.id), [
      shots[2].id,
      shots[3].id,
      shots[0].id,
      shots[1].id,
    ]);
    expect(controller.value.shots.map((shot) => shot.shotNumber), [1, 2, 3, 4]);
    expect(controller.value.shots[2].continuesToNext, isTrue);
    expect(controller.value.shots[3].continuesFromPrevious, isTrue);
    expect(repository.listPrompts(runId).map((prompt) => prompt.shotNumber), [
      1,
      3,
    ]);
    expect(
      repository
          .listPrompts(runId)
          .firstWhere((prompt) => prompt.id == 'prompt-${shots[0].id}')
          .scriptShotId,
      shots[0].id,
      reason: '旧工程空镜头关联需在排序前按旧镜号补齐',
    );
    expect(
      repository
          .listReplicatedShotImages(runId)
          .map((image) => image.shotNumber),
      [1, 3],
    );

    expect(controller.removeShotGroup(shots[0].id), isTrue);
    expect(controller.value.shots.map((shot) => shot.id), [
      shots[2].id,
      shots[3].id,
    ]);
    expect(repository.listPrompts(runId).map((prompt) => prompt.scriptShotId), [
      shots[2].id,
    ]);
    expect(
      repository
          .listReplicatedShotImages(runId)
          .map((image) => image.scriptShotId),
      [shots[2].id],
    );
  });
}

String _validFreeCreationH3Prompt({
  required int pictureCount,
  required int durationSeconds,
}) {
  final definitions = [
    for (var index = 1; index <= pictureCount; index++)
      '<Picture $index> 是第 $index 张参考图，用于定义可见主体、构图和动作阶段。',
  ].join('\n');
  final retention = [
    for (var index = 1; index <= pictureCount; index++)
      '<Picture $index> ([Shot 1] 分镜规划参考): fully_preserved - 保留该图的主体特征、构图关系和动作意图。',
  ].join('\n');
  final continuation = pictureCount >= 2
      ? '动作过程参考 <Picture 2> 的手部与产品空间关系'
      : '动作过程严格保持 <Picture 1> 的手部与产品空间关系';
  return '''subject_definitions:
$definitions

summary:
[参考生成] $durationSeconds秒视频，根据参考图和用户描述生成连续镜头。

retention_analysis:
$retention

detailed_description:
目标视频采用清晰、克制且可执行的商业影像语言。
[Shot 1] 画面从 <Picture 1> 所定义的人物位置与室内构图开始，人物按真实速度拿起产品，摄影机平稳推近；$continuation，最后在画面中心稳定呈现。手指接触瓶身的轻微摩擦声与拿起动作同步，不出现无关文字、水印或 Logo。

overall_soundscape:
安静的室内环境底噪持续存在，仅保留与手部接触、产品拿起和放稳同步的自然物理声。

non_diegetic_music:
N/A''';
}

String _splitFreeCreationH3Prompt({
  required int pictureCount,
  required int durationSeconds,
}) {
  final definitions = [
    for (var index = 1; index <= pictureCount; index++)
      '<Picture $index> 是连续动作的第 $index 张参考图。',
  ].join('\n');
  final retention = [
    for (var index = 1; index <= pictureCount; index++)
      '<Picture $index> ([Shot $index] 首帧): fully_preserved - 保留该图的主体、构图和动作阶段。',
  ].join('\n');
  return '''subject_definitions:
$definitions

summary:
[参考生成] $durationSeconds秒视频，人物完成连续动作。

retention_analysis:
$retention

detailed_description:
[Shot 1] 人物从 <Picture 1> 的姿态开始动作。
[Shot 2] 在 00:03.500，镜头切换到 <Picture 2> 的构图并继续动作。

overall_soundscape:
自然环境底噪与人物动作声保持同步。

non_diegetic_music:
N/A''';
}

int _occurrences(String text, String pattern) =>
    RegExp(RegExp.escape(pattern)).allMatches(text).length;

class _RecordingImageGenerationService extends ImageGenerationService {
  final requests = <ImageGenerationRequest>[];
  Completer<void>? requestStarted;
  Future<void>? requestGate;

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) async {
    requests.add(request);
    final started = requestStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final gate = requestGate;
    if (gate != null) await gate;
    final serviceCacheDirectory = request.outputDirectory.parent.parent.parent;
    final output = File(
      '${serviceCacheDirectory.path}${Platform.pathSeparator}'
      'service-cache-${requests.length}.png',
    );
    await output.writeAsBytes([137, 80, 78, 71, requests.length], flush: true);
    return ImageGenerationResult(
      localPath: output.path,
      remoteUrl: '',
      rawResponse: '{"ok":true}',
    );
  }
}

class _RecordingVisionStoryboardService extends VisionStoryboardService {
  var analyzeCount = 0;
  var resolvedPrompt = '';
  final completionResponses = <String>[];
  var activeCompletions = 0;
  var maxActiveCompletions = 0;
  Completer<void>? firstCompletionStarted;
  Completer<void>? secondCompletionStarted;
  Future<void>? completionGate;
  final completionPrompts = <String>[];
  final completionImagePaths = <List<String>>[];
  final completionResponseTimeouts = <Duration>[];
  final completionCompressOversizedImages = <bool>[];

  @override
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
    Duration responseTimeout = VisionStoryboardService.requestTimeout,
    bool compressOversizedImages = false,
  }) async {
    activeCompletions++;
    if (activeCompletions > maxActiveCompletions) {
      maxActiveCompletions = activeCompletions;
    }
    try {
      completionPrompts.add(prompt);
      completionImagePaths.add([for (final file in imageFiles) file.path]);
      completionResponseTimeouts.add(responseTimeout);
      completionCompressOversizedImages.add(compressOversizedImages);
      final firstStarted = firstCompletionStarted;
      if (completionPrompts.length == 1 &&
          firstStarted != null &&
          !firstStarted.isCompleted) {
        firstStarted.complete();
      }
      final secondStarted = secondCompletionStarted;
      if (completionPrompts.length >= 2 &&
          secondStarted != null &&
          !secondStarted.isCompleted) {
        secondStarted.complete();
      }
      final gate = completionGate;
      if (gate != null) await gate;
      final response = completionResponses.isEmpty
          ? resolvedPrompt
          : completionResponses.removeAt(0);
      if (response.trimLeft().startsWith('subject_definitions:')) {
        final duration =
            RegExp(r'(\d+)\s*秒视频').firstMatch(response)?.group(1) ?? '6';
        if (prompt.trimLeft().startsWith('你正在为可灵图生视频编写')) {
          final range = imageFiles.length <= 1
              ? '图片1作为起始画面参考'
              : '图片1至图片${imageFiles.length}作为同一连续镜头的顺序动作参考';
          return '$duration秒视频。$range。保持图片中的主体、场景和外观一致，主体按正常速度连续完成用户指定动作，平稳跟随镜头，无切镜。';
        }
        if (prompt.trimLeft().startsWith('你正在为即梦 / Seedance 2.0')) {
          final range = imageFiles.length <= 1
              ? '@图片 1 作为起始画面参考'
              : '@图片 1 至 @图片 ${imageFiles.length} 作为同一连续镜头的顺序动作参考';
          return '$duration秒视频。$range。保持参考图中的主体、场景和外观一致，主体按正常速度连续完成用户指定动作，中景平稳跟随，无切镜，保留自然环境声。';
        }
      }
      return response;
    } finally {
      activeCompletions--;
    }
  }

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
    File? previousImageFile,
    File? nextImageFile,
    String creativeBrief = '',
    String storyContext = '',
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    analyzeCount++;
    return const VisionImageAnalysis(
      caption: '女模特在窗边展示产品',
      detail: '中景中女模特右手持蓝色包装瓶，侧身面向窗光。',
      scene: '明亮室内窗边',
      props: '蓝色包装瓶',
      people: '女模特',
      expression: '自然微笑，看向产品',
      bodyAction: '右手举起产品展示',
      movementTrend: '动作进行中',
      shotSize: '中景',
      cameraMovement: '固定',
      composition: '主体偏右，左侧窗光留白',
      subjectDirection: '三分之二侧面朝左',
      gazeDirection: '看向手中产品',
      actionStage: '进行',
      spatialRelation: '站在窗边，产品位于胸前',
      chronologyCue: '展示动作中',
      cameraAngle: '眼平中景',
      visualFocus: '蓝色包装瓶',
      lightingMood: '柔和侧窗光',
      colorPalette: '清爽白蓝色',
      narrativeFunction: '广告产品记忆点',
      transitionHint: '承接展示动作',
      rawResponse: '{}',
    );
  }
}
