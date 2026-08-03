import '../../storyboard/domain/image_generation_model_catalog.dart';

class ImageGenerationApiConfig {
  const ImageGenerationApiConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;

  ImageGenerationProviderProtocol? get protocol =>
      ImageGenerationCatalog.descriptorFor(model)?.protocol;

  String get providerLabel => ImageGenerationCatalog.providerLabelFor(model);

  ImageGenerationApiConfig copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return ImageGenerationApiConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  factory ImageGenerationApiConfig.fromJson(Map<String, dynamic> json) {
    return ImageGenerationApiConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名图片生成 API',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
    );
  }
}
