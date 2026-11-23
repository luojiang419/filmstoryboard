import 'dart:convert';

import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/minimax_video_api_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const config = VideoGenerationApiConfig(
    id: 'local-h3',
    name: '本地 H3',
    baseUrl: 'http://127.0.0.1:7860',
    apiKey: 'test-key',
    model: 'minimax-h3-local',
  );

  test('读取 H3 本地 API 返回的分辨率列表与默认值', () async {
    final service = MiniMaxVideoApiService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/config');
        expect(request.headers['authorization'], 'Bearer test-key');
        return http.Response(
          jsonEncode({
            'resolutions': [
              '0.2MP 16:9 - 608x352',
              '0.8MP 16:9 - 1216x704',
              '0.8MP 16:9 - 1216x704',
              '',
            ],
            'defaults': {'resolution': '0.8MP 16:9 - 1216x704', 'steps': 18},
          }),
          200,
        );
      }),
    );

    final result = await service.fetchConfig(config: config);

    expect(result.resolutions, [
      '0.2MP 16:9 - 608x352',
      '0.8MP 16:9 - 1216x704',
    ]);
    expect(result.defaultResolution, '0.8MP 16:9 - 1216x704');
    expect(result.defaultSteps, 18);
  });

  test('分辨率列表为空时拒绝使用无效配置', () async {
    final service = MiniMaxVideoApiService(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'resolutions': []}), 200),
      ),
    );

    await expectLater(
      service.fetchConfig(config: config),
      throwsA(isA<KlingCliException>()),
    );
  });
}
