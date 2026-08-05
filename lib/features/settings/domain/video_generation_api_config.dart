enum VideoGenerationApiConfigKind {
  klingCli('可灵 CLI'),
  httpApi('HTTP API');

  const VideoGenerationApiConfigKind(this.label);

  final String label;

  static VideoGenerationApiConfigKind fromName(String? value) {
    return VideoGenerationApiConfigKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => VideoGenerationApiConfigKind.httpApi,
    );
  }
}

class VideoGenerationApiConfig {
  const VideoGenerationApiConfig({
    required this.id,
    required this.name,
    this.kind = VideoGenerationApiConfigKind.httpApi,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String id;
  final String name;
  final VideoGenerationApiConfigKind kind;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isKlingCli => kind == VideoGenerationApiConfigKind.klingCli;
  bool get isHttpApi => kind == VideoGenerationApiConfigKind.httpApi;

  VideoGenerationApiConfig copyWith({
    String? name,
    VideoGenerationApiConfigKind? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return VideoGenerationApiConfig(
      id: id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  factory VideoGenerationApiConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final baseUrl = json['baseUrl'] as String? ?? '';
    final kind = json.containsKey('kind')
        ? VideoGenerationApiConfigKind.fromName(json['kind'] as String?)
        : (id == 'default-kling-cli' || baseUrl.trim().isEmpty
              ? VideoGenerationApiConfigKind.klingCli
              : VideoGenerationApiConfigKind.httpApi);
    return VideoGenerationApiConfig(
      id: id,
      name: json['name'] as String? ?? '未命名视频生成 API',
      kind: kind,
      baseUrl: baseUrl,
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
    );
  }
}
