import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../core/api/remote_api.dart';
import '../../core/api/remote_event_client.dart';
import '../../core/models/remote_models.dart';
import '../video_analysis/selected_video_file.dart';

enum RemoteAppPhase { loading, signedOut, projectSelection, ready }

class RemoteAppController extends ChangeNotifier {
  RemoteAppController({required RemoteApi api, RemoteEventClient? eventClient})
    : _api = api,
      _eventClient = eventClient ?? RemoteEventClient();

  final RemoteApi _api;
  final RemoteEventClient _eventClient;
  final Map<String, Future<Uint8List>> _mediaCache = {};
  StreamSubscription<Map<String, Object?>>? _eventSubscription;
  Timer? _reconnectTimer;
  Timer? _videoRefreshTimer;
  Timer? _videoGenerationRefreshTimer;
  Timer? _exportRefreshTimer;
  bool _disposed = false;

  RemoteAppPhase phase = RemoteAppPhase.loading;
  RemoteSession? session;
  List<RemoteProjectEntry> projects = const [];
  RemoteWorkspace? workspace;
  bool storyboardsAvailable = false;
  bool shootingWorkflowAvailable = false;
  bool videoAnalysisAvailable = false;
  bool videoUploadsAvailable = false;
  bool videoGenerationAvailable = false;
  bool exportsAvailable = false;
  bool settingsAvailable = false;
  bool tasksAvailable = false;
  List<RemoteVideoSummary> videos = const [];
  RemoteVideoDetail? selectedVideo;
  String selectedVideoFrameId = '';
  List<RemoteTask> tasks = const [];
  bool videoCommandBusy = false;
  bool videoGenerationCommandBusy = false;
  bool exportCommandBusy = false;
  bool settingsCommandBusy = false;
  String uploadingFileName = '';
  int uploadedBytes = 0;
  int uploadTotalBytes = 0;
  List<RemoteStoryboardGroup> storyboardGroups = const [];
  List<RemoteStoryboardSummary> storyboards = const [];
  RemoteStoryboardDetail? selectedStoryboard;
  List<RemoteStoryboardAsset> storyboardAssets = const [];
  String selectedStoryboardItemId = '';
  List<RemoteScriptSummary> scripts = const [];
  RemoteScriptDetail? selectedScript;
  RemoteShootingWorkflow? shootingWorkflow;
  bool shootingWorkflowCommandBusy = false;
  String selectedShotId = '';
  RemoteVideoGenerationOptions? videoGenerationOptions;
  List<RemoteVideoGenerationGroup> videoGenerationGroups = const [];
  List<RemoteVideoGenerationTask> videoGenerationTasks = const [];
  List<RemoteVideoGenerationTask> videoGenerationWorks = const [];
  RemoteExportOptions? exportOptions;
  RemoteSettingsSelection? settingsSelection;
  bool busy = false;
  bool liveConnected = false;
  String message = '';
  String errorMessage = '';

  bool get canEdit => session?.role == 'director';

  RemoteVideoFrame? get selectedVideoFrame {
    final detail = selectedVideo;
    if (detail == null) return null;
    for (final frame in detail.frames) {
      if (frame.id == selectedVideoFrameId) return frame;
    }
    return detail.frames.firstOrNull;
  }

  List<RemoteTask> get videoTasks => tasks
      .where(
        (task) =>
            task.kind == 'videoImport' ||
            task.kind == 'videoAnalysis' ||
            task.kind == 'videoStoryboard',
      )
      .toList(growable: false);

  List<RemoteTask> get videoGenerationOperations => tasks
      .where((task) => task.kind == 'videoGeneration')
      .toList(growable: false);

  List<RemoteTask> get exportTasks =>
      tasks.where((task) => task.kind == 'export').toList(growable: false);

  List<RemoteTask> get shootingWorkflowTasks => tasks
      .where(
        (task) =>
            task.kind == 'shootingAssetMatch' ||
            task.kind == 'shootingScriptBuild' ||
            task.kind == 'storyboardReplication',
      )
      .toList(growable: false);

  RemoteStoryboardItem? get selectedStoryboardItem {
    final detail = selectedStoryboard;
    if (detail == null) return null;
    for (final item in detail.items) {
      if (item.assetId == selectedStoryboardItemId) return item;
    }
    return detail.items.firstOrNull;
  }

  RemoteShot? get selectedShot {
    final detail = selectedScript;
    if (detail == null) return null;
    for (final shot in detail.shots) {
      if (shot.id == selectedShotId) return shot;
    }
    return detail.shots.firstOrNull;
  }

