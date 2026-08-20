import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/quick_replication_person_count_service.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:test/test.dart';

void main() {
  test('快速解析只提交人数识别提示词和极小输出额度', () async {
    final root = await Directory.systemTemp.createTemp(
      'quick_person_count_service_',
    );
    addTearDown(() => root.delete(recursive: true));
    final image = File('${root.path}/models.jpg')..writeAsBytesSync([1, 2, 3]);
    final vision = _RecordingVisionService('```json\n{"person_count": 3}\n```');
    final service = QuickReplicationPersonCountService(visionService: vision);

    final result = await service.analyze(
      settings: _settings(),
      imageFile: image,
      shotNumber: 8,
    );

    expect(result.personCount, 3);
    expect(vision.maxTokens, 64);
    expect(vision.allowThinking, isFalse);
    expect(vision.imagePaths, [image.path]);
    expect(vision.prompt, contains('只识别镜头 8'));
    expect(vision.prompt, contains('模特A、模特B直到模特N'));
    expect(vision.prompt, contains('{"person_count":2}'));
    expect(vision.prompt, isNot(contains('逐关节')));
    expect(vision.prompt, isNot(contains('preservable_elements')));
    expect(vision.prompt, isNot(contains('products')));
  });

  test('人数结果兼容解释文字并拒绝越界值', () {
    const service = QuickReplicationPersonCountService();
    expect(service.parseResponse('结果如下：{"personCount":"2"}').personCount, 2);
    expect(
      () => service.parseResponse('{"person_count":21}'),
      throwsFormatException,
    );
    expect(() => service.parseResponse('{"people":[]}'), throwsFormatException);
  });
}

AppSettings _settings() => AppSettings(
  exportDirectory: 'exports',
  themePreference: AppThemePreference.system,
  cutImageNumberEnabled: false,
  cutImageNumberPosition: CutImageNumberPosition.topLeft,
  cutImageNumberBackgroundOpacity:
      AppSettings.defaultCutImageNumberBackgroundOpacity,
  cutImageNumberTextScale: AppSettings.defaultCutImageNumberTextScale,
  storyboardSummaryPageEnabled: true,
  visionApiBaseUrl: '127.0.0.1:12345',
  visionApiKey: 'test-key',
  visionModel: 'test-vlm',
  imageGenerationApiBaseUrl: 'https://example.test',
  imageGenerationApiKey: 'test-image-key',
  imageGenerationGeminiApiKey: 'test-gemini-key',
  imageGenerationModel: 'nano-banana-fast',
  updateReleaseApiUrl: '',
  autoInstallUpdates: false,
  updateDownloadMode: UpdateDownloadMode.automatic,
  updateManualProxyUrl: 'http://127.0.0.1:7890',
);

class _RecordingVisionService extends VisionStoryboardService {
  _RecordingVisionService(this.response);

  final String response;
  String prompt = '';
  List<String> imagePaths = const [];
  int maxTokens = 0;
  bool allowThinking = true;

  @override
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
    Duration responseTimeout = VisionStoryboardService.requestTimeout,
    bool compressOversizedImages = false,
  }) async {
    this.prompt = prompt;
    imagePaths = [for (final file in imageFiles) file.path];
    this.maxTokens = maxTokens;
    this.allowThinking = allowThinking;
    return response;
  }
}
