import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/features/storyboard/data/image_generation_diagnostic_logger.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';
import 'package:test/test.dart';

void main() {
  test('纯文生图允许不传参考图并发送空 images', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_service_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'result.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/api/generate') {
          submitBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'task-text',
              'status': 'succeeded',
              'results': [
                {'url': 'https://files.example/text.png'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.toString() == 'https://files.example/text.png') {
          return http.Response.bytes(await source.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    final result = await service.generateTextToImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'nano-banana-fast',
          apiBaseUrl: 'https://grsai.dakka.com.cn',
          apiKey: 'test-key',
        ),
        model: 'nano-banana-fast',
        prompt: '雨夜街头的电影感分镜图',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: const [],
        outputDirectory: output,
      ),
    );

    expect(submitBody?['prompt'], '雨夜街头的电影感分镜图');
    expect(submitBody?['images'], isEmpty);
    expect(File(result.localPath).existsSync(), isTrue);
  });

  test('Grsai统一接口会发送当前参考图并下载异步结果', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_service_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'source.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/api/generate') {
          submitBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'id': 'task-1', 'status': 'running'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/v1/api/result') {
          expect(request.url.queryParameters['id'], 'task-1');
          return http.Response(
            jsonEncode({
              'id': 'task-1',
              'status': 'succeeded',
              'results': [
                {'url': 'https://files.example/result.png'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.toString() == 'https://files.example/result.png') {
          return http.Response.bytes(await source.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    final result = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'nano-banana-fast',
          apiBaseUrl: 'https://grsai.dakka.com.cn',
          apiKey: 'test-key',
        ),
        model: 'nano-banana-fast',
        prompt: '让人物回头看向门口',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: [source.path],
        outputDirectory: output,
      ),
    );

    expect(submitBody?['model'], 'nano-banana-fast');
    expect(submitBody?['prompt'], '让人物回头看向门口');
    expect(submitBody?['aspectRatio'], '16:9');
    expect(submitBody?['imageSize'], '2K');
    expect(submitBody?['replyType'], 'json');
    final images = submitBody?['images'] as List<dynamic>;
    expect(images, hasLength(1));
    final submittedImage = images.single.toString();
    expect(submittedImage, startsWith('data:image/png;base64,'));
    expect(
      base64Decode(submittedImage.substring(submittedImage.indexOf(',') + 1)),
      await source.readAsBytes(),
    );
    expect(File(result.localPath).existsSync(), isTrue);
    expect(File('${result.localPath}.json').existsSync(), isTrue);
  });

  test('Gemini图像模型对20MB以内本地参考图保持原格式和原始字节', () async {
    final root = await Directory.systemTemp.createTemp('gemini_image_gen_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'reference.png');
    final sourceBytes = await source.readAsBytes();
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    final resultBytes = img.encodePng(img.Image(width: 4, height: 4));
    final service = ImageGenerationService(
      client: MockClient((request) async {
        submitBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'inlineData': {
                        'mimeType': 'image/png',
                        'data': base64Encode(resultBytes),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);

    await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'gemini-3-pro-image-preview',
          apiBaseUrl: 'https://www.shiying-api.com',
          apiKey: 'gemini-key',
        ),
        model: 'gemini-3-pro-image-preview',
        prompt: '保持产品全部细节',
        aspectRatio: '4:3',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: [source.path],
        outputDirectory: output,
      ),
    );

    final contents = submitBody?['contents'] as List<dynamic>;
    final parts = (contents.single as Map<String, dynamic>)['parts'] as List;
    final inlineData = (parts.last as Map)['inline_data'] as Map;
    expect(inlineData['mime_type'], 'image/png');
    expect(base64Decode(inlineData['data'] as String), sourceBytes);
  });

  test('GPT Image模型会把比例和档位换算为分辨率并传递质量', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_service_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'source.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/api/generate') {
          submitBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'task-2',
              'status': 'succeeded',
              'results': [
                {'url': 'https://files.example/gpt.png'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.toString() == 'https://files.example/gpt.png') {
          return http.Response.bytes(await source.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'gpt-image-2',
          apiBaseUrl: 'https://grsaiapi.com/v1/api/generate',
          apiKey: 'test-key',
        ),
        model: 'gpt-image-2',
        prompt: '增强逆光和表情',
        aspectRatio: '3:2',
        imageSize: '2K',
        quality: 'high',
        referenceImagePaths: [source.path],
        outputDirectory: output,
      ),
    );

    expect(submitBody?['model'], 'gpt-image-2');
    expect(submitBody?['aspectRatio'], '1536x1024');
    expect(submitBody?['quality'], 'high');
    expect(submitBody?.containsKey('imageSize'), isFalse);
  });

  test('缺少API Key时按模型提示对应厂商', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_service_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'source.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');
    final service = ImageGenerationService();
    addTearDown(service.close);

    await expectLater(
      () => service.generateEditedImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'gemini-3-pro-image',
            apiBaseUrl: 'https://grsai.dakka.com.cn',
            apiKey: '',
          ),
          model: 'gemini-3-pro-image',
          prompt: '增强画面质感',
          aspectRatio: '16:9',
          imageSize: '2K',
          quality: 'auto',
          referenceImagePaths: [source.path],
          outputDirectory: output,
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Gemini API Key'),
        ),
      ),
    );
  });

  test('Gemini generateContent保持多图顺序并原样回传thoughtSignature续轮', () async {
    final root = await Directory.systemTemp.createTemp('gemini_image_gen_');
    addTearDown(() => root.delete(recursive: true));
    final firstSource = await _writeImage(
      root,
      'reference-1.png',
      color: img.ColorRgb8(20, 40, 60),
    );
    final secondSource = await _writeImage(
      root,
      'reference-2.png',
      color: img.ColorRgb8(80, 100, 120),
    );
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    final submitBodies = <Map<String, dynamic>>[];
    final resultBytes = img.encodePng(img.Image(width: 4, height: 4));
    final encodedResult = base64Encode(resultBytes);
    final firstThoughtSignature = 'opaque-signature-first-' * 128;
    final secondThoughtSignature = 'opaque-signature-second-' * 64;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        expect(request.url.host, 'www.shiying-api.com');
        expect(
          request.url.path,
          '/v1beta/models/gemini-3-pro-image-preview:generateContent',
        );
        expect(request.headers['authorization'], 'Bearer gemini-key');
        submitBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final isFirstTurn = submitBodies.length == 1;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'role': 'model',
                  'parts': [
                    {
                      'text': isFirstTurn ? '已完成初稿' : '已完成纠正',
                      'thoughtSignature': isFirstTurn
                          ? firstThoughtSignature
                          : secondThoughtSignature,
                    },
                    {
                      'thoughtSignature': isFirstTurn
                          ? firstThoughtSignature
                          : secondThoughtSignature,
                      'inlineData': {
                        'mimeType': 'image/png',
                        'data': encodedResult,
                      },
                    },
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 12,
              'candidatesTokenCount': 34,
            },
            'modelVersion': 'gemini-3-pro-image-preview',
            'responseId': isFirstTurn
                ? 'response-compact-test'
                : 'response-follow-up',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);

    final provider = _providerFor(
      model: 'gemini-3-pro-image-preview',
      apiBaseUrl: 'https://www.shiying-api.com',
      apiKey: 'gemini-key',
    );
    final firstResult = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: provider,
        model: 'gemini-3-pro-image-preview',
        prompt: '保留角色并改成雨夜场景',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: [firstSource.path, secondSource.path],
        outputDirectory: output,
      ),
    );
    final secondResult = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: provider,
        model: 'gemini-3-pro-image-preview',
        prompt: '只纠正雨伞颜色，其他内容不变',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: const [],
        outputDirectory: output,
        geminiContinuation: firstResult.geminiContinuation,
      ),
    );

    final firstContents = submitBodies.first['contents'] as List<dynamic>;
    final firstParts = (firstContents.single as Map)['parts'] as List;
    expect(firstParts, hasLength(3));
    expect(_inlineBytes(firstParts[1] as Map), await firstSource.readAsBytes());
    expect(
      _inlineBytes(firstParts[2] as Map),
      await secondSource.readAsBytes(),
    );
    expect(
      ((submitBodies.first['generationConfig'] as Map)['imageConfig'] as Map),
      containsPair('aspectRatio', '16:9'),
    );

    final followUpContents = submitBodies.last['contents'] as List<dynamic>;
    expect(followUpContents, hasLength(3));
    final returnedModelParts = (followUpContents[1] as Map)['parts'] as List;
    expect(
      (returnedModelParts.first as Map)['thoughtSignature'],
      firstThoughtSignature,
    );
    expect(
      (returnedModelParts.last as Map)['thoughtSignature'],
      firstThoughtSignature,
    );
    expect(
      ((returnedModelParts.last as Map)['inlineData'] as Map)['data'],
      encodedResult,
    );
    expect(
      (((followUpContents.last as Map)['parts'] as List).single as Map)['text'],
      '只纠正雨伞颜色，其他内容不变',
    );

    expect(firstResult.remoteUrl, isEmpty);
    expect(await File(firstResult.localPath).readAsBytes(), resultBytes);
    expect(await File(secondResult.localPath).readAsBytes(), resultBytes);
    expect(
      firstResult.geminiContinuation?.transport,
      GeminiImageContinuationTransport.generateContent,
    );
    final metadataFile = File('${firstResult.localPath}.json');
    final compactResponse =
        jsonDecode(firstResult.rawResponse) as Map<String, dynamic>;
    expect(compactResponse['responseId'], 'response-compact-test');
    expect(compactResponse['modelVersion'], 'gemini-3-pro-image-preview');
    expect(compactResponse['usageMetadata'], isNotNull);
    expect(firstResult.rawResponse, isNot(contains(encodedResult)));
    expect(firstResult.rawResponse, contains(firstThoughtSignature));
    expect(firstResult.rawResponse, contains('thoughtSignature'));
    expect(
      compactResponse['payloadOmissions'],
      containsPair('imagePayloadCharacters', encodedResult.length),
    );
    final metadata =
        jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    expect(metadata['rawResponse'], firstResult.rawResponse);
    final requestRecord = metadata['requestRecord'] as Map<String, dynamic>;
    expect(requestRecord['route'], 'generateContent');
    expect(
      (requestRecord['orderedReferences'] as List)
          .map((item) => (item as Map)['source'])
          .toList(),
      [firstSource.path, secondSource.path],
    );
    expect(requestRecord.containsKey('apiKey'), isFalse);
    expect(await metadataFile.length(), lessThan(32 * 1024));
  });

  test('Gemini Interactions保持多图顺序并使用官方有状态续轮', () async {
    final root = await Directory.systemTemp.createTemp('gemini_image_gen_');
    addTearDown(() => root.delete(recursive: true));
    final firstSource = await _writeImage(
      root,
      'reference-1.png',
      color: img.ColorRgb8(12, 34, 56),
    );
    final secondSource = await _writeImage(
      root,
      'reference-2.png',
      color: img.ColorRgb8(65, 43, 21),
    );
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    final submitBodies = <Map<String, dynamic>>[];
    final resultBytes = List<int>.generate(512, (index) => index % 251);
    final encodedResult = base64Encode(resultBytes);
    final service = ImageGenerationService(
      client: MockClient((request) async {
        expect(request.url.host, 'generativelanguage.googleapis.com');
        expect(request.url.path, '/v1beta/interactions');
        expect(request.headers['x-goog-api-key'], 'gemini-key');
        expect(request.headers.containsKey('authorization'), isFalse);
        submitBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'id': 'interaction-${submitBodies.length}',
            'steps': [
              {
                'type': 'thought',
                'signature': 'interaction-signature-${submitBodies.length}',
              },
              {
                'type': 'model_output',
                'content': [
                  {'type': 'text', 'text': '已完成'},
                  {
                    'type': 'image',
                    'mime_type': 'image/png',
                    'data': encodedResult,
                  },
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);

    final provider = _providerFor(
      model: 'gemini-3-pro-image',
      apiBaseUrl: 'https://generativelanguage.googleapis.com',
      apiKey: 'gemini-key',
    );
    final firstResult = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: provider,
        model: 'gemini-3-pro-image',
        prompt: '保留构图并高清重绘',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: [firstSource.path, '', secondSource.path],
        outputDirectory: output,
      ),
    );
    final secondResult = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: provider,
        model: 'gemini-3-pro-image',
        prompt: '只修正左手手指，其他内容不变',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: const [],
        outputDirectory: output,
        geminiContinuation: firstResult.geminiContinuation,
      ),
    );

    final firstBody = submitBodies.first;
    expect(firstBody['model'], 'gemini-3-pro-image');
    expect(firstBody['store'], isTrue);
    expect(firstBody.containsKey('previous_interaction_id'), isFalse);
    final firstInput = firstBody['input'] as List<dynamic>;
    expect((firstInput.first as Map)['text'], '保留构图并高清重绘');
    expect(
      _interactionBytes(firstInput[1] as Map),
      await firstSource.readAsBytes(),
    );
    expect(
      _interactionBytes(firstInput[2] as Map),
      await secondSource.readAsBytes(),
    );
    expect(firstBody['response_format'], containsPair('aspect_ratio', '16:9'));
    expect(firstBody['response_format'], containsPair('image_size', '2K'));

    final followUpBody = submitBodies.last;
    expect(followUpBody['store'], isTrue);
    expect(followUpBody['previous_interaction_id'], 'interaction-1');
    final followUpInput = followUpBody['input'] as List<dynamic>;
    expect(followUpInput, hasLength(1));
    expect((followUpInput.single as Map)['text'], '只修正左手手指，其他内容不变');
    expect(
      secondResult.geminiContinuation?.previousInteractionId,
      'interaction-2',
    );
    expect(await File(firstResult.localPath).readAsBytes(), resultBytes);
    expect(await File(secondResult.localPath).readAsBytes(), resultBytes);
    expect(firstResult.rawResponse, isNot(contains(encodedResult)));
    expect(firstResult.rawResponse, contains('interaction-signature-1'));
    final compactResponse =
        jsonDecode(firstResult.rawResponse) as Map<String, dynamic>;
    expect(
      compactResponse['payloadOmissions'],
      containsPair('imagePayloadCharacters', encodedResult.length),
    );
    final metadata =
        jsonDecode(await File('${firstResult.localPath}.json').readAsString())
            as Map<String, dynamic>;
    final requestRecord = metadata['requestRecord'] as Map<String, dynamic>;
    expect(requestRecord['route'], 'interactions');
    expect(
      (requestRecord['inputOrder'] as List)
          .map((item) => (item as Map)['sourceRequestIndex'])
          .whereType<int>()
          .toList(),
      [0, 2],
    );
  });

  test('第三方Gemini地址对稳定图像模型使用preview generateContent兼容路由', () async {
    final root = await Directory.systemTemp.createTemp('gemini_image_gen_');
    addTearDown(() => root.delete(recursive: true));
    final firstSource = await _writeImage(
      root,
      'reference-1.png',
      color: img.ColorRgb8(10, 20, 30),
    );
    final secondSource = await _writeImage(
      root,
      'reference-2.png',
      color: img.ColorRgb8(30, 20, 10),
    );
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    final resultBytes = List<int>.generate(384, (index) => index % 197);
    final encodedResult = base64Encode(resultBytes);
    final service = ImageGenerationService(
      client: MockClient((request) async {
        expect(request.url.host, 'www.shiying-api.com');
        expect(
          request.url.path,
          '/v1beta/models/gemini-3-pro-image-preview:generateContent',
        );
        expect(request.headers['authorization'], 'Bearer gemini-key');
        expect(request.headers.containsKey('x-goog-api-key'), isFalse);
        submitBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'inlineData': {
                        'mimeType': 'image/png',
                        'data': encodedResult,
                      },
                    },
                  ],
                },
              },
            ],
            'modelVersion': 'gemini-3-pro-image-preview',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);

    final result = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'gemini-3-pro-image',
          apiBaseUrl: 'https://www.shiying-api.com',
          apiKey: 'gemini-key',
        ),
        model: 'gemini-3-pro-image',
        prompt: '保留构图并高清重绘',
        aspectRatio: '16:9',
        imageSize: '2K',
        quality: 'auto',
        referenceImagePaths: [firstSource.path, secondSource.path],
        outputDirectory: output,
      ),
    );

    final contents = submitBody?['contents'] as List<dynamic>;
    final parts = (contents.single as Map)['parts'] as List;
    expect(parts, hasLength(3));
    expect(_inlineBytes(parts[1] as Map), await firstSource.readAsBytes());
    expect(_inlineBytes(parts[2] as Map), await secondSource.readAsBytes());
    final generationConfig =
        submitBody?['generationConfig'] as Map<String, dynamic>;
    final imageConfig = generationConfig['imageConfig'] as Map<String, dynamic>;
    expect(imageConfig, containsPair('aspectRatio', '16:9'));
    expect(imageConfig, containsPair('imageSize', '2K'));
    expect(await File(result.localPath).readAsBytes(), resultBytes);
    final metadata =
        jsonDecode(await File('${result.localPath}.json').readAsString())
            as Map<String, dynamic>;
    expect(
      (metadata['requestRecord'] as Map)['route'],
      'thirdPartyGenerateContentCompatibility',
    );
  });

  test('图片修改仍然要求至少一张参考图', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_service_');
    addTearDown(() => root.delete(recursive: true));
    final output = Directory('${root.path}${Platform.pathSeparator}output');
    final service = ImageGenerationService();
    addTearDown(service.close);

    expect(
      () => service.generateEditedImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'nano-banana-fast',
            apiBaseUrl: 'https://grsai.dakka.com.cn',
            apiKey: 'test-key',
          ),
          model: 'nano-banana-fast',
          prompt: '增强画面质感',
          aspectRatio: '16:9',
          imageSize: '2K',
          quality: 'auto',
          referenceImagePaths: const [],
          outputDirectory: output,
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('至少需要一张参考图'),
        ),
      ),
    );
  });

  test('APIMart会上传本地参考图并轮询统一任务接口', () async {
    final root = await Directory.systemTemp.createTemp('apimart_image_gen_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'reference.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    Map<String, dynamic>? submitBody;
    var uploaded = false;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/uploads/images') {
          expect(request.headers['authorization'], 'Bearer apimart-key');
          uploaded = true;
          expect(
            request.headers['content-type'],
            contains('multipart/form-data'),
          );
          return http.Response(
            jsonEncode({'url': 'https://upload.apimart.ai/reference.png'}),
            200,
          );
        }
        if (request.url.path == '/v1/images/generations') {
          expect(request.headers['authorization'], 'Bearer apimart-key');
          submitBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': [
                {'status': 'submitted', 'task_id': 'task-apimart'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/tasks/task-apimart') {
          expect(request.headers['authorization'], 'Bearer apimart-key');
          expect(request.url.queryParameters['language'], 'zh');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'id': 'task-apimart',
                'status': 'completed',
                'result': {
                  'images': [
                    {
                      'url': ['https://files.example/apimart.png'],
                    },
                  ],
                },
              },
            }),
            200,
          );
        }
        if (request.url.toString() == 'https://files.example/apimart.png') {
          return http.Response.bytes(await source.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    final result = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'apimart:gemini-3.1-flash-image-preview',
          apiBaseUrl: 'https://api.apimart.ai',
          apiKey: 'apimart-key',
        ),
        model: 'apimart:gemini-3.1-flash-image-preview',
        prompt: '保持人物一致，改成雨夜场景',
        aspectRatio: '1:8',
        imageSize: '4K',
        quality: 'auto',
        referenceImagePaths: [source.path],
        outputDirectory: output,
      ),
    );

    expect(uploaded, isTrue);
    expect(submitBody?['model'], 'gemini-3.1-flash-image-preview');
    expect(submitBody?['size'], '1:8');
    expect(submitBody?['resolution'], '4K');
    expect(submitBody?['image_urls'], [
      'https://upload.apimart.ai/reference.png',
    ]);
    expect(File(result.localPath).existsSync(), isTrue);
  });

  test('APIMart图片上传代理解析始终强制直连', () {
    expect(
      ImageGenerationService.apiMartUploadProxyFor(
        Uri.parse('https://api.apimart.ai/v1/uploads/images'),
      ),
      'DIRECT',
    );
  });

  test('APIMart图片上传遇到网络异常会重建直连客户端并重试', () async {
    final root = await Directory.systemTemp.createTemp('apimart_upload_retry_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'reference.png');
    final resultImage = await _writeImage(root, 'result.png');
    final output = Directory('${root.path}${Platform.pathSeparator}output');

    var uploadAttempts = 0;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/images/generations') {
          return http.Response(
            jsonEncode({
              'data': [
                {'task_id': 'task-upload-retry'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/tasks/task-upload-retry') {
          return http.Response(
            jsonEncode({
              'data': {
                'status': 'completed',
                'result': {
                  'images': [
                    {'url': 'https://files.example/retry-result.png'},
                  ],
                },
              },
            }),
            200,
          );
        }
        if (request.url.toString() ==
            'https://files.example/retry-result.png') {
          return http.Response.bytes(await resultImage.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
      apiMartUploadClientFactory: () {
        uploadAttempts += 1;
        final currentAttempt = uploadAttempts;
        return MockClient((request) async {
          expect(request.url.path, '/v1/uploads/images');
          expect(request.headers['authorization'], 'Bearer apimart-key');
          if (currentAttempt == 1) {
            throw http.ClientException(
              'with SocketException: OS Error 121',
              request.url,
            );
          }
          return http.Response(
            jsonEncode({'url': 'https://upload.apimart.ai/retry.png'}),
            200,
          );
        });
      },
      apiMartUploadRetryDelay: Duration.zero,
      apiMartPollInterval: Duration.zero,
    );
    addTearDown(service.close);

    final result = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'apimart:wan2.7-image-pro',
          apiBaseUrl: 'https://api.apimart.ai',
          apiKey: 'apimart-key',
        ),
        model: 'apimart:wan2.7-image-pro',
        prompt: '保留人物并替换背景',
        aspectRatio: '16:9',
        imageSize: '1K',
        quality: 'auto',
        referenceImagePaths: [source.path],
        outputDirectory: output,
      ),
    );

    expect(uploadAttempts, 2);
    expect(File(result.localPath).existsSync(), isTrue);
  });

  test('APIMart参考图直连失败后可回退到环境代理客户端', () async {
    final root = await Directory.systemTemp.createTemp(
      'apimart_upload_fallback_',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'reference.png');
    final resultImage = await _writeImage(root, 'result.png');
    var fallbackAttempts = 0;

    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/images/generations') {
          return http.Response(
            jsonEncode({
              'data': [
                {'task_id': 'task-upload-fallback'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/tasks/task-upload-fallback') {
          return http.Response(
            jsonEncode({
              'data': {
                'status': 'completed',
                'result': {
                  'images': [
                    {'url': 'https://files.example/fallback-result.png'},
                  ],
                },
              },
            }),
            200,
          );
        }
        if (request.url.toString() ==
            'https://files.example/fallback-result.png') {
          return http.Response.bytes(await resultImage.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
      apiMartUploadClientFactory: () => MockClient((request) async {
        throw http.ClientException('direct failed', request.url);
      }),
      apiMartUploadFallbackClientFactory: () => MockClient((request) async {
        fallbackAttempts += 1;
        return http.Response(
          jsonEncode({'url': 'https://upload.apimart.ai/fallback.png'}),
          200,
        );
      }),
      apiMartUploadRetryDelay: Duration.zero,
      apiMartUploadMaxAttempts: 1,
      apiMartPollInterval: Duration.zero,
    );
    addTearDown(service.close);

    final result = await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'apimart:wan2.7-image-pro',
          apiBaseUrl: 'https://api.apimart.ai',
          apiKey: 'apimart-key',
        ),
        model: 'apimart:wan2.7-image-pro',
        prompt: '回退网络测试',
        aspectRatio: '16:9',
        imageSize: '1K',
        quality: 'auto',
        referenceImagePaths: [source.path],
        outputDirectory: root,
      ),
    );

    expect(fallbackAttempts, 1);
    expect(File(result.localPath).existsSync(), isTrue);
  });

  test('APIMart图片直连上传重试耗尽后返回明确错误', () async {
    final root = await Directory.systemTemp.createTemp(
      'apimart_upload_failure_',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'reference.png');

    var uploadAttempts = 0;
    final service = ImageGenerationService(
      client: MockClient((_) async => http.Response('not expected', 500)),
      apiMartUploadClientFactory: () => MockClient((request) async {
        uploadAttempts += 1;
        throw http.ClientException('OS Error 121', request.url);
      }),
      apiMartUploadRetryDelay: Duration.zero,
      apiMartUploadMaxAttempts: 3,
    );
    addTearDown(service.close);

    await expectLater(
      () => service.generateEditedImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'apimart:gpt-image-2',
            apiBaseUrl: 'https://api.apimart.ai',
            apiKey: 'apimart-key',
          ),
          model: 'apimart:gpt-image-2',
          prompt: '雪景人像',
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'auto',
          referenceImagePaths: [source.path],
          outputDirectory: root,
        ),
      ),
      throwsA(
        isA<HttpException>()
            .having((error) => error.message, 'message', contains('已尝试 3 次'))
            .having((error) => error.message, 'message', contains('未检测到环境代理')),
      ),
    );
    expect(uploadAttempts, 3);
  });

  test('图片生成诊断日志记录请求参数和错误但不写入Key或提示词', () async {
    final root = await Directory.systemTemp.createTemp('image_gen_log_');
    addTearDown(() => root.delete(recursive: true));
    final logs = Directory('${root.path}${Platform.pathSeparator}logs');
    const secretKey = 'secret-apimart-key-123';
    const secretPrompt = '不应写入日志的秘密提示词';
    final service = ImageGenerationService(
      client: MockClient((_) async => http.Response('not expected', 500)),
      diagnosticLogger: ImageGenerationDiagnosticLogger(logs),
    );
    addTearDown(service.close);

    await expectLater(
      service.generateTextToImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'apimart:gpt-image-2-official',
            apiBaseUrl: 'https://docs.apimart.ai/cn',
            apiKey: secretKey,
          ),
          model: 'apimart:gpt-image-2-official',
          prompt: secretPrompt,
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'low',
          referenceImagePaths: const [],
          outputDirectory: root,
        ),
      ),
      throwsA(isA<FormatException>()),
    );

    final logFiles = logs.listSync().whereType<File>().toList();
    expect(logFiles, hasLength(1));
    final content = await logFiles.single.readAsString();
    expect(content, contains('"event":"started"'));
    expect(content, contains('"event":"failed"'));
    expect(content, contains('apimart:gpt-image-2-official'));
    expect(content, contains('docs.apimart.ai'));
    expect(content, isNot(contains(secretKey)));
    expect(content, isNot(contains(secretPrompt)));
  });

  test('APIMart失败任务会保留上游返回的具体错误', () async {
    final root = await Directory.systemTemp.createTemp('apimart_failure_');
    addTearDown(() => root.delete(recursive: true));
    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/images/generations') {
          return http.Response(
            jsonEncode({
              'data': [
                {'status': 'submitted', 'task_id': 'task-failed'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/tasks/task-failed') {
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'task-failed',
                'status': 'failed',
                'error': {
                  'message': 'upstream model temporarily unavailable',
                  'type': 'upstream_error',
                },
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    expect(
      () => service.generateTextToImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'apimart:gpt-image-2',
            apiBaseUrl: 'https://api.apimart.ai',
            apiKey: 'apimart-key',
          ),
          model: 'apimart:gpt-image-2',
          prompt: '雪景人像',
          aspectRatio: '1:1',
          imageSize: '1K',
          quality: 'auto',
          referenceImagePaths: const [],
          outputDirectory: root,
        ),
      ),
      throwsA(
        isA<HttpException>().having(
          (error) => error.message,
          'message',
          contains('upstream model temporarily unavailable'),
        ),
      ),
    );
  });

  test('APIMart Grok有参考图时切换到专用编辑端点和模型', () async {
    final root = await Directory.systemTemp.createTemp('apimart_grok_');
    addTearDown(() => root.delete(recursive: true));
    final resultImage = await _writeImage(root, 'result.png');
    Map<String, dynamic>? submitBody;

    final service = ImageGenerationService(
      client: MockClient((request) async {
        if (request.url.path == '/v1/images/edits') {
          submitBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'data': [
                {'task_id': 'task-grok'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/v1/tasks/task-grok') {
          return http.Response(
            jsonEncode({
              'data': {
                'status': 'completed',
                'result': {
                  'images': [
                    {'url': 'https://files.example/grok.png'},
                  ],
                },
              },
            }),
            200,
          );
        }
        if (request.url.toString() == 'https://files.example/grok.png') {
          return http.Response.bytes(await resultImage.readAsBytes(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.close);

    await service.generateEditedImage(
      ImageGenerationRequest(
        provider: _providerFor(
          model: 'apimart:grok-imagine-1.5-apimart',
          apiBaseUrl: 'https://api.apimart.ai',
          apiKey: 'apimart-key',
        ),
        model: 'apimart:grok-imagine-1.5-apimart',
        prompt: '替换背景',
        aspectRatio: '16:9',
        imageSize: 'auto',
        quality: 'auto',
        referenceImagePaths: const ['https://files.example/reference.png'],
        outputDirectory: Directory(
          '${root.path}${Platform.pathSeparator}output',
        ),
      ),
    );

    expect(submitBody?['model'], 'grok-imagine-1.5-edit-apimart');
    expect(submitBody?['image_urls'], ['https://files.example/reference.png']);
    expect(submitBody?.containsKey('size'), isFalse);
  });

  test('APIMart不支持参考图的模型会在提交前报错', () async {
    final root = await Directory.systemTemp.createTemp('apimart_imagen_');
    addTearDown(() => root.delete(recursive: true));
    final source = await _writeImage(root, 'source.png');
    final service = ImageGenerationService();
    addTearDown(service.close);

    expect(
      () => service.generateEditedImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'apimart:imagen-4.0-apimart',
            apiBaseUrl: 'https://api.apimart.ai',
            apiKey: 'apimart-key',
          ),
          model: 'apimart:imagen-4.0-apimart',
          prompt: '修改图片',
          aspectRatio: '16:9',
          imageSize: 'auto',
          quality: 'auto',
          referenceImagePaths: [source.path],
          outputDirectory: root,
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('不支持参考图'),
        ),
      ),
    );
  });

  test('APIMart GPT Image 2 无效比例和 4K 组合会在联网前报错', () async {
    final root = await Directory.systemTemp.createTemp('apimart_gpt2_4k_');
    addTearDown(() => root.delete(recursive: true));
    var requestCount = 0;
    final service = ImageGenerationService(
      client: MockClient((request) async {
        requestCount++;
        return http.Response('unexpected request', 500);
      }),
    );
    addTearDown(service.close);

    await expectLater(
      service.generateTextToImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'apimart:gpt-image-2-official',
            apiBaseUrl: 'https://api.apimart.ai',
            apiKey: 'apimart-key',
          ),
          model: 'apimart:gpt-image-2-official',
          prompt: '电影感分镜',
          aspectRatio: '1:1',
          imageSize: '4K',
          quality: 'high',
          referenceImagePaths: const [],
          outputDirectory: root,
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('1:1'), contains('不支持 4K')),
        ),
      ),
    );
    expect(requestCount, 0);
  });

  test('APIMart模型拒绝使用GRSai连接配置', () async {
    final root = await Directory.systemTemp.createTemp('provider_mismatch_');
    addTearDown(() => root.delete(recursive: true));
    final service = ImageGenerationService();
    addTearDown(service.close);

    expect(
      () => service.generateTextToImage(
        ImageGenerationRequest(
          provider: _providerFor(
            model: 'nano-banana-fast',
            apiBaseUrl: 'https://grsai.example',
            apiKey: 'grsai-key',
          ),
          model: 'apimart:gemini-3-pro-image-preview',
          prompt: '电影感画面',
          aspectRatio: '16:9',
          imageSize: '2K',
          quality: 'auto',
          referenceImagePaths: const [],
          outputDirectory: root,
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('APIMart'), contains('不能使用 GRSai 配置')),
        ),
      ),
    );
  });
}

List<int> _inlineBytes(Map part) {
  final inlineData = (part['inline_data'] ?? part['inlineData']) as Map;
  return base64Decode(inlineData['data'] as String);
}

List<int> _interactionBytes(Map part) {
  return base64Decode(part['data'] as String);
}

ImageGenerationProviderConnection _providerFor({
  required String model,
  required String apiBaseUrl,
  required String apiKey,
}) {
  final descriptor = ImageGenerationModelCatalog.descriptorFor(model)!;
  return ImageGenerationProviderConnection(
    providerId: descriptor.providerId,
    providerLabel: ImageGenerationModelCatalog.providerLabelForModel(model),
    protocol: descriptor.protocol,
    apiBaseUrl: apiBaseUrl,
    apiKey: apiKey,
  );
}

Future<File> _writeImage(
  Directory root,
  String name, {
  img.Color? color,
}) async {
  final image = img.Image(width: 12, height: 8);
  img.fill(image, color: color ?? img.ColorRgb8(40, 90, 140));
  final file = File('${root.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(img.encodePng(image));
  return file;
}
