import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_task_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_video_generation_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_video_generation_models.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频生成 registry 投影动态参数、镜头、任务、作品并驱动启动取消重试', () async {
    final fixture = await _Fixture.create('generation-registry');
    addTearDown(fixture.dispose);
    final source = await _FakeGenerationSource.create(fixture.directories);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final registry = RemoteVideoGenerationRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      mediaRegistry: RemoteMediaRegistry(
        workspaceRegistry: fixture.workspaceRegistry,
        secret: 'generation-registry-secret',
      ),
      taskRegistry: taskRegistry,
    )..attach(source);
    addTearDown(() {
      registry.dispose();
      source.dispose();
    });

    final options = registry.options();
    expect(options['selectedScriptId'], 'script-a');
    expect(
      ((options['parameters']! as List<Object?>).single
          as Map<String, Object?>)['key'],
      'ratio',
    );
    expect(jsonEncode(options), isNot(contains('api-key')));

    final groups = registry.groups();
    final group =
        (groups['items']! as List<Object?>).single as Map<String, Object?>;
    expect(group['referenceImageUrl'], startsWith('/api/v1/media/'));
    expect(jsonEncode(group), isNot(contains(fixture.root.path)));

    final tasks = registry.tasks();
    expect(tasks['items'], hasLength(3));
    final works = registry.works();
    final work =
        (works['items']! as List<Object?>).single as Map<String, Object?>;
    expect(work['mediaUrl'], startsWith('/api/v1/media/'));
    expect(jsonEncode(works), isNot(contains(fixture.root.path)));

    final selection = registry.selectScript('script-b');
    expect(
      (selection['options']! as Map<String, Object?>)['selectedScriptId'],
      'script-b',
    );
    registry.selectScript('script-a');

    final generation = registry.start(
      const RemoteVideoGenerationCommand(
        scriptId: 'script-a',
        shotIds: ['group-a'],
        parameters: {'ratio': '9:16'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(source.lastCommand?.parameters['ratio'], '9:16');
    source.finishGeneration();
    final finished = await _waitForTask(taskRegistry, generation.id);
    expect(finished.status, RemoteTaskStatus.succeeded);
    expect(finished.result['total'], 1);

    source.prepareGeneration();
    final cancelled = registry.start(
      const RemoteVideoGenerationCommand(shotIds: ['group-a']),
    );
    await Future<void>.delayed(Duration.zero);
    await taskRegistry.cancelCurrentProject(cancelled.id);
    expect(
      taskRegistry.getCurrentProject(cancelled.id)!.status,
      RemoteTaskStatus.cancelled,
    );
    expect(source.cancelOperationCalls, 1);

    final cancelledGenerationTask = await registry.cancelTask('task-running');
    expect(cancelledGenerationTask['status'], 'canceled');

    source.prepareGeneration();
    final retried = registry.retry('task-failed');
    await Future<void>.delayed(Duration.zero);
    expect(source.lastCommand?.shotIds, ['group-a']);
    source.finishGeneration();
    expect(
      (await _waitForTask(taskRegistry, retried.id)).status,
      RemoteTaskStatus.succeeded,
    );
  });

  test('视频生成 HTTP API 提供选择、参数、镜头、启动、取消、重试、作品与媒体读取', () async {
    final fixture = await _Fixture.create('generation-http');
    addTearDown(fixture.dispose);
    final source = await _FakeGenerationSource.create(fixture.directories);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final mediaRegistry = RemoteMediaRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      secret: 'generation-http-secret',
    );
    final registry = RemoteVideoGenerationRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      mediaRegistry: mediaRegistry,
      taskRegistry: taskRegistry,
    )..attach(source);
    final facade = RemoteAccessFacade(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: taskRegistry,
      videoGenerationRegistry: registry,
    );
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      pairingCodeFactory: () => '667788',
      tokenFactory: () => 'generation-http-token',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: fixture.changeBus,
      mediaRegistry: mediaRegistry,
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
      body: const {'code': '667788', 'clientName': '生成视频 Web'},
    );
    final token = pair.json['accessToken']! as String;

    final options = await _request(
      client,
      base.resolve('/api/v1/video-generation/options'),
      token: token,
    );
    expect(options.statusCode, HttpStatus.ok);
    expect(options.json['backend'], isA<Map<String, Object?>>());

    final selection = await _request(
      client,
      base.resolve('/api/v1/video-generation/selection'),
      method: 'POST',
      token: token,
      body: const {'scriptId': 'script-b'},
    );
    expect(selection.statusCode, HttpStatus.ok);
    expect(
      (selection.json['options']! as Map<String, Object?>)['selectedScriptId'],
      'script-b',
    );

    final groups = await _request(
      client,
      base.resolve('/api/v1/video-generation/groups'),
      token: token,
    );
    expect(groups.statusCode, HttpStatus.ok);
    expect(groups.json['items'], hasLength(1));

    source.selectScript('script-a');
    source.prepareGeneration();
    final started = await _request(
      client,
      base.resolve('/api/v1/video-generation/tasks'),
      method: 'POST',
      token: token,
      body: const {
        'scriptId': 'script-a',
        'shotIds': ['group-a'],
        'parameters': {'ratio': '9:16', 'count': 2},
        'shotOverrides': {
          'group-a': {
            'prompt': 'Web 自定义提示词',
            'promptMode': 'edited',
            'durationSeconds': 6,
          },
        },
      },
    );
    expect(started.statusCode, HttpStatus.accepted);
    expect(started.json['kind'], 'videoGeneration');
    await Future<void>.delayed(Duration.zero);
    expect(source.lastCommand?.parameters['count'], '2');
    expect(source.lastCommand?.shotOverrides['group-a']?.durationSeconds, 6);
    source.finishGeneration();
    await _waitForTask(taskRegistry, started.json['id']! as String);

    final generationTasks = await _request(
      client,
      base.resolve('/api/v1/video-generation/tasks'),
      token: token,
    );
    expect(generationTasks.statusCode, HttpStatus.ok);
    expect(generationTasks.json['items'], isNotEmpty);

    final cancelled = await _request(
      client,
      base.resolve('/api/v1/video-generation/tasks/task-running/cancel'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(cancelled.statusCode, HttpStatus.ok);
    expect(cancelled.json['status'], 'canceled');

    source.prepareGeneration();
    final retried = await _request(
      client,
      base.resolve('/api/v1/video-generation/tasks/task-failed/retry'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(retried.statusCode, HttpStatus.accepted);
    source.finishGeneration();
    await _waitForTask(taskRegistry, retried.json['id']! as String);

    final works = await _request(
      client,
      base.resolve('/api/v1/video-generation/works'),
      token: token,
    );
    expect(works.statusCode, HttpStatus.ok);
    final work =
        (works.json['items']! as List<Object?>).first as Map<String, Object?>;
    final media = await _requestBytes(
      client,
      base.resolve(work['mediaUrl']! as String),
      token: token,
    );
    expect(media.statusCode, HttpStatus.ok);
    expect(media.bytes, isNotEmpty);
  });
}

class _FakeGenerationSource extends ChangeNotifier
    implements RemoteVideoGenerationSource {
  _FakeGenerationSource(this._referenceFile, this._workFile) {
    _tasks.addAll([
      _task('task-running', 'running'),
      _task('task-failed', 'failed', errorMessage: '测试失败'),
      _task(
        'task-work',
        'completed',
        localPath: _workFile.path,
        hasLocalResult: true,
      ),
    ]);
  }

  final File _referenceFile;
  final File _workFile;
  final List<RemoteVideoGenerationTaskRecord> _tasks = [];
  final Set<String> _cancelledOperations = {};
  Completer<void> _generationGate = Completer<void>();
  String _selectedScriptId = 'script-a';
  int _generationCount = 0;
  int cancelOperationCalls = 0;
  RemoteVideoGenerationCommand? lastCommand;

  static Future<_FakeGenerationSource> create(
    ProjectDirectories directories,
  ) async {
    final reference = File(
      '${directories.frames.path}${Platform.pathSeparator}generation.jpg',
    );
    final work = File(
      '${directories.root.path}${Platform.pathSeparator}generated.mp4',
    );
    await reference.parent.create(recursive: true);
    await reference.writeAsBytes(const [1, 2, 3]);
    await work.writeAsBytes(const [4, 5, 6, 7]);
    return _FakeGenerationSource(reference, work);
  }

  @override
  RemoteVideoGenerationOptionsRecord get options =>
      RemoteVideoGenerationOptionsRecord(
        scripts: [
          RemoteVideoGenerationScriptRecord(
            id: 'script-a',
            name: '脚本 A',
            status: 'active',
            version: 1,
            isSelected: _selectedScriptId == 'script-a',
          ),
          RemoteVideoGenerationScriptRecord(
            id: 'script-b',
            name: '脚本 B',
            status: 'draft',
            version: 2,
            isSelected: _selectedScriptId == 'script-b',
          ),
        ],
        selectedScriptId: _selectedScriptId,
        backendKind: 'libTvCli',
        backendName: 'LibTV',
        backendReady: true,
        backendMessage: '已就绪',
        projectAspectRatio: '9:16',
        models: const [RemoteVideoGenerationModelRecord(id: 'h3', name: 'H3')],
        selectedModelId: 'h3',
        parameters: const [
          RemoteVideoGenerationParameterRecord(
            key: 'ratio',
            label: '比例',
            component: 'select',
            group: 'basic',
            value: '9:16',
            options: [
              RemoteVideoGenerationParameterOption(
                value: '9:16',
                label: '9:16',
              ),
            ],
          ),
        ],
      );

  @override
  List<RemoteVideoGenerationGroupRecord> get groups => [
    RemoteVideoGenerationGroupRecord(
      id: 'group-a',
      scriptId: _selectedScriptId,
      shotIds: const ['group-a'],
      shotNumbers: const [1],
      title: '镜头 1',
      durationSeconds: 5,
      prompt: '测试提示词',
      promptMode: 'h3Optimized',
      canGenerate: true,
      isActive: false,
      referenceImagePath: _referenceFile.path,
    ),
  ];

  @override
  List<RemoteVideoGenerationTaskRecord> get tasks => List.unmodifiable(_tasks);

  @override
  List<RemoteVideoGenerationTaskRecord> get works =>
      _tasks.where((task) => task.hasLocalResult).toList(growable: false);

  @override
  void selectScript(String scriptId) {
    if (!const {'script-a', 'script-b'}.contains(scriptId)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_script_not_found',
        '脚本不存在',
      );
    }
    _selectedScriptId = scriptId;
    notifyListeners();
  }

  @override
  RemoteVideoGenerationTaskRecord? taskById(String taskId) =>
      _tasks.where((task) => task.id == taskId).firstOrNull;

  @override
  Future<RemoteVideoGenerationOperationResult> startGeneration(
    RemoteVideoGenerationCommand command, {
    required String operationId,
  }) async {
    lastCommand = command;
    if (command.scriptId != null) selectScript(command.scriptId!);
    notifyListeners();
    await _generationGate.future;
    if (_cancelledOperations.remove(operationId)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_cancelled',
        '已取消',
      );
    }
    final task = _task(
      'generated-${++_generationCount}',
      'completed',
      localPath: _workFile.path,
      hasLocalResult: true,
    );
    _tasks.insert(0, task);
    notifyListeners();
    return RemoteVideoGenerationOperationResult(tasks: [task]);
  }

  @override
  RemoteVideoGenerationOperationProgress operationProgress(
    String operationId,
  ) => const RemoteVideoGenerationOperationProgress(
    current: 0,
    total: 1,
    message: '正在生成',
  );

  @override
  Future<bool> cancelOperation(String operationId) async {
    cancelOperationCalls++;
    _cancelledOperations.add(operationId);
    finishGeneration();
    return true;
  }

  @override
  Future<RemoteVideoGenerationTaskRecord?> cancelTask(String taskId) async {
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) return null;
    final current = _tasks[index];
    final cancelled = _task(
      current.id,
      'canceled',
      localPath: current.localPath,
      hasLocalResult: current.hasLocalResult,
    );
    _tasks[index] = cancelled;
    notifyListeners();
    return cancelled;
  }

  void prepareGeneration() {
    _generationGate = Completer<void>();
  }

  void finishGeneration() {
    if (!_generationGate.isCompleted) _generationGate.complete();
  }

  RemoteVideoGenerationTaskRecord _task(
    String id,
    String status, {
    String errorMessage = '',
    String localPath = '',
    bool hasLocalResult = false,
  }) => RemoteVideoGenerationTaskRecord(
    id: id,
    scriptId: 'script-a',
    shotId: 'group-a',
    shotNumber: 1,
    model: 'H3',
    parameters: const {'ratio': '9:16'},
    durationSeconds: 5,
    promptMode: 'h3Optimized',
    prompt: '测试提示词',
    status: status,
    errorMessage: errorMessage,
    createdAt: DateTime.utc(2026, 8, 12),
    updatedAt: DateTime.utc(2026, 8, 12, 0, 1),
    completedAt: status == 'completed' ? DateTime.utc(2026, 8, 12, 0, 1) : null,
    localPath: localPath,
    hasLocalResult: hasLocalResult,
  );
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

Future<RemoteTaskSnapshot> _waitForTask(
  RemoteTaskRegistry registry,
  String taskId,
) async {
  for (var index = 0; index < 100; index++) {
    final task = registry.getCurrentProject(taskId)!;
    if (task.terminal) return task;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('等待任务结束超时：$taskId');
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

Future<_BytesResponse> _requestBytes(
  HttpClient client,
  Uri uri, {
  required String token,
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final response = await request.close();
  final bytes = await response.fold<List<int>>(<int>[], (buffer, data) {
    buffer.addAll(data);
    return buffer;
  });
  return _BytesResponse(statusCode: response.statusCode, bytes: bytes);
}

class _Response {
  const _Response({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

class _BytesResponse {
  const _BytesResponse({required this.statusCode, required this.bytes});

  final int statusCode;
  final List<int> bytes;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final values = iterator;
    return values.moveNext() ? values.current : null;
  }
}
