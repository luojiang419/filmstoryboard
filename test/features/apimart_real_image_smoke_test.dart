import 'dart:io';

import 'package:filmstoryboard/features/storyboard/data/image_generation_diagnostic_logger.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';
import 'package:test/test.dart';

void main() {
  final runRealApiMart = Platform.environment['RUN_REAL_APIMART'] == '1';

  test(
    'APIMart GPT Image 2 Official 真实最低规格文生图',
    () async {
      final apiKey = (Platform.environment['APIMART_API_KEY'] ?? '').trim();
      expect(apiKey, isNotEmpty, reason: '真实测试需要 APIMART_API_KEY');
      final baseUrl =
          (Platform.environment['APIMART_API_BASE_URL'] ??
                  ImageGenerationService.apiMartBaseUrl)
              .trim();
      final outputPath = (Platform.environment['APIMART_SMOKE_OUTPUT'] ?? '')
          .trim();
      final output = outputPath.isEmpty
          ? await Directory.systemTemp.createTemp('apimart_real_smoke_')
          : Directory(outputPath);
      if (outputPath.isEmpty) {
        addTearDown(() => output.delete(recursive: true));
      }
      await output.create(recursive: true);

      final service = ImageGenerationService(
        diagnosticLogger: ImageGenerationDiagnosticLogger(
          Directory('${output.path}${Platform.pathSeparator}logs'),
        ),
      );
      addTearDown(service.close);

      final result = await service.generateTextToImage(
        ImageGenerationRequest(
          provider: ImageGenerationProviderConnection(
            providerId: 'apimart',
            providerLabel: 'APIMart',
            protocol: ImageGenerationProviderProtocol.apiMart,
            apiBaseUrl: baseUrl,
            apiKey: apiKey,
          ),
          model: 'apimart:gpt-image-2-official',
          prompt:
              'A single matte blue cube centered on a clean light gray studio background, soft shadow, minimal product photography, no text',
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'low',
          referenceImagePaths: const [],
          outputDirectory: output,
        ),
      );

      final generated = File(result.localPath);
      expect(await generated.exists(), isTrue);
      expect(await generated.length(), greaterThan(1024));
      expect(result.remoteUrl, startsWith('http'));
      // ignore: avoid_print
      print('APIMart real smoke image: ${generated.path}');
    },
    skip: runRealApiMart ? false : '设置 RUN_REAL_APIMART=1 后才调用真实 APIMart 生图',
    timeout: const Timeout(Duration(minutes: 35)),
  );
}
