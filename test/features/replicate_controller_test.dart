import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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
        shotSize: '中景',
        cameraMovement: '缓慢推镜、横移',
        dialogue: '今天也要清爽一点',
        sound: '冰块碰撞声',
      ),
    );

    controller = ReplicateController(
      repository: ReplicateRepository(database),
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
    controller.updateGenerationDefaults(aspectRatio: changedAspectRatio);
    expect(controller.value.run?.generationAspectRatio, changedAspectRatio);
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
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.run?.confirmedShotIds, contains(shot.id));
    expect(controller.value.run?.generationAspectRatio, changedAspectRatio);

    final secondSource = File('${root.path}/second.png');
    await secondSource.writeAsBytes([137, 80, 78, 71, 13], flush: true);
    final second = await controller.importAsset(
      sourcePath: secondSource.path,
      type: ReplicateAssetType.product,
      name: '气泡水',
      description: '透明玻璃瓶，蓝色标签',
    );
    expect(second?.referenceNumber, 2);
    expect(controller.moveToStep(ReplicateStep.composePrompts), isTrue);

    await controller.composeAllPrompts();
    expect(controller.value.prompts, hasLength(1));
    final prompt = controller.value.prompts.single.prompt;
    expect(prompt, contains('图片2'));
    expect(prompt, contains('镜头1'));
    expect(prompt, contains('无字幕'));
    expect(prompt, isNot(contains(second!.id)));
    expect(controller.value.run?.completedCount, 1);
    expect(shootingController.value.shots.single.prompt, prompt);

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
    expect(exportedSheet, contains('主体与素材定义'));
    expect(exportedSheet, contains('图片2中的透明玻璃瓶'));
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
    expect(controller.value.prompts.single.prompt, prompt);
    expect(controller.value.run?.currentStep, ReplicateStep.composePrompts);

    final restoredShot = shootingController.value.shots.single;
    shootingController.updateShot(
      restoredShot.copyWith(content: '外部页面修改后的镜头内容'),
    );
    expect(
      controller.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '脚本内容变化后，旧提示词必须明确标记为待重新合成',
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
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      imageService.close();
      database.dispose();
      await root.delete(recursive: true);
    });
    await controller.replicateAllShots(
      stagger: const Duration(milliseconds: 20),
      maxConcurrent: 2,
    );

    expect(imageService.requests, hasLength(2));
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
    expect(imageService.requests[0].prompt, contains('【视觉模型对原帧的关键维度解析】'));
    expect(imageService.requests[0].prompt, contains('视觉焦点与道具：蓝色包装瓶'));
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
    expect(imageService.requests[0].prompt, contains('色彩硬约束：以图片1的色彩风格'));
    expect(imageService.requests[0].prompt, contains('产品主体必须清晰可辨'));
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
}

class _RecordingImageGenerationService extends ImageGenerationService {
  final requests = <ImageGenerationRequest>[];

  @override
  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) async {
    requests.add(request);
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

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
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
