enum ProjectAspectMode {
  auto('自动检测'),
  landscape('16:9 横屏'),
  landscape4x3('4:3 横屏'),
  portrait3x4('3:4 竖屏'),
  portrait4x5('4:5 竖屏'),
  portrait('9:16 竖屏');

  const ProjectAspectMode(this.label);

  final String label;

  static ProjectAspectMode fromStorage(String? value) {
    return ProjectAspectMode.values.firstWhere(
      (item) => item.name == value,
      orElse: () => ProjectAspectMode.landscape,
    );
  }
}

enum ProjectAspectRatio {
  landscape16x9('16:9', 16 / 9),
  landscape4x3('4:3', 4 / 3),
  portrait3x4('3:4', 3 / 4),
  portrait4x5('4:5', 4 / 5),
  portrait9x16('9:16', 9 / 16);

  const ProjectAspectRatio(this.label, this.value);

  final String label;
  final double value;

  bool get isPortrait => value < 1;

  static ProjectAspectRatio closestTo(double value) {
    if (!value.isFinite || value <= 0) {
      return ProjectAspectRatio.landscape16x9;
    }
    var closest = ProjectAspectRatio.values.first;
    var closestDistance = (closest.value - value).abs();
    for (final candidate in ProjectAspectRatio.values.skip(1)) {
      final distance = (candidate.value - value).abs();
      if (distance < closestDistance) {
        closest = candidate;
        closestDistance = distance;
      }
    }
    return closest;
  }

  static ProjectAspectRatio? fromStorage(String? value) {
    for (final item in ProjectAspectRatio.values) {
      if (item.name == value) return item;
    }
    return null;
  }
}

class ProjectAspectState {
  const ProjectAspectState({required this.mode, this.detectedRatio});

  final ProjectAspectMode mode;
  final ProjectAspectRatio? detectedRatio;

  ProjectAspectRatio get effectiveRatio => switch (mode) {
    ProjectAspectMode.landscape => ProjectAspectRatio.landscape16x9,
    ProjectAspectMode.landscape4x3 => ProjectAspectRatio.landscape4x3,
    ProjectAspectMode.portrait3x4 => ProjectAspectRatio.portrait3x4,
    ProjectAspectMode.portrait4x5 => ProjectAspectRatio.portrait4x5,
    ProjectAspectMode.portrait => ProjectAspectRatio.portrait9x16,
    ProjectAspectMode.auto => detectedRatio ?? ProjectAspectRatio.landscape16x9,
  };

  bool get isAutoPending =>
      mode == ProjectAspectMode.auto && detectedRatio == null;

  ProjectAspectState copyWith({
    ProjectAspectMode? mode,
    ProjectAspectRatio? detectedRatio,
    bool clearDetectedRatio = false,
  }) {
    return ProjectAspectState(
      mode: mode ?? this.mode,
      detectedRatio: clearDetectedRatio
          ? null
          : detectedRatio ?? this.detectedRatio,
    );
  }
}

enum ProjectAspectDetectionResult { unchanged, resolved, conflict }
