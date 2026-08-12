import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../domain/video_analysis_models.dart';

class VideoAnalysisRepository {
  const VideoAnalysisRepository(this._database);

  static const _legacyOrientationRepairSetting =
      'videoOrientationMetadataRepairVersion';
  static const _legacyOrientationRepairVersion = '1';

  final AppDatabase _database;

  bool get isLegacyOrientationRepairCompleted =>
      _database.getSetting(_legacyOrientationRepairSetting) ==
      _legacyOrientationRepairVersion;

  void markLegacyOrientationRepairCompleted() {
    _database.setSetting(
      _legacyOrientationRepairSetting,
      _legacyOrientationRepairVersion,
    );
  }

  void upsertSourceVideo(SourceVideo video) {
    _database.executeStatement(
      '''
      INSERT INTO source_videos(
        id, original_path, file_name, stored_path, duration_ms, frame_rate,
        width, height, rotation_degrees, has_audio, frame_count, successful_frames,
        failed_frames, status, error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        original_path = excluded.original_path,
        file_name = excluded.file_name,
        stored_path = excluded.stored_path,
        duration_ms = excluded.duration_ms,
        frame_rate = excluded.frame_rate,
        width = excluded.width,
        height = excluded.height,
        rotation_degrees = excluded.rotation_degrees,
        has_audio = excluded.has_audio,
        frame_count = excluded.frame_count,
        successful_frames = excluded.successful_frames,
        failed_frames = excluded.failed_frames,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        video.id,
        video.originalPath,
        video.fileName,
        video.storedPath,
        video.durationMs,
        video.frameRate,
        video.width,
        video.height,
        video.rotationDegrees,
        video.hasAudio ? 1 : 0,
        video.frameCount,
        video.successfulFrames,
        video.failedFrames,
        video.status.name,
        video.errorMessage,
        _date(video.createdAt),
        _date(video.updatedAt),
      ],
    );
  }

  SourceVideo? getSourceVideo(String id) {
    final rows = _database.selectRows(
      'SELECT * FROM source_videos WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : _sourceVideo(rows.first);
  }

  List<SourceVideo> listSourceVideos() => _database
      .selectRows('SELECT * FROM source_videos ORDER BY created_at DESC;')
      .map(_sourceVideo)
      .toList();

  void deleteSourceVideo(String id) {
    _database.executeStatement('DELETE FROM source_videos WHERE id = ?;', [id]);
  }

  void deleteVideoShots(String videoId) {
    _database.executeStatement('DELETE FROM video_shots WHERE video_id = ?;', [
      videoId,
    ]);
  }

  void upsertVideoFrame(VideoFrame frame) {
    _database.executeStatement(
      '''
      INSERT INTO video_frames(
        id, video_id, index_no, timestamp_ms, path, width, height, sharpness,
        brightness, motion_score, perceptual_hash, is_focus, is_selected,
        status, error_message, created_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        index_no = excluded.index_no,
        timestamp_ms = excluded.timestamp_ms,
        path = excluded.path,
        width = excluded.width,
        height = excluded.height,
        sharpness = excluded.sharpness,
        brightness = excluded.brightness,
        motion_score = excluded.motion_score,
        perceptual_hash = excluded.perceptual_hash,
        is_focus = excluded.is_focus,
        is_selected = excluded.is_selected,
        status = excluded.status,
        error_message = excluded.error_message;
    ''',
      [
        frame.id,
        frame.videoId,
        frame.index,
        frame.timestampMs,
        frame.path,
        frame.width,
        frame.height,
        frame.sharpness,
        frame.brightness,
        frame.motionScore,
        frame.perceptualHash,
        frame.isFocus ? 1 : 0,
        frame.isSelected ? 1 : 0,
        frame.status.name,
        frame.errorMessage,
        _date(frame.createdAt),
      ],
    );
  }

  List<VideoFrame> listVideoFrames(String videoId) => _database
      .selectRows(
        'SELECT * FROM video_frames WHERE video_id = ? ORDER BY index_no;',
        [videoId],
      )
      .map(_videoFrame)
      .toList();

  void deleteVideoFrame(String frameId) {
    _database.executeStatement('DELETE FROM video_frames WHERE id = ?;', [
      frameId,
    ]);
  }

  void upsertVideoShot(VideoShot shot) {
    _database.executeStatement('BEGIN IMMEDIATE;');
    try {
      _database.executeStatement(
        '''
        INSERT INTO video_shots(
          id, video_id, shot_number, start_ms, end_ms, primary_frame_id,
          description, story_flow, status, created_at, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          shot_number = excluded.shot_number,
          start_ms = excluded.start_ms,
          end_ms = excluded.end_ms,
          primary_frame_id = excluded.primary_frame_id,
          description = excluded.description,
          story_flow = excluded.story_flow,
          status = excluded.status,
          updated_at = excluded.updated_at;
      ''',
        [
          shot.id,
          shot.videoId,
          shot.shotNumber,
          shot.startMs,
          shot.endMs,
          shot.primaryFrameId,
          shot.description,
          shot.storyFlow,
          shot.status.name,
          _date(shot.createdAt),
          _date(shot.updatedAt),
        ],
      );
      _database.executeStatement(
        'DELETE FROM video_shot_frames WHERE shot_id = ?;',
        [shot.id],
      );
      for (var index = 0; index < shot.frameIds.length; index++) {
        final frameId = shot.frameIds[index];
        _database.executeStatement(
          '''
          INSERT INTO video_shot_frames(shot_id, frame_id, position, is_primary)
          VALUES(?, ?, ?, ?);
        ''',
          [shot.id, frameId, index, frameId == shot.primaryFrameId ? 1 : 0],
        );
      }
      _database.executeStatement('COMMIT;');
    } catch (_) {
      _database.executeStatement('ROLLBACK;');
      rethrow;
    }
  }

  List<VideoShot> listVideoShots(String videoId) {
    final shots = _database.selectRows(
      'SELECT * FROM video_shots WHERE video_id = ? ORDER BY shot_number;',
      [videoId],
    );
    return shots.map((row) {
      final frameRows = _database.selectRows(
        '''
        SELECT frame_id FROM video_shot_frames
        WHERE shot_id = ? ORDER BY position;
      ''',
        [row['id']],
      );
      return _videoShot(
        row,
        frameRows.map((item) => item['frame_id'] as String),
      );
    }).toList();
  }

  void upsertMarketingAnalysis(MarketingAnalysis analysis) {
    _database.executeStatement(
      '''
      INSERT INTO marketing_analyses(
        id, video_id, scope, dimensions_json, raw_response, status,
        error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        scope = excluded.scope,
        dimensions_json = excluded.dimensions_json,
        raw_response = excluded.raw_response,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        analysis.id,
        analysis.videoId,
        analysis.scope,
        jsonEncode(analysis.dimensions),
        analysis.rawResponse,
        analysis.status.name,
        analysis.errorMessage,
        _date(analysis.createdAt),
        _date(analysis.updatedAt),
      ],
    );
  }

  List<MarketingAnalysis> listMarketingAnalyses(String videoId) => _database
      .selectRows(
        'SELECT * FROM marketing_analyses WHERE video_id = ? ORDER BY scope;',
        [videoId],
      )
      .map(_marketingAnalysis)
      .toList();

  void deleteMarketingAnalyses(String videoId) {
    _database.executeStatement(
      'DELETE FROM marketing_analyses WHERE video_id = ?;',
      [videoId],
    );
  }

  void upsertVideoFrameAnalysis(VideoFrameAnalysis analysis) {
    _database.executeStatement(
      '''
      INSERT INTO video_frame_analyses(
        id, video_id, frame_id, sequence_no, dimensions_json, raw_response,
        status, error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(video_id, frame_id) DO UPDATE SET
        sequence_no = excluded.sequence_no,
        dimensions_json = excluded.dimensions_json,
        raw_response = excluded.raw_response,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        analysis.id,
        analysis.videoId,
        analysis.frameId,
        analysis.sequenceNo,
        jsonEncode(analysis.dimensions),
        analysis.rawResponse,
        analysis.status.name,
        analysis.errorMessage,
        _date(analysis.createdAt),
        _date(analysis.updatedAt),
      ],
    );
  }

  List<VideoFrameAnalysis> listVideoFrameAnalyses(String videoId) => _database
      .selectRows(
        'SELECT * FROM video_frame_analyses WHERE video_id = ? ORDER BY sequence_no;',
        [videoId],
      )
      .map(_videoFrameAnalysis)
      .toList();

  void deleteVideoFrameAnalyses(String videoId) {
    _database.executeStatement(
      'DELETE FROM video_frame_analyses WHERE video_id = ?;',
      [videoId],
    );
  }

  Map<String, VideoFrameAnalysis> completedFrameAnalysesByFrameIds(
    Iterable<String> frameIds,
  ) {
    final ids = frameIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) {
      return const {};
    }
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _database.selectRows(
      '''
      SELECT * FROM video_frame_analyses
      WHERE frame_id IN ($placeholders) AND status = ?
      ORDER BY sequence_no;
      ''',
      [...ids, ProcessingStatus.completed.name],
    );
    return {
      for (final analysis in rows.map(_videoFrameAnalysis))
        analysis.frameId: analysis,
    };
  }

  Map<String, String> videoShotStoryFlowByFrameIds(Iterable<String> frameIds) {
    final ids = frameIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) {
      return const {};
    }
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _database.selectRows('''
      SELECT vsf.frame_id AS frame_id, vs.story_flow AS story_flow
      FROM video_shot_frames vsf
      INNER JOIN video_shots vs ON vs.id = vsf.shot_id
      WHERE vsf.frame_id IN ($placeholders);
      ''', ids.toList());
    return {
      for (final row in rows)
        row['frame_id'] as String: row['story_flow'] as String? ?? '',
    };
  }

  void upsertVideoSummary(VideoSummary summary) {
    _database.executeStatement(
      '''
      INSERT INTO video_summaries(
        id, video_id, fields_json, raw_response, status, error_message,
        updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(video_id) DO UPDATE SET
        id = excluded.id,
        fields_json = excluded.fields_json,
        raw_response = excluded.raw_response,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        summary.id,
        summary.videoId,
        jsonEncode(summary.fields),
        summary.rawResponse,
        summary.status.name,
        summary.errorMessage,
        _date(summary.updatedAt),
      ],
    );
  }

  VideoSummary? getVideoSummary(String videoId) {
    final rows = _database.selectRows(
      'SELECT * FROM video_summaries WHERE video_id = ? LIMIT 1;',
      [videoId],
    );
    return rows.isEmpty ? null : _videoSummary(rows.first);
  }

  void deleteVideoSummary(String videoId) {
    _database.executeStatement(
      'DELETE FROM video_summaries WHERE video_id = ?;',
      [videoId],
    );
  }

  void upsertShootingScript(ShootingScript script) {
    _database.executeStatement(
      '''
      INSERT INTO shooting_scripts(
        id, name, source_storyboard_id, source_video_id, status, version,
        created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        source_storyboard_id = excluded.source_storyboard_id,
        source_video_id = excluded.source_video_id,
        status = excluded.status,
        version = excluded.version,
        updated_at = excluded.updated_at;
    ''',
      [
        script.id,
        script.name,
        script.sourceStoryboardId,
        script.sourceVideoId,
        script.status.name,
        script.version,
        _date(script.createdAt),
        _date(script.updatedAt),
      ],
    );
  }

  List<ShootingScript> listShootingScripts() => _database
      .selectRows('SELECT * FROM shooting_scripts ORDER BY updated_at DESC;')
      .map(_shootingScript)
      .toList();

  void upsertScriptShot(ScriptShot shot) {
    _database.executeStatement(
      '''
      INSERT INTO script_shots(
        id, script_id, source_video_frame_id, shot_number, duration_seconds, frame_path, visual,
        content, free_creation_description, shot_size, camera_movement, camera_notes, composition,
        camera_angle, lighting_mood, color_palette, visual_focus,
        transition_hint, movement_trend, action_stage, continues_from_previous,
        continues_to_next, scene, product_code, product_styling, dialogue,
        sound, prompt, replication_instructions, status, updated_at
      ) VALUES(
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
      ON CONFLICT(id) DO UPDATE SET
        shot_number = excluded.shot_number,
        duration_seconds = excluded.duration_seconds,
        frame_path = excluded.frame_path,
        visual = excluded.visual,
        content = excluded.content,
        free_creation_description = excluded.free_creation_description,
        shot_size = excluded.shot_size,
        camera_movement = excluded.camera_movement,
        camera_notes = excluded.camera_notes,
        composition = excluded.composition,
        camera_angle = excluded.camera_angle,
        lighting_mood = excluded.lighting_mood,
        color_palette = excluded.color_palette,
        visual_focus = excluded.visual_focus,
        transition_hint = excluded.transition_hint,
        movement_trend = excluded.movement_trend,
        action_stage = excluded.action_stage,
        continues_from_previous = excluded.continues_from_previous,
        continues_to_next = excluded.continues_to_next,
        scene = excluded.scene,
        product_code = excluded.product_code,
        product_styling = excluded.product_styling,
        dialogue = excluded.dialogue,
        sound = excluded.sound,
        prompt = excluded.prompt,
        replication_instructions = excluded.replication_instructions,
        status = excluded.status,
        updated_at = excluded.updated_at;
    ''',
      [
        shot.id,
        shot.scriptId,
        shot.sourceVideoFrameId,
        shot.shotNumber,
        shot.durationSeconds,
        shot.framePath,
        shot.visual,
        shot.content,
        shot.freeCreationDescription,
        shot.shotSize,
        shot.cameraMovement,
        shot.cameraNotes,
        shot.composition,
        shot.cameraAngle,
        shot.lightingMood,
        shot.colorPalette,
        shot.visualFocus,
        shot.transitionHint,
        shot.movementTrend,
        shot.actionStage,
        shot.continuesFromPrevious ? 1 : 0,
        shot.continuesToNext ? 1 : 0,
        shot.scene,
        shot.productCode,
        shot.productStyling,
        shot.dialogue,
        shot.sound,
        shot.prompt,
        shot.replicationInstructions,
        shot.status.name,
        _date(shot.updatedAt),
      ],
    );
  }

  List<ScriptShot> listScriptShots(String scriptId) => _database
      .selectRows(
        'SELECT * FROM script_shots WHERE script_id = ? ORDER BY shot_number;',
        [scriptId],
      )
      .map(_scriptShot)
      .toList();

  void upsertReplicateRun(ReplicateRun run) {
    _database.executeStatement(
      '''
      INSERT INTO replicate_runs(
        id, video_id, script_id, global_style, constraints_text,
        replication_instructions, free_creation_enabled, free_creation_story_override,
        generation_model, generation_aspect_ratio, generation_image_size,
        generation_quality,
        confirmed_shot_ids_json,
        image_reference_count, video_reference_count,
        audio_reference_count, current_step, status, confirm_shots_status,
        prepare_assets_status, compose_prompts_status, completed_count,
        generate_videos_status,
        total_count, error_message, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        video_id = excluded.video_id,
        script_id = excluded.script_id,
        global_style = excluded.global_style,
        constraints_text = excluded.constraints_text,
        replication_instructions = excluded.replication_instructions,
        free_creation_enabled = excluded.free_creation_enabled,
        free_creation_story_override = excluded.free_creation_story_override,
        generation_model = excluded.generation_model,
        generation_aspect_ratio = excluded.generation_aspect_ratio,
        generation_image_size = excluded.generation_image_size,
        generation_quality = excluded.generation_quality,
        confirmed_shot_ids_json = excluded.confirmed_shot_ids_json,
        image_reference_count = excluded.image_reference_count,
        video_reference_count = excluded.video_reference_count,
        audio_reference_count = excluded.audio_reference_count,
        current_step = excluded.current_step,
        status = excluded.status,
        confirm_shots_status = excluded.confirm_shots_status,
        prepare_assets_status = excluded.prepare_assets_status,
        compose_prompts_status = excluded.compose_prompts_status,
        generate_videos_status = excluded.generate_videos_status,
        completed_count = excluded.completed_count,
        total_count = excluded.total_count,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        run.id,
        run.videoId,
        run.scriptId ?? '',
        run.globalStyle,
        run.constraints,
        run.replicationInstructions,
        run.freeCreationEnabled ? 1 : 0,
        run.freeCreationStoryOverride,
        run.generationModel,
        run.generationAspectRatio,
        run.generationImageSize,
        run.generationQuality,
        jsonEncode(run.confirmedShotIds),
        run.imageReferenceCount,
        run.videoReferenceCount,
        run.audioReferenceCount,
        run.currentStep.name,
        run.status.name,
        run.confirmShotsStatus.name,
        run.prepareAssetsStatus.name,
        run.composePromptsStatus.name,
        run.completedCount,
        run.generateVideosStatus.name,
        run.totalCount,
        run.errorMessage,
        _date(run.createdAt),
        _date(run.updatedAt),
      ],
    );
  }

  ReplicateRun? getReplicateRun(String id) {
    final rows = _database.selectRows(
      'SELECT * FROM replicate_runs WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : _replicateRun(rows.first);
  }

  List<ReplicateRun> listReplicateRuns() => _database
      .selectRows('SELECT * FROM replicate_runs ORDER BY updated_at DESC;')
      .map(_replicateRun)
      .toList();

  void upsertReplicateAsset(ReplicateAsset asset) {
    _database.executeStatement(
      '''
      INSERT INTO replicate_assets(
        id, run_id, asset_type, name, description, path, reference_number,
        status, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        asset_type = excluded.asset_type,
        name = excluded.name,
        description = excluded.description,
        path = excluded.path,
        reference_number = excluded.reference_number,
        status = excluded.status,
        updated_at = excluded.updated_at;
    ''',
      [
        asset.id,
        asset.runId,
        asset.type.name,
        asset.name,
        asset.description,
        asset.path,
        asset.referenceNumber,
        asset.status.name,
        _date(asset.createdAt),
        _date(asset.updatedAt),
      ],
    );
  }

  List<ReplicateAsset> listReplicateAssets(String runId) => _database
      .selectRows(
        'SELECT * FROM replicate_assets WHERE run_id = ? ORDER BY reference_number;',
        [runId],
      )
      .map(_replicateAsset)
      .toList();

  void upsertShotPrompt(ShotPrompt prompt) {
    _database.executeStatement(
      '''
      INSERT INTO shot_prompts(
        id, run_id, shot_number, script_shot_id, asset_ids_json, prompt,
        model, raw_response, is_user_edited, status, error_message, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        shot_number = excluded.shot_number,
        script_shot_id = excluded.script_shot_id,
        asset_ids_json = excluded.asset_ids_json,
        prompt = excluded.prompt,
        model = excluded.model,
        raw_response = excluded.raw_response,
        is_user_edited = excluded.is_user_edited,
        status = excluded.status,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
    ''',
      [
        prompt.id,
        prompt.runId,
        prompt.shotNumber,
        prompt.scriptShotId,
        jsonEncode(prompt.assetIds),
        prompt.prompt,
        prompt.model,
        prompt.rawResponse,
        prompt.isUserEdited ? 1 : 0,
        prompt.status.name,
        prompt.errorMessage,
        _date(prompt.updatedAt),
      ],
    );
  }

  List<ShotPrompt> listShotPrompts(String runId) => _database
      .selectRows(
        'SELECT * FROM shot_prompts WHERE run_id = ? ORDER BY shot_number;',
        [runId],
      )
      .map(_shotPrompt)
      .toList();

  String _date(DateTime value) => value.toUtc().toIso8601String();

  DateTime _parseDate(Object? value) =>
      DateTime.tryParse(value as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  SourceVideo _sourceVideo(Map<String, Object?> row) => SourceVideo(
    id: row['id'] as String,
    originalPath: row['original_path'] as String,
    fileName: row['file_name'] as String,
    storedPath: row['stored_path'] as String,
    durationMs: row['duration_ms'] as int,
    frameRate: (row['frame_rate'] as num).toDouble(),
    width: row['width'] as int,
    height: row['height'] as int,
    rotationDegrees: row['rotation_degrees'] as int? ?? 0,
    hasAudio: row['has_audio'] == 1,
    frameCount: row['frame_count'] as int,
    successfulFrames: row['successful_frames'] as int,
    failedFrames: row['failed_frames'] as int,
    status: ProcessingStatus.fromStorage(row['status']),
    errorMessage: row['error_message'] as String,
    createdAt: _parseDate(row['created_at']),
    updatedAt: _parseDate(row['updated_at']),
  );

  VideoFrame _videoFrame(Map<String, Object?> row) => VideoFrame(
    id: row['id'] as String,
    videoId: row['video_id'] as String,
    index: row['index_no'] as int,
    timestampMs: row['timestamp_ms'] as int,
    path: row['path'] as String,
    width: row['width'] as int,
    height: row['height'] as int,
    sharpness: (row['sharpness'] as num).toDouble(),
    brightness: (row['brightness'] as num).toDouble(),
    motionScore: (row['motion_score'] as num).toDouble(),
    perceptualHash: row['perceptual_hash'] as String,
    isFocus: row['is_focus'] == 1,
    isSelected: row['is_selected'] == 1,
    status: ProcessingStatus.fromStorage(row['status']),
    errorMessage: row['error_message'] as String,
    createdAt: _parseDate(row['created_at']),
  );

  VideoShot _videoShot(Map<String, Object?> first, Iterable<String> ids) {
    return VideoShot(
      id: first['id'] as String,
      videoId: first['video_id'] as String,
      shotNumber: first['shot_number'] as int,
      startMs: first['start_ms'] as int,
      endMs: first['end_ms'] as int,
      primaryFrameId: first['primary_frame_id'] as String?,
      frameIds: ids.toList(),
      description: first['description'] as String,
      storyFlow: first['story_flow'] as String,
      status: ProcessingStatus.fromStorage(first['status']),
      createdAt: _parseDate(first['created_at']),
      updatedAt: _parseDate(first['updated_at']),
    );
  }

  MarketingAnalysis _marketingAnalysis(Map<String, Object?> row) {
    final decoded = jsonDecode(row['dimensions_json'] as String);
    final dimensions = decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', '$value'))
        : <String, String>{};
    return MarketingAnalysis(
      id: row['id'] as String,
      videoId: row['video_id'] as String,
      scope: row['scope'] as String,
      dimensions: dimensions,
      rawResponse: row['raw_response'] as String,
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String,
      createdAt: _parseDate(row['created_at']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  VideoFrameAnalysis _videoFrameAnalysis(Map<String, Object?> row) {
    final decoded = jsonDecode(row['dimensions_json'] as String);
    final dimensions = decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', '$value'))
        : <String, String>{};
    return VideoFrameAnalysis(
      id: row['id'] as String,
      videoId: row['video_id'] as String,
      frameId: row['frame_id'] as String,
      sequenceNo: row['sequence_no'] as int,
      dimensions: dimensions,
      rawResponse: row['raw_response'] as String,
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String,
      createdAt: _parseDate(row['created_at']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  VideoSummary _videoSummary(Map<String, Object?> row) {
    final decoded = jsonDecode(row['fields_json'] as String);
    final fields = decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', '$value'))
        : <String, String>{};
    return VideoSummary(
      id: row['id'] as String,
      videoId: row['video_id'] as String,
      fields: fields,
      rawResponse: row['raw_response'] as String,
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String,
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  ShootingScript _shootingScript(Map<String, Object?> row) => ShootingScript(
    id: row['id'] as String,
    name: row['name'] as String,
    sourceStoryboardId: row['source_storyboard_id'] as String?,
    sourceVideoId: row['source_video_id'] as String?,
    status: ShootingScriptStatus.values.firstWhere(
      (value) => value.name == row['status'],
      orElse: () => ShootingScriptStatus.draft,
    ),
    version: row['version'] as int,
    createdAt: _parseDate(row['created_at']),
    updatedAt: _parseDate(row['updated_at']),
  );

  ScriptShot _scriptShot(Map<String, Object?> row) {
    final legacy = ScriptShotVisualFields.fromLegacyCameraNotes(
      row['camera_notes'] as String? ?? '',
    );
    String text(String column) => row[column] as String? ?? '';
    String valueOrLegacy(String column, String legacyValue) {
      final value = text(column);
      return value.trim().isEmpty ? legacyValue : value;
    }

    return ScriptShot(
      id: row['id'] as String,
      scriptId: row['script_id'] as String,
      sourceStoryboardAssetId: row['source_storyboard_asset_id'] as String?,
      sourceVideoFrameId: row['source_video_frame_id'] as String?,
      shotNumber: row['shot_number'] as int,
      durationSeconds: (row['duration_seconds'] as num).toDouble(),
      framePath: row['frame_path'] as String,
      visual: row['visual'] as String,
      content: row['content'] as String,
      freeCreationDescription: text('free_creation_description'),
      shotSize: row['shot_size'] as String,
      cameraMovement: row['camera_movement'] as String,
      cameraNotes: legacy.cameraNotes,
      composition: valueOrLegacy('composition', legacy.composition),
      cameraAngle: valueOrLegacy('camera_angle', legacy.cameraAngle),
      lightingMood: valueOrLegacy('lighting_mood', legacy.lightingMood),
      colorPalette: valueOrLegacy('color_palette', legacy.colorPalette),
      visualFocus: valueOrLegacy('visual_focus', legacy.visualFocus),
      transitionHint: valueOrLegacy('transition_hint', legacy.transitionHint),
      movementTrend: text('movement_trend'),
      actionStage: text('action_stage'),
      continuesFromPrevious: (row['continues_from_previous'] as int? ?? 0) != 0,
      continuesToNext: (row['continues_to_next'] as int? ?? 0) != 0,
      scene: row['scene'] as String,
      productCode: row['product_code'] as String,
      productStyling: row['product_styling'] as String,
      dialogue: row['dialogue'] as String,
      sound: row['sound'] as String,
      prompt: row['prompt'] as String,
      replicationInstructions: text('replication_instructions'),
      status: ProcessingStatus.fromStorage(row['status']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  ReplicateRun _replicateRun(Map<String, Object?> row) {
    final confirmedJson = jsonDecode(
      row['confirmed_shot_ids_json'] as String? ?? '[]',
    );
    return ReplicateRun(
      id: row['id'] as String,
      videoId: row['video_id'] as String?,
      scriptId: (row['script_id'] as String?)?.trim().isEmpty == true
          ? null
          : row['script_id'] as String?,
      globalStyle: row['global_style'] as String? ?? '',
      constraints: row['constraints_text'] as String? ?? '',
      replicationInstructions: row['replication_instructions'] as String? ?? '',
      freeCreationEnabled: (row['free_creation_enabled'] as int? ?? 0) != 0,
      freeCreationStoryOverride:
          row['free_creation_story_override'] as String? ?? '',
      generationModel: row['generation_model'] as String? ?? '',
      generationAspectRatio:
          row['generation_aspect_ratio'] as String? ?? '16:9',
      generationImageSize: row['generation_image_size'] as String? ?? '',
      generationQuality: row['generation_quality'] as String? ?? '',
      confirmedShotIds: confirmedJson is List
          ? confirmedJson.map((value) => '$value').toList()
          : const [],
      imageReferenceCount: row['image_reference_count'] as int? ?? 0,
      videoReferenceCount: row['video_reference_count'] as int? ?? 0,
      audioReferenceCount: row['audio_reference_count'] as int? ?? 0,
      currentStep: ReplicateStep.values.firstWhere(
        (value) => value.name == row['current_step'],
        orElse: () => ReplicateStep.confirmShots,
      ),
      status: ProcessingStatus.fromStorage(row['status']),
      confirmShotsStatus: ProcessingStatus.fromStorage(
        row['confirm_shots_status'],
      ),
      prepareAssetsStatus: ProcessingStatus.fromStorage(
        row['prepare_assets_status'],
      ),
      composePromptsStatus: ProcessingStatus.fromStorage(
        row['compose_prompts_status'],
      ),
      generateVideosStatus: ProcessingStatus.fromStorage(
        row['generate_videos_status'],
      ),
      completedCount: row['completed_count'] as int,
      totalCount: row['total_count'] as int,
      errorMessage: row['error_message'] as String,
      createdAt: _parseDate(row['created_at']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  ReplicateAsset _replicateAsset(Map<String, Object?> row) => ReplicateAsset(
    id: row['id'] as String,
    runId: row['run_id'] as String,
    type: ReplicateAssetType.values.firstWhere(
      (value) => value.name == row['asset_type'],
      orElse: () => ReplicateAssetType.other,
    ),
    name: row['name'] as String,
    description: row['description'] as String,
    path: row['path'] as String,
    referenceNumber: row['reference_number'] as int,
    status: ProcessingStatus.fromStorage(row['status']),
    createdAt: _parseDate(row['created_at']),
    updatedAt: _parseDate(row['updated_at']),
  );

  ShotPrompt _shotPrompt(Map<String, Object?> row) {
    final decoded = jsonDecode(row['asset_ids_json'] as String);
    final assetIds = decoded is List
        ? decoded.map((value) => '$value').toList()
        : <String>[];
    return ShotPrompt(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      shotNumber: row['shot_number'] as int,
      scriptShotId: row['script_shot_id'] as String?,
      assetIds: assetIds,
      prompt: row['prompt'] as String,
      model: row['model'] as String,
      rawResponse: row['raw_response'] as String,
      isUserEdited: (row['is_user_edited'] as int? ?? 0) != 0,
      status: ProcessingStatus.fromStorage(row['status']),
      errorMessage: row['error_message'] as String,
      updatedAt: _parseDate(row['updated_at']),
    );
  }
}
