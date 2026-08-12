import '../../../core/database/app_database.dart';
import '../domain/project_aspect_ratio.dart';

class ProjectAspectRepository {
  const ProjectAspectRepository(this._database);

  static const modeSettingKey = 'projectAspectMode';
  static const detectedRatioSettingKey = 'projectDetectedAspectRatio';

  final AppDatabase _database;

  ProjectAspectState load() {
    return ProjectAspectState(
      mode: ProjectAspectMode.fromStorage(_database.getSetting(modeSettingKey)),
      detectedRatio: ProjectAspectRatio.fromStorage(
        _database.getSetting(detectedRatioSettingKey),
      ),
    );
  }

  void save(ProjectAspectState state) {
    _database
      ..setSetting(modeSettingKey, state.mode.name)
      ..setSetting(detectedRatioSettingKey, state.detectedRatio?.name ?? '');
  }
}
