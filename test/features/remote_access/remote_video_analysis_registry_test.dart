import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_task_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_upload_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_video_analysis_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_video_analysis_models.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频 registry 投影媒体、消费 uploadId 并驱动解析与建板任务', () async {
    final fixture = await _Fixture.create('video-registry');
    addTearDown(fixture.dispose);
    final source = await _FakeVideoSource.create(fixture.directories);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final uploadRegistry = RemoteUploadRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
    );
    final registry = RemoteVideoAnalysisRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      mediaRegistry: RemoteMediaRegistry(
        workspaceRegistry: fixture.workspaceRegistry,
        secret: 'video-test-secret',
      ),
      uploadRegistry: uploadRegistry,
      taskRegistry: taskRegistry,
    )..attach(source);
    addTearDown(() {
      registry.dispose();
      source.dispose();
    });

    final collection = registry.collection();
    final videoJson =
        (collection['items']! as List<Object?>).single as Map<String, Object?>;
    expect(videoJson['fileName'], '样片.mp4');
    expect(videoJson['mediaUrl'], startsWith('/api/v1/media/'));
    expect(jsonEncode(videoJson), isNot(contains(fixture.root.path)));
    final detail = registry.detail('video-a');
    expect((detail['frames']! as List<Object?>), hasLength(1));
    expect(jsonEncode(detail), isNot(contains(fixture.root.path)));

    final removed = registry.removeFrame('video-a', 'frame-a');
    expect(source.frameRemoveCalls, 1);
    expect(
      (removed['analysisState']!
          as Map<String, Object?>)['canUndoFrameRemoval'],
      isTrue,
    );
    registry.undoFrameRemoval('video-a');
    expect(source.frameUndoCalls, 1);
    registry.redoFrameRemoval('video-a');
    expect(source.frameRedoCalls, 1);

    final upload = await uploadRegistry.receiveVideo(
      fileName: '浏览器上传.mov',
      bytes: Stream.value(const [1, 2, 3, 4]),
      maxBytes: 1024,
    );
    final importTask = registry.importUpload(upload.id);
    final imported = await _waitForTask(taskRegistry, importTask.id);
    expect(imported.status, RemoteTaskStatus.succeeded);
    expect(source.lastImportedFileName, '浏览器上传.mov');
    expect(source.videos, hasLength(2));
    expect(upload.file.existsSync(), isFalse);

    final analysisTask = registry.startAnalysis('video-a');
    await Future<void>.delayed(Duration.zero);
    expect(
      taskRegistry.getCurrentProject(analysisTask.id)!.status,
      RemoteTaskStatus.running,
    );
    final pausedDetail = registry.pauseAnalysis('video-a');
    expect(
      (pausedDetail['analysisState']! as Map<String, Object?>)['isPaused'],
      isTrue,
    );
    expect(taskRegistry.getCurrentProject(analysisTask.id)!.current, 1);
    expect(taskRegistry.getCurrentProject(analysisTask.id)!.total, 3);
    source.finishAnalysis();
    expect(
      (await _waitForTask(taskRegistry, analysisTask.id)).status,
      RemoteTaskStatus.succeeded,
    );

    source.prepareAnalysis();
    final cancelledTask = registry.startAnalysis('video-a');
    await Future<void>.delayed(Duration.zero);
    await registry.cancelAnalysis('video-a');
    expect(
      taskRegistry.getCurrentProject(cancelledTask.id)!.status,
      RemoteTaskStatus.cancelled,
    );
    source.finishAnalysis();

    final storyboardTask = registry.generateStoryboard('video-a');
    expect(
      (await _waitForTask(taskRegistry, storyboardTask.id)).status,
      RemoteTaskStatus.succeeded,
    );
    expect(source.storyboardCalls, 1);
  });

  test('视频 HTTP API 提供列表详情、导入、解析、暂停、取消和建板命令', () async {
    final fixture = await _Fixture.create('video-http');
    addTearDown(fixture.dispose);
    final source = await _FakeVideoSource.create(fixture.directories);
    final taskRegistry = RemoteTaskRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
    );
    final uploadRegistry = RemoteUploadRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
    );
    final registry = RemoteVideoAnalysisRegistry(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      mediaRegistry: RemoteMediaRegistry(
        workspaceRegistry: fixture.workspaceRegistry,
        secret: 'video-http-secret',
      ),
      uploadRegistry: uploadRegistry,
      taskRegistry: taskRegistry,
    )..attach(source);
    final facade = RemoteAccessFacade(
      workspaceRegistry: fixture.workspaceRegistry,
      changeBus: fixture.changeBus,
      taskRegistry: taskRegistry,
      videoAnalysisRegistry: registry,
    );
    final config = RemoteAccessConfig(
      enabled: true,
      maxUploadBytes: 1024 * 1024,
    );
    final auth = RemoteAuthService(
      config: config,
      pairingCodeFactory: () => '112233',
      tokenFactory: () => 'video-http-token',
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
      registry.dispose();
      source.dispose();
    });
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
    final pair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '112233', 'clientName': 'Web 导演'},
    );
    final token = pair.json['accessToken']! as String;

    final list = await _request(
      client,
      base.resolve('/api/v1/videos'),
      token: token,
    );
    expect(list.statusCode, HttpStatus.ok);
    expect(list.json['items'], hasLength(1));
    final detail = await _request(
      client,
      base.resolve('/api/v1/videos/video-a'),
      token: token,
    );
    expect(detail.statusCode, HttpStatus.ok);
    expect(detail.json['id'], 'video-a');

    final removedFrame = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/frames/frame-a'),
      method: 'DELETE',
      token: token,
    );
    expect(removedFrame.statusCode, HttpStatus.ok);
    expect(source.frameRemoveCalls, 1);
    final restoredFrame = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/frames/undo'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(restoredFrame.statusCode, HttpStatus.ok);
    final removedAgain = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/frames/redo'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(removedAgain.statusCode, HttpStatus.ok);

    final upload = await uploadRegistry.receiveVideo(
      fileName: '远程导入.mp4',
      bytes: Stream.value(const [7, 8, 9]),
      maxBytes: 1024,
    );
    final imported = await _request(
      client,
      base.resolve('/api/v1/videos/import'),
      method: 'POST',
      token: token,
      body: {'uploadId': upload.id},
    );
    expect(imported.statusCode, HttpStatus.accepted);
    expect(imported.json['kind'], 'videoImport');

    final analyzing = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/analyze'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(analyzing.statusCode, HttpStatus.accepted);
    expect(analyzing.json['kind'], 'videoAnalysis');
    final paused = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/pause'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(paused.statusCode, HttpStatus.ok);
    source.finishAnalysis();
    await _waitForTask(taskRegistry, analyzing.json['id']! as String);

    source.prepareAnalysis();
    final nextAnalysis = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/analyze'),
      method: 'POST',
      token: token,
      body: const {'retryFailedOnly': true},
    );
    final cancelled = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/cancel'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(cancelled.statusCode, HttpStatus.ok);
    expect(
      taskRegistry
          .getCurrentProject(nextAnalysis.json['id']! as String)!
          .status,
      RemoteTaskStatus.cancelled,
    );
    source.finishAnalysis();

    final storyboard = await _request(
      client,
      base.resolve('/api/v1/videos/video-a/storyboard'),
      method: 'POST',
      token: token,
      body: const {},
    );
    expect(storyboard.statusCode, HttpStatus.accepted);
    expect(storyboard.json['kind'], 'videoStoryboard');

    final missing = await _request(
      client,
      base.resolve('/api/v1/videos/missing'),
      token: token,
    );
    expect(missing.statusCode, HttpStatus.notFound);
  });
}

