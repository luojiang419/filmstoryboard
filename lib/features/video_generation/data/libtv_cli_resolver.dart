import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'libtv_cli_models.dart';

typedef LibTvProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<ProcessResult> defaultLibTvProcessRunner(
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
    decodeLibTvProcessOutput(result.stdout),
    decodeLibTvProcessOutput(result.stderr),
  );
}

String decodeLibTvProcessOutput(Object? output) {
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

class LibTvCliResolver {
  const LibTvCliResolver({
    this.processRunner = defaultLibTvProcessRunner,
    this.fallbackCandidates,
  });

  final LibTvProcessRunner processRunner;
  final List<String>? fallbackCandidates;

  Future<LibTvCliEnvironment> resolve() async {
    final executable = await _findExecutable();
    if (executable.isEmpty) {
      return const LibTvCliEnvironment(
        executablePath: '',
        version: '',
        errorMessage:
            'LibTV Skill 已随软件内置，但未检测到 LibTV CLI 程序。请安装 CLI，或将 libtv 加入 PATH。',
      );
    }
    final result = await processRunner(executable, const [
      '--version',
    ], runInShell: false);
    final version = '${result.stdout}'.trim();
    if (result.exitCode != 0 || version.isEmpty) {
      final detail = '${result.stderr}'.trim();
      return LibTvCliEnvironment(
        executablePath: executable,
        version: '',
        errorMessage: detail.isEmpty
            ? 'LibTV CLI 无法执行。'
            : 'LibTV CLI 无法执行：$detail',
      );
    }
    return LibTvCliEnvironment(
      executablePath: executable,
      version: version,
      errorMessage: '',
    );
  }

  Future<String> _findExecutable() async {
    final command = Platform.isWindows ? 'libtv.exe' : 'libtv';
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
    for (final candidate in fallbackCandidates ?? _defaultCandidates(command)) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return '';
  }

  List<String> _defaultCandidates(String command) {
    final userProfile = Platform.environment['USERPROFILE']?.trim() ?? '';
    final home = Platform.environment['HOME']?.trim() ?? '';
    return [
      if (userProfile.isNotEmpty) p.join(userProfile, '.libtv', command),
      if (home.isNotEmpty) p.join(home, '.libtv', command),
    ];
  }
}
