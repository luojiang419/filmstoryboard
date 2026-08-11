import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_storyboard_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/data/remote_audit_logger.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_auth_models.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_remote_source.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('故事板 HTTP API 执行角色、冲突、批注、媒体和审计闭环', () async {
    final root = await Directory.systemTemp.createTemp(
      'remote-storyboard-http-',
    );
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final image = File('${directories.frames.path}/frame.png');
    await image.writeAsBytes(const [0, 1, 2, 3, 4, 5]);
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-http',
          projectName: 'HTTP 故事板工程',
          database: database,
          directories: directories,
        ),
      );
    final mediaRegistry = RemoteMediaRegistry(
      workspaceRegistry: workspaceRegistry,
      secret: 'storyboard-http-media',
    );
    final controller = StoryboardController(database: database);
    final boardId = controller.value.selectedBoardId!;
    controller.addOrRemoveAsset(
      StoryboardCutAsset(
        id: 'asset-http',
        imageId: 'image-http',
        sourceName: '焦点帧',
        path: image.path,
        indexNo: 1,
      ),
    );
    final source = StoryboardRemoteSource(controller);
    final storyboardRegistry = RemoteStoryboardRegistry(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
    )..attach(source);
    final facade = RemoteAccessFacade(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
      storyboardRegistry: storyboardRegistry,
    );
    final config = RemoteAccessConfig(enabled: true);
    var tokenIndex = 0;
    final auth = RemoteAuthService(
      config: config,
      tokenFactory: () => 'storyboard-http-token-${++tokenIndex}',
      pairingCodeFactory: () => '246810',
    );
    final audit = _MemoryAuditLogger();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
      auditLogger: audit,
      capabilitiesProvider: () => const {
        'workspace': true,
        'storyboards': true,
        'shootingScripts': true,
        'mediaStreaming': true,
      },
    );
    await server.start(portOverride: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
      storyboardRegistry.dispose();
      source.dispose();
      controller.dispose();
      database.dispose();
      await changeBus.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');

    auth.createPairingCode(role: RemoteAccessRole.director);
    final directorPair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '246810', 'clientName': '远端导演'},
    );
    final directorToken = directorPair.json['accessToken']! as String;
    auth.createPairingCode(role: RemoteAccessRole.viewer);
    final viewerPair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '246810', 'clientName': '只读场记'},
    );
    final viewerToken = viewerPair.json['accessToken']! as String;

    final list = await _request(
      client,
      base.resolve('/api/v1/storyboards'),
      token: viewerToken,
    );
    expect(list.statusCode, HttpStatus.ok);
    final summary =
        (list.json['items']! as List<Object?>).single as Map<String, Object?>;
    expect(summary['revision'], 1);

    final detail = await _request(
      client,
      base.resolve('/api/v1/storyboards/$boardId'),
      token: viewerToken,
    );
    final item =
        (detail.json['items']! as List<Object?>).single as Map<String, Object?>;
    final mediaId = item['imageMediaId']! as String;
    final media = await _requestBytes(
      client,
      base.resolve('/api/v1/media/$mediaId/content'),
      token: viewerToken,
    );
    expect(media.statusCode, HttpStatus.ok);
    expect(media.bytes, const [0, 1, 2, 3, 4, 5]);

    final viewerWrite = await _request(
      client,
      base.resolve('/api/v1/storyboards/$boardId'),
      method: 'PATCH',
      token: viewerToken,
      body: const {
        'expectedRevision': 1,
        'changes': {'name': '只读角色不应保存'},
      },
    );
    expect(viewerWrite.statusCode, HttpStatus.forbidden);
    expect(
      (viewerWrite.json['error']! as Map<String, Object?>)['code'],
      'permission_denied',
    );

    final updated = await _request(
      client,
      base.resolve('/api/v1/storyboards/$boardId'),
      method: 'PATCH',
      token: directorToken,
      body: const {
        'expectedRevision': 1,
        'changes': {
          'itemCaptions': {'asset-http': '来自 Web 的镜头描述'},
        },
      },
    );
    expect(updated.statusCode, HttpStatus.ok);
    expect(updated.json['revision'], 2);

    final conflict = await _request(
      client,
      base.resolve('/api/v1/storyboards/$boardId'),
      method: 'PATCH',
      token: directorToken,
      body: const {
        'expectedRevision': 1,
        'changes': {'name': '旧修订不应覆盖'},
      },
    );
    expect(conflict.statusCode, HttpStatus.conflict);
    final conflictError = conflict.json['error']! as Map<String, Object?>;
    expect(conflictError['code'], 'revision_conflict');
    expect(
      (conflictError['details']! as Map<String, Object?>)['currentRevision'],
      2,
    );

    final annotated = await _request(
      client,
      base.resolve('/api/v1/storyboards/$boardId/annotations'),
      method: 'POST',
      token: directorToken,
      body: const {
        'expectedRevision': 2,
        'assetId': 'asset-http',
        'body': '人物视线再向左一点',
      },
    );
    expect(annotated.statusCode, HttpStatus.ok);
    expect(annotated.json['revision'], 3);
    final annotation =
        (annotated.json['annotations']! as List<Object?>).single
            as Map<String, Object?>;
    expect(annotation['authorName'], '远端导演');

    final resolved = await _request(
      client,
      base.resolve(
        '/api/v1/storyboards/$boardId/annotations/${annotation['id']}',
      ),
      method: 'PATCH',
      token: directorToken,
      body: const {
        'expectedRevision': 3,
        'changes': {'resolved': true},
      },
    );
    expect(resolved.statusCode, HttpStatus.ok);
    expect(resolved.json['revision'], 4);
    expect(
      ((resolved.json['annotations']! as List<Object?>).single
          as Map<String, Object?>)['resolved'],
      isTrue,
    );
    expect(
      audit.events.map((event) => event.action),
      containsAll([
        'storyboard.update',
        'storyboard.annotation.create',
        'storyboard.annotation.update',
      ]),
    );
  });
}

class _MemoryAuditLogger implements RemoteAuditLogger {
  final List<RemoteAuditEvent> events = [];

  @override
  Future<void> record(RemoteAuditEvent event) async => events.add(event);
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

Future<_ByteResponse> _requestBytes(
  HttpClient client,
  Uri uri, {
  required String token,
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final response = await request.close();
  final bytes = await response.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  return _ByteResponse(statusCode: response.statusCode, bytes: bytes);
}

class _Response {
  const _Response({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

class _ByteResponse {
  const _ByteResponse({required this.statusCode, required this.bytes});

  final int statusCode;
  final List<int> bytes;
}
