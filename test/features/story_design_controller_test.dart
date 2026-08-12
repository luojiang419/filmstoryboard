import 'dart:async';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/grid_cut/application/grid_cut_controller.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_crop_service.dart';
import 'package:filmstoryboard/features/grid_cut/data/grid_detection_service.dart';
import 'package:filmstoryboard/features/projects/application/project_aspect_controller.dart';
import 'package:filmstoryboard/features/projects/data/project_aspect_repository.dart';
import 'package:filmstoryboard/features/projects/domain/project_aspect_ratio.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/story_design/application/story_design_controller.dart';
import 'package:filmstoryboard/features/story_design/data/story_design_preferences_repository.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';
import 'package:test/test.dart';

void main() {
  test('竖屏项目把设计分镜的首次默认比例设为9比16', () async {
    final fixture = await _createFixture();
    final aspectRepository = ProjectAspectRepository(fixture.database)
      ..save(const ProjectAspectState(mode: ProjectAspectMode.portrait));
    final aspectController = ProjectAspectController(
      repository: aspectRepository,
    );
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      preferencesRepository: StoryDesignPreferencesRepository(fixture.database),
      projectAspectController: aspectController,
    );
    addTearDown(() {
      controller.dispose();
      aspectController.dispose();
    });

    expect(controller.value.aspectRatio, '9:16');
  });

  test('设计页首次默认无宫格并向API原样发送提示词', () async {
    final fixture = await _createFixture();
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      preferencesRepository: StoryDesignPreferencesRepository(fixture.database),
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    expect(StoryDesignController.gridOptions, [0, 4, 6, 9, 12, 16, 24]);
    expect(controller.value.gridCount, 0);
    expect(controller.value.portraitGrid, isFalse);

    controller.setPrompt('女人抱着一个西瓜炸开了');
    await controller.generate();

    final submittedPrompt = imageService.lastRequest!.prompt;
    expect(imageService.lastRequest!.provider.providerId, 'grsai');
    expect(
      imageService.lastRequest!.provider.apiBaseUrl,
      'https://grsai.dakka.com.cn',
    );
    expect(imageService.lastRequest!.provider.apiKey, 'test-image-key');
    expect(submittedPrompt, '女人抱着一个西瓜炸开了');
    expect(submittedPrompt, isNot(contains('多宫格')));
    expect(controller.value.prompt, '女人抱着一个西瓜炸开了');
    expect(controller.value.results.single.prompt, '女人抱着一个西瓜炸开了');
  });

  test('Gemini 3 Pro 图像模型会使用连贯的分镜提示词增强规则', () async {
    final fixture = await _createFixture();
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller
      ..setModel('apimart:gemini-3-pro-image-preview')
      ..setGridCount(4)
      ..setPrompt('雨夜里，侦探在霓虹灯下追踪嫌疑人');
    await controller.generate();

    final submittedPrompt = imageService.lastRequest!.prompt;
    expect(submittedPrompt, contains('雨夜里，侦探在霓虹灯下追踪嫌疑人'));
    expect(submittedPrompt, contains('【Gemini 3 分镜图像指令】'));
    expect(submittedPrompt, contains('完整、连贯的视觉叙事'));
    expect(submittedPrompt, contains('景别、机位、焦段感'));
    expect(submittedPrompt, contains('固定排列为 2列×2行'));
    expect(submittedPrompt, contains('不要添加标题、镜号、字幕'));
  });

  test('生成参数修改后写入工程数据库并在新控制器恢复', () async {
    final fixture = await _createFixture();
    final preferencesRepository = StoryDesignPreferencesRepository(
      fixture.database,
    );
    final first = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      preferencesRepository: preferencesRepository,
      imageGenerationService: _FakeImageGenerationService(),
    );

    const targetModel = 'apimart:gpt-image-2';
    first.setModel(targetModel);
    final targetRatio = StoryDesignController.aspectRatioOptionsFor(
      targetModel,
    ).last;
    first.setAspectRatio(targetRatio);
    final targetSize = StoryDesignController.imageSizeOptionsFor(
      targetModel,
      first.value.aspectRatio,
    ).last;
    first.setImageSize(targetSize);
    if (StoryDesignController.supportsQuality(targetModel)) {
      first.setQuality(
        StoryDesignController.qualityOptionsFor(targetModel).last,
      );
    }
    first.setBatchCount(4);
    first.setGridCount(12);
    first.setPortraitGrid(true);
    final expected = first.value;
    first.dispose();

    expect(
      fixture.database.getSetting(StoryDesignPreferencesRepository.settingKey),
      isNotNull,
    );

    final restored = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      preferencesRepository: preferencesRepository,
      imageGenerationService: _FakeImageGenerationService(),
    );
    addTearDown(restored.dispose);

    expect(restored.value.model, expected.model);
    expect(restored.value.aspectRatio, expected.aspectRatio);
    expect(restored.value.imageSize, expected.imageSize);
    expect(restored.value.quality, expected.quality);
    expect(restored.value.batchCount, 4);
    expect(restored.value.gridCount, 12);
    expect(restored.value.portraitGrid, isTrue);
    expect(restored.value.prompt, isEmpty);
    expect(restored.value.referenceImagePaths, isEmpty);
    expect(restored.value.generationTasks, isEmpty);
    expect(restored.value.results, isEmpty);
  });

  test('APIMart GPT Image 2 切换比例时自动排除无效 4K 组合', () async {
    final fixture = await _createFixture();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    addTearDown(controller.dispose);

    const model = 'apimart:gpt-image-2-official';
    controller.setModel(model);
    controller.setAspectRatio('16:9');
    controller.setImageSize('4K');
    expect(controller.value.imageSize, '4K');
    expect(StoryDesignController.imageSizeOptionsFor(model, '16:9'), [
      '1K',
      '2K',
      '4K',
    ]);

    controller.setAspectRatio('1:1');
    expect(StoryDesignController.imageSizeOptionsFor(model, '1:1'), [
      '1K',
      '2K',
    ]);
    expect(controller.value.imageSize, '1K');
  });

  test('生成结果写入工程索引并在重启控制器后恢复', () async {
    final fixture = await _createFixture();
    final first = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    first.setPrompt('需要持久化的山间日出');
    await first.generate();

    final generated = first.value.results.single;
    final generatedFile = File(generated.path);
    final indexFile = File(
      p.join(
        fixture.directories.generatedImages.path,
        'design',
        'results.json',
      ),
    );
    expect(generatedFile.existsSync(), isTrue);
    expect(indexFile.existsSync(), isTrue);
    first.dispose();

    final restored = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    expect(restored.value.results, hasLength(1));
    expect(restored.value.results.single.id, generated.id);
    expect(restored.value.results.single.path, generated.path);
    expect(restored.value.results.single.prompt, '需要持久化的山间日出');
    expect(restored.value.message, '已恢复 1 张设计分镜图');

    restored.removeResult(generated.id);
    restored.dispose();
    expect(generatedFile.existsSync(), isTrue);

    final afterRemoval = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    addTearDown(afterRemoval.dispose);
    expect(afterRemoval.value.results, isEmpty);
    expect(generatedFile.existsSync(), isTrue);
  });

  test('首次升级会扫描并恢复工程目录中的历史生成图', () async {
    final fixture = await _createFixture();
    final designDirectory = Directory(
      p.join(fixture.directories.generatedImages.path, 'design'),
    );
    await designDirectory.create(recursive: true);
    final image = img.Image(width: 24, height: 18);
    final legacyImage = File(p.join(designDirectory.path, 'legacy.png'));
    await legacyImage.writeAsBytes(img.encodePng(image));
    await File('${legacyImage.path}.json').writeAsString(
      '{"prompt":"历史分镜","model":"nano-banana-fast",'
      '"aspectRatio":"16:9","imageSize":"2K","quality":"auto",'
      '"remoteUrl":"https://files.example/legacy.png",'
      '"timestamp":1700000000000}',
    );

    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    addTearDown(controller.dispose);

    expect(controller.value.results, hasLength(1));
    expect(controller.value.results.single.path, legacyImage.path);
    expect(controller.value.results.single.prompt, '历史分镜');
    expect(controller.value.results.single.aspectRatio, '16:9');
    expect(
      File(p.join(designDirectory.path, 'results.json')).existsSync(),
      isTrue,
    );
  });

  test('设计页可切换预置宫格且拒绝非预置数量', () async {
    final fixture = await _createFixture();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: _FakeImageGenerationService(),
    );
    addTearDown(controller.dispose);

    controller.setGridCount(24);
    expect(controller.value.gridCount, 24);
    expect(
      StoryDesignController.buildGridPrompt('测试', 24),
      contains('固定排列为 6列×4行'),
    );

    controller.setGridCount(8);
    expect(controller.value.gridCount, 24);
  });

  test('选择无宫格时API只接收原提示词且竖屏开关关闭', () async {
    final fixture = await _createFixture();
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setGridCount(9);
    controller.setPortraitGrid(true);
    expect(controller.value.portraitGrid, isTrue);
    controller.setGridCount(0);
    expect(controller.value.gridCount, 0);
    expect(controller.value.portraitGrid, isFalse);
    controller.setPortraitGrid(true);
    expect(controller.value.portraitGrid, isFalse);

    controller.setPrompt('  单张电影感画面  ');
    await controller.generate();

    expect(imageService.lastRequest!.prompt, '单张电影感画面');
    expect(imageService.lastRequest!.prompt, isNot(contains('多宫格')));
    expect(imageService.lastRequest!.prompt, isNot(contains('固定排列')));
  });

  test('竖屏多宫格按每行一图生成单列提示词', () async {
    final fixture = await _createFixture();
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setGridCount(6);
    controller.setPortraitGrid(true);
    controller.setPrompt('角色连续动作');
    await controller.generate();

    final submittedPrompt = imageService.lastRequest!.prompt;
    expect(submittedPrompt, contains('严格 6 个独立分镜画面'));
    expect(submittedPrompt, contains('固定排列为 1列×6行'));
    expect(submittedPrompt, contains('每行只能有一个分镜'));
    expect(submittedPrompt, contains('按从上到下的顺序阅读'));
    expect(submittedPrompt, contains('单个分镜仍保持横向画幅'));
    expect(submittedPrompt, isNot(contains('3列×2行')));
  });

  test('设计页勾选生成结果后可导入多宫格裁切任务栏', () async {
    final fixture = await _createFixture();
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setPrompt('雨夜街头的电影感分镜图');
    await controller.generate();

    expect(controller.value.results, hasLength(1));
    expect(controller.value.results.single.selected, isTrue);
    expect(imageService.lastRequest?.referenceImagePaths, isEmpty);
    expect(
      imageService.lastRequest?.outputDirectory.path,
      p.join(fixture.directories.generatedImages.path, 'design'),
    );

    final added = await controller.addSelectedToCutPage();

    expect(added, 1);
    expect(fixture.gridCutController.value.images, hasLength(1));
    expect(
      fixture.gridCutController.value.selectedImage?.originalName,
      '项目1.png',
    );
  });

  test('选择APIMart模型时只使用APIMart独立地址和Key', () async {
    final fixture = await _createFixture();
    await fixture.settingsController.setImageGenerationApiMartSettings(
      baseUrl: 'https://apimart.example',
      apiKey: 'apimart-key',
    );
    await fixture.settingsController.setImageGenerationModel(
      'apimart:gemini-3-pro-image-preview',
    );
    final imageService = _FakeImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setPrompt('APIMart 路由验证');
    await controller.generate();

    final request = imageService.lastRequest!;
    expect(request.model, 'apimart:gemini-3-pro-image-preview');
    expect(request.provider.providerId, 'apimart');
    expect(request.provider.apiBaseUrl, 'https://apimart.example');
    expect(request.provider.apiKey, 'apimart-key');
    expect(request.provider.protocol, ImageGenerationProviderProtocol.apiMart);
  });

  test('连续点击生成会创建彼此独立的并发任务', () async {
    final fixture = await _createFixture();
    final imageService = _BlockingImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setPrompt('并发雪景任务');
    final first = controller.generate();
    expect(imageService.callCount, 1);
    expect(controller.value.activeTaskCount, 1);

    final second = controller.generate();
    expect(imageService.callCount, 2);
    expect(controller.value.generationTasks, hasLength(2));
    expect(controller.value.activeTaskCount, 2);
    expect(controller.value.isGenerating, isTrue);

    await imageService.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(controller.value.results, hasLength(1));
    expect(controller.value.activeTaskCount, 1);

    await imageService.complete(0);
    await Future.wait([first, second]);
    expect(controller.value.results, hasLength(2));
    expect(controller.value.activeTaskCount, 0);
    expect(controller.value.completedCount, 2);
    expect(controller.value.failedCount, 0);
  });

  test('单个并发任务失败会保留具体错误且不影响其他任务', () async {
    final fixture = await _createFixture();
    final imageService = _PartiallyFailingImageGenerationService();
    final controller = StoryDesignController(
      directories: fixture.directories,
      settingsController: fixture.settingsController,
      gridCutController: fixture.gridCutController,
      imageGenerationService: imageService,
    );
    addTearDown(controller.dispose);

    controller.setBatchCount(2);
    controller.setPrompt('局部失败验证');
    await controller.generate();

    expect(controller.value.results, hasLength(1));
    expect(controller.value.completedCount, 1);
    expect(controller.value.failedCount, 1);
    final failed = controller.value.generationTasks.singleWhere(
      (task) => task.isFailed,
    );
    expect(failed.errorMessage, '上游模型暂时不可用');
    expect(controller.value.message, contains('上游模型暂时不可用'));
  });
}

