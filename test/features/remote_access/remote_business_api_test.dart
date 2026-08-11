import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP 脚本编辑通过 WebSocket 推送且旧版本返回 409', () async {
    final root = await Directory.systemTemp.createTemp('remote-api-test-');
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    addTearDown(() async {
      database.dispose();
      await changeBus.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final frameFile = File('${directories.frames.path}\\frame.png');
    await frameFile.writeAsBytes(List<int>.generate(16, (index) => index));
    _seed(database, frameFile.path);
    final registry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-api',
          projectName: 'API 工程',
          database: database,
          directories: directories,
        ),
      );
    final mediaRegistry = RemoteMediaRegistry(
      workspaceRegistry: registry,
      secret: 'media-test-secret',
    );
    final facade = RemoteAccessFacade(
      workspaceRegistry: registry,
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
    );
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      tokenFactory: () => 'business-api-access-token',
      pairingCodeFactory: () => '112233',
      ticketFactory: () => 'business-api-ws-ticket',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
      capabilitiesProvider: () => const {
        'workspace': true,
        'shootingScripts': true,
      },
    );
    await server.start(portOverride: 0);
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

    final pair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '112233', 'clientName': '远端导演'},
    );
    final token = pair.json['accessToken']! as String;
    final ticket = await _request(
      client,
      base.resolve('/api/v1/auth/ws-ticket'),
      method: 'POST',
      token: token,
    );
    final wsTicket = ticket.json['ticket']! as String;
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/api/v1/events?ticket=$wsTicket',
    );
    addTearDown(socket.close);
    final messages = StreamController<Map<String, Object?>>.broadcast();
    final socketSubscription = socket.listen((message) {
      messages.add(jsonDecode(message as String) as Map<String, Object?>);
    });
    addTearDown(() async {
      await socketSubscription.cancel();
      await messages.close();
    });
    final ready = await messages.stream.first.timeout(
      const Duration(seconds: 2),
    );
    expect(ready['type'], 'ready');

    final workspace = await _request(
      client,
      base.resolve('/api/v1/workspace'),
      token: token,
    );
    expect(workspace.statusCode, HttpStatus.ok);
    expect(
      (workspace.json['project']! as Map<String, Object?>)['name'],
      'API 工程',
    );

    final script = await _request(
      client,
      base.resolve('/api/v1/scripts/script-api'),
      token: token,
    );
    final shot =
        (script.json['shots']! as List<Object?>).single as Map<String, Object?>;
    final mediaId = shot['frameMediaId']! as String;
    final range = await _requestBytes(
      client,
      base.resolve('/api/v1/media/$mediaId/content'),
      token: token,
      headers: const {'Range': 'bytes=2-5'},
    );
    expect(range.statusCode, HttpStatus.partialContent);
    expect(range.bytes, const [2, 3, 4, 5]);
    expect(range.headers.value('Content-Range'), 'bytes 2-5/16');

    final nextChange = messages.stream
        .firstWhere((event) => event['type'] == 'shootingScript.changed')
        .timeout(const Duration(seconds: 2));
    final updated = await _request(
      client,
      base.resolve('/api/v1/scripts/script-api/shots/shot-api'),
      method: 'PATCH',
      token: token,
      body: const {
        'expectedVersion': 1,
        'changes': {'content': '来自 Web 的导演修改'},
      },
    );
    expect(updated.statusCode, HttpStatus.ok);
    expect(updated.json['version'], 2);
    final event = await nextChange;
    expect(event['resourceId'], 'script-api');
    expect(event['revision'], 2);

    final conflict = await _request(
      client,
      base.resolve('/api/v1/scripts/script-api/shots/shot-api'),
      method: 'PATCH',
      token: token,
      body: const {
        'expectedVersion': 1,
        'changes': {'content': '不应覆盖的新内容'},
      },
    );
    expect(conflict.statusCode, HttpStatus.conflict);
    expect(
      (conflict.json['error']! as Map<String, Object?>)['code'],
      'revision_conflict',
    );
  });
}

void _seed(AppDatabase database, String framePath) {
  final repository = ShootingScriptRepository(database);
  final now = DateTime.utc(2026, 8, 10);
  repository.upsertScript(
    ShootingScript(
      id: 'script-api',
      name: '远程脚本',
      sourceStoryboardId: null,
      sourceVideoId: null,
      status: ShootingScriptStatus.active,
      version: 1,
      createdAt: now,
      updatedAt: now,
    ),
  );
  repository.replaceShots('script-api', [
    ScriptShot(
      id: 'shot-api',
      scriptId: 'script-api',
      shotNumber: 1,
      durationSeconds: 4,
      framePath: framePath,
      visual: '',
      content: '初始内容',
      shotSize: '',
      cameraMovement: '',
      cameraNotes: '',
      scene: '',
      productCode: '',
      productStyling: '',
      dialogue: '',
      sound: '',
      prompt: '',
      status: ProcessingStatus.completed,
      updatedAt: now,
    ),
  ]);
}

Future<_Response> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final source = await utf8.decoder.bind(response).join();
  return _Response(
    statusCode: response.statusCode,
    json: source.isEmpty
        ? const {}
        : jsonDecode(source) as Map<String, Object?>,
  );
}

class _Response {
  const _Response({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

Future<_ByteResponse> _requestBytes(
  HttpClient client,
  Uri uri, {
  required String token,
  Map<String, String> headers = const {},
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  final response = await request.close();
  final bytes = await response.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  return _ByteResponse(
    statusCode: response.statusCode,
    headers: response.headers,
    bytes: bytes,
  );
}

class _ByteResponse {
  const _ByteResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });

  final int statusCode;
  final HttpHeaders headers;
  final List<int> bytes;
}
