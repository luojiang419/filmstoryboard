import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/video_generation_models.dart';
import 'kling_cli_models.dart';
import 'kling_cli_resolver.dart';

class KlingCliService {
  const KlingCliService({
    this.executable = 'kling',
    this.argumentPrefix = const [],
    this.runInShell,
    this.processRunner = defaultKlingProcessRunner,
    this.processStarter = defaultKlingProcessStarter,
  });

  final String executable;
  final List<String> argumentPrefix;
  final bool? runInShell;
  final KlingProcessRunner processRunner;
  final KlingProcessStarter processStarter;

  bool get _runInShell =>
      runInShell ?? (Platform.isWindows && argumentPrefix.isEmpty);

  Future<void> login() async {
    await _run(const ['login']);
  }

  Future<KlingLoginProcess> startLogin() => processStarter(executable, [
    ...argumentPrefix,
    'login',
  ], runInShell: _runInShell);

  Future<KlingIdentity> whoAmI() async {
    final json = await _run(const ['who_am_i', '--quiet']);
    final body = _body(json);
    final user = _map(body['user']);
    final userId = _text(user['userId'] ?? user['user_id']);
    final availableModels = _map(
      body['availableModels'] ?? body['available_models'],
    );
    final imageToVideo = _map(
      availableModels['image_to_video'] ?? availableModels['imageToVideo'],
    );
    final models = _list(imageToVideo['models'])
        .map(_modelSpec)
        .where((model) => model.model.isNotEmpty)
        .toList(growable: false);
    if (userId.isEmpty || models.isEmpty) {
      throw const KlingCliException('可灵身份响应缺少用户或图生视频模型信息。');
    }
    return KlingIdentity(userId: userId, imageToVideoModels: models);
  }

  Future<Map<String, Object?>> toolList() =>
      _run(const ['tool_list', '--quiet']);

  Future<KlingAccount> account() async {
    final json = await _run(const ['account', '--quiet']);
    final body = _body(json);
    return KlingAccount(
      userId: _text(body['userId'] ?? body['user_id']),
      membershipType: _text(body['membershipType'] ?? body['membership_type']),
      membershipDescription: _text(
        body['membershipTypeDescription'] ??
            body['membership_type_description'],
      ),
      availableCredits: _integer(
        body['availableRemainCredits'] ??
            body['available_remain_credits'] ??
            body['availableCredits'],
      ),
    );
  }