Future<
  ({
    Directory root,
    AppDirectories directories,
    AppDatabase database,
    SettingsController settingsController,
    GridCutController gridCutController,
  })
>
_createFixture() async {
  final root = await Directory.systemTemp.createTemp(
    'story_design_controller_',
  );
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final repository = SettingsRepository(
    database,
    directories,
    imageGenerationDefaultsText:
        '4. `builtin-grsai-image`\nkey: test-image-key\n模型：nano-banana-fast',
  );
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
  return (
    root: root,
    directories: directories,
    database: database,
    settingsController: settingsController,
    gridCutController: gridCutController,
  );
}

class _FakeImageGenerationService extends ImageGenerationService {
  ImageGenerationRequest? lastRequest;
  var callCount = 0;

  @override
  Future<ImageGenerationResult> generateTextToImage(
    ImageGenerationRequest request,
  ) async {
    lastRequest = request;
    callCount++;
    if (!request.outputDirectory.existsSync()) {
      await request.outputDirectory.create(recursive: true);
    }
    final image = img.Image(width: 32, height: 24);
    img.fill(image, color: img.ColorRgb8(60, 110, 180));
    final file = File(
      p.join(request.outputDirectory.path, 'design_$callCount.png'),
    );
    await file.writeAsBytes(img.encodePng(image));
    return ImageGenerationResult(
      localPath: file.path,
      remoteUrl: 'https://files.example/design_$callCount.png',
      rawResponse: '{"ok":true}',
    );
  }

