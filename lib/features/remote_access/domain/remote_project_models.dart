enum RemoteProjectAvailability { available, missing, invalid, newerVersion }

class RemoteProjectRecord {
  const RemoteProjectRecord({
    required this.id,
    required this.name,
    required this.availability,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOpenedAt,
    required this.isActive,
  });

  final String id;
  final String name;
  final RemoteProjectAvailability availability;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastOpenedAt;
  final bool isActive;

  bool get canOpen => availability == RemoteProjectAvailability.available;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'availability': availability.name,
    'canOpen': canOpen,
    'isActive': isActive,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
  };
}

class RemoteProjectOpenResult {
  const RemoteProjectOpenResult({
    required this.projectId,
    required this.projectName,
    required this.alreadyOpen,
  });

  final String projectId;
  final String projectName;
  final bool alreadyOpen;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'projectName': projectName,
    'alreadyOpen': alreadyOpen,
  };
}

class RemoteProjectSourceException implements Exception {
  const RemoteProjectSourceException(this.code, this.message);

  final String code;
  final String message;
}
