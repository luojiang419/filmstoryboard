import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../application/remote_auth_service.dart';
import '../application/remote_access_facade.dart';
import '../application/remote_media_registry.dart';
import '../data/remote_audit_logger.dart';
import '../domain/remote_access_config.dart';
import '../domain/remote_auth_models.dart';
import '../domain/remote_events.dart';
import 'remote_api_exception.dart';

typedef RemoteCapabilitiesProvider = Map<String, Object?> Function();

class EmbeddedWebServer {
  static const sessionCookieName = 'filmstoryboard_remote_session';

  EmbeddedWebServer({
    required RemoteAccessConfig config,
    required RemoteAuthService authService,
    required String appVersion,
    RemoteAccessFacade? facade,
    RemoteChangeBus? changeBus,
    RemoteMediaRegistry? mediaRegistry,
    RemoteCapabilitiesProvider? capabilitiesProvider,
    RemoteAuditLogger auditLogger = const NoopRemoteAuditLogger(),
    Directory? webRoot,
  }) : _config = config.validated(),
       _authService = authService,
       _appVersion = appVersion,
       _facade = facade,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _capabilitiesProvider = capabilitiesProvider ?? _defaultCapabilities,
       _auditLogger = auditLogger,
       _webRoot = webRoot;

  final RemoteAccessConfig _config;
  final RemoteAuthService _authService;
  final String _appVersion;
  final RemoteAccessFacade? _facade;
  final RemoteChangeBus? _changeBus;
  final RemoteMediaRegistry? _mediaRegistry;
  final RemoteCapabilitiesProvider _capabilitiesProvider;
  final RemoteAuditLogger _auditLogger;
  final Directory? _webRoot;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final Set<WebSocket> _webSockets = {};

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  InternetAddress? get boundAddress => _server?.address;

