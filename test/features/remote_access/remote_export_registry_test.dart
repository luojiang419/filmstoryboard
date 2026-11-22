import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_export_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_task_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_export_models.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('导出 registry 仅投影安全选项和已登记产物并支持取消失败重试', () async {
    final fixture = await _Fixture.create('export-registry');
    addTearDown(fixture.dispose);
    final source = _FakeExportSource();
    final tasks = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final registry = RemoteExportRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: tasks,
    )..attach(source);
    addTearDown(() {
      registry.dispose();
      source.dispose();
    });

    final options = registry.options();
    expect(options['storyboardFormats'], ['png', 'jpg', 'pdf']);
    expect(jsonEncode(options), isNot(contains(fixture.root.path)));

    final started = registry.start(
      const RemoteExportCommand(
        kind: 'storyboardDocument',
        boardIds: ['board-1'],
        format: 'png',
        resolution: 'sourceDetail',
      ),
    );
    final completed = await _waitForTask(tasks, started.id);
    expect(completed.status, RemoteTaskStatus.succeeded);
    final artifactJson =
        (completed.result['artifacts']! as List<Object?>).single
            as Map<String, Object?>;
    expect(
      artifactJson['contentUrl'],
      startsWith('/api/v1/exports/artifacts/'),
    );
    expect(artifactJson['downloadUrl'], endsWith('?download=1'));
    expect(jsonEncode(completed.toJson()), isNot(contains(fixture.root.path)));
    final artifact = registry.resolveArtifact(artifactJson['id']! as String);
    expect(artifact?.file.existsSync(), isTrue);
    expect(artifact?.previewable, isTrue);

    source.mode = _FakeExportMode.cancel;
    final cancelling = registry.start(
      const RemoteExportCommand(kind: 'boardImages', boardIds: ['board-1']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tasks.cancelCurrentProject(cancelling.id);
    expect(
      (await _waitForTask(tasks, cancelling.id)).status,
      RemoteTaskStatus.cancelled,
    );

    source.mode = _FakeExportMode.fail;
    final failing = registry.start(
      const RemoteExportCommand(kind: 'boardImages', boardIds: ['board-1']),
    );
    expect(
      (await _waitForTask(tasks, failing.id)).status,
      RemoteTaskStatus.failed,
    );
    source.mode = _FakeExportMode.success;
    final retried = registry.retry(failing.id);
    expect(
      (await _waitForTask(tasks, retried.id)).status,
      RemoteTaskStatus.succeeded,
    );

    fixture.workspaceRegistry.detach(projectId: fixture.projectId);
    expect(registry.resolveArtifact(artifactJson['id']! as String), isNull);
  });

  test('导出 registry 拒绝登记受控导出根目录之外的文件', () async {
    final fixture = await _Fixture.create('export-boundary');
    addTearDown(fixture.dispose);
    final source = _FakeExportSource()..mode = _FakeExportMode.outside;
    final tasks = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final registry = RemoteExportRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: tasks,
    )..attach(source);
    addTearDown(() {
      registry.dispose();
      source.dispose();
    });

    final task = registry.start(
      const RemoteExportCommand(kind: 'boardImages', boardIds: ['board-1']),
    );
    final failed = await _waitForTask(tasks, task.id);
    expect(failed.status, RemoteTaskStatus.failed);
    expect(failed.errorMessage, contains('允许的目录'));
  });

  test('导出 HTTP API 启动真实本机任务并提供鉴权预览下载且拒绝路径字段', () async {
    final fixture = await _Fixture.create('export-http');
    addTearDown(fixture.dispose);
    final source = _FakeExportSource();
    final tasks = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final registry = RemoteExportRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: tasks,
    )..attach(source);
    final facade = RemoteAccessFacade(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: tasks,
      exportRegistry: registry,
    );
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      pairingCodeFactory: () => '112233',
      tokenFactory: () => 'export-http-token',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: fixture.changeBus,
      exportRegistry: registry,
    );
    await server.start(portOverride: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
      registry.dispose();
      source.dispose();
    });
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
    final pair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '112233', 'clientName': '导出 Web'},
    );
    final token = pair.json['accessToken']! as String;

    final options = await _request(
      client,
      base.resolve('/api/v1/exports/options'),
      token: token,
    );
    expect(options.statusCode, HttpStatus.ok);
    expect(options.json['boards'], hasLength(1));
    expect(jsonEncode(options.json), isNot(contains(fixture.root.path)));

    final rejected = await _request(
      client,
      base.resolve('/api/v1/exports/tasks'),
      method: 'POST',
      token: token,
      body: const {
        'kind': 'boardImages',
        'boardIds': ['board-1'],
        'outputPath': r'C:\任意路径',
      },
    );
    expect(rejected.statusCode, HttpStatus.badRequest);
    expect(rejected.json['error'], isA<Map<String, Object?>>());

    final started = await _request(
      client,
      base.resolve('/api/v1/exports/tasks'),
      method: 'POST',
      token: token,
      body: const {
        'kind': 'storyboardDocument',
        'boardIds': ['board-1'],
        'format': 'png',
        'resolution': 'sourceDetail',
      },
    );
    expect(started.statusCode, HttpStatus.accepted);
    final completed = await _waitForTask(tasks, started.json['id']! as String);
    final artifact =
        (completed.result['artifacts']! as List<Object?>).single
            as Map<String, Object?>;

    final unauthenticated = await _requestBytes(
      client,
      base.resolve(artifact['contentUrl']! as String),
    );
    expect(unauthenticated.statusCode, HttpStatus.unauthorized);

    final preview = await _requestBytes(
      client,
      base.resolve(artifact['contentUrl']! as String),
      token: token,
    );
    expect(preview.statusCode, HttpStatus.ok);
    expect(preview.contentDisposition, startsWith('inline'));
    expect(preview.bytes, isNotEmpty);

    final download = await _requestBytes(
      client,
      base.resolve(artifact['downloadUrl']! as String),
      token: token,
    );
    expect(download.statusCode, HttpStatus.ok);
    expect(download.contentDisposition, startsWith('attachment'));
  });
}

