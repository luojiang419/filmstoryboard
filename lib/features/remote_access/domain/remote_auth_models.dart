enum RemoteAccessRole {
  viewer,
  director;

  bool allows(RemoteAccessRole requiredRole) =>
      this == director || requiredRole == viewer;
}

class RemotePairingCode {
  const RemotePairingCode({
    required this.code,
    required this.role,
    required this.expiresAt,
  });

  final String code;
  final RemoteAccessRole role;
  final DateTime expiresAt;
}

class RemoteSessionView {
  const RemoteSessionView({
    required this.id,
    required this.clientName,
    required this.role,
    required this.createdAt,
    required this.expiresAt,
    required this.lastSeenAt,
  });

  final String id;
  final String clientName;
  final RemoteAccessRole role;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime lastSeenAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'clientName': clientName,
    'role': role.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
  };
}

class RemotePairingResult {
  const RemotePairingResult({required this.token, required this.session});

  final String token;
  final RemoteSessionView session;
}

class RemoteWebSocketTicket {
  const RemoteWebSocketTicket({required this.ticket, required this.expiresAt});

  final String ticket;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'ticket': ticket,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

class RemoteAuthException implements Exception {
  const RemoteAuthException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