  @override
  void close() {}
}

class _BlockingImageGenerationService extends ImageGenerationService {
  final requests = <ImageGenerationRequest>[];
  final blockers = <Completer<ImageGenerationResult>>[];

  int get callCount => requests.length;

  @override
  Future<ImageGenerationResult> generateTextToImage(
    ImageGenerationRequest request,
  ) {
    requests.add(request);
    final blocker = Completer<ImageGenerationResult>();
    blockers.add(blocker);
    return blocker.future;
  }

  Future<void> complete(int index) async {
    final request = requests[index];
    if (!request.outputDirectory.existsSync()) {
      await request.outputDirectory.create(recursive: true);
    }
    final image = img.Image(width: 32, height: 24);
    final file = File(
      p.join(request.outputDirectory.path, 'concurrent_$index.png'),
    );
    await file.writeAsBytes(img.encodePng(image));
    blockers[index].complete(
      ImageGenerationResult(
        localPath: file.path,
        remoteUrl: 'https://files.example/concurrent_$index.png',
        rawResponse: '{"ok":true}',
      ),
    );
  }

  @override
  void close() {}
}

class _PartiallyFailingImageGenerationService
    extends _FakeImageGenerationService {
  @override
  Future<ImageGenerationResult> generateTextToImage(
    ImageGenerationRequest request,
  ) async {
    if (callCount == 0) {
      callCount++;
      throw const HttpException('上游模型暂时不可用');
    }
    return super.generateTextToImage(request);
  }
}