enum _FakeExportMode { success, cancel, fail, outside }

class _FakeExportSource extends ChangeNotifier implements RemoteExportSource {
  _FakeExportMode mode = _FakeExportMode.success;

  @override
  RemoteExportOptionsRecord get options => const RemoteExportOptionsRecord(
    boards: [
      RemoteExportBoardRecord(id: 'board-1', name: '测试画板', itemCount: 2),
    ],
    videos: [RemoteExportVideoRecord(id: 'video-1', name: '测试视频.mp4')],
    scripts: [
      RemoteExportScriptRecord(
        id: 'script-1',
        name: '测试脚本',
        timelineAvailable: true,
      ),
    ],
    includeSummaryPage: true,
    includeMultiDimensionAnalysis: true,
    includeShotDetails: true,
  );

  @override
  Future<List<RemoteExportProducedFile>> export(
    RemoteExportCommand command, {
    required Directory outputDirectory,
    required RemoteExportProgressCallback onProgress,
    required RemoteExportCancellationCheck isCancelled,
  }) async {
    switch (mode) {
      case _FakeExportMode.cancel:
        while (!isCancelled()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw const RemoteExportSourceException('export_cancelled', '导出已取消');
      case _FakeExportMode.fail:
        throw const RemoteExportSourceException('fixture_failed', '模拟导出失败');
      case _FakeExportMode.outside:
        final file = File('${outputDirectory.parent.parent.path}.outside.png');
        await file.writeAsBytes(const [1, 2, 3], flush: true);
        return [RemoteExportProducedFile(file)];
      case _FakeExportMode.success:
        await outputDirectory.create(recursive: true);
        onProgress(1, 2, '正在生成测试产物');
        final file = File(
          '${outputDirectory.path}${Platform.pathSeparator}测试导出.png',
        );
        await file.writeAsBytes(const [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ], flush: true);
        onProgress(2, 2, '测试产物已生成');
        return [RemoteExportProducedFile(file)];
    }
  }
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.database,
    required this.directories,
    required this.changeBus,
    required this.workspaceRegistry,
    required this.projectId,
  });

  final Directory root;
  final AppDatabase database;
  final ProjectDirectories directories;
  final RemoteChangeBus changeBus;
  final RemoteWorkspaceRegistry workspaceRegistry;
  final String projectId;

  static Future<_Fixture> create(String name) async {
    final root = await Directory.systemTemp.createTemp('$name-');
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final database = await AppDatabase.open(directories.databaseFile);
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus);
    final projectId = '$name-project';
    workspaceRegistry.attachContext(
      RemoteWorkspaceContext(
        projectId: projectId,
        projectName: name,
        database: database,
        directories: directories,
      ),
    );
    return _Fixture(
      root: root,
      database: database,
      directories: directories,
      changeBus: changeBus,
      workspaceRegistry: workspaceRegistry,
      projectId: projectId,
    );
  }

  Future<void> dispose() async {
    database.dispose();
    await changeBus.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

Future<RemoteTaskSnapshot> _waitForTask(
  RemoteTaskRegistry registry,
  String taskId,
) async {
  for (var index = 0; index < 100; index++) {
    final task = registry.getCurrentProject(taskId)!;
    if (task.terminal) return task;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('等待导出任务结束超时：$taskId');
}

Future<_JsonResponse> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  return _JsonResponse(
    response.statusCode,
    text.isEmpty
        ? const {}
        : (jsonDecode(text) as Map).map(
            (key, value) => MapEntry('$key', value),
          ),
  );
}

Future<_BytesResponse> _requestBytes(
  HttpClient client,
  Uri uri, {
  String? token,
}) async {
  final request = await client.getUrl(uri);
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final bytes = await response.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  return _BytesResponse(
    response.statusCode,
    bytes,
    response.headers.value('content-disposition') ?? '',
  );
}

class _JsonResponse {
  const _JsonResponse(this.statusCode, this.json);

  final int statusCode;
  final Map<String, Object?> json;
}

class _BytesResponse {
  const _BytesResponse(this.statusCode, this.bytes, this.contentDisposition);

  final int statusCode;
  final List<int> bytes;
  final String contentDisposition;
}
