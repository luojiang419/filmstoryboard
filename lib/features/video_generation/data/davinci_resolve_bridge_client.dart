import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/video_timeline_snapshot.dart';

typedef DaVinciBridgeTokenProvider = Future<String> Function();

class DaVinciResolveBridgeClient {
  const DaVinciResolveBridgeClient({
    this.baseUrl = 'http://127.0.0.1:47861',
    this.timeout = const Duration(seconds: 3),
    http.Client? client,
    DaVinciBridgeTokenProvider? tokenProvider,
  }) : _client = client,
       _tokenProvider = tokenProvider;

  final String baseUrl;
  final Duration timeout;
  final http.Client? _client;
  final DaVinciBridgeTokenProvider? _tokenProvider;

  Future<DaVinciBridgeHealth> health() async {
    final response = await _request('GET', '/v1/health');
    return DaVinciBridgeHealth(
      pluginVersion: _text(response['pluginVersion']),
      resolveVersion: _text(response['resolveVersion']),
      projectName: _text(response['projectName']),
      projectId: _text(response['projectId']),
    );
  }

  Future<DaVinciTimelineSyncResult> sync(VideoTimelineSnapshot snapshot) async {
    final response = await _request(
      'POST',
      '/v1/timelines/sync',
      body: snapshot.toJson(),
    );
    return DaVinciTimelineSyncResult(
      timelineName: _text(response['timelineName']),
      revision: _text(response['revision']),
      created: response['created'] == true,
      unchanged: response['unchanged'] == true,
      importedClipCount: _integer(response['importedClipCount']),
      syncedClipCount: _integer(response['syncedClipCount']),
      removedClipCount: _integer(response['removedClipCount']),
    );
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object>? body,
  }) async {
    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      final token = await (_tokenProvider ?? loadOrCreateDaVinciBridgeToken)();
      final uri = Uri.parse('$baseUrl$path');
      final headers = <String, String>{
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        'X-FilmStoryboard-Token': token,
      };
      final future = switch (method) {
        'GET' => client.get(uri, headers: headers),
        'POST' => client.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const <String, Object>{}),
        ),
        _ => throw ArgumentError.value(method, 'method'),
      };
      final response = await future.timeout(timeout);
      final decoded = _decodeResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DaVinciBridgeException(
          _text(decoded['message']).isNotEmpty
              ? _text(decoded['message'])
              : '达芬奇插件返回 HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      if (_text(decoded['status']) != 'ok') {
        throw DaVinciBridgeException(
          _text(decoded['message']).isNotEmpty
              ? _text(decoded['message'])
              : '达芬奇插件返回了无效状态',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const DaVinciBridgeException(
        '达芬奇流程整合插件响应超时',
        kind: DaVinciBridgeFailureKind.timeout,
      );
    } on SocketException {
      throw const DaVinciBridgeException(
        '未检测到达芬奇流程整合插件',
        kind: DaVinciBridgeFailureKind.pluginUnavailable,
      );
    } on http.ClientException {
      throw const DaVinciBridgeException(
        '未检测到达芬奇流程整合插件',
        kind: DaVinciBridgeFailureKind.pluginUnavailable,
      );
    } on FormatException catch (error) {
      throw DaVinciBridgeException('达芬奇插件返回数据无效：$error');
    } finally {
      if (ownsClient) client.close();
    }
  }

  Map<String, Object?> _decodeResponse(http.Response response) {
    if (response.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const FormatException('响应不是 JSON 对象');
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  static String _text(Object? value) => value == null ? '' : '$value'.trim();

  static int _integer(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }
}

class DaVinciBridgeHealth {
  const DaVinciBridgeHealth({
    required this.pluginVersion,
    required this.resolveVersion,
    required this.projectName,
    required this.projectId,
  });

  final String pluginVersion;
  final String resolveVersion;
  final String projectName;
  final String projectId;
}

class DaVinciTimelineSyncResult {
  const DaVinciTimelineSyncResult({
    required this.timelineName,
    required this.revision,
    required this.created,
    required this.unchanged,
    required this.importedClipCount,
    required this.syncedClipCount,
    required this.removedClipCount,
  });

  final String timelineName;
  final String revision;
  final bool created;
  final bool unchanged;
  final int importedClipCount;
  final int syncedClipCount;
  final int removedClipCount;
}

enum DaVinciBridgeFailureKind { other, pluginUnavailable, timeout }

class DaVinciBridgeException implements Exception {
  const DaVinciBridgeException(
    this.message, {
    this.statusCode,
    this.kind = DaVinciBridgeFailureKind.other,
  });

  final String message;
  final int? statusCode;
  final DaVinciBridgeFailureKind kind;

  @override
  String toString() => message;
}

Directory daVinciBridgeSharedDirectory() {
  final environmentRoot =
      Platform.environment['LOCALAPPDATA']?.trim() ??
      Platform.environment['APPDATA']?.trim() ??
      '';
  final root = environmentRoot.isEmpty
      ? Directory.systemTemp.path
      : environmentRoot;
  return Directory(p.join(root, 'FilmStoryboard', 'ResolveBridge'));
}

Future<String> loadOrCreateDaVinciBridgeToken() async {
  final directory = daVinciBridgeSharedDirectory();
  final file = File(p.join(directory.path, 'bridge-token.txt'));
  if (file.existsSync()) {
    final existing = (await file.readAsString()).trim();
    if (existing.length >= 32) return existing;
    await file.delete();
  }
  await directory.create(recursive: true);
  final random = Random.secure();
  final token = List<int>.generate(
    32,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  try {
    await file.create(exclusive: true);
    await file.writeAsString(token, flush: true);
    return token;
  } on FileSystemException {
    final existing = (await file.readAsString()).trim();
    if (existing.length >= 32) return existing;
    rethrow;
  }
}
