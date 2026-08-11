import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/remote_models.dart';

abstract interface class RemoteApi {
  Uri get baseUri;

  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  });

  Future<Map<String, Object?>> capabilities();
  Future<RemoteWorkspace> workspace();
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards();
  Future<RemoteStoryboardDetail> storyboard(String id);
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  });
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  });
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  });
  Future<List<RemoteScriptSummary>> scripts();
  Future<RemoteScriptDetail> script(String id);

  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  });

  Future<String> webSocketTicket();
  Future<RemoteMediaBytes> media(String id);
  Future<void> logout();
  void close();
}

class RemoteApiFailure implements Exception {
  const RemoteApiFailure({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const {},
  });

  final int statusCode;
  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => message;
}

class HttpRemoteApi implements RemoteApi {
  HttpRemoteApi({Uri? baseUri, http.Client? client})
    : baseUri = baseUri ?? Uri.parse(Uri.base.origin),
      _client = client ?? http.Client();

  @override
  final Uri baseUri;
  final http.Client _client;

  @override
  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  }) async => RemotePairResult.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/auth/pair',
      body: {'code': code, 'clientName': clientName},
    ),
  );

  @override
  Future<Map<String, Object?>> capabilities() =>
      _jsonRequest('GET', '/api/v1/capabilities');

  @override
  Future<RemoteWorkspace> workspace() async =>
      RemoteWorkspace.fromJson(await _jsonRequest('GET', '/api/v1/workspace'));

  @override
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards() async {
    final json = await _jsonRequest('GET', '/api/v1/storyboards');
    return (
      groups: _list(json['groups'])
          .map((item) => RemoteStoryboardGroup.fromJson(_map(item)))
          .toList(growable: false),
      items: _list(json['items'])
          .map((item) => RemoteStoryboardSummary.fromJson(_map(item)))
          .toList(growable: false),
    );
  }

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) async =>
      RemoteStoryboardDetail.fromJson(
        await _jsonRequest(
          'GET',
          '/api/v1/storyboards/${Uri.encodeComponent(id)}',
        ),
      );

  @override
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}',
      body: {'expectedRevision': expectedRevision, 'changes': changes},
    ),
  );

  @override
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}/annotations',
      body: {
        'expectedRevision': expectedRevision,
        'body': body,
        'assetId': ?assetId,
      },
    ),
  );

  @override
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}/annotations/${Uri.encodeComponent(annotationId)}',
      body: {'expectedRevision': expectedRevision, 'changes': changes},
    ),
  );

  @override
  Future<List<RemoteScriptSummary>> scripts() async {
    final json = await _jsonRequest('GET', '/api/v1/scripts');
    final items = json['items'];
    return items is List
        ? items
              .map((item) => RemoteScriptSummary.fromJson(_map(item)))
              .toList(growable: false)
        : const [];
  }

  @override
  Future<RemoteScriptDetail> script(String id) async =>
      RemoteScriptDetail.fromJson(
        await _jsonRequest('GET', '/api/v1/scripts/${Uri.encodeComponent(id)}'),
      );

  @override
  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) async => RemoteScriptDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/scripts/${Uri.encodeComponent(scriptId)}/shots/${Uri.encodeComponent(shotId)}',
      body: {'expectedVersion': expectedVersion, 'changes': changes},
    ),
  );

  @override
  Future<String> webSocketTicket() async {
    final json = await _jsonRequest('POST', '/api/v1/auth/ws-ticket');
    return '${json['ticket'] ?? ''}';
  }

  @override
  Future<RemoteMediaBytes> media(String id) async {
    final response = await _client.get(
      _resolve('/api/v1/media/${Uri.encodeComponent(id)}/content'),
    );
    _throwIfFailed(response);
    return RemoteMediaBytes(
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  @override
  Future<void> logout() async {
    final response = await _client.delete(_resolve('/api/v1/auth/session'));
    _throwIfFailed(response);
  }

  Future<Map<String, Object?>> _jsonRequest(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, _resolve(path));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _throwIfFailed(response);
    if (response.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const RemoteApiFailure(
        statusCode: 502,
        code: 'invalid_response',
        message: '主机返回了无法识别的数据',
      );
    }
    return _map(decoded);
  }

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    try {
      final json = _map(jsonDecode(utf8.decode(response.bodyBytes)));
      final error = _map(json['error']);
      throw RemoteApiFailure(
        statusCode: response.statusCode,
        code: '${error['code'] ?? 'request_failed'}',
        message: '${error['message'] ?? '请求失败'}',
        details: _map(error['details']),
      );
    } on RemoteApiFailure {
      rethrow;
    } catch (_) {
      throw RemoteApiFailure(
        statusCode: response.statusCode,
        code: 'request_failed',
        message: '主机请求失败（${response.statusCode}）',
      );
    }
  }

  Uri _resolve(String path) => baseUri.resolve(path);

  @override
  void close() => _client.close();
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];
