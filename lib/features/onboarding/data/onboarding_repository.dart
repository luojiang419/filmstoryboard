import '../../../core/database/app_database.dart';

class OnboardingRepository {
  const OnboardingRepository(this._database);

  static const completedVersionKey = 'onboardingCompletedVersion';
  static const currentVersion = 2;
  static const pendingVersion = 0;

  final AppDatabase _database;

  static void initializeInstallation({
    required AppDatabase database,
    required bool isFreshInstall,
  }) {
    if (database.getSetting(completedVersionKey) != null) {
      return;
    }
    database.setSetting(
      completedVersionKey,
      isFreshInstall ? '$pendingVersion' : '$currentVersion',
    );
  }

  bool get isFirstRunPending {
    final value = int.tryParse(
      _database.getSetting(completedVersionKey)?.trim() ?? '',
    );
    return value == pendingVersion;
  }

  int? get completedVersion =>
      int.tryParse(_database.getSetting(completedVersionKey)?.trim() ?? '');

  void markCompleted() {
    _database.setSetting(completedVersionKey, '$currentVersion');
  }
}
