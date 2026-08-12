import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/remote_events.dart';
import '../domain/remote_export_models.dart';
import 'remote_task_registry.dart';
import 'remote_workspace_registry.dart';

class RemoteExportArtifactResource {
  const RemoteExportArtifactResource({
    required this.id,
    required this.projectId,
    required this.file,
    required this.fileName,
    required this.contentType,
    required this.size,
    required this.previewable,
  });

  final String id;
  final String projectId;
  final File file;
  final String fileName;
  final String contentType;
  final int size;
  final bool previewable;

  Map<String, Object?> toJson() => {
    'id': id,
    'fileName': fileName,
    'contentType': contentType,
    'size': size,
    'previewable': previewable,
    'contentUrl': '/api/v1/exports/artifacts/$id/content',
    'downloadUrl': '/api/v1/exports/artifacts/$id/content?download=1',
  };
}

class RemoteExportRegistry {
  RemoteExportRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    required RemoteTaskRegistry taskRegistry,
    Uuid uuid = const Uuid(),
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _taskRegistry = taskRegistry,
       _uuid = uuid;

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final RemoteTaskRegistry _taskRegistry;
  final Uuid _uuid;
  final Map<String, RemoteExportArtifactResource> _artifacts = {};
  final Map<String, RemoteExportCommand> _commands = {};

  RemoteExportSource? _source;
  String? _projectId;

