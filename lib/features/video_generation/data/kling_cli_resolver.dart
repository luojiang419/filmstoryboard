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
}) => Process.run(
  executable,
  arguments,
  runInShell: runInShell,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

class KlingCliEnvironment {
  const KlingCliEnvironment({
    required this.nodePath,
    required this.nodeVersion,
    required this.npmPath,
    required this.klingPath,
    required this.klingVersion,
    required this.errorMessage,
  });

  final String nodePath;
  final String nodeVersion;
  final String npmPath;
  final String klingPath;
  final String klingVersion;
  final String errorMessage;

  bool get isReady => errorMessage.isEmpty;
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
        '未检测到可灵 CLI。请先按官方说明安装可灵 Skill：npx skills add klingai-tech/skills；如果需要本软件直接调用命令行，请安装 @klingai/cli-cn。',
        nodePath: nodePath,
        nodeVersion: nodeVersion,
        npmPath: npmPath,
      );
    }
    final versionResult = await processRunner(klingPath, const [
      '--version',
    ], runInShell: Platform.isWindows);
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
    if (result.exitCode != 0) return '';
    final candidates = '${result.stdout}'
        .split(RegExp(r'[\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    return candidates.isEmpty ? '' : candidates.first;
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
