import 'dart:async';

import 'package:uuid/uuid.dart';

import '../domain/remote_events.dart';
import 'remote_workspace_registry.dart';

enum RemoteTaskStatus { queued, running, succeeded, failed, cancelled }

class RemoteTaskSnapshot {
  const RemoteTaskSnapshot({
    required this.id,
    required this.projectId,
    required this.kind,
    required this.status,
    required this.current,
    required this.total,
    required this.message,
    required this.errorCode,
    required this.errorMessage,
    required this.result,
    required this.createdAt,
    required this.updatedAt,
    required this.cancellable,
  });

  final String id;
  final String projectId;
  final String kind;
  final RemoteTaskStatus status;
  final int current;
  final int total;
  final String message;
  final String errorCode;
  final String errorMessage;
  final Map<String, Object?> result;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool cancellable;

  bool get terminal =>
      status == RemoteTaskStatus.succeeded ||
      status == RemoteTaskStatus.failed ||
      status == RemoteTaskStatus.cancelled;

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
    'kind': kind,
    'status': status.name,
    'progress': {'current': current, 'total': total},
    'message': message,
    if (errorCode.isNotEmpty)
      'error': {'code': errorCode, 'message': errorMessage},
    if (result.isNotEmpty) 'result': result,
    'cancellable': cancellable && !terminal,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class RemoteTaskExecution {
  RemoteTaskExecution._(this._registry, this.taskId);

  final RemoteTaskRegistry _registry;
  final String taskId;

  bool get isCancellationRequested =>
      _registry._isCancellationRequested(taskId);

  void report({required int current, required int total, String? message}) {
    _registry._report(taskId, current: current, total: total, message: message);
  }

  void throwIfCancellationRequested() {
    if (isCancellationRequested) throw const RemoteTaskCancelled();
  }
}

class RemoteTaskCancelled implements Exception {
  const RemoteTaskCancelled();
}

typedef RemoteTaskRunner =
    Future<Map<String, Object?>> Function(RemoteTaskExecution execution);
typedef RemoteTaskCancelCallback = FutureOr<void> Function();

class RemoteTaskRegistry {
  RemoteTaskRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    Uuid uuid = const Uuid(),
    DateTime Function()? now,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _uuid = uuid,
       _now = now ?? DateTime.now;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final Uuid _uuid;
  final DateTime Function() _now;
  final Map<String, _RemoteTaskState> _tasks = {};