class _FakeVideoSource extends ChangeNotifier
    implements RemoteVideoAnalysisSource {
  _FakeVideoSource(this._directories, this._videos);

  final ProjectDirectories _directories;
  final List<RemoteVideoRecord> _videos;
  Completer<void> _analysisGate = Completer<void>();
  bool _isAnalyzing = false;
  bool _isPaused = false;
  String lastImportedFileName = '';
  int storyboardCalls = 0;
  int frameRemoveCalls = 0;
  int frameUndoCalls = 0;
  int frameRedoCalls = 0;
  bool _canUndoFrameRemoval = false;
  bool _canRedoFrameRemoval = false;

  static Future<_FakeVideoSource> create(ProjectDirectories directories) async {
    final video = File(
      '${directories.videos.path}${Platform.pathSeparator}样片.mp4',
    );
    final frame = File(
      '${directories.frames.path}${Platform.pathSeparator}00001.jpg',
    );
    await video.parent.create(recursive: true);
    await frame.parent.create(recursive: true);
    await video.writeAsBytes(const [1, 2, 3]);
    await frame.writeAsBytes(const [4, 5, 6]);
    return _FakeVideoSource(directories, [
      _videoRecord('video-a', '样片.mp4', video.path),
    ]);
  }

  @override
  List<RemoteVideoRecord> get videos => List.unmodifiable(_videos);

  @override
  RemoteVideoOperationProgress get operationProgress =>
      const RemoteVideoOperationProgress(
        current: 0,
        total: 1,
        message: '正在处理测试视频',
      );

  @override
  RemoteVideoDetailRecord? videoById(String videoId) {
    final video = _videos.where((item) => item.id == videoId).firstOrNull;
    if (video == null) return null;
    final framePath =
        '${_directories.frames.path}${Platform.pathSeparator}00001.jpg';
    return RemoteVideoDetailRecord(
      video: video,
      frames: [
        RemoteVideoFrameRecord(
          id: 'frame-a',
          index: 0,
          timestampMs: 0,
          width: 1920,
          height: 1080,
          sharpness: 88,
          brightness: 0.5,
          motionScore: 0.1,
          isFocus: true,
          isSelected: true,
          status: 'completed',
          errorMessage: '',
          createdAt: DateTime.utc(2026, 1, 1),
          localPath: framePath,
          analysis: RemoteVideoFrameAnalysisRecord(
            id: 'analysis-a',
            sequenceNo: 1,
            dimensions: const {'场景': '工作室'},
            status: 'completed',
            errorMessage: '',
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ),
      ],
      shots: const [],
      marketingAnalyses: const [],
      summary: null,
      isAnalyzing: _isAnalyzing,
      isPaused: _isPaused,
      completedProgress: _isPaused ? 1 : 0,
      totalProgress: 3,
      message: _isPaused ? '解析已暂停' : (_isAnalyzing ? '正在解析' : ''),
      errorMessage: '',
      canUndoFrameRemoval: _canUndoFrameRemoval,
      canRedoFrameRemoval: _canRedoFrameRemoval,
    );
  }

  @override
  Future<RemoteVideoImportResult> importVideo(
    File file, {
    required String fileName,
  }) async {
    lastImportedFileName = fileName;
    final target = File(
      '${_directories.videos.path}${Platform.pathSeparator}$fileName',
    );
    await file.copy(target.path);
    final id = 'video-${_videos.length + 1}';
    _videos.add(_videoRecord(id, fileName, target.path));
    notifyListeners();
    return RemoteVideoImportResult(videoId: id);
  }

  @override
  Future<void> startAnalysis(
    String videoId, {
    bool retryFailedOnly = false,
  }) async {
    _isAnalyzing = true;
    _isPaused = false;
    notifyListeners();
    await _analysisGate.future;
    _isAnalyzing = false;
    notifyListeners();
  }

  @override
  bool pauseAnalysis(String videoId) {
    if (!_isAnalyzing) return false;
    _isPaused = true;
    notifyListeners();
    return true;
  }

  @override
  bool cancelAnalysis(String videoId) {
    if (!_isAnalyzing) return false;
    _isPaused = false;
    _isAnalyzing = false;
    notifyListeners();
    return true;
  }

  void prepareAnalysis() {
    _analysisGate = Completer<void>();
    _isAnalyzing = false;
    _isPaused = false;
  }

  void finishAnalysis() {
    if (!_analysisGate.isCompleted) _analysisGate.complete();
  }

  @override
  Future<bool> generateStoryboard(String videoId) async {
    storyboardCalls++;
    return true;
  }

  @override
  bool removeFrame(String videoId, String frameId) {
    frameRemoveCalls++;
    _canUndoFrameRemoval = true;
    _canRedoFrameRemoval = false;
    notifyListeners();
    return true;
  }

  @override
  bool undoFrameRemoval(String videoId) {
    if (!_canUndoFrameRemoval) return false;
    frameUndoCalls++;
    _canUndoFrameRemoval = false;
    _canRedoFrameRemoval = true;
    notifyListeners();
    return true;
  }

  @override
  bool redoFrameRemoval(String videoId) {
    if (!_canRedoFrameRemoval) return false;
    frameRedoCalls++;
    _canUndoFrameRemoval = true;
    _canRedoFrameRemoval = false;
    notifyListeners();
    return true;
  }

  static RemoteVideoRecord _videoRecord(
    String id,
    String fileName,
    String localPath,
  ) => RemoteVideoRecord(
    id: id,
    fileName: fileName,
    durationMs: 5000,
    frameRate: 25,
    width: 1920,
    height: 1080,
    displayWidth: 1920,
    displayHeight: 1080,
    rotationDegrees: 0,
    hasAudio: true,
    frameCount: 1,
    successfulFrames: 1,
    failedFrames: 0,
    status: 'pending',
    errorMessage: '',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
    localPath: localPath,
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

class _Response {
  const _Response({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final values = iterator;
    return values.moveNext() ? values.current : null;
  }
}
