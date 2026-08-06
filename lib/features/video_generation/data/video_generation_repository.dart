import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../domain/video_generation_models.dart';

class VideoGenerationRepository {
  const VideoGenerationRepository(this._database);

  final AppDatabase _database;

  VideoGenerationProfile? getProfile(String scriptId) {
    final rows = _database.selectRows(
      'SELECT * FROM video_generation_profiles WHERE script_id = ? LIMIT 1;',
      [scriptId],
    );
    return rows.isEmpty ? null : _profile(rows.single);
  }

  void upsertProfile(VideoGenerationProfile profile) {
    _database.executeStatement(
      '''
      INSERT INTO video_generation_profiles(
        script_id, model, parameters_json, prompt_mode,
        prefer_without_watermark, directory_name, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(script_id) DO UPDATE SET
        model = excluded.model,
        parameters_json = excluded.parameters_json,
        prompt_mode = excluded.prompt_mode,
        prefer_without_watermark = excluded.prefer_without_watermark,
        directory_name = excluded.directory_name,
        updated_at = excluded.updated_at;
      ''',
      [
        profile.scriptId,
        profile.model,
        jsonEncode(profile.parameters),
        profile.promptMode.name,
        profile.preferWithoutWatermark ? 1 : 0,
        profile.directoryName,
        profile.createdAt.toIso8601String(),
        profile.updatedAt.toIso8601String(),
      ],
    );
  }

  List<VideoGenerationDraft> listDrafts(String scriptId) => _database
      .selectRows(
        'SELECT * FROM video_generation_drafts WHERE script_id = ?;',
        [scriptId],
      )
      .map(_draft)
      .toList();

  void upsertDraft(VideoGenerationDraft draft) {
    _database.executeStatement(
      '''
      INSERT INTO video_generation_drafts(
        id, script_id, shot_id, source_prompt, kling_prompt,
        h3_prompt, edited_prompt, prompt_mode, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(shot_id) DO UPDATE SET
        source_prompt = excluded.source_prompt,
        kling_prompt = excluded.kling_prompt,
        h3_prompt = excluded.h3_prompt,
        edited_prompt = excluded.edited_prompt,
        prompt_mode = excluded.prompt_mode,
        updated_at = excluded.updated_at;
      ''',
      [
        draft.id,
        draft.scriptId,
        draft.shotId,
        draft.sourcePrompt,
        draft.klingPrompt,
        draft.h3Prompt,
        draft.editedPrompt,
        draft.promptMode.name,
        draft.updatedAt.toIso8601String(),
      ],
    );
  }

