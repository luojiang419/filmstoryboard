import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
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

  List<ReplicatedShotImage> listReplicatedShotImages(String runId) => _database
      .selectRows(
        'SELECT * FROM replicated_shot_images WHERE run_id = ? ORDER BY shot_number;',
        [runId],
      )
      .map(_replicatedShotImage)
      .toList();

  void upsertReplicatedShotImage(ReplicatedShotImage image) {
    _database.executeStatement(
      '''
      INSERT INTO replicated_shot_images(
        id, run_id, script_shot_id, shot_number, original_frame_path,
        generated_frame_path, asset_ids_json, prompt, model, raw_response,
        status, error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        original_frame_path = excluded.original_frame_path,
        generated_frame_path = excluded.generated_frame_path,
        asset_ids_json = excluded.asset_ids_json,
        prompt = excluded.prompt,
        model = excluded.model,
        raw_response = excluded.raw_response,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
      ''',
      [
        image.id,
        image.runId,
        image.scriptShotId,
        image.shotNumber,
        image.originalFramePath,
        image.generatedFramePath,
        jsonEncode(image.assetIds),
        image.prompt,
        image.model,
        image.rawResponse,
        image.status.name,
        image.errorMessage,
        image.createdAt.toUtc().toIso8601String(),
        image.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  ReplicatedShotImage _replicatedShotImage(Map<String, Object?> row) {
    final assetIds = jsonDecode(row['asset_ids_json'] as String? ?? '[]');
    DateTime date(Object? value) =>
        DateTime.tryParse(value as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return ReplicatedShotImage(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      scriptShotId: row['script_shot_id'] as String,
      shotNumber: row['shot_number'] as int,
      originalFramePath: row['original_frame_path'] as String? ?? '',
      generatedFramePath: row['generated_frame_path'] as String? ?? '',
      assetIds: assetIds is List
          ? assetIds.map((value) => '$value').toList()
          : const [],
      prompt: row['prompt'] as String? ?? '',
      model: row['model'] as String? ?? '',
      rawResponse: row['raw_response'] as String? ?? '',
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String? ?? '',
      createdAt: date(row['created_at']),
      updatedAt: date(row['updated_at']),
    );
  }
}
