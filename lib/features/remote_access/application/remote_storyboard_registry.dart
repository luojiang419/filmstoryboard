import 'dart:async';

import '../domain/remote_events.dart';
import '../domain/remote_storyboard_models.dart';
import 'remote_workspace_registry.dart';

class RemoteStoryboardRegistry {
  RemoteStoryboardRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final Map<String, int> _revisions = {};

  RemoteStoryboardSource? _source;
  StreamSubscription<RemoteStoryboardSourceChange>? _subscription;
  String? _projectId;
  String _changeSource = 'desktop';

  RemoteStoryboardSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    return _source;
  }

  bool get isAvailable => source != null;

  void attach(RemoteStoryboardSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    _revisions
      ..clear()
      ..addEntries(source.boards.map((board) => MapEntry(board.id, 1)));
    _subscription = source.changes.listen(_handleSourceChange);
  }

  void detach({RemoteStoryboardSource? source}) {
    if (source != null && !identical(source, _source)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _source = null;
    _projectId = null;
    _revisions.clear();
    _changeSource = 'desktop';
  }

  int revisionFor(String boardId) {
    final currentSource = source;
    if (currentSource?.boardById(boardId) == null) return 0;
    return _revisions.putIfAbsent(boardId, () => 1);
  }

  T performRemoteMutation<T>(T Function(RemoteStoryboardSource source) action) {
    final currentSource = source;
    if (currentSource == null) {
      throw StateError('故事板实时数据源尚未连接');
    }
    final previousSource = _changeSource;
    _changeSource = 'remote';
    try {
      return action(currentSource);
    } finally {
      _changeSource = previousSource;
    }
  }

  int publishAnnotationChanged(String boardId, {required String action}) {
    final currentSource = source;
    final projectId = _projectId;
    if (currentSource?.boardById(boardId) == null || projectId == null) {
      return 0;
    }
    final revision = _nextRevision(boardId);
    _changeBus.publish(
      type: 'storyboard.changed',
      projectId: projectId,
      resourceId: boardId,
      revision: revision,
      data: {'source': 'remote', 'change': 'annotation', 'action': action},
    );
    return revision;
  }

  void _handleSourceChange(RemoteStoryboardSourceChange change) {
    final projectId = _projectId;
    if (projectId == null || source == null) return;
    for (final boardId in change.boardIds) {
      final revision = _nextRevision(boardId);
      _changeBus.publish(
        type: 'storyboard.changed',
        projectId: projectId,
        resourceId: boardId,
        revision: revision,
        data: {'source': _changeSource, 'change': 'content'},
      );
      if (_source?.boardById(boardId) == null) {
        _revisions.remove(boardId);
      }
    }
    if (change.structureChanged) {
      _changeBus.publish(
        type: 'storyboards.changed',
        projectId: projectId,
        data: {'source': _changeSource},
      );
    }
  }

  int _nextRevision(String boardId) {
    final revision = (_revisions[boardId] ?? 0) + 1;
    _revisions[boardId] = revision;
    return revision;
  }

  void dispose() => detach();
}
