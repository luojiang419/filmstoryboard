class ApiEndpointNormalizer {
  const ApiEndpointNormalizer._();

  static Uri normalizeChatCompletionsEndpoint(String input) {
    return _normalizeProtocolEndpoint(input, '/v1/chat/completions');
  }

  static Uri normalizeResponsesEndpoint(
    String baseUrl, {
    String endpoint = '/v1/responses',
  }) {
    final base = _normalizeBaseUrl(baseUrl);
    if (base.path.endsWith('/responses')) {
      return base;
    }
    final override = endpoint.trim();
    if (override.isEmpty) {
      return _appendPath(base, '/v1/responses');
    }
    if (_hasScheme(override)) {
      return _normalizeProtocolEndpoint(override, '/v1/responses');
    }
    if (!override.startsWith('/')) {
      throw const FormatException('Responses 端点必须是 / 开头的路径或完整 URL');
    }
    return _appendPath(base, override);
  }

  static String normalizeEndpointOverride(
    String value, {
    required String defaultPath,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return defaultPath;
    if (_hasScheme(trimmed)) {
      return _normalizeBaseUrl(trimmed).toString();
    }
    if (!trimmed.startsWith('/')) {
      throw const FormatException('API 端点必须是 / 开头的路径或完整 URL');
    }
    final normalized = '/${trimmed.replaceFirst(RegExp(r'^/+'), '')}'
        .replaceAll(RegExp(r'/+'), '/');
    return normalized == '/' ? defaultPath : normalized;
  }

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

  static Uri _normalizeProtocolEndpoint(String input, String defaultPath) {
    final base = _normalizeBaseUrl(input);
    final path = base.path == '/' || base.path.isEmpty
        ? defaultPath
        : base.path.endsWith('/chat/completions') ||
              base.path.endsWith('/responses')
        ? base.path
        : base.path.endsWith('/v1')
        ? '${base.path}$defaultPath'.replaceFirst('/v1/v1', '/v1')
        : '${base.path}$defaultPath';
    return base.replace(path: path.replaceAll(RegExp(r'/+'), '/'));
  }

  static Uri _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('API 地址不能为空');
    }
    final candidate = _hasScheme(trimmed)
        ? trimmed
        : '${_defaultSchemeFor(trimmed)}://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('API 地址格式不正确');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('API 地址仅支持 http 或 https');
    }
    if (uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('API 地址不能包含用户名、密码、查询参数或片段');
    }
    return uri.replace(
      path: uri.path.isEmpty ? '/' : uri.path.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  static Uri _appendPath(Uri base, String endpoint) {
    final basePath = base.path == '/'
        ? ''
        : base.path.replaceAll(RegExp(r'/+$'), '');
    final endpointPath = '/${endpoint.replaceFirst(RegExp(r'^/+'), '')}'
        .replaceAll(RegExp(r'/+'), '/');
    final path = '$basePath$endpointPath'.replaceFirst('/v1/v1', '/v1');
    return base.replace(path: path);
  }

  static String _defaultSchemeFor(String value) {
    final host = value.split('/').first.split(':').first.toLowerCase();
    final isIpv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
    return host == 'localhost' || host == '127.0.0.1' || isIpv4
        ? 'http'
        : 'https';
  }
}
