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
    this.canvasTitle = '',
  });

  final Uri baseUri;
  final String canvasId;
  final String groupId;
  final int frameCount;
  final Uri editorUri;
  final String canvasTitle;
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

  Future<_BridgeDiscovery> _discover({
    bool requireDirect = false,
    bool requireWorkflow = false,
  }) async {
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
            (!requireDirect ||
                (data['direct_receive'] == true &&
                    data['dedicated_board_projects'] == true)) &&
            (!requireWorkflow || data['workflow_receive'] == true)) {
          return _BridgeDiscovery(base);
        }
      } catch (_) {
        // 继续探测下一个仅本机端口。
      }
    }
    throw BridgeLoopbackException(
      '未发现支持独立画板工程的 SHIYIN-AI，请先启动或更新 SHIYIN-AI'
      '（已检查本机端口：${ports.join("、")}）',
    );
  }

  Future<BridgeLoopbackResult> sendDirect({
    required Map<String, Object?> manifest,
    required List<BridgeDirectUpload> uploads,
    required String canvasTitle,
    bool requireWorkflow = false,
  }) async {
    if (uploads.isEmpty) {
      throw const BridgeLoopbackException('没有可发送的故事板图片');
    }
    final discovery = await _discover(
      requireDirect: true,
      requireWorkflow: requireWorkflow,
    );
    final request =
        http.MultipartRequest(
            'POST',
            discovery.baseUri.resolve('api/canvas-bridges/film/receive-direct'),
          )
          ..fields['manifest'] = jsonEncode(manifest)
          ..fields['canvas_title'] = canvasTitle
          ..fields['create_prompt_nodes'] = 'false';
    // 接收端按 manifest.bridge_id 创建或更新对应画布，不能绑定当前打开的画布。
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
    return _validatedResult(
      discovery.baseUri,
      data,
      expectedFrames: uploads.length,
      requireWorkflow: requireWorkflow,
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
    return _validatedResult(base, data);
  }

  BridgeLoopbackResult _validatedResult(
    Uri base,
    Map data, {
    int? expectedFrames,
    bool requireWorkflow = false,
  }) {
    final canvasId = '${data['canvas_id'] ?? ''}'.trim();
    final groupId = '${data['group_id'] ?? ''}'.trim();
    final frameCount = (data['frame_count'] as num?)?.toInt() ?? 0;
    if (canvasId.isEmpty ||
        groupId.isEmpty ||
        frameCount <= 0 ||
        (expectedFrames != null && frameCount != expectedFrames)) {
      throw const BridgeLoopbackException(
        '无限画布未返回完整的工程、图片组和分镜数量，请更新 SHIYIN-AI 后重新导出',
      );
    }
    final workflowIds = data['workflow_node_ids'];
    if (requireWorkflow &&
        (workflowIds is! List ||
            workflowIds.length != 3 ||
            workflowIds.any((id) => id is! String || id.trim().isEmpty) ||
            workflowIds.toSet().length != 3)) {
      throw const BridgeLoopbackException(
        '画板已发送，但尚未确认准备资产、确认镜头和视频生成节点全部创建，请更新 SHIYIN-AI 后重新导出',
      );
    }
    if (requireWorkflow && data['workflow_ready'] != true) {
      final warning = '${data['workflow_warning'] ?? ''}'.trim();
      throw BridgeLoopbackException(
        '画布和图片组已保存，但准备资产与镜头数据尚未初始化。'
        '${warning.isEmpty ? '请更新两端软件并重新导出。' : warning}',
      );
    }
    final editorPath = '${data['editor_url'] ?? ''}';
    final editor = editorPath.isEmpty
        ? base
              .resolve('static/canvas.html')
              .replace(queryParameters: {'id': canvasId})
        : base.resolve(editorPath);
    if (editor.origin != base.origin ||
        editor.path != '/static/canvas.html' ||
        editor.queryParameters['id'] != canvasId ||
        editor.userInfo.isNotEmpty) {
      throw const BridgeLoopbackException('无限画布返回的工程地址无效，请更新 SHIYIN-AI 后重新导出');
    }
    return BridgeLoopbackResult(
      baseUri: base,
      canvasId: canvasId,
      groupId: groupId,
      frameCount: frameCount,
      editorUri: editor,
      canvasTitle: '${data['canvas_title'] ?? ''}'.trim(),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class _BridgeDiscovery {
  const _BridgeDiscovery(this.baseUri);

  final Uri baseUri;
}
