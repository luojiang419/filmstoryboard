import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum KlingCliInstallRegion {
  china('中国区', '@klingai/cli-cn'),
  global('海外区', '@klingai/cli-global');

  const KlingCliInstallRegion(this.label, this.packageName);

  final String label;
  final String packageName;

  static KlingCliInstallRegion? fromName(String? value) {
    for (final region in values) {
      if (region.name == value?.trim()) return region;
    }
    return null;
  }
}

typedef CliInstallProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<ProcessResult> defaultCliInstallProcessRunner(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    runInShell: runInShell,
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  return ProcessResult(
    result.pid,
    result.exitCode,
    _decodeOutput(result.stdout),
    _decodeOutput(result.stderr),
  );
}

class CliDependencyInstaller {
  const CliDependencyInstaller({
    this.processRunner = defaultCliInstallProcessRunner,
    this.libTvInstallerPath,
  });

  static const npmRegistry = 'https://registry.npmjs.org';
  static const nodeJsWingetPackageId = 'OpenJS.NodeJS.LTS';

  final CliInstallProcessRunner processRunner;
  final String? libTvInstallerPath;

  Future<void> installNodeJsLts() async {
    if (!Platform.isWindows) {
      throw const CliDependencyInstallException(
        '自动安装 Node.js 当前仅支持 Windows。请手动安装 Node.js 18 或更高版本。',
      );
    }
    await _run(
      'winget.exe',
      const [
        'install',
        '--id',
        nodeJsWingetPackageId,
        '--exact',
        '--source',
        'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
      ],
      action: '自动安装 Node.js LTS',
      runInShell: true,
    );
  }

  Future<void> installKling({
    required KlingCliInstallRegion region,
    required String npmPath,
  }) async {
    final executable = npmPath.trim();
    if (executable.isEmpty) {
      throw const CliDependencyInstallException(
        '未检测到 npm，无法安装可灵 CLI。请先安装 Node.js 18 或更高版本。',
      );
    }
    await _run(
      executable,
      ['install', '--global', region.packageName, '--registry=$npmRegistry'],
      action: '安装可灵 CLI（${region.label}）',
      runInShell: Platform.isWindows,
    );
  }

  Future<void> installLibTv() async {
    if (!Platform.isWindows) {
      throw const CliDependencyInstallException(
        '自动安装 LibTV CLI 当前仅支持 Windows。',
      );
    }
    final scriptPath = _resolveLibTvInstallerPath();
    if (scriptPath.isEmpty || !File(scriptPath).existsSync()) {
      throw const CliDependencyInstallException(
        '安装包中的 LibTV 官方安装脚本缺失，请重新安装 Film Storyboard。',
      );
    }
    await _run(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
      ],
      action: '安装 LibTV CLI',
      runInShell: false,
    );
  }

  String _resolveLibTvInstallerPath() {
    final explicit = libTvInstallerPath?.trim() ?? '';
    if (explicit.isNotEmpty) return p.normalize(explicit);
    const relative =
        'assets/video_cli_skills/libtv-cli/scripts/'
        'install-libtv-cli.ps1';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      p.join(executableDirectory, 'data', 'flutter_assets', relative),
      p.join(Directory.current.path, relative),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return '';
  }

  Future<void> _run(
    String executable,
    List<String> arguments, {
    required String action,
    required bool runInShell,
  }) async {
    ProcessResult result;
    try {
      result = await processRunner(
        executable,
        arguments,
        runInShell: runInShell,
      );
    } on ProcessException catch (error) {
      throw CliDependencyInstallException(
        '$action失败：无法启动 ${error.executable}。'
        '${executable.toLowerCase().contains('winget') ? '请确认系统已安装“应用安装程序（winget）”。' : ''}',
      );
    }
    if (result.exitCode == 0) return;
    final stderr = _compactOutput(result.stderr);
    final stdout = _compactOutput(result.stdout);
    final detail = stderr.isNotEmpty ? stderr : stdout;
    throw CliDependencyInstallException(
      detail.isEmpty
          ? '$action失败，退出码 ${result.exitCode}。'
          : '$action失败：$detail',
      exitCode: result.exitCode,
    );
  }
}

class CliDependencyInstallException implements Exception {
  const CliDependencyInstallException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => message;
}

String _decodeOutput(Object? output) {
  if (output is String) return output;
  if (output is! List<int>) return '$output';
  try {
    return utf8.decode(output);
  } on FormatException {
    try {
      return systemEncoding.decode(output);
    } catch (_) {
      return latin1.decode(output, allowInvalid: true);
    }
  }
}

String _compactOutput(Object? output) {
  final text = '$output'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 1200) return text;
  return text.substring(text.length - 1200);
}
