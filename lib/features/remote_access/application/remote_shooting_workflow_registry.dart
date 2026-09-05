import 'dart:async';

import '../domain/remote_events.dart';
import '../domain/remote_shooting_workflow_models.dart';
import 'remote_workspace_registry.dart';

class RemoteShootingWorkflowRegistry {
  RemoteShootingWorkflowRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  RemoteShootingWorkflowSource? _source;
  RemoteShootingWorkflowSource Function()? _sourceFactory;
  RemoteShootingWorkflowSource Function()? _factoryOwner;
  StreamSubscription<String>? _subscription;
  String? _projectId;

  RemoteShootingWorkflowSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    final factory = _sourceFactory;
    if (_source == null && factory != null) {
      _sourceFactory = null;
      try {
        attach(factory());
        _factoryOwner = factory;
      } catch (_) {
        _sourceFactory = factory;
        rethrow;
      }
    }
    return _source;
  }

  void attachDeferred(RemoteShootingWorkflowSource Function() factory) {
    detach();
    _projectId = _workspaceRegistry.current?.projectId;
    _sourceFactory = factory;
    _factoryOwner = factory;
  }

  void attach(RemoteShootingWorkflowSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    _subscription = source.changes.listen(_publishChanged);
  }

  void detach({
    RemoteShootingWorkflowSource? source,
    RemoteShootingWorkflowSource Function()? factory,
  }) {
    if (factory != null && factory != _factoryOwner) return;
    if (source != null && !identical(source, _source)) return;
    _sourceFactory = null;
    _factoryOwner = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _source = null;
    _projectId = null;
  }

  void _publishChanged(String scriptId) {
    final projectId = _projectId;
    if (projectId == null || source == null || scriptId.isEmpty) return;
    _changeBus.publish(
      type: 'shootingWorkflow.changed',
      projectId: projectId,
      resourceId: scriptId,
      data: const {'source': 'desktop'},
    );
  }

  void dispose() => detach();
}
