import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/data/storyboard_image_edit_preferences_repository.dart';

void main() {
  test('图片修改面板偏好独立持久化且不会覆盖设置页默认模型', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_image_edit_preferences_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    addTearDown(() async {
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await settingsController.setImageGenerationModel(
      'gemini-3-pro-image-preview',
    );
    final repository = StoryboardImageEditPreferencesRepository(database);
    final initial = repository.load(
      fallbackModel: settingsController.value.imageGenerationModel,
    );
    expect(initial.model, 'gemini-3-pro-image-preview');
    expect(initial.aspectRatio, 'auto');
    expect(initial.imageSize, '1K');

    repository.save(
      const StoryboardImageEditPreferences(
        model: 'nano-banana-fast',
        aspectRatio: '16:9',
        imageSize: '2K',
      ),
    );
    final restored = repository.load(
      fallbackModel: 'gemini-3-pro-image-preview',
    );
    expect(restored.model, 'nano-banana-fast');
    expect(restored.aspectRatio, '16:9');
    expect(restored.imageSize, '2K');
    expect(
      database.getSetting('imageGenerationModel'),
      'gemini-3-pro-image-preview',
    );
    expect(
      settingsController.value.imageGenerationModel,
      'gemini-3-pro-image-preview',
    );
  });
}
