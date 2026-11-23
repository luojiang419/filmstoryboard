class ApiEndpointNormalizer {
  const ApiEndpointNormalizer._();

  static String normalizeApiMartBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('请填写 APIMart API 地址');
    }

    final candidate = _hasScheme(trimmed) ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('APIMart API 地址格式不正确');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw const FormatException('APIMart API 地址仅支持 http 或 https');
    }
    if (uri.host.toLowerCase() == 'docs.apimart.ai') {
      throw const FormatException(
        'docs.apimart.ai 是文档地址，请填写 https://api.apimart.ai',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('APIMart API 地址不能包含用户名或密码');
    }

    final port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port';
  }

  static bool _hasScheme(String value) {
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
  }
}