  VideoGenerationTask? getTask(String id) {
    final rows = _database.selectRows(
      'SELECT * FROM video_generation_tasks WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : _task(rows.single);
  }

  List<VideoGenerationTask> listTasks({String? scriptId, String? shotId}) {
    final clauses = <String>[];
    final parameters = <Object?>[];
    if (scriptId != null) {
      clauses.add('script_id = ?');
      parameters.add(scriptId);
    }
    if (shotId != null) {
      clauses.add('shot_id = ?');
      parameters.add(shotId);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return _database
        .selectRows(
          'SELECT * FROM video_generation_tasks $where ORDER BY created_at DESC;',
          parameters,
        )
        .map(_task)
        .toList();
  }

  List<VideoGenerationTask> listRecoverableTasks({
    bool includeTimedOut = true,
  }) {
    final statuses = includeTimedOut
        ? "'submitting', 'queued', 'running', 'timedOut'"
        : "'submitting', 'queued', 'running'";
    return _database
        .selectRows('''
        SELECT * FROM video_generation_tasks
        WHERE generation_id <> ''
          AND status IN ($statuses)
        ORDER BY updated_at;
      ''')
        .map(_task)
        .toList();
  }

  void upsertTask(VideoGenerationTask task) {
    _database.executeStatement(
      '''
      INSERT INTO video_generation_tasks(
        id, script_id, shot_id, generation_id, model, parameters_json,
        duration_seconds, prompt_mode, prompt_text, credits_before,
        credits_after, status, result_url, result_without_watermark_url,
        local_path, used_watermarked_fallback, error_message, created_at,
        updated_at, completed_at, tail_image_path
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        generation_id = excluded.generation_id,
        credits_before = excluded.credits_before,
        credits_after = excluded.credits_after,
        status = excluded.status,
        result_url = excluded.result_url,
        result_without_watermark_url = excluded.result_without_watermark_url,
        local_path = excluded.local_path,
        tail_image_path = excluded.tail_image_path,
        used_watermarked_fallback = excluded.used_watermarked_fallback,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at,
        completed_at = excluded.completed_at;
      ''',
      [
        task.id,
        task.scriptId,
        task.shotId,
        task.generationId,
        task.model,
        jsonEncode(task.parameters),
        task.durationSeconds,
        task.promptMode.name,
        task.prompt,
        task.creditsBefore,
        task.creditsAfter,
        task.status.name,
        task.resultUrl,
        task.resultWithoutWatermarkUrl,
        task.localPath,
        task.usedWatermarkedFallback ? 1 : 0,
        task.errorMessage,
        task.createdAt.toIso8601String(),
        task.updatedAt.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.tailImagePath,
      ],
    );
  }

  void deleteTask(String id) {
    _database.executeStatement(
      'DELETE FROM video_generation_tasks WHERE id = ?;',
      [id],
    );
  }

  VideoGenerationProfile _profile(Map<String, Object?> row) =>
      VideoGenerationProfile(
        scriptId: row['script_id'] as String,
        model: row['model'] as String? ?? '',
        parameters: _stringMap(row['parameters_json']),
        promptMode: _promptMode(row['prompt_mode']),
        preferWithoutWatermark:
            (row['prefer_without_watermark'] as int? ?? 1) != 0,
        directoryName: row['directory_name'] as String? ?? '',
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  VideoGenerationDraft _draft(Map<String, Object?> row) => VideoGenerationDraft(
    id: row['id'] as String,
    scriptId: row['script_id'] as String,
    shotId: row['shot_id'] as String,
    sourcePrompt: row['source_prompt'] as String? ?? '',
    klingPrompt: row['kling_prompt'] as String? ?? '',
    h3Prompt: row['h3_prompt'] as String? ?? '',
    editedPrompt: row['edited_prompt'] as String? ?? '',
    promptMode: _promptMode(row['prompt_mode']),
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );

  VideoGenerationTask _task(Map<String, Object?> row) => VideoGenerationTask(
    id: row['id'] as String,
    scriptId: row['script_id'] as String,
    shotId: row['shot_id'] as String,
    generationId: row['generation_id'] as String? ?? '',
    model: row['model'] as String,
    parameters: _stringMap(row['parameters_json']),
    durationSeconds: row['duration_seconds'] as int,
    promptMode: _promptMode(row['prompt_mode']),
    prompt: row['prompt_text'] as String,
    creditsBefore: row['credits_before'] as int?,
    creditsAfter: row['credits_after'] as int?,
    status: VideoGenerationTaskStatus.fromStorage(row['status']),
    resultUrl: row['result_url'] as String? ?? '',
    resultWithoutWatermarkUrl:
        row['result_without_watermark_url'] as String? ?? '',
    localPath: row['local_path'] as String? ?? '',
    tailImagePath: row['tail_image_path'] as String? ?? '',
    usedWatermarkedFallback:
        (row['used_watermarked_fallback'] as int? ?? 0) != 0,
    errorMessage: row['error_message'] as String? ?? '',
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    completedAt: row['completed_at'] == null
        ? null
        : DateTime.parse(row['completed_at'] as String),
  );

  Map<String, String> _stringMap(Object? value) {
    try {
      final decoded = jsonDecode(value as String? ?? '{}');
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', '$value'));
      }
    } catch (_) {
      // 旧数据或手工修改的非法 JSON 按空配置处理。
    }
    return const {};
  }

  VideoPromptMode _promptMode(Object? value) =>
      VideoPromptMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => VideoPromptMode.klingOptimized,
      );
}
