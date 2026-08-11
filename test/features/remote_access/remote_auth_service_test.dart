import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late RemoteAuthService auth;

  setUp(() {
    now = DateTime.utc(2026, 8, 10, 12);
    auth = RemoteAuthService(
      config: RemoteAccessConfig(
        sessionDuration: const Duration(hours: 1),
        pairingCodeTtl: const Duration(minutes: 5),
      ),
      now: () => now,
      tokenFactory: () => 'stable-test-access-token-value',
      pairingCodeFactory: () => '123456',
    );
  });

  test('配对码只能使用一次且令牌只按哈希认证', () {
    auth.createPairingCode();
    final result = auth.pair(
      code: '123456',
      clientName: '导演的浏览器',
      attemptKey: '127.0.0.1',
    );

    expect(result.token, 'stable-test-access-token-value');
    expect(auth.authenticate(result.token)?.clientName, '导演的浏览器');
    expect(
      () => auth.pair(
        code: '123456',
        clientName: '第二个浏览器',
        attemptKey: '127.0.0.2',
      ),
      throwsA(
        isA<RemoteAuthException>().having(
          (error) => error.code,
          'code',
          'invalid_pairing_code',
        ),
      ),
    );
  });

  test('只读会话不能通过导演角色校验', () {
    auth.createPairingCode(role: RemoteAccessRole.viewer);
    final result = auth.pair(
      code: '123456',
      clientName: '审阅平板',
      attemptKey: 'viewer',
    );

    expect(
      auth.authenticate(result.token, requiredRole: RemoteAccessRole.director),
      isNull,
    );
    expect(auth.authenticate(result.token), isNotNull);
  });

  test('过期或撤销的会话不能继续认证', () {
    auth.createPairingCode();
    final result = auth.pair(
      code: '123456',
      clientName: '浏览器',
      attemptKey: 'client',
    );

    now = now.add(const Duration(hours: 2));
    expect(auth.authenticate(result.token), isNull);

    auth.createPairingCode();
    final replacement = auth.pair(
      code: '123456',
      clientName: '浏览器',
      attemptKey: 'client',
    );
    expect(auth.revokeToken(replacement.token), isTrue);
    expect(auth.authenticate(replacement.token), isNull);
  });

  test('一分钟内五次错误配对后触发限流', () {
    auth.createPairingCode();
    for (var index = 0; index < 5; index++) {
      expect(
        () => auth.pair(
          code: '000000',
          clientName: '浏览器',
          attemptKey: 'limited-client',
        ),
        throwsA(isA<RemoteAuthException>()),
      );
    }

    expect(
      () => auth.pair(
        code: '123456',
        clientName: '浏览器',
        attemptKey: 'limited-client',
      ),
      throwsA(
        isA<RemoteAuthException>().having(
          (error) => error.code,
          'code',
          'pairing_rate_limited',
        ),
      ),
    );
  });

  test('WebSocket 票据 30 秒内仅能消费一次', () {
    auth = RemoteAuthService(
      config: RemoteAccessConfig(),
      now: () => now,
      tokenFactory: () => 'stable-test-access-token-value',
      pairingCodeFactory: () => '123456',
      ticketFactory: () => 'single-use-websocket-ticket',
    );
    auth.createPairingCode();
    final result = auth.pair(
      code: '123456',
      clientName: '导演浏览器',
      attemptKey: 'ticket-client',
    );

    final ticket = auth.issueWebSocketTicket(result.token);

    expect(auth.consumeWebSocketTicket(ticket.ticket), isNotNull);
    expect(auth.consumeWebSocketTicket(ticket.ticket), isNull);
  });
}
