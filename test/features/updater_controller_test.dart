import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/updater/application/updater_controller.dart';
import 'package:filmstoryboard/features/updater/data/updater_service.dart';
import 'package:filmstoryboard/features/updater/domain/app_update_config.dart';
import 'package:filmstoryboard/features/updater/domain/update_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动检查下载完成后默认等待用户确认', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_wait_confirm_',
    );
    final harness = await _createHarness(root);
    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final exitCodes = <int>[];
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: exitCodes.add,
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.beginStartupFlow();
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(service.downloadCount, 1);
    expect(service.launchCount, 0);
    expect(controller.value.hasReadyUpdate, isTrue);
    expect(controller.value.readyFromManualCheck, isFalse);
    expect(controller.shouldShowReadyPrompt, isTrue);
    expect(controller.value.statusMessage, '更新包已下载完成：v9.9.9');
    expect(
      service.lastReleaseSource,
      AppUpdateConfig.defaultReleaseRepositoryUrl,
    );
    expect(exitCodes, isEmpty);
  });

  test('手动检查下载完成后会等待用户确认', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_manual_confirm_',
    );
    final harness = await _createHarness(root);
    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final exitCodes = <int>[];
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: exitCodes.add,
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.checkForUpdates();
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(service.downloadCount, 1);
    expect(service.launchCount, 0);
    expect(controller.value.readyFromManualCheck, isTrue);
    expect(controller.shouldShowReadyPrompt, isTrue);
    expect(controller.value.statusMessage, '更新包已下载完成：v9.9.9');
    expect(exitCodes, isEmpty);
  });

  test('安排下次启动更新会保留安装包并关闭当前提示', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_defer_',
    );
    final harness = await _createHarness(root);
    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: (_) {},
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.checkForUpdates();
    controller.installPendingUpdateOnNextStartup();

    expect(service.launchCount, 0);
    expect(harness.repository.pendingUpdateVersion(), 'v9.9.9');
    expect(harness.repository.dismissedUpdatePromptVersion(), 'v9.9.9');
    expect(controller.shouldShowReadyPrompt, isFalse);
    expect(controller.value.statusMessage, '已安排下次启动更新：v9.9.9');
  });

  test('自动更新开启时下载完成后会直接启动安装流程', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_auto_install_',
    );
    final harness = await _createHarness(root);
    await harness.settingsController.setAutoInstallUpdates(true);
    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final exitCodes = <int>[];
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: exitCodes.add,
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.beginStartupFlow();
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(service.downloadCount, 1);
    expect(service.launchCount, 1);
    expect(service.launchedVersionTag, 'v9.9.9');
    expect(
      p.basename(service.launchedInstallerPath!),
      'filmstoryboard-Setup-9.9.9.exe',
    );
    expect(controller.shouldShowReadyPrompt, isFalse);
    expect(controller.value.statusMessage, '更新进度窗口已打开，正在退出旧版本：v9.9.9');
    expect(exitCodes, [0]);
  });

  test('启动检查会用最新发布替换旧的待安装缓存并等待确认', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_stale_pending_',
    );
    final harness = await _createHarness(root);
    final oldInstaller = File(
      p.join(
        harness.directories.updates.path,
        'windows',
        'filmstoryboard-Setup-9.9.8.exe',
      ),
    );
    await oldInstaller.parent.create(recursive: true);
    await oldInstaller.writeAsBytes(List<int>.filled(8, 1));
    harness.repository.setPendingUpdate(
      versionTag: 'v9.9.8',
      installerPath: oldInstaller.path,
    );
    harness.repository.setDismissedUpdatePromptVersion('v9.9.8');

    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final exitCodes = <int>[];
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: exitCodes.add,
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.beginStartupFlow();
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(controller.value.hasReadyUpdate, isTrue);
    expect(controller.value.readyVersionTag, 'v9.9.9');
    expect(
      p.basename(controller.value.readyInstallerPath!),
      release.installerName,
    );
    expect(harness.repository.pendingUpdateVersion(), 'v9.9.9');
    expect(
      p.basename(harness.repository.pendingUpdateInstallerPath()!),
      release.installerName,
    );
    expect(harness.repository.dismissedUpdatePromptVersion(), isEmpty);
    expect(service.downloadCount, 1);
    expect(service.launchCount, 0);
    expect(controller.shouldShowReadyPrompt, isTrue);
    expect(controller.value.statusMessage, '更新包已下载完成：v9.9.9');
    expect(exitCodes, isEmpty);
  });

  test('选择下次启动更新后启动流程会执行一次安装', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_update_next_startup_',
    );
    final harness = await _createHarness(root);
    final release = const UpdateReleaseInfo(
      versionTag: 'v9.9.9',
      installerName: 'filmstoryboard-Setup-9.9.9.exe',
      installerUrl: 'https://example.com/setup.exe',
      installerSize: 9,
    );
    final pendingInstaller = File(
      p.join(
        harness.directories.updates.path,
        'windows',
        release.installerName,
      ),
    );
    await pendingInstaller.parent.create(recursive: true);
    await pendingInstaller.writeAsBytes(List<int>.filled(9, 1));
    harness.repository.setPendingUpdate(
      versionTag: release.versionTag,
      installerPath: pendingInstaller.path,
    );
    harness.repository.setDismissedUpdatePromptVersion(release.versionTag);

    final service = _FakeUpdaterService(
      directories: harness.directories,
      release: release,
    );
    final exitCodes = <int>[];
    final controller = UpdaterController(
      settingsController: harness.settingsController,
      settingsRepository: harness.repository,
      service: service,
      exitApplication: exitCodes.add,
    );
    addTearDown(() async {
      controller.dispose();
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await controller.beginStartupFlow();
    await Future<void>.delayed(const Duration(milliseconds: 550));

    expect(service.downloadCount, 0);
    expect(service.launchCount, 1);
    expect(service.launchedVersionTag, 'v9.9.9');
    expect(
      p.basename(service.launchedInstallerPath!),
      'filmstoryboard-Setup-9.9.9.exe',
    );
    expect(controller.shouldShowReadyPrompt, isFalse);
    expect(controller.value.statusMessage, '更新进度窗口已打开，正在退出旧版本：v9.9.9');
    expect(exitCodes, [0]);
  });
}

