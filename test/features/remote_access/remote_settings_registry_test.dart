import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_settings_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/application/settings_remote_source.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/image_generation_api_config.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/settings/domain/vision_api_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('设置远程投影不包含密钥地址路径且只允许切换既有配置', () async {
    final root = await Directory.systemTemp.createTemp('remote_settings_');
    addTearDown(() => root.delete(recursive: true));
    final appDirectories = await AppDirectories.create(
      executableDirectory: Directory('${root.path}/app'),
    );
    final settingsDatabase = await AppDatabase.open(
      appDirectories.databaseFile,
    );
    addTearDown(settingsDatabase.dispose);
    final repository = SettingsRepository(settingsDatabase, appDirectories);
    final controller = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    addTearDown(controller.dispose);

    await controller.saveVisionApiConfig(
      const VisionApiConfig(
        id: 'vision-safe-id',
        name: '视觉模型 A',
        baseUrl: 'https://vision.secret.example',
        apiKey: 'vision-secret-key',
        model: 'vision-model-a',
      ),
    );
    await controller.saveImageGenerationApiConfig(
      const ImageGenerationApiConfig(
        id: 'image-safe-id',
        name: '图片模型 A',
        baseUrl: 'https://image.secret.example',
        apiKey: 'image-secret-key',
        model: 'nano-banana-2',
      ),
    );
    await controller.saveVideoGenerationApiConfig(
      const VideoGenerationApiConfig(
        id: 'video-safe-id',
        name: '视频模型 A',
        baseUrl: r'C:\private\video-api',
        apiKey: 'video-secret-key',
        model: 'video-model-a',
      ),
    );

    final projectDirectories = ProjectDirectories.fromRoot(
      Directory('${root.path}/project'),
    );
    await projectDirectories.create();
    final projectDatabase = await AppDatabase.open(
      projectDirectories.databaseFile,
    );
    addTearDown(projectDatabase.dispose);
    final changeBus = RemoteChangeBus();
    addTearDown(changeBus.close);
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-1',
          projectName: '测试工程',
          database: projectDatabase,
          directories: projectDirectories,
        ),
      );
    final source = SettingsRemoteSource(controller);
    addTearDown(source.dispose);
    final registry = RemoteSettingsRegistry(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
    )..attach(source);
    addTearDown(registry.dispose);
    final facade = RemoteAccessFacade(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
      settingsRegistry: registry,
    );

    final encoded = jsonEncode(facade.settingsOptions());
    expect(encoded, contains('视觉模型 A'));
    expect(encoded, contains('vision-model-a'));
    expect(encoded, isNot(contains('secret-key')));
    expect(encoded, isNot(contains('secret.example')));
    expect(encoded, isNot(contains(r'C:\private')));
    expect(encoded, isNot(contains('baseUrl')));
    expect(encoded, isNot(contains('apiKey')));

    final updated = await facade.updateSettingsSelection({
      'extractionStrategy': 'intervalOnly',
      'visionModelId': 'vision-safe-id',
    });
    expect(updated['selectedExtractionStrategy'], 'intervalOnly');
    expect(updated['selectedVisionModelId'], 'vision-safe-id');
    expect(
      () => facade.updateSettingsSelection({'apiKey': 'forbidden'}),
      throwsA(isA<FormatException>()),
    );
  });
}
