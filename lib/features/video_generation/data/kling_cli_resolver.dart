import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef KlingProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<ProcessResult> defaultKlingProcessRunner(
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
    decodeKlingProcessOutput(result.stdout),
    decodeKlingProcessOutput(result.stderr),
  );
}

String decodeKlingProcessOutput(Object? output) {
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

class KlingCliEnvironment {
  const KlingCliEnvironment({
    required this.nodePath,
    required this.nodeVersion,
    required this.npmPath,
    required this.klingPath,
    required this.klingVersion,
    required this.errorMessage,
    this.klingEntryPointPath = '',
  });

  final String nodePath;
  final String nodeVersion;
  final String npmPath;
  final String klingPath;
  final String klingVersion;
  final String errorMessage;
  final String klingEntryPointPath;

  bool get isReady => errorMessage.isEmpty;

  String get commandExecutable =>
      Platform.isWindows && klingEntryPointPath.isNotEmpty
      ? nodePath
      : klingPath;

  List<String> get commandArgumentsPrefix =>
      Platform.isWindows && klingEntryPointPath.isNotEmpty
      ? [klingEntryPointPath]
      : const [];

  bool get commandRunInShell =>
      Platform.isWindows && klingEntryPointPath.isEmpty;
}

class KlingCliResolver {
  const KlingCliResolver({this.processRunner = defaultKlingProcessRunner});

  final KlingProcessRunner processRunner;

  Future<KlingCliEnvironment> resolve() async {
    final nodePath = await _find('node');
    if (nodePath.isEmpty) {
      return _error('未检测到 Node.js，请先安装 Node.js 18 或更高版本。');
    }
    final nodeVersionResult = await processRunner(nodePath, const [
      '--version',
    ], runInShell: Platform.isWindows);
    final nodeVersion = '${nodeVersionResult.stdout}'.trim();
    if (nodeVersionResult.exitCode != 0 || parseNodeMajor(nodeVersion) < 18) {
      return _error('Node.js 版本过低，需要 18 或更高版本；当前为 $nodeVersion。');
    }
    final npmPath = await _find(Platform.isWindows ? 'npm.cmd' : 'npm');
    if (npmPath.isEmpty) return _error('未检测到 npm，无法安装或更新可灵 CLI。');
    final klingPath = await _findKlingCli(npmPath);
    if (klingPath.isEmpty) {
      return _error(
        '未检测到可灵 CLI。可在软件中选择账号区域后自动安装。',
        nodePath: nodePath,
        nodeVersion: nodeVersion,
        npmPath: npmPath,
      );
    }
    final klingEntryPointPath = await _findKlingEntryPoint(klingPath);
    final commandExecutable =
        Platform.isWindows && klingEntryPointPath.isNotEmpty
        ? nodePath
        : klingPath;
    final commandArguments = <String>[
      if (Platform.isWindows && klingEntryPointPath.isNotEmpty)
        klingEntryPointPath,
      '--version',
    ];
    final versionResult = await processRunner(
      commandExecutable,
      commandArguments,
      runInShell: Platform.isWindows && klingEntryPointPath.isEmpty,
    );
    if (versionResult.exitCode != 0) {
      return _error(
        '可灵 CLI 无法执行：${versionResult.stderr}',
        nodePath: nodePath,
        nodeVersion: nodeVersion,
        npmPath: npmPath,
        klingPath: klingPath,
      );
    }
    return KlingCliEnvironment(
      nodePath: nodePath,
      nodeVersion: nodeVersion,
      npmPath: npmPath,
      klingPath: klingPath,
      klingVersion: '${versionResult.stdout}'.trim(),
      errorMessage: '',
      klingEntryPointPath: klingEntryPointPath,
    );
  }

  static int parseNodeMajor(String version) {
    final match = RegExp(r'v?(\d+)').firstMatch(version.trim());
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  Future<String> _find(String command) async {
    final locator = Platform.isWindows ? 'where.exe' : 'which';
    final result = await processRunner(locator, [
      command,
    ], runInShell: Platform.isWindows);
    if (result.exitCode == 0) {
      final candidates = '${result.stdout}'
          .split(RegExp(r'[\r\n]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty);
      if (candidates.isNotEmpty) return candidates.first;
    }
    for (final candidate in _defaultCommandCandidates(command)) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return '';
  }

  List<String> _defaultCommandCandidates(String command) {
    if (!Platform.isWindows) return const [];
    final normalized = command.toLowerCase();
    if (normalized != 'node' && normalized != 'npm.cmd') return const [];
    final fileName = normalized == 'node' ? 'node.exe' : 'npm.cmd';
    final programFiles = Platform.environment['ProgramFiles']?.trim() ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim() ?? '';
    return [
      if (programFiles.isNotEmpty) p.join(programFiles, 'nodejs', fileName),
      if (localAppData.isNotEmpty)
        p.join(localAppData, 'Programs', 'nodejs', fileName),
    ];
  }

  Future<String> _findKlingCli(String npmPath) async {
    final command = Platform.isWindows ? 'kling.cmd' : 'kling';
    final fromPath = await _find(command);
    if (fromPath.isNotEmpty) return fromPath;
    for (final candidate in await _klingCliCandidates(npmPath, command)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return '';
  }

  Future<List<String>> _klingCliCandidates(
    String npmPath,
    String command,
  ) async {
    final candidates = <String>[];
    Future<void> addNpmPrefix() async {
      if (npmPath.trim().isEmpty) return;
      final result = await processRunner(npmPath, const [
        'prefix',
        '-g',
      ], runInShell: Platform.isWindows);
      if (result.exitCode != 0) return;
      final prefix = '${result.stdout}'.trim();
      if (prefix.isEmpty) return;
      candidates.add(p.join(prefix, command));
      if (!Platform.isWindows) candidates.add(p.join(prefix, 'bin', command));
    }

    await addNpmPrefix();
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA']?.trim() ?? '';
      if (appData.isNotEmpty) candidates.add(p.join(appData, 'npm', command));
      final userProfile = Platform.environment['USERPROFILE']?.trim() ?? '';
      if (userProfile.isNotEmpty) {
        candidates.add(
          p.join(userProfile, 'AppData', 'Roaming', 'npm', command),
        );
      }
    }
    return candidates;
  }

  Future<String> _findKlingEntryPoint(String klingPath) async {
    if (!Platform.isWindows || !klingPath.toLowerCase().endsWith('.cmd')) {
      return '';
    }
    final wrapper = File(klingPath);
    final wrapperDirectory = wrapper.parent.path;
    final candidates = <String>[
      p.join(
        wrapperDirectory,
        'node_modules',
        '@klingai',
        'cli-cn',
        'dist',
        'cli.js',
      ),
      p.join(
        wrapperDirectory,
        'node_modules',
        '@klingai',
        'cli',
        'dist',
        'cli.js',
      ),
    ];
    if (wrapper.existsSync()) {
      try {
        final content = await wrapper.readAsString();
        final match = RegExp(
          r'%d[pP]0%[\\/]([^"\r\n]+?\.js)',
        ).firstMatch(content);
        final relativePath = match?.group(1)?.trim() ?? '';
        if (relativePath.isNotEmpty) {
          candidates.insert(
            0,
            p.join(
              wrapperDirectory,
              relativePath.replaceAll(RegExp(r'[\\/]+'), p.separator),
            ),
          );
        }
      } on FileSystemException {
        // npm 标准目录候选仍可继续定位，不因包装脚本临时不可读而中断。
      }
    }
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return '';
  }

  KlingCliEnvironment _error(
    String message, {
    String nodePath = '',
    String nodeVersion = '',
    String npmPath = '',
    String klingPath = '',
  }) => KlingCliEnvironment(
    nodePath: nodePath,
    nodeVersion: nodeVersion,
    npmPath: npmPath,
    klingPath: klingPath,
    klingVersion: '',
    errorMessage: message,
  );
}
