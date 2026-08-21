import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../domain/line_art_color_style_catalog.dart';
import '../domain/line_art_color_style_preset.dart';

class LineArtColorStyleRepository {
  const LineArtColorStyleRepository(this._database);

  final AppDatabase _database;

  List<LineArtColorStylePreset> listCustomPresets() => _database
      .selectRows(
        'SELECT * FROM replicate_color_style_presets ORDER BY updated_at DESC;',
      )
      .map(_presetFromRow)
      .toList(growable: false);

  LineArtColorStylePreset? getCustomPreset(String id) {
    final rows = _database.selectRows(
      'SELECT * FROM replicate_color_style_presets WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : _presetFromRow(rows.first);
  }

  void upsertCustomPreset(LineArtColorStylePreset preset) {
    _validateCustomPreset(preset);
    _database.executeStatement(
      '''
      INSERT INTO replicate_color_style_presets(
        id, name, description, prompt, swatches_json, use_case, version,
        thumbnail_json, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        description = excluded.description,
        prompt = excluded.prompt,
        swatches_json = excluded.swatches_json,
        use_case = excluded.use_case,
        version = excluded.version,
        thumbnail_json = excluded.thumbnail_json,
        updated_at = excluded.updated_at;
      ''',
      [
        preset.id,
        preset.name,
        preset.description,
        preset.prompt,
        jsonEncode(preset.swatches),
        preset.useCase.name,
        preset.version,
        jsonEncode(preset.thumbnail?.toJson() ?? const {}),
        _date(preset.createdAt ?? preset.updatedAt ?? DateTime.now()),
        _date(preset.updatedAt ?? DateTime.now()),
      ],
    );
  }

  void deleteCustomPreset(String id) {
    _database.executeStatement(
      'DELETE FROM replicate_color_style_presets WHERE id = ?;',
      [id],
    );
    removeThumbnailOverride(id);
  }

  Map<String, ColorStyleThumbnailReference> listThumbnailOverrides() {
    final rows = _database.selectRows(
      'SELECT preset_id, thumbnail_json '
      'FROM replicate_color_style_thumbnail_overrides;',
    );
    final result = <String, ColorStyleThumbnailReference>{};
    for (final row in rows) {
      final reference = _thumbnailFromJson(row['thumbnail_json']);
      if (reference != null) result[row['preset_id'] as String] = reference;
    }
    return result;
  }

  ColorStyleThumbnailReference? getThumbnailOverride(String presetId) {
    final rows = _database.selectRows(
      'SELECT thumbnail_json FROM replicate_color_style_thumbnail_overrides '
      'WHERE preset_id = ? LIMIT 1;',
      [presetId],
    );
    return rows.isEmpty
        ? null
        : _thumbnailFromJson(rows.first['thumbnail_json']);
  }

  void setThumbnailOverride({
    required String presetId,
    required ColorStyleThumbnailReference thumbnail,
    DateTime? updatedAt,
  }) {
    if (presetId.trim().isEmpty) {
      throw ArgumentError.value(presetId, 'presetId', '预设 ID 不能为空');
    }
    if (thumbnail.type != ColorStyleThumbnailType.projectFile ||
        thumbnail.path.trim().isEmpty) {
      throw ArgumentError('项目覆盖缩略图必须引用项目托管文件');
    }
    _database.executeStatement(
      '''
      INSERT INTO replicate_color_style_thumbnail_overrides(
        preset_id, thumbnail_json, updated_at
      ) VALUES(?, ?, ?)
      ON CONFLICT(preset_id) DO UPDATE SET
        thumbnail_json = excluded.thumbnail_json,
        updated_at = excluded.updated_at;
      ''',
      [
        presetId,
        jsonEncode(thumbnail.toJson()),
        _date(updatedAt ?? DateTime.now()),
      ],
    );
  }

  void removeThumbnailOverride(String presetId) {
    _database.executeStatement(
      'DELETE FROM replicate_color_style_thumbnail_overrides '
      'WHERE preset_id = ?;',
      [presetId],
    );
  }

  List<LineArtColorStylePreset> listEffectivePresets() {
    final overrides = listThumbnailOverrides();
    return [
      for (final preset in LineArtColorStyleCatalog.builtInPresets)
        preset.copyWith(thumbnail: overrides[preset.id]),
      ...listCustomPresets(),
    ];
  }

  LineArtColorStylePreset? resolvePreset(String id) {
    final custom = getCustomPreset(id);
    if (custom != null) return custom;
    for (final preset in LineArtColorStyleCatalog.builtInPresets) {
      if (preset.id == id) {
        final override = getThumbnailOverride(id);
        return override == null ? preset : preset.copyWith(thumbnail: override);
      }
    }
    return null;
  }

  LineArtColorStylePreset _presetFromRow(Map<String, Object?> row) {
    final swatches = _stringList(row['swatches_json']);
    return LineArtColorStylePreset(
      id: row['id'] as String,
      name: row['name'] as String? ?? '',
      description: row['description'] as String? ?? '',
      prompt: row['prompt'] as String? ?? '',
      swatches: swatches,
      useCase: LineArtColorStyleUseCase.values.firstWhere(
        (value) => value.name == row['use_case'],
        orElse: () => LineArtColorStyleUseCase.fashion,
      ),
      isBuiltIn: false,
      version: row['version'] as int? ?? 1,
      thumbnail: _thumbnailFromJson(row['thumbnail_json']),
      createdAt: _parseDate(row['created_at']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  static void _validateCustomPreset(LineArtColorStylePreset preset) {
    if (preset.isBuiltIn) throw ArgumentError('不能把内置预设写入自定义预设表');
    if (LineArtColorStyleCatalog.builtInPresets.any(
      (builtIn) => builtIn.id == preset.id,
    )) {
      throw ArgumentError('自定义预设 ID 不能覆盖内置预设');
    }
    if (preset.id.trim().isEmpty ||
        preset.name.trim().isEmpty ||
        preset.prompt.trim().isEmpty) {
      throw ArgumentError('自定义预设的 ID、名称和提示词不能为空');
    }
    if (preset.version < 1) throw ArgumentError('自定义预设版本必须大于 0');
    final thumbnail = preset.thumbnail;
    if (thumbnail != null &&
        thumbnail.type != ColorStyleThumbnailType.projectFile) {
      throw ArgumentError('自定义预设缩略图必须引用项目托管文件');
    }
  }

  static ColorStyleThumbnailReference? _thumbnailFromJson(Object? source) {
    try {
      final decoded = jsonDecode(source as String? ?? '{}');
      if (decoded is Map && decoded.isNotEmpty) {
        return ColorStyleThumbnailReference.fromJson(
          decoded.map((key, value) => MapEntry('$key', value)),
        );
      }
    } on FormatException {
      // 损坏的可选缩略图记录回退到色板占位，不阻止预设加载。
    }
    return null;
  }

  static List<String> _stringList(Object? source) {
    try {
      final decoded = jsonDecode(source as String? ?? '[]');
      if (decoded is List) {
        return decoded.map((value) => '$value').toList(growable: false);
      }
    } on FormatException {
      // 损坏色板回退为空列表，编辑器可再次保存修复。
    }
    return const [];
  }

  static String _date(DateTime value) => value.toUtc().toIso8601String();

  static DateTime? _parseDate(Object? value) =>
      DateTime.tryParse(value as String? ?? '');
}
