import 'package:filmstoryboard/features/remote_access/data/remote_audit_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('审计事件脱敏令牌、配对码和本机绝对路径', () {
    final json = RemoteAuditEvent(
      action: 'test',
      outcome: 'success',
      requestId: 'request-1',
      timestamp: DateTime.utc(2026, 8, 10),
      metadata: const {
        'accessToken': 'secret-token',
        'pairingCode': '123456',
        'file': r'G:\project\frame.png',
        'mediaId': 'media-123',
      },
    ).toJson();

    final metadata = json['metadata']! as Map<String, Object?>;
    expect(metadata['accessToken'], '[REDACTED]');
    expect(metadata['pairingCode'], '[REDACTED]');
    expect(metadata['file'], '[LOCAL_PATH]');
    expect(metadata['mediaId'], 'media-123');
  });
}
