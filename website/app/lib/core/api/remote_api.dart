import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/remote_models.dart';

abstract interface class RemoteApi {
  Uri get baseUri;

  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  });

  Future<Map<String, Object?>> capabilities();
  Future<RemoteSettingsSelection> settingsSelection();
  Future<RemoteSettingsSelection> updateSettingsSelection({
    String? extractionStrategy,
    String? visionModelId,
    String? imageGenerationModelId,
    String? videoGenerationModelId,
  });
  Future<List<RemoteProjectEntry>> projects();
  Future<Map<String, Object?>> openProject(String id);
  Future<RemoteWorkspace> workspace();
  Future<List<RemoteVideoSummary>> videos();
  Future<RemoteVideoDetail> video(String id);
  Future<RemoteVideoUpload> uploadVideo({
    required String fileName,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent, int total)? onProgress,
  });
  Future<RemoteTask> importVideo(String uploadId);
  Future<RemoteTask> analyzeVideo(
    String videoId, {
    bool retryFailedOnly = false,
  });
  Future<RemoteVideoDetail> pauseVideo(String videoId);
  Future<RemoteVideoDetail> cancelVideo(String videoId);
  Future<RemoteVideoDetail> removeVideoFrame(String videoId, String frameId);
  Future<RemoteVideoDetail> undoVideoFrameRemoval(String videoId);
  Future<RemoteVideoDetail> redoVideoFrameRemoval(String videoId);
  Future<RemoteTask> generateVideoStoryboard(String videoId);
  Future<List<RemoteTask>> tasks();
  Future<RemoteTask> cancelTask(String taskId);
  Future<RemoteExportOptions> exportOptions();
  Future<RemoteTask> startExport(RemoteExportRequest request);
  Future<RemoteTask> retryExport(String taskId);
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards();
  Future<RemoteStoryboardDetail> storyboard(String id);
  Future<List<RemoteStoryboardAsset>> storyboardAssets(String id);
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  });
  Future<RemoteStoryboardDetail> updateStoryboardLayout({
    required String storyboardId,
    required int expectedRevision,
    required String action,
    required String assetId,
    int? slotIndex,
  });
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  });
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  });
  Future<List<RemoteScriptSummary>> scripts();
  Future<RemoteScriptDetail> script(String id);
  Future<RemoteShootingWorkflow> shootingWorkflow(String scriptId);
  Future<RemoteShootingWorkflow> confirmShootingWorkflowShots(String scriptId);
  Future<RemoteTask> startShootingWorkflowAction({
    required String scriptId,
    required String action,
    String? shotId,
  });

  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  });
  Future<RemoteVideoGenerationOptions> videoGenerationOptions();
  Future<List<RemoteVideoGenerationGroup>> videoGenerationGroups();
  Future<
    ({
      RemoteVideoGenerationOptions options,
      List<RemoteVideoGenerationGroup> groups,
    })
  >
  selectVideoGenerationScript(String scriptId);
  Future<List<RemoteVideoGenerationTask>> videoGenerationTasks();
  Future<RemoteTask> startVideoGeneration({
    required String scriptId,
    required List<String> shotIds,
    required String model,
    required Map<String, String> parameters,
    required Map<String, RemoteVideoGenerationShotOverride> shotOverrides,
  });
  Future<RemoteVideoGenerationTask> cancelVideoGenerationTask(String taskId);
  Future<RemoteTask> retryVideoGenerationTask(String taskId);
  Future<List<RemoteVideoGenerationTask>> videoGenerationWorks();

  Future<String> webSocketTicket();
  Future<RemoteMediaBytes> media(String id);
  Future<void> logout();
  void close();
}

class RemoteApiFailure implements Exception {
  const RemoteApiFailure({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const {},
  });

  final int statusCode;
  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => message;
}

class HttpRemoteApi implements RemoteApi {
  HttpRemoteApi({Uri? baseUri, http.Client? client})
    : baseUri = baseUri ?? Uri.parse(Uri.base.origin),
      _client = client ?? http.Client();

  @override
  final Uri baseUri;
  final http.Client _client;

