import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_task_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_upload_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('任务可查询进度并在取消后阻止完成态回写', () async {
    final fixture = await _Fixture.create('task-registry');
    addTearDown(fixture.dispose);
    final registry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final gate = Completer<Map<String, Object?>>();
    var cancelCalls = 0;
    final created = registry.start(
      kind: 'videoAnalysis',
      onCancel: () => cancelCalls++,
      runner: (execution) async {
        execution.report(current: 2, total: 5, message: '正在解析第 2 帧');
        return gate.future;
      },
    );
    await Future<void>.delayed(Duration.zero);

    final running = registry.getCurrentProject(created.id)!;
    expect(running.status, RemoteTaskStatus.running);
    expect(running.current, 2);
    expect(running.total, 5);
    expect(running.message, '正在解析第 2 帧');

    final cancelled = await registry.cancelCurrentProject(created.id);
    expect(cancelled!.status, RemoteTaskStatus.cancelled);
    expect(cancelCalls, 1);
    gate.complete(const {'videoId': 'late-result'});
    await Future<void>.delayed(Duration.zero);
    expect(
      registry.getCurrentProject(created.id)!.status,
      RemoteTaskStatus.cancelled,
    );
  });

  test('视频上传流式落入当前工程并校验格式、大小和一次性领取', () async {
    final fixture = await _Fixture.create('upload-registry');
    addTearDown(fixture.dispose);
    final registry = RemoteUploadRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
    );

    final upload = await registry.receiveVideo(
      fileName: r'C:\browser\样片.mp4',
      bytes: Stream.fromIterable(const [
        [1, 2, 3],
        [4, 5],
      ]),
      maxBytes: 8,
      declaredLength: 5,
    );
    expect(upload.fileName, '样片.mp4');
    expect(upload.size, 5);
    expect(upload.file.readAsBytesSync(), const [1, 2, 3, 4, 5]);
    expect(
      upload.file.path,
      startsWith(fixture.directories.temp.absolute.path),
    );
    expect(registry.claimCurrentProject(upload.id), isNotNull);
    expect(registry.claimCurrentProject(upload.id), isNull);

    await expectLater(
      registry.receiveVideo(
        fileName: '脚本.exe',
        bytes: const Stream.empty(),
        maxBytes: 8,
      ),
      throwsA(
        isA<RemoteUploadException>().having(
          (error) => error.code,
          'code',
          'unsupported_video_format',
        ),
      ),
    );
    await expectLater(
      registry.receiveVideo(
        fileName: '过大.mp4',
        bytes: Stream.fromIterable(const [
          [1, 2, 3],
          [4],
        ]),
        maxBytes: 3,
      ),
      throwsA(
        isA<RemoteUploadException>().having(
          (error) => error.code,
          'code',
          'upload_too_large',
        ),
      ),
    );
  });

  test('HTTP 上传与任务查询取消形成认证闭环且响应不泄露路径', () async {
    final fixture = await _Fixture.create('upload-http');
    addTearDown(fixture.dispose);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final uploadRegistry = RemoteUploadRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
    );
    final facade = RemoteAccessFacade(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: taskRegistry,
    );
    final config = RemoteAccessConfig(
      enabled: true,
      maxUploadBytes: 1024 * 1024,
    );
    final auth = RemoteAuthService(
      config: config,
      pairingCodeFactory: () => '778899',
      tokenFactory: () => 'upload-http-token',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: fixture.changeBus,
      uploadRegistry: uploadRegistry,
    );
    await server.start(portOverride: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
    });
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
    final pair = await _jsonRequest(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '778899', 'clientName': 'Web 导演'},
    );
    final token = pair['accessToken']! as String;

    final uploadRequest = await client.postUrl(
      base.resolve('/api/v1/uploads/videos'),
    );
    uploadRequest.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.binary
      ..set('X-File-Name', Uri.encodeComponent('浏览器样片.mp4'))
      ..contentLength = 6;
    uploadRequest.add(const [0, 1, 2, 3, 4, 5]);
    final uploadResponse = await uploadRequest.close();
    final uploadJson =
        jsonDecode(await utf8.decoder.bind(uploadResponse).join())
            as Map<String, Object?>;
    expect(uploadResponse.statusCode, HttpStatus.created);
    expect(uploadJson['fileName'], '浏览器样片.mp4');
    expect(jsonEncode(uploadJson), isNot(contains(fixture.root.path)));

    final taskGate = Completer<Map<String, Object?>>();
    var cancelCalls = 0;
    final task = taskRegistry.start(
      kind: 'videoImport',
      onCancel: () => cancelCalls++,
      runner: (_) => taskGate.future,
    );
    await Future<void>.delayed(Duration.zero);
    final taskList = await _jsonRequest(
      client,
      base.resolve('/api/v1/tasks'),
      token: token,
    );
    expect((taskList['items']! as List<Object?>).single, isA<Map>());
    final cancelled = await _jsonRequest(
      client,
      base.resolve('/api/v1/tasks/${task.id}/cancel'),
      method: 'POST',
      token: token,
    );
    expect(cancelled['status'], 'cancelled');
    expect(cancelCalls, 1);
    taskGate.complete(const {});
  });
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.directories,
    required this.database,
    required this.changeBus,
    required this.workspaceRegistry,
  });

  final Directory root;
  final ProjectDirectories directories;
  final AppDatabase database;
  final RemoteChangeBus changeBus;
  final RemoteWorkspaceRegistry workspaceRegistry;

  static Future<_Fixture> create(String prefix) async {
    final root = await Directory.systemTemp.createTemp('$prefix-');
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'project-$prefix',
          projectName: '测试工程',
          database: database,
          directories: directories,
        ),
      );
    return _Fixture(
      root: root,
      directories: directories,
      database: database,
      changeBus: changeBus,
      workspaceRegistry: workspaceRegistry,
    );
  }

  Future<void> dispose() async {
    database.dispose();
    await changeBus.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _jsonRequest(
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
  return source.isEmpty ? const {} : jsonDecode(source) as Map<String, Object?>;
}
