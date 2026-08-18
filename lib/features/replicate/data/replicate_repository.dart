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

  void deletePromptsForShotIds(String runId, Iterable<String> shotIds) {
    final ids = shotIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    _database.executeStatement(
      'DELETE FROM shot_prompts '
      'WHERE run_id = ? AND script_shot_id IN ($placeholders);',
      [runId, ...ids],
    );
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

  String storyboardStory(String? boardId) {
    final normalizedBoardId = boardId?.trim() ?? '';
    if (normalizedBoardId.isEmpty) return '';
    final rows = _database.selectRows(
      'SELECT outline, content, scenes FROM storyboard_summaries '
      'WHERE board_id = ? LIMIT 1;',
      [normalizedBoardId],
    );
    if (rows.isEmpty) return '';
    final row = rows.first;
    final parts = <String>[];
    for (final column in const ['outline', 'content', 'scenes']) {
      final text = '${row[column] ?? ''}'.trim();
      if (text.isNotEmpty && !parts.contains(text)) parts.add(text);
    }
    return parts.join('\n\n');
  }

  Map<String, String> storyboardCaptionsForAssetIds(Iterable<String> assetIds) {
    final ids = assetIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _database.selectRows(
      'SELECT cut_result_id, caption FROM storyboard_items '
      'WHERE cut_result_id IN ($placeholders);',
      ids,
    );
    return {
      for (final row in rows)
        '${row['cut_result_id'] ?? ''}': '${row['caption'] ?? ''}'.trim(),
    };
  }

  ReplicateShotGuide? getShotGuide(String shotId) {
    final rows = _database.selectRows(
      'SELECT * FROM replicate_shot_guides WHERE shot_id = ? LIMIT 1;',
      [shotId],
    );
    return rows.isEmpty ? null : _shotGuide(rows.first);
  }

  List<ReplicateShotGuide> listShotGuidesForScript(String scriptId) => _database
      .selectRows(
        '''
            SELECT guide.*
            FROM replicate_shot_guides AS guide
            INNER JOIN script_shots AS shot ON shot.id = guide.shot_id
            WHERE shot.script_id = ?
            ORDER BY shot.shot_number;
            ''',
        [scriptId],
      )
      .map(_shotGuide)
      .toList();

  void upsertShotGuide(ReplicateShotGuide guide) {
    _database.executeStatement(
      '''
      INSERT INTO replicate_shot_guides(
        shot_id, source_frame_fingerprint, elements_json, subjects_json,
        full_outfit_assets_json, wearable_product_links_json,
        product_mark_authorizations_json, editable_pose_json,
        action_description, pose_constraints, person_count, skeleton_path, analysis_model,
        analysis_status, pose_status, raw_response, error_message,
        created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(shot_id) DO UPDATE SET
        source_frame_fingerprint = excluded.source_frame_fingerprint,
        elements_json = excluded.elements_json,
        subjects_json = excluded.subjects_json,
        full_outfit_assets_json = excluded.full_outfit_assets_json,
        wearable_product_links_json = excluded.wearable_product_links_json,
        product_mark_authorizations_json = excluded.product_mark_authorizations_json,
        editable_pose_json = excluded.editable_pose_json,
        action_description = excluded.action_description,
        pose_constraints = excluded.pose_constraints,
        person_count = excluded.person_count,
        skeleton_path = excluded.skeleton_path,
        analysis_model = excluded.analysis_model,
        analysis_status = excluded.analysis_status,
        pose_status = excluded.pose_status,
        raw_response = excluded.raw_response,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
      ''',
      [
        guide.shotId,
        guide.sourceFrameFingerprint,
        jsonEncode([for (final element in guide.elements) element.toJson()]),
        jsonEncode([for (final subject in guide.subjects) subject.toJson()]),
        jsonEncode([
          for (final asset in guide.fullOutfitAssets) asset.toJson(),
        ]),
        jsonEncode([
          for (final link in guide.wearableProductLinks) link.toJson(),
        ]),
        jsonEncode([
          for (final authorization in guide.productMarkAuthorizations)
            authorization.toJson(),
        ]),
        jsonEncode(guide.editablePose.toJson()),
        guide.actionDescription,
        guide.poseConstraints,
        guide.personCount,
        guide.skeletonPath,
        guide.analysisModel,
        guide.analysisStatus.name,
        guide.poseStatus.name,
        guide.rawResponse,
        guide.errorMessage,
        guide.createdAt.toUtc().toIso8601String(),
        guide.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  ReplicateShotGuide _shotGuide(Map<String, Object?> row) {
    Object? decodeColumn(String column, String fallback) {
      try {
        return jsonDecode(row[column] as String? ?? fallback);
      } on FormatException {
        return jsonDecode(fallback);
      }
    }

    List<T> decodeList<T>(
      String column,
      T Function(Map<String, Object?>) decode,
    ) {
      final value = decodeColumn(column, '[]');
      if (value is! List) return const [];
      return [
        for (final item in value)
          if (item is Map)
            decode(item.map((key, value) => MapEntry('$key', value))),
      ];
    }

    final decoded = decodeColumn('elements_json', '[]');
    final decodedSubjects = decodeColumn('subjects_json', '[]');
    final decodedPose = decodeColumn('editable_pose_json', '{}');
    DateTime date(Object? value) =>
        DateTime.tryParse(value as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return ReplicateShotGuide(
      shotId: row['shot_id'] as String,
      sourceFrameFingerprint: row['source_frame_fingerprint'] as String? ?? '',
      elements: decoded is List
          ? [
              for (final item in decoded)
                if (item is Map)
                  ReplicatePreservedElement.fromJson(
                    item.map((key, value) => MapEntry('$key', value)),
                  ),
            ]
          : const [],
      subjects: decodedSubjects is List
          ? [
              for (final item in decodedSubjects)
                if (item is Map)
                  ReplicateDetectedSubject.fromJson(
                    item.map((key, value) => MapEntry('$key', value)),
                  ),
            ]
          : const [],
      fullOutfitAssets: decodeList(
        'full_outfit_assets_json',
        ReplicateFullOutfitAsset.fromJson,
      ),
      wearableProductLinks: decodeList(
        'wearable_product_links_json',
        ReplicateWearableProductLink.fromJson,
      ),
      productMarkAuthorizations: decodeList(
        'product_mark_authorizations_json',
        ReplicateProductMarkAuthorization.fromJson,
      ),
      editablePose: decodedPose is Map
          ? ReplicateEditablePoseData.fromJson(
              decodedPose.map((key, value) => MapEntry('$key', value)),
            )
          : ReplicateEditablePoseData.empty,
      actionDescription: row['action_description'] as String? ?? '',
      poseConstraints: row['pose_constraints'] as String? ?? '',
      personCount: row['person_count'] as int? ?? 0,
      skeletonPath: row['skeleton_path'] as String? ?? '',
      analysisModel: row['analysis_model'] as String? ?? '',
      analysisStatus: ProcessingStatus.fromStorage(row['analysis_status']),
      poseStatus: ProcessingStatus.fromStorage(row['pose_status']),
      rawResponse: row['raw_response'] as String? ?? '',
      errorMessage: row['error_message'] as String? ?? '',
      createdAt: date(row['created_at']),
      updatedAt: date(row['updated_at']),
    );
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
        generation_recovery_json, status, error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        original_frame_path = excluded.original_frame_path,
        generated_frame_path = excluded.generated_frame_path,
        asset_ids_json = excluded.asset_ids_json,
        prompt = excluded.prompt,
        model = excluded.model,
        raw_response = excluded.raw_response,
        generation_recovery_json = excluded.generation_recovery_json,
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
        jsonEncode(image.generationRecovery.toJson()),
        image.status.name,
        image.errorMessage,
        image.createdAt.toUtc().toIso8601String(),
        image.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  ReplicatedShotImage _replicatedShotImage(Map<String, Object?> row) {
    final assetIds = jsonDecode(row['asset_ids_json'] as String? ?? '[]');
    ReplicatedShotGenerationRecovery recovery() {
      try {
        final decoded = jsonDecode(
          row['generation_recovery_json'] as String? ?? '{}',
        );
        if (decoded is Map) {
          return ReplicatedShotGenerationRecovery.fromJson(
            decoded.map((key, value) => MapEntry('$key', value)),
          );
        }
      } on FormatException {
        // 旧版或损坏的恢复状态不得阻止已生成图片继续加载。
      }
      return ReplicatedShotGenerationRecovery.empty;
    }

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
      generationRecovery: recovery(),
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String? ?? '',
      createdAt: date(row['created_at']),
      updatedAt: date(row['updated_at']),
    );
  }
}
