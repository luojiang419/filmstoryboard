import 'dart:async';
import 'dart:typed_data';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:filmstoryboard_remote_web/core/api/remote_event_client.dart';
import 'package:filmstoryboard_remote_web/core/models/remote_models.dart';
import 'package:filmstoryboard_remote_web/features/workspace/remote_app_controller.dart';
import 'package:filmstoryboard_remote_web/features/video_analysis/selected_video_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('刷新工作区会加载故事板列表和当前详情', () async {
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..storyboardsAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();

    expect(controller.storyboards.single.id, 'board-1');
    expect(controller.selectedStoryboard?.revision, 1);
    expect(controller.selectedStoryboardItem?.assetId, 'asset-1');
    expect(api.storyboardDetailRequests, 1);
  });

  test('故事板 409 冲突会自动恢复最新详情且 viewer 不会写入', () async {
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..storyboardsAvailable = true;
    addTearDown(controller.dispose);
    await controller.refreshAll();
    api
      ..detail = _detail(revision: 2, caption: '桌面端新内容')
      ..conflictOnUpdate = true;

    await controller.saveSelectedStoryboard(const {
      'itemCaptions': {'asset-1': '远程旧内容'},
    });

    expect(controller.selectedStoryboard?.revision, 2);
    expect(controller.selectedStoryboardItem?.caption, '桌面端新内容');
    expect(controller.errorMessage, contains('已为你加载最新版本'));
    expect(api.updateRequests, 1);

    controller.session = const RemoteSession(
      id: 'viewer',
      clientName: '场记',
      role: 'viewer',
      expiresAt: null,
    );
    await controller.addStoryboardAnnotation(body: '不应写入');
    expect(api.annotationRequests, 0);
  });

  test('拍摄脚本工作流恢复步骤并提交确认、匹配、构建和复刻任务', () async {
    final api = _FakeRemoteApi()..workflowEnabled = true;
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..shootingWorkflowAvailable = true
      ..tasksAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();
    expect(controller.shootingWorkflow?.scriptId, 'script-workflow');
    await controller.confirmShootingWorkflowShots();
    await controller.startShootingWorkflowAction('matchAssets');
    await controller.startShootingWorkflowAction('buildScript');
    await controller.startShootingWorkflowAction(
      'replicateStoryboards',
      shotId: 'shot-workflow',
    );

    expect(api.workflowConfirmRequests, 1);
    expect(api.workflowActions, [
      'matchAssets',
      'buildScript',
      'replicateStoryboards:shot-workflow',
    ]);
    expect(controller.shootingWorkflowTasks.length, 3);
  });

  test('视频页控制器恢复任务并串联流式上传、导入和解析命令', () async {
    final api = _FakeRemoteApi()..videoEnabled = true;
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..videoAnalysisAvailable = true
      ..videoUploadsAvailable = true
      ..tasksAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();
    expect(controller.videos.single.id, 'video-1');
    expect(controller.selectedVideoFrame?.id, 'frame-1');
    expect(controller.videoTasks.single.id, 'task-existing');

    await controller.uploadVideo(
      RemoteSelectedVideoFile(
        name: '浏览器样片.mp4',
        size: 4,
        openRead: () => Stream.value(const [1, 2, 3, 4]),
      ),
    );
    expect(api.uploadedBytes, const [1, 2, 3, 4]);
    expect(api.importRequests, 1);
    expect(controller.videoTasks.first.kind, 'videoImport');

    await controller.startSelectedVideoAnalysis();
    expect(api.analysisRequests, 1);
    expect(controller.message, contains('解析任务'));
  });

  test('生成视频控制器恢复双层任务并执行选择、启动、取消和重试', () async {
    final api = _FakeRemoteApi()
      ..videoEnabled = true
      ..generationEnabled = true;
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..videoGenerationAvailable = true
      ..tasksAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();
    expect(controller.videoGenerationOptions?.backend.name, 'LibTV');
    expect(controller.videoGenerationGroups.single.id, 'group-1');
    expect(controller.videoGenerationTasks.single.status, 'running');
    expect(controller.videoGenerationWorks.single.mediaId, 'work-media');
    expect(controller.videoGenerationOperations.single.id, 'outer-existing');

    await controller.selectVideoGenerationScript('script-2');
    expect(controller.videoGenerationOptions?.selectedScriptId, 'script-2');
    await controller.startVideoGeneration(
      shotIds: const ['group-1'],
      model: 'model-h3',
      parameters: const {'ratio': '9:16'},
      shotOverrides: const {
        'group-1': RemoteVideoGenerationShotOverride(
          prompt: '逐镜头覆盖',
          promptMode: 'edited',
          durationSeconds: 6,
        ),
      },
    );
    expect(api.generationStartRequests, 1);
    expect(api.lastGenerationParameters['ratio'], '9:16');
    expect(controller.videoGenerationOperations.first.id, 'outer-started');

    await controller.cancelVideoGenerationOperation('outer-started');
    expect(api.outerCancelRequests, 1);
    await controller.cancelVideoGenerationTask('generation-running');
    expect(api.generationCancelRequests, 1);
    expect(controller.videoGenerationTasks.first.status, 'canceled');
    await controller.retryVideoGenerationTask('generation-failed');
    expect(api.generationRetryRequests, 1);
  });

  test('生成视频 WebSocket 事件以 REST 事实来源恢复任务和作品', () async {
    final api = _FakeRemoteApi()..generationEnabled = true;
    final events = _FakeEventClient();
    final controller = RemoteAppController(api: api, eventClient: events);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.openProject('project');
    final before = api.generationOptionsRequests;
    api.generationTaskStatus = 'completed';
    events.add({
      'type': 'videoGeneration.changed',
      'data': {'taskCount': 1, 'workCount': 1},
    });
    await Future<void>.delayed(const Duration(milliseconds: 240));

    expect(api.generationOptionsRequests, greaterThan(before));
    expect(controller.videoGenerationTasks.single.status, 'completed');

    events.add({
      'type': 'task.changed',
      'data': _task('outer-live', 'videoGeneration').toJsonForTest(),
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.videoGenerationOperations.first.id, 'outer-live');
  });

  test('导出控制器恢复任务并执行启动、取消、失败重试和安全产物定位', () async {
    final api = _FakeRemoteApi()..exportEnabled = true;
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..exportsAvailable = true
      ..tasksAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();
    expect(controller.exportOptions?.boards.single.id, 'board-1');
    expect(controller.exportTasks.single.id, 'export-existing');
    final artifact = controller.exportTasks.single.exportArtifacts.single;
    expect(
      controller.exportArtifactUri(artifact, download: true).toString(),
      'http://localhost:47836/api/v1/exports/artifacts/artifact-1/content?download=1',
    );

    await controller.startExport(
      const RemoteExportRequest(
        kind: 'storyboardDocument',
        boardIds: ['board-1'],
        format: 'png',
        resolution: 'sourceDetail',
      ),
    );
    expect(api.exportStartRequests, 1);
    expect(controller.exportTasks.first.id, 'export-started');
    await controller.cancelExportTask('export-started');
    expect(api.exportCancelRequests, 1);
    await controller.retryExportTask('export-failed');
    expect(api.exportRetryRequests, 1);
  });

  test('导出 WebSocket 事件会防抖刷新 REST 选项和可恢复任务', () async {
    final api = _FakeRemoteApi()..exportEnabled = true;
    final events = _FakeEventClient();
    final controller = RemoteAppController(api: api, eventClient: events);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.openProject('project');
    final before = api.exportOptionsRequests;
    events.add({'type': 'export.changed', 'data': const {}});
    await Future<void>.delayed(const Duration(milliseconds: 240));
    expect(api.exportOptionsRequests, greaterThan(before));

    events.add({
      'type': 'task.changed',
      'data': _task('export-live', 'export').toJsonForTest(),
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.exportTasks.first.id, 'export-live');
  });
}

const _director = RemoteSession(
  id: 'director',
  clientName: '远端导演',
  role: 'director',
  expiresAt: null,
);

RemoteStoryboardDetail _detail({
  required int revision,
  String caption = '初始描述',
}) => RemoteStoryboardDetail(
  id: 'board-1',
  name: '画板 1',
  groupId: null,
  revision: revision,
  locked: false,
  rows: 1,
  columns: 1,
  itemCount: 1,
  annotationCount: 0,
  unresolvedAnnotationCount: 0,
  width: 1920,
  height: 1080,
  gap: 18,
  storyDescriptionEnabled: true,
  rowDescriptionEnabled: false,
  rowCaptions: const [''],
  rowDividerEnabled: true,
  rowDividerStyle: 'dashed',
  rowDividerOpacity: .35,
  titleAlignment: 'center',
  portraitMode: false,
  storySummary: null,
  items: [
    RemoteStoryboardItem(
      assetId: 'asset-1',
      sourceName: '焦点帧',
      indexNo: 1,
      caption: caption,
      slotIndex: 0,
      flipHorizontal: false,
      flipVertical: false,
      resourceRemoved: false,
      imageMediaId: 'media-1',
    ),
  ],
  annotations: const [],
);

const _videoSummary = RemoteVideoSummary(
  id: 'video-1',
  fileName: '样片.mp4',
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
  mediaId: 'video-media',
  createdAt: null,
  updatedAt: null,
);

const _videoDetail = RemoteVideoDetail(
  video: _videoSummary,
  analysisState: RemoteVideoAnalysisState(
    isAnalyzing: false,
    isPaused: false,
    current: 0,
    total: 1,
    message: '',
    errorMessage: '',
  ),
  frames: [
    RemoteVideoFrame(
      id: 'frame-1',
      index: 0,
      timestampMs: 1000,
      width: 1920,
      height: 1080,
      sharpness: 88,
      brightness: .5,
      motionScore: .1,
      isFocus: true,
      status: 'pending',
      errorMessage: '',
      mediaId: 'frame-media',
      analysis: null,
    ),
  ],
  shots: [],
  marketingAnalyses: [],
  summary: null,
);

RemoteTask _task(
  String id,
  String kind, {
  String status = 'running',
  Map<String, Object?> result = const {},
}) => RemoteTask(
  id: id,
  kind: kind,
  status: status,
  current: 0,
  total: 1,
  message: '处理中',
  errorCode: '',
  errorMessage: '',
  result: result,
  cancellable: status == 'running',
  createdAt: null,
  updatedAt: null,
);

const _exportOptions = RemoteExportOptions(
  storyboardFormats: ['png', 'jpg', 'pdf'],
  storyboardResolutions: ['standard', 'sourceDetail'],
  analysisReportFormats: ['xlsx', 'pdf', 'png', 'jpg'],
  boards: [RemoteExportBoard(id: 'board-1', name: '画板 1', itemCount: 2)],
  videos: [RemoteExportVideo(id: 'video-1', name: '样片.mp4')],
  scripts: [
    RemoteExportScript(id: 'script-1', name: '拍摄脚本 1', timelineAvailable: true),
  ],
  defaults: RemoteExportDefaults(
    storyboardFormat: 'png',
    storyboardResolution: 'sourceDetail',
    includeSummaryPage: true,
    analysisReportFormat: 'xlsx',
    includeMultiDimensionAnalysis: true,
    includeShotDetails: true,
  ),
);

RemoteTask _existingExportTask() => _task(
  'export-existing',
  'export',
  status: 'succeeded',
  result: const {
    'exportKind': 'storyboardDocument',
    'artifacts': [
      {
        'id': 'artifact-1',
        'fileName': '画板.png',
        'contentType': 'image/png',
        'size': 128,
        'previewable': true,
        'contentUrl': '/api/v1/exports/artifacts/artifact-1/content',
        'downloadUrl':
            '/api/v1/exports/artifacts/artifact-1/content?download=1',
      },
    ],
  },
);

RemoteVideoGenerationOptions _generationOptions({
  String selectedScriptId = 'script-1',
}) => RemoteVideoGenerationOptions(
  scripts: [
    RemoteVideoGenerationScript(
      id: selectedScriptId,
      name: '竖屏拍摄脚本',
      status: 'active',
      version: 3,
      isSelected: true,
    ),
  ],
  selectedScriptId: selectedScriptId,
  backend: const RemoteVideoGenerationBackend(
    kind: 'libtvCli',
    name: 'LibTV',
    ready: true,
    message: '已连接',
  ),
  projectAspectRatio: '9:16',
  models: const [
    RemoteVideoGenerationModel(id: 'model-h3', name: 'MiniMax H3'),
  ],
  selectedModelId: 'model-h3',
  parameters: const [
    RemoteVideoGenerationParameter(
      key: 'ratio',
      label: '画幅',
      component: 'select',
      group: 'basic',
      value: '9:16',
      options: [
        RemoteVideoGenerationParameterOption(value: '9:16', label: '9:16'),
      ],
      min: null,
      max: null,
      step: null,
    ),
  ],
);

const _generationGroup = RemoteVideoGenerationGroup(
  id: 'group-1',
  scriptId: 'script-1',
  shotIds: ['shot-1'],
  shotNumbers: [1],
  title: '镜头 1',
  durationSeconds: 6,
  prompt: '雨夜追逐',
  promptMode: 'auto',
  canGenerate: true,
  isActive: true,
  referenceImageMediaId: 'reference-media',
);

RemoteVideoGenerationTask _generationTask({
  String id = 'generation-running',
  String status = 'running',
}) => RemoteVideoGenerationTask(
  id: id,
  scriptId: 'script-1',
  shotId: 'group-1',
  shotNumber: 1,
  model: 'model-h3',
  parameters: const {'ratio': '9:16'},
  durationSeconds: 6,
  promptMode: 'auto',
  prompt: '雨夜追逐',
  status: status,
  errorMessage: status == 'failed' ? '远端失败' : '',
  hasLocalResult: status == 'completed',
  mediaId: status == 'completed' ? 'work-media' : null,
  createdAt: null,
  updatedAt: null,
  completedAt: null,
);

extension on RemoteTask {
  Map<String, Object?> toJsonForTest() => {
    'id': id,
    'kind': kind,
    'status': status,
    'progress': {'current': current, 'total': total},
    'message': message,
    'cancellable': cancellable,
    if (result.isNotEmpty) 'result': result,
  };
}

class _FakeEventClient extends RemoteEventClient {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  void add(Map<String, Object?> event) => _events.add(event);

  @override
  Stream<Map<String, Object?>> connect(Uri uri) => _events.stream;

  @override
  Future<void> close() async {}
}

class _FakeRemoteApi implements RemoteApi {
  RemoteStoryboardDetail detail = _detail(revision: 1);
  bool conflictOnUpdate = false;
  int updateRequests = 0;
  int annotationRequests = 0;
  int storyboardDetailRequests = 0;
  bool videoEnabled = false;
  bool generationEnabled = false;
  bool exportEnabled = false;
  bool workflowEnabled = false;
  String generationTaskStatus = 'running';
  int importRequests = 0;
  int analysisRequests = 0;
  int generationOptionsRequests = 0;
  int generationStartRequests = 0;
  int outerCancelRequests = 0;
  int generationCancelRequests = 0;
  int generationRetryRequests = 0;
  int exportOptionsRequests = 0;
  int exportStartRequests = 0;
  int exportCancelRequests = 0;
  int exportRetryRequests = 0;
  int workflowConfirmRequests = 0;
  final List<String> workflowActions = [];
  Map<String, String> lastGenerationParameters = const {};
  List<int> uploadedBytes = const [];

  @override
  Uri get baseUri => Uri.parse('http://localhost:47836');

  @override
  Future<RemoteTask> analyzeVideo(
    String videoId, {
    bool retryFailedOnly = false,
  }) async {
    analysisRequests++;
    return _task('task-analysis', 'videoAnalysis');
  }

  @override
  Future<RemoteVideoDetail> cancelVideo(String videoId) async => _videoDetail;

  @override
  Future<RemoteVideoDetail> removeVideoFrame(
    String videoId,
    String frameId,
  ) async => _videoDetail;

  @override
  Future<RemoteVideoDetail> undoVideoFrameRemoval(String videoId) async =>
      _videoDetail;

  @override
  Future<RemoteVideoDetail> redoVideoFrameRemoval(String videoId) async =>
      _videoDetail;

  @override
  Future<RemoteTask> cancelTask(String taskId) async => (() {
    if (taskId.startsWith('export')) {
      exportCancelRequests++;
      return _task(taskId, 'export', status: 'cancelled');
    }
    outerCancelRequests++;
    return _task(taskId, 'videoGeneration', status: 'cancelled');
  })();

  @override
  Future<RemoteTask> generateVideoStoryboard(String videoId) async =>
      _task('task-storyboard', 'videoStoryboard');

  @override
  Future<RemoteTask> importVideo(String uploadId) async {
    importRequests++;
    return _task('task-import', 'videoImport');
  }

  @override
  Future<RemoteVideoDetail> pauseVideo(String videoId) async => _videoDetail;

  @override
  Future<List<RemoteTask>> tasks() async => [
    if (videoEnabled) _task('task-existing', 'videoAnalysis'),
    if (generationEnabled) _task('outer-existing', 'videoGeneration'),
    if (exportEnabled) _existingExportTask(),
  ];

  @override
  Future<RemoteExportOptions> exportOptions() async {
    exportOptionsRequests++;
    return _exportOptions;
  }

  @override
  Future<RemoteTask> startExport(RemoteExportRequest request) async {
    exportStartRequests++;
    return _task('export-started', 'export');
  }

  @override
  Future<RemoteTask> retryExport(String taskId) async {
    exportRetryRequests++;
    return _task('export-retried', 'export');
  }

  @override
  Future<RemoteVideoUpload> uploadVideo({
    required String fileName,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final collected = <int>[];
    await for (final chunk in bytes) {
      collected.addAll(chunk);
      onProgress?.call(collected.length, size);
    }
    uploadedBytes = collected;
    return RemoteVideoUpload(
      id: 'upload-1',
      fileName: fileName,
      size: size,
      createdAt: null,
    );
  }

  @override
  Future<RemoteVideoDetail> video(String id) async => _videoDetail;

  @override
  Future<List<RemoteVideoSummary>> videos() async =>
      videoEnabled ? [_videoSummary] : const [];

  @override
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  }) async {
    annotationRequests++;
    return detail;
  }

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'session': {'id': 'director', 'clientName': '远端导演', 'role': 'director'},
    'capabilities': {
      'storyboards': true,
      'videoAnalysis': videoEnabled,
      'videoUploads': videoEnabled,
      'videoGeneration': generationEnabled,
      'exports': exportEnabled,
      'shootingWorkflow': workflowEnabled,
      'tasks':
          videoEnabled || generationEnabled || exportEnabled || workflowEnabled,
    },
  };

  @override
  Future<RemoteSettingsSelection> settingsSelection() async =>
      _settingsSelection;

  @override
  Future<RemoteSettingsSelection> updateSettingsSelection({
    String? extractionStrategy,
    String? visionModelId,
    String? imageGenerationModelId,
    String? videoGenerationModelId,
  }) async => _settingsSelection;

  @override
  void close() {}

  @override
  Future<void> logout() async {}

  @override
  Future<RemoteMediaBytes> media(String id) async =>
      RemoteMediaBytes(bytes: Uint8List(0), contentType: 'image/png');

  @override
  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  }) async => const RemotePairResult(session: _director);

  @override
  Future<List<RemoteProjectEntry>> projects() async => const [
    RemoteProjectEntry(
      id: 'project',
      name: '项目 A',
      availability: 'available',
      canOpen: true,
      isActive: true,
      createdAt: null,
      updatedAt: null,
      lastOpenedAt: null,
    ),
  ];

  @override
  Future<Map<String, Object?>> openProject(String id) async => {
    'projectId': id,
    'projectName': '项目 A',
    'alreadyOpen': true,
  };

  @override
  Future<RemoteScriptDetail> script(String id) async => _workflowScript;

  @override
  Future<RemoteShootingWorkflow> shootingWorkflow(String scriptId) =>
      Future.value(_workflow);

  @override
  Future<RemoteShootingWorkflow> confirmShootingWorkflowShots(
    String scriptId,
  ) async {
    workflowConfirmRequests++;
    return _workflow;
  }

  @override
  Future<RemoteTask> startShootingWorkflowAction({
    required String scriptId,
    required String action,
    String? shotId,
  }) async {
    workflowActions.add('$action${shotId == null ? '' : ':$shotId'}');
    final kind = switch (action) {
      'matchAssets' => 'shootingAssetMatch',
      'buildScript' => 'shootingScriptBuild',
      _ => 'storyboardReplication',
    };
    return _task('workflow-${workflowActions.length}', kind);
  }

  @override
  Future<List<RemoteScriptSummary>> scripts() async =>
      workflowEnabled ? const [_workflowScript] : const [];

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) async {
    storyboardDetailRequests++;
    return detail;
  }

  @override
  Future<List<RemoteStoryboardAsset>> storyboardAssets(String id) async =>
      const [];

  @override
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards() async => (
    groups: const <RemoteStoryboardGroup>[],
    items: <RemoteStoryboardSummary>[detail],
  );

  @override
  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) => throw UnimplementedError();

  @override
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async {
    updateRequests++;
    if (conflictOnUpdate) {
      throw const RemoteApiFailure(
        statusCode: 409,
        code: 'revision_conflict',
        message: '故事板已更新',
        details: {'currentRevision': 2},
      );
    }
    return detail;
  }

  @override
  Future<RemoteStoryboardDetail> updateStoryboardLayout({
    required String storyboardId,
    required int expectedRevision,
    required String action,
    required String assetId,
    int? slotIndex,
  }) async => detail;

  @override
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async {
    annotationRequests++;
    return detail;
  }

  @override
  Future<RemoteVideoGenerationTask> cancelVideoGenerationTask(String taskId) =>
      Future.value(() {
        generationCancelRequests++;
        return _generationTask(id: taskId, status: 'canceled');
      }());

  @override
  Future<RemoteTask> retryVideoGenerationTask(String taskId) =>
      Future.value(() {
        generationRetryRequests++;
        return _task('outer-retry', 'videoGeneration');
      }());

  @override
  Future<
    ({
      RemoteVideoGenerationOptions options,
      List<RemoteVideoGenerationGroup> groups,
    })
  >
  selectVideoGenerationScript(String scriptId) async => (
    options: _generationOptions(selectedScriptId: scriptId),
    groups: const [_generationGroup],
  );

  @override
  Future<RemoteTask> startVideoGeneration({
    required String scriptId,
    required List<String> shotIds,
    required String model,
    required Map<String, String> parameters,
    required Map<String, RemoteVideoGenerationShotOverride> shotOverrides,
  }) async {
    generationStartRequests++;
    lastGenerationParameters = parameters;
    return _task('outer-started', 'videoGeneration');
  }

  @override
  Future<List<RemoteVideoGenerationGroup>> videoGenerationGroups() =>
      Future.value(generationEnabled ? const [_generationGroup] : const []);

  @override
  Future<RemoteVideoGenerationOptions> videoGenerationOptions() async {
    generationOptionsRequests++;
    return _generationOptions();
  }

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationTasks() =>
      Future.value(
        generationEnabled
            ? [_generationTask(status: generationTaskStatus)]
            : const [],
      );

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationWorks() =>
      Future.value(
        generationEnabled
            ? [_generationTask(id: 'generation-work', status: 'completed')]
            : const [],
      );

  @override
  Future<String> webSocketTicket() async => 'ticket';

  @override
  Future<RemoteWorkspace> workspace() async => const RemoteWorkspace(
    phase: 'editor',
    project: RemoteProject(
      id: 'project',
      name: '项目 A',
      storyboardCount: 1,
      scriptCount: 0,
      shotCount: 0,
    ),
  );
}

