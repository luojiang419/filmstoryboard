import 'dart:convert';

class ProjectManifest {
  const ProjectManifest({
    required this.projectId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.databasePath = 'database/project.sqlite',
    this.coverPath,
  });

  static const format = 'storyboard-project';
  static const supportedSchemaVersion = 1;

  final String projectId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String databasePath;
  final String? coverPath;

  Map<String, Object?> toJson() => {
    'format': format,
    'schemaVersion': supportedSchemaVersion,
    'projectId': projectId,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'databasePath': databasePath,
    'coverPath': coverPath,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory ProjectManifest.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('工程索引不是有效的 JSON 对象');
    }
    if (decoded['format'] != format) {
      throw const FormatException('不是故事板工程索引');
    }
    final version = decoded['schemaVersion'];
    if (version is! int || version < 1) {
      throw const FormatException('工程索引版本无效');
    }
    if (version > supportedSchemaVersion) {
      throw UnsupportedError('工程由更高版本的软件创建，请先更新故事板');
    }
    final projectId = _requiredString(decoded, 'projectId');
    final name = _requiredString(decoded, 'name');
    final createdAt = DateTime.tryParse(_requiredString(decoded, 'createdAt'));
    final updatedAt = DateTime.tryParse(_requiredString(decoded, 'updatedAt'));
    if (createdAt == null || updatedAt == null) {
      throw const FormatException('工程时间字段无效');
    }
    return ProjectManifest(
      projectId: projectId,
      name: name,
      createdAt: createdAt,
      updatedAt: updatedAt,
      databasePath: _requiredString(decoded, 'databasePath'),
      coverPath: switch (decoded['coverPath']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
    );
  }

  ProjectManifest copyWith({
    String? projectId,
    String? name,
    DateTime? updatedAt,
    String? coverPath,
    bool clearCoverPath = false,
  }) {
    return ProjectManifest(
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      databasePath: databasePath,
      coverPath: clearCoverPath ? null : coverPath ?? this.coverPath,
    );
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('工程索引缺少 $key');
    }
    return value.trim();
  }
}
