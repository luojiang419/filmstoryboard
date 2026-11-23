import 'dart:convert';
import 'dart:io';

class RemoteAuditEvent {
  const RemoteAuditEvent({
    required this.action,
    required this.outcome,
    required this.requestId,
    required this.timestamp,
    this.sessionId,
    this.clientAddress,
    this.metadata = const {},
  });

  final String action;
  final String outcome;
  final String requestId;
  final DateTime timestamp;
  final String? sessionId;
  final String? clientAddress;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'action': action,
    'outcome': outcome,
    'requestId': requestId,
    if (sessionId != null) 'sessionId': sessionId,
    if (clientAddress != null) 'clientAddress': clientAddress,
    if (metadata.isNotEmpty) 'metadata': _redactMap(metadata),
  };

  static Map<String, Object?> _redactMap(Map<String, Object?> source) => {
    for (final entry in source.entries)
      entry.key: _sensitiveKey.hasMatch(entry.key)
          ? '[REDACTED]'
          : _redactValue(entry.value),
  };

  static Object? _redactValue(Object? value) => switch (value) {
    final Map<String, Object?> map => _redactMap(map),
    final List<Object?> list => list.map(_redactValue).toList(),
    final String text when _looksLikeAbsolutePath(text) => '[LOCAL_PATH]',
    _ => value,
  };

  static bool _looksLikeAbsolutePath(String value) =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
      value.startsWith(r'\\') ||
      value.startsWith('/');

  static final _sensitiveKey = RegExp(
    r'(authorization|token|secret|password|pairing.?code|api.?key|local.?path|absolute.?path)',
    caseSensitive: false,
  );
}

abstract interface class RemoteAuditLogger {
  Future<void> record(RemoteAuditEvent event);
}

class NoopRemoteAuditLogger implements RemoteAuditLogger {
  const NoopRemoteAuditLogger();

  @override
  Future<void> record(RemoteAuditEvent event) async {}
}

class JsonLineRemoteAuditLogger implements RemoteAuditLogger {
  JsonLineRemoteAuditLogger(this.file);

  final File file;
  Future<void> _pending = Future<void>.value();

  @override
  Future<void> record(RemoteAuditEvent event) {
    _pending = _pending.catchError((_) {}).then((_) async {
      if (!file.parent.existsSync()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    return _pending;
  }
}
