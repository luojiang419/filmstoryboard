import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/domain/image_generation_model_catalog.dart';
import 'package:filmstoryboard/features/storyboard/domain/image_generation_provider_resolver.dart';
import 'package:test/test.dart';

void main() {
  final settings = AppSettings(
    exportDirectory: 'exports',
    themePreference: AppThemePreference.system,
    cutImageNumberEnabled: false,
    cutImageNumberPosition: CutImageNumberPosition.topLeft,
    cutImageNumberBackgroundOpacity: 0.5,
    cutImageNumberTextScale: 1,
    storyboardSummaryPageEnabled: true,
    visionApiBaseUrl: 'https://vision.example',
    visionApiKey: 'vision-key',
    visionModel: 'vision-model',
    imageGenerationApiBaseUrl: 'https://grsai.example',
    imageGenerationApiKey: 'grsai-key',
    imageGenerationGeminiApiBaseUrl: 'https://www.shiying-api.com',
    imageGenerationGeminiApiKey: 'gemini-key',
    imageGenerationApiMartApiBaseUrl: 'https://apimart.example',
    imageGenerationApiMartApiKey: 'apimart-key',
    imageGenerationModel: 'nano-banana-pro',
    updateReleaseApiUrl: 'https://updates.example',
    autoInstallUpdates: false,
    updateDownloadMode: UpdateDownloadMode.direct,
    updateManualProxyUrl: '',
  );

  test('GRSai模型只解析GRSai地址和Key', () {
    final connection = ImageGenerationProviderResolver.resolve(
      settings: settings,
      model: 'nano-banana-pro',
    );

    expect(connection.providerId, 'grsai');
    expect(connection.protocol, ImageGenerationProviderProtocol.grsai);
    expect(connection.apiBaseUrl, 'https://grsai.example');
    expect(connection.apiKey, 'grsai-key');
  });

  test('Gemini模型只解析诗影独立地址和Gemini Key', () {
    final connection = ImageGenerationProviderResolver.resolve(
      settings: settings,
      model: 'gemini-3-pro-image',
    );

    expect(connection.providerId, 'gemini');
    expect(connection.protocol, ImageGenerationProviderProtocol.gemini);
    expect(connection.apiBaseUrl, 'https://www.shiying-api.com');
    expect(connection.apiKey, 'gemini-key');
  });

  test('APIMart模型只解析APIMart独立地址和Key', () {
    final connection = ImageGenerationProviderResolver.resolve(
      settings: settings,
      model: 'apimart:gemini-3-pro-image-preview',
    );

    expect(connection.providerId, 'apimart');
    expect(connection.protocol, ImageGenerationProviderProtocol.apiMart);
    expect(connection.apiBaseUrl, 'https://apimart.example');
    expect(connection.apiKey, 'apimart-key');
  });

  test('未知模型不会回退到GRSai', () {
    expect(
      () => ImageGenerationProviderResolver.resolve(
        settings: settings,
        model: 'unknown-model',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