const _settingsSelection = RemoteSettingsSelection(
  extractionStrategies: [
    RemoteSettingsOption(
      id: 'sceneAndInterval',
      name: '场景变化 + 间隔补帧',
      detail: '场景切换优先',
    ),
  ],
  selectedExtractionStrategy: 'sceneAndInterval',
  visionModels: [],
  selectedVisionModelId: '',
  imageGenerationModels: [],
  selectedImageGenerationModelId: '',
  videoGenerationModels: [],
  selectedVideoGenerationModelId: '',
);

const _workflowScript = RemoteScriptDetail(
  id: 'script-workflow',
  name: '工作流脚本',
  status: 'active',
  version: 1,
  shotCount: 1,
  updatedAt: null,
  shots: [],
);

const _workflow = RemoteShootingWorkflow(
  scriptId: 'script-workflow',
  currentStep: 'prepareAssets',
  confirmShotsStatus: 'pending',
  prepareAssetsStatus: 'pending',
  composePromptsStatus: 'pending',
  shotCount: 1,
  confirmedShotCount: 1,
  promptCount: 1,
  analysisCompleted: 0,
  analysisFailed: 0,
  analysisTotal: 1,
  isBusy: false,
  message: '',
  errorMessage: '',
  assets: [],
  links: [],
  replicas: [],
);