  Future<void> initialize() async {
    phase = RemoteAppPhase.loading;
    _notify();
    try {
      final capabilities = await _api.capabilities();
      _applyCapabilities(capabilities);
      final sessionJson = capabilities['session'];
      if (sessionJson is Map) {
        session = RemoteSession.fromJson(
          sessionJson.map((key, value) => MapEntry('$key', value)),
        );
      }
      await _enterProjectSelection();
      await _connectEvents();
    } on RemoteApiFailure catch (error) {
      if (error.statusCode == 401) {
        phase = RemoteAppPhase.signedOut;
      } else {
        phase = RemoteAppPhase.signedOut;
        errorMessage = error.message;
      }
      _notify();
    } catch (_) {
      phase = RemoteAppPhase.signedOut;
      errorMessage = '无法连接 FilmStoryboard 主机，请确认桌面软件已开启远程访问';
      _notify();
    }
  }

  Future<void> pair({required String code, required String clientName}) async {
    if (busy) return;
    busy = true;
    errorMessage = '';
    _notify();
    try {
      final result = await _api.pair(code: code, clientName: clientName);
      session = result.session;
      busy = false;
      _applyCapabilities(await _api.capabilities());
      await _enterProjectSelection();
      await _connectEvents();
    } on RemoteApiFailure catch (error) {
      errorMessage = error.message;
    } catch (_) {
      errorMessage = '连接失败，请检查配对码和网络后重试';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refreshProjects() async {
    if (session == null || busy) return;
    busy = true;
    errorMessage = '';
    _notify();
    try {
      projects = await _api.projects();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '读取本机工程列表失败，请稍后重试';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> openProject(String projectId) async {
    if (!canEdit || busy || projectId.trim().isEmpty) return;
    busy = true;
    errorMessage = '';
    message = '正在请求桌面端打开工程…';
    _notify();
    try {
      await _api.openProject(projectId);
      workspace = await _api.workspace();
      if (workspace?.project?.id != projectId) {
        throw const RemoteApiFailure(
          statusCode: 409,
          code: 'workspace_not_ready',
          message: '桌面端尚未完成工程切换，请稍后重试',
        );
      }
      phase = RemoteAppPhase.ready;
      busy = false;
      message = '已进入 ${workspace!.project!.name}';
      await refreshAll();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
      phase = RemoteAppPhase.projectSelection;
    } catch (_) {
      errorMessage = '打开工程失败，请检查桌面端状态后重试';
      phase = RemoteAppPhase.projectSelection;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> showProjectSelection() async {
    if (session == null) return;
    phase = RemoteAppPhase.projectSelection;
    message = '';
    errorMessage = '';
    _notify();
    await refreshProjects();
  }

  Future<void> refreshAll() async {
    if (phase != RemoteAppPhase.ready || busy) return;
    busy = true;
    errorMessage = '';
    _notify();
    try {
      workspace = await _api.workspace();
      if (workspace?.project == null) {
        videos = const [];
        selectedVideo = null;
        selectedVideoFrameId = '';
        tasks = const [];
        storyboardGroups = const [];
        storyboards = const [];
        selectedStoryboard = null;
        storyboardAssets = const [];
        selectedStoryboardItemId = '';
        scripts = const [];
        selectedScript = null;
        shootingWorkflow = null;
        selectedShotId = '';
        _clearVideoGenerationState();
        _clearExportState();
        settingsSelection = null;
        return;
      }
      if (videoAnalysisAvailable) {
        await _loadVideoCollection();
      } else {
        videos = const [];
        selectedVideo = null;
        selectedVideoFrameId = '';
      }
      tasks = tasksAvailable ? await _api.tasks() : const [];
      if (storyboardsAvailable) {
        await _loadStoryboardCollection();
      } else {
        storyboardGroups = const [];
        storyboards = const [];
        selectedStoryboard = null;
        storyboardAssets = const [];
        selectedStoryboardItemId = '';
      }
      scripts = await _api.scripts();
      final selectedId = selectedScript?.id;
      final nextId = scripts.any((script) => script.id == selectedId)
          ? selectedId!
          : scripts.firstOrNull?.id;
      if (nextId == null) {
        selectedScript = null;
        shootingWorkflow = null;
        selectedShotId = '';
      } else {
        await _loadScript(nextId);
      }
      if (videoGenerationAvailable) {
        await _loadVideoGeneration();
      } else {
        _clearVideoGenerationState();
      }
      if (exportsAvailable) {
        exportOptions = await _api.exportOptions();
      } else {
        _clearExportState();
      }
      if (settingsAvailable) {
        settingsSelection = await _api.settingsSelection();
      } else {
        settingsSelection = null;
      }
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '刷新工作台失败，请稍后重试';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> selectScript(String scriptId) async {
    if (busy || selectedScript?.id == scriptId) return;
    busy = true;
    errorMessage = '';
    _notify();
    try {
      await _loadScript(scriptId);
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> updateSettingsSelection({
    String? extractionStrategy,
    String? visionModelId,
    String? imageGenerationModelId,
    String? videoGenerationModelId,
  }) async {
    if (!canEdit || settingsCommandBusy || !settingsAvailable) return;
    settingsCommandBusy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      settingsSelection = await _api.updateSettingsSelection(
        extractionStrategy: extractionStrategy,
        visionModelId: visionModelId,
        imageGenerationModelId: imageGenerationModelId,
        videoGenerationModelId: videoGenerationModelId,
      );
      message = '已切换本机工作模型设置';
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '切换设置失败，请稍后重试';
    } finally {
      settingsCommandBusy = false;
      _notify();
    }
  }

  Future<void> selectVideo(String videoId) async {
    if (videoCommandBusy || selectedVideo?.video.id == videoId) return;
    videoCommandBusy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      await _loadVideo(videoId);
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '读取视频解析详情失败，请稍后重试';
    } finally {
      videoCommandBusy = false;
      _notify();
    }
  }

  void selectVideoFrame(String frameId) {
    if (selectedVideoFrameId == frameId) return;
    selectedVideoFrameId = frameId;
    _notify();
  }

  Future<void> uploadVideo(RemoteSelectedVideoFile file) async {
    if (!canEdit ||
        !videoUploadsAvailable ||
        videoCommandBusy ||
        file.name.trim().isEmpty ||
        file.size <= 0) {
      return;
    }
    videoCommandBusy = true;
    uploadingFileName = file.name;
    uploadedBytes = 0;
    uploadTotalBytes = file.size;
    message = '正在上传 ${file.name}…';
    errorMessage = '';
    _notify();
    try {
      final upload = await _api.uploadVideo(
        fileName: file.name,
        size: file.size,
        bytes: file.openRead(),
        onProgress: (sent, total) {
          uploadedBytes = sent;
          uploadTotalBytes = total;
          _notify();
        },
      );
      final task = await _api.importVideo(upload.id);
      _trackTask(task);
      message = '${file.name} 已上传，桌面端正在导入并提取候选帧';
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '视频上传失败，请检查连接后重试';
    } finally {
      videoCommandBusy = false;
      uploadingFileName = '';
      uploadedBytes = 0;
      uploadTotalBytes = 0;
      _notify();
    }
  }

  Future<void> startSelectedVideoAnalysis({
    bool retryFailedOnly = false,
  }) async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      final task = await _api.analyzeVideo(
        videoId,
        retryFailedOnly: retryFailedOnly,
      );
      _trackTask(task);
      message = retryFailedOnly ? '已提交失败帧重试' : '已提交视频解析任务';
    });
  }

  Future<void> pauseSelectedVideoAnalysis() async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _applyVideoDetail(await _api.pauseVideo(videoId));
      message = '已请求在当前帧结束后暂停';
    });
  }

  Future<void> cancelSelectedVideoAnalysis() async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _applyVideoDetail(await _api.cancelVideo(videoId));
      message = '视频解析任务已取消';
    });
  }

  Future<void> removeVideoFrame(String frameId) async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _applyVideoDetail(await _api.removeVideoFrame(videoId, frameId));
      message = '候选帧已移除，可使用撤销恢复';
    });
  }

  Future<void> undoVideoFrameRemoval() async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _applyVideoDetail(await _api.undoVideoFrameRemoval(videoId));
      message = '已恢复最近移除的候选帧';
    });
  }

  Future<void> redoVideoFrameRemoval() async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _applyVideoDetail(await _api.redoVideoFrameRemoval(videoId));
      message = '已再次移除候选帧';
    });
  }

  Future<void> generateSelectedVideoStoryboard() async {
    final videoId = selectedVideo?.video.id;
    if (!canEdit || videoId == null || videoCommandBusy) return;
    await _runVideoCommand(() async {
      final task = await _api.generateVideoStoryboard(videoId);
      _trackTask(task);
      message = '已提交故事板和拍摄脚本生成任务';
    });
  }

  Future<void> cancelRemoteTask(String taskId) async {
    if (!canEdit || videoCommandBusy) return;
    await _runVideoCommand(() async {
      _trackTask(await _api.cancelTask(taskId));
      message = '任务已取消';
    });
  }

  Future<void> selectStoryboard(String storyboardId) async {
    if (busy || selectedStoryboard?.id == storyboardId) return;
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      await _loadStoryboard(storyboardId);
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  void selectStoryboardItem(String assetId) {
    if (selectedStoryboardItemId == assetId) return;
    selectedStoryboardItemId = assetId;
    message = '';
    errorMessage = '';
    _notify();
  }

  void selectShot(String shotId) {
    if (selectedShotId == shotId) return;
    selectedShotId = shotId;
    message = '';
    errorMessage = '';
    _notify();
  }

  Future<void> saveSelectedShot(Map<String, Object?> changes) async {
    final script = selectedScript;
    final shot = selectedShot;
    if (script == null || shot == null || busy || changes.isEmpty) return;
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      final updated = await _api.updateShot(
        scriptId: script.id,
        shotId: shot.id,
        expectedVersion: script.version,
        changes: changes,
      );
      selectedScript = updated;
      selectedShotId = shot.id;
      scripts = [
        for (final item in scripts)
          if (item.id == updated.id) updated else item,
      ];
      message = '镜头 ${shot.shotNumber} 已同步到桌面端';
    } on RemoteApiFailure catch (error) {
      if (error.code == 'revision_conflict') {
        await _loadScript(script.id);
        errorMessage = '桌面端或另一位导演刚刚更新了脚本，已为你加载最新版本';
      } else {
        _handleApiFailure(error);
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> confirmShootingWorkflowShots() async {
    final scriptId = selectedScript?.id;
    if (!canEdit ||
        !shootingWorkflowAvailable ||
        scriptId == null ||
        shootingWorkflowCommandBusy) {
      return;
    }
    await _runShootingWorkflowCommand(() async {
      shootingWorkflow = await _api.confirmShootingWorkflowShots(scriptId);
      message = '已确认当前脚本全部镜头';
    });
  }

  Future<void> startShootingWorkflowAction(
    String action, {
    String? shotId,
  }) async {
    final scriptId = selectedScript?.id;
    if (!canEdit ||
        !shootingWorkflowAvailable ||
        scriptId == null ||
        shootingWorkflowCommandBusy) {
      return;
    }
    await _runShootingWorkflowCommand(() async {
      final task = await _api.startShootingWorkflowAction(
        scriptId: scriptId,
        action: action,
        shotId: shotId,
      );
      _trackTask(task);
      message = switch (action) {
        'matchAssets' => '已提交本机资产匹配任务',
        'buildScript' => '已提交本机脚本构建任务',
        'replicateStoryboards' =>
          shotId == null ? '已提交全部分镜复刻任务' : '已提交当前镜头复刻任务',
        _ => '已提交本机任务',
      };
    });
  }

  Future<void> saveSelectedStoryboard(
    Map<String, Object?> changes, {
    int? expectedRevision,
  }) async {
    final storyboard = selectedStoryboard;
    if (!canEdit ||
        storyboard == null ||
        storyboard.locked ||
        busy ||
        changes.isEmpty) {
      return;
    }
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      final updated = await _api.updateStoryboard(
        storyboardId: storyboard.id,
        expectedRevision: expectedRevision ?? storyboard.revision,
        changes: changes,
      );
      _applyStoryboardDetail(updated);
      message = '${updated.name} 已同步到桌面端';
    } on RemoteApiFailure catch (error) {
      await _handleStoryboardFailure(error, storyboard.id);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> updateStoryboardLayout({
    required String action,
    required String assetId,
    int? slotIndex,
  }) async {
    final storyboard = selectedStoryboard;
    if (!canEdit || storyboard == null || storyboard.locked || busy) return;
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      final updated = await _api.updateStoryboardLayout(
        storyboardId: storyboard.id,
        expectedRevision: storyboard.revision,
        action: action,
        assetId: assetId,
        slotIndex: slotIndex,
      );
      _applyStoryboardDetail(updated);
      storyboardAssets = await _api.storyboardAssets(storyboard.id);
      message = switch (action) {
        'add' => '图片已加入画板',
        'move' => '画板排版已更新',
        'remove' => '图片已从画板移除',
        _ => '画板已更新',
      };
    } on RemoteApiFailure catch (error) {
      await _handleStoryboardFailure(error, storyboard.id);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> addStoryboardAnnotation({
    required String body,
    String? assetId,
  }) async {
    final storyboard = selectedStoryboard;
    if (!canEdit || storyboard == null || busy || body.trim().isEmpty) return;
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      final updated = await _api.addStoryboardAnnotation(
        storyboardId: storyboard.id,
        expectedRevision: storyboard.revision,
        body: body.trim(),
        assetId: assetId,
      );
      _applyStoryboardDetail(updated);
      message = '批注已保存';
    } on RemoteApiFailure catch (error) {
      await _handleStoryboardFailure(error, storyboard.id);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> updateStoryboardAnnotation({
    required String annotationId,
    String? body,
    bool? resolved,
  }) async {
    final storyboard = selectedStoryboard;
    if (!canEdit ||
        storyboard == null ||
        busy ||
        (body == null && resolved == null)) {
      return;
    }
    busy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      final updated = await _api.updateStoryboardAnnotation(
        storyboardId: storyboard.id,
        annotationId: annotationId,
        expectedRevision: storyboard.revision,
        changes: {'body': ?body, 'resolved': ?resolved},
      );
      _applyStoryboardDetail(updated);
      message = resolved == true ? '批注已解决' : '批注已更新';
    } on RemoteApiFailure catch (error) {
      await _handleStoryboardFailure(error, storyboard.id);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<Uint8List> mediaBytes(String mediaId) => _mediaCache.putIfAbsent(
    mediaId,
    () async => (await _api.media(mediaId)).bytes,
  );

  Uri mediaUri(String mediaId) => _api.baseUri.resolve(
    '/api/v1/media/${Uri.encodeComponent(mediaId)}/content',
  );

  Future<void> refreshVideoAnalysis() async {
    if (!videoAnalysisAvailable || videoCommandBusy) return;
    videoCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      await _loadVideoCollection();
      if (tasksAvailable) tasks = await _api.tasks();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '刷新视频解析状态失败，请稍后重试';
    } finally {
      videoCommandBusy = false;
      _notify();
    }
  }

  Future<void> refreshVideoGeneration() async {
    if (!videoGenerationAvailable || videoGenerationCommandBusy) return;
    videoGenerationCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      await _loadVideoGeneration();
      if (tasksAvailable) tasks = await _api.tasks();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '刷新视频生成状态失败，请稍后重试';
    } finally {
      videoGenerationCommandBusy = false;
      _notify();
    }
  }

  Future<void> refreshExports() async {
    if (!exportsAvailable || exportCommandBusy) return;
    exportCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      exportOptions = await _api.exportOptions();
      if (tasksAvailable) tasks = await _api.tasks();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '刷新导出状态失败，请稍后重试';
    } finally {
      exportCommandBusy = false;
      _notify();
    }
  }

  Future<void> startExport(RemoteExportRequest request) async {
    if (!canEdit || !exportsAvailable || exportCommandBusy) return;
    await _runExportCommand(() async {
      _trackTask(await _api.startExport(request));
      message = '导出任务已提交到本机';
    });
  }

  Future<void> cancelExportTask(String taskId) async {
    if (!canEdit || exportCommandBusy) return;
    await _runExportCommand(() async {
      _trackTask(await _api.cancelTask(taskId));
      message = '导出任务已取消';
    });
  }

  Future<void> retryExportTask(String taskId) async {
    if (!canEdit || exportCommandBusy) return;
    await _runExportCommand(() async {
      _trackTask(await _api.retryExport(taskId));
      message = '已重新提交导出任务';
    });
  }

  Uri? exportArtifactUri(
    RemoteExportArtifact artifact, {
    required bool download,
  }) {
    final path = download ? artifact.downloadUrl : artifact.contentUrl;
    return path.isEmpty ? null : _api.baseUri.resolve(path);
  }

  Future<void> selectVideoGenerationScript(String scriptId) async {
    if (!canEdit ||
        !videoGenerationAvailable ||
        videoGenerationCommandBusy ||
        scriptId.trim().isEmpty ||
        videoGenerationOptions?.selectedScriptId == scriptId) {
      return;
    }
    await _runVideoGenerationCommand(() async {
      final result = await _api.selectVideoGenerationScript(scriptId);
      videoGenerationOptions = result.options;
      videoGenerationGroups = result.groups;
      message = '已切换生成用拍摄脚本';
    });
  }

  Future<void> startVideoGeneration({
    required List<String> shotIds,
    required String model,
    required Map<String, String> parameters,
    required Map<String, RemoteVideoGenerationShotOverride> shotOverrides,
  }) async {
    final scriptId = videoGenerationOptions?.selectedScriptId ?? '';
    if (!canEdit ||
        !videoGenerationAvailable ||
        videoGenerationCommandBusy ||
        scriptId.isEmpty ||
        shotIds.isEmpty) {
      return;
    }
    await _runVideoGenerationCommand(() async {
      final task = await _api.startVideoGeneration(
        scriptId: scriptId,
        shotIds: shotIds,
        model: model,
        parameters: parameters,
        shotOverrides: shotOverrides,
      );
      _trackTask(task);
      message = '已提交 ${shotIds.length} 个镜头组的视频生成任务';
    });
  }

  Future<void> cancelVideoGenerationOperation(String taskId) async {
    if (!canEdit || videoGenerationCommandBusy) return;
    await _runVideoGenerationCommand(() async {
      _trackTask(await _api.cancelTask(taskId));
      message = '生成操作已取消';
    });
  }

  Future<void> cancelVideoGenerationTask(String taskId) async {
    if (!canEdit || videoGenerationCommandBusy) return;
    await _runVideoGenerationCommand(() async {
      _replaceVideoGenerationTask(await _api.cancelVideoGenerationTask(taskId));
      message = '真实生成任务已取消';
    });
  }

  Future<void> retryVideoGenerationTask(String taskId) async {
    if (!canEdit || videoGenerationCommandBusy) return;
    await _runVideoGenerationCommand(() async {
      _trackTask(await _api.retryVideoGenerationTask(taskId));
      message = '已重新提交失败的生成任务';
    });
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // 本地仍会退出；服务不可达时会话将在服务端按时过期。
    }
    await _eventSubscription?.cancel();
    await _eventClient.close();
    _reconnectTimer?.cancel();
    _videoRefreshTimer?.cancel();
    _videoGenerationRefreshTimer?.cancel();
    _exportRefreshTimer?.cancel();
    session = null;
    projects = const [];
    workspace = null;
    storyboardsAvailable = false;
    videoAnalysisAvailable = false;
    videoUploadsAvailable = false;
    videoGenerationAvailable = false;
    exportsAvailable = false;
    settingsAvailable = false;
    tasksAvailable = false;
    videos = const [];
    selectedVideo = null;
    selectedVideoFrameId = '';
    tasks = const [];
    storyboardGroups = const [];
    storyboards = const [];
    selectedStoryboard = null;
    storyboardAssets = const [];
    selectedStoryboardItemId = '';
    scripts = const [];
    selectedScript = null;
    shootingWorkflow = null;
    selectedShotId = '';
    _clearVideoGenerationState();
    _clearExportState();
    settingsSelection = null;
    liveConnected = false;
    phase = RemoteAppPhase.signedOut;
    _notify();
  }

  Future<void> _loadScript(String id) async {
    final previousShotId = selectedShotId;
    final responses = await Future.wait<Object>([
      _api.script(id),
      if (shootingWorkflowAvailable) _api.shootingWorkflow(id),
    ]);
    final detail = responses.first as RemoteScriptDetail;
    shootingWorkflow = shootingWorkflowAvailable
        ? responses[1] as RemoteShootingWorkflow
        : null;
    selectedScript = detail;
    selectedShotId = detail.shots.any((shot) => shot.id == previousShotId)
        ? previousShotId
        : (detail.shots.firstOrNull?.id ?? '');
  }

  Future<void> _loadVideoCollection() async {
    final previousId = selectedVideo?.video.id;
    videos = await _api.videos();
    final nextId = videos.any((video) => video.id == previousId)
        ? previousId!
        : videos.firstOrNull?.id;
    if (nextId == null) {
      selectedVideo = null;
      selectedVideoFrameId = '';
    } else {
      await _loadVideo(nextId);
    }
  }

  Future<void> _loadVideoGeneration() async {
    videoGenerationOptions = await _api.videoGenerationOptions();
    videoGenerationGroups = await _api.videoGenerationGroups();
    videoGenerationTasks = await _api.videoGenerationTasks();
    videoGenerationWorks = await _api.videoGenerationWorks();
  }

  void _clearVideoGenerationState() {
    videoGenerationOptions = null;
    videoGenerationGroups = const [];
    videoGenerationTasks = const [];
    videoGenerationWorks = const [];
  }

  void _clearExportState() {
    exportOptions = null;
  }

  Future<void> _loadVideo(String id) async {
    final previousFrameId = selectedVideoFrameId;
    final detail = await _api.video(id);
    selectedVideo = detail;
    selectedVideoFrameId =
        detail.frames.any((frame) => frame.id == previousFrameId)
        ? previousFrameId
        : (detail.frames.firstOrNull?.id ?? '');
    videos = [
      for (final item in videos)
        if (item.id == detail.video.id) detail.video else item,
    ];
  }

  void _applyVideoDetail(RemoteVideoDetail detail) {
    final previousFrameId = selectedVideoFrameId;
    selectedVideo = detail;
    selectedVideoFrameId =
        detail.frames.any((frame) => frame.id == previousFrameId)
        ? previousFrameId
        : (detail.frames.firstOrNull?.id ?? '');
    videos = [
      for (final item in videos)
        if (item.id == detail.video.id) detail.video else item,
    ];
  }

  Future<void> _runVideoCommand(Future<void> Function() command) async {
    videoCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      await command();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '视频解析命令执行失败，请稍后重试';
    } finally {
      videoCommandBusy = false;
      _notify();
    }
  }

  Future<void> _runVideoGenerationCommand(
    Future<void> Function() command,
  ) async {
    videoGenerationCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      await command();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '视频生成命令执行失败，请稍后重试';
    } finally {
      videoGenerationCommandBusy = false;
      _notify();
    }
  }

  Future<void> _runExportCommand(Future<void> Function() command) async {
    exportCommandBusy = true;
    errorMessage = '';
    _notify();
    try {
      await command();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } catch (_) {
      errorMessage = '导出命令执行失败，请稍后重试';
    } finally {
      exportCommandBusy = false;
      _notify();
    }
  }

  void _trackTask(RemoteTask task) {
    tasks = [
      task,
      for (final item in tasks)
        if (item.id != task.id) item,
    ];
  }

  void _replaceVideoGenerationTask(RemoteVideoGenerationTask task) {
    videoGenerationTasks = [
      task,
      for (final item in videoGenerationTasks)
        if (item.id != task.id) item,
    ];
  }

  Future<void> _enterProjectSelection() async {
    phase = RemoteAppPhase.projectSelection;
    workspace = null;
    projects = await _api.projects();
    _notify();
  }

  Future<void> _loadStoryboardCollection() async {
    final previousId = selectedStoryboard?.id;
    final response = await _api.storyboards();
    storyboardGroups = response.groups;
    storyboards = response.items;
    final nextId = storyboards.any((board) => board.id == previousId)
        ? previousId!
        : storyboards.firstOrNull?.id;
    if (nextId == null) {
      selectedStoryboard = null;
      storyboardAssets = const [];
      selectedStoryboardItemId = '';
    } else {
      await _loadStoryboard(nextId);
    }
  }

  Future<void> _loadStoryboard(String id) async {
    final previousItemId = selectedStoryboardItemId;
    final responses = await Future.wait<Object>([
      _api.storyboard(id),
      _api.storyboardAssets(id),
    ]);
    final detail = responses[0] as RemoteStoryboardDetail;
    storyboardAssets = responses[1] as List<RemoteStoryboardAsset>;
    selectedStoryboard = detail;
    selectedStoryboardItemId =
        detail.items.any((item) => item.assetId == previousItemId)
        ? previousItemId
        : (detail.items.firstOrNull?.assetId ?? '');
    _replaceStoryboardSummary(detail);
  }

  void _applyStoryboardDetail(RemoteStoryboardDetail detail) {
    final previousItemId = selectedStoryboardItemId;
    selectedStoryboard = detail;
    selectedStoryboardItemId =
        detail.items.any((item) => item.assetId == previousItemId)
        ? previousItemId
        : (detail.items.firstOrNull?.assetId ?? '');
    _replaceStoryboardSummary(detail);
  }

  void _replaceStoryboardSummary(RemoteStoryboardDetail detail) {
    storyboards = [
      for (final item in storyboards)
        if (item.id == detail.id) detail else item,
    ];
  }

  Future<void> _connectEvents() async {
    await _eventSubscription?.cancel();
    await _eventClient.close();
    try {
      final ticket = await _api.webSocketTicket();
      final eventUri = _api.baseUri.replace(
        scheme: _api.baseUri.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/v1/events',
        queryParameters: {'ticket': ticket},
      );
      final events = _eventClient.connect(eventUri);
      _eventSubscription = events.listen(
        _handleEvent,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleEvent(Map<String, Object?> event) {
    final type = '${event['type'] ?? ''}';
    if (type == 'ready') {
      liveConnected = true;
      _notify();
      return;
    }
    if (type == 'workspace.closed') {
      unawaited(showProjectSelection());
      return;
    }
    if (type == 'workspace.opened') {
      if (phase == RemoteAppPhase.ready) unawaited(refreshAll());
      return;
    }
    if (type == 'projects.changed' &&
        phase == RemoteAppPhase.projectSelection) {
      unawaited(refreshProjects());
      return;
    }
    if (type == 'task.changed') {
      final data = event['data'];
      if (data is Map) {
        final task = RemoteTask.fromJson(
          data.map((key, value) => MapEntry('$key', value)),
        );
        _trackTask(task);
        _notify();
        if (task.terminal &&
            task.kind.startsWith('video') &&
            task.kind != 'videoGeneration') {
          _scheduleVideoRefresh();
        }
        if (task.kind == 'videoGeneration') {
          _scheduleVideoGenerationRefresh();
        }
        if (task.kind == 'export') {
          _scheduleExportRefresh();
        }
        if (task.kind == 'shootingAssetMatch' ||
            task.kind == 'shootingScriptBuild' ||
            task.kind == 'storyboardReplication') {
          final scriptId = selectedScript?.id;
          if (scriptId != null) unawaited(_refreshShootingWorkflow(scriptId));
        }
      }
      return;
    }
    if (type == 'videos.changed') {
      _scheduleVideoRefresh();
      return;
    }
    if (type == 'videoGeneration.changed') {
      _scheduleVideoGenerationRefresh();
      return;
    }
    if (type == 'export.changed') {
      _scheduleExportRefresh();
      return;
    }
    if (type == 'settings.changed') {
      unawaited(_refreshSettings());
      return;
    }
    if (type == 'shootingScript.changed') {
      final resourceId = '${event['resourceId'] ?? ''}';
      unawaited(_refreshChangedScript(resourceId));
      return;
    }
    if (type == 'shootingWorkflow.changed') {
      final resourceId = '${event['resourceId'] ?? ''}';
      unawaited(_refreshShootingWorkflow(resourceId));
      return;
    }
    if (type == 'storyboard.changed') {
      final resourceId = '${event['resourceId'] ?? ''}';
      unawaited(_refreshChangedStoryboard(resourceId));
      return;
    }
    if (type == 'storyboards.changed') {
      unawaited(_refreshStoryboards());
    }
  }

  Future<void> _refreshChangedScript(String scriptId) async {
    if (busy || phase != RemoteAppPhase.ready) return;
    try {
      scripts = await _api.scripts();
      if (selectedScript?.id == scriptId) await _loadScript(scriptId);
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次手动刷新会恢复。
    }
  }

  Future<void> _refreshShootingWorkflow(String scriptId) async {
    if (phase != RemoteAppPhase.ready ||
        !shootingWorkflowAvailable ||
        selectedScript?.id != scriptId ||
        scriptId.isEmpty) {
      return;
    }
    try {
      shootingWorkflow = await _api.shootingWorkflow(scriptId);
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次任务事件或手动刷新会恢复。
    }
  }

  Future<void> _runShootingWorkflowCommand(
    Future<void> Function() command,
  ) async {
    shootingWorkflowCommandBusy = true;
    message = '';
    errorMessage = '';
    _notify();
    try {
      await command();
    } on RemoteApiFailure catch (error) {
      _handleApiFailure(error);
    } finally {
      shootingWorkflowCommandBusy = false;
      _notify();
    }
  }

  Future<void> _refreshSettings() async {
    if (phase != RemoteAppPhase.ready || !settingsAvailable) return;
    try {
      settingsSelection = await _api.settingsSelection();
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次手动刷新会恢复。
    }
  }

  Future<void> _refreshChangedStoryboard(String storyboardId) async {
    if (busy ||
        phase != RemoteAppPhase.ready ||
        !storyboardsAvailable ||
        storyboardId.isEmpty) {
      return;
    }
    try {
      final response = await _api.storyboards();
      storyboardGroups = response.groups;
      storyboards = response.items;
      if (selectedStoryboard?.id == storyboardId) {
        await _loadStoryboard(storyboardId);
      }
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次手动刷新会恢复。
    }
  }

  Future<void> _refreshStoryboards() async {
    if (busy || phase != RemoteAppPhase.ready || !storyboardsAvailable) {
      return;
    }
    try {
      await _loadStoryboardCollection();
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次手动刷新会恢复。
    }
  }

  Future<void> _refreshVideosFromEvent() async {
    if (phase != RemoteAppPhase.ready || !videoAnalysisAvailable) return;
    try {
      await _loadVideoCollection();
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次任务事件或手动刷新会恢复。
    }
  }

  void _scheduleVideoRefresh() {
    _videoRefreshTimer?.cancel();
    _videoRefreshTimer = Timer(
      const Duration(milliseconds: 180),
      _refreshVideosFromEvent,
    );
  }

  void _scheduleVideoGenerationRefresh() {
    _videoGenerationRefreshTimer?.cancel();
    _videoGenerationRefreshTimer = Timer(
      const Duration(milliseconds: 180),
      _refreshVideoGenerationFromEvent,
    );
  }

  Future<void> _refreshVideoGenerationFromEvent() async {
    if (phase != RemoteAppPhase.ready || !videoGenerationAvailable) return;
    try {
      await _loadVideoGeneration();
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次任务事件或手动刷新会恢复。
    }
  }

  void _scheduleExportRefresh() {
    _exportRefreshTimer?.cancel();
    _exportRefreshTimer = Timer(
      const Duration(milliseconds: 180),
      _refreshExportsFromEvent,
    );
  }

  Future<void> _refreshExportsFromEvent() async {
    if (phase != RemoteAppPhase.ready || !exportsAvailable) return;
    try {
      exportOptions = await _api.exportOptions();
      if (tasksAvailable) tasks = await _api.tasks();
      _notify();
    } catch (_) {
      // REST 状态仍是事实来源，下次任务事件或手动刷新会恢复。
    }
  }

  Future<void> _handleStoryboardFailure(
    RemoteApiFailure error,
    String storyboardId,
  ) async {
    if (error.code == 'revision_conflict') {
      try {
        final response = await _api.storyboards();
        storyboardGroups = response.groups;
        storyboards = response.items;
        await _loadStoryboard(storyboardId);
      } catch (_) {
        // 保留原冲突提示，用户仍可手动刷新恢复。
      }
      errorMessage = '桌面端或另一位导演刚刚更新了故事板，已为你加载最新版本';
    } else {
      _handleApiFailure(error);
    }
  }

  void _applyCapabilities(Map<String, Object?> response) {
    final capabilities = response['capabilities'];
    storyboardsAvailable =
        capabilities is Map && capabilities['storyboards'] == true;
    shootingWorkflowAvailable =
        capabilities is Map && capabilities['shootingWorkflow'] == true;
    videoAnalysisAvailable =
        capabilities is Map && capabilities['videoAnalysis'] == true;
    videoUploadsAvailable =
        capabilities is Map && capabilities['videoUploads'] == true;
    videoGenerationAvailable =
        capabilities is Map && capabilities['videoGeneration'] == true;
    exportsAvailable = capabilities is Map && capabilities['exports'] == true;
    settingsAvailable = capabilities is Map && capabilities['settings'] == true;
    tasksAvailable = capabilities is Map && capabilities['tasks'] == true;
  }

  void _scheduleReconnect() {
    liveConnected = false;
    _notify();
    if (_disposed || phase == RemoteAppPhase.signedOut) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _connectEvents);
  }

  void _handleApiFailure(RemoteApiFailure error) {
    if (error.statusCode == 401) {
      phase = RemoteAppPhase.signedOut;
      session = null;
    }
    errorMessage = error.message;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _videoRefreshTimer?.cancel();
    _videoGenerationRefreshTimer?.cancel();
    _exportRefreshTimer?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_eventClient.close());
    _api.close();
    super.dispose();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
