import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class BridgeLoopbackException implements Exception {
  const BridgeLoopbackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BridgeLoopbackResult {
  const BridgeLoopbackResult({
    required this.baseUri,
    required this.canvasId,
    required this.groupId,
    required this.frameCount,
    required this.editorUri,
  });

  final Uri baseUri;
  final String canvasId;
  final String groupId;
  final int frameCount;
  final Uri editorUri;
}

class BridgeLoopbackClient {
  BridgeLoopbackClient({
    http.Client? client,
    this.ports = const [3000, 3001, 8000],
    this.discoveryTimeout = const Duration(milliseconds: 900),
    this.sendTimeout = const Duration(minutes: 5),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final List<int> ports;
  final Duration discoveryTimeout;
  final Duration sendTimeout;

  Future<Uri> discover() async {
    for (final port in ports) {
      final base = Uri.parse('http://127.0.0.1:$port/');
      try {
        final response = await _client
            .get(base.resolve('api/canvas-bridges/film/capabilities'))
            .timeout(discoveryTimeout);
        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body);
        if (data is Map &&
            data['app'] == 'shiyin-ai' &&
            data['schema'] == 'shiyin-film-bridge' &&
            data['automatic_receive'] == true) {
          return base;
        }
      } catch (_) {
        // 继续探测下一个仅本机端口。
      }
    }
    throw const BridgeLoopbackException('未发现正在运行的 SHIYIN-AI');
  }

  Future<BridgeLoopbackResult> sendPackage({
    required File packageFile,
    required String canvasTitle,
  }) async {
    if (!packageFile.existsSync()) {
      throw const BridgeLoopbackException('待发送桥接包不存在');
    }
    final base = await discover();
    final request =
        http.MultipartRequest(
            'POST',
            base.resolve('api/canvas-bridges/film/receive'),
          )
          ..fields['canvas_title'] = canvasTitle
          ..fields['create_prompt_nodes'] = 'true'
          ..files.add(
            await http.MultipartFile.fromPath('file', packageFile.path),
          );
    final streamed = await _client.send(request).timeout(sendTimeout);
    final response = await http.Response.fromStream(streamed);
    Object? data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      data = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = data is Map ? data['detail'] : null;
      throw BridgeLoopbackException(
        '${detail ?? 'SHIYIN-AI 接收失败（HTTP ${response.statusCode}）'}',
      );
    }
    if (data is! Map || data['ok'] != true) {
      throw const BridgeLoopbackException('SHIYIN-AI 返回了无效的接收结果');
    }
    final editorPath = '${data['editor_url'] ?? ''}';
    return BridgeLoopbackResult(
      baseUri: base,
      canvasId: '${data['canvas_id'] ?? ''}',
      groupId: '${data['group_id'] ?? ''}',
      frameCount: (data['frame_count'] as num?)?.toInt() ?? 0,
      editorUri: editorPath.isEmpty ? base : base.resolve(editorPath),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
