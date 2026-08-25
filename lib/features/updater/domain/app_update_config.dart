class AppUpdateConfig {
  const AppUpdateConfig._();

  static const appName = 'filmstoryboard';
  static const userAgent = 'filmstoryboard';
  static const currentVersion = '1.0.0.361';
  static const currentVersionTag = 'v1.0.0.361';
  static const windowTitle = '$appName $currentVersionTag';
  static const installerBaseName = 'filmstoryboard-Setup';
  static const defaultReleaseRepositoryUrl =
      'https://github.com/luojiang419/storyboard-grid-app-releases';
  static const defaultReleaseApiUrl = defaultReleaseRepositoryUrl;
  static const updaterSessionArg = '--run-update-session=';
  static const updaterVersionArg = '--update-version=';
  static const updaterInstallerArg = '--update-installer=';
  static const updaterInstallRootArg = '--update-install-root=';
  static const updaterOldPidArg = '--update-old-pid=';
  static const updaterRelaunchDelayMilliseconds = 800;
}
