import '../../../core/database/app_database.dart';
import '../../projects/data/project_directories.dart';
import '../../projects/domain/project_models.dart';
import '../domain/remote_events.dart';

class RemoteWorkspaceContext {
  const RemoteWorkspaceContext({
    required this.projectId,
    required this.projectName,
    required this.database,
    required this.directories,
  });

  final String projectId;
  final String projectName;
  final AppDatabase database;
  final ProjectDirectories directories;

  factory RemoteWorkspaceContext.fromSession(ProjectSession session) =>
      RemoteWorkspaceContext(
        projectId: session.manifest.projectId,
        projectName: session.manifest.name,
        database: session.database,
        directories: session.directories,
      );
}

class RemoteWorkspaceRegistry {
  RemoteWorkspaceRegistry(this._changeBus);

  final RemoteChangeBus _changeBus;
  RemoteWorkspaceContext? _current;

  RemoteWorkspaceContext? get current => _current;

  void attach(ProjectSession session) {
    attachContext(RemoteWorkspaceContext.fromSession(session));
  }

  void attachContext(RemoteWorkspaceContext next) {
    if (_current?.projectId == next.projectId) return;
    _current = next;
    _changeBus.publish(
      type: 'workspace.opened',
      projectId: next.projectId,
      data: {'projectName': next.projectName},
    );
  }

  void detach({String? projectId}) {
    final current = _current;
    if (current == null ||
        (projectId != null && current.projectId != projectId)) {
      return;
    }
    _current = null;
    _changeBus.publish(type: 'workspace.closed', projectId: current.projectId);
  }
}
