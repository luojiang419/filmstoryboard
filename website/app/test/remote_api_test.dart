import 'dart:convert';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:filmstoryboard_remote_web/core/models/remote_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('配对请求使用同源 API 并解析 HttpOnly 会话响应', () async {
    late http.Request captured;
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'session': {
              'id': 'session-1',
              'clientName': '导演平板',
              'role': 'director',
              'expiresAt': '2026-08-11T00:00:00Z',
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.pair(code: '123456', clientName: '导演平板');

    expect(captured.url.path, '/api/v1/auth/pair');
    expect(captured.method, 'POST');
    expect(jsonDecode(captured.body)['code'], '123456');
    expect(result.session.role, 'director');
  });

  test('409 响应保留 revision_conflict 和当前版本', () async {
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {
                'code': 'revision_conflict',
                'message': '拍摄脚本已在其他位置更新',
                'details': {'currentVersion': 8},
              },
            }),
          ),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    expect(
      () => api.updateShot(
        scriptId: 'script',
        shotId: 'shot',
        expectedVersion: 7,
        changes: const {'content': '新内容'},
      ),
      throwsA(
        isA<RemoteApiFailure>()
            .having((error) => error.code, 'code', 'revision_conflict')
            .having(
              (error) => error.details['currentVersion'],
              'currentVersion',
              8,
            ),
      ),
    );
  });

  test('设置 API 只发送选择 ID 并只解析安全模型摘要', () async {
    late http.Request captured;
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'extractionStrategies': [
              {
                'id': 'sceneAndInterval',
                'name': '场景变化 + 间隔补帧',
                'detail': '场景切换优先',
              },
            ],
            'selectedExtractionStrategy': 'sceneAndInterval',
            'visionModels': [
              {'id': 'vision-1', 'name': '视觉 A', 'detail': 'model-a'},
            ],
            'selectedVisionModelId': 'vision-1',
            'imageGenerationModels': const [],
            'selectedImageGenerationModelId': '',
            'videoGenerationModels': const [],
            'selectedVideoGenerationModelId': '',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.updateSettingsSelection(visionModelId: 'vision-1');

    expect(captured.method, 'PATCH');
    expect(captured.url.path, '/api/v1/settings/selection');
    expect(jsonDecode(captured.body), {'visionModelId': 'vision-1'});
    expect(captured.body, isNot(contains('apiKey')));
    expect(captured.body, isNot(contains('baseUrl')));
    expect(captured.body, isNot(contains('path')));
    expect(result.visionModels.single.name, '视觉 A');
  });

  test('候选帧移除与撤销只发送视频和帧资源 ID', () async {
    final requests = <http.Request>[];
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'video-1',
            'fileName': '样片.mp4',
            'analysisState': {
              'canUndoFrameRemoval': true,
              'canRedoFrameRemoval': false,
              'progress': {'current': 0, 'total': 0},
            },
            'frames': const [],
            'shots': const [],
            'marketingAnalyses': const [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final removed = await api.removeVideoFrame('video-1', 'frame-1');
    await api.undoVideoFrameRemoval('video-1');
    await api.redoVideoFrameRemoval('video-1');

    expect(requests[0].method, 'DELETE');
    expect(requests[0].url.path, '/api/v1/videos/video-1/frames/frame-1');
    expect(requests[1].url.path, '/api/v1/videos/video-1/frames/undo');
    expect(requests[2].url.path, '/api/v1/videos/video-1/frames/redo');
    expect(requests.every((request) => request.url.query.isEmpty), isTrue);
    expect(removed.analysisState.canUndoFrameRemoval, isTrue);
  });

  test('故事板编辑使用修订号并解析安全媒体投影', () async {
    final requests = <http.Request>[];
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/assets')) {
          return http.Response(
            jsonEncode({
              'boardId': 'board-1',
              'revision': 6,
              'items': [
                {
                  'id': 'asset-2',
                  'sourceName': '候选帧',
                  'indexNo': 2,
                  'used': false,
                  'imageMediaId': 'asset-media-safe-id',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'board-1',
            'name': '导演审阅版',
            'revision': 6,
            'locked': false,
            'rows': 1,
            'columns': 1,
            'itemCount': 1,
            'annotationCount': 0,
            'unresolvedAnnotationCount': 0,
            'width': 1920,
            'height': 1080,
            'gap': 18,
            'storyDescriptionEnabled': true,
            'rowDescriptionEnabled': false,
            'rowCaptions': [''],
            'rowDividerEnabled': true,
            'rowDividerStyle': 'dashed',
            'rowDividerOpacity': .35,
            'titleAlignment': 'center',
            'portraitMode': false,
            'items': [
              {
                'assetId': 'asset-1',
                'sourceName': '焦点帧',
                'indexNo': 1,
                'caption': '新的描述',
                'slotIndex': 0,
                'imageMediaId': 'media-safe-id',
              },
            ],
            'annotations': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final detail = await api.updateStoryboard(
      storyboardId: 'board-1',
      expectedRevision: 5,
      changes: const {
        'itemCaptions': {'asset-1': '新的描述'},
      },
    );
    final assets = await api.storyboardAssets('board-1');
    await api.updateStoryboardLayout(
      storyboardId: 'board-1',
      expectedRevision: 6,
      action: 'add',
      assetId: 'asset-2',
      slotIndex: 0,
    );

    expect(requests[0].method, 'PATCH');
    expect(requests[0].url.path, '/api/v1/storyboards/board-1');
    expect(jsonDecode(requests[0].body)['expectedRevision'], 5);
    expect(requests[1].url.path, '/api/v1/storyboards/board-1/assets');
    expect(assets.single.imageMediaId, 'asset-media-safe-id');
    expect(requests[2].url.path, '/api/v1/storyboards/board-1/layout');
    expect(jsonDecode(requests[2].body), {
      'expectedRevision': 6,
      'action': 'add',
      'assetId': 'asset-2',
      'slotIndex': 0,
    });
    expect(detail.revision, 6);
    expect(detail.items.single.imageMediaId, 'media-safe-id');
  });

  test('拍摄脚本三步工作流只发送脚本、镜头和动作 ID', () async {
    final requests = <http.Request>[];
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/actions')) {
          return http.Response(
            jsonEncode({
              'id': 'task-workflow',
              'kind': 'storyboardReplication',
              'status': 'queued',
              'progress': {'current': 0, 'total': 0},
              'message': '等待本机处理',
              'cancellable': false,
            }),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'scriptId': 'script-1',
            'currentStep': 'prepareAssets',
            'statuses': {
              'confirmShots': 'pending',
              'prepareAssets': 'pending',
              'composePrompts': 'pending',
            },
            'shotCount': 1,
            'confirmedShotCount': 1,
            'promptCount': 0,
            'analysisProgress': {'completed': 0, 'failed': 0, 'total': 1},
            'isBusy': false,
            'message': '',
            'errorMessage': '',
            'assets': [
              {
                'id': 'asset-1',
                'name': '角色参考',
                'type': 'character',
                'description': '主角',
                'referenceNumber': 1,
                'mediaId': 'safe-asset-media',
              },
            ],
            'links': [],
            'replicas': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final workflow = await api.shootingWorkflow('script-1');
    await api.confirmShootingWorkflowShots('script-1');
    final task = await api.startShootingWorkflowAction(
      scriptId: 'script-1',
      action: 'replicateStoryboards',
      shotId: 'shot-1',
    );

    expect(requests[0].method, 'GET');
    expect(requests[1].method, 'POST');
    expect(requests[2].url.path, '/api/v1/scripts/script-1/workflow/actions');
    expect(jsonDecode(requests[2].body), {
      'action': 'replicateStoryboards',
      'shotId': 'shot-1',
    });
    expect(workflow.assets.single.mediaId, 'safe-asset-media');
    expect(task.kind, 'storyboardReplication');
  });

  test('视频使用八位流上传并解析视频、候选帧与任务 DTO', () async {
    final requests = <http.Request>[];
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/uploads/videos') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 'upload-1',
                'fileName': '竖屏样片.mp4',
                'size': 5,
                'createdAt': '2026-08-12T00:00:00Z',
              }),
            ),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/api/v1/videos/video-1') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 'video-1',
                'fileName': '竖屏样片.mp4',
                'durationMs': 5000,
                'frameRate': 25,
                'width': 1920,
                'height': 1080,
                'displayWidth': 1080,
                'displayHeight': 1920,
                'rotationDegrees': 90,
                'hasAudio': true,
                'frameCount': 1,
                'successfulFrames': 1,
                'failedFrames': 0,
                'status': 'pending',
                'mediaUrl': '/api/v1/media/video-media/content',
                'analysisState': {
                  'isAnalyzing': false,
                  'isPaused': false,
                  'progress': {'current': 0, 'total': 1},
                  'message': '',
                  'errorMessage': '',
                },
                'frames': [
                  {
                    'id': 'frame-1',
                    'index': 0,
                    'timestampMs': 1000,
                    'width': 1080,
                    'height': 1920,
                    'sharpness': 88,
                    'brightness': .5,
                    'motionScore': .1,
                    'isFocus': true,
                    'status': 'completed',
                    'mediaUrl': '/api/v1/media/frame-media/content',
                    'analysis': {
                      'id': 'analysis-1',
                      'sequenceNo': 1,
                      'dimensions': {'场景': '工作室'},
                      'status': 'completed',
                    },
                  },
                ],
                'shots': [],
                'marketingAnalyses': [],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        throw StateError('未预期请求：${request.url.path}');
      }),
    );
    final progress = <int>[];

    final upload = await api.uploadVideo(
      fileName: '竖屏样片.mp4',
      size: 5,
      bytes: Stream.fromIterable(const [
        [1, 2],
        [3, 4, 5],
      ]),
      onProgress: (sent, _) => progress.add(sent),
    );
    final detail = await api.video('video-1');

    expect(upload.id, 'upload-1');
    expect(
      requests.first.headers['x-file-name'],
      Uri.encodeComponent('竖屏样片.mp4'),
    );
    expect(requests.first.bodyBytes, const [1, 2, 3, 4, 5]);
    expect(progress, const [2, 5]);
    expect(detail.video.isPortrait, isTrue);
    expect(detail.video.mediaId, 'video-media');
    expect(detail.frames.single.mediaId, 'frame-media');
    expect(detail.frames.single.analysis?.dimensions['场景'], '工作室');
  });

  test('视频生成 API 使用本机安全 DTO 并保留动态参数', () async {
    final requests = <http.Request>[];
    http.Response jsonResponse(Object body, [int status = 200]) =>
        http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
    final optionsJson = {
      'scripts': [
        {
          'id': 'script-1',
          'name': '竖屏拍摄脚本',
          'status': 'active',
          'version': 3,
          'isSelected': true,
        },
      ],
      'selectedScriptId': 'script-1',
      'backend': {
        'kind': 'libtvCli',
        'name': 'LibTV',
        'ready': true,
        'message': '已连接',
      },
      'projectAspectRatio': '9:16',
      'models': [
        {'id': 'model-h3', 'name': 'MiniMax H3'},
      ],
      'selectedModelId': 'model-h3',
      'parameters': [
        {
          'key': 'duration',
          'label': '时长',
          'component': 'select',
          'group': 'basic',
          'value': '6',
          'options': [
            {'value': '6', 'label': '6 秒'},
          ],
          'min': 1,
          'max': 10,
          'step': 1,
        },
      ],
    };
    final groupJson = {
      'id': 'group-1',
      'scriptId': 'script-1',
      'shotIds': ['shot-1', 'shot-2'],
      'shotNumbers': [1, 2],
      'title': '镜头 1–2',
      'durationSeconds': 6,
      'prompt': '雨夜追逐',
      'promptMode': 'auto',
      'canGenerate': true,
      'isActive': true,
      'referenceImageUrl': '/api/v1/media/reference-safe/content',
    };
    final generationJson = {
      'id': 'generation-1',
      'scriptId': 'script-1',
      'shotId': 'group-1',
      'shotNumber': 1,
      'model': 'model-h3',
      'parameters': {'duration': '6'},
      'durationSeconds': 6,
      'promptMode': 'edited',
      'prompt': 'Web 提示词',
      'status': 'completed',
      'errorMessage': '',
      'hasLocalResult': true,
      'mediaUrl': '/api/v1/media/work-safe/content',
      'createdAt': '2026-08-12T00:00:00Z',
      'updatedAt': '2026-08-12T00:01:00Z',
      'completedAt': '2026-08-12T00:01:00Z',
    };
    final outerTaskJson = {
      'id': 'outer-1',
      'kind': 'videoGeneration',
      'status': 'running',
      'progress': {'current': 0, 'total': 1},
      'message': '等待本机生成视频',
      'cancellable': true,
      'createdAt': '2026-08-12T00:00:00Z',
      'updatedAt': '2026-08-12T00:00:00Z',
    };
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/api/v1/video-generation/options') {
          return jsonResponse(optionsJson);
        }
        if (path == '/api/v1/video-generation/groups') {
          return jsonResponse({
            'items': [groupJson],
          });
        }
        if (path == '/api/v1/video-generation/selection') {
          return jsonResponse({
            'options': optionsJson,
            'groups': [groupJson],
          });
        }
        if (path == '/api/v1/video-generation/tasks' &&
            request.method == 'GET') {
          return jsonResponse({
            'items': [generationJson],
          });
        }
        if (path == '/api/v1/video-generation/tasks' &&
            request.method == 'POST') {
          return jsonResponse(outerTaskJson, 202);
        }
        if (path.endsWith('/cancel')) return jsonResponse(generationJson);
        if (path.endsWith('/retry')) return jsonResponse(outerTaskJson, 202);
        if (path == '/api/v1/video-generation/works') {
          return jsonResponse({
            'items': [generationJson],
          });
        }
        throw StateError('未预期请求：$path');
      }),
    );

    final options = await api.videoGenerationOptions();
    final groups = await api.videoGenerationGroups();
    final selection = await api.selectVideoGenerationScript('script-1');
    final tasks = await api.videoGenerationTasks();
    final started = await api.startVideoGeneration(
      scriptId: 'script-1',
      shotIds: const ['group-1'],
      model: 'model-h3',
      parameters: const {'duration': '6'},
      shotOverrides: const {
        'group-1': RemoteVideoGenerationShotOverride(
          prompt: 'Web 提示词',
          promptMode: 'edited',
          durationSeconds: 6,
        ),
      },
    );
    final cancelled = await api.cancelVideoGenerationTask('generation-1');
    final retried = await api.retryVideoGenerationTask('generation-1');
    final works = await api.videoGenerationWorks();

    expect(options.backend.name, 'LibTV');
    expect(options.parameters.single.options.single.label, '6 秒');
    expect(groups.single.referenceImageMediaId, 'reference-safe');
    expect(selection.options.projectAspectRatio, '9:16');
    expect(tasks.single.parameters['duration'], '6');
    expect(started.kind, 'videoGeneration');
    expect(cancelled.mediaId, 'work-safe');
    expect(retried.id, 'outer-1');
    expect(works.single.hasLocalResult, isTrue);
    final startRequest = requests.firstWhere(
      (request) =>
          request.url.path == '/api/v1/video-generation/tasks' &&
          request.method == 'POST',
    );
    final body = jsonDecode(startRequest.body) as Map<String, Object?>;
    expect(body['model'], 'model-h3');
    expect(body['shotOverrides'], isA<Map<String, Object?>>());
    expect(startRequest.body, isNot(contains('apiKey')));
    expect(startRequest.body, isNot(contains(r'G:\\')));
  });

  test('导出 API 只发送资源 ID 和白名单选项并过滤非同源产物 URL', () async {
    final requests = <http.Request>[];
    Map<String, Object?> taskJson(String id) => {
      'id': id,
      'kind': 'export',
      'status': 'succeeded',
      'progress': {'current': 1, 'total': 1},
      'message': '已完成',
      'cancellable': false,
      'result': {
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
          {
            'id': 'artifact-unsafe',
            'fileName': '不安全.png',
            'contentType': 'image/png',
            'size': 1,
            'previewable': true,
            'contentUrl': 'https://evil.example/file',
            'downloadUrl': r'file:///C:/secret.txt',
          },
        ],
      },
    };
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/v1/exports/options') {
          return http.Response(
            jsonEncode({
              'storyboardFormats': ['png', 'jpg', 'pdf'],
              'storyboardResolutions': ['standard', 'sourceDetail'],
              'analysisReportFormats': ['xlsx', 'pdf', 'png', 'jpg'],
              'boards': [
                {'id': 'board-1', 'name': '画板 1', 'itemCount': 2},
              ],
              'videos': [
                {'id': 'video-1', 'name': '样片.mp4'},
              ],
              'scripts': [
                {'id': 'script-1', 'name': '脚本 1', 'timelineAvailable': true},
              ],
              'defaults': {
                'storyboardFormat': 'png',
                'storyboardResolution': 'sourceDetail',
                'includeSummaryPage': true,
                'analysisReportFormat': 'xlsx',
                'includeMultiDimensionAnalysis': true,
                'includeShotDetails': true,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(taskJson('export-task')),
          202,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final options = await api.exportOptions();
    final task = await api.startExport(
      const RemoteExportRequest(
        kind: 'storyboardDocument',
        boardIds: ['board-1'],
        format: 'png',
        resolution: 'sourceDetail',
        includeSummaryPage: true,
      ),
    );
    await api.retryExport('failed-task');

    expect(options.boards.single.name, '画板 1');
    expect(task.exportArtifacts.first.downloadUrl, endsWith('download=1'));
    expect(task.exportArtifacts.last.contentUrl, isEmpty);
    expect(task.exportArtifacts.last.downloadUrl, isEmpty);
    final start = requests.firstWhere(
      (request) =>
          request.url.path == '/api/v1/exports/tasks' &&
          request.method == 'POST',
    );
    final body = jsonDecode(start.body) as Map<String, Object?>;
    expect(body['boardIds'], ['board-1']);
    expect(body['format'], 'png');
    expect(start.body, isNot(contains('outputPath')));
    expect(start.body, isNot(contains('apiKey')));
    expect(start.body, isNot(contains(r'G:\\')));
    expect(requests.last.url.path, '/api/v1/exports/tasks/failed-task/retry');
  });
}