  RemoteTaskSnapshot start({
    required String kind,
    required RemoteTaskRunner runner,
    RemoteTaskCancelCallback? onCancel,
    String message = '等待本机处理',
  }) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      throw StateError('桌面端当前没有打开工程');
    }
    _prune();
    final timestamp = _now().toUtc();
    final state = _RemoteTaskState(
      id: _uuid.v4(),
      projectId: workspace.projectId,
      kind: kind.trim(),
      status: RemoteTaskStatus.queued,
      message: message,
      createdAt: timestamp,
      updatedAt: timestamp,
      onCancel: onCancel,
    );
    _tasks[state.id] = state;
    _publish(state);
    unawaited(_run(state, runner));
    return state.snapshot;
  }

  List<RemoteTaskSnapshot> listCurrentProject() {
    final projectId = _workspaceRegistry.current?.projectId;
    if (projectId == null) return const [];
    _prune();
    final items = _tasks.values
        .where((task) => task.projectId == projectId)
        .map((task) => task.snapshot)
        .toList();
    items.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return items;
  }

  RemoteTaskSnapshot? getCurrentProject(String taskId) {
    final projectId = _workspaceRegistry.current?.projectId;
    final state = _tasks[taskId];
    return state != null && state.projectId == projectId
        ? state.snapshot
        : null;
  }

  Future<RemoteTaskSnapshot?> cancelCurrentProject(String taskId) async {
    final projectId = _workspaceRegistry.current?.projectId;
    final state = _tasks[taskId];
    if (state == null || state.projectId != projectId) return null;
    if (state.snapshot.terminal || state.onCancel == null) {
      return state.snapshot;
    }
    state
      ..cancellationRequested = true
      ..status = RemoteTaskStatus.cancelled
      ..message = '任务已取消'
      ..updatedAt = _now().toUtc();
    try {
      await state.onCancel!();
    } finally {
      _publish(state);
    }
    return state.snapshot;
  }

  Future<void> _run(_RemoteTaskState state, RemoteTaskRunner runner) async {
    if (state.status == RemoteTaskStatus.cancelled) return;
    state
      ..status = RemoteTaskStatus.running
      ..updatedAt = _now().toUtc();
    _publish(state);
    try {
      final result = await runner(RemoteTaskExecution._(this, state.id));
      if (state.status == RemoteTaskStatus.cancelled) return;
      state
        ..status = RemoteTaskStatus.succeeded
        ..result = result
        ..message = state.message.isEmpty ? '任务已完成' : state.message
        ..updatedAt = _now().toUtc();
    } on RemoteTaskCancelled {
      state
        ..status = RemoteTaskStatus.cancelled
        ..message = '任务已取消'
        ..updatedAt = _now().toUtc();
    } catch (error) {
      if (state.status == RemoteTaskStatus.cancelled) return;
      state
        ..status = RemoteTaskStatus.failed
        ..errorCode = 'task_failed'
        ..errorMessage = '$error'
        ..message = '任务执行失败'
        ..updatedAt = _now().toUtc();
    }
    _publish(state);
  }

  bool _isCancellationRequested(String taskId) =>
      _tasks[taskId]?.cancellationRequested ?? true;

  void _report(
    String taskId, {
    required int current,
    required int total,
    String? message,
  }) {
    final state = _tasks[taskId];
    if (state == null || state.snapshot.terminal) return;
    final safeTotal = total < 0 ? 0 : total;
    final safeCurrent = current < 0
        ? 0
        : safeTotal == 0
        ? current
        : current.clamp(0, safeTotal);
    state
      ..total = safeTotal
      ..current = safeCurrent
      ..message = message ?? state.message
      ..updatedAt = _now().toUtc();
    _publish(state);
  }

  void _publish(_RemoteTaskState state) {
    _changeBus.publish(
      type: 'task.changed',
      projectId: state.projectId,
      resourceId: state.id,
      data: state.snapshot.toJson(),
    );
  }

  void _prune() {
    final cutoff = _now().toUtc().subtract(const Duration(hours: 24));
    _tasks.removeWhere(
      (_, state) => state.snapshot.terminal && state.updatedAt.isBefore(cutoff),
    );
    if (_tasks.length <= 200) return;
    final terminal =
        _tasks.values.where((state) => state.snapshot.terminal).toList()
          ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (final state in terminal.take(_tasks.length - 200)) {
      _tasks.remove(state.id);
    }
  }
}

class _RemoteTaskState {
  _RemoteTaskState({
    required this.id,
    required this.projectId,
    required this.kind,
    required this.status,
    required this.message,
    required this.createdAt,
    required this.updatedAt,
    required this.onCancel,
  });

  final String id;
  final String projectId;
  final String kind;
  final DateTime createdAt;
  final RemoteTaskCancelCallback? onCancel;
  RemoteTaskStatus status;
  int current = 0;
  int total = 0;
  String message;
  String errorCode = '';
  String errorMessage = '';
  Map<String, Object?> result = const {};
  DateTime updatedAt;
  bool cancellationRequested = false;

  RemoteTaskSnapshot get snapshot => RemoteTaskSnapshot(
    id: id,
    projectId: projectId,
    kind: kind,
    status: status,
    current: current,
    total: total,
    message: message,
    errorCode: errorCode,
    errorMessage: errorMessage,
    result: result,
    createdAt: createdAt,
    updatedAt: updatedAt,
    cancellable: onCancel != null,
  );
}
