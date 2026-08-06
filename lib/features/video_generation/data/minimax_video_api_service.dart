import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../settings/domain/video_generation_api_config.dart';
import '../domain/video_generation_models.dart';
import 'kling_cli_models.dart';

class MiniMaxVideoApiSubmissionResult {
  const MiniMaxVideoApiSubmissionResult({required this.generationId});

  final String generationId;
}

class MiniMaxVideoApiTaskResult {
  const MiniMaxVideoApiTaskResult({
    required this.status,
    required this.url,
    required this.errorMessage,
  });

  final VideoGenerationTaskStatus status;
  final String url;
  final String errorMessage;
}

class MiniMaxVideoApiTaskNotFoundException extends KlingCliException {
  const MiniMaxVideoApiTaskNotFoundException(this.generationId, String message)
    : super(message);

  final String generationId;
}

class MiniMaxVideoApiService {
  MiniMaxVideoApiService({http.Client? client}) : _client = client;

  final http.Client? _client;

  Future<MiniMaxVideoApiSubmissionResult> submitImageToVideo({
    required VideoGenerationApiConfig config,
    required String imagePath,
    List<String> referenceImagePaths = const [],
    String tailImagePath = '',
    required Map<String, String> parameters,
    required String prompt,
  }) async {
    final baseUri = _baseUri(config.baseUrl);
    final request = http.MultipartRequest(
      'POST',
      baseUri.replace(path: _joinPath(baseUri.path, '/api/generate-upload')),
    );
    _applyAuthorization(request.headers, config.apiKey);
    final hasTailImage = tailImagePath.trim().isNotEmpty;
    final mode = _modeForSubmission(hasTailImage: hasTailImage);
    request.fields.addAll({
      'mode': mode,
      'prompt': prompt,
      'resolution': parameters['resolution'] ?? '0.2MP 16:9 - 608x352',
      'duration': parameters['duration'] ?? '2',
      'steps': parameters['steps'] ?? '12',
      if ((parameters['seed'] ?? '').trim().isNotEmpty)
        'seed': parameters['seed']!.trim(),
    });
    if (mode == 'references') {
      request.files.add(
        await http.MultipartFile.fromPath('reference_images', imagePath),
      );
      for (final referenceImagePath in referenceImagePaths) {
        if (referenceImagePath.trim().isEmpty) continue;
        request.files.add(
          await http.MultipartFile.fromPath(
            'reference_images',
            referenceImagePath.trim(),
          ),
        );
      }
    } else {
      request.files.add(
        await http.MultipartFile.fromPath('first_frame', imagePath),
      );
      if (hasTailImage) {
        request.files.add(
          await http.MultipartFile.fromPath('last_frame', tailImagePath.trim()),
        );
      }
    }
    final response = await _send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KlingCliException(
        'MiniMax 视频提交失败：HTTP ${response.statusCode} $body',
      );
    }
    final json = _decodeObject(body);
    final id = _text(json['id']);
    if (id.isEmpty) {
      throw KlingCliException('MiniMax 视频提交响应缺少任务 ID。', rawOutput: body);
    }
    return MiniMaxVideoApiSubmissionResult(generationId: id);
  }

  Future<MiniMaxVideoApiTaskResult> queryTask({
    required VideoGenerationApiConfig config,
    required String generationId,
  }) async {
    final baseUri = _baseUri(config.baseUrl);
    final uri = baseUri.replace(
      path: _joinPath(baseUri.path, '/api/jobs/$generationId'),
    );
    final client = _client ?? http.Client();
    try {
      final response = await client.get(
        uri,
        headers: _authorizationHeaders(config.apiKey),
      );
      if (response.statusCode == 404) {
        final recovered = await _queryCompletedWork(
          client: client,
          baseUri: baseUri,
          apiKey: config.apiKey,
          generationId: generationId,
        );
        if (recovered != null) return recovered;
        throw MiniMaxVideoApiTaskNotFoundException(
          generationId,
          'MiniMax 视频任务不存在：$generationId',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw KlingCliException(
          'MiniMax 视频查询失败：HTTP ${response.statusCode} ${response.body}',
        );
      }
      final json = _decodeObject(response.body);
      final statusText = _text(json['status']);
      final status = switch (statusText.toLowerCase()) {
        'done' => VideoGenerationTaskStatus.completed,
        'completed' => VideoGenerationTaskStatus.completed,
        'error' => VideoGenerationTaskStatus.failed,
        'failed' => VideoGenerationTaskStatus.failed,
        'running' => VideoGenerationTaskStatus.running,
        'in_progress' => VideoGenerationTaskStatus.running,
        'queued' => VideoGenerationTaskStatus.queued,
        _ => VideoGenerationTaskStatus.fromStorage(statusText),
      };
      final normalizedStatus =
          status == VideoGenerationTaskStatus.queued &&
              _int(json['jobs_ahead']) == 0
          ? VideoGenerationTaskStatus.running
          : status;
      final output = _firstText(json, const [
        'output',
        'content_url',
        'url',
        'result_url',
      ]);
      if (normalizedStatus != VideoGenerationTaskStatus.completed ||
          output.isEmpty) {
        final recovered = await _queryCompletedWork(
          client: client,
          baseUri: baseUri,
          apiKey: config.apiKey,
          generationId: generationId,
        );
        if (recovered != null) return recovered;
      }
      final message = _text(json['error'] ?? json['message']);
      return MiniMaxVideoApiTaskResult(
        status: normalizedStatus,
        url: output.isEmpty ? '' : _absoluteUrl(baseUri, output),
        errorMessage: normalizedStatus == VideoGenerationTaskStatus.failed
            ? message
            : '',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<bool> cancelTask({
    required VideoGenerationApiConfig config,
    required String generationId,
  }) async {
    final baseUri = _baseUri(config.baseUrl);
    final uri = baseUri.replace(
      path: _joinPath(baseUri.path, '/api/jobs/$generationId'),
    );
    final client = _client ?? http.Client();
    try {
      final response = await client.delete(
        uri,
        headers: _authorizationHeaders(config.apiKey),
      );
      if (response.statusCode == 404) return false;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw KlingCliException(
          'MiniMax 视频取消失败：HTTP ${response.statusCode} ${response.body}',
        );
      }
      return true;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<MiniMaxVideoApiTaskResult?> _queryCompletedWork({
    required http.Client client,
    required Uri baseUri,
    required String apiKey,
    required String generationId,
  }) async {
    final uri = baseUri.replace(path: _joinPath(baseUri.path, '/api/works'));
    try {
      final response = await client.get(
        uri,
        headers: _authorizationHeaders(apiKey),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final json = _decodeObject(response.body);
      final items = _workItems(json);
      if (items is! List) return null;
      for (final item in items) {
        if (item is! Map) continue;
        final work = item.map((key, value) => MapEntry('$key', value));
        final id = _firstText(work, const [
          'id',
          'generation_id',
          'generationId',
          'job_id',
          'jobId',
          'task_id',
          'taskId',
        ]);
        if (id != generationId) continue;
        final output = _firstText(work, const [
          'output',
          'content_url',
          'url',
          'result_url',
        ]);
        if (output.isEmpty) return null;
        return MiniMaxVideoApiTaskResult(
          status: VideoGenerationTaskStatus.completed,
          url: _absoluteUrl(baseUri, output),
          errorMessage: '',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<http.StreamedResponse> _send(http.MultipartRequest request) {
    final client = _client;
    if (client != null) return client.send(request);
    return request.send();
  }

  static Uri _baseUri(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const KlingCliException('MiniMax 视频 API 地址无效。');
    }
    return uri;
  }

  static String _joinPath(String basePath, String childPath) {
    final base = basePath.trim().replaceAll(RegExp(r'/+$'), '');
    final child = childPath.trim().replaceAll(RegExp(r'^/+'), '');
    return base.isEmpty ? '/$child' : '$base/$child';
  }

  static String _absoluteUrl(Uri baseUri, String url) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.hasScheme) return parsed.toString();
    return baseUri.replace(path: _joinPath(baseUri.path, url)).toString();
  }

  static void _applyAuthorization(Map<String, String> headers, String apiKey) {
    if (apiKey.trim().isEmpty) return;
    headers['Authorization'] = 'Bearer ${apiKey.trim()}';
  }

  static Map<String, String> _authorizationHeaders(String apiKey) {
    if (apiKey.trim().isEmpty) return const {};
    return {'Authorization': 'Bearer ${apiKey.trim()}'};
  }

  static String _modeForSubmission({required bool hasTailImage}) {
    if (hasTailImage) return 'keyframes';
    return 'references';
  }

  static Map<String, Object?> _decodeObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw KlingCliException('MiniMax 视频 API 返回值不是 JSON 对象。', rawOutput: body);
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  static String _firstText(Map<String, Object?> json, List<String> keys) {
    for (final key in keys) {
      final value = _text(json[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _text(Object? value) => value == null ? '' : '$value'.trim();

  static Object? _workItems(Map<String, Object?> json) {
    for (final key in const ['items', 'works', 'data', 'results']) {
      final value = json[key];
      if (value is List) return value;
      if (value is Map) {
        final nested = value.map((key, value) => MapEntry('$key', value));
        final items = _workItems(nested);
        if (items != null) return items;
      }
    }
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(_text(value));
  }
}
