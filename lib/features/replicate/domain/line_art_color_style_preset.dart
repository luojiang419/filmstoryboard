import 'dart:convert';

import 'package:crypto/crypto.dart';

enum ReplicateSourceFrameMode { autoDetect, colorReference, lineArt }

enum LineArtColorStyleUseCase { fashion, cinema, commercial, stylized }

enum ColorStyleThumbnailType { bundledAsset, projectFile }

class ColorStyleThumbnailAttribution {
  const ColorStyleThumbnailAttribution({
    required this.repositoryName,
    required this.repositoryUrl,
    required this.licenseName,
    required this.licenseUrl,
    required this.author,
    required this.authorUrl,
    required this.sourcePostUrl,
    this.modified = true,
  });

  final String repositoryName;
  final String repositoryUrl;
  final String licenseName;
  final String licenseUrl;
  final String author;
  final String authorUrl;
  final String sourcePostUrl;
  final bool modified;

  Map<String, Object?> toJson() => {
    'repositoryName': repositoryName,
    'repositoryUrl': repositoryUrl,
    'licenseName': licenseName,
    'licenseUrl': licenseUrl,
    'author': author,
    'authorUrl': authorUrl,
    'sourcePostUrl': sourcePostUrl,
    'modified': modified,
  };

  factory ColorStyleThumbnailAttribution.fromJson(Map<String, Object?> json) =>
      ColorStyleThumbnailAttribution(
        repositoryName: _string(json['repositoryName']),
        repositoryUrl: _string(json['repositoryUrl']),
        licenseName: _string(json['licenseName']),
        licenseUrl: _string(json['licenseUrl']),
        author: _string(json['author']),
        authorUrl: _string(json['authorUrl']),
        sourcePostUrl: _string(json['sourcePostUrl']),
        modified: _bool(json['modified'], fallback: true),
      );
}

class ColorStyleThumbnailReference {
  const ColorStyleThumbnailReference({
    required this.type,
    required this.path,
    this.attribution,
  });

  const ColorStyleThumbnailReference.bundled(
    String assetPath, {
    ColorStyleThumbnailAttribution? attribution,
  }) : this(
         type: ColorStyleThumbnailType.bundledAsset,
         path: assetPath,
         attribution: attribution,
       );

  const ColorStyleThumbnailReference.projectFile(String relativePath)
    : this(type: ColorStyleThumbnailType.projectFile, path: relativePath);

  final ColorStyleThumbnailType type;

  /// Bundle asset path or a path relative to the project root.
  final String path;
  final ColorStyleThumbnailAttribution? attribution;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'path': path,
    if (attribution != null) 'attribution': attribution!.toJson(),
  };

  factory ColorStyleThumbnailReference.fromJson(Map<String, Object?> json) {
    final attribution = _objectMap(json['attribution']);
    return ColorStyleThumbnailReference(
      type: _enumValue(
        ColorStyleThumbnailType.values,
        json['type'],
        ColorStyleThumbnailType.projectFile,
      ),
      path: _string(json['path']),
      attribution: attribution == null
          ? null
          : ColorStyleThumbnailAttribution.fromJson(attribution),
    );
  }
}

