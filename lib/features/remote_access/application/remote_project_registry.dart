import 'package:flutter/foundation.dart';

import '../domain/remote_events.dart';
import '../domain/remote_project_models.dart';

abstract interface class RemoteProjectSource implements Listenable {
  List<RemoteProjectRecord> get projects;
  String? get activeProjectId;
  bool get isTransitioning;

  Future<RemoteProjectOpenResult> openProject(String projectId);
}

class RemoteProjectRegistry {
  RemoteProjectRegistry({required RemoteChangeBus changeBus})
    : _changeBus = changeBus;

  final RemoteChangeBus _changeBus;
  RemoteProjectSource? _source;

  RemoteProjectSource? get source => _source;

  void attach(RemoteProjectSource source) {
    if (identical(_source, source)) return;
    _source?.removeListener(_handleChanged);
    _source = source;
    source.addListener(_handleChanged);
    _handleChanged();
  }

  void detach({RemoteProjectSource? source}) {
    final current = _source;
    if (current == null || (source != null && !identical(current, source))) {
      return;
    }
    current.removeListener(_handleChanged);
    _source = null;
    _handleChanged();
  }

  Map<String, Object?> collection() {
    final source = _requireSource();
    return {
      'activeProjectId': source.activeProjectId,
      'isTransitioning': source.isTransitioning,
      'items': [for (final project in source.projects) project.toJson()],
    };
  }

  Future<Map<String, Object?>> openProject(String projectId) async {
    final source = _requireSource();
    if (source.isTransitioning) {
      throw const RemoteProjectSourceException(
        'project_transition_busy',
        '桌面端正在切换工程，请稍后再试',
      );
    }
    return (await source.openProject(projectId)).toJson();
  }

  RemoteProjectSource _requireSource() {
    final source = _source;
    if (source == null) {
      throw const RemoteProjectSourceException(
        'project_catalog_unavailable',
        '桌面工程目录尚未就绪',
      );
    }
    return source;
  }

  void _handleChanged() {
    final source = _source;
    _changeBus.publish(
      type: 'projects.changed',
      projectId: source?.activeProjectId,
      data: {
        'activeProjectId': source?.activeProjectId,
        'isTransitioning': source?.isTransitioning ?? false,
      },
    );
  }
}
