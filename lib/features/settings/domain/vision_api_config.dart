class VisionApiConfig {
  const VisionApiConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.maxRequestsPerMinute = 200,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// MiniMax-M3 的视觉请求在 60 秒滑动窗口内允许发出的最大数量。
  /// 非 MiniMax 配置会忽略该值，保持既有串行策略。
  final int maxRequestsPerMinute;

  VisionApiConfig copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    int? maxRequestsPerMinute,
  }) {
    return VisionApiConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      maxRequestsPerMinute: maxRequestsPerMinute ?? this.maxRequestsPerMinute,
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'maxRequestsPerMinute': maxRequestsPerMinute.toString(),
  };

  factory VisionApiConfig.fromJson(Map<String, dynamic> json) {
    return VisionApiConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名视觉模型',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      maxRequestsPerMinute: _readMaxRequestsPerMinute(
        json['maxRequestsPerMinute'],
      ),
    );
  }

  static int _readMaxRequestsPerMinute(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return (parsed ?? 200).clamp(1, 200);
  }
}
