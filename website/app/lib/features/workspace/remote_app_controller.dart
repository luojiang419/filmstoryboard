import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../core/api/remote_api.dart';
import '../../core/api/remote_event_client.dart';
import '../../core/models/remote_models.dart';

enum RemoteAppPhase { loading, signedOut, ready }

class RemoteAppController extends ChangeNotifier {
  RemoteAppController({required RemoteApi api, RemoteEventClient? eventClient})
    : _api = api,
      _eventClient = eventClient ?? RemoteEventClient();

  final RemoteApi _api;
  final RemoteEventClient _eventClient;
  final Map<String, Future<Uint8List>> _mediaCache = {};
  StreamSubscription<Map<String, Object?>>? _eventSubscription;
  Timer? _reconnectTimer;
  bool _disposed = false;

  RemoteAppPhase phase = RemoteAppPhase.loading;
  RemoteSession? session;
  RemoteWorkspace? workspace;
  bool storyboardsAvailable = false;
  List<RemoteStoryboardGroup> storyboardGroups = const [];
  List<RemoteStoryboardSummary> storyboards = const [];
  RemoteStoryboardDetail? selectedStoryboard;
  String selectedStoryboardItemId = '';
  List<RemoteScriptSummary> scripts = const [];
  RemoteScriptDetail? selectedScript;
  String selectedShotId = '';
  bool busy = false;
  bool liveConnected = false;
  String message = '';
  String errorMessage = '';

  bool get canEdit => session?.role == 'director';

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
      phase = RemoteAppPhase.ready;
      await refreshAll();
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
      phase = RemoteAppPhase.ready;
      busy = false;
      _applyCapabilities(await _api.capabilities());
      await refreshAll();
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

  Future<void> refreshAll() async {
    if (phase != RemoteAppPhase.ready || busy) return;
    busy = true;
    errorMessage = '';
    _notify();
    try {
      workspace = await _api.workspace();
      if (workspace?.project == null) {
        storyboardGroups = const [];
        storyboards = const [];
        selectedStoryboard = null;
        selectedStoryboardItemId = '';
        scripts = const [];
        selectedScript = null;
        selectedShotId = '';
        return;
      }
      if (storyboardsAvailable) {
        await _loadStoryboardCollection();
      } else {
        storyboardGroups = const [];
        storyboards = const [];
        selectedStoryboard = null;
        selectedStoryboardItemId = '';
      }
      scripts = await _api.scripts();
      final selectedId = selectedScript?.id;
      final nextId = scripts.any((script) => script.id == selectedId)
          ? selectedId!
          : scripts.firstOrNull?.id;
      if (nextId == null) {
        selectedScript = null;
        selectedShotId = '';
      } else {
        await _loadScript(nextId);
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

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // 本地仍会退出；服务不可达时会话将在服务端按时过期。
    }
    await _eventSubscription?.cancel();
    await _eventClient.close();
    _reconnectTimer?.cancel();
    session = null;
    workspace = null;
    storyboardsAvailable = false;
    storyboardGroups = const [];
    storyboards = const [];
    selectedStoryboard = null;
    selectedStoryboardItemId = '';
    scripts = const [];
    selectedScript = null;
    selectedShotId = '';
    liveConnected = false;
    phase = RemoteAppPhase.signedOut;
    _notify();
  }

  Future<void> _loadScript(String id) async {
    final previousShotId = selectedShotId;
    final detail = await _api.script(id);
    selectedScript = detail;
    selectedShotId = detail.shots.any((shot) => shot.id == previousShotId)
        ? previousShotId
        : (detail.shots.firstOrNull?.id ?? '');
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
      selectedStoryboardItemId = '';
    } else {
      await _loadStoryboard(nextId);
    }
  }

  Future<void> _loadStoryboard(String id) async {
    final previousItemId = selectedStoryboardItemId;
    final detail = await _api.storyboard(id);
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
    if (type == 'workspace.opened' || type == 'workspace.closed') {
      unawaited(refreshAll());
      return;
    }
    if (type == 'shootingScript.changed') {
      final resourceId = '${event['resourceId'] ?? ''}';
      unawaited(_refreshChangedScript(resourceId));
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
  }

  void _scheduleReconnect() {
    liveConnected = false;
    _notify();
    if (_disposed || phase != RemoteAppPhase.ready) return;
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
    unawaited(_eventSubscription?.cancel());
    unawaited(_eventClient.close());
    _api.close();
    super.dispose();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
