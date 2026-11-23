import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../domain/shooting_script_workflow_models.dart';

class ShootingScriptWorkflowRepository {
  const ShootingScriptWorkflowRepository(this._database);

  final AppDatabase _database;

  List<ScriptAsset> listScriptAssets(String scriptId) => _database
      .selectRows(
        'SELECT * FROM script_assets WHERE script_id = ? '
        'ORDER BY asset_type, reference_number, created_at;',
        [scriptId],
      )
      .map(_assetFromRow)
      .toList();

  void upsertScriptAsset(ScriptAsset asset) {
    _database.executeStatement(
      '''
      INSERT INTO script_assets(
        id, script_id, library_asset_id, asset_type, name, description, path,
        reference_number, status, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        script_id = excluded.script_id,
        library_asset_id = excluded.library_asset_id,
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
        asset.scriptId,
        asset.libraryAssetId,
        asset.type.name,
        asset.name,
        asset.description,
        asset.path,
        asset.referenceNumber,
        asset.status.storageValue,
        asset.createdAt.toIso8601String(),
        asset.updatedAt.toIso8601String(),
      ],
    );
  }

  void deleteScriptAsset(String scriptAssetId) {
    _database.executeStatement('DELETE FROM script_assets WHERE id = ?;', [
      scriptAssetId,
    ]);
  }

  List<ScriptShotAssetLink> listLinksForScript(String scriptId) {
    final rows = _database.selectRows(
      '''
        SELECT link.*
          , asset.asset_type AS linked_asset_type
        FROM script_shot_asset_links link
        INNER JOIN script_assets asset ON asset.id = link.script_asset_id
        WHERE asset.script_id = ?
        ORDER BY link.shot_id, link.sort_order, link.created_at;
      ''',
      [scriptId],
    );
    return _linksWithBackfilledQuickMetadata(rows);
  }

  List<ScriptShotAssetLink> listLinksForShot(String shotId) {
    final rows = _database.selectRows(
      '''
      SELECT link.*, asset.asset_type AS linked_asset_type
      FROM script_shot_asset_links link
      INNER JOIN script_assets asset ON asset.id = link.script_asset_id
      WHERE link.shot_id = ?
      ORDER BY link.sort_order, link.created_at;
      ''',
      [shotId],
    );
    return _linksWithBackfilledQuickMetadata(rows);
  }

  void upsertLink(ScriptShotAssetLink link) {
    _database.executeStatement(
      '''
      INSERT INTO script_shot_asset_links(
        shot_id, script_asset_id, match_source, confidence, match_reason,
        confirmed, locked, sort_order, quick_reference_order,
        quick_reference_role, quick_description, quick_group_anchor_asset_id,
        quick_group_confidence, quick_group_warning, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(shot_id, script_asset_id) DO UPDATE SET
        match_source = excluded.match_source,
        confidence = excluded.confidence,
        match_reason = excluded.match_reason,
        confirmed = excluded.confirmed,
        locked = excluded.locked,
        sort_order = excluded.sort_order,
        quick_reference_order = excluded.quick_reference_order,
        quick_reference_role = excluded.quick_reference_role,
        quick_description = excluded.quick_description,
        quick_group_anchor_asset_id = excluded.quick_group_anchor_asset_id,
        quick_group_confidence = excluded.quick_group_confidence,
        quick_group_warning = excluded.quick_group_warning,
        updated_at = excluded.updated_at;
      ''',
      [
        link.shotId,
        link.scriptAssetId,
        link.matchSource.name,
        link.confidence,
        link.matchReason,
        link.confirmed ? 1 : 0,
        link.locked ? 1 : 0,
        link.sortOrder,
        link.quickReferenceOrder,
        link.quickReferenceRole?.name,
        link.quickDescription,
        link.quickGroupAnchorAssetId,
        link.quickGroupConfidence,
        link.quickGroupWarning,
        link.createdAt.toIso8601String(),
        link.updatedAt.toIso8601String(),
      ],
    );
  }

  void deleteLink(String shotId, String scriptAssetId) {
    _database.executeStatement(
      'DELETE FROM script_shot_asset_links '
      'WHERE shot_id = ? AND script_asset_id = ?;',
      [shotId, scriptAssetId],
    );
  }

  ScriptShotAnalysisRecord? getAnalysis(String shotId) {
    final rows = _database.selectRows(
      'SELECT * FROM script_shot_analysis WHERE shot_id = ? LIMIT 1;',
      [shotId],
    );
    return rows.isEmpty ? null : _analysisFromRow(rows.first);
  }

  List<ScriptShotAnalysisRecord> listAnalyses(String scriptId) => _database
      .selectRows(
        '''
        SELECT analysis.*
        FROM script_shot_analysis analysis
        INNER JOIN script_shots shot ON shot.id = analysis.shot_id
        WHERE shot.script_id = ?
        ORDER BY shot.shot_number;
        ''',
        [scriptId],
      )
      .map(_analysisFromRow)
      .toList();

  void upsertAnalysis(ScriptShotAnalysisRecord analysis) {
    _database.executeStatement(
      '''
      INSERT INTO script_shot_analysis(
        id, shot_id, model, status, field_sources_json,
        field_confidence_json, prompt_context_json,
        prompt_context_schema_version, source_image_fingerprint,
        analysis_rule_version, raw_response, error_message, created_at,
        updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(shot_id) DO UPDATE SET
        id = excluded.id,
        model = excluded.model,
        status = excluded.status,
        field_sources_json = excluded.field_sources_json,
        field_confidence_json = excluded.field_confidence_json,
        prompt_context_json = excluded.prompt_context_json,
        prompt_context_schema_version = excluded.prompt_context_schema_version,
        source_image_fingerprint = excluded.source_image_fingerprint,
        analysis_rule_version = excluded.analysis_rule_version,
        raw_response = excluded.raw_response,
        error_message = excluded.error_message,
        updated_at = excluded.updated_at;
      ''',
      [
        analysis.id,
        analysis.shotId,
        analysis.model,
        analysis.status.storageValue,
        jsonEncode(analysis.fieldSources),
        jsonEncode(analysis.fieldConfidence),
        jsonEncode(analysis.promptContext.toJson()),
        analysis.promptContextSchemaVersion,
        analysis.sourceImageFingerprint,
        analysis.analysisRuleVersion,
        analysis.rawResponse,
        analysis.errorMessage,
        analysis.createdAt.toIso8601String(),
        analysis.updatedAt.toIso8601String(),
      ],
    );
  }

  ScriptAsset _assetFromRow(Map<String, Object?> row) => ScriptAsset(
    id: row['id'] as String,
    scriptId: row['script_id'] as String,
    libraryAssetId: row['library_asset_id'] as String?,
    type: _assetType(row['asset_type'] as String?),
    name: row['name'] as String,
    description: row['description'] as String,
    path: row['path'] as String,
    referenceNumber: row['reference_number'] as int,
    status: ProcessingStatus.fromStorage(row['status']),
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );

  ScriptShotAssetLink _linkFromRow(Map<String, Object?> row) =>
      ScriptShotAssetLink(
        shotId: row['shot_id'] as String,
        scriptAssetId: row['script_asset_id'] as String,
        matchSource: ScriptAssetMatchSource.values.firstWhere(
          (source) => source.name == row['match_source'],
          orElse: () => ScriptAssetMatchSource.manual,
        ),
        confidence: (row['confidence'] as num).toDouble(),
        matchReason: row['match_reason'] as String,
        confirmed: (row['confirmed'] as int) == 1,
        locked: (row['locked'] as int) == 1,
        sortOrder: row['sort_order'] as int,
        quickReferenceOrder: row['quick_reference_order'] as int?,
        quickReferenceRole: _quickReferenceRole(
          row['quick_reference_role'] as String?,
        ),
        quickDescription: row['quick_description'] as String? ?? '',
        quickGroupAnchorAssetId: row['quick_group_anchor_asset_id'] as String?,
        quickGroupConfidence: (row['quick_group_confidence'] as num?)
            ?.toDouble(),
        quickGroupWarning: row['quick_group_warning'] as String? ?? '',
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  List<ScriptShotAssetLink> _linksWithBackfilledQuickMetadata(
    List<Map<String, Object?>> rows,
  ) {
    final result = <ScriptShotAssetLink>[];
    for (var start = 0; start < rows.length;) {
      final shotId = rows[start]['shot_id'] as String;
      var end = start + 1;
      while (end < rows.length && rows[end]['shot_id'] == shotId) {
        end++;
      }
      final shotRows = rows.sublist(start, end);
      final needsOrderBackfill = shotRows.any(
        (row) => row['quick_reference_order'] == null,
      );
      for (var index = 0; index < shotRows.length; index++) {
        final row = shotRows[index];
        final storedRole = _quickReferenceRole(
          row['quick_reference_role'] as String?,
        );
        final fallbackRole = _defaultQuickReferenceRole(
          _assetType(row['linked_asset_type'] as String?),
        );
        final role = storedRole ?? fallbackRole;
        final order = needsOrderBackfill
            ? index + 1
            : row['quick_reference_order'] as int;
        if (needsOrderBackfill || storedRole == null) {
          _database.executeStatement(
            '''
            UPDATE script_shot_asset_links
            SET quick_reference_order = ?, quick_reference_role = ?
            WHERE shot_id = ? AND script_asset_id = ?;
            ''',
            [order, role.name, shotId, row['script_asset_id']],
          );
        }
        result.add(
          _linkFromRow(
            row,
          ).copyWith(quickReferenceOrder: order, quickReferenceRole: role),
        );
      }
      start = end;
    }
    return result;
  }

  ScriptShotAnalysisRecord _analysisFromRow(Map<String, Object?> row) {
    return ScriptShotAnalysisRecord(
      id: row['id'] as String,
      shotId: row['shot_id'] as String,
      model: row['model'] as String,
      status: ProcessingStatus.fromStorage(row['status']),
      fieldSources: _stringMap(row['field_sources_json'] as String),
      fieldConfidence: _doubleMap(row['field_confidence_json'] as String),
      promptContext: _promptContext(row['prompt_context_json'] as String),
      promptContextSchemaVersion:
          row['prompt_context_schema_version'] as int? ?? 0,
      sourceImageFingerprint: row['source_image_fingerprint'] as String? ?? '',
      analysisRuleVersion: row['analysis_rule_version'] as int? ?? 0,
      rawResponse: row['raw_response'] as String,
      errorMessage: row['error_message'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  static ReplicateAssetType _assetType(String? value) =>
      ReplicateAssetType.values.firstWhere(
        (type) => type.name == value,
        orElse: () => ReplicateAssetType.reference,
      );

  static QuickReferenceRole? _quickReferenceRole(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final role in QuickReferenceRole.values) {
      if (role.name == value) return role;
    }
    return null;
  }

  static QuickReferenceRole _defaultQuickReferenceRole(
    ReplicateAssetType type,
  ) => switch (type) {
    ReplicateAssetType.character => QuickReferenceRole.model,
    ReplicateAssetType.scene => QuickReferenceRole.scene,
    ReplicateAssetType.product => QuickReferenceRole.product,
    ReplicateAssetType.prop => QuickReferenceRole.prop,
    ReplicateAssetType.video ||
    ReplicateAssetType.audio ||
    ReplicateAssetType.reference ||
    ReplicateAssetType.other => QuickReferenceRole.otherReference,
  };

  static Map<String, String> _stringMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const {};
      return decoded.map((key, item) => MapEntry('$key', '$item'));
    } catch (_) {
      return const {};
    }
  }

  static Map<String, double> _doubleMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const {};
      return decoded.map((key, item) {
        final number = item is num ? item.toDouble() : double.tryParse('$item');
        return MapEntry('$key', number ?? 0);
      });
    } catch (_) {
      return const {};
    }
  }

  static ScriptShotPromptContext _promptContext(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? ScriptShotPromptContext.fromJson(decoded)
          : const ScriptShotPromptContext();
    } catch (_) {
      return const ScriptShotPromptContext();
    }
  }
}

extension on ProcessingStatus {
  String get storageValue => name;
}
