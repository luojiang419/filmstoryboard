import 'package:uuid/uuid.dart';

import '../domain/remote_events.dart';
import '../domain/remote_video_generation_models.dart';
import 'remote_media_registry.dart';
import 'remote_task_registry.dart';
import 'remote_workspace_registry.dart';

class RemoteVideoGenerationRegistry {
  RemoteVideoGenerationRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    required RemoteMediaRegistry mediaRegistry,
    required RemoteTaskRegistry taskRegistry,
    Uuid uuid = const Uuid(),
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _taskRegistry = taskRegistry,
       _uuid = uuid;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final RemoteMediaRegistry _mediaRegistry;
  final RemoteTaskRegistry _taskRegistry;
  final Uuid _uuid;

  RemoteVideoGenerationSource? _source;
  String? _projectId;

  RemoteVideoGenerationSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    return _source;
  }

  void attach(RemoteVideoGenerationSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    source.addListener(_handleSourceChanged);
    _handleSourceChanged();
  }

  void detach({RemoteVideoGenerationSource? source}) {
    if (source != null && !identical(source, _source)) return;
    _source?.removeListener(_handleSourceChanged);
    _source = null;
    _projectId = null;
  }

  Map<String, Object?> options() => _optionsJson(_requireSource().options);

  Map<String, Object?> groups() => {
    'items': [for (final group in _requireSource().groups) _groupJson(group)],
  };

  Map<String, Object?> tasks() => {
    'items': [for (final task in _requireSource().tasks) _taskJson(task)],
  };

  Map<String, Object?> works() => {
    'items': [for (final task in _requireSource().works) _taskJson(task)],
  };

  Map<String, Object?> selectScript(String scriptId) {
    final currentSource = _requireSource();
    currentSource.selectScript(scriptId);
    return {
      'options': _optionsJson(currentSource.options),
      'groups': [for (final group in currentSource.groups) _groupJson(group)],
    };
  }

  RemoteTaskSnapshot start(RemoteVideoGenerationCommand command) {
    final currentSource = _requireSource();
    final operationId = _uuid.v4();
    return _taskRegistry.start(
      kind: 'videoGeneration',
      message: '等待本机生成视频',
      onCancel: () => currentSource.cancelOperation(operationId),
      runner: (execution) async {
        void reportProgress() {
          final progress = currentSource.operationProgress(operationId);
          execution.report(
            current: progress.current,
            total: progress.total,
            message: progress.message,
          );
        }

        currentSource.addListener(reportProgress);
        try {
          final result = await currentSource.startGeneration(
            command,
            operationId: operationId,
          );
          execution.throwIfCancellationRequested();
          reportProgress();
          final completed = result.tasks
              .where(
                (task) =>
                    task.status == 'completed' ||
                    task.status == 'partialCompleted',
              )
              .length;
          return {
            'taskIds': [for (final task in result.tasks) task.id],
            'completed': completed,
            'total': result.tasks.length,
            'tasks': [for (final task in result.tasks) _taskJson(task)],
          };
        } on RemoteVideoGenerationSourceException catch (error) {
          if (error.code == 'generation_cancelled') {
            throw const RemoteTaskCancelled();
          }
          rethrow;
        } finally {
          currentSource.removeListener(reportProgress);
        }
      },
    );
  }

  RemoteTaskSnapshot retry(String taskId) {
    final currentSource = _requireSource();
    final task = currentSource.taskById(taskId);
    if (task == null) {
      throw const RemoteVideoGenerationSourceException(
        'generation_task_not_found',
        '视频生成任务不存在',
      );
    }
    if (!const {'failed', 'canceled', 'timedOut'}.contains(task.status)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_task_not_retryable',
        '只有失败、取消或超时的视频生成任务可以重试',
      );
    }
    return start(
      RemoteVideoGenerationCommand(
        scriptId: task.scriptId,
        shotIds: [task.shotId],
      ),
    );
  }

  Future<Map<String, Object?>> cancelTask(String taskId) async {
    final currentSource = _requireSource();
    final task = currentSource.taskById(taskId);
    if (task == null) {
      throw const RemoteVideoGenerationSourceException(
        'generation_task_not_found',
        '视频生成任务不存在',
      );
    }
    if (const {
      'completed',
      'partialCompleted',
      'failed',
      'canceled',
    }.contains(task.status)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_task_not_cancellable',
        '该视频生成任务已经结束，不能取消',
      );
    }
    final cancelled = await currentSource.cancelTask(taskId);
    if (cancelled == null) {
      throw const RemoteVideoGenerationSourceException(
        'generation_task_not_found',
        '视频生成任务不存在',
      );
    }
    return _taskJson(cancelled);
  }

  RemoteVideoGenerationSource _requireSource() {
    final current = source;
    if (current == null) {
      throw const RemoteVideoGenerationSourceException(
        'video_generation_unavailable',
        '当前工程的视频生成控制器尚未就绪',
      );
    }
    return current;
  }

  void _handleSourceChanged() {
    final current = source;
    final projectId = _projectId;
    if (current == null || projectId == null) return;
    _changeBus.publish(
      type: 'videoGeneration.changed',
      projectId: projectId,
      data: {
        'taskCount': current.tasks.length,
        'workCount': current.works.length,
      },
    );
  }

  Map<String, Object?> _optionsJson(
    RemoteVideoGenerationOptionsRecord options,
  ) => {
    'scripts': [
      for (final script in options.scripts)
        {
          'id': script.id,
          'name': script.name,
          'status': script.status,
          'version': script.version,
          'isSelected': script.isSelected,
        },
    ],
    'selectedScriptId': options.selectedScriptId,
    'backend': {
      'kind': options.backendKind,
      'name': options.backendName,
      'ready': options.backendReady,
      'message': options.backendMessage,
    },
    'projectAspectRatio': options.projectAspectRatio,
    'models': [
      for (final model in options.models) {'id': model.id, 'name': model.name},
    ],
    'selectedModelId': options.selectedModelId,
    'parameters': [
      for (final parameter in options.parameters)
        {
          'key': parameter.key,
          'label': parameter.label,
          'component': parameter.component,
          'group': parameter.group,
          'value': parameter.value,
          'options': [
            for (final option in parameter.options)
              {'value': option.value, 'label': option.label},
          ],
          if (parameter.min != null) 'min': parameter.min,
          if (parameter.max != null) 'max': parameter.max,
          if (parameter.step != null) 'step': parameter.step,
        },
    ],
  };

  Map<String, Object?> _groupJson(RemoteVideoGenerationGroupRecord group) {
    final mediaId = _mediaRegistry.registerProjectFile(
      group.referenceImagePath,
    );
    return {
      'id': group.id,
      'scriptId': group.scriptId,
      'shotIds': group.shotIds,
      'shotNumbers': group.shotNumbers,
      'title': group.title,
      'durationSeconds': group.durationSeconds,
      'prompt': group.prompt,
      'promptMode': group.promptMode,
      'canGenerate': group.canGenerate,
      'isActive': group.isActive,
      if (mediaId != null)
        'referenceImageUrl': '/api/v1/media/$mediaId/content',
    };
  }

  Map<String, Object?> _taskJson(RemoteVideoGenerationTaskRecord task) {
    final mediaId = task.hasLocalResult
        ? _mediaRegistry.registerProjectFile(task.localPath)
        : null;
    return {
      'id': task.id,
      'scriptId': task.scriptId,
      'shotId': task.shotId,
      'shotNumber': task.shotNumber,
      'model': task.model,
      'parameters': task.parameters,
      'durationSeconds': task.durationSeconds,
      'promptMode': task.promptMode,
      'prompt': task.prompt,
      'status': task.status,
      'errorMessage': task.errorMessage,
      'hasLocalResult': task.hasLocalResult,
      if (mediaId != null) 'mediaUrl': '/api/v1/media/$mediaId/content',
      'createdAt': task.createdAt.toUtc().toIso8601String(),
      'updatedAt': task.updatedAt.toUtc().toIso8601String(),
      if (task.completedAt != null)
        'completedAt': task.completedAt!.toUtc().toIso8601String(),
    };
  }

  void dispose() => detach();
}
