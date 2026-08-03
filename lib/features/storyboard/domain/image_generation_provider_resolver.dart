import '../../settings/domain/app_settings.dart';
import 'image_generation_model_catalog.dart';

class ImageGenerationProviderResolver {
  const ImageGenerationProviderResolver._();

  static ImageGenerationProviderConnection resolve({
    required AppSettings settings,
    required String model,
  }) {
    final descriptor = ImageGenerationCatalog.descriptorFor(model);
    if (descriptor == null) {
      throw FormatException('不支持的图片生成模型：$model');
    }

    var activeConfig = settings.activeImageGenerationApiConfig;
    if (activeConfig != null && activeConfig.protocol != descriptor.protocol) {
      for (final config in settings.imageGenerationApiConfigs) {
        if (config.protocol == descriptor.protocol) {
          activeConfig = config;
          break;
        }
      }
    }
    if (activeConfig != null) {
      if (activeConfig.protocol != descriptor.protocol) {
        throw FormatException(
          '当前默认图片生成 API 卡片“${activeConfig.name}”配置的是'
          '${activeConfig.providerLabel} 模型，请先在设置中选中与 ${ImageGenerationCatalog.providerLabelFor(model)} 模型匹配的卡片。',
        );
      }
      return ImageGenerationProviderConnection(
        providerId: descriptor.providerId,
        providerLabel: ImageGenerationCatalog.providerLabelFor(model),
        protocol: descriptor.protocol,
        apiBaseUrl: activeConfig.baseUrl,
        apiKey: activeConfig.apiKey,
      );
    }

    final providerLabel = ImageGenerationCatalog.providerLabelFor(model);
    return switch (descriptor.protocol) {
      ImageGenerationProviderProtocol.gemini =>
        ImageGenerationProviderConnection(
          providerId: descriptor.providerId,
          providerLabel: providerLabel,
          protocol: descriptor.protocol,
          apiBaseUrl: settings.imageGenerationGeminiApiBaseUrl,
          apiKey: settings.imageGenerationGeminiApiKey,
        ),
      ImageGenerationProviderProtocol.grsai =>
        ImageGenerationProviderConnection(
          providerId: descriptor.providerId,
          providerLabel: providerLabel,
          protocol: descriptor.protocol,
          apiBaseUrl: settings.imageGenerationApiBaseUrl,
          apiKey: settings.imageGenerationApiKey,
        ),
      ImageGenerationProviderProtocol.apiMart =>
        ImageGenerationProviderConnection(
          providerId: descriptor.providerId,
          providerLabel: providerLabel,
          protocol: descriptor.protocol,
          apiBaseUrl: settings.imageGenerationApiMartApiBaseUrl,
          apiKey: settings.imageGenerationApiMartApiKey,
        ),
    };
  }
}