  RemoteExportSource? get source {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || workspace.projectId != _projectId) return null;
    return _source;
  }

  void attach(RemoteExportSource source) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) return;
    if (identical(_source, source) && _projectId == workspace.projectId) return;
    detach();
    _source = source;
    _projectId = workspace.projectId;
    source.addListener(_handleSourceChanged);
    _handleSourceChanged();
  }

  void detach({RemoteExportSource? source}) {
    if (source != null && !identical(source, _source)) return;
    _source?.removeListener(_handleSourceChanged);
    _source = null;
    _projectId = null;
  }

  Map<String, Object?> options() {
    final value = _requireSource().options;
    return {
      'storyboardFormats': const ['png', 'jpg', 'pdf'],
      'storyboardResolutions': const ['standard', 'sourceDetail'],
      'analysisReportFormats': const ['xlsx', 'pdf', 'png', 'jpg'],
      'boards': [
        for (final board in value.boards)
          {'id': board.id, 'name': board.name, 'itemCount': board.itemCount},
      ],
      'videos': [
        for (final video in value.videos) {'id': video.id, 'name': video.name},
      ],
      'scripts': [
        for (final script in value.scripts)
          {
            'id': script.id,
            'name': script.name,
            'timelineAvailable': script.timelineAvailable,
          },
      ],
      'defaults': {
        'storyboardFormat': 'png',
        'storyboardResolution': 'sourceDetail',
        'includeSummaryPage': value.includeSummaryPage,
        'analysisReportFormat': 'xlsx',
        'includeMultiDimensionAnalysis': value.includeMultiDimensionAnalysis,
        'includeShotDetails': value.includeShotDetails,
      },
    };
  }

  RemoteTaskSnapshot start(RemoteExportCommand command) {
    final currentSource = _requireSource();
    final workspace = _requireWorkspace();
    late final RemoteTaskSnapshot task;
    task = _taskRegistry.start(
      kind: 'export',
      message: '等待本机导出',
      onCancel: () {},
      runner: (execution) async {
        final outputDirectory = Directory(
          p.join(
            workspace.directories.exports.path,
            'remote-exports',
            execution.taskId,
          ),
        );
        try {
          final produced = await currentSource.export(
            command,
            outputDirectory: outputDirectory,
            onProgress: (current, total, message) => execution.report(
              current: current,
              total: total,
              message: message,
            ),
            isCancelled: () => execution.isCancellationRequested,
          );
          execution.throwIfCancellationRequested();
          final artifacts = await _registerArtifacts(
            projectId: workspace.projectId,
            exportRoot: workspace.directories.exports,
            produced: produced,
          );
          execution.throwIfCancellationRequested();
          _publishChanged(
            projectId: workspace.projectId,
            taskId: execution.taskId,
          );
          return {
            'exportKind': command.kind,
            'artifacts': [for (final artifact in artifacts) artifact.toJson()],
          };
        } on RemoteExportSourceException catch (error) {
          await _deleteDirectory(outputDirectory);
          if (error.code == 'export_cancelled') {
            throw const RemoteTaskCancelled();
          }
          rethrow;
        } on RemoteTaskCancelled {
          await _deleteDirectory(outputDirectory);
          rethrow;
        } catch (_) {
          await _deleteDirectory(outputDirectory);
          throw const RemoteExportSourceException(
            'export_failed',
            '本机导出失败，请在桌面端检查日志',
          );
        }
      },
    );
    _commands[task.id] = command;
    return task;
  }

  RemoteTaskSnapshot retry(String taskId) {
    final task = _taskRegistry.getCurrentProject(taskId);
    final command = _commands[taskId];
    if (task == null || command == null || task.kind != 'export') {
      throw const RemoteExportSourceException(
        'export_task_not_found',
        '导出任务不存在',
      );
    }
    if (task.status != RemoteTaskStatus.failed &&
        task.status != RemoteTaskStatus.cancelled) {
      throw const RemoteExportSourceException(
        'export_task_not_retryable',
        '只有失败或已取消的导出任务可以重试',
      );
    }
    return start(command);
  }

  RemoteExportArtifactResource? resolveArtifact(String artifactId) {
    final workspace = _workspaceRegistry.current;
    final resource = _artifacts[artifactId];
    if (workspace == null ||
        resource == null ||
        resource.projectId != workspace.projectId ||
        !resource.file.existsSync()) {
      return null;
    }
    final rootPath = _canonicalDirectory(workspace.directories.exports);
    final filePath = _canonicalFile(resource.file);
    if (!_isWithin(rootPath, filePath)) {
      _artifacts.remove(artifactId);
      return null;
    }
    return RemoteExportArtifactResource(
      id: resource.id,
      projectId: resource.projectId,
      file: File(filePath),
      fileName: resource.fileName,
      contentType: resource.contentType,
      size: resource.file.lengthSync(),
      previewable: resource.previewable,
    );
  }

  Future<List<RemoteExportArtifactResource>> _registerArtifacts({
    required String projectId,
    required Directory exportRoot,
    required List<RemoteExportProducedFile> produced,
  }) async {
    if (produced.isEmpty) {
      throw const RemoteExportSourceException(
        'export_empty_result',
        '导出任务没有生成文件',
      );
    }
    final rootPath = _canonicalDirectory(exportRoot);
    final artifacts = <RemoteExportArtifactResource>[];
    for (final output in produced) {
      final filePath = _canonicalFile(output.file);
      if (!output.file.existsSync() || !_isWithin(rootPath, filePath)) {
        throw const RemoteExportSourceException(
          'export_output_forbidden',
          '导出结果不在允许的目录内',
        );
      }
      final contentType = _contentType(filePath);
      if (contentType == null) {
        throw const RemoteExportSourceException(
          'export_output_type_forbidden',
          '导出结果的文件类型不允许下载',
        );
      }
      final artifact = RemoteExportArtifactResource(
        id: _uuid.v4(),
        projectId: projectId,
        file: File(filePath),
        fileName: p.basename(filePath),
        contentType: contentType,
        size: await File(filePath).length(),
        previewable: const {
          'application/pdf',
          'image/png',
          'image/jpeg',
        }.contains(contentType),
      );
      _artifacts[artifact.id] = artifact;
      artifacts.add(artifact);
    }
    return artifacts;
  }

  RemoteExportSource _requireSource() {
    final current = source;
    if (current == null) {
      throw const RemoteExportSourceException(
        'export_unavailable',
        '当前工程的导出服务尚未就绪',
      );
    }
    return current;
  }

  RemoteWorkspaceContext _requireWorkspace() {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      throw const RemoteExportSourceException(
        'workspace_unavailable',
        '桌面端当前没有打开工程',
      );
    }
    return workspace;
  }

  void _handleSourceChanged() {
    final projectId = _projectId;
    if (projectId != null) _publishChanged(projectId: projectId);
  }

  void _publishChanged({required String projectId, String? taskId}) {
    _changeBus.publish(
      type: 'export.changed',
      projectId: projectId,
      resourceId: taskId,
      data: {'taskId': ?taskId},
    );
  }

  Future<void> _deleteDirectory(Directory directory) async {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // 失败任务尽力清理；不会登记任何下载产物。
    }
  }

  static String _canonicalDirectory(Directory directory) {
    final absolute = directory.absolute;
    return absolute.existsSync()
        ? absolute.resolveSymbolicLinksSync()
        : p.normalize(absolute.path);
  }

  static String _canonicalFile(File file) {
    final absolute = file.absolute;
    return absolute.existsSync()
        ? absolute.resolveSymbolicLinksSync()
        : p.normalize(absolute.path);
  }

  static bool _isWithin(String rootPath, String filePath) {
    final normalizedRoot = p.normalize(rootPath).toLowerCase();
    final normalizedFile = p.normalize(filePath).toLowerCase();
    return p.isWithin(normalizedRoot, normalizedFile);
  }

  static String? _contentType(String path) =>
      switch (p.extension(path).toLowerCase()) {
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.pdf' => 'application/pdf',
        '.xlsx' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        '.xml' => 'application/xml',
        _ => null,
      };

  void dispose() => detach();
}
