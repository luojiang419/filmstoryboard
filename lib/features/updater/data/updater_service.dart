import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/app_directories.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/app_update_config.dart';
import '../domain/update_models.dart';

typedef UpdaterProcessLauncher =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      ProcessStartMode mode,
      bool runInShell,
    });

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdaterService {
  UpdaterService({
    required AppDirectories directories,
    UpdaterProcessLauncher? processLauncher,
    Directory? scriptRootDirectory,
  }) : _directories = directories,
       _processLauncher = processLauncher ?? _defaultProcessLauncher,
       _scriptRootDirectory = scriptRootDirectory;

  final AppDirectories _directories;
  final UpdaterProcessLauncher _processLauncher;
  final Directory? _scriptRootDirectory;

  static String currentPlatformKey() {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'macos';
    }
    return 'unknown';
  }

  static String normalizeVersionTag(String versionTag) {
    var normalized = versionTag.trim();
    if (normalized.startsWith(RegExp('v', caseSensitive: false))) {
      normalized = normalized.substring(1);
    }
    final buildIndex = normalized.indexOf('+');
    if (buildIndex >= 0) {
      normalized = normalized.substring(0, buildIndex);
    }
    final match = RegExp(r'^\d+(?:\.\d+){0,3}$').firstMatch(normalized);
    if (match == null) {
      return '';
    }
    final parts = normalized.split('.').map(int.parse).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return 'v${parts.join('.')}';
  }

  static int compareVersionTags(String left, String right) {
    final leftParts = _versionParts(normalizeVersionTag(left));
    final rightParts = _versionParts(normalizeVersionTag(right));
    if (leftParts == null && rightParts == null) {
      return 0;
    }
    if (leftParts == null) {
      return -1;
    }
    if (rightParts == null) {
      return 1;
    }
    for (var i = 0; i < leftParts.length; i++) {
      if (leftParts[i] == rightParts[i]) {
        continue;
      }
      return leftParts[i] > rightParts[i] ? 1 : -1;
    }
    return 0;
  }

  static List<String> expectedInstallerNames(
    String versionTag, {
    String? platformKey,
  }) {
    final normalized = normalizeVersionTag(versionTag);
    if (normalized.isEmpty) {
      return const [];
    }

    final platform = (platformKey ?? currentPlatformKey()).trim().toLowerCase();
    final version = normalized.substring(1);
    if (platform == 'windows') {
      return [
        '${AppUpdateConfig.installerBaseName}-$normalized.exe',
        '${AppUpdateConfig.installerBaseName}-$version.exe',
      ];
    }
    return const [];
  }

  static String expectedInstallerName(
    String versionTag, {
    String? platformKey,
  }) {
    final names = expectedInstallerNames(versionTag, platformKey: platformKey);
    return names.isEmpty ? '' : names.first;
  }

  static String latestReleaseApiUrlForSource(String releaseSource) {
    var source = releaseSource.trim();
    if (source.isEmpty) {
      source = AppUpdateConfig.defaultReleaseRepositoryUrl.trim();
    }
    if (source.isEmpty) {
      return '';
    }

    final repository = _githubRepositoryFromSource(source);
    if (repository == null) {
      return '';
    }
    return 'https://api.github.com/repos/${repository.owner}/${repository.name}/releases/latest';
  }

  static bool installerNameMatchesExpected(
    String installerName,
    String versionTag, {
    String? platformKey,
  }) {
    final expectedNames = expectedInstallerNames(
      versionTag,
      platformKey: platformKey,
    );
    return expectedNames.any(
      (expected) => expected.toLowerCase() == installerName.toLowerCase(),
    );
  }

  static UpdaterInstallSession? parseInstallSessionArgs(List<String> args) {
    final sessionId = _argumentValue(args, AppUpdateConfig.updaterSessionArg);
    if (sessionId == null || sessionId.trim().isEmpty) {
      return null;
    }
    final versionTag = normalizeVersionTag(
      _argumentValue(args, AppUpdateConfig.updaterVersionArg) ?? '',
    );
    final installerPath =
        _argumentValue(args, AppUpdateConfig.updaterInstallerArg) ?? '';
    final installRoot =
        _argumentValue(args, AppUpdateConfig.updaterInstallRootArg) ?? '';
    final oldProcessId = int.tryParse(
      _argumentValue(args, AppUpdateConfig.updaterOldPidArg) ?? '',
    );
    if (versionTag.isEmpty ||
        installerPath.trim().isEmpty ||
        installRoot.trim().isEmpty ||
        oldProcessId == null) {
      return null;
    }
    return UpdaterInstallSession(
      sessionId: sessionId.trim(),
      versionTag: versionTag,
      installerPath: installerPath,
      installRoot: installRoot,
      oldProcessId: oldProcessId,
    );
  }

  static UpdateReleaseInfo parseLatestRelease(
    String payload, {
    String? platformKey,
  }) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      throw const UpdateException('GitHub 发布信息解析失败。');
    }
    if (decoded is! Map<String, Object?>) {
      throw const UpdateException('GitHub 发布信息解析失败。');
    }

    final versionTag = normalizeVersionTag(
      decoded['tag_name']?.toString() ?? '',
    );
    if (versionTag.isEmpty) {
      throw const UpdateException('GitHub 发布信息缺少有效版本号。');
    }

    final expectedNames = expectedInstallerNames(
      versionTag,
      platformKey: platformKey,
    );
    if (expectedNames.isEmpty) {
      throw const UpdateException('当前平台暂不支持自动匹配更新资产。');
    }

    final assets = decoded['assets'];
    if (assets is! List) {
      throw const UpdateException('GitHub 发布信息缺少安装包资产。');
    }

    for (final expectedName in expectedNames) {
      for (final asset in assets) {
        if (asset is! Map<String, Object?>) {
          continue;
        }
        final assetName = asset['name']?.toString() ?? '';
        if (assetName.toLowerCase() != expectedName.toLowerCase()) {
          continue;
        }
        final downloadUrl =
            asset['browser_download_url']?.toString().trim() ?? '';
        if (downloadUrl.isEmpty) {
          continue;
        }
        return UpdateReleaseInfo(
          versionTag: versionTag,
          installerName: assetName,
          installerUrl: downloadUrl,
          installerSize: _readAssetSize(asset['size']),
        );
      }
    }

    throw UpdateException('最新发布版本缺少当前平台更新包：${expectedNames.join(' / ')}');
  }

  static String latestReleaseStatusMessage(
    int statusCode,
    String networkErrorString,
  ) {
    if (statusCode == 404) {
      return '当前仓库还没有可用的发布版本。';
    }
    final message = networkErrorString.trim().isEmpty
        ? '网络请求没有返回结果。'
        : networkErrorString.trim();
    return '检查更新失败：$message';
  }

  static String normalizedProxyUrl(String proxyUrl) {
    var candidate = proxyUrl.trim();
    if (candidate.isEmpty) {
      return '';
    }
    if (!candidate.contains('://')) {
      candidate = 'http://$candidate';
    }
    final uri = Uri.tryParse(candidate);
    final scheme = uri?.scheme.trim().toLowerCase() ?? '';
    if (uri == null ||
        uri.host.trim().isEmpty ||
        (uri.hasPort ? uri.port <= 0 : true) ||
        !{
          'http',
          'https',
          'socks4',
          'socks4a',
          'socks5',
          'socks5h',
        }.contains(scheme)) {
      return '';
    }
    return uri.replace(scheme: scheme).toString();
  }

  static List<String> proxyUrlsForEnvironment(Map<String, String> environment) {
    final urls = <String>[];
    const keys = [
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ];
    for (final key in keys) {
      _appendUnique(urls, normalizedProxyUrl(environment[key] ?? ''));
    }
    return urls;
  }

  static List<String> localProxyCandidates({List<String> hosts = const []}) {
    final resolvedHosts = hosts.isEmpty ? ['127.0.0.1', 'localhost'] : hosts;
    final candidates = <String>[];
    for (final host in resolvedHosts) {
      final normalizedHost = host.trim();
      if (normalizedHost.isEmpty) {
        continue;
      }
      for (final port in [7890, 7897, 7899, 8080, 10809, 20171]) {
        _appendUnique(candidates, 'http://$normalizedHost:$port');
      }
      for (final port in [1080, 10808]) {
        _appendUnique(candidates, 'socks5://$normalizedHost:$port');
      }
    }
    return candidates;
  }

  static Future<String> firstReachableProxyUrl(
    Iterable<String> proxyUrls, {
    Duration timeout = const Duration(milliseconds: 120),
  }) async {
    final normalizedUrls = <String>[];
    for (final proxyUrl in proxyUrls) {
      _appendUnique(normalizedUrls, normalizedProxyUrl(proxyUrl));
    }

    for (final proxyUrl in normalizedUrls) {
      final uri = Uri.parse(proxyUrl);
      try {
        final socket = await Socket.connect(
          uri.host,
          uri.port,
          timeout: timeout,
        );
        await socket.close();
        return proxyUrl;
      } catch (_) {
        continue;
      }
    }
    return '';
  }

  Directory updatesRootForPlatform([String? platformKey]) {
    final platform = (platformKey ?? currentPlatformKey()).trim().toLowerCase();
    return Directory(p.join(_directories.updates.path, platform));
  }

  File installerFileFor(UpdateReleaseInfo release) {
    return File(p.join(updatesRootForPlatform().path, release.installerName));
  }

  Future<UpdateReleaseInfo> fetchLatestRelease({
    required String releaseSource,
    required AppSettings settings,
  }) async {
    final releaseApiUrl = latestReleaseApiUrlForSource(releaseSource);
    if (releaseApiUrl.isEmpty) {
      throw const UpdateException('请先配置公开 GitHub 仓库地址。');
    }

    final proxyUrl = await configuredProxyUrl(settings);
    try {
      return await _fetchLatestReleaseWithProxy(releaseApiUrl, proxyUrl);
    } on UpdateException {
      if (proxyUrl.isEmpty) {
        rethrow;
      }
      return _fetchLatestReleaseWithProxy(releaseApiUrl, '');
    }
  }

  Future<File> downloadInstaller({
    required UpdateReleaseInfo release,
    required AppSettings settings,
    void Function(double? progress)? onProgress,
  }) async {
    final proxyUrl = await configuredProxyUrl(settings);
    try {
      return await _downloadInstallerWithProxy(
        release: release,
        proxyUrl: proxyUrl,
        onProgress: onProgress,
      );
    } on UpdateException {
      if (proxyUrl.isEmpty) {
        rethrow;
      }
      return _downloadInstallerWithProxy(
        release: release,
        proxyUrl: '',
        onProgress: onProgress,
      );
    }
  }

  Future<String> configuredProxyUrl(AppSettings settings) async {
    switch (settings.updateDownloadMode) {
      case UpdateDownloadMode.direct:
        return '';
      case UpdateDownloadMode.manual:
        final proxyUrl = normalizedProxyUrl(settings.updateManualProxyUrl);
        if (proxyUrl.isEmpty) {
          throw const UpdateException(
            '手动代理地址无效，请填写类似 http://127.0.0.1:7890 的地址。',
          );
        }
        return proxyUrl;
      case UpdateDownloadMode.automatic:
        final candidates = <String>[];
        for (final proxyUrl in proxyUrlsForEnvironment(Platform.environment)) {
          _appendUnique(candidates, proxyUrl);
        }
        final hosts = await _localProxyHosts();
        for (final proxyUrl in localProxyCandidates(hosts: hosts)) {
          _appendUnique(candidates, proxyUrl);
        }
        return firstReachableProxyUrl(candidates);
    }
  }

  Future<bool> launchInstaller({
    required String versionTag,
    required String installerPath,
  }) async {
    if (!Platform.isWindows) {
      throw UpdateException('当前平台暂未实现自动安装，请手动打开更新包：$installerPath');
    }

    final installer = File(installerPath);
    if (!installer.existsSync()) {
      throw UpdateException('更新安装包不存在：$installerPath');
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    final sessionId = _safeSessionId(
      'update_${DateTime.now().microsecondsSinceEpoch}',
    );
    final runtime = await _stageUpdaterRuntime(
      sessionId: sessionId,
      sourceRootDir: appDir,
      sourceExecutablePath: Platform.resolvedExecutable,
    );
    final launchedPid = await _processLauncher(
      runtime.executablePath,
      [
        '${AppUpdateConfig.updaterSessionArg}$sessionId',
        '${AppUpdateConfig.updaterVersionArg}$versionTag',
        '${AppUpdateConfig.updaterInstallerArg}${installer.path}',
        '${AppUpdateConfig.updaterInstallRootArg}$appDir',
        '${AppUpdateConfig.updaterOldPidArg}$pid',
      ],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    return launchedPid > 0;
  }

  Future<void> runUpdaterSession(
    UpdaterInstallSession session, {
    required void Function(UpdaterProgressEvent event) onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw const UpdateException('当前平台暂未实现自动安装。');
    }
    final installer = File(session.installerPath);
    if (!installer.existsSync()) {
      throw UpdateException('更新安装包不存在：${session.installerPath}');
    }
    final installRoot = Directory(session.installRoot);
    if (!installRoot.existsSync()) {
      throw UpdateException('安装目录不存在：${session.installRoot}');
    }

    onProgress(
      const UpdaterProgressEvent(
        stepIndex: 0,
        stepLabel: '准备安装',
        message: '正在准备独立更新器会话...',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    onProgress(
      const UpdaterProgressEvent(
        stepIndex: 1,
        stepLabel: '关闭旧版本',
        message: '正在等待旧版本退出...',
        substep: '主程序即将关闭，更新窗口会继续完成安装。',
      ),
    );
    await _waitForProcessExit(session.oldProcessId);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    onProgress(
      const UpdaterProgressEvent(
        stepIndex: 2,
        stepLabel: '安装新版本',
        message: '正在启动静默安装程序...',
        substep: '系统可能会请求管理员权限确认。',
      ),
    );
    final installerExitCode = await _runSilentInstaller(
      session: session,
      installer: installer,
    );
    if (installerExitCode != 0) {
      onProgress(
        UpdaterProgressEvent(
          stepIndex: 2,
          stepLabel: '安装新版本',
          message: '安装程序退出码：$installerExitCode',
          substep: '请重新打开故事板后在设置页重试。',
          isError: true,
        ),
      );
      return;
    }

    onProgress(
      const UpdaterProgressEvent(
        stepIndex: 3,
        stepLabel: '启动新版本',
        message: '安装完成，正在启动新版本...',
        substep: '正在等待新版主程序可用。',
      ),
    );
    final appExe = File(
      p.join(session.installRoot, p.basename(Platform.resolvedExecutable)),
    );
    await _waitForFile(appExe);
    await Future<void>.delayed(
      const Duration(
        milliseconds: AppUpdateConfig.updaterRelaunchDelayMilliseconds,
      ),
    );
    await Process.start(
      appExe.path,
      const [],
      mode: ProcessStartMode.detached,
      workingDirectory: session.installRoot,
    );

    onProgress(
      UpdaterProgressEvent(
        stepIndex: 4,
        stepLabel: '完成',
        message: '已启动 ${session.versionTag}',
        substep: '更新完成。',
        isSuccess: true,
      ),
    );
  }

  Future<UpdateReleaseInfo> _fetchLatestReleaseWithProxy(
    String releaseApiUrl,
    String proxyUrl,
  ) async {
    final arguments = [
      ..._curlNetworkArguments(proxyUrl),
      '-L',
      '--silent',
      '--show-error',
      '--connect-timeout',
      '20',
      '--max-time',
      '60',
      '-H',
      'User-Agent: ${AppUpdateConfig.userAgent}',
      '-H',
      'Accept: application/vnd.github+json',
      '--output',
      '-',
      '--write-out',
      '\n%{http_code}',
      releaseApiUrl,
    ];

    final result = await _runCurl(arguments);
    if (result.exitCode != 0) {
      throw UpdateException(
        latestReleaseStatusMessage(0, result.errorOutput(result.stdout)),
      );
    }

    final output = result.stdout.replaceAll('\r\n', '\n').trim();
    final separatorIndex = output.lastIndexOf('\n');
    if (separatorIndex <= 0) {
      throw const UpdateException('检查更新失败：版本检查结果无法解析。');
    }

    final payload = output.substring(0, separatorIndex);
    final statusCode =
        int.tryParse(output.substring(separatorIndex + 1).trim()) ?? 0;
    if (statusCode != 200) {
      throw UpdateException(
        latestReleaseStatusMessage(statusCode, result.stderr),
      );
    }

    try {
      return parseLatestRelease(payload);
    } on FormatException {
      throw const UpdateException('GitHub 发布信息解析失败。');
    }
  }

  Future<File> _downloadInstallerWithProxy({
    required UpdateReleaseInfo release,
    required String proxyUrl,
    void Function(double? progress)? onProgress,
  }) async {
    final updatesRoot = updatesRootForPlatform();
    if (!updatesRoot.existsSync()) {
      await updatesRoot.create(recursive: true);
    }

    final target = installerFileFor(release);
    if (target.existsSync() &&
        (release.installerSize <= 0 ||
            target.lengthSync() == release.installerSize)) {
      onProgress?.call(1.0);
      return target;
    }

    final partFile = File('${target.path}.part');
    if (partFile.existsSync()) {
      await partFile.delete();
    }

    final arguments = [
      ..._curlNetworkArguments(proxyUrl),
      '-L',
      '--silent',
      '--show-error',
      '--connect-timeout',
      '20',
      '--max-time',
      '600',
      '-H',
      'User-Agent: ${AppUpdateConfig.userAgent}',
      '--output',
      partFile.path,
      release.installerUrl,
    ];

    late final Process process;
    try {
      process = await Process.start(
        'curl.exe',
        arguments,
        workingDirectory: updatesRoot.path,
      );
    } on ProcessException catch (error) {
      throw UpdateException('无法启动更新包下载进程：${error.message}');
    }

    final stderr = StringBuffer();
    final stdout = StringBuffer();
    final stderrSub = process.stderr
        .transform(systemEncoding.decoder)
        .listen(stderr.write);
    final stdoutSub = process.stdout
        .transform(systemEncoding.decoder)
        .listen(stdout.write);
    final timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (release.installerSize <= 0 || !partFile.existsSync()) {
        onProgress?.call(null);
        return;
      }
      final progress = partFile.lengthSync() / release.installerSize;
      onProgress?.call(progress.clamp(0, 0.98).toDouble());
    });

    final exitCode = await process.exitCode;
    timer.cancel();
    await stderrSub.cancel();
    await stdoutSub.cancel();

    if (exitCode != 0) {
      if (partFile.existsSync()) {
        await partFile.delete();
      }
      final message = stderr.toString().trim().isEmpty
          ? stdout.toString().trim()
          : stderr.toString().trim();
      throw UpdateException('下载更新包失败：${message.isEmpty ? '未知错误' : message}');
    }

    if (!partFile.existsSync() || partFile.lengthSync() <= 0) {
      if (partFile.existsSync()) {
        await partFile.delete();
      }
      throw const UpdateException('下载更新包失败：未生成完整安装包。');
    }

    if (release.installerSize > 0 &&
        partFile.lengthSync() != release.installerSize) {
      await partFile.delete();
      throw const UpdateException('下载更新包失败：安装包大小与发布资产不一致。');
    }

    if (target.existsSync()) {
      await target.delete();
    }
    await partFile.rename(target.path);
    onProgress?.call(1.0);
    return target;
  }

  Future<_PreparedUpdaterRuntime> _stageUpdaterRuntime({
    required String sessionId,
    required String sourceRootDir,
    required String sourceExecutablePath,
  }) async {
    final root = _scriptRootDirectory ?? updatesRootForPlatform();
    final runtimeDir = Directory(
      p.join(root.path, 'staging', '${_safeSessionId(sessionId)}_runtime'),
    );
    if (runtimeDir.existsSync()) {
      await runtimeDir.delete(recursive: true);
    }
    await runtimeDir.create(recursive: true);

    final sourceRoot = Directory(sourceRootDir);
    if (!sourceRoot.existsSync()) {
      throw UpdateException('更新器源目录不存在：$sourceRootDir');
    }
    await for (final entity in sourceRoot.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File) {
        await entity.copy(p.join(runtimeDir.path, name));
        continue;
      }
      if (entity is Directory && name.toLowerCase() == 'data') {
        await _copyFlutterRuntimeData(
          entity,
          Directory(p.join(runtimeDir.path, name)),
        );
      }
    }

    final executablePath = p.join(
      runtimeDir.path,
      p.basename(sourceExecutablePath),
    );
    if (!File(executablePath).existsSync()) {
      throw UpdateException('临时更新器主程序不存在：$executablePath');
    }
    return _PreparedUpdaterRuntime(
      runtimeDir: runtimeDir.path,
      executablePath: executablePath,
    );
  }

  Future<void> _copyFlutterRuntimeData(
    Directory source,
    Directory target,
  ) async {
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    for (final fileName in ['app.so', 'icudtl.dat']) {
      final file = File(p.join(source.path, fileName));
      if (file.existsSync()) {
        await file.copy(p.join(target.path, fileName));
      }
    }
    final flutterAssets = Directory(p.join(source.path, 'flutter_assets'));
    if (flutterAssets.existsSync()) {
      await _copyDirectoryRecursively(
        flutterAssets,
        Directory(p.join(target.path, 'flutter_assets')),
      );
    }
  }

  Future<void> _copyDirectoryRecursively(
    Directory source,
    Directory target,
  ) async {
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(targetPath);
        continue;
      }
      if (entity is Directory) {
        await _copyDirectoryRecursively(entity, Directory(targetPath));
      }
    }
  }

  Future<int> _runSilentInstaller({
    required UpdaterInstallSession session,
    required File installer,
  }) async {
    final updatesRoot = updatesRootForPlatform();
    if (!updatesRoot.existsSync()) {
      await updatesRoot.create(recursive: true);
    }
    final sessionRoot = Directory(
      p.join(updatesRoot.path, 'sessions', _safeSessionId(session.sessionId)),
    );
    if (!sessionRoot.existsSync()) {
      await sessionRoot.create(recursive: true);
    }
    final logPath = p.join(sessionRoot.path, 'installer.log');
    final scriptLogPath = p.join(sessionRoot.path, 'updater.log');
    final scriptFile = File(p.join(sessionRoot.path, 'install-update.ps1'));
    final scriptLines = [
      r"$ErrorActionPreference = 'Stop'",
      '\$installerPath = ${_toPowerShellLiteral(installer.path)}',
      '\$appDir = ${_toPowerShellLiteral(session.installRoot)}',
      '\$installerLogPath = ${_toPowerShellLiteral(logPath)}',
      '\$scriptLogPath = ${_toPowerShellLiteral(scriptLogPath)}',
      r'function Write-UpdateLog([string]$message) {',
      r"    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'",
      r"    Add-Content -LiteralPath $scriptLogPath -Value ($timestamp + ' ' + $message) -Encoding UTF8",
      r'}',
      r'try {',
      "    Write-UpdateLog '可视化更新器开始静默安装，目标版本：${session.versionTag}'",
      r'    $installerArgs = @(',
      r"        '/SP-',",
      r"        '/VERYSILENT',",
      r"        '/SUPPRESSMSGBOXES',",
      r"        '/NORESTART',",
      r"        '/NOCANCEL',",
      r"        '/CLOSEAPPLICATIONS',",
      r"        '/FORCECLOSEAPPLICATIONS',",
      r'        "/DIR=`"$appDir`"",',
      r'        "/LOG=`"$installerLogPath`""',
      r'    )',
      r'    $process = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -Verb RunAs -Wait -PassThru',
      r"    Write-UpdateLog ('安装进程已结束，ExitCode=' + $process.ExitCode)",
      r'    exit $process.ExitCode',
      r'} catch {',
      r"    Write-UpdateLog ('安装脚本失败：' + $_.Exception.Message)",
      r'    exit 1',
      r'}',
    ];
    await scriptFile.writeAsBytes([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(scriptLines.join('\r\n')),
    ]);
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
      ],
      mode: ProcessStartMode.normal,
      runInShell: false,
    );
    return process.exitCode;
  }

  Future<void> _waitForProcessExit(int processId) async {
    if (processId <= 0 || processId == pid) {
      return;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (DateTime.now().isBefore(deadline)) {
      if (!await _processExists(processId)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<bool> _processExists(int processId) async {
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          'if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: systemEncoding,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForFile(File file) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (file.existsSync()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  static Future<_CurlResult> _runCurl(List<String> arguments) async {
    try {
      final result = await Process.run(
        'curl.exe',
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: systemEncoding,
      );
      return _CurlResult(
        exitCode: result.exitCode,
        stdout: result.stdout?.toString() ?? '',
        stderr: result.stderr?.toString() ?? '',
      );
    } on ProcessException catch (error) {
      throw UpdateException('无法启动版本检查进程：${error.message}');
    }
  }

  static List<String> _curlNetworkArguments(String proxyUrl) {
    if (proxyUrl.trim().isEmpty) {
      return ['--noproxy', '*'];
    }
    return ['--proxy', proxyUrl.trim()];
  }

  static List<int>? _versionParts(String versionTag) {
    final normalized = normalizeVersionTag(versionTag);
    if (normalized.isEmpty) {
      return null;
    }
    final parts = normalized.substring(1).split('.').map(int.parse).toList();
    while (parts.length < 4) {
      parts.add(0);
    }
    return parts;
  }

  static int _readAssetSize(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static _GitHubRepository? _githubRepositoryFromSource(String source) {
    final shorthand = RegExp(
      r'^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$',
    ).firstMatch(source);
    if (shorthand != null) {
      return _GitHubRepository.fromParts(
        shorthand.group(1)!,
        shorthand.group(2)!,
      );
    }

    var candidate = source;
    if (!candidate.contains('://')) {
      candidate = 'https://$candidate';
    }
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.trim().isEmpty) {
      return null;
    }

    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (host == 'api.github.com') {
      if (segments.length < 3 || segments[0].toLowerCase() != 'repos') {
        return null;
      }
      return _GitHubRepository.fromParts(segments[1], segments[2]);
    }

    if (host == 'github.com' || host == 'www.github.com') {
      if (segments.length < 2) {
        return null;
      }
      return _GitHubRepository.fromParts(segments[0], segments[1]);
    }

    return null;
  }

  static void _appendUnique(List<String> items, String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (items.any((item) => item.toLowerCase() == normalized.toLowerCase())) {
      return;
    }
    items.add(normalized);
  }

  static Future<List<String>> _localProxyHosts() async {
    final hosts = <String>['127.0.0.1', 'localhost'];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          _appendUnique(hosts, address.address);
        }
      }
    } catch (_) {
      return hosts;
    }
    return hosts;
  }

  static String _toPowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  static String? _argumentValue(List<String> args, String prefix) {
    for (final arg in args) {
      if (arg.startsWith(prefix)) {
        return arg.substring(prefix.length);
      }
    }
    return null;
  }

  static String _safeSessionId(String value) {
    return value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
  }
}

class _PreparedUpdaterRuntime {
  const _PreparedUpdaterRuntime({
    required this.runtimeDir,
    required this.executablePath,
  });

  final String runtimeDir;
  final String executablePath;
}

Future<int> _defaultProcessLauncher(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode = ProcessStartMode.normal,
  bool runInShell = false,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    mode: mode,
    runInShell: runInShell,
  );
  return process.pid;
}

class _GitHubRepository {
  const _GitHubRepository({required this.owner, required this.name});

  final String owner;
  final String name;

  static _GitHubRepository? fromParts(String owner, String name) {
    final normalizedOwner = owner.trim();
    final normalizedName = name.trim().replaceFirst(
      RegExp(r'\.git$', caseSensitive: false),
      '',
    );
    if (!_isValidPart(normalizedOwner) || !_isValidPart(normalizedName)) {
      return null;
    }
    return _GitHubRepository(owner: normalizedOwner, name: normalizedName);
  }

  static bool _isValidPart(String value) {
    return RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);
  }
}

class _CurlResult {
  const _CurlResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String errorOutput(String fallback) {
    final message = stderr.trim().isEmpty ? fallback.trim() : stderr.trim();
    return message.isEmpty ? '未知错误' : message;
  }
}
