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

class BridgeDirectUpload {
  const BridgeDirectUpload({required this.file, required this.uploadName});

  final File file;
  final String uploadName;
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
    return (await _discover()).baseUri;
  }

  Future<_BridgeDiscovery> _discover({bool requireDirect = false}) async {
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
            data['automatic_receive'] == true &&
            (!requireDirect || data['direct_receive'] == true)) {
          return _BridgeDiscovery(
            base,
            '${data['active_canvas_id'] ?? ''}'.trim(),
          );
        }
      } catch (_) {
        // 继续探测下一个仅本机端口。
      }
    }
    throw const BridgeLoopbackException('未发现正在运行的 SHIYIN-AI');
  }

  Future<BridgeLoopbackResult> sendDirect({
    required Map<String, Object?> manifest,
    required List<BridgeDirectUpload> uploads,
    required String canvasTitle,
  }) async {
    if (uploads.isEmpty) {
      throw const BridgeLoopbackException('没有可发送的故事板图片');
    }
    final discovery = await _discover(requireDirect: true);
    final request = http.MultipartRequest(
      'POST',
      discovery.baseUri.resolve('api/canvas-bridges/film/receive-direct'),
    )
      ..fields['manifest'] = jsonEncode(manifest)
      ..fields['canvas_title'] = canvasTitle
      ..fields['create_prompt_nodes'] = 'false';
    if (discovery.activeCanvasId.isNotEmpty) {
      request.fields['canvas_id'] = discovery.activeCanvasId;
    }
    for (final upload in uploads) {
      if (!upload.file.existsSync()) {
        throw BridgeLoopbackException('故事板图片不存在：${upload.file.path}');
      }
      request.files.add(
        await http.MultipartFile.fromPath(
          'frames',
          upload.file.path,
          filename: upload.uploadName,
        ),
      );
    }
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
        '${detail ?? 'SHIYIN-AI 直接接收失败（HTTP ${response.statusCode}）'}',
      );
    }
    if (data is! Map || data['ok'] != true) {
      throw const BridgeLoopbackException('SHIYIN-AI 返回了无效的直接接收结果');
    }
    final editorPath = '${data['editor_url'] ?? ''}';
    return BridgeLoopbackResult(
      baseUri: discovery.baseUri,
      canvasId: '${data['canvas_id'] ?? ''}',
      groupId: '${data['group_id'] ?? ''}',
      frameCount: (data['frame_count'] as num?)?.toInt() ?? 0,
      editorUri: editorPath.isEmpty
          ? discovery.baseUri
          : discovery.baseUri.resolve(editorPath),
    );
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

class _BridgeDiscovery {
  const _BridgeDiscovery(this.baseUri, this.activeCanvasId);

  final Uri baseUri;
  final String activeCanvasId;
}