  Future<void> start({int? portOverride}) async {
    if (_server != null) return;
    if (!_config.enabled) {
      throw StateError('远程访问未开启，不能启动 Web 服务');
    }
    final server = await HttpServer.bind(
      _config.bindAddress,
      portOverride ?? _config.port,
      shared: false,
    );
    _server = server;
    _subscription = server.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    final sockets = _webSockets.toList(growable: false);
    _webSockets.clear();
    await Future.wait([
      for (final socket in sockets) socket.close(WebSocketStatus.goingAway),
    ]);
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final requestId = _requestId();
    _setSecurityHeaders(request.response, requestId);
    try {
      if (!_applyCors(request)) {
        throw const RemoteApiException(
          HttpStatus.forbidden,
          'origin_forbidden',
          '不允许的 Web 来源',
        );
      }
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != 'api') {
        await _handleStatic(request, segments);
        return;
      }
      if (segments.length < 3 || segments[0] != 'api' || segments[1] != 'v1') {
        throw const RemoteApiException(
          HttpStatus.notFound,
          'not_found',
          '接口不存在',
        );
      }
      final route = segments.skip(2).toList(growable: false);
      if (_matches(route, const ['health'])) {
        _requireMethod(request, 'GET');
        await _writeJson(request.response, HttpStatus.ok, {
          'status': 'ok',
          'service': 'filmstoryboard-remote',
          'apiVersion': 1,
          'appVersion': _appVersion,
        });
        return;
      }
      if (_matches(route, const ['auth', 'pair'])) {
        _requireMethod(request, 'POST');
        await _handlePair(request, requestId);
        return;
      }
      if (_matches(route, const ['events'])) {
        _requireMethod(request, 'GET');
        await _handleEvents(request, requestId);
        return;
      }

      final authentication = _authenticate(request);
      if (_matches(route, const ['capabilities'])) {
        _requireMethod(request, 'GET');
        await _writeJson(request.response, HttpStatus.ok, {
          'apiVersion': 1,
          'appVersion': _appVersion,
          'session': authentication.session.toJson(),
          'capabilities': _capabilitiesProvider(),
        });
        return;
      }
      if (_matches(route, const ['auth', 'session'])) {
        _requireMethod(request, 'DELETE');
        _authService.revokeToken(authentication.token);
        await _record(
          action: 'auth.logout',
          outcome: 'success',
          request: request,
          requestId: requestId,
          sessionId: authentication.session.id,
        );
        request.response.cookies.add(
          Cookie(sessionCookieName, '')
            ..httpOnly = true
            ..sameSite = SameSite.strict
            ..secure = _isSecureRequest(request)
            ..path = '/api/v1'
            ..maxAge = 0,
        );
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (_matches(route, const ['auth', 'ws-ticket'])) {
        _requireMethod(request, 'POST');
        if (_changeBus == null) {
          throw const RemoteApiException(
            HttpStatus.notImplemented,
            'feature_unavailable',
            '实时事件功能尚未启用',
          );
        }
        final ticket = _authService.issueWebSocketTicket(authentication.token);
        await _writeJson(request.response, HttpStatus.created, ticket.toJson());
        return;
      }
      if (_matches(route, const ['auth', 'sessions'])) {
        _requireMethod(request, 'GET');
        _requireRole(authentication.session, RemoteAccessRole.director);
        await _writeJson(request.response, HttpStatus.ok, {
          'items': _authService
              .listSessions()
              .map((session) => session.toJson())
              .toList(),
        });
        return;
      }
      if (route.length == 3 && route[0] == 'media' && route[2] == 'content') {
        await _handleMedia(request, route[1]);
        return;
      }
      if (_matches(route, const ['workspace'])) {
        _requireMethod(request, 'GET');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _requireFacade().workspaceOverview(),
        );
        return;
      }
      if (_matches(route, const ['storyboards'])) {
        _requireMethod(request, 'GET');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _requireFacade().listStoryboards(),
        );
        return;
      }
      if (route.length == 2 && route[0] == 'storyboards') {
        if (request.method == 'GET') {
          await _writeJson(
            request.response,
            HttpStatus.ok,
            _requireFacade().storyboardDetail(route[1]),
          );
          return;
        }
        _requireMethod(request, 'PATCH');
        _requireRole(authentication.session, RemoteAccessRole.director);
        final body = await _readJson(request);
        final expectedRevision = body['expectedRevision'];
        final changes = body['changes'];
        if (expectedRevision is! int || changes is! Map<String, Object?>) {
          throw const RemoteApiException(
            HttpStatus.badRequest,
            'invalid_request',
            '必须提供整数 expectedRevision 和对象 changes',
          );
        }
        final result = _requireFacade().updateStoryboard(
          boardId: route[1],
          expectedRevision: expectedRevision,
          changes: changes,
        );
        await _record(
          action: 'storyboard.update',
          outcome: 'success',
          request: request,
          requestId: requestId,
          sessionId: authentication.session.id,
          metadata: {'boardId': route[1]},
        );
        await _writeJson(request.response, HttpStatus.ok, result);
        return;
      }
      if (route.length == 3 &&
          route[0] == 'storyboards' &&
          route[2] == 'annotations') {
        _requireMethod(request, 'POST');
        _requireRole(authentication.session, RemoteAccessRole.director);
        final body = await _readJson(request);
        final expectedRevision = body['expectedRevision'];
        final annotationBody = body['body'];
        final assetId = body['assetId'];
        if (expectedRevision is! int ||
            annotationBody is! String ||
            (assetId != null && assetId is! String)) {
          throw const RemoteApiException(
            HttpStatus.badRequest,
            'invalid_request',
            '必须提供整数 expectedRevision、文本 body 和可选文本 assetId',
          );
        }
        final result = _requireFacade().addStoryboardAnnotation(
          boardId: route[1],
          expectedRevision: expectedRevision,
          body: annotationBody,
          assetId: assetId as String?,
          authorSessionId: authentication.session.id,
          authorName: authentication.session.clientName,
        );
        await _record(
          action: 'storyboard.annotation.create',
          outcome: 'success',
          request: request,
          requestId: requestId,
          sessionId: authentication.session.id,
          metadata: {'boardId': route[1]},
        );
        await _writeJson(request.response, HttpStatus.ok, result);
        return;
      }
      if (route.length == 4 &&
          route[0] == 'storyboards' &&
          route[2] == 'annotations') {
        _requireMethod(request, 'PATCH');
        _requireRole(authentication.session, RemoteAccessRole.director);
        final body = await _readJson(request);
        final expectedRevision = body['expectedRevision'];
        final changes = body['changes'];
        if (expectedRevision is! int || changes is! Map<String, Object?>) {
          throw const RemoteApiException(
            HttpStatus.badRequest,
            'invalid_request',
            '必须提供整数 expectedRevision 和对象 changes',
          );
        }
        final result = _requireFacade().updateStoryboardAnnotation(
          boardId: route[1],
          annotationId: route[3],
          expectedRevision: expectedRevision,
          changes: changes,
        );
        await _record(
          action: 'storyboard.annotation.update',
          outcome: 'success',
          request: request,
          requestId: requestId,
          sessionId: authentication.session.id,
          metadata: {'boardId': route[1], 'annotationId': route[3]},
        );
        await _writeJson(request.response, HttpStatus.ok, result);
        return;
      }
      if (_matches(route, const ['scripts'])) {
        _requireMethod(request, 'GET');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _requireFacade().listScripts(),
        );
        return;
      }
      if (route.length == 2 && route[0] == 'scripts') {
        _requireMethod(request, 'GET');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          _requireFacade().scriptDetail(route[1]),
        );
        return;
      }
      if (route.length == 4 && route[0] == 'scripts' && route[2] == 'shots') {
        _requireMethod(request, 'PATCH');
        _requireRole(authentication.session, RemoteAccessRole.director);
        final body = await _readJson(request);
        final expectedVersion = body['expectedVersion'];
        final changes = body['changes'];
        if (expectedVersion is! int || changes is! Map<String, Object?>) {
          throw const RemoteApiException(
            HttpStatus.badRequest,
            'invalid_request',
            '必须提供整数 expectedVersion 和对象 changes',
          );
        }
        final result = _requireFacade().updateShot(
          scriptId: route[1],
          shotId: route[3],
          expectedVersion: expectedVersion,
          changes: changes,
        );
        await _record(
          action: 'shootingScript.updateShot',
          outcome: 'success',
          request: request,
          requestId: requestId,
          sessionId: authentication.session.id,
          metadata: {'scriptId': route[1], 'shotId': route[3]},
        );
        await _writeJson(request.response, HttpStatus.ok, result);
        return;
      }
      throw const RemoteApiException(HttpStatus.notFound, 'not_found', '接口不存在');
    } on RemoteApiException catch (error) {
      await _writeError(request.response, error, requestId);
    } on RemoteAuthException catch (error) {
      final status = error.code == 'pairing_rate_limited'
          ? HttpStatus.tooManyRequests
          : HttpStatus.unauthorized;
      await _writeError(
        request.response,
        RemoteApiException(status, error.code, error.message),
        requestId,
      );
    } on RemoteOperationException catch (error) {
      await _writeError(
        request.response,
        RemoteApiException(
          _operationStatus(error.code),
          error.code,
          error.message,
          error.details,
        ),
        requestId,
      );
    } on FormatException catch (error) {
      await _writeError(
        request.response,
        RemoteApiException(
          HttpStatus.badRequest,
          'invalid_request',
          error.message.toString(),
        ),
        requestId,
      );
    } catch (_) {
      await _writeError(
        request.response,
        const RemoteApiException(
          HttpStatus.internalServerError,
          'internal_error',
          '服务器处理请求失败',
        ),
        requestId,
      );
    }
  }

  Future<void> _handleStatic(
    HttpRequest request,
    List<String> pathSegments,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      throw const RemoteApiException(
        HttpStatus.methodNotAllowed,
        'method_not_allowed',
        'Web 页面只允许 GET 或 HEAD 请求',
      );
    }
    final webRoot = _webRoot;
    if (webRoot == null || !webRoot.existsSync()) {
      throw const RemoteApiException(
        HttpStatus.serviceUnavailable,
        'web_assets_unavailable',
        'Web 页面资源尚未安装',
      );
    }
    if (pathSegments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains('/') ||
          segment.contains('\\'),
    )) {
      throw const RemoteApiException(
        HttpStatus.badRequest,
        'invalid_web_path',
        'Web 资源路径无效',
      );
    }

    final canonicalRoot = await webRoot.resolveSymbolicLinks();
    final relativePath = pathSegments.isEmpty
        ? 'index.html'
        : p.joinAll(pathSegments);
    var file = File(p.join(canonicalRoot, relativePath));
    if (!file.existsSync() && p.extension(relativePath).isEmpty) {
      file = File(p.join(canonicalRoot, 'index.html'));
    }
    if (!file.existsSync()) {
      throw const RemoteApiException(
        HttpStatus.notFound,
        'web_asset_not_found',
        'Web 资源不存在',
      );
    }
    final canonicalFile = await file.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalFile)) {
      throw const RemoteApiException(
        HttpStatus.forbidden,
        'web_path_forbidden',
        '不允许访问该 Web 资源',
      );
    }

    final response = request.response;
    final contentType = _staticContentType(canonicalFile);
    response
      ..statusCode = HttpStatus.ok
      ..contentLength = await file.length()
      ..headers.contentType = contentType;
    response.headers
      ..set('Content-Security-Policy', _webContentSecurityPolicy)
      ..set('X-Frame-Options', 'DENY')
      ..set(
        HttpHeaders.cacheControlHeader,
        p.basename(canonicalFile) == 'index.html'
            ? 'no-cache'
            : 'public, max-age=86400',
      );
    if (request.method == 'HEAD') {
      await response.close();
    } else {
      await file.openRead().pipe(response);
    }
  }

  Future<void> _handlePair(HttpRequest request, String requestId) async {
    try {
      final body = await _readJson(request);
      final result = _authService.pair(
        code: _requiredString(body, 'code'),
        clientName: _requiredString(body, 'clientName'),
        attemptKey: request.connectionInfo?.remoteAddress.address ?? 'unknown',
      );
      await _record(
        action: 'auth.pair',
        outcome: 'success',
        request: request,
        requestId: requestId,
        sessionId: result.session.id,
        metadata: {'clientName': result.session.clientName},
      );
      request.response.cookies.add(
        Cookie(sessionCookieName, result.token)
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..secure = _isSecureRequest(request)
          ..path = '/api/v1'
          ..maxAge = result.session.expiresAt
              .difference(DateTime.now().toUtc())
              .inSeconds
              .clamp(1, 30 * 24 * 60 * 60),
      );
      await _writeJson(request.response, HttpStatus.created, {
        'accessToken': result.token,
        'tokenType': 'Bearer',
        'session': result.session.toJson(),
      });
    } on RemoteAuthException {
      await _record(
        action: 'auth.pair',
        outcome: 'failure',
        request: request,
        requestId: requestId,
      );
      rethrow;
    }
  }

  Future<void> _handleEvents(HttpRequest request, String requestId) async {
    final changeBus = _changeBus;
    if (changeBus == null) {
      throw const RemoteApiException(
        HttpStatus.notImplemented,
        'feature_unavailable',
        '实时事件功能尚未启用',
      );
    }
    final ticket = request.uri.queryParameters['ticket']?.trim() ?? '';
    final session = _authService.consumeWebSocketTicket(ticket);
    if (session == null) {
      throw const RemoteApiException(
        HttpStatus.unauthorized,
        'invalid_ws_ticket',
        '实时连接票据无效或已过期',
      );
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      throw const RemoteApiException(
        HttpStatus.badRequest,
        'websocket_upgrade_required',
        '该接口需要 WebSocket Upgrade 请求',
      );
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _webSockets.add(socket);
    socket.add(
      jsonEncode({
        'type': 'ready',
        'sequence': changeBus.lastSequence,
        'session': session.toJson(),
        'requestId': requestId,
      }),
    );
    final subscription = changeBus.events.listen((event) {
      if (socket.readyState == WebSocket.open) {
        socket.add(jsonEncode(event.toJson()));
      }
    });
    unawaited(
      socket.done.whenComplete(() async {
        _webSockets.remove(socket);
        await subscription.cancel();
      }),
    );
  }

  Future<void> _handleMedia(HttpRequest request, String mediaId) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      throw const RemoteApiException(
        HttpStatus.methodNotAllowed,
        'method_not_allowed',
        '媒体接口只允许 GET 或 HEAD 请求',
      );
    }
    final resource = _mediaRegistry?.resolve(mediaId);
    if (resource == null) {
      throw const RemoteApiException(
        HttpStatus.notFound,
        'media_not_found',
        '媒体不存在或不允许远程访问',
      );
    }
    final length = await resource.file.length();
    final response = request.response;
    response.headers
      ..contentType = ContentType.parse(resource.contentType)
      ..set('Accept-Ranges', 'bytes')
      ..set('Content-Disposition', 'inline')
      ..set(
        HttpHeaders.lastModifiedHeader,
        HttpDate.format((await resource.file.lastModified()).toUtc()),
      );
    final rangeHeader = request.headers.value('Range');
    if (rangeHeader == null || rangeHeader.isEmpty) {
      response
        ..statusCode = HttpStatus.ok
        ..contentLength = length;
      if (request.method == 'HEAD') {
        await response.close();
      } else {
        await resource.file.openRead().pipe(response);
      }
      return;
    }
    final range = _parseRange(rangeHeader, length);
    if (range == null) {
      response.headers.set('Content-Range', 'bytes */$length');
      throw const RemoteApiException(
        HttpStatus.requestedRangeNotSatisfiable,
        'invalid_range',
        '请求的媒体字节范围无效',
      );
    }
    final (start, end) = range;
    response
      ..statusCode = HttpStatus.partialContent
      ..contentLength = end - start + 1
      ..headers.set('Content-Range', 'bytes $start-$end/$length');
    if (request.method == 'HEAD') {
      await response.close();
    } else {
      await resource.file.openRead(start, end + 1).pipe(response);
    }
  }

  RemoteAccessFacade _requireFacade() {
    final facade = _facade;
    if (facade == null) {
      throw const RemoteApiException(
        HttpStatus.notImplemented,
        'feature_unavailable',
        '当前软件版本尚未启用工程远程接口',
      );
    }
    return facade;
  }

  _Authentication _authenticate(HttpRequest request) {
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final bearerToken =
        authorization != null &&
            authorization.startsWith('Bearer ') &&
            authorization.length > 7
        ? authorization.substring(7).trim()
        : null;
    String? cookieToken;
    for (final cookie in request.cookies) {
      if (cookie.name == sessionCookieName) cookieToken = cookie.value;
    }
    final token = bearerToken ?? cookieToken;
    if (token == null || token.isEmpty) {
      request.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Bearer realm="FilmStoryboard Remote"',
      );
      throw const RemoteApiException(
        HttpStatus.unauthorized,
        'authentication_required',
        '请先完成远程配对登录',
      );
    }
    final session = _authService.authenticate(token);
    if (session == null) {
      throw const RemoteApiException(
        HttpStatus.unauthorized,
        'invalid_session',
        '远程会话无效或已过期',
      );
    }
    return _Authentication(token: token, session: session);
  }

  static bool _isSecureRequest(HttpRequest request) {
    final forwardedProto = request.headers.value('X-Forwarded-Proto');
    return forwardedProto?.toLowerCase() == 'https' ||
        request.requestedUri.scheme == 'https';
  }

  void _requireRole(RemoteSessionView session, RemoteAccessRole role) {
    if (!session.role.allows(role)) {
      throw const RemoteApiException(
        HttpStatus.forbidden,
        'permission_denied',
        '当前远程角色无权执行此操作',
      );
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType?.mimeType != ContentType.json.mimeType) {
      throw const RemoteApiException(
        HttpStatus.unsupportedMediaType,
        'json_required',
        '请求必须使用 application/json',
      );
    }
    if (request.contentLength > _config.maxRequestBodyBytes) {
      throw const RemoteApiException(
        HttpStatus.requestEntityTooLarge,
        'request_too_large',
        '请求内容超过允许大小',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _config.maxRequestBodyBytes) {
        throw const RemoteApiException(
          HttpStatus.requestEntityTooLarge,
          'request_too_large',
          '请求内容超过允许大小',
        );
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('请求体必须是 JSON 对象');
    }
    return decoded;
  }

  bool _applyCors(HttpRequest request) {
    final origin = request.headers.value('Origin');
    if (origin == null || origin.isEmpty) return true;
    final parsed = Uri.tryParse(origin);
    final hostHeader = request.headers.value(HttpHeaders.hostHeader)?.trim();
    final sameAuthority =
        parsed != null &&
        parsed.host.isNotEmpty &&
        hostHeader != null &&
        parsed.authority.toLowerCase() == hostHeader.toLowerCase();
    final explicitlyAllowed = _config.allowedOrigins.contains(origin);
    if (!sameAuthority && !explicitlyAllowed) return false;
    request.response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, origin)
      ..set(HttpHeaders.varyHeader, 'Origin')
      ..set(
        HttpHeaders.accessControlAllowMethodsHeader,
        'GET, POST, PATCH, DELETE, OPTIONS',
      )
      ..set(
        HttpHeaders.accessControlAllowHeadersHeader,
        'Authorization, Content-Type, If-Match',
      )
      ..set(HttpHeaders.accessControlMaxAgeHeader, '600');
    return true;
  }

  void _setSecurityHeaders(HttpResponse response, String requestId) {
    response.headers
      ..set('X-Request-ID', requestId)
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  Future<void> _writeError(
    HttpResponse response,
    RemoteApiException error,
    String requestId,
  ) => _writeJson(response, error.statusCode, {
    'error': {
      'code': error.code,
      'message': error.message,
      'requestId': requestId,
      if (error.details.isNotEmpty) 'details': error.details,
    },
  });

  Future<void> _record({
    required String action,
    required String outcome,
    required HttpRequest request,
    required String requestId,
    String? sessionId,
    Map<String, Object?> metadata = const {},
  }) async {
    try {
      await _auditLogger.record(
        RemoteAuditEvent(
          action: action,
          outcome: outcome,
          requestId: requestId,
          timestamp: DateTime.now().toUtc(),
          sessionId: sessionId,
          clientAddress: request.connectionInfo?.remoteAddress.address,
          metadata: metadata,
        ),
      );
    } catch (_) {
      // 审计文件暂时不可写时不能导致业务响应泄露内部文件错误。
    }
  }

  void _requireMethod(HttpRequest request, String method) {
    if (request.method == method) return;
    request.response.headers.set(HttpHeaders.allowHeader, method);
    throw RemoteApiException(
      HttpStatus.methodNotAllowed,
      'method_not_allowed',
      '该接口只允许 $method 请求',
    );
  }

  static bool _matches(List<String> actual, List<String> expected) {
    if (actual.length != expected.length) return false;
    for (var index = 0; index < actual.length; index++) {
      if (actual[index] != expected[index]) return false;
    }
    return true;
  }

  static String _requiredString(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('缺少有效字段：$key');
    }
    return value.trim();
  }

  static Map<String, Object?> _defaultCapabilities() => const {
    'workspace': false,
    'storyboards': false,
    'shootingScripts': false,
    'videoGeneration': false,
    'mediaStreaming': false,
  };

  static const _webContentSecurityPolicy =
      "default-src 'self'; base-uri 'self'; object-src 'none'; "
      "frame-ancestors 'none'; script-src 'self' 'unsafe-eval'; "
      "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
      "font-src 'self' data:; connect-src 'self' ws: wss:; "
      "worker-src 'self' blob:";

  static ContentType _staticContentType(String path) {
    return switch (p.extension(path).toLowerCase()) {
      '.html' => ContentType('text', 'html', charset: 'utf-8'),
      '.js' => ContentType('application', 'javascript', charset: 'utf-8'),
      '.css' => ContentType('text', 'css', charset: 'utf-8'),
      '.json' => ContentType('application', 'json', charset: 'utf-8'),
      '.webmanifest' => ContentType('application', 'manifest+json'),
      '.wasm' => ContentType('application', 'wasm'),
      '.png' => ContentType('image', 'png'),
      '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
      '.webp' => ContentType('image', 'webp'),
      '.gif' => ContentType('image', 'gif'),
      '.ico' => ContentType('image', 'x-icon'),
      '.svg' => ContentType('image', 'svg+xml'),
      '.woff2' => ContentType('font', 'woff2'),
      '.ttf' => ContentType('font', 'ttf'),
      '.otf' => ContentType('font', 'otf'),
      _ => ContentType.binary,
    };
  }

  static int _operationStatus(String code) => switch (code) {
    'not_found' => HttpStatus.notFound,
    'workspace_unavailable' || 'revision_conflict' => HttpStatus.conflict,
    'storyboard_locked' => HttpStatus.locked,
    'invalid_changes' => HttpStatus.badRequest,
    _ => HttpStatus.unprocessableEntity,
  };

  static (int, int)? _parseRange(String source, int length) {
    if (length <= 0 || source.contains(',')) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(source.trim());
    if (match == null) return null;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return null;
    if (startText.isEmpty) {
      final suffixLength = int.tryParse(endText);
      if (suffixLength == null || suffixLength <= 0) return null;
      final start = (length - suffixLength).clamp(0, length - 1);
      return (start, length - 1);
    }
    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= length) return null;
    final requestedEnd = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (requestedEnd == null || requestedEnd < start) return null;
    return (start, requestedEnd.clamp(start, length - 1));
  }

  static String _requestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _Authentication {
  const _Authentication({required this.token, required this.session});

  final String token;
  final RemoteSessionView session;
}
