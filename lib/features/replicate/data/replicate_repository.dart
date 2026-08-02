import '../../../core/database/app_database.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../domain/replicate_models.dart';

class ReplicateRepository {
  ReplicateRepository(AppDatabase database)
    : _database = database,
      _delegate = VideoAnalysisRepository(database);

  final AppDatabase _database;
  final VideoAnalysisRepository _delegate;

  ReplicateRun? getRun(String id) => _delegate.getReplicateRun(id);

  List<ReplicateRun> listRuns() => _delegate.listReplicateRuns();

  void upsertRun(ReplicateRun run) => _delegate.upsertReplicateRun(run);

  List<ReplicateAsset> listAssets(String runId) =>
      _delegate.listReplicateAssets(runId);

  void upsertAsset(ReplicateAsset asset) =>
      _delegate.upsertReplicateAsset(asset);

  void deleteAsset(String assetId) {
    _database.executeStatement('DELETE FROM replicate_assets WHERE id = ?;', [
      assetId,
    ]);
  }

  List<ShotPrompt> listPrompts(String runId) =>
      _delegate.listShotPrompts(runId);

  void upsertPrompt(ShotPrompt prompt) => _delegate.upsertShotPrompt(prompt);

  void deletePrompts(String runId) {
    _database.executeStatement('DELETE FROM shot_prompts WHERE run_id = ?;', [
      runId,
    ]);
  }

  void replacePrompts(String runId, List<ShotPrompt> prompts) {
    _database.executeStatement('BEGIN IMMEDIATE;');
    try {
      deletePrompts(runId);
      for (final prompt in prompts) {
        upsertPrompt(prompt);
      }
      _database.executeStatement('COMMIT;');
    } catch (_) {
      _database.executeStatement('ROLLBACK;');
      rethrow;
    }
  }
}
