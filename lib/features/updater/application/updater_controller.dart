import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../settings/application/settings_controller.dart';
import '../../settings/data/settings_repository.dart';
import '../data/updater_service.dart';
import '../domain/app_update_config.dart';
import '../domain/update_models.dart';

class UpdaterController extends ValueNotifier<UpdaterState> {
  UpdaterController({
    required SettingsController settingsController,
    required SettingsRepository settingsRepository,
    required UpdaterService service,
    void Function(int exitCode)? exitApplication,
  }) : _settingsController = settingsController,
       _settingsRepository = settingsRepository,
       _service = service,
       _exitApplication = exitApplication ?? ((exitCode) => exit(exitCode)),
       super(const UpdaterState.initial());

  final SettingsController _settingsController;
  final SettingsRepository _settingsRepository;
  final UpdaterService _service;
  final void Function(int exitCode) _exitApplication;

  bool _startupFlowStarted = false;

  Future<void> beginStartupFlow() async {
    if (_startupFlowStarted) {
      return;
    }
    _startupFlowStarted = true;
    _clearPendingUpdateIfCurrentOrMissing();
    await checkForUpdates(manual: false);
  }

  Future<void> checkForUpdates({bool manual = true}) async {
    if (value.isBusy) {
      _setStatus('正在检查或下载更新，请稍候。');
      return;
    }

    _clearPendingUpdateIfCurrentOrMissing();

    final settings = _settingsController.value;

    value = value.copyWith(
      isBusy: true,
      statusMessage: manual ? '正在检查最新版本...' : '启动后正在检查最新版本...',
      readyVersionTag: null,
      readyInstallerPath: null,
      downloadProgress: null,
      readyFromManualCheck: manual,
    );

    try {
      final release = await _service.fetchLatestRelease(
        releaseSource: AppUpdateConfig.defaultReleaseRepositoryUrl,
        settings: settings,
      );
      if (UpdaterService.compareVersionTags(
            release.versionTag,
            AppUpdateConfig.currentVersionTag,
          ) <=
          0) {
        value = value.copyWith(
          isBusy: false,
          statusMessage: '当前已是最新版本：${AppUpdateConfig.currentVersionTag}',
          downloadProgress: null,
        );
        return;
      }

      final pending = _readPendingUpdate();
      if (pending != null) {
        if (_pendingMatchesRelease(pending, release)) {
          _settingsRepository.setDownloadedUpdateVersion(release.versionTag);
          _settingsRepository.setPendingUpdate(
            versionTag: release.versionTag,
            installerPath: pending.installerPath,
          );
          if (!_shouldInstallOnNextStartup(
            versionTag: release.versionTag,
            manual: manual,
          )) {
            _settingsRepository.clearDismissedUpdatePromptVersion();
          }
          await _setReadyAndMaybeInstall(
            versionTag: release.versionTag,
            installerPath: pending.installerPath,
            manual: manual,
            message: '已复用更新包：${release.versionTag}',
          );
          return;
        }
        _settingsRepository.clearPendingUpdate();
        _settingsRepository.clearDismissedUpdatePromptVersion();
      }

      final existingInstaller = _existingInstallerFor(release);
      if (existingInstaller != null) {
        _settingsRepository.setDownloadedUpdateVersion(release.versionTag);
        _settingsRepository.setPendingUpdate(
          versionTag: release.versionTag,
          installerPath: existingInstaller.path,
        );
        if (!_shouldInstallOnNextStartup(
          versionTag: release.versionTag,
          manual: manual,
        )) {
          _settingsRepository.clearDismissedUpdatePromptVersion();
        }
        await _setReadyAndMaybeInstall(
          versionTag: release.versionTag,
          installerPath: existingInstaller.path,
          manual: manual,
          message: '已复用更新包：${release.versionTag}',
        );
        return;
      }

      value = value.copyWith(
        statusMessage: '发现新版本 ${release.versionTag}，正在下载更新包...',
        downloadProgress: 0.0,
      );
      final installer = await _service.downloadInstaller(
        release: release,
        settings: settings,
        onProgress: (progress) {
          value = value.copyWith(downloadProgress: progress);
        },
      );
      _settingsRepository.setDownloadedUpdateVersion(release.versionTag);
      _settingsRepository.setPendingUpdate(
        versionTag: release.versionTag,
        installerPath: installer.path,
      );
      _settingsRepository.clearDismissedUpdatePromptVersion();
      await _setReadyAndMaybeInstall(
        versionTag: release.versionTag,
        installerPath: installer.path,
        manual: manual,
        message: '更新包已下载完成：${release.versionTag}',
      );
    } on UpdateException catch (error) {
      if (await _emitPendingUpdate(manual: manual)) {
        return;
      }
      value = value.copyWith(
        isBusy: false,
        statusMessage: error.message,
        downloadProgress: null,
      );
    } catch (error) {
      if (await _emitPendingUpdate(manual: manual)) {
        return;
      }
      value = value.copyWith(
        isBusy: false,
        statusMessage: '检查更新失败：$error',
        downloadProgress: null,
      );
    }
  }

