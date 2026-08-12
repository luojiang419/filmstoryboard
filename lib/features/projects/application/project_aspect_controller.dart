import 'package:flutter/foundation.dart';

import '../data/project_aspect_repository.dart';
import '../domain/project_aspect_ratio.dart';

class ProjectAspectController extends ChangeNotifier {
  ProjectAspectController({required ProjectAspectRepository repository})
    : _repository = repository,
      state = repository.load();

  final ProjectAspectRepository _repository;
  ProjectAspectState state;

  void setMode(ProjectAspectMode mode) {
    if (state.mode == mode && state.detectedRatio == null) return;
    state = ProjectAspectState(mode: mode);
    _repository.save(state);
    notifyListeners();
  }

  ProjectAspectDetectionResult detectFromDimensions({
    required int width,
    required int height,
  }) {
    if (state.mode != ProjectAspectMode.auto ||
        width <= 0 ||
        height <= 0 ||
        width == height) {
      return ProjectAspectDetectionResult.unchanged;
    }
    final detected = ProjectAspectRatio.closestTo(width / height);
    final current = state.detectedRatio;
    if (current != null) {
      return current == detected
          ? ProjectAspectDetectionResult.unchanged
          : ProjectAspectDetectionResult.conflict;
    }
    state = state.copyWith(detectedRatio: detected);
    _repository.save(state);
    notifyListeners();
    return ProjectAspectDetectionResult.resolved;
  }
}