Future<_UpdaterHarness> _createHarness(Directory root) async {
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final repository = SettingsRepository(database, directories);
  final settingsController = SettingsController(
    repository: repository,
    initialSettings: repository.load(),
  );
  return _UpdaterHarness(
    directories: directories,
    database: database,
    repository: repository,
    settingsController: settingsController,
  );
}

class _UpdaterHarness {
  const _UpdaterHarness({
    required this.directories,
    required this.database,
    required this.repository,
    required this.settingsController,
  });

  final AppDirectories directories;
  final AppDatabase database;
  final SettingsRepository repository;
  final SettingsController settingsController;

  Future<void> dispose() async {
    settingsController.dispose();
    database.dispose();
  }
}

class _FakeUpdaterService extends UpdaterService {
  _FakeUpdaterService({required super.directories, required this.release});

  final UpdateReleaseInfo release;
  int downloadCount = 0;
  int launchCount = 0;
  String? launchedVersionTag;
  String? launchedInstallerPath;
  String? lastReleaseSource;

  @override
  Future<UpdateReleaseInfo> fetchLatestRelease({
    required String releaseSource,
    required AppSettings settings,
  }) async {
    lastReleaseSource = releaseSource;
    return release;
  }

  @override
  Future<File> downloadInstaller({
    required UpdateReleaseInfo release,
    required AppSettings settings,
    void Function(double? progress)? onProgress,
  }) async {
    downloadCount++;
    final file = installerFileFor(release);
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsBytes(List<int>.filled(release.installerSize, 1));
    onProgress?.call(1.0);
    return file;
  }

  @override
  Future<bool> launchInstaller({
    required String versionTag,
    required String installerPath,
  }) async {
    launchCount++;
    launchedVersionTag = versionTag;
    launchedInstallerPath = installerPath;
    return true;
  }

  @override
  File installerFileFor(UpdateReleaseInfo release) {
    return File(
      p.join(updatesRootForPlatform('windows').path, release.installerName),
    );
  }
}
