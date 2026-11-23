import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'libtv_cli_models.dart';
import 'libtv_cli_resolver.dart';

typedef LibTvProcessStarter =
    Future<LibTvRunningProcess> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<LibTvRunningProcess> defaultLibTvProcessStarter(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    runInShell: runInShell,
  );
  final stdoutBytes = <int>[];
  final stderrBytes = <int>[];
  unawaited(process.stdout.forEach(stdoutBytes.addAll).catchError((_) {}));
  unawaited(process.stderr.forEach(stderrBytes.addAll).catchError((_) {}));
  return LibTvRunningProcess(
    exitCode: process.exitCode,
    kill: process.kill,
    stdout: () => decodeLibTvProcessOutput(stdoutBytes).trim(),
    stderr: () => decodeLibTvProcessOutput(stderrBytes).trim(),
  );
}

class LibTvRunningProcess {
  const LibTvRunningProcess({
    required this.exitCode,
    required this.kill,
    required this.stdout,
    required this.stderr,
  });

  final Future<int> exitCode;
  final bool Function([ProcessSignal signal]) kill;
  final String Function() stdout;
  final String Function() stderr;
}

class LibTvCliService {
  const LibTvCliService({
    this.executable = 'libtv',
    this.runInShell = false,
    this.processRunner = defaultLibTvProcessRunner,
    this.processStarter = defaultLibTvProcessStarter,
    this.delay = Future<void>.delayed,
  });

  static const seedance20ModelName = 'Seedance 2.0';

  final String executable;
  final bool runInShell;
  final LibTvProcessRunner processRunner;
  final LibTvProcessStarter processStarter;
  final Future<void> Function(Duration duration) delay;

  Future<LibTvRunningProcess> startLogin() => processStarter(executable, const [
    'login',
    'web',
    '--open',
  ], runInShell: runInShell);

  Future<LibTvAccountInfo> accountInfo() async {
    final json = await _run(const ['account', 'info']);
    final user = _map(_findValue(json, const ['user']));
    final account = _map(_findValue(json, const ['activeAccount']));
    final userId = _text(user['uuid'] ?? user['id']);
    if (userId.isEmpty) {
      throw LibTvCliException('LibTV 身份响应缺少用户信息。', rawOutput: jsonEncode(json));
    }
    return LibTvAccountInfo(
      userId: userId,
      nickname: _text(user['nickname'] ?? user['name']),
      accountName: _text(account['accountName'] ?? account['name']),
      teamId: _integer(json['teamId'] ?? account['teamId']),
    );
  }

  Future<List<LibTvModelSummary>> videoModels() async {
    final json = await _run(const ['model', 'search', '--type', 'video']);
    final result = <LibTvModelSummary>[];
    final seen = <String>{};
    for (final match in _mapsDeep(json)) {
      final modelName = _text(match['modelName']);
      final modelKey = _text(match['modelKey']);
      if (modelName.isEmpty || modelKey.isEmpty || !seen.add(modelKey)) {
        continue;
      }
      result.add(
        LibTvModelSummary(
          modelName: modelName,
          modelKey: modelKey,
          modality: _text(match['modality']).isEmpty
              ? 'video'
              : _text(match['modality']),
        ),
      );
    }
    if (result.isEmpty) {
      throw LibTvCliException(
        'LibTV 没有返回可用的视频模型。',
        rawOutput: jsonEncode(json),
      );
    }
    return List.unmodifiable(result);
  }

  Future<LibTvModelSpec> model(String name) async {
    final json = await _run(['model', name]);
    final modelName = _text(_findValue(json, const ['modelName']));
    final modelKey = _text(_findValue(json, const ['modelKey']));
    if (modelName.isEmpty || modelKey.isEmpty) {
      throw LibTvCliException(
        'LibTV 模型响应缺少 modelName 或 modelKey。',
        rawOutput: jsonEncode(json),
      );
    }
    return LibTvModelSpec(
      modelName: modelName,
      modelKey: modelKey,
      modality: _text(_findValue(json, const ['modality'])),
      schema: _map(_findValue(json, const ['schema'])),
    );
  }

  Future<String> ensureScriptProject({
    required String scriptId,
    required String scriptName,
  }) async {
    final projectName = scriptProjectName(scriptId, scriptName);
    final listed = await _run([
      'project',
      'list',
      '--name',
      projectName,
      '--page-size',
      '100',
    ]);
    for (final project in _mapsDeep(listed)) {
      final name = _text(project['name'] ?? project['projectName']);
      final uuid = _text(project['uuid'] ?? project['projectUuid']);
      if (name == projectName && uuid.isNotEmpty) return uuid;
    }
    final created = await _run([
      'project',
      'create',
      projectName,
      '--description',
      '由 Film Storyboard 自动创建，用于脚本 $scriptId 的视频生成。',
    ]);
    final uuid = _text(_findValue(created, const ['uuid', 'projectUuid']));
    if (uuid.isEmpty) {
      throw LibTvCliException(
        'LibTV 创建画布成功响应中缺少画布 UUID。',
        rawOutput: jsonEncode(created),
      );
    }
    return uuid;
  }