class LineArtColorStylePreset {
  const LineArtColorStylePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    required this.swatches,
    required this.useCase,
    required this.isBuiltIn,
    required this.version,
    this.thumbnail,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String prompt;
  final List<String> swatches;
  final LineArtColorStyleUseCase useCase;
  final bool isBuiltIn;
  final int version;
  final ColorStyleThumbnailReference? thumbnail;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  LineArtColorStylePreset copyWith({
    String? name,
    String? description,
    String? prompt,
    List<String>? swatches,
    LineArtColorStyleUseCase? useCase,
    bool? isBuiltIn,
    int? version,
    ColorStyleThumbnailReference? thumbnail,
    bool clearThumbnail = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => LineArtColorStylePreset(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    prompt: prompt ?? this.prompt,
    swatches: swatches ?? this.swatches,
    useCase: useCase ?? this.useCase,
    isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    version: version ?? this.version,
    thumbnail: clearThumbnail ? null : thumbnail ?? this.thumbnail,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'prompt': prompt,
    'swatches': swatches,
    'useCase': useCase.name,
    'isBuiltIn': isBuiltIn,
    'version': version,
    if (thumbnail != null) 'thumbnail': thumbnail!.toJson(),
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  factory LineArtColorStylePreset.fromJson(Map<String, Object?> json) {
    final thumbnail = _objectMap(json['thumbnail']);
    return LineArtColorStylePreset(
      id: _string(json['id']),
      name: _string(json['name']),
      description: _string(json['description']),
      prompt: _string(json['prompt']),
      swatches: _stringList(json['swatches']),
      useCase: _enumValue(
        LineArtColorStyleUseCase.values,
        json['useCase'],
        LineArtColorStyleUseCase.cinema,
      ),
      isBuiltIn: _bool(json['isBuiltIn']),
      version: _int(json['version'], fallback: 1),
      thumbnail: thumbnail == null
          ? null
          : ColorStyleThumbnailReference.fromJson(thumbnail),
      createdAt: _dateTime(json['createdAt']),
      updatedAt: _dateTime(json['updatedAt']),
    );
  }
}

/// Immutable generation-time copy. Editing a preset later cannot alter a run.
class LineArtColorStyleSelectionSnapshot {
  const LineArtColorStyleSelectionSnapshot({
    required this.schemaVersion,
    required this.presetId,
    required this.presetVersion,
    required this.presetName,
    required this.prompt,
    required this.swatches,
    required this.fingerprint,
    this.thumbnail,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String presetId;
  final int presetVersion;
  final String presetName;
  final String prompt;
  final List<String> swatches;
  final ColorStyleThumbnailReference? thumbnail;
  final String fingerprint;

  factory LineArtColorStyleSelectionSnapshot.fromPreset(
    LineArtColorStylePreset preset,
  ) {
    final payload = _snapshotPayload(
      schemaVersion: currentSchemaVersion,
      presetId: preset.id,
      presetVersion: preset.version,
      presetName: preset.name,
      prompt: preset.prompt,
      swatches: preset.swatches,
      thumbnail: preset.thumbnail,
    );
    return LineArtColorStyleSelectionSnapshot(
      schemaVersion: currentSchemaVersion,
      presetId: preset.id,
      presetVersion: preset.version,
      presetName: preset.name,
      prompt: preset.prompt,
      swatches: List<String>.unmodifiable(preset.swatches),
      thumbnail: preset.thumbnail,
      fingerprint: _fingerprint(payload),
    );
  }

  bool get hasValidFingerprint =>
      fingerprint ==
      _fingerprint(
        _snapshotPayload(
          schemaVersion: schemaVersion,
          presetId: presetId,
          presetVersion: presetVersion,
          presetName: presetName,
          prompt: prompt,
          swatches: swatches,
          thumbnail: thumbnail,
        ),
      );

  Map<String, Object?> toJson() => {
    ..._snapshotPayload(
      schemaVersion: schemaVersion,
      presetId: presetId,
      presetVersion: presetVersion,
      presetName: presetName,
      prompt: prompt,
      swatches: swatches,
      thumbnail: thumbnail,
    ),
    'fingerprint': fingerprint,
  };

  factory LineArtColorStyleSelectionSnapshot.fromJson(
    Map<String, Object?> json,
  ) {
    final thumbnail = _objectMap(json['thumbnail']);
    return LineArtColorStyleSelectionSnapshot(
      schemaVersion: _int(json['schemaVersion'], fallback: 1),
      presetId: _string(json['presetId']),
      presetVersion: _int(json['presetVersion'], fallback: 1),
      presetName: _string(json['presetName']),
      prompt: _string(json['prompt']),
      swatches: _stringList(json['swatches']),
      thumbnail: thumbnail == null
          ? null
          : ColorStyleThumbnailReference.fromJson(thumbnail),
      fingerprint: _string(json['fingerprint']),
    );
  }
}

Map<String, Object?> _snapshotPayload({
  required int schemaVersion,
  required String presetId,
  required int presetVersion,
  required String presetName,
  required String prompt,
  required List<String> swatches,
  required ColorStyleThumbnailReference? thumbnail,
}) => {
  'schemaVersion': schemaVersion,
  'presetId': presetId,
  'presetVersion': presetVersion,
  'presetName': presetName,
  'prompt': prompt,
  'swatches': swatches,
  if (thumbnail != null) 'thumbnail': thumbnail.toJson(),
};

String _fingerprint(Map<String, Object?> payload) =>
    sha256.convert(utf8.encode(jsonEncode(payload))).toString();

String _string(Object? value) => value?.toString().trim() ?? '';

int _int(Object? value, {int fallback = 0}) =>
    value is num ? value.toInt() : int.tryParse(_string(value)) ?? fallback;

bool _bool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final normalized = _string(value).toLowerCase();
  if (normalized == 'true' || normalized == '1') return true;
  if (normalized == 'false' || normalized == '0') return false;
  return fallback;
}

T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final name = _string(raw);
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<String> _stringList(Object? value) {
  if (value is! Iterable) return const [];
  return List<String>.unmodifiable(
    value.map(_string).where((item) => item.isNotEmpty),
  );
}

DateTime? _dateTime(Object? value) => DateTime.tryParse(_string(value));
