import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef WorkflowRequestHandler =
    Future<Map<String, Object?>> Function(Map<String, Object?> body);

/// 独立于故事板页面生命周期；只供本机 SHIYIN 服务使用，不允许网页跨域调用。
class BridgeWorkflowServer {
  BridgeWorkflowServer({
    required this.onRequest,
    required this.projectId,
    this.port = 3211,
    this.fallbackPorts = const [3212, 3213, 3214, 3215, 3216, 3217, 3218, 3219],
  });
  final WorkflowRequestHandler onRequest;
  final String projectId;
  final int port;
  final List<int> fallbackPorts;
  final String token = base64Url.encode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Map<String, File> media = {};
  HttpServer? _server;
  Future<void>? _starting;
  bool _stopped = false;
  int? get boundPort => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    if (_starting != null) return _starting;
    _stopped = false;
    final starting = _bind();
    _starting = starting;
    try {
      await starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> _bind() async {
    final candidates = <int>{port, if (port != 0) ...fallbackPorts}.toList();
    for (final candidate in candidates) {
      HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, candidate);
      } on SocketException {
        if (candidate == candidates.last) rethrow;
        continue;
      }
      if (_stopped) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.listen((request) => unawaited(_handle(request)));
      return;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    try {
      await _starting;
    } catch (_) {
      /* 启动异常由调用方处理。 */
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value('origin') != null) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/capabilities') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'app': 'filmstoryboard',
            'workflow_version': 1,
            'project_id': projectId,
            'token': token,
          }),
        );
        return;
      }
      if (request.headers.value('x-workflow-token') != token) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method == 'GET' && request.uri.path.startsWith('/media/')) {
        final file = media[request.uri.pathSegments.last];
        if (file == null || !await file.exists()) {
          response.statusCode = HttpStatus.notFound;
          return;
        }
        response.headers.contentType = ContentType.binary;
        await response.addStream(file.openRead());
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/workflow') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request) {
        if (bytes.length + chunk.length > 256 * 1024 * 1024) {
          throw const FormatException('工作流请求超过 256MB，请减少本次图片数量');
        }
        bytes.addAll(chunk);
      }
      final body = (jsonDecode(utf8.decode(bytes)) as Map)
          .cast<String, Object?>();
      if (body['project_id'] != projectId) {
        throw const FormatException('请在 film 打开此画布对应的源项目');
      }
      final result = await onRequest(body);
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true, ...result}));
    } catch (error) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': false, 'detail': '$error'}));
    } finally {
      await response.close();
    }
  }
}