  Future<LibTvGenerationResult> generateImageToVideo({
    required String scriptId,
    required String scriptName,
    required String taskId,
    required String prompt,
    required String sourceImagePath,
    List<String> referenceImagePaths = const [],
    String modelName = seedance20ModelName,
    String ratio = '16:9',
    String resolution = '720p',
    required int durationSeconds,
    bool enableSound = true,
    bool searchEnabled = true,
    Map<String, String> parameters = const {},
    bool Function()? isCanceled,
  }) async {
    if (!File(sourceImagePath).existsSync()) {
      throw const LibTvCliException('LibTV 图生视频缺少首帧图。');
    }
    final imagePaths = [
      sourceImagePath,
      for (final path in referenceImagePaths)
        if (path.trim().isNotEmpty) path.trim(),
    ];
    for (final path in imagePaths) {
      if (!File(path).existsSync()) {
        throw LibTvCliException('LibTV 参考图不存在：$path');
      }
    }
    if (isCanceled?.call() == true) {
      throw const LibTvGenerationCanceledException();
    }
    final projectUuid = await ensureScriptProject(
      scriptId: scriptId,
      scriptName: scriptName,
    );
    final suffix = _safeSuffix(taskId);
    final imageNodeKeys = <String>[];
    for (var index = 0; index < imagePaths.length; index += 1) {
      if (isCanceled?.call() == true) {
        throw const LibTvGenerationCanceledException();
      }
      final uploaded = await _run([
        'upload',
        'FS-$suffix-图片${index + 1}',
        '--type',
        'image',
        '--resource',
        imagePaths[index],
        '--project',
        projectUuid,
      ]);
      final nodeKey = _text(
        _findValue(uploaded, const ['nodeKey', 'newNodeKey']),
      );
      if (nodeKey.isEmpty) {
        throw LibTvCliException(
          'LibTV 上传图片成功响应中缺少 nodeKey。',
          rawOutput: jsonEncode(uploaded),
        );
      }
      imageNodeKeys.add(nodeKey);
    }
    final normalizedPrompt = promptWithNodeReferences(prompt, imageNodeKeys);
    final nodeName = 'FS-$suffix-视频';
    final generationParameters = parameters.isEmpty
        ? <String, String>{
            'modeType': 'mixed2video',
            'count': '1',
            'ratio': ratio,
            'resolution': resolution,
            'enableSound': enableSound ? 'on' : 'off',
            'search_enabled': searchEnabled ? '1' : '0',
          }
        : <String, String>{...parameters};
    generationParameters['duration'] = '$durationSeconds';
    final process = await processStarter(executable, [
      'node',
      'create',
      nodeName,
      '--project',
      projectUuid,
      '--type',
      'video',
      '--prompt',
      normalizedPrompt,
      '--set',
      'model=$modelName',
      for (final parameter in generationParameters.entries) ...[
        '--set',
        '${parameter.key}=${parameter.value}',
      ],
      for (final nodeKey in imageNodeKeys) ...['--left', nodeKey],
      '--run',
    ], runInShell: runInShell);
    final exitCode = await _waitForGeneration(process, isCanceled);
    final stdout = process.stdout().trim();
    final stderr = process.stderr().trim();
    if (exitCode != 0) {
      throw LibTvCliException(
        stderr.isEmpty ? 'LibTV 视频生成失败。' : stderr,
        exitCode: exitCode,
        rawOutput: stdout,
      );
    }
    final json = _decodeJson(stdout);
    final videoUrl = _videoUrl(json);
    if (videoUrl.isEmpty) {
      throw LibTvCliException('LibTV 视频节点已结束，但响应中没有视频 URL。', rawOutput: stdout);
    }
    return LibTvGenerationResult(
      projectUuid: projectUuid,
      nodeKey: _text(_findValue(json, const ['nodeKey', 'newNodeKey'])),
      taskId: _text(_findValue(json, const ['taskId', 'generationId'])),
      videoUrl: videoUrl,
      rawJson: json,
    );
  }

  Future<int> _waitForGeneration(
    LibTvRunningProcess process,
    bool Function()? isCanceled,
  ) async {
    while (true) {
      final result = await Future.any<Object?>([
        process.exitCode,
        delay(const Duration(milliseconds: 250)).then<Object?>((_) => null),
      ]);
      if (result is int) return result;
      if (isCanceled?.call() == true) {
        process.kill();
        throw const LibTvGenerationCanceledException();
      }
    }
  }

