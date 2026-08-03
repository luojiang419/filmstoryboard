import '../../../core/database/app_database.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../domain/shooting_script_models.dart';

class ShootingScriptRepository {
  const ShootingScriptRepository(this._database);

  final AppDatabase _database;

  List<ShootingScript> listScripts() => _database
      .selectRows('SELECT * FROM shooting_scripts ORDER BY updated_at DESC;')
      .map(_scriptFromRow)
      .toList();

  List<ScriptShot> listShots(String scriptId) => _database
      .selectRows(
        'SELECT * FROM script_shots WHERE script_id = ? ORDER BY shot_number;',
        [scriptId],
      )
      .map(_shotFromRow)
      .toList();

  void upsertScript(ShootingScript script) {
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
        script.createdAt.toIso8601String(),
        script.updatedAt.toIso8601String(),
      ],
    );
  }

  void replaceShots(String scriptId, List<ScriptShot> shots) {
    _database.executeStatement('BEGIN IMMEDIATE;');
    try {
      _database.executeStatement(
        'DELETE FROM script_shots WHERE script_id = ?;',
        [scriptId],
      );
      for (final shot in shots) {
        _insertShot(shot);
      }
      _database.executeStatement('COMMIT;');
    } catch (_) {
      _database.executeStatement('ROLLBACK;');
      rethrow;
    }
  }

  void deleteScript(String scriptId) {
    _database.executeStatement('DELETE FROM shooting_scripts WHERE id = ?;', [
      scriptId,
    ]);
  }

  void _insertShot(ScriptShot shot) {
    _database.executeStatement(
      '''
      INSERT INTO script_shots(
        id, script_id, source_storyboard_asset_id, shot_number,
        duration_seconds, frame_path, visual,
        content, shot_size, camera_movement, camera_notes, composition,
        camera_angle, lighting_mood, color_palette, visual_focus,
        transition_hint, scene, product_code, product_styling, dialogue,
        sound, prompt, status, updated_at
      ) VALUES(
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      );
      ''',
      [
        shot.id,
        shot.scriptId,
        shot.sourceStoryboardAssetId,
        shot.shotNumber,
        shot.durationSeconds,
        shot.framePath,
        shot.visual,
        shot.content,
        shot.shotSize,
        shot.cameraMovement,
        shot.cameraNotes,
        shot.composition,
        shot.cameraAngle,
        shot.lightingMood,
        shot.colorPalette,
        shot.visualFocus,
        shot.transitionHint,
        shot.scene,
        shot.productCode,
        shot.productStyling,
        shot.dialogue,
        shot.sound,
        shot.prompt,
        shot.status.name,
        shot.updatedAt.toIso8601String(),
      ],
    );
  }

  ShootingScript _scriptFromRow(Map<String, Object?> row) => ShootingScript(
    id: row['id'] as String,
    name: row['name'] as String,
    sourceStoryboardId: row['source_storyboard_id'] as String?,
    sourceVideoId: row['source_video_id'] as String?,
    status: ShootingScriptStatus.values.firstWhere(
      (status) => status.name == row['status'],
      orElse: () => ShootingScriptStatus.draft,
    ),
    version: row['version'] as int,
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );

  ScriptShot _shotFromRow(Map<String, Object?> row) {
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
      shotNumber: row['shot_number'] as int,
      durationSeconds: (row['duration_seconds'] as num).toDouble(),
      framePath: row['frame_path'] as String,
      visual: row['visual'] as String,
      content: row['content'] as String,
      shotSize: row['shot_size'] as String,
      cameraMovement: row['camera_movement'] as String,
      cameraNotes: legacy.cameraNotes,
      composition: valueOrLegacy('composition', legacy.composition),
      cameraAngle: valueOrLegacy('camera_angle', legacy.cameraAngle),
      lightingMood: valueOrLegacy('lighting_mood', legacy.lightingMood),
      colorPalette: valueOrLegacy('color_palette', legacy.colorPalette),
      visualFocus: valueOrLegacy('visual_focus', legacy.visualFocus),
      transitionHint: valueOrLegacy('transition_hint', legacy.transitionHint),
      scene: row['scene'] as String,
      productCode: row['product_code'] as String,
      productStyling: row['product_styling'] as String,
      dialogue: row['dialogue'] as String,
      sound: row['sound'] as String,
      prompt: row['prompt'] as String,
      status: ProcessingStatus.fromStorage(row['status']),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
