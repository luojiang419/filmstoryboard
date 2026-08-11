import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('健康检查、认证、能力查询和注销形成完整闭环', () async {
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      tokenFactory: () => 'integration-test-access-token',
      pairingCodeFactory: () => '654321',
    );
    auth.createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: '1.0.0+246',
      capabilitiesProvider: () => const {'workspace': true},
    );
    await server.start(portOverride: 0);
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

    final health = await _request(client, base.resolve('/api/v1/health'));
    expect(health.statusCode, HttpStatus.ok);
    expect(health.json['status'], 'ok');
    expect(health.json['appVersion'], '1.0.0+246');
    expect(health.headers.value('X-Content-Type-Options'), 'nosniff');

    final unauthorized = await _request(
      client,
      base.resolve('/api/v1/capabilities'),
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    expect(
      (unauthorized.json['error']! as Map<String, Object?>)['code'],
      'authentication_required',
    );

    final paired = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '654321', 'clientName': 'Test Browser'},
    );
    expect(paired.statusCode, HttpStatus.created);
    final token = paired.json['accessToken']! as String;

    final capabilities = await _request(
      client,
      base.resolve('/api/v1/capabilities'),
      token: token,
    );
    expect(capabilities.statusCode, HttpStatus.ok);
    expect(
      (capabilities.json['capabilities']! as Map<String, Object?>)['workspace'],
      isTrue,
    );

    final logout = await _request(
      client,
      base.resolve('/api/v1/auth/session'),
      method: 'DELETE',
      token: token,
    );
    expect(logout.statusCode, HttpStatus.noContent);

    final afterLogout = await _request(
      client,
      base.resolve('/api/v1/capabilities'),
      token: token,
    );
    expect(afterLogout.statusCode, HttpStatus.unauthorized);
  });

  test('跨来源请求默认拒绝且错误响应不暴露内部异常', () async {
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(config: config);
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
    );
    await server.start(portOverride: 0);
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('http://127.0.0.1:${server.boundPort}/api/v1/health');

    final response = await _request(
      client,
      uri,
      headers: const {'Origin': 'https://attacker.example.com'},
    );

    expect(response.statusCode, HttpStatus.forbidden);
    final error = response.json['error']! as Map<String, Object?>;
    expect(error['code'], 'origin_forbidden');
    expect(error.toString(), isNot(contains('stack')));
  });

  test('同源浏览器可使用 HttpOnly Cookie 完成认证和注销', () async {
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      tokenFactory: () => 'cookie-test-access-token',
      pairingCodeFactory: () => '135790',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
    );
    await server.start(portOverride: 0);
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

    final paired = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '135790', 'clientName': 'Cookie Browser'},
    );
    final setCookie = paired.headers.value(HttpHeaders.setCookieHeader)!;
    expect(setCookie, contains('HttpOnly'));
    expect(setCookie, contains('SameSite=Strict'));
    final cookie = setCookie.split(';').first;

    final authenticated = await _request(
      client,
      base.resolve('/api/v1/capabilities'),
      headers: {HttpHeaders.cookieHeader: cookie},
    );
    expect(authenticated.statusCode, HttpStatus.ok);

    final logout = await _request(
      client,
      base.resolve('/api/v1/auth/session'),
      method: 'DELETE',
      headers: {HttpHeaders.cookieHeader: cookie},
    );
    expect(logout.statusCode, HttpStatus.noContent);
    expect(
      logout.headers.value(HttpHeaders.setCookieHeader),
      contains('Max-Age=0'),
    );

    final afterLogout = await _request(
      client,
      base.resolve('/api/v1/capabilities'),
      headers: {HttpHeaders.cookieHeader: cookie},
    );
    expect(afterLogout.statusCode, HttpStatus.unauthorized);
  });

  test('内置 Web 支持静态资源、SPA 回退和安全响应头', () async {
    final webRoot = await Directory.systemTemp.createTemp(
      'filmstoryboard-web-test-',
    );
    addTearDown(() => webRoot.delete(recursive: true));
    await File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsString('<!doctype html><title>Remote</title>');
    await File(
      '${webRoot.path}${Platform.pathSeparator}main.js',
    ).writeAsString('console.log("remote");');
    final fontDirectory = Directory(
      [webRoot.path, 'assets', 'assets', 'fonts'].join(Platform.pathSeparator),
    );
    await fontDirectory.create(recursive: true);
    await File(
      '${fontDirectory.path}${Platform.pathSeparator}NotoSansSC-Regular.otf',
    ).writeAsString('font');
    final config = RemoteAccessConfig(enabled: true);
    final server = EmbeddedWebServer(
      config: config,
      authService: RemoteAuthService(config: config),
      appVersion: 'test',
      webRoot: webRoot,
    );
    await server.start(portOverride: 0);
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

    final index = await _request(client, base.resolve('/'));
    expect(index.statusCode, HttpStatus.ok);
    expect(index.body, contains('<title>Remote</title>'));
    expect(index.headers.contentType?.mimeType, 'text/html');
    expect(
      index.headers.value('Content-Security-Policy'),
      contains("default-src 'self'"),
    );
    expect(index.headers.value('X-Frame-Options'), 'DENY');

    final spa = await _request(client, base.resolve('/scripts/current'));
    expect(spa.statusCode, HttpStatus.ok);
    expect(spa.body, contains('<title>Remote</title>'));

    final script = await _request(client, base.resolve('/main.js'));
    expect(script.statusCode, HttpStatus.ok);
    expect(script.headers.contentType?.mimeType, 'application/javascript');
    expect(script.body, contains('remote'));

    final font = await _request(
      client,
      base.resolve('/assets/assets/fonts/NotoSansSC-Regular.otf'),
    );
    expect(font.statusCode, HttpStatus.ok);
    expect(font.headers.contentType?.mimeType, 'font/otf');
    expect(font.body, 'font');

    final sameOriginModule = await _request(
      client,
      base.resolve('/main.js'),
      headers: {'Origin': base.origin},
    );
    expect(sameOriginModule.statusCode, HttpStatus.ok);
    expect(
      sameOriginModule.headers.value(
        HttpHeaders.accessControlAllowOriginHeader,
      ),
      base.origin,
    );

    final missing = await _request(client, base.resolve('/missing.png'));
    expect(missing.statusCode, HttpStatus.notFound);
    expect(
      (missing.json['error']! as Map<String, Object?>)['code'],
      'web_asset_not_found',
    );
  });
}

Future<_TestResponse> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
  Map<String, String> headers = const {},
}) async {
  final request = await client.openUrl(method, uri);
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final source = await utf8.decoder.bind(response).join();
  final json =
      source.isEmpty ||
          response.headers.contentType?.mimeType != 'application/json'
      ? <String, Object?>{}
      : jsonDecode(source) as Map<String, Object?>;
  return _TestResponse(
    statusCode: response.statusCode,
    headers: response.headers,
    json: json,
    body: source,
  );
}

class _TestResponse {
  const _TestResponse({
    required this.statusCode,
    required this.headers,
    required this.json,
    required this.body,
  });

  final int statusCode;
  final HttpHeaders headers;
  final Map<String, Object?> json;
  final String body;
}
