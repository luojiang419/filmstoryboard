import 'dart:async';

import '../domain/remote_events.dart';
import '../domain/remote_settings_models.dart';
import 'remote_workspace_registry.dart';

class RemoteSettingsRegistry {
  RemoteSettingsRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  RemoteSettingsSource? _source;
  StreamSubscription<void>? _subscription;
  String? _projectId;

  RemoteSettingsSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    return _source;
  }

  bool get isAvailable => source != null;

  void attach(RemoteSettingsSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    _subscription = source.changes.listen((_) => _publishChanged());
  }

  void detach({RemoteSettingsSource? source}) {
    if (source != null && !identical(source, _source)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _source = null;
    _projectId = null;
  }

  RemoteSettingsSnapshot read() {
    final current = source;
    if (current == null) throw StateError('设置实时数据源尚未连接');
    return current.snapshot;
  }

  Future<RemoteSettingsSnapshot> update(
    RemoteSettingsSelectionCommand command,
  ) async {
    final current = source;
    if (current == null) throw StateError('设置实时数据源尚未连接');
    await current.applySelection(command);
    return current.snapshot;
  }

  void _publishChanged() {
    final projectId = _projectId;
    if (projectId == null || source == null) return;
    _changeBus.publish(
      type: 'settings.changed',
      projectId: projectId,
      data: const {'source': 'desktop'},
    );
  }

  void dispose() => detach();
}
