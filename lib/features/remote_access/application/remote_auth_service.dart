import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../domain/remote_access_config.dart';
import '../domain/remote_auth_models.dart';

class RemoteAuthService {
  RemoteAuthService({
    required RemoteAccessConfig config,
    DateTime Function()? now,
    String Function()? tokenFactory,
    String Function()? pairingCodeFactory,
    String Function()? ticketFactory,
  }) : _config = config.validated(),
       _now = now ?? DateTime.now,
       _tokenFactory = tokenFactory ?? _secureToken,
       _pairingCodeFactory = pairingCodeFactory ?? _securePairingCode,
       _ticketFactory = ticketFactory ?? _secureToken;

  final RemoteAccessConfig _config;
  final DateTime Function() _now;
  final String Function() _tokenFactory;
  final String Function() _pairingCodeFactory;
  final String Function() _ticketFactory;
  final Map<String, _StoredSession> _sessionsByHash = {};
  final Map<String, _StoredWebSocketTicket> _webSocketTickets = {};
  final Map<String, _AttemptWindow> _pairAttempts = {};
  _StoredPairingCode? _pairingCode;

  RemotePairingCode createPairingCode({
    RemoteAccessRole role = RemoteAccessRole.director,
  }) {
    final code = _pairingCodeFactory();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw StateError('配对码生成器必须返回 6 位数字');
    }
    final expiresAt = _now().toUtc().add(_config.pairingCodeTtl);
    _pairingCode = _StoredPairingCode(
      hash: _hash(code),
      role: role,
      expiresAt: expiresAt,
    );
    return RemotePairingCode(code: code, role: role, expiresAt: expiresAt);
  }

  RemotePairingResult pair({
    required String code,
    required String clientName,
    required String attemptKey,
  }) {
    final now = _now().toUtc();
    _prune(now);
    _checkAttemptLimit(attemptKey, now);
    final pairing = _pairingCode;
    if (pairing == null ||
        !pairing.expiresAt.isAfter(now) ||
        !_constantTimeEquals(pairing.hash, _hash(code.trim()))) {
      _recordFailedAttempt(attemptKey, now);
      throw const RemoteAuthException('invalid_pairing_code', '配对码无效或已过期');
    }

    final normalizedName = clientName.trim();
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const RemoteAuthException(
        'invalid_client_name',
        '客户端名称不能为空且不能超过 80 个字符',
      );
    }
    _pairingCode = null;
    _pairAttempts.remove(attemptKey);
    if (_sessionsByHash.length >= 8) {
      final oldest = _sessionsByHash.entries.reduce(
        (left, right) =>
            left.value.createdAt.isBefore(right.value.createdAt) ? left : right,
      );
      _sessionsByHash.remove(oldest.key);
    }
    final token = _tokenFactory();
    final tokenHash = _hash(token);
    final session = _StoredSession(
      id: tokenHash.substring(0, 16),
      clientName: normalizedName,
      role: pairing.role,
      createdAt: now,
      expiresAt: now.add(_config.sessionDuration),
      lastSeenAt: now,
    );
    _sessionsByHash[tokenHash] = session;
    return RemotePairingResult(token: token, session: session.view);
  }

  RemoteSessionView? authenticate(
    String token, {
    RemoteAccessRole requiredRole = RemoteAccessRole.viewer,
  }) {
    final normalized = token.trim();
    if (normalized.isEmpty) return null;
    final now = _now().toUtc();
    _prune(now);
    final session = _sessionsByHash[_hash(normalized)];
    if (session == null || !session.role.allows(requiredRole)) return null;
    session.lastSeenAt = now;
    return session.view;
  }

  bool revokeToken(String token) =>
      _sessionsByHash.remove(_hash(token)) != null;

  bool revokeSession(String sessionId) {
    String? matchedHash;
    for (final entry in _sessionsByHash.entries) {
      if (entry.value.id == sessionId) matchedHash = entry.key;
    }
    return matchedHash != null && _sessionsByHash.remove(matchedHash) != null;
  }

  void revokeAll() {
    _sessionsByHash.clear();
    _webSocketTickets.clear();
    _pairingCode = null;
    _pairAttempts.clear();
  }

  List<RemoteSessionView> listSessions() {
    _prune(_now().toUtc());
    final sessions = _sessionsByHash.values.map((value) => value.view).toList();
    sessions.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return sessions;
  }

  RemoteWebSocketTicket issueWebSocketTicket(String accessToken) {
    final now = _now().toUtc();
    _prune(now);
    final sessionHash = _hash(accessToken.trim());
    if (!_sessionsByHash.containsKey(sessionHash)) {
      throw const RemoteAuthException('invalid_session', '远程会话无效或已过期');
    }
    final ticket = _ticketFactory();
    final expiresAt = now.add(const Duration(seconds: 30));
    _webSocketTickets[_hash(ticket)] = _StoredWebSocketTicket(
      sessionHash: sessionHash,
      expiresAt: expiresAt,
    );
    return RemoteWebSocketTicket(ticket: ticket, expiresAt: expiresAt);
  }

  RemoteSessionView? consumeWebSocketTicket(String ticket) {
    final now = _now().toUtc();
    _prune(now);
    final stored = _webSocketTickets.remove(_hash(ticket.trim()));
    if (stored == null || !stored.expiresAt.isAfter(now)) return null;
    final session = _sessionsByHash[stored.sessionHash];
    if (session == null) return null;
    session.lastSeenAt = now;
    return session.view;
  }

  void _checkAttemptLimit(String key, DateTime now) {
    final window = _pairAttempts[key];
    if (window != null &&
        now.difference(window.startedAt) < const Duration(minutes: 1) &&
        window.failures >= 5) {
      throw const RemoteAuthException('pairing_rate_limited', '配对失败次数过多，请稍后重试');
    }
  }

  void _recordFailedAttempt(String key, DateTime now) {
    final current = _pairAttempts[key];
    if (current == null ||
        now.difference(current.startedAt) >= const Duration(minutes: 1)) {
      _pairAttempts[key] = _AttemptWindow(startedAt: now, failures: 1);
      return;
    }
    current.failures++;
  }

  void _prune(DateTime now) {
    _sessionsByHash.removeWhere(
      (_, session) => !session.expiresAt.isAfter(now),
    );
    _webSocketTickets.removeWhere(
      (_, ticket) =>
          !ticket.expiresAt.isAfter(now) ||
          !_sessionsByHash.containsKey(ticket.sessionHash),
    );
    _pairAttempts.removeWhere(
      (_, window) =>
          now.difference(window.startedAt) >= const Duration(minutes: 1),
    );
    if (_pairingCode case final pairing? when !pairing.expiresAt.isAfter(now)) {
      _pairingCode = null;
    }
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  static String _secureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _securePairingCode() =>
      Random.secure().nextInt(1000000).toString().padLeft(6, '0');
}

class _StoredPairingCode {
  const _StoredPairingCode({
    required this.hash,
    required this.role,
    required this.expiresAt,
  });

  final String hash;
  final RemoteAccessRole role;
  final DateTime expiresAt;
}

class _StoredSession {
  _StoredSession({
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
  DateTime lastSeenAt;

  RemoteSessionView get view => RemoteSessionView(
    id: id,
    clientName: clientName,
    role: role,
    createdAt: createdAt,
    expiresAt: expiresAt,
    lastSeenAt: lastSeenAt,
  );
}

class _AttemptWindow {
  _AttemptWindow({required this.startedAt, required this.failures});

  final DateTime startedAt;
  int failures;
}

class _StoredWebSocketTicket {
  const _StoredWebSocketTicket({
    required this.sessionHash,
    required this.expiresAt,
  });

  final String sessionHash;
  final DateTime expiresAt;
}