  Future<bool> installPendingUpdateNow({bool quitApp = true}) async {
    _clearPendingUpdateIfCurrentOrMissing();
    final pending = _readPendingUpdate();
    if (pending == null) {
      _setStatus('当前没有可安装的更新包。');
      return false;
    }

    value = value.copyWith(
      isBusy: true,
      statusMessage: '正在打开更新进度窗口：${pending.versionTag}',
      downloadProgress: null,
    );

    try {
      final launched = await _service.launchInstaller(
        versionTag: pending.versionTag,
        installerPath: pending.installerPath,
      );
      if (!launched) {
        value = value.copyWith(
          isBusy: false,
          statusMessage: '无法启动更新进度窗口。',
          downloadProgress: null,
        );
        return false;
      }
      value = value.copyWith(
        isBusy: false,
        statusMessage: '更新进度窗口已打开，正在退出旧版本：${pending.versionTag}',
        downloadProgress: null,
      );
      if (quitApp) {
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            _exitApplication(0);
          }),
        );
      }
      return true;
    } on UpdateException catch (error) {
      value = value.copyWith(
        isBusy: false,
        statusMessage: error.message,
        downloadProgress: null,
      );
      return false;
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        statusMessage: '启动更新进度窗口失败：$error',
        downloadProgress: null,
      );
      return false;
    }
  }

  void dismissReadyPrompt() {
    installPendingUpdateOnNextStartup();
  }

  void installPendingUpdateOnNextStartup() {
    final versionTag = value.readyVersionTag;
    if (versionTag != null) {
      _settingsRepository.setDismissedUpdatePromptVersion(versionTag);
    }
    value = value.copyWith(
      statusMessage: versionTag == null
          ? value.statusMessage
          : '已安排下次启动更新：$versionTag',
      readyFromManualCheck: false,
    );
  }

  bool get shouldShowReadyPrompt {
    if (value.isBusy || !value.hasReadyUpdate) {
      return false;
    }
    if (_settingsController.value.autoInstallUpdates) {
      return false;
    }
    if (value.readyFromManualCheck) {
      return true;
    }
    final versionTag = value.readyVersionTag;
    if (versionTag == null) {
      return false;
    }
    return !_isScheduledForNextStartup(versionTag);
  }

  File? _existingInstallerFor(UpdateReleaseInfo release) {
    final candidates = [_service.installerFileFor(release)];
    for (final file in candidates) {
      if (!file.existsSync()) {
        continue;
      }
      if (release.installerSize > 0 &&
          file.lengthSync() != release.installerSize) {
        continue;
      }
      return file;
    }
    return null;
  }

  bool _pendingMatchesRelease(
    _PendingUpdate pending,
    UpdateReleaseInfo release,
  ) {
    if (UpdaterService.compareVersionTags(
          pending.versionTag,
          release.versionTag,
        ) !=
        0) {
      return false;
    }
    if (release.installerSize <= 0) {
      return true;
    }
    final installer = File(pending.installerPath);
    return installer.existsSync() &&
        installer.lengthSync() == release.installerSize;
  }

  Future<bool> _emitPendingUpdate({required bool manual}) async {
    final pending = _readPendingUpdate();
    if (pending == null) {
      return false;
    }
    await _setReadyAndMaybeInstall(
      versionTag: pending.versionTag,
      installerPath: pending.installerPath,
      manual: manual,
      message: '已找到待安装更新：${pending.versionTag}',
    );
    return true;
  }

  _PendingUpdate? _readPendingUpdate() {
    final versionTag = UpdaterService.normalizeVersionTag(
      _settingsRepository.pendingUpdateVersion() ?? '',
    );
    final installerPath =
        _settingsRepository.pendingUpdateInstallerPath() ?? '';
    if (versionTag.isEmpty || installerPath.trim().isEmpty) {
      return null;
    }
    final installer = File(installerPath);
    if (!installer.existsSync()) {
      return null;
    }
    if (!UpdaterService.installerNameMatchesExpected(
      p.basename(installer.path),
      versionTag,
    )) {
      return null;
    }
    if (UpdaterService.compareVersionTags(
          versionTag,
          AppUpdateConfig.currentVersionTag,
        ) <=
        0) {
      return null;
    }
    return _PendingUpdate(versionTag: versionTag, installerPath: installerPath);
  }

  void _clearPendingUpdateIfCurrentOrMissing() {
    final versionTag = UpdaterService.normalizeVersionTag(
      _settingsRepository.pendingUpdateVersion() ?? '',
    );
    if (versionTag.isEmpty) {
      return;
    }
    if (_readPendingUpdate() == null) {
      _settingsRepository.clearPendingUpdate();
      _settingsRepository.clearDismissedUpdatePromptVersion();
    }
  }

  Future<void> _setReadyAndMaybeInstall({
    required String versionTag,
    required String installerPath,
    required bool manual,
    required String message,
  }) async {
    _setReady(
      versionTag: versionTag,
      installerPath: installerPath,
      manual: manual,
      message: message,
    );
    if (_settingsController.value.autoInstallUpdates ||
        _shouldInstallOnNextStartup(versionTag: versionTag, manual: manual)) {
      await installPendingUpdateNow();
    }
  }

  void _setReady({
    required String versionTag,
    required String installerPath,
    required bool manual,
    required String message,
  }) {
    value = value.copyWith(
      isBusy: false,
      statusMessage: message,
      readyVersionTag: versionTag,
      readyInstallerPath: installerPath,
      downloadProgress: 1.0,
      readyFromManualCheck: manual,
    );
  }

  void _setStatus(String message) {
    value = value.copyWith(statusMessage: message);
  }

  bool _shouldInstallOnNextStartup({
    required String versionTag,
    required bool manual,
  }) {
    if (manual) {
      return false;
    }
    return _isScheduledForNextStartup(versionTag);
  }

  bool _isScheduledForNextStartup(String versionTag) {
    return UpdaterService.compareVersionTags(
          _settingsRepository.dismissedUpdatePromptVersion() ?? '',
          versionTag,
        ) ==
        0;
  }
}

class _PendingUpdate {
  const _PendingUpdate({required this.versionTag, required this.installerPath});

  final String versionTag;
  final String installerPath;
}
