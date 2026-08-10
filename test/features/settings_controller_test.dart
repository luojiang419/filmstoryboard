import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/settings/domain/image_generation_api_config.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/settings/domain/vision_api_config.dart';
import 'package:test/test.dart';

void main() {
  test('功能菜单位置会持久化且默认使用底部布局', () async {
    final root = await Directory.systemTemp.createTemp('settings_navigation_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    expect(controller.value.navigationPosition, AppNavigationPosition.bottom);

    await controller.setNavigationPosition(AppNavigationPosition.left);

    expect(controller.value.navigationPosition, AppNavigationPosition.left);
    expect(repository.load().navigationPosition, AppNavigationPosition.left);
    expect(database.getSetting('navigationPosition'), 'left');
  });

  test('视觉模型卡片可新增、切换并持久化', () async {
    final root = await Directory.systemTemp.createTemp(
      'settings_vision_cards_',
    );
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    final miniMax = const VisionApiConfig(
      id: 'test-minimax',
      name: 'MiniMax M3 测试',
      baseUrl: 'https://api.minimaxi.com',
      apiKey: 'test-key',
      model: 'MiniMax-M3',
    );
    await controller.saveVisionApiConfig(miniMax);
    await controller.setActiveVisionApiConfig(miniMax.id);

    final restored = repository.load();
    expect(restored.activeVisionApiConfigId, miniMax.id);
    expect(restored.visionApiBaseUrl, miniMax.baseUrl);
    expect(restored.visionApiKey, miniMax.apiKey);
    expect(restored.visionModel, miniMax.model);
    expect(restored.visionMaxRequestsPerMinute, 200);
    expect(restored.visionApiConfigs, contains(isA<VisionApiConfig>()));

    await controller.setVisionApiConfigMaxRequestsPerMinute(miniMax.id, 37);

    final reloaded = repository.load();
    expect(reloaded.activeVisionApiConfig?.maxRequestsPerMinute, 37);
    expect(reloaded.visionMaxRequestsPerMinute, 37);
  });

  test('图片生成 API 卡片可新增、设为默认并持久化', () async {
    final root = await Directory.systemTemp.createTemp('settings_image_cards_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    const config = ImageGenerationApiConfig(
      id: 'test-gemini-image',
      name: 'Gemini 图片测试',
      baseUrl: 'https://gemini.example',
      apiKey: 'test-key',
      model: 'gemini-3-pro-image',
    );
    await controller.saveImageGenerationApiConfig(config);

    expect(controller.value.activeImageGenerationApiConfigId, config.id);
    expect(controller.value.imageGenerationModel, config.model);
    expect(
      controller.value.activeImageGenerationApiConfig?.apiKey,
      config.apiKey,
    );

    final restored = repository.load();
    expect(restored.activeImageGenerationApiConfigId, config.id);
    expect(restored.imageGenerationModel, config.model);
    expect(
      restored.imageGenerationApiConfigs.map((item) => item.id),
      contains(config.id),
    );
  });

  test('视频生成 API 卡片可新增、设为默认并持久化', () async {
    final root = await Directory.systemTemp.createTemp('settings_video_api_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    expect(
      controller.value.activeVideoGenerationApiConfig?.id,
      AppSettings.defaultKlingCliVideoGenerationConfigId,
    );
    expect(controller.value.activeVideoGenerationApiConfig?.isKlingCli, isTrue);
    expect(
      controller.value.videoGenerationApiConfigs.map((item) => item.id),
      contains(AppSettings.defaultMiniMaxVideoGenerationConfigId),
    );

    const config = VideoGenerationApiConfig(
      id: 'test-minimax-h3',
      name: 'MiniMax H3 测试',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: 'local-key',
      model: 'minimax-h3-local',
    );
    await controller.saveVideoGenerationApiConfig(config);

    expect(controller.value.activeVideoGenerationApiConfigId, config.id);
    expect(
      controller.value.activeVideoGenerationApiConfig?.apiKey,
      config.apiKey,
    );

    final restored = repository.load();
    expect(restored.activeVideoGenerationApiConfigId, config.id);
    expect(restored.activeVideoGenerationApiConfig?.isHttpApi, isTrue);
    expect(restored.activeVideoGenerationApiConfig?.model, config.model);
    expect(
      restored.videoGenerationApiConfigs.map((item) => item.id),
      contains(config.id),
    );

    await controller.deleteVideoGenerationApiConfig(
      AppSettings.defaultKlingCliVideoGenerationConfigId,
    );
    expect(
      controller.value.videoGenerationApiConfigs.map((item) => item.id),
      contains(AppSettings.defaultKlingCliVideoGenerationConfigId),
    );
  });

  test('视频抽帧配置会校验范围并持久化', () async {
    final root = await Directory.systemTemp.createTemp('settings_video_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await controller.setVideoAnalysisSettings(
      ffmpegExecutable: r'D:\tools\ffmpeg.exe',
      ffprobeExecutable: r'D:\tools\ffprobe.exe',
      extractionStrategy: VideoFrameExtractionStrategy.perFrame,
      frameIntervalSeconds: 0,
      sceneThreshold: 2,
      minimumSharpness: -1,
      previewPaddingSeconds: 45,
      thinkingEnabled: true,
    );

    final restored = repository.load();
    expect(restored.ffmpegExecutable, r'D:\tools\ffmpeg.exe');
    expect(
      restored.videoFrameExtractionStrategy,
      VideoFrameExtractionStrategy.perFrame,
    );
    expect(restored.videoFrameIntervalSeconds, 0.1);
    expect(restored.videoSceneThreshold, 0.95);
    expect(restored.videoMinimumSharpness, 0);
    expect(restored.videoPreviewPaddingSeconds, 30);
    expect(restored.videoAnalysisThinkingEnabled, isTrue);
  });

  test('即梦提示词默认规则会持久化且空值恢复安全默认值', () async {
    final root = await Directory.systemTemp.createTemp('settings_replicate_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await controller.setReplicatePromptDefaults(
      globalStyle: '商业电影质感，低饱和暖色调',
      constraints: '无字幕、无 Logo、无水印，主体一致',
    );

    var restored = repository.load();
    expect(restored.replicateDefaultGlobalStyle, '商业电影质感，低饱和暖色调');
    expect(restored.replicateDefaultConstraints, '无字幕、无 Logo、无水印，主体一致');

    await controller.setReplicatePromptDefaults(
      globalStyle: ' ',
      constraints: '',
    );
    restored = repository.load();
    expect(
      restored.replicateDefaultGlobalStyle,
      AppSettings.defaultReplicateGlobalStyle,
    );
    expect(
      restored.replicateDefaultConstraints,
      AppSettings.defaultReplicateConstraints,
    );
  });

  test('编号滑块预览只更新内存且拖动结束值才持久化', () async {
    final root = await Directory.systemTemp.createTemp('settings_controller_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    controller.previewCutImageNumberBackgroundOpacity(0.35);
    controller.previewCutImageNumberTextScale(1.4);

    expect(controller.value.cutImageNumberBackgroundOpacity, 0.35);
    expect(controller.value.cutImageNumberTextScale, 1.4);
    var restored = repository.load();
    expect(
      restored.cutImageNumberBackgroundOpacity,
      AppSettings.defaultCutImageNumberBackgroundOpacity,
    );
    expect(
      restored.cutImageNumberTextScale,
      AppSettings.defaultCutImageNumberTextScale,
    );

    await controller.setCutImageNumberBackgroundOpacity(
      controller.value.cutImageNumberBackgroundOpacity,
    );
    await controller.setCutImageNumberTextScale(
      controller.value.cutImageNumberTextScale,
    );

    restored = repository.load();
    expect(restored.cutImageNumberBackgroundOpacity, 0.35);
    expect(restored.cutImageNumberTextScale, 1.4);
  });

  test('文本框编号开关会持久化', () async {
    final root = await Directory.systemTemp.createTemp('settings_controller_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    expect(controller.value.storyboardCaptionNumberEnabled, isTrue);
    await controller.setStoryboardCaptionNumberEnabled(false);

    expect(controller.value.storyboardCaptionNumberEnabled, isFalse);
    expect(repository.load().storyboardCaptionNumberEnabled, isFalse);
  });

  test('APIMart地址和Key独立持久化且不覆盖GRSai配置', () async {
    final root = await Directory.systemTemp.createTemp('settings_controller_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await controller.setImageGenerationApiKey('grsai-key');
    await controller.setImageGenerationApiMartSettings(
      baseUrl: 'https://api.apimart.ai/v1/images/generations/',
      apiKey: 'apimart-key',
    );

    final restored = repository.load();
    expect(restored.imageGenerationApiKey, 'grsai-key');
    expect(restored.imageGenerationApiMartApiBaseUrl, 'https://api.apimart.ai');
    expect(restored.imageGenerationApiMartApiKey, 'apimart-key');
  });

  test('APIMart文档地址不会被误保存为接口地址', () async {
    final root = await Directory.systemTemp.createTemp('settings_controller_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.setImageGenerationApiMartSettings(
        baseUrl: 'https://docs.apimart.ai/cn',
        apiKey: 'apimart-key',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('文档地址'), contains('api.apimart.ai')),
        ),
      ),
    );
    expect(
      repository.load().imageGenerationApiMartApiBaseUrl,
      AppSettings.defaultImageGenerationApiMartApiBaseUrl,
    );
  });

  test('Gemini地址和Key独立持久化且不覆盖GRSai配置', () async {
    final root = await Directory.systemTemp.createTemp('settings_controller_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final repository = SettingsRepository(database, directories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await controller.setImageGenerationGrsaiSettings(
      baseUrl: 'https://grsai.example',
      apiKey: 'grsai-key',
    );
    await controller.setImageGenerationGeminiSettings(
      baseUrl: 'https://www.shiying-api.com',
      apiKey: 'gemini-key',
    );

    final restored = repository.load();
    expect(restored.imageGenerationApiBaseUrl, 'https://grsai.example');
    expect(restored.imageGenerationApiKey, 'grsai-key');
    expect(
      restored.imageGenerationGeminiApiBaseUrl,
      'https://www.shiying-api.com',
    );
    expect(restored.imageGenerationGeminiApiKey, 'gemini-key');
  });
}
