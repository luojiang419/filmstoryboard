import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef BridgeLoopbackPackageHandler =
    Future<Map<String, Object?>> Function(File packageFile);

class BridgeLoopbackReceiver {
  BridgeLoopbackReceiver({
    required this.directory,
    required this.onPackage,
    this.port = 3210,
    this.maxBytes = 2 * 1024 * 1024 * 1024,
  });

  final Directory directory;
  final BridgeLoopbackPackageHandler onPackage;
  final int port;
  final int maxBytes;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    _subscription = server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type, X-Bridge-Canvas-Title',
      )
      ..contentType = ContentType.json;
    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/canvas-bridges/shiyin/capabilities') {
        await _writeJson(response, HttpStatus.ok, {
          'app': 'filmstoryboard',
          'schema': 'shiyin-film-bridge',
          'schema_version': 2,
          'automatic_receive': true,
          'incremental_sync': true,
          'port': boundPort ?? port,
        });
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/canvas-bridges/shiyin/receive') {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        await directory.create(recursive: true);
        final file = File(
          '${directory.path}/shiyin_receive_$stamp.filmbridge.zip',
        );
        var total = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in request) {
            total += chunk.length;
            if (total > maxBytes) {
              throw const FormatException('桥接包不能超过 2GB');
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (total == 0) throw const FormatException('桥接包为空');
        try {
          final result = await onPackage(file);
          if (file.existsSync()) await file.delete();
          await _writeJson(response, HttpStatus.ok, {'ok': true, ...result});
        } finally {
          if (file.existsSync()) await file.delete();
        }
        return;
      }
      await _writeJson(response, HttpStatus.notFound, {'error': 'not_found'});
    } catch (error) {
      await _writeJson(response, HttpStatus.badRequest, {
        'ok': false,
        'detail': '$error',
      });
    }
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> value,
  ) async {
    response.statusCode = statusCode;
    response.write(jsonEncode(value));
    await response.close();
  }
}
