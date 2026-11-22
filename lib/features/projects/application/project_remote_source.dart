import 'package:flutter/foundation.dart';

import '../../remote_access/application/remote_project_registry.dart';
import '../../remote_access/domain/remote_project_models.dart';
import '../domain/project_models.dart';
import 'project_workspace_controller.dart';

class ProjectRemoteSource extends ChangeNotifier
    implements RemoteProjectSource {
  ProjectRemoteSource(this._controller) {
    _controller.addListener(_handleControllerChanged);
  }

  final ProjectWorkspaceController _controller;

  @override
  String? get activeProjectId => _controller.session?.manifest.projectId;

  @override
  bool get isTransitioning =>
      _controller.phase == ProjectWorkspacePhase.booting ||
      _controller.phase == ProjectWorkspacePhase.opening;

  @override
  List<RemoteProjectRecord> get projects => [
    for (final entry in _controller.projects)
      RemoteProjectRecord(
        id: entry.projectId,
        name: entry.displayName,
        availability: _availability(entry.health),
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt,
        lastOpenedAt: entry.lastOpenedAt,
        isActive: entry.projectId == activeProjectId,
      ),
  ];

  @override
  Future<RemoteProjectOpenResult> openProject(String projectId) async {
    final normalizedId = projectId.trim();
    if (normalizedId.isEmpty) {
      throw const RemoteProjectSourceException('project_not_found', '工程不存在');
    }
    if (activeProjectId == normalizedId) {
      final current = _controller.session!;
      return RemoteProjectOpenResult(
        projectId: current.manifest.projectId,
        projectName: current.manifest.name,
        alreadyOpen: true,
      );
    }
    final entry = _controller.projects
        .where((item) => item.projectId == normalizedId)
        .firstOrNull;
    if (entry == null) {
      throw const RemoteProjectSourceException(
        'project_not_found',
        '工程不在本机项目列表中',
      );
    }
    if (!entry.exists) {
      throw RemoteProjectSourceException(
        'project_unavailable',
        switch (entry.health) {
          ProjectHealth.missing => '工程位置已失效，请先在桌面端重新定位',
          ProjectHealth.newerVersion => '工程由更高版本创建，请先更新桌面软件',
          _ => '工程索引损坏，请先在桌面端修复',
        },
      );
    }
    await _controller.switchToCatalogProject(entry);
    final opened = _controller.session;
    if (opened == null || opened.manifest.projectId != normalizedId) {
      throw const RemoteProjectSourceException(
        'project_open_failed',
        '桌面端未能打开所选工程',
      );
    }
    return RemoteProjectOpenResult(
      projectId: opened.manifest.projectId,
      projectName: opened.manifest.name,
      alreadyOpen: false,
    );
  }

  void _handleControllerChanged() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  static RemoteProjectAvailability _availability(ProjectHealth health) =>
      switch (health) {
        ProjectHealth.available => RemoteProjectAvailability.available,
        ProjectHealth.missing => RemoteProjectAvailability.missing,
        ProjectHealth.invalid => RemoteProjectAvailability.invalid,
        ProjectHealth.newerVersion => RemoteProjectAvailability.newerVersion,
      };
}