  Future<Map<String, Object?>> _run(List<String> arguments) async {
    final result = await processRunner(
      executable,
      arguments,
      runInShell: runInShell,
    );
    final stdout = '${result.stdout}'.trim();
    final stderr = '${result.stderr}'.trim();
    if (result.exitCode != 0) {
      throw LibTvCliException(
        stderr.isEmpty ? 'LibTV CLI 执行失败。' : stderr,
        exitCode: result.exitCode,
        rawOutput: stdout,
      );
    }
    return _decodeJson(stdout);
  }

  static Map<String, Object?> _decodeJson(String output) {
    if (output.isEmpty) throw const LibTvCliException('LibTV CLI 未返回 JSON。');
    Object? decoded;
    try {
      decoded = jsonDecode(output);
    } catch (_) {
      for (final line in output.split(RegExp(r'[\r\n]+')).reversed) {
        try {
          decoded = jsonDecode(line.trim());
          break;
        } catch (_) {
          // CLI 的进度信息应走 stderr；这里兼容最后一行才是 JSON 的旧输出。
        }
      }
    }
    if (decoded is! Map) {
      throw LibTvCliException('无法解析 LibTV CLI JSON。', rawOutput: output);
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  static String scriptProjectName(String scriptId, String scriptName) {
    final suffix = _safeSuffix(scriptId);
    final normalizedName = scriptName
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .trim();
    final title = normalizedName.length > 32
        ? normalizedName.substring(0, 32)
        : normalizedName;
    return title.isEmpty
        ? 'Film Storyboard · $suffix'
        : 'Film Storyboard · $suffix · $title';
  }

  static String promptWithNodeReferences(
    String prompt,
    List<String> imageNodeKeys,
  ) {
    var normalized = prompt.trim();
    String replace(Match match) {
      final index = int.tryParse(match.group(1) ?? '') ?? 0;
      if (index < 1 || index > imageNodeKeys.length) return match.group(0)!;
      return '{{Node ${imageNodeKeys[index - 1]}}}';
    }

    normalized = normalized.replaceAllMapped(
      RegExp(r'@?(?:图片|图)\s*(\d+)', caseSensitive: false),
      replace,
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'<Picture\s+(\d+)>', caseSensitive: false),
      replace,
    );
    final definitions = <String>[];
    for (var index = 0; index < imageNodeKeys.length; index += 1) {
      final token = '{{Node ${imageNodeKeys[index]}}}';
      if (normalized.contains(token)) continue;
      definitions.add(
        index == 0 ? '参考$token作为起始画面，保持主体、构图与场景连续。' : '参考$token中的主体、造型或场景特征。',
      );
    }
    return [
      ...definitions,
      normalized,
    ].where((part) => part.trim().isNotEmpty).join('\n');
  }

  static String _safeSuffix(String value) {
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (normalized.isEmpty) return 'task';
    return normalized.length <= 12 ? normalized : normalized.substring(0, 12);
  }

  static String _videoUrl(Map<String, Object?> json) {
    for (final map in _mapsDeep(json)) {
      for (final key in const [
        'videoUrl',
        'resultUrl',
        'urlWithoutWatermark',
        'url',
      ]) {
        final value = map[key];
        if (value is String && _looksLikeVideoUrl(value)) return value.trim();
        if (value is List) {
          for (final item in value) {
            if (item is String && _looksLikeVideoUrl(item)) return item.trim();
          }
        }
      }
    }
    return '';
  }

  static bool _looksLikeVideoUrl(String value) {
    final normalized = value.trim().toLowerCase();
    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      return false;
    }
    return normalized.contains('.mp4') ||
        normalized.contains('.mov') ||
        normalized.contains('.webm') ||
        normalized.contains('video');
  }

  static Iterable<Map<String, Object?>> _mapsDeep(Object? value) sync* {
    if (value is Map) {
      final map = value.map((key, value) => MapEntry('$key', value));
      yield map;
      for (final child in value.values) {
        yield* _mapsDeep(child);
      }
    } else if (value is List) {
      for (final child in value) {
        yield* _mapsDeep(child);
      }
    }
  }

  static Object? _findValue(Object? value, List<String> keys) {
    for (final map in _mapsDeep(value)) {
      for (final key in keys) {
        if (map.containsKey(key)) return map[key];
      }
    }
    return null;
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  static String _text(Object? value) => value == null ? '' : '$value'.trim();

  static int _integer(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => int.tryParse('$value') ?? 0,
  };
}
