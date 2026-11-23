import 'package:flutter/services.dart';

import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../features/onboarding/data/onboarding_repository.dart';
import '../database/app_database.dart';
import '../providers/app_providers.dart';
import '../services/app_directories.dart';

class AppBootstrap {
  const AppBootstrap({
    required this.directories,
    required this.database,
    required this.settingsRepository,
    required this.settingsController,
  });

  final AppDirectories directories;
  final AppDatabase database;
  final SettingsRepository settingsRepository;
  final SettingsController settingsController;

  static Future<AppBootstrap> initialize() async {
    final directories = await AppDirectories.create();
    final isFreshInstall = !directories.databaseFile.existsSync();
    final database = await AppDatabase.open(directories.databaseFile);
    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: isFreshInstall,
    );
    final settingsRepository = SettingsRepository(
      database,
      directories,
      visionDefaultsText: await _loadVisionDefaultsText(),
    );
    final initialSettings = settingsRepository.load();
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: initialSettings,
    );

    return AppBootstrap(
      directories: directories,
      database: database,
      settingsRepository: settingsRepository,
      settingsController: settingsController,
    );
  }

  static Future<String?> _loadVisionDefaultsText() async {
    try {
      return await rootBundle.loadString('docs/视觉模型api.md');
    } catch (_) {
      return null;
    }
  }

  dynamic get providerOverrides => [
    appDirectoriesProvider.overrideWithValue(directories),
    globalDatabaseProvider.overrideWithValue(database),
    settingsRepositoryProvider.overrideWithValue(settingsRepository),
    settingsControllerProvider.overrideWithValue(settingsController),
  ];
}
