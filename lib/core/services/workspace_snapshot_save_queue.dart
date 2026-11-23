import 'dart:async';

typedef WorkspaceSnapshotBuilder = String Function();
typedef WorkspaceSnapshotWriter = void Function(String snapshot);

class WorkspaceSnapshotSaveQueue {
  WorkspaceSnapshotSaveQueue({
    required WorkspaceSnapshotBuilder buildSnapshot,
    required WorkspaceSnapshotWriter writeSnapshot,
    this.defaultDelay = const Duration(milliseconds: 100),
  }) : _buildSnapshot = buildSnapshot,
       _writeSnapshot = writeSnapshot;

  final WorkspaceSnapshotBuilder _buildSnapshot;
  final WorkspaceSnapshotWriter _writeSnapshot;
  final Duration defaultDelay;

  Timer? _timer;
  var _revision = 0;
  var _persistedRevision = 0;
  var _isFlushing = false;
  var _disposed = false;

  bool get hasPendingSave => _persistedRevision < _revision;

  void markDirty({Duration? delay}) {
    if (_disposed) {
      return;
    }
    _revision++;
    _timer?.cancel();
    _timer = Timer(delay ?? defaultDelay, flush);
  }

  void flush() {
    if (_disposed || _isFlushing) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    _isFlushing = true;
    try {
      while (_persistedRevision < _revision) {
        final targetRevision = _revision;
        final snapshot = _buildSnapshot();
        if (targetRevision != _revision) {
          continue;
        }
        _writeSnapshot(snapshot);
        _persistedRevision = targetRevision;
      }
    } finally {
      _isFlushing = false;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    flush();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
