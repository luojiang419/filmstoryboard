import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

class ProjectCatalogRecord {
  const ProjectCatalogRecord({
    required this.projectId,
    required this.indexPath,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOpenedAt,
  });

  final String projectId;
  final String indexPath;
  final String displayName;
  final String createdAt;
  final String updatedAt;
  final String lastOpenedAt;
}

class CutResultRecord {
  const CutResultRecord({
    required this.id,
    required this.taskId,
    required this.imageId,
    required this.indexNo,
    required this.path,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.selected,
    required this.createdAt,
    required this.originalName,
  });

  final String id;
  final String taskId;
  final String imageId;
  final int indexNo;
  final String path;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool selected;
  final String createdAt;
  final String originalName;
}

class VisionAnalysisRunRecord {
  const VisionAnalysisRunRecord({
    required this.id,
    required this.boardId,
    required this.model,
    required this.status,
    required this.totalImages,
    required this.successCount,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String boardId;
  final String model;
  final String status;
  final int totalImages;
  final int successCount;
  final String errorMessage;
  final String createdAt;
  final String updatedAt;
}

class VisionAnalysisItemRecord {
  const VisionAnalysisItemRecord({
    required this.id,
    required this.runId,
    required this.boardId,
    required this.cutResultId,
    required this.slotIndex,
    required this.sequenceNo,
    required this.rowIndex,
    required this.columnIndex,
    required this.status,
    required this.caption,
    required this.detail,
    required this.scene,
    required this.props,
    required this.people,
    required this.expression,
    required this.bodyAction,
    required this.movementTrend,
    this.cameraMovement = '',
    required this.shotSize,
    required this.composition,
    required this.subjectDirection,
    required this.gazeDirection,
    required this.actionStage,
    required this.spatialRelation,
    required this.chronologyCue,
    this.cameraAngle = '',
    this.visualFocus = '',
    this.lightingMood = '',
    this.colorPalette = '',
    this.narrativeFunction = '',
    this.transitionHint = '',
    required this.rawResponse,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String runId;
  final String boardId;
  final String cutResultId;
  final int slotIndex;
  final int sequenceNo;
  final int rowIndex;
  final int columnIndex;
  final String status;
  final String caption;
  final String detail;
  final String scene;
  final String props;
  final String people;
  final String expression;
  final String bodyAction;
  final String movementTrend;
  final String cameraMovement;
  final String shotSize;
  final String composition;
  final String subjectDirection;
  final String gazeDirection;
  final String actionStage;
  final String spatialRelation;
  final String chronologyCue;
  final String cameraAngle;
  final String visualFocus;
  final String lightingMood;
  final String colorPalette;
  final String narrativeFunction;
  final String transitionHint;
  final String rawResponse;
  final String errorMessage;
  final String createdAt;
  final String updatedAt;
}

class VisionAnalysisBatchRecord {
  const VisionAnalysisBatchRecord({required this.run, required this.items});

  final VisionAnalysisRunRecord run;
  final List<VisionAnalysisItemRecord> items;
}

class StoryboardSummaryRecord {
  const StoryboardSummaryRecord({
    required this.boardId,
    required this.runId,
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
    required this.rawResponse,
    required this.updatedAt,
  });

  final String boardId;
  final String runId;
  final String outline;
  final String content;
  final String scenes;
  final String props;
  final String rawResponse;
  final String updatedAt;
}

class ImageGenerationRecord {
  const ImageGenerationRecord({
    required this.id,
    required this.boardId,
    required this.slotIndex,
    required this.sourceAssetId,
    required this.sourcePath,
    required this.resultAssetId,
    required this.resultPath,
    required this.model,
    required this.prompt,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.referencePathsJson,
    required this.status,
    required this.errorMessage,
    required this.rawResponse,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String boardId;
  final int slotIndex;
  final String sourceAssetId;
  final String sourcePath;
  final String resultAssetId;
  final String resultPath;
  final String model;
  final String prompt;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final String referencePathsJson;
  final String status;
  final String errorMessage;
  final String rawResponse;
  final String createdAt;
  final String updatedAt;
}

class AppDatabase {
  static const currentSchemaVersion = 30;

  AppDatabase._(this._database, this._settingWriteObserver);

  final Database _database;
  final void Function(String key)? _settingWriteObserver;

  static Future<AppDatabase> open(
    File file, {
    void Function(String key)? settingWriteObserver,
    bool verifyIntegrity = false,
  }) async {
    await file.parent.create(recursive: true);
    // A Future around synchronous SQLite does not move it off the UI isolate.
    // Prepare and verify using a worker-owned connection; never transfer FFI
    // handles between isolates. Only the short-lived runtime open stays here.
    final path = file.path;
    await Isolate.run(() => _prepareDatabase(path, verifyIntegrity));
    final database = sqlite3.open(file.path);
    database.execute('PRAGMA foreign_keys = ON;');
    return AppDatabase._(database, settingWriteObserver);
  }

  static void _prepareDatabase(String path, bool verifyIntegrity) {
    final database = AppDatabase._(sqlite3.open(path), null);
    try {
      database._initialize();
      if (verifyIntegrity && !database.integrityCheck()) {
        throw StateError('工程数据库完整性检查失败');
      }
    } finally {
      database.dispose();
    }
  }

  void _initialize() {
    _database
      ..execute('PRAGMA foreign_keys = ON;')
      ..execute('PRAGMA journal_mode = WAL;')
      ..execute('''
        CREATE TABLE IF NOT EXISTS imported_images (
          id TEXT PRIMARY KEY,
          original_path TEXT NOT NULL,
          original_name TEXT NOT NULL,
          stored_path TEXT NOT NULL,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS cut_tasks (
          id TEXT PRIMARY KEY,
          image_id TEXT NOT NULL REFERENCES imported_images(id) ON DELETE CASCADE,
          status TEXT NOT NULL,
          rows INTEGER NOT NULL DEFAULT 0,
          columns INTEGER NOT NULL DEFAULT 0,
          confidence REAL NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS cut_results (
          id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL REFERENCES cut_tasks(id) ON DELETE CASCADE,
          image_id TEXT NOT NULL REFERENCES imported_images(id) ON DELETE CASCADE,
          index_no INTEGER NOT NULL,
          path TEXT NOT NULL,
          x INTEGER NOT NULL,
          y INTEGER NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          selected INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS storyboard_tasks (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS storyboard_boards (
          id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL REFERENCES storyboard_tasks(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          columns INTEGER NOT NULL,
          gap INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS storyboard_items (
          id TEXT PRIMARY KEY,
          board_id TEXT NOT NULL REFERENCES storyboard_boards(id) ON DELETE CASCADE,
          cut_result_id TEXT NOT NULL REFERENCES cut_results(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          caption TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS export_records (
          id TEXT PRIMARY KEY,
          board_id TEXT REFERENCES storyboard_boards(id) ON DELETE SET NULL,
          format TEXT NOT NULL,
          output_path TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS project_catalog (
          project_id TEXT PRIMARY KEY,
          index_path TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_opened_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS vision_analysis_runs (
          id TEXT PRIMARY KEY,
          board_id TEXT NOT NULL,
          model TEXT NOT NULL,
          status TEXT NOT NULL,
          total_images INTEGER NOT NULL DEFAULT 0,
          success_count INTEGER NOT NULL DEFAULT 0,
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS vision_analysis_items (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES vision_analysis_runs(id) ON DELETE CASCADE,
          board_id TEXT NOT NULL,
          cut_result_id TEXT NOT NULL,
          slot_index INTEGER NOT NULL,
          sequence_no INTEGER NOT NULL,
          row_index INTEGER NOT NULL,
          column_index INTEGER NOT NULL,
          status TEXT NOT NULL,
          caption TEXT NOT NULL DEFAULT '',
          detail TEXT NOT NULL DEFAULT '',
          scene TEXT NOT NULL DEFAULT '',
          props TEXT NOT NULL DEFAULT '',
          people TEXT NOT NULL DEFAULT '',
          expression TEXT NOT NULL DEFAULT '',
          body_action TEXT NOT NULL DEFAULT '',
          movement_trend TEXT NOT NULL DEFAULT '',
          camera_movement TEXT NOT NULL DEFAULT '',
          shot_size TEXT NOT NULL DEFAULT '',
          composition TEXT NOT NULL DEFAULT '',
          subject_direction TEXT NOT NULL DEFAULT '',
          gaze_direction TEXT NOT NULL DEFAULT '',
          action_stage TEXT NOT NULL DEFAULT '',
          spatial_relation TEXT NOT NULL DEFAULT '',
          chronology_cue TEXT NOT NULL DEFAULT '',
          camera_angle TEXT NOT NULL DEFAULT '',
          visual_focus TEXT NOT NULL DEFAULT '',
          lighting_mood TEXT NOT NULL DEFAULT '',
          color_palette TEXT NOT NULL DEFAULT '',
          narrative_function TEXT NOT NULL DEFAULT '',
          transition_hint TEXT NOT NULL DEFAULT '',
          raw_response TEXT NOT NULL DEFAULT '',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS storyboard_summaries (
          board_id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES vision_analysis_runs(id) ON DELETE CASCADE,
          outline TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          scenes TEXT NOT NULL DEFAULT '',
          props TEXT NOT NULL DEFAULT '',
          raw_response TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS image_generation_records (
          id TEXT PRIMARY KEY,
          board_id TEXT NOT NULL,
          slot_index INTEGER NOT NULL,
          source_asset_id TEXT NOT NULL,
          source_path TEXT NOT NULL,
          result_asset_id TEXT NOT NULL DEFAULT '',
          result_path TEXT NOT NULL DEFAULT '',
          model TEXT NOT NULL,
          prompt TEXT NOT NULL,
          aspect_ratio TEXT NOT NULL,
          image_size TEXT NOT NULL,
          quality TEXT NOT NULL DEFAULT '',
          reference_paths_json TEXT NOT NULL DEFAULT '[]',
          status TEXT NOT NULL,
          error_message TEXT NOT NULL DEFAULT '',
          raw_response TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
    _migrateFeatureSchema();
    _ensureVisionAnalysisItemColumns();
    _ensureVisionAnalysisItemsSupportAllStoryboardAssets();
  }

  void _migrateFeatureSchema() {
    final row = _database.select('PRAGMA user_version;').first;
    final version = row['user_version'] as int? ?? 0;
    if (version < 1) {
      _database
        ..execute('''
        CREATE TABLE IF NOT EXISTS source_videos (
          id TEXT PRIMARY KEY,
          original_path TEXT NOT NULL,
          file_name TEXT NOT NULL,
          stored_path TEXT NOT NULL,
          duration_ms INTEGER NOT NULL DEFAULT 0,
          frame_rate REAL NOT NULL DEFAULT 0,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          rotation_degrees INTEGER NOT NULL DEFAULT 0,
          has_audio INTEGER NOT NULL DEFAULT 0,
          frame_count INTEGER NOT NULL DEFAULT 0,
          successful_frames INTEGER NOT NULL DEFAULT 0,
          failed_frames INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS video_frames (
          id TEXT PRIMARY KEY,
          video_id TEXT NOT NULL REFERENCES source_videos(id) ON DELETE CASCADE,
          index_no INTEGER NOT NULL,
          timestamp_ms INTEGER NOT NULL DEFAULT 0,
          path TEXT NOT NULL,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          sharpness REAL NOT NULL DEFAULT 0,
          brightness REAL NOT NULL DEFAULT 0,
          motion_score REAL NOT NULL DEFAULT 0,
          perceptual_hash TEXT NOT NULL DEFAULT '',
          is_focus INTEGER NOT NULL DEFAULT 0,
          is_selected INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          UNIQUE(video_id, index_no)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS video_shots (
          id TEXT PRIMARY KEY,
          video_id TEXT NOT NULL REFERENCES source_videos(id) ON DELETE CASCADE,
          shot_number INTEGER NOT NULL,
          start_ms INTEGER NOT NULL DEFAULT 0,
          end_ms INTEGER NOT NULL DEFAULT 0,
          primary_frame_id TEXT,
          description TEXT NOT NULL DEFAULT '',
          story_flow TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(video_id, shot_number)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS video_shot_frames (
          shot_id TEXT NOT NULL REFERENCES video_shots(id) ON DELETE CASCADE,
          frame_id TEXT NOT NULL REFERENCES video_frames(id) ON DELETE CASCADE,
          position INTEGER NOT NULL DEFAULT 0,
          is_primary INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(shot_id, frame_id)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS marketing_analyses (
          id TEXT PRIMARY KEY,
          video_id TEXT NOT NULL REFERENCES source_videos(id) ON DELETE CASCADE,
          scope TEXT NOT NULL,
          dimensions_json TEXT NOT NULL DEFAULT '{}',
          raw_response TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(video_id, scope)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS shooting_scripts (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          source_storyboard_id TEXT,
          source_video_id TEXT,
          status TEXT NOT NULL DEFAULT 'draft',
          version INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS script_shots (
          id TEXT PRIMARY KEY,
          script_id TEXT NOT NULL REFERENCES shooting_scripts(id) ON DELETE CASCADE,
          source_storyboard_asset_id TEXT,
          source_video_frame_id TEXT REFERENCES video_frames(id) ON DELETE SET NULL,
          shot_number INTEGER NOT NULL,
          duration_seconds REAL NOT NULL DEFAULT 0,
          frame_path TEXT NOT NULL DEFAULT '',
          visual TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          free_creation_description TEXT NOT NULL DEFAULT '',
          shot_size TEXT NOT NULL DEFAULT '',
          camera_movement TEXT NOT NULL DEFAULT '',
          camera_notes TEXT NOT NULL DEFAULT '',
          composition TEXT NOT NULL DEFAULT '',
          camera_angle TEXT NOT NULL DEFAULT '',
          lighting_mood TEXT NOT NULL DEFAULT '',
          color_palette TEXT NOT NULL DEFAULT '',
          visual_focus TEXT NOT NULL DEFAULT '',
          transition_hint TEXT NOT NULL DEFAULT '',
          movement_trend TEXT NOT NULL DEFAULT '',
          action_stage TEXT NOT NULL DEFAULT '',
          continues_from_previous INTEGER NOT NULL DEFAULT 0,
          continues_to_next INTEGER NOT NULL DEFAULT 0,
          scene TEXT NOT NULL DEFAULT '',
          product_code TEXT NOT NULL DEFAULT '',
          product_styling TEXT NOT NULL DEFAULT '',
          dialogue TEXT NOT NULL DEFAULT '',
          sound TEXT NOT NULL DEFAULT '',
          prompt TEXT NOT NULL DEFAULT '',
          replication_instructions TEXT NOT NULL DEFAULT '',
          generation_feedback TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          updated_at TEXT NOT NULL,
          UNIQUE(script_id, shot_number)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS replicate_runs (
          id TEXT PRIMARY KEY,
          video_id TEXT,
          script_id TEXT NOT NULL DEFAULT '',
           global_style TEXT NOT NULL DEFAULT '',
           constraints_text TEXT NOT NULL DEFAULT '',
          replication_instructions TEXT NOT NULL DEFAULT '',
          free_creation_enabled INTEGER NOT NULL DEFAULT 0,
          free_creation_story_override TEXT NOT NULL DEFAULT '',
          inherit_source_aspect_ratio INTEGER NOT NULL DEFAULT 1,
          multi_view_enhancement_enabled INTEGER NOT NULL DEFAULT 0,
          confirmed_shot_ids_json TEXT NOT NULL DEFAULT '[]',
          start_end_pairs_json TEXT NOT NULL DEFAULT '[]',
          image_reference_count INTEGER NOT NULL DEFAULT 0,
          video_reference_count INTEGER NOT NULL DEFAULT 0,
          audio_reference_count INTEGER NOT NULL DEFAULT 0,
          current_step TEXT NOT NULL DEFAULT 'confirmShots',
          status TEXT NOT NULL DEFAULT 'pending',
          confirm_shots_status TEXT NOT NULL DEFAULT 'pending',
          prepare_assets_status TEXT NOT NULL DEFAULT 'pending',
          compose_prompts_status TEXT NOT NULL DEFAULT 'pending',
          generate_videos_status TEXT NOT NULL DEFAULT 'pending',
          completed_count INTEGER NOT NULL DEFAULT 0,
          total_count INTEGER NOT NULL DEFAULT 0,
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS replicate_assets (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES replicate_runs(id) ON DELETE CASCADE,
          asset_type TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          reference_number INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS shot_prompts (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES replicate_runs(id) ON DELETE CASCADE,
          shot_number INTEGER NOT NULL,
          script_shot_id TEXT,
          asset_ids_json TEXT NOT NULL DEFAULT '[]',
          prompt TEXT NOT NULL DEFAULT '',
          model TEXT NOT NULL DEFAULT '',
          raw_response TEXT NOT NULL DEFAULT '',
          is_user_edited INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          error_message TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL,
          UNIQUE(run_id, shot_number)
        );
      ''')
        ..execute('PRAGMA user_version = 1;');
    }
    if (version < 2) {
      _database
        ..execute('''
          CREATE TABLE IF NOT EXISTS video_frame_analyses (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL REFERENCES source_videos(id) ON DELETE CASCADE,
            frame_id TEXT NOT NULL REFERENCES video_frames(id) ON DELETE CASCADE,
            sequence_no INTEGER NOT NULL,
            dimensions_json TEXT NOT NULL DEFAULT '{}',
            raw_response TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending',
            error_message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(video_id, frame_id)
          );
        ''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS video_summaries (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL REFERENCES source_videos(id) ON DELETE CASCADE,
            fields_json TEXT NOT NULL DEFAULT '{}',
            raw_response TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending',
            error_message TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL,
            UNIQUE(video_id)
          );
        ''')
        ..execute('PRAGMA user_version = 2;');
    }
    if (version < 3) {
      _ensureTextColumn('replicate_runs', 'script_id');
      _ensureTextColumn('replicate_runs', 'global_style');
      _ensureTextColumn('replicate_runs', 'constraints_text');
      _ensureTextColumn('replicate_runs', 'confirmed_shot_ids_json');
      _database.execute(
        "UPDATE replicate_runs SET confirmed_shot_ids_json = '[]' "
        "WHERE confirmed_shot_ids_json = '';",
      );
      _database.execute('PRAGMA user_version = 3;');
    }
    if (version < 4) {
      _ensureIntegerColumn('replicate_runs', 'image_reference_count');
      _ensureIntegerColumn('replicate_runs', 'video_reference_count');
      _ensureIntegerColumn('replicate_runs', 'audio_reference_count');
      _database.execute('PRAGMA user_version = 4;');
    }
    if (version < 5) {
      _database
        ..execute('''
        CREATE TABLE IF NOT EXISTS shooting_asset_library_items (
          id TEXT PRIMARY KEY,
          asset_type TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS script_assets (
          id TEXT PRIMARY KEY,
          script_id TEXT NOT NULL REFERENCES shooting_scripts(id) ON DELETE CASCADE,
          library_asset_id TEXT,
          asset_type TEXT NOT NULL,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          reference_number INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(script_id, library_asset_id)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS script_shot_asset_links (
          shot_id TEXT NOT NULL REFERENCES script_shots(id) ON DELETE CASCADE,
          script_asset_id TEXT NOT NULL REFERENCES script_assets(id) ON DELETE CASCADE,
          match_source TEXT NOT NULL DEFAULT 'manual',
          confidence REAL NOT NULL DEFAULT 1,
          match_reason TEXT NOT NULL DEFAULT '',
          confirmed INTEGER NOT NULL DEFAULT 0,
          locked INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0,
          quick_reference_order INTEGER,
          quick_reference_role TEXT,
          quick_description TEXT NOT NULL DEFAULT '',
          quick_group_anchor_asset_id TEXT,
          quick_group_confidence REAL,
          quick_group_warning TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(shot_id, script_asset_id)
        );
      ''')
        ..execute('''
        CREATE TABLE IF NOT EXISTS script_shot_analysis (
          id TEXT PRIMARY KEY,
          shot_id TEXT NOT NULL UNIQUE REFERENCES script_shots(id) ON DELETE CASCADE,
          model TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          field_sources_json TEXT NOT NULL DEFAULT '{}',
          field_confidence_json TEXT NOT NULL DEFAULT '{}',
          prompt_context_json TEXT NOT NULL DEFAULT '{}',
          prompt_context_schema_version INTEGER NOT NULL DEFAULT 0,
          source_image_fingerprint TEXT NOT NULL DEFAULT '',
          analysis_rule_version INTEGER NOT NULL DEFAULT 0,
          raw_response TEXT NOT NULL DEFAULT '',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''')
        ..execute('PRAGMA user_version = 5;');
    }
    if (version < 6) {
      _database
        ..execute('''
        CREATE TABLE IF NOT EXISTS replicated_shot_images (
          id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES replicate_runs(id) ON DELETE CASCADE,
          script_shot_id TEXT NOT NULL REFERENCES script_shots(id) ON DELETE CASCADE,
          shot_number INTEGER NOT NULL,
          original_frame_path TEXT NOT NULL DEFAULT '',
          generated_frame_path TEXT NOT NULL DEFAULT '',
          asset_ids_json TEXT NOT NULL DEFAULT '[]',
          prompt TEXT NOT NULL DEFAULT '',
           model TEXT NOT NULL DEFAULT '',
           raw_response TEXT NOT NULL DEFAULT '',
           generation_recovery_json TEXT NOT NULL DEFAULT '{}',
           status TEXT NOT NULL DEFAULT 'pending',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(run_id, script_shot_id)
        );
      ''')
        ..execute('PRAGMA user_version = 6;');
    }
    if (version < 7) {
      for (final column in const [
        'composition',
        'camera_angle',
        'lighting_mood',
        'color_palette',
        'visual_focus',
        'transition_hint',
      ]) {
        _ensureTextColumn('script_shots', column);
      }
      _database.execute('PRAGMA user_version = 7;');
    }
    if (version < 8) {
      _ensureNullableTextColumn('script_shots', 'source_storyboard_asset_id');
      _database.execute('PRAGMA user_version = 8;');
    }
    if (version < 9) {
      _ensureTextColumn('replicate_runs', 'generation_model');
      _ensureTextColumn('replicate_runs', 'generation_aspect_ratio');
      _ensureTextColumn('replicate_runs', 'generation_image_size');
      _ensureTextColumn('replicate_runs', 'generation_quality');
      _database.execute('PRAGMA user_version = 9;');
    }
    if (version < 10) {
      _ensureTextColumn('shooting_asset_library_items', 'aliases_json');
      _database.execute(
        "UPDATE shooting_asset_library_items SET aliases_json = '[]' "
        "WHERE aliases_json = '';",
      );
      _database.execute('PRAGMA user_version = 10;');
    }
    if (version < 11) {
      _ensureTextColumn('replicate_runs', 'replication_instructions');
      _database.execute('PRAGMA user_version = 11;');
    }
    if (version < 12) {
      _ensureTextColumn('script_shots', 'replication_instructions');
      _database.execute('PRAGMA user_version = 12;');
    }
    if (version < 13) {
      _ensureNullableTextColumn('script_shots', 'source_video_frame_id');
      _ensureTextColumn('replicate_runs', 'generate_videos_status');
      _database
        ..execute(
          "UPDATE replicate_runs SET generate_videos_status = 'pending' "
          "WHERE generate_videos_status = '';",
        )
        ..execute('''
          UPDATE script_shots
          SET source_video_frame_id = (
            SELECT frame.id
            FROM shooting_scripts AS script
            INNER JOIN video_frames AS frame
              ON frame.video_id = script.source_video_id
            WHERE script.id = script_shots.script_id
              AND lower(frame.path) = lower(script_shots.frame_path)
            LIMIT 1
          )
          WHERE source_video_frame_id IS NULL
            AND frame_path <> '';
        ''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS video_generation_profiles (
            script_id TEXT PRIMARY KEY REFERENCES shooting_scripts(id) ON DELETE CASCADE,
            model TEXT NOT NULL DEFAULT '',
            parameters_json TEXT NOT NULL DEFAULT '{}',
            prompt_mode TEXT NOT NULL DEFAULT 'klingOptimized',
            prefer_without_watermark INTEGER NOT NULL DEFAULT 1,
            directory_name TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS video_generation_drafts (
            id TEXT PRIMARY KEY,
            script_id TEXT NOT NULL REFERENCES shooting_scripts(id) ON DELETE CASCADE,
            shot_id TEXT NOT NULL UNIQUE REFERENCES script_shots(id) ON DELETE CASCADE,
            source_prompt TEXT NOT NULL DEFAULT '',
            kling_prompt TEXT NOT NULL DEFAULT '',
            h3_prompt TEXT NOT NULL DEFAULT '',
            edited_prompt TEXT NOT NULL DEFAULT '',
            prompt_mode TEXT NOT NULL DEFAULT 'klingOptimized',
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS video_generation_tasks (
            id TEXT PRIMARY KEY,
            script_id TEXT NOT NULL REFERENCES shooting_scripts(id) ON DELETE CASCADE,
            shot_id TEXT NOT NULL REFERENCES script_shots(id) ON DELETE CASCADE,
            generation_id TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL,
            parameters_json TEXT NOT NULL DEFAULT '{}',
            duration_seconds INTEGER NOT NULL,
            prompt_mode TEXT NOT NULL,
            prompt_text TEXT NOT NULL,
            credits_before INTEGER,
            credits_after INTEGER,
            status TEXT NOT NULL DEFAULT 'draft',
            result_url TEXT NOT NULL DEFAULT '',
            result_without_watermark_url TEXT NOT NULL DEFAULT '',
            local_path TEXT NOT NULL DEFAULT '',
            tail_image_path TEXT NOT NULL DEFAULT '',
            source_duration_ms INTEGER NOT NULL DEFAULT 0,
            trim_in_ms INTEGER NOT NULL DEFAULT 0,
            trim_out_ms INTEGER NOT NULL DEFAULT 0,
            used_watermarked_fallback INTEGER NOT NULL DEFAULT 0,
            error_message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT
          );
        ''')
        ..execute('''
          CREATE INDEX IF NOT EXISTS idx_video_generation_tasks_script_shot
          ON video_generation_tasks(script_id, shot_id, created_at DESC);
        ''')
        ..execute('''
          CREATE INDEX IF NOT EXISTS idx_video_generation_tasks_status
          ON video_generation_tasks(status, updated_at DESC);
        ''')
        ..execute('PRAGMA user_version = 13;');
    }
    if (version < 14) {
      _ensureTextColumn('script_shots', 'movement_trend');
      _ensureTextColumn('script_shots', 'action_stage');
      _ensureIntegerColumn('script_shots', 'continues_from_previous');
      _ensureIntegerColumn('script_shots', 'continues_to_next');
      _ensureTextColumn('video_generation_tasks', 'tail_image_path');
      _database.execute('PRAGMA user_version = 14;');
    }
    if (version < 15) {
      _ensureTextColumn('replicate_runs', 'start_end_pairs_json');
      _database.execute(
        "UPDATE replicate_runs SET start_end_pairs_json = '[]' "
        "WHERE start_end_pairs_json = '';",
      );
      _database.execute('PRAGMA user_version = 15;');
    }
    if (version < 16) {
      _ensureTextColumn('video_generation_drafts', 'h3_prompt');
      _database.execute('PRAGMA user_version = 16;');
    }
    if (version < 17) {
      _database.execute('''
        CREATE TABLE IF NOT EXISTS script_shot_analysis (
          id TEXT PRIMARY KEY,
          shot_id TEXT NOT NULL UNIQUE REFERENCES script_shots(id) ON DELETE CASCADE,
          model TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          field_sources_json TEXT NOT NULL DEFAULT '{}',
          field_confidence_json TEXT NOT NULL DEFAULT '{}',
          prompt_context_json TEXT NOT NULL DEFAULT '{}',
          prompt_context_schema_version INTEGER NOT NULL DEFAULT 0,
          source_image_fingerprint TEXT NOT NULL DEFAULT '',
          analysis_rule_version INTEGER NOT NULL DEFAULT 0,
          raw_response TEXT NOT NULL DEFAULT '',
          error_message TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
      _ensureTextColumn('script_shot_analysis', 'prompt_context_json');
      _ensureIntegerColumn(
        'script_shot_analysis',
        'prompt_context_schema_version',
      );
      _ensureTextColumn('script_shot_analysis', 'source_image_fingerprint');
      _ensureIntegerColumn('script_shot_analysis', 'analysis_rule_version');
      _database.execute(
        "UPDATE script_shot_analysis SET prompt_context_json = '{}' "
        "WHERE prompt_context_json = '';",
      );
      _database.execute('PRAGMA user_version = 17;');
    }
    if (version < 18) {
      if (_database
          .select(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'script_shots' LIMIT 1;",
          )
          .isNotEmpty) {
        _ensureTextColumn('script_shots', 'generation_feedback');
      }
      _database.execute('PRAGMA user_version = 18;');
    }
    if (version < 19) {
      if (_tableExists('script_shots')) {
        _ensureTextColumn('script_shots', 'free_creation_description');
      }
      if (_tableExists('replicate_runs')) {
        _ensureIntegerColumn('replicate_runs', 'free_creation_enabled');
        _ensureTextColumn('replicate_runs', 'free_creation_story_override');
      }
      if (_tableExists('shot_prompts')) {
        _ensureIntegerColumn('shot_prompts', 'is_user_edited');
      }
      if (_tableExists('script_shots') &&
          _tableExists('replicate_runs') &&
          _columnExists('replicate_runs', 'script_id') &&
          _columnExists('replicate_runs', 'start_end_pairs_json') &&
          _columnExists('script_shots', 'script_id') &&
          _columnExists('script_shots', 'shot_number') &&
          _columnExists('script_shots', 'continues_from_previous') &&
          _columnExists('script_shots', 'continues_to_next')) {
        _migrateStartEndPairsToShotGroups();
      }
      _database.execute('PRAGMA user_version = 19;');
    }
    if (version < 20) {
      if (_tableExists('source_videos')) {
        _ensureIntegerColumn('source_videos', 'rotation_degrees');
      }
      _database.execute('PRAGMA user_version = 20;');
    }
    if (version < 21) {
      if (_tableExists('video_generation_tasks')) {
        _ensureIntegerColumn('video_generation_tasks', 'source_duration_ms');
        _ensureIntegerColumn('video_generation_tasks', 'trim_in_ms');
        _ensureIntegerColumn('video_generation_tasks', 'trim_out_ms');
      }
      _database.execute('PRAGMA user_version = 21;');
    }
    if (version < 22) {
      _database
        ..execute('''
          CREATE TABLE IF NOT EXISTS replicate_shot_guides (
            shot_id TEXT PRIMARY KEY REFERENCES script_shots(id) ON DELETE CASCADE,
            source_frame_fingerprint TEXT NOT NULL DEFAULT '',
            elements_json TEXT NOT NULL DEFAULT '[]',
            subjects_json TEXT NOT NULL DEFAULT '[]',
            action_description TEXT NOT NULL DEFAULT '',
            pose_constraints TEXT NOT NULL DEFAULT '',
            skeleton_path TEXT NOT NULL DEFAULT '',
            analysis_model TEXT NOT NULL DEFAULT '',
            analysis_status TEXT NOT NULL DEFAULT 'pending',
            pose_status TEXT NOT NULL DEFAULT 'pending',
            raw_response TEXT NOT NULL DEFAULT '',
            error_message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('PRAGMA user_version = 22;');
    }
    if (version < 23) {
      if (_tableExists('replicate_shot_guides') &&
          !_columnExists('replicate_shot_guides', 'person_count')) {
        _database.execute(
          'ALTER TABLE replicate_shot_guides '
          'ADD COLUMN person_count INTEGER NOT NULL DEFAULT 0;',
        );
      }
      _database.execute('PRAGMA user_version = 23;');
    }
    if (version < 24) {
      if (_tableExists('replicate_shot_guides') &&
          !_columnExists('replicate_shot_guides', 'subjects_json')) {
        _database.execute(
          'ALTER TABLE replicate_shot_guides '
          "ADD COLUMN subjects_json TEXT NOT NULL DEFAULT '[]';",
        );
      }
      if (_tableExists('replicate_runs') &&
          !_columnExists('replicate_runs', 'inherit_source_aspect_ratio')) {
        _database.execute(
          'ALTER TABLE replicate_runs '
          'ADD COLUMN inherit_source_aspect_ratio INTEGER NOT NULL DEFAULT 1;',
        );
      }
      _database.execute('PRAGMA user_version = 24;');
    }
    if (version < 25) {
      if (_tableExists('replicate_runs') &&
          !_columnExists('replicate_runs', 'multi_view_enhancement_enabled')) {
        _database.execute(
          'ALTER TABLE replicate_runs '
          'ADD COLUMN multi_view_enhancement_enabled INTEGER NOT NULL DEFAULT 0;',
        );
      }
      _database.execute('PRAGMA user_version = 25;');
    }
    if (version < 26) {
      if (_tableExists('replicated_shot_images') &&
          !_columnExists(
            'replicated_shot_images',
            'generation_recovery_json',
          )) {
        _database.execute(
          'ALTER TABLE replicated_shot_images '
          "ADD COLUMN generation_recovery_json TEXT NOT NULL DEFAULT '{}';",
        );
      }
      _database.execute('PRAGMA user_version = 26;');
    }
    if (version < 27) {
      if (_tableExists('replicate_shot_guides')) {
        if (!_columnExists(
          'replicate_shot_guides',
          'full_outfit_assets_json',
        )) {
          _database.execute(
            'ALTER TABLE replicate_shot_guides '
            "ADD COLUMN full_outfit_assets_json TEXT NOT NULL DEFAULT '[]';",
          );
        }
        if (!_columnExists(
          'replicate_shot_guides',
          'wearable_product_links_json',
        )) {
          _database.execute(
            'ALTER TABLE replicate_shot_guides '
            "ADD COLUMN wearable_product_links_json TEXT NOT NULL DEFAULT '[]';",
          );
        }
        if (!_columnExists(
          'replicate_shot_guides',
          'product_mark_authorizations_json',
        )) {
          _database.execute(
            'ALTER TABLE replicate_shot_guides '
            "ADD COLUMN product_mark_authorizations_json TEXT NOT NULL DEFAULT '[]';",
          );
        }
        if (!_columnExists('replicate_shot_guides', 'editable_pose_json')) {
          _database.execute(
            'ALTER TABLE replicate_shot_guides '
            "ADD COLUMN editable_pose_json TEXT NOT NULL DEFAULT '{}';",
          );
        }
      }
      _database.execute('PRAGMA user_version = 27;');
    }
    if (version < 28) {
      if (_tableExists('script_shot_asset_links')) {
        _ensureNullableIntegerColumn(
          'script_shot_asset_links',
          'quick_reference_order',
        );
        _ensureNullableTextColumn(
          'script_shot_asset_links',
          'quick_reference_role',
        );
        _ensureTextColumn('script_shot_asset_links', 'quick_description');
        _ensureNullableTextColumn(
          'script_shot_asset_links',
          'quick_group_anchor_asset_id',
        );
        _ensureNullableRealColumn(
          'script_shot_asset_links',
          'quick_group_confidence',
        );
        _ensureTextColumn('script_shot_asset_links', 'quick_group_warning');
      }
      _database.execute('PRAGMA user_version = 28;');
    }
    if (version < 29) {
      if (_tableExists('replicate_runs')) {
        _ensureTextColumn('replicate_runs', 'source_frame_mode');
        _ensureTextColumn('replicate_runs', 'color_style_preset_id');
        _ensureTextColumn('replicate_runs', 'color_style_snapshot_json');
        _database
          ..execute(
            "UPDATE replicate_runs SET source_frame_mode = 'colorReference' "
            "WHERE trim(source_frame_mode) = '';",
          )
          ..execute(
            "UPDATE replicate_runs SET color_style_snapshot_json = '{}' "
            "WHERE trim(color_style_snapshot_json) = '';",
          );
      }
      if (_tableExists('replicated_shot_images')) {
        _ensureTextColumn('replicated_shot_images', 'color_style_fingerprint');
      }
      _database
        ..execute('''
          CREATE TABLE IF NOT EXISTS replicate_color_style_presets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            prompt TEXT NOT NULL,
            swatches_json TEXT NOT NULL DEFAULT '[]',
            use_case TEXT NOT NULL DEFAULT 'fashion',
            version INTEGER NOT NULL DEFAULT 1,
            thumbnail_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS replicate_color_style_thumbnail_overrides (
            preset_id TEXT PRIMARY KEY,
            thumbnail_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('PRAGMA user_version = 29;');
    }
    if (version < 30) {
      // Cover the project-scoped hot paths. Keep legacy partial databases
      // migratable by checking columns before creating each index.
      const indexes = <String, (String, List<String>)>{
        'idx_video_drafts_script': ('video_generation_drafts', ['script_id']),
        'idx_replicate_runs_script': ('replicate_runs', ['script_id']),
        'idx_replicate_assets_run': ('replicate_assets', ['run_id']),
        'idx_replicated_images_run': ('replicated_shot_images', ['run_id']),
        'idx_vision_runs_board_created': (
          'vision_analysis_runs',
          ['board_id', 'created_at'],
        ),
        'idx_vision_items_run_slot': (
          'vision_analysis_items',
          ['run_id', 'slot_index'],
        ),
        'idx_script_assets_script': ('script_assets', ['script_id']),
        'idx_shot_asset_links_shot': ('script_shot_asset_links', ['shot_id']),
      };
      for (final entry in indexes.entries) {
        final (table, columns) = entry.value;
        if (_tableExists(table) &&
            columns.every((column) => _columnExists(table, column))) {
          _database.execute(
            'CREATE INDEX IF NOT EXISTS ${entry.key} '
            'ON $table (${columns.join(', ')});',
          );
        }
      }
      _database.execute('PRAGMA user_version = 30;');
    }
  }

  bool _tableExists(String tableName) => _database.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
    [tableName],
  ).isNotEmpty;

  bool _columnExists(String tableName, String columnName) => _database
      .select('PRAGMA table_info($tableName);')
      .any((row) => row['name'] == columnName);

  void _migrateStartEndPairsToShotGroups() {
    final runs = _database.select('''
      SELECT script_id, start_end_pairs_json
      FROM replicate_runs
      WHERE trim(script_id) <> '' AND trim(start_end_pairs_json) <> '[]';
    ''');
    _database.execute('BEGIN IMMEDIATE;');
    try {
      for (final run in runs) {
        final scriptId = run['script_id'] as String? ?? '';
        final rows = _database.select(
          'SELECT id FROM script_shots WHERE script_id = ? ORDER BY shot_number;',
          [scriptId],
        );
        final shotIds = [for (final row in rows) row['id'] as String];
        final indexById = <String, int>{
          for (var index = 0; index < shotIds.length; index++)
            shotIds[index]: index,
        };
        try {
          final decoded = jsonDecode(
            run['start_end_pairs_json'] as String? ?? '[]',
          );
          if (decoded is List) {
            for (final item in decoded) {
              if (item is! Map) continue;
              final startIndex = indexById['${item['startShotId'] ?? ''}'];
              final tailIndex = indexById['${item['tailShotId'] ?? ''}'];
              if (startIndex == null ||
                  tailIndex == null ||
                  tailIndex <= startIndex) {
                continue;
              }
              for (var index = startIndex; index < tailIndex; index++) {
                _database.execute(
                  'UPDATE script_shots SET continues_to_next = 1 WHERE id = ?;',
                  [shotIds[index]],
                );
                _database.execute(
                  'UPDATE script_shots SET continues_from_previous = 1 WHERE id = ?;',
                  [shotIds[index + 1]],
                );
              }
            }
          }
        } on FormatException {
          // Invalid legacy data cannot describe a valid range; clear it below.
        }
      }
      _database.execute(
        "UPDATE replicate_runs SET start_end_pairs_json = '[]';",
      );
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _ensureVisionAnalysisItemColumns() {
    _ensureTextColumn('vision_analysis_items', 'expression');
    _ensureTextColumn('vision_analysis_items', 'body_action');
    _ensureTextColumn('vision_analysis_items', 'movement_trend');
    _ensureTextColumn('vision_analysis_items', 'camera_movement');
    _ensureTextColumn('vision_analysis_items', 'shot_size');
    _ensureTextColumn('vision_analysis_items', 'composition');
    _ensureTextColumn('vision_analysis_items', 'subject_direction');
    _ensureTextColumn('vision_analysis_items', 'gaze_direction');
    _ensureTextColumn('vision_analysis_items', 'action_stage');
    _ensureTextColumn('vision_analysis_items', 'spatial_relation');
    _ensureTextColumn('vision_analysis_items', 'chronology_cue');
    _ensureTextColumn('vision_analysis_items', 'camera_angle');
    _ensureTextColumn('vision_analysis_items', 'visual_focus');
    _ensureTextColumn('vision_analysis_items', 'lighting_mood');
    _ensureTextColumn('vision_analysis_items', 'color_palette');
    _ensureTextColumn('vision_analysis_items', 'narrative_function');
    _ensureTextColumn('vision_analysis_items', 'transition_hint');
  }

  void _ensureTextColumn(String tableName, String columnName) {
    final columns = _database
        .select('PRAGMA table_info($tableName);')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains(columnName)) {
      return;
    }
    _database.execute(
      "ALTER TABLE $tableName ADD COLUMN $columnName TEXT NOT NULL DEFAULT '';",
    );
  }

  void _ensureNullableTextColumn(String tableName, String columnName) {
    final columns = _database
        .select('PRAGMA table_info($tableName);')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains(columnName)) {
      return;
    }
    _database.execute('ALTER TABLE $tableName ADD COLUMN $columnName TEXT;');
  }

  void _ensureNullableIntegerColumn(String tableName, String columnName) {
    if (_columnExists(tableName, columnName)) {
      return;
    }
    _database.execute('ALTER TABLE $tableName ADD COLUMN $columnName INTEGER;');
  }

  void _ensureNullableRealColumn(String tableName, String columnName) {
    if (_columnExists(tableName, columnName)) {
      return;
    }
    _database.execute('ALTER TABLE $tableName ADD COLUMN $columnName REAL;');
  }

  void _ensureIntegerColumn(String tableName, String columnName) {
    final columns = _database
        .select('PRAGMA table_info($tableName);')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains(columnName)) {
      return;
    }
    _database.execute(
      'ALTER TABLE $tableName ADD COLUMN $columnName INTEGER NOT NULL DEFAULT 0;',
    );
  }

  void _ensureVisionAnalysisItemsSupportAllStoryboardAssets() {
    final foreignKeys = _database.select(
      'PRAGMA foreign_key_list(vision_analysis_items);',
    );
    final hasCutResultForeignKey = foreignKeys.any(
      (row) => row['table'] == 'cut_results' && row['from'] == 'cut_result_id',
    );
    if (!hasCutResultForeignKey) {
      return;
    }

    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database
        ..execute('DROP TABLE IF EXISTS _vision_analysis_items_migration;')
        ..execute('''
          CREATE TABLE _vision_analysis_items_migration (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES vision_analysis_runs(id) ON DELETE CASCADE,
            board_id TEXT NOT NULL,
            cut_result_id TEXT NOT NULL,
            slot_index INTEGER NOT NULL,
            sequence_no INTEGER NOT NULL,
            row_index INTEGER NOT NULL,
            column_index INTEGER NOT NULL,
            status TEXT NOT NULL,
            caption TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            scene TEXT NOT NULL DEFAULT '',
            props TEXT NOT NULL DEFAULT '',
            people TEXT NOT NULL DEFAULT '',
            expression TEXT NOT NULL DEFAULT '',
            body_action TEXT NOT NULL DEFAULT '',
            movement_trend TEXT NOT NULL DEFAULT '',
            camera_movement TEXT NOT NULL DEFAULT '',
            shot_size TEXT NOT NULL DEFAULT '',
            composition TEXT NOT NULL DEFAULT '',
            subject_direction TEXT NOT NULL DEFAULT '',
            gaze_direction TEXT NOT NULL DEFAULT '',
            action_stage TEXT NOT NULL DEFAULT '',
            spatial_relation TEXT NOT NULL DEFAULT '',
            chronology_cue TEXT NOT NULL DEFAULT '',
            camera_angle TEXT NOT NULL DEFAULT '',
            visual_focus TEXT NOT NULL DEFAULT '',
            lighting_mood TEXT NOT NULL DEFAULT '',
            color_palette TEXT NOT NULL DEFAULT '',
            narrative_function TEXT NOT NULL DEFAULT '',
            transition_hint TEXT NOT NULL DEFAULT '',
            raw_response TEXT NOT NULL DEFAULT '',
            error_message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        ''')
        ..execute('''
          INSERT INTO _vision_analysis_items_migration (
            id, run_id, board_id, cut_result_id, slot_index, sequence_no,
            row_index, column_index, status, caption, detail, scene, props,
            people, expression, body_action, movement_trend, camera_movement,
            shot_size, composition, subject_direction, gaze_direction,
            action_stage, spatial_relation, chronology_cue, camera_angle,
            visual_focus, lighting_mood, color_palette, narrative_function,
            transition_hint, raw_response, error_message, created_at, updated_at
          )
          SELECT
            id, run_id, board_id, cut_result_id, slot_index, sequence_no,
            row_index, column_index, status, caption, detail, scene, props,
            people, expression, body_action, movement_trend, camera_movement,
            shot_size, composition, subject_direction, gaze_direction,
            action_stage, spatial_relation, chronology_cue, camera_angle,
            visual_focus, lighting_mood, color_palette, narrative_function,
            transition_hint, raw_response, error_message, created_at, updated_at
          FROM vision_analysis_items;
        ''')
        ..execute('DROP TABLE vision_analysis_items;')
        ..execute('''
          ALTER TABLE _vision_analysis_items_migration
          RENAME TO vision_analysis_items;
        ''')
        ..execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  String? getSetting(String key) {
    final rows = _database.select(
      'SELECT value FROM settings WHERE key = ? LIMIT 1',
      [key],
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _database.execute(
      '''
      INSERT INTO settings(key, value, updated_at)
      VALUES(?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updated_at = excluded.updated_at;
      ''',
      [key, value, DateTime.now().toIso8601String()],
    );
    _settingWriteObserver?.call(key);
  }

  List<ProjectCatalogRecord> listProjectCatalog() {
    final rows = _database.select('''
      SELECT project_id, index_path, display_name, created_at, updated_at,
             last_opened_at
      FROM project_catalog
      ORDER BY last_opened_at DESC, updated_at DESC;
    ''');
    return [
      for (final row in rows)
        ProjectCatalogRecord(
          projectId: row['project_id'] as String,
          indexPath: row['index_path'] as String,
          displayName: row['display_name'] as String,
          createdAt: row['created_at'] as String,
          updatedAt: row['updated_at'] as String,
          lastOpenedAt: row['last_opened_at'] as String,
        ),
    ];
  }

  void upsertProjectCatalog(ProjectCatalogRecord record) {
    _database.execute(
      '''
      INSERT INTO project_catalog(
        project_id, index_path, display_name, created_at, updated_at,
        last_opened_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(project_id) DO UPDATE SET
        index_path = excluded.index_path,
        display_name = excluded.display_name,
        updated_at = excluded.updated_at,
        last_opened_at = excluded.last_opened_at;
      ''',
      [
        record.projectId,
        record.indexPath,
        record.displayName,
        record.createdAt,
        record.updatedAt,
        record.lastOpenedAt,
      ],
    );
  }

  void removeProjectCatalog(String projectId) {
    _database.execute('DELETE FROM project_catalog WHERE project_id = ?;', [
      projectId,
    ]);
  }

  bool integrityCheck() {
    final rows = _database.select('PRAGMA integrity_check;');
    return rows.length == 1 && rows.first.values.first == 'ok';
  }

  void checkpoint() {
    _database.execute('PRAGMA wal_checkpoint(TRUNCATE);');
  }

  void importProjectDataFrom(
    File sourceFile, {
    required Set<String> projectSettingKeys,
  }) {
    if (!sourceFile.existsSync()) {
      throw StateError('旧版数据库不存在：${sourceFile.path}');
    }
    const tables = [
      'imported_images',
      'cut_tasks',
      'cut_results',
      'storyboard_tasks',
      'storyboard_boards',
      'storyboard_items',
      'export_records',
      'vision_analysis_runs',
      'vision_analysis_items',
      'storyboard_summaries',
      'image_generation_records',
    ];
    _database.execute('ATTACH DATABASE ? AS legacy;', [sourceFile.path]);
    try {
      _database.execute('BEGIN IMMEDIATE;');
      for (final table in tables) {
        final columns = _database
            .select('PRAGMA main.table_info($table);')
            .map((row) => row['name'] as String)
            .toList();
        if (columns.isEmpty) {
          continue;
        }
        final columnList = columns.join(', ');
        _database.execute(
          'INSERT OR REPLACE INTO main.$table($columnList) '
          'SELECT $columnList FROM legacy.$table;',
        );
      }
      for (final key in projectSettingKeys) {
        _database.execute(
          '''
          INSERT OR REPLACE INTO main.settings(key, value, updated_at)
          SELECT key, value, updated_at FROM legacy.settings WHERE key = ?;
          ''',
          [key],
        );
      }
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    } finally {
      _database.execute('DETACH DATABASE legacy;');
    }
  }

  void rewriteManagedPaths(String Function(String path) transform) {
    _rewriteTextColumn('imported_images', 'stored_path', transform);
    _rewriteTextColumn('cut_results', 'path', transform);
    _rewriteTextColumn('export_records', 'output_path', transform);
    _rewriteTextColumn('image_generation_records', 'source_path', transform);
    _rewriteTextColumn('image_generation_records', 'result_path', transform);
    _rewriteTextColumn(
      'replicated_shot_images',
      'original_frame_path',
      transform,
    );
    _rewriteTextColumn(
      'replicated_shot_images',
      'generated_frame_path',
      transform,
    );
    _rewriteTextColumn('replicate_shot_guides', 'skeleton_path', transform);
    _rewriteJsonColumn(
      'image_generation_records',
      'reference_paths_json',
      transform,
    );
    for (final key in const [
      'gridCutWorkspaceSnapshot',
      'storyboardWorkspaceSnapshot',
    ]) {
      final source = getSetting(key);
      if (source == null || source.trim().isEmpty) {
        continue;
      }
      try {
        setSetting(
          key,
          jsonEncode(_rewriteJsonValue(jsonDecode(source), transform)),
        );
      } catch (_) {
        // 保留无法解析的旧版状态，业务控制器会按现有容错逻辑忽略。
      }
    }
  }

  void _rewriteTextColumn(
    String table,
    String column,
    String Function(String path) transform,
  ) {
    final rows = _database.select('SELECT rowid, $column FROM $table;');
    for (final row in rows) {
      final value = row[column];
      if (value is! String || value.isEmpty) {
        continue;
      }
      final next = transform(value);
      if (next != value) {
        _database.execute('UPDATE $table SET $column = ? WHERE rowid = ?;', [
          next,
          row['rowid'],
        ]);
      }
    }
  }

  void _rewriteJsonColumn(
    String table,
    String column,
    String Function(String path) transform,
  ) {
    final rows = _database.select('SELECT rowid, $column FROM $table;');
    for (final row in rows) {
      final source = row[column];
      if (source is! String || source.trim().isEmpty) {
        continue;
      }
      try {
        final next = jsonEncode(
          _rewriteJsonValue(jsonDecode(source), transform),
        );
        if (next != source) {
          _database.execute('UPDATE $table SET $column = ? WHERE rowid = ?;', [
            next,
            row['rowid'],
          ]);
        }
      } catch (_) {
        // 非法旧记录不阻断其他记录迁移。
      }
    }
  }

  Object? _rewriteJsonValue(
    Object? value,
    String Function(String path) transform,
  ) {
    return switch (value) {
      final String path => transform(path),
      final List<Object?> values => [
        for (final item in values) _rewriteJsonValue(item, transform),
      ],
      final Map<String, Object?> values => {
        for (final entry in values.entries)
          entry.key: _rewriteJsonValue(entry.value, transform),
      },
      _ => value,
    };
  }

  void upsertImportedImage({
    required String id,
    required String originalPath,
    required String originalName,
    required String storedPath,
    required int width,
    required int height,
    required String createdAt,
  }) {
    _database.execute(
      '''
      INSERT INTO imported_images(
        id, original_path, original_name, stored_path, width, height, created_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        original_path = excluded.original_path,
        original_name = excluded.original_name,
        stored_path = excluded.stored_path,
        width = excluded.width,
        height = excluded.height;
      ''',
      [id, originalPath, originalName, storedPath, width, height, createdAt],
    );
  }

  void upsertCutTask({
    required String id,
    required String imageId,
    required String status,
    required int rows,
    required int columns,
    required double confidence,
  }) {
    final now = DateTime.now().toIso8601String();
    _database.execute(
      '''
      INSERT INTO cut_tasks(
        id, image_id, status, rows, columns, confidence, created_at, updated_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        rows = excluded.rows,
        columns = excluded.columns,
        confidence = excluded.confidence,
        updated_at = excluded.updated_at;
      ''',
      [id, imageId, status, rows, columns, confidence, now, now],
    );
  }

  void deleteCutResultsForTask(String taskId) {
    _database.execute('DELETE FROM cut_results WHERE task_id = ?', [taskId]);
  }

  void deleteCutResultsForImage(String imageId) {
    _database.execute('DELETE FROM cut_results WHERE image_id = ?', [imageId]);
  }

  void deleteCutResultsForImageSource({
    required String originalPath,
    required String originalName,
  }) {
    _database.execute(
      '''
      DELETE FROM cut_results
      WHERE image_id IN (
        SELECT id
        FROM imported_images
        WHERE original_path = ? AND original_name = ?
      );
      ''',
      [originalPath, originalName],
    );
  }

  int deleteMissingCutResults({
    String Function(String storedPath)? resolvePath,
  }) {
    final rows = _database.select('SELECT id, path FROM cut_results');
    final missingIds = <String>[];
    for (final row in rows) {
      final id = row['id'] as String;
      final storedPath = row['path'] as String;
      final path = resolvePath?.call(storedPath) ?? storedPath;
      if (File(path).existsSync()) {
        continue;
      }
      missingIds.add(id);
    }
    return deleteCutResultsByIds(missingIds);
  }

  int deleteCutResultsByIds(Iterable<String> ids) {
    final uniqueIds = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) {
      return 0;
    }

    var deleted = 0;
    _database.execute('BEGIN IMMEDIATE;');
    try {
      const batchSize = 500;
      for (var offset = 0; offset < uniqueIds.length; offset += batchSize) {
        final end = offset + batchSize < uniqueIds.length
            ? offset + batchSize
            : uniqueIds.length;
        final batch = uniqueIds.sublist(offset, end);
        final placeholders = List.filled(batch.length, '?').join(', ');
        _database.execute(
          'DELETE FROM cut_results WHERE id IN ($placeholders)',
          batch,
        );
        deleted += _database.updatedRows;
      }
      _database.execute('COMMIT;');
      return deleted;
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void insertCutResult({
    required String id,
    required String taskId,
    required String imageId,
    required int indexNo,
    required String path,
    required int x,
    required int y,
    required int width,
    required int height,
    required bool selected,
  }) {
    _database.execute(
      '''
      INSERT INTO cut_results(
        id, task_id, image_id, index_no, path, x, y, width, height, selected, created_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        id,
        taskId,
        imageId,
        indexNo,
        path,
        x,
        y,
        width,
        height,
        selected ? 1 : 0,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  List<CutResultRecord> listCutResults() {
    final rows = _database.select('''
      SELECT
        cut_results.*,
        imported_images.original_name AS original_name
      FROM cut_results
      JOIN imported_images ON imported_images.id = cut_results.image_id
      ORDER BY imported_images.created_at DESC, cut_results.index_no ASC;
    ''');
    return rows.map((row) {
      return CutResultRecord(
        id: row['id'] as String,
        taskId: row['task_id'] as String,
        imageId: row['image_id'] as String,
        indexNo: row['index_no'] as int,
        path: row['path'] as String,
        x: row['x'] as int,
        y: row['y'] as int,
        width: row['width'] as int,
        height: row['height'] as int,
        selected: (row['selected'] as int) == 1,
        createdAt: row['created_at'] as String,
        originalName: row['original_name'] as String,
      );
    }).toList();
  }

  void updateCutResultPathAndIndex(String id, String path, int indexNo) {
    _database.execute(
      'UPDATE cut_results SET path = ?, index_no = ? WHERE id = ?;',
      [path, indexNo, id],
    );
  }

  void updateExternalCutResult({
    required String id,
    required int indexNo,
    required String path,
    required int width,
    required int height,
  }) {
    _database.execute(
      '''
      UPDATE cut_results
      SET index_no = ?, path = ?, x = 0, y = 0,
          width = ?, height = ?, selected = 1
      WHERE id = ?;
      ''',
      [indexNo, path, width, height, id],
    );
  }

  void updateImportedImageStoredPath(String imageId, String path) {
    _database.execute(
      'UPDATE imported_images SET stored_path = ? WHERE id = ?;',
      [path, imageId],
    );
  }

  void reassignCutResultImageSource({
    required String resultId,
    required String taskId,
    required String imageId,
  }) {
    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database.execute('UPDATE cut_results SET image_id = ? WHERE id = ?;', [
        imageId,
        resultId,
      ]);
      _database.execute('UPDATE cut_tasks SET image_id = ? WHERE id = ?;', [
        imageId,
        taskId,
      ]);
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void deleteImportedImageIfUnreferenced(String imageId) {
    _database.execute(
      '''
      DELETE FROM imported_images
      WHERE id = ?
        AND NOT EXISTS (
          SELECT 1 FROM cut_results WHERE image_id = ?
        )
        AND NOT EXISTS (
          SELECT 1 FROM cut_tasks WHERE image_id = ?
        );
      ''',
      [imageId, imageId, imageId],
    );
  }

  void insertVisionAnalysisRun({
    required String id,
    required String boardId,
    required String model,
    required String status,
    required int totalImages,
  }) {
    final now = DateTime.now().toIso8601String();
    _database.execute(
      '''
      INSERT INTO vision_analysis_runs(
        id, board_id, model, status, total_images, success_count,
        error_message, created_at, updated_at
      )
      VALUES(?, ?, ?, ?, ?, 0, '', ?, ?);
      ''',
      [id, boardId, model, status, totalImages, now, now],
    );
  }

  void updateVisionAnalysisRun({
    required String id,
    required String status,
    required int successCount,
    String errorMessage = '',
  }) {
    _database.execute(
      '''
      UPDATE vision_analysis_runs
      SET status = ?,
          success_count = ?,
          error_message = ?,
          updated_at = ?
      WHERE id = ?;
      ''',
      [
        status,
        successCount,
        errorMessage,
        DateTime.now().toIso8601String(),
        id,
      ],
    );
  }

  VisionAnalysisRunRecord? getVisionAnalysisRun(String id) {
    final rows = _database.select(
      'SELECT * FROM vision_analysis_runs WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _visionAnalysisRunFromRow(rows.first);
  }

  void insertVisionAnalysisItem({
    required String id,
    required String runId,
    required String boardId,
    required String cutResultId,
    required int slotIndex,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String status,
    required String caption,
    required String detail,
    required String scene,
    required String props,
    required String people,
    required String expression,
    required String bodyAction,
    required String movementTrend,
    String cameraMovement = '',
    String shotSize = '',
    String composition = '',
    String subjectDirection = '',
    String gazeDirection = '',
    String actionStage = '',
    String spatialRelation = '',
    String chronologyCue = '',
    String cameraAngle = '',
    String visualFocus = '',
    String lightingMood = '',
    String colorPalette = '',
    String narrativeFunction = '',
    String transitionHint = '',
    required String rawResponse,
    String errorMessage = '',
  }) {
    final now = DateTime.now().toIso8601String();
    _database.execute(
      '''
      INSERT INTO vision_analysis_items(
        id, run_id, board_id, cut_result_id, slot_index, sequence_no,
        row_index, column_index, status, caption, detail, scene, props,
        people, expression, body_action, movement_trend, camera_movement, shot_size,
        composition, subject_direction, gaze_direction, action_stage,
        spatial_relation, chronology_cue, camera_angle, visual_focus,
        lighting_mood, color_palette, narrative_function, transition_hint,
        raw_response,
        error_message, created_at, updated_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        id,
        runId,
        boardId,
        cutResultId,
        slotIndex,
        sequenceNo,
        rowIndex,
        columnIndex,
        status,
        caption,
        detail,
        scene,
        props,
        people,
        expression,
        bodyAction,
        movementTrend,
        cameraMovement,
        shotSize,
        composition,
        subjectDirection,
        gazeDirection,
        actionStage,
        spatialRelation,
        chronologyCue,
        cameraAngle,
        visualFocus,
        lightingMood,
        colorPalette,
        narrativeFunction,
        transitionHint,
        rawResponse,
        errorMessage,
        now,
        now,
      ],
    );
  }

  List<VisionAnalysisItemRecord> listVisionAnalysisItems(String runId) {
    final rows = _database.select(
      '''
      SELECT *
      FROM vision_analysis_items
      WHERE run_id = ?
      ORDER BY sequence_no ASC;
      ''',
      [runId],
    );
    return rows.map(_visionAnalysisItemFromRow).toList();
  }

  VisionAnalysisBatchRecord? getLatestVisionAnalysisBatchForBoard(
    String boardId,
  ) {
    final runRows = _database.select(
      '''
      SELECT *
      FROM vision_analysis_runs
      WHERE board_id = ? AND success_count > 0
      ORDER BY updated_at DESC, created_at DESC
      LIMIT 1;
      ''',
      [boardId],
    );
    if (runRows.isEmpty) {
      return null;
    }
    final run = _visionAnalysisRunFromRow(runRows.first);
    final itemRows = _database.select(
      '''
      SELECT *
      FROM vision_analysis_items
      WHERE run_id = ? AND status = 'success'
      ORDER BY sequence_no ASC;
      ''',
      [run.id],
    );
    return VisionAnalysisBatchRecord(
      run: run,
      items: itemRows.map(_visionAnalysisItemFromRow).toList(),
    );
  }

  void deleteVisionAnalysisForBoard(String boardId) {
    _database
      ..execute('DELETE FROM storyboard_summaries WHERE board_id = ?;', [
        boardId,
      ])
      ..execute('DELETE FROM vision_analysis_items WHERE board_id = ?;', [
        boardId,
      ])
      ..execute('DELETE FROM vision_analysis_runs WHERE board_id = ?;', [
        boardId,
      ]);
  }

  void upsertStoryboardSummary({
    required String boardId,
    required String runId,
    required String outline,
    required String content,
    required String scenes,
    required String props,
    required String rawResponse,
  }) {
    _database.execute(
      '''
      INSERT INTO storyboard_summaries(
        board_id, run_id, outline, content, scenes, props, raw_response,
        updated_at
      )
      VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(board_id) DO UPDATE SET
        run_id = excluded.run_id,
        outline = excluded.outline,
        content = excluded.content,
        scenes = excluded.scenes,
        props = excluded.props,
        raw_response = excluded.raw_response,
        updated_at = excluded.updated_at;
      ''',
      [
        boardId,
        runId,
        outline,
        content,
        scenes,
        props,
        rawResponse,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  StoryboardSummaryRecord? getStoryboardSummary(String boardId) {
    final rows = _database.select(
      'SELECT * FROM storyboard_summaries WHERE board_id = ? LIMIT 1',
      [boardId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    return StoryboardSummaryRecord(
      boardId: row['board_id'] as String,
      runId: row['run_id'] as String,
      outline: row['outline'] as String,
      content: row['content'] as String,
      scenes: row['scenes'] as String,
      props: row['props'] as String,
      rawResponse: row['raw_response'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  void insertImageGenerationRecord({
    required String id,
    required String boardId,
    required int slotIndex,
    required String sourceAssetId,
    required String sourcePath,
    required String model,
    required String prompt,
    required String aspectRatio,
    required String imageSize,
    required String quality,
    required String referencePathsJson,
    required String status,
  }) {
    final now = DateTime.now().toIso8601String();
    _database.execute(
      '''
      INSERT INTO image_generation_records(
        id, board_id, slot_index, source_asset_id, source_path,
        result_asset_id, result_path, model, prompt, aspect_ratio, image_size,
        quality, reference_paths_json, status, error_message, raw_response,
        created_at, updated_at
      )
      VALUES(?, ?, ?, ?, ?, '', '', ?, ?, ?, ?, ?, ?, ?, '', '', ?, ?);
      ''',
      [
        id,
        boardId,
        slotIndex,
        sourceAssetId,
        sourcePath,
        model,
        prompt,
        aspectRatio,
        imageSize,
        quality,
        referencePathsJson,
        status,
        now,
        now,
      ],
    );
  }

  void updateImageGenerationRecord({
    required String id,
    required String status,
    String resultAssetId = '',
    String resultPath = '',
    String errorMessage = '',
    String rawResponse = '',
  }) {
    _database.execute(
      '''
      UPDATE image_generation_records
      SET status = ?,
          result_asset_id = ?,
          result_path = ?,
          error_message = ?,
          raw_response = ?,
          updated_at = ?
      WHERE id = ?;
      ''',
      [
        status,
        resultAssetId,
        resultPath,
        errorMessage,
        rawResponse,
        DateTime.now().toIso8601String(),
        id,
      ],
    );
  }

  ImageGenerationRecord? getImageGenerationRecord(String id) {
    final rows = _database.select(
      'SELECT * FROM image_generation_records WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _imageGenerationRecordFromRow(rows.first);
  }

  List<ImageGenerationRecord> listImageGenerationRecords() {
    return _database
        .select('SELECT * FROM image_generation_records ORDER BY created_at;')
        .map(_imageGenerationRecordFromRow)
        .toList();
  }

  void updateImageGenerationResultPathByAssetId(
    String resultAssetId,
    String resultPath,
  ) {
    _database.execute(
      '''
      UPDATE image_generation_records
      SET result_path = ?, updated_at = ?
      WHERE result_asset_id = ?;
      ''',
      [resultPath, DateTime.now().toIso8601String(), resultAssetId],
    );
  }

  VisionAnalysisRunRecord _visionAnalysisRunFromRow(Row row) {
    return VisionAnalysisRunRecord(
      id: row['id'] as String,
      boardId: row['board_id'] as String,
      model: row['model'] as String,
      status: row['status'] as String,
      totalImages: row['total_images'] as int,
      successCount: row['success_count'] as int,
      errorMessage: row['error_message'] as String,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  ImageGenerationRecord _imageGenerationRecordFromRow(Row row) {
    return ImageGenerationRecord(
      id: row['id'] as String,
      boardId: row['board_id'] as String,
      slotIndex: row['slot_index'] as int,
      sourceAssetId: row['source_asset_id'] as String,
      sourcePath: row['source_path'] as String,
      resultAssetId: row['result_asset_id'] as String,
      resultPath: row['result_path'] as String,
      model: row['model'] as String,
      prompt: row['prompt'] as String,
      aspectRatio: row['aspect_ratio'] as String,
      imageSize: row['image_size'] as String,
      quality: row['quality'] as String,
      referencePathsJson: row['reference_paths_json'] as String,
      status: row['status'] as String,
      errorMessage: row['error_message'] as String,
      rawResponse: row['raw_response'] as String,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  VisionAnalysisItemRecord _visionAnalysisItemFromRow(Row row) {
    return VisionAnalysisItemRecord(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      boardId: row['board_id'] as String,
      cutResultId: row['cut_result_id'] as String,
      slotIndex: row['slot_index'] as int,
      sequenceNo: row['sequence_no'] as int,
      rowIndex: row['row_index'] as int,
      columnIndex: row['column_index'] as int,
      status: row['status'] as String,
      caption: row['caption'] as String,
      detail: row['detail'] as String,
      scene: row['scene'] as String,
      props: row['props'] as String,
      people: row['people'] as String,
      expression: row['expression'] as String,
      bodyAction: row['body_action'] as String,
      movementTrend: row['movement_trend'] as String,
      cameraMovement: row['camera_movement'] as String,
      shotSize: row['shot_size'] as String,
      composition: row['composition'] as String,
      subjectDirection: row['subject_direction'] as String,
      gazeDirection: row['gaze_direction'] as String,
      actionStage: row['action_stage'] as String,
      spatialRelation: row['spatial_relation'] as String,
      chronologyCue: row['chronology_cue'] as String,
      cameraAngle: row['camera_angle'] as String,
      visualFocus: row['visual_focus'] as String,
      lightingMood: row['lighting_mood'] as String,
      colorPalette: row['color_palette'] as String,
      narrativeFunction: row['narrative_function'] as String,
      transitionHint: row['transition_hint'] as String,
      rawResponse: row['raw_response'] as String,
      errorMessage: row['error_message'] as String,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  int countRows(String tableName) {
    final rows = _database.select('SELECT COUNT(*) AS total FROM $tableName');
    return rows.first['total'] as int;
  }

  List<Map<String, Object?>> selectRows(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    return _database.select(sql, parameters);
  }

  void executeStatement(String sql, [List<Object?> parameters = const []]) {
    _database.execute(sql, parameters);
  }

  void dispose() {
    _database.close();
  }
}
