import 'dart:convert';
import 'dart:io';

class RemoteAccessConfig {
  RemoteAccessConfig({
    this.enabled = false,
    InternetAddress? bindAddress,
    this.port = defaultPort,
    this.allowLan = false,
    this.allowedOrigins = const [],
    this.sessionDuration = const Duration(hours: 24),
    this.pairingCodeTtl = const Duration(minutes: 10),
    this.maxRequestBodyBytes = 10 * 1024 * 1024,
  }) : bindAddress = bindAddress ?? InternetAddress.loopbackIPv4;

  static const defaultPort = 47836;

  final bool enabled;
  final InternetAddress bindAddress;
  final int port;
  final bool allowLan;
  final List<String> allowedOrigins;
  final Duration sessionDuration;
  final Duration pairingCodeTtl;
  final int maxRequestBodyBytes;

  RemoteAccessConfig validated() {
    if (port < 1024 || port > 65535) {
      throw const FormatException('远程访问端口必须在 1024 到 65535 之间');
    }
    if (!allowLan && !bindAddress.isLoopback) {
      throw const FormatException('未允许局域网访问时只能监听本机回环地址');
    }
    if (sessionDuration < const Duration(minutes: 5) ||
        sessionDuration > const Duration(days: 30)) {
      throw const FormatException('远程会话有效期必须在 5 分钟到 30 天之间');
    }
    if (pairingCodeTtl < const Duration(minutes: 1) ||
        pairingCodeTtl > const Duration(minutes: 30)) {
      throw const FormatException('配对码有效期必须在 1 到 30 分钟之间');
    }
    if (maxRequestBodyBytes < 1024 || maxRequestBodyBytes > 100 * 1024 * 1024) {
      throw const FormatException('请求体上限必须在 1KB 到 100MB 之间');
    }
    for (final origin in allowedOrigins) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          !uri.hasScheme ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.path != '' ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw FormatException('不合法的 Web 来源：$origin');
      }
    }
    return this;
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'bindAddress': bindAddress.address,
    'port': port,
    'allowLan': allowLan,
    'allowedOrigins': allowedOrigins,
    'sessionDurationMinutes': sessionDuration.inMinutes,
    'pairingCodeTtlMinutes': pairingCodeTtl.inMinutes,
    'maxRequestBodyBytes': maxRequestBodyBytes,
  };

  String encode() => jsonEncode(toJson());

  factory RemoteAccessConfig.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('远程访问配置不是有效的 JSON 对象');
    }
    final addressText = _string(decoded, 'bindAddress', '127.0.0.1');
    final addresses = InternetAddress.tryParse(addressText);
    if (addresses == null) {
      throw const FormatException('远程访问监听地址无效');
    }
    final origins = decoded['allowedOrigins'];
    return RemoteAccessConfig(
      enabled: _bool(decoded, 'enabled', false),
      bindAddress: addresses,
      port: _int(decoded, 'port', defaultPort),
      allowLan: _bool(decoded, 'allowLan', false),
      allowedOrigins: origins is List
          ? origins
                .map((value) => '$value'.trim())
                .where((e) => e.isNotEmpty)
                .toList()
          : const [],
      sessionDuration: Duration(
        minutes: _int(decoded, 'sessionDurationMinutes', 24 * 60),
      ),
      pairingCodeTtl: Duration(
        minutes: _int(decoded, 'pairingCodeTtlMinutes', 10),
      ),
      maxRequestBodyBytes: _int(
        decoded,
        'maxRequestBodyBytes',
        10 * 1024 * 1024,
      ),
    ).validated();
  }

  RemoteAccessConfig copyWith({
    bool? enabled,
    InternetAddress? bindAddress,
    int? port,
    bool? allowLan,
    List<String>? allowedOrigins,
    Duration? sessionDuration,
    Duration? pairingCodeTtl,
    int? maxRequestBodyBytes,
  }) => RemoteAccessConfig(
    enabled: enabled ?? this.enabled,
    bindAddress: bindAddress ?? this.bindAddress,
    port: port ?? this.port,
    allowLan: allowLan ?? this.allowLan,
    allowedOrigins: allowedOrigins ?? this.allowedOrigins,
    sessionDuration: sessionDuration ?? this.sessionDuration,
    pairingCodeTtl: pairingCodeTtl ?? this.pairingCodeTtl,
    maxRequestBodyBytes: maxRequestBodyBytes ?? this.maxRequestBodyBytes,
  );

  static String _string(
    Map<String, Object?> values,
    String key,
    String fallback,
  ) => switch (values[key]) {
    final String value when value.trim().isNotEmpty => value.trim(),
    _ => fallback,
  };

  static int _int(Map<String, Object?> values, String key, int fallback) =>
      switch (values[key]) {
        final int value => value,
        final num value => value.toInt(),
        _ => fallback,
      };

  static bool _bool(Map<String, Object?> values, String key, bool fallback) =>
      switch (values[key]) {
        final bool value => value,
        _ => fallback,
      };
}