  @override
  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  }) async => RemotePairResult.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/auth/pair',
      body: {'code': code, 'clientName': clientName},
    ),
  );

  @override
  Future<Map<String, Object?>> capabilities() =>
      _jsonRequest('GET', '/api/v1/capabilities');

  @override
  Future<RemoteSettingsSelection> settingsSelection() async =>
      RemoteSettingsSelection.fromJson(
        await _jsonRequest('GET', '/api/v1/settings/selection'),
      );

  @override
  Future<RemoteSettingsSelection> updateSettingsSelection({
    String? extractionStrategy,
    String? visionModelId,
    String? imageGenerationModelId,
    String? videoGenerationModelId,
  }) async => RemoteSettingsSelection.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/settings/selection',
      body: {
        'extractionStrategy': ?extractionStrategy,
        'visionModelId': ?visionModelId,
        'imageGenerationModelId': ?imageGenerationModelId,
        'videoGenerationModelId': ?videoGenerationModelId,
      },
    ),
  );

  @override
  Future<List<RemoteProjectEntry>> projects() async {
    final json = await _jsonRequest('GET', '/api/v1/projects');
    return _list(json['items'])
        .map((item) => RemoteProjectEntry.fromJson(_map(item)))
        .toList(growable: false);
  }

  @override
  Future<Map<String, Object?>> openProject(String id) =>
      _jsonRequest('POST', '/api/v1/projects/${Uri.encodeComponent(id)}/open');

  @override
  Future<RemoteWorkspace> workspace() async =>
      RemoteWorkspace.fromJson(await _jsonRequest('GET', '/api/v1/workspace'));

  @override
  Future<List<RemoteVideoSummary>> videos() async {
    final json = await _jsonRequest('GET', '/api/v1/videos');
    return _list(json['items'])
        .map((item) => RemoteVideoSummary.fromJson(_map(item)))
        .toList(growable: false);
  }

  @override
  Future<RemoteVideoDetail> video(String id) async =>
      RemoteVideoDetail.fromJson(
        await _jsonRequest('GET', '/api/v1/videos/${Uri.encodeComponent(id)}'),
      );

  @override
  Future<RemoteVideoUpload> uploadVideo({
    required String fileName,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final request =
        http.StreamedRequest('POST', _resolve('/api/v1/uploads/videos'))
          ..headers['Content-Type'] = 'application/octet-stream'
          ..headers['X-File-Name'] = Uri.encodeComponent(fileName)
          ..contentLength = size;
    final responseFuture = _client.send(request);
    var sent = 0;
    await request.sink.addStream(
      bytes.map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, size);
        return chunk;
      }),
    );
    await request.sink.close();
    final response = await http.Response.fromStream(await responseFuture);
    _throwIfFailed(response);
    return RemoteVideoUpload.fromJson(
      _map(jsonDecode(utf8.decode(response.bodyBytes))),
    );
  }

  @override
  Future<RemoteTask> importVideo(String uploadId) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/videos/import',
      body: {'uploadId': uploadId},
    ),
  );

  @override
  Future<RemoteTask> analyzeVideo(
    String videoId, {
    bool retryFailedOnly = false,
  }) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/videos/${Uri.encodeComponent(videoId)}/analyze',
      body: {'retryFailedOnly': retryFailedOnly},
    ),
  );

  @override
  Future<RemoteVideoDetail> pauseVideo(String videoId) async =>
      RemoteVideoDetail.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/videos/${Uri.encodeComponent(videoId)}/pause',
          body: const {},
        ),
      );

  @override
  Future<RemoteVideoDetail> removeVideoFrame(
    String videoId,
    String frameId,
  ) async => RemoteVideoDetail.fromJson(
    await _jsonRequest(
      'DELETE',
      '/api/v1/videos/${Uri.encodeComponent(videoId)}/frames/${Uri.encodeComponent(frameId)}',
    ),
  );

  @override
  Future<RemoteVideoDetail> undoVideoFrameRemoval(String videoId) async =>
      RemoteVideoDetail.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/videos/${Uri.encodeComponent(videoId)}/frames/undo',
          body: const {},
        ),
      );

  @override
  Future<RemoteVideoDetail> redoVideoFrameRemoval(String videoId) async =>
      RemoteVideoDetail.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/videos/${Uri.encodeComponent(videoId)}/frames/redo',
          body: const {},
        ),
      );

  @override
  Future<RemoteVideoDetail> cancelVideo(String videoId) async =>
      RemoteVideoDetail.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/videos/${Uri.encodeComponent(videoId)}/cancel',
          body: const {},
        ),
      );

  @override
  Future<RemoteTask> generateVideoStoryboard(String videoId) async =>
      RemoteTask.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/videos/${Uri.encodeComponent(videoId)}/storyboard',
          body: const {},
        ),
      );

  @override
  Future<List<RemoteTask>> tasks() async {
    final json = await _jsonRequest('GET', '/api/v1/tasks');
    return _list(
      json['items'],
    ).map((item) => RemoteTask.fromJson(_map(item))).toList(growable: false);
  }

  @override
  Future<RemoteTask> cancelTask(String taskId) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/tasks/${Uri.encodeComponent(taskId)}/cancel',
      body: const {},
    ),
  );

  @override
  Future<RemoteExportOptions> exportOptions() async =>
      RemoteExportOptions.fromJson(
        await _jsonRequest('GET', '/api/v1/exports/options'),
      );

  @override
  Future<RemoteTask> startExport(RemoteExportRequest request) async =>
      RemoteTask.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/exports/tasks',
          body: request.toJson(),
        ),
      );

  @override
  Future<RemoteTask> retryExport(String taskId) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/exports/tasks/${Uri.encodeComponent(taskId)}/retry',
      body: const {},
    ),
  );

  @override
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards() async {
    final json = await _jsonRequest('GET', '/api/v1/storyboards');
    return (
      groups: _list(json['groups'])
          .map((item) => RemoteStoryboardGroup.fromJson(_map(item)))
          .toList(growable: false),
      items: _list(json['items'])
          .map((item) => RemoteStoryboardSummary.fromJson(_map(item)))
          .toList(growable: false),
    );
  }

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) async =>
      RemoteStoryboardDetail.fromJson(
        await _jsonRequest(
          'GET',
          '/api/v1/storyboards/${Uri.encodeComponent(id)}',
        ),
      );

  @override
  Future<List<RemoteStoryboardAsset>> storyboardAssets(String id) async {
    final json = await _jsonRequest(
      'GET',
      '/api/v1/storyboards/${Uri.encodeComponent(id)}/assets',
    );
    return _list(json['items'])
        .map((item) => RemoteStoryboardAsset.fromJson(_map(item)))
        .toList(growable: false);
  }

  @override
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}',
      body: {'expectedRevision': expectedRevision, 'changes': changes},
    ),
  );

  @override
  Future<RemoteStoryboardDetail> updateStoryboardLayout({
    required String storyboardId,
    required int expectedRevision,
    required String action,
    required String assetId,
    int? slotIndex,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}/layout',
      body: {
        'expectedRevision': expectedRevision,
        'action': action,
        'assetId': assetId,
        'slotIndex': ?slotIndex,
      },
    ),
  );

  @override
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}/annotations',
      body: {
        'expectedRevision': expectedRevision,
        'body': body,
        'assetId': ?assetId,
      },
    ),
  );

  @override
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async => RemoteStoryboardDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/storyboards/${Uri.encodeComponent(storyboardId)}/annotations/${Uri.encodeComponent(annotationId)}',
      body: {'expectedRevision': expectedRevision, 'changes': changes},
    ),
  );

  @override
  Future<List<RemoteScriptSummary>> scripts() async {
    final json = await _jsonRequest('GET', '/api/v1/scripts');
    final items = json['items'];
    return items is List
        ? items
              .map((item) => RemoteScriptSummary.fromJson(_map(item)))
              .toList(growable: false)
        : const [];
  }

  @override
  Future<RemoteScriptDetail> script(String id) async =>
      RemoteScriptDetail.fromJson(
        await _jsonRequest('GET', '/api/v1/scripts/${Uri.encodeComponent(id)}'),
      );

  @override
  Future<RemoteShootingWorkflow> shootingWorkflow(String scriptId) async =>
      RemoteShootingWorkflow.fromJson(
        await _jsonRequest(
          'GET',
          '/api/v1/scripts/${Uri.encodeComponent(scriptId)}/workflow',
        ),
      );

  @override
  Future<RemoteShootingWorkflow> confirmShootingWorkflowShots(
    String scriptId,
  ) async => RemoteShootingWorkflow.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/scripts/${Uri.encodeComponent(scriptId)}/workflow',
      body: const {},
    ),
  );

  @override
  Future<RemoteTask> startShootingWorkflowAction({
    required String scriptId,
    required String action,
    String? shotId,
  }) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/scripts/${Uri.encodeComponent(scriptId)}/workflow/actions',
      body: {'action': action, 'shotId': ?shotId},
    ),
  );

  @override
  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) async => RemoteScriptDetail.fromJson(
    await _jsonRequest(
      'PATCH',
      '/api/v1/scripts/${Uri.encodeComponent(scriptId)}/shots/${Uri.encodeComponent(shotId)}',
      body: {'expectedVersion': expectedVersion, 'changes': changes},
    ),
  );

  @override
  Future<RemoteVideoGenerationOptions> videoGenerationOptions() async =>
      RemoteVideoGenerationOptions.fromJson(
        await _jsonRequest('GET', '/api/v1/video-generation/options'),
      );

  @override
  Future<List<RemoteVideoGenerationGroup>> videoGenerationGroups() async {
    final json = await _jsonRequest('GET', '/api/v1/video-generation/groups');
    return _list(json['items'])
        .map((item) => RemoteVideoGenerationGroup.fromJson(_map(item)))
        .toList(growable: false);
  }

  @override
  Future<
    ({
      RemoteVideoGenerationOptions options,
      List<RemoteVideoGenerationGroup> groups,
    })
  >
  selectVideoGenerationScript(String scriptId) async {
    final json = await _jsonRequest(
      'POST',
      '/api/v1/video-generation/selection',
      body: {'scriptId': scriptId},
    );
    return (
      options: RemoteVideoGenerationOptions.fromJson(_map(json['options'])),
      groups: _list(json['groups'])
          .map((item) => RemoteVideoGenerationGroup.fromJson(_map(item)))
          .toList(growable: false),
    );
  }

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationTasks() =>
      _videoGenerationTaskCollection('/api/v1/video-generation/tasks');

  @override
  Future<RemoteTask> startVideoGeneration({
    required String scriptId,
    required List<String> shotIds,
    required String model,
    required Map<String, String> parameters,
    required Map<String, RemoteVideoGenerationShotOverride> shotOverrides,
  }) async => RemoteTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/video-generation/tasks',
      body: {
        'scriptId': scriptId,
        'shotIds': shotIds,
        'model': model,
        'parameters': parameters,
        'shotOverrides': shotOverrides.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      },
    ),
  );

  @override
  Future<RemoteVideoGenerationTask> cancelVideoGenerationTask(
    String taskId,
  ) async => RemoteVideoGenerationTask.fromJson(
    await _jsonRequest(
      'POST',
      '/api/v1/video-generation/tasks/${Uri.encodeComponent(taskId)}/cancel',
      body: const {},
    ),
  );

  @override
  Future<RemoteTask> retryVideoGenerationTask(String taskId) async =>
      RemoteTask.fromJson(
        await _jsonRequest(
          'POST',
          '/api/v1/video-generation/tasks/${Uri.encodeComponent(taskId)}/retry',
          body: const {},
        ),
      );

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationWorks() =>
      _videoGenerationTaskCollection('/api/v1/video-generation/works');

  Future<List<RemoteVideoGenerationTask>> _videoGenerationTaskCollection(
    String path,
  ) async {
    final json = await _jsonRequest('GET', path);
    return _list(json['items'])
        .map((item) => RemoteVideoGenerationTask.fromJson(_map(item)))
        .toList(growable: false);
  }

  @override
  Future<String> webSocketTicket() async {
    final json = await _jsonRequest('POST', '/api/v1/auth/ws-ticket');
    return '${json['ticket'] ?? ''}';
  }

  @override
  Future<RemoteMediaBytes> media(String id) async {
    final response = await _client.get(
      _resolve('/api/v1/media/${Uri.encodeComponent(id)}/content'),
    );
    _throwIfFailed(response);
    return RemoteMediaBytes(
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  @override
  Future<void> logout() async {
    final response = await _client.delete(_resolve('/api/v1/auth/session'));
    _throwIfFailed(response);
  }

  Future<Map<String, Object?>> _jsonRequest(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, _resolve(path));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _throwIfFailed(response);
    if (response.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const RemoteApiFailure(
        statusCode: 502,
        code: 'invalid_response',
        message: '主机返回了无法识别的数据',
      );
    }
    return _map(decoded);
  }

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    try {
      final json = _map(jsonDecode(utf8.decode(response.bodyBytes)));
      final error = _map(json['error']);
      throw RemoteApiFailure(
        statusCode: response.statusCode,
        code: '${error['code'] ?? 'request_failed'}',
        message: '${error['message'] ?? '请求失败'}',
        details: _map(error['details']),
      );
    } on RemoteApiFailure {
      rethrow;
    } catch (_) {
      throw RemoteApiFailure(
        statusCode: response.statusCode,
        code: 'request_failed',
        message: '主机请求失败（${response.statusCode}）',
      );
    }
  }

  Uri _resolve(String path) => baseUri.resolve(path);

  @override
  void close() => _client.close();
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];
