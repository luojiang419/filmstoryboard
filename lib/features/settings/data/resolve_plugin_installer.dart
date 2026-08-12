import 'dart:io';

import 'package:path/path.dart' as p;

typedef ResolvePluginProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<ProcessResult> defaultResolvePluginProcessRunner(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) {
  return Process.run(
    executable,
    arguments,
    runInShell: runInShell,
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
}

class ResolvePluginInstallResult {
  const ResolvePluginInstallResult({
    required this.message,
    required this.bundleRoot,
  });

  final String message;
  final String bundleRoot;
}

class ResolvePluginInstaller {
  const ResolvePluginInstaller({
    this.processRunner = defaultResolvePluginProcessRunner,
    this.bundleRoot,
    this.executablePath,
    this.currentDirectory,
    this.platformIsWindows,
  });

  static const pluginDirectoryName = 'com.filmstoryboard.timelinebridge';
  static const installScriptName = 'Install-FilmStoryboardResolvePlugin.ps1';

  final ResolvePluginProcessRunner processRunner;
  final String? bundleRoot;
  final String? executablePath;
  final String? currentDirectory;
  final bool? platformIsWindows;

  Future<ResolvePluginInstallResult> install() async {
    if (!(platformIsWindows ?? Platform.isWindows)) {
      throw const ResolvePluginInstallException('达芬奇流程整合插件自动安装当前仅支持 Windows。');
    }

    final resolvedBundleRoot = _resolveBundleRoot();
    final scriptPath = p.join(resolvedBundleRoot, 'windows', installScriptName);
    final pluginSource = p.join(resolvedBundleRoot, pluginDirectoryName);
    final requiredPaths = <String>[
      scriptPath,
      p.join(pluginSource, 'manifest.xml'),
      p.join(pluginSource, 'package.json'),
      p.join(pluginSource, 'main.js'),
    ];
    final missing = requiredPaths.where((path) => !File(path).existsSync());
    if (missing.isNotEmpty) {
      throw ResolvePluginInstallException(
        '软件 data 文件夹中的达芬奇插件包不完整，请重新安装 FilmStoryboard。缺少：${missing.first}',
      );
    }

    final errorLogFile = File(
      p.join(
        Directory.systemTemp.path,
        'filmstoryboard-resolve-plugin-install-$pid-'
        '${DateTime.now().microsecondsSinceEpoch}.log',
      ),
    );
    ProcessResult result;
    try {
      result = await processRunner('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.normalize(scriptPath),
        '-PluginSource',
        p.normalize(pluginSource),
        '-ElevateIfNeeded',
        '-ErrorLogPath',
        p.normalize(errorLogFile.path),
      ], runInShell: false);
    } on ProcessException catch (error) {
      _deleteErrorLog(errorLogFile);
      throw ResolvePluginInstallException('无法启动插件安装程序：${error.message}');
    }

    final errorLog = _readAndDeleteErrorLog(errorLogFile);
    if (result.exitCode != 0) {
      final stderr = _compactOutput(result.stderr);
      final stdout = _compactOutput(result.stdout);
      final detail = errorLog.isNotEmpty
          ? errorLog
          : stderr.isNotEmpty
          ? stderr
          : stdout;
      throw ResolvePluginInstallException(
        detail.isEmpty
            ? '达芬奇插件安装失败，退出码 ${result.exitCode}。请确认已允许管理员权限且 Resolve 官方插件目录可写。'
            : '达芬奇插件安装失败：$detail',
        exitCode: result.exitCode,
      );
    }

    return ResolvePluginInstallResult(
      message: '达芬奇插件文件已复制到 Resolve 流程整合目录。是否能够加载由目标机 Resolve 环境决定。',
      bundleRoot: resolvedBundleRoot,
    );
  }

  String _readAndDeleteErrorLog(File file) {
    var content = '';
    try {
      if (file.existsSync()) {
        content = file.readAsStringSync();
      }
    } on FileSystemException {
      // 读取诊断日志失败时仍回退到 PowerShell 标准输出。
    } finally {
      _deleteErrorLog(file);
    }
    return _compactOutput(content.replaceFirst('\uFEFF', ''));
  }

  void _deleteErrorLog(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 临时诊断日志清理失败不应改变插件部署结果。
    }
  }

  String _resolveBundleRoot() {
    final explicit = bundleRoot?.trim() ?? '';
    if (explicit.isNotEmpty) return p.normalize(explicit);

    final resolvedExecutable = executablePath?.trim().isNotEmpty == true
        ? executablePath!.trim()
        : Platform.resolvedExecutable;
    final installedRoot = p.join(
      File(resolvedExecutable).parent.path,
      'data',
      'resolve_plugin',
    );
    if (_hasInstallScript(installedRoot)) return p.normalize(installedRoot);

    final workingDirectory = currentDirectory?.trim().isNotEmpty == true
        ? currentDirectory!.trim()
        : Directory.current.path;
    final developmentRoot = p.join(workingDirectory, 'resolve_plugin');
    if (_hasInstallScript(developmentRoot)) {
      return p.normalize(developmentRoot);
    }
    return p.normalize(installedRoot);
  }

  bool _hasInstallScript(String root) {
    return File(p.join(root, 'windows', installScriptName)).existsSync();
  }
}

class ResolvePluginInstallException implements Exception {
  const ResolvePluginInstallException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => message;
}

String _compactOutput(Object? output) {
  final text = '$output'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 1200) return text;
  return text.substring(text.length - 1200);
}
