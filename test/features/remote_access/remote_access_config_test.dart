import 'dart:io';

import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteAccessConfig', () {
    test('安全默认值为关闭且仅监听回环地址', () {
      final config = RemoteAccessConfig().validated();

      expect(config.enabled, isFalse);
      expect(config.bindAddress.isLoopback, isTrue);
      expect(config.port, RemoteAccessConfig.defaultPort);
      expect(config.allowLan, isFalse);
    });

    test('未允许局域网时拒绝非回环监听地址', () {
      final config = RemoteAccessConfig(
        bindAddress: InternetAddress.anyIPv4,
        allowLan: false,
      );

      expect(config.validated, throwsFormatException);
    });

    test('配置编码解码保持允许来源与时限', () {
      final source = RemoteAccessConfig(
        enabled: true,
        allowedOrigins: const ['https://director.example.com'],
        sessionDuration: const Duration(hours: 8),
        pairingCodeTtl: const Duration(minutes: 5),
      );

      final decoded = RemoteAccessConfig.decode(source.encode());

      expect(decoded.enabled, isTrue);
      expect(decoded.allowedOrigins, const ['https://director.example.com']);
      expect(decoded.sessionDuration, const Duration(hours: 8));
      expect(decoded.pairingCodeTtl, const Duration(minutes: 5));
      expect(decoded.maxUploadBytes, source.maxUploadBytes);
    });
  });
}