  Future<KlingSubmissionResult> submitImageToVideo({
    required String model,
    required String imagePath,
    List<String> referenceImagePaths = const [],
    String tailImagePath = '',
    required Map<String, String> parameters,
    required String prompt,
  }) async {
    if (model.trim().isEmpty) {
      throw const KlingCliException('提交图生视频前必须选择动态返回的可灵模型。');
    }
    if (imagePath.trim().isEmpty) {
      throw const KlingCliException('图生视频必须提供首帧图。');
    }
    final arguments = <String>[
      'image_to_video',
      '--quiet',
      '--model',
      model,
      '--image',
      imagePath,
      for (final referenceImagePath in referenceImagePaths)
        if (referenceImagePath.trim().isNotEmpty) ...[
          '--image',
          referenceImagePath.trim(),
        ],
      if (tailImagePath.trim().isNotEmpty) ...[
        '--tailImage',
        tailImagePath.trim(),
      ],
    ];
    for (final entry in parameters.entries) {
      if (entry.key == 'prompt' || entry.value.trim().isEmpty) continue;
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(entry.key)) {
        throw KlingCliException('非法可灵参数名：${entry.key}');
      }
      arguments
        ..add('--${entry.key}')
        ..add(entry.value);
    }
    arguments.add(prompt);
    final json = await _run(arguments);
    final body = _body(json);
    final generationId = _text(
      _findValue(body, const ['generationId', 'generation_id', 'generationID']),
    );
    if (generationId.isEmpty) {
      throw KlingCliException(
        '可灵提交成功响应中缺少 generationId。',
        rawOutput: jsonEncode(json),
      );
    }
    return KlingSubmissionResult(generationId: generationId, rawJson: json);
  }

  Future<KlingTaskResult> queryTask(String generationId) async {
    if (generationId.trim().isEmpty) {
      throw const KlingCliException('查询任务时 generationId 不能为空。');
    }
    final json = await _run(['query_tasks', '--quiet', generationId]);
    final body = _body(json);
    final statusValue = _findValue(body, const [
      'taskStatus',
      'task_status',
      'status',
      'state',
    ]);
    final status = VideoGenerationTaskStatus.fromStorage(statusValue);
    final worksValue = _findValue(body, const ['works', 'results', 'outputs']);
    final works = _list(worksValue);
    final work = works.isEmpty ? const <String, Object?>{} : works.first;
    final url = _text(
      work['url'] ??
          _findValue(body, const ['resultUrl', 'result_url', 'videoUrl']),
    );
    final urlWithoutWatermark = _text(
      work['urlWithoutWatermark'] ??
          work['url_without_watermark'] ??
          _findValue(body, const [
            'urlWithoutWatermark',
            'url_without_watermark',
          ]),
    );
    final errorMessage = _text(
      _findValue(body, const [
        'errorMessage',
        'error_message',
        'message',
        'failReason',
      ]),
    );
    return KlingTaskResult(
      generationId: generationId,
      status: status,
      url: url,
      urlWithoutWatermark: urlWithoutWatermark,
      errorMessage: errorMessage,
      rawJson: json,
    );
  }

  Future<Map<String, Object?>> _run(List<String> arguments) async {
    final result = await processRunner(executable, [
      ...argumentPrefix,
      ...arguments,
    ], runInShell: _runInShell);
    final stdout = '${result.stdout}'.trim();
    final stderr = '${result.stderr}'.trim();
    if (result.exitCode != 0) {
      throw KlingCliException(
        stderr.isEmpty ? '可灵 CLI 执行失败。' : stderr,
        exitCode: result.exitCode,
        rawOutput: stdout,
      );
    }
    final json = _decodeJson(stdout);
    if (json['ok'] == false) {
      final body = _body(json);
      final message = _text(
        _findValue(body, const ['message', 'error', 'errorMessage']),
      );
      throw KlingCliException(
        message.isEmpty ? '可灵 CLI 返回失败状态。' : message,
        rawOutput: stdout,
      );
    }
    return json;
  }

  static Map<String, Object?> _decodeJson(String output) {
    if (output.isEmpty) {
      throw const KlingCliException('可灵 CLI 未返回 JSON。');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(output);
    } catch (_) {
      for (final line in output.split(RegExp(r'[\r\n]+')).reversed) {
        try {
          decoded = jsonDecode(line.trim());
          break;
        } catch (_) {
          // 兼容非 quiet 模式偶发的前置日志，只接受最后一个完整 JSON 行。
        }
      }
    }
    if (decoded is! Map) {
      throw KlingCliException('无法解析可灵 CLI JSON。', rawOutput: output);
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  static KlingModelSpec _modelSpec(Map<String, Object?> json) => KlingModelSpec(
    model: _text(json['model']),
    alias: _text(json['alias']),
    description: _text(json['description']),
    arguments: _list(json['arguments'])
        .map((argument) {
          final allowed =
              argument['allowedValues'] ?? argument['allowed_values'];
          return KlingArgumentSpec(
            name: _text(argument['name']),
            required: argument['required'] == true,
            defaultValue: _text(argument['default']),
            allowedValues: _values(
              allowed,
            ).map((value) => _text(value)).toList(growable: false),
            description: _text(argument['description']),
          );
        })
        .toList(growable: false),
    inputs: _list(json['inputs'])
        .map(
          (input) => KlingInputSpec(
            name: _text(input['name']),
            required: input['required'] == true,
            description: _text(input['description']),
          ),
        )
        .where((input) => input.name.isNotEmpty)
        .toList(growable: false),
  );

  static Map<String, Object?> _body(Map<String, Object?> json) =>
      _map(json['body'] ?? json['data'] ?? json);

  static Object? _findValue(Object? value, List<String> keys) {
    if (value is Map) {
      for (final key in keys) {
        if (value.containsKey(key)) return value[key];
      }
      for (final child in value.values) {
        final found = _findValue(child, keys);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final child in value) {
        final found = _findValue(child, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry('$key', value));
  }

  static List<Map<String, Object?>> _list(Object? value) {
    if (value is! List) return const [];
    return value.map(_map).toList(growable: false);
  }

  static List<Object?> _values(Object? value) =>
      value is List ? value : const [];

  static String _text(Object? value) => value == null ? '' : '$value'.trim();

  static int _integer(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => int.tryParse('$value') ?? 0,
  };
}

typedef KlingProcessStarter =
    Future<KlingLoginProcess> Function(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    });

Future<KlingLoginProcess> defaultKlingProcessStarter(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    runInShell: runInShell,
  );
  final stderrBytes = <int>[];
  unawaited(process.stderr.forEach(stderrBytes.addAll).catchError((_) {}));
  unawaited(process.stdout.drain<void>());
  return KlingLoginProcess(
    exitCode: process.exitCode,
    kill: process.kill,
    stderr: () => decodeKlingProcessOutput(stderrBytes).trim(),
  );
}

class KlingLoginProcess {
  const KlingLoginProcess({
    required this.exitCode,
    required this.kill,
    required this.stderr,
  });

  final Future<int> exitCode;
  final bool Function([ProcessSignal signal]) kill;
  final String Function() stderr;
}

class KlingResultDownloader {
  const KlingResultDownloader();

  Future<File> download(String url, File destination) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const KlingCliException('可灵结果下载地址无效。');
    }
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    if (partial.existsSync()) await partial.delete();
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw KlingCliException('下载可灵结果失败：HTTP ${response.statusCode}。');
      }
      final output = await partial.open(mode: FileMode.write);
      try {
        await for (final chunk in response) {
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (!partial.existsSync() || await partial.length() == 0) {
        throw const KlingCliException('可灵结果下载为空文件。');
      }
      if (destination.existsSync()) await destination.delete();
      try {
        return await partial.rename(destination.path);
      } on FileSystemException {
        // Windows 可能在流结束后短暂拒绝重命名；复制到最终文件可避免
        // 已下载完成的结果因为句柄释放时序而丢失。
        final copied = await partial.copy(destination.path);
        await partial.delete();
        return copied;
      }
    } finally {
      client.close(force: true);
      if (partial.existsSync()) await partial.delete();
    }
  }
}
