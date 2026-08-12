enum VideoGenerationApiConfigKind {
  klingCli('可灵 CLI'),
  libTvCli('LibTV CLI'),
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
    this.klingCliRegion = '',
  });

  final String id;
  final String name;
  final VideoGenerationApiConfigKind kind;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String klingCliRegion;

  bool get isKlingCli => kind == VideoGenerationApiConfigKind.klingCli;
  bool get isLibTvCli => kind == VideoGenerationApiConfigKind.libTvCli;
  bool get isHttpApi => kind == VideoGenerationApiConfigKind.httpApi;

  bool get isLocalHttpApi {
    if (!isHttpApi) return false;
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0';
  }

  bool get isMiniMaxH3Model {
    final identity = [id, name, model].join(' ').toLowerCase();
    return identity.contains('minimax') ||
        identity.contains('海螺') ||
        RegExp(r'(^|[^a-z0-9])h3([^a-z0-9]|$)').hasMatch(identity);
  }

  /// H3 专项 Skill 只服务软件内连接的本地 H3 后端。
  bool get supportsLocalH3SkillRouting => isLocalHttpApi && isMiniMaxH3Model;

  VideoGenerationApiConfig copyWith({
    String? name,
    VideoGenerationApiConfigKind? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? klingCliRegion,
  }) {
    return VideoGenerationApiConfig(
      id: id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      klingCliRegion: klingCliRegion ?? this.klingCliRegion,
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'klingCliRegion': klingCliRegion,
  };

  factory VideoGenerationApiConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final baseUrl = json['baseUrl'] as String? ?? '';
    final kind = json.containsKey('kind')
        ? VideoGenerationApiConfigKind.fromName(json['kind'] as String?)
        : switch (id) {
            'default-libtv-cli' => VideoGenerationApiConfigKind.libTvCli,
            'default-kling-cli' => VideoGenerationApiConfigKind.klingCli,
            _ =>
              baseUrl.trim().isEmpty
                  ? VideoGenerationApiConfigKind.klingCli
                  : VideoGenerationApiConfigKind.httpApi,
          };
    return VideoGenerationApiConfig(
      id: id,
      name: json['name'] as String? ?? '未命名视频生成 API',
      kind: kind,
      baseUrl: baseUrl,
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      klingCliRegion: json['klingCliRegion'] as String? ?? '',
    );
  }
}
