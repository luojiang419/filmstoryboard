import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/h3_skill_library.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/settings/domain/vision_api_config.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_service.dart';
import 'package:test/test.dart';

void main() {
  test('规范化 OpenAI-compatible Chat Completions 地址', () {
    expect(
      normalizeChatCompletionsEndpoint('115.231.35.105:12345').toString(),
      'http://115.231.35.105:12345/v1/chat/completions',
    );
    expect(
      normalizeChatCompletionsEndpoint('api.example.com').toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(
      normalizeChatCompletionsEndpoint('http://localhost:9000/v1').toString(),
      'http://localhost:9000/v1/chat/completions',
    );
    expect(
      normalizeChatCompletionsEndpoint(
        'https://api.example.com/v1/chat/completions',
      ).toString(),
      'https://api.example.com/v1/chat/completions',
    );
  });

  test('Responses 端点支持本地地址、完整 URL 和 /v1 去重', () {
    expect(
      normalizeResponsesEndpoint('127.0.0.1:9000').toString(),
      'http://127.0.0.1:9000/v1/responses',
    );
    expect(
      normalizeResponsesEndpoint('http://localhost:9000/v1').toString(),
      'http://localhost:9000/v1/responses',
    );
    expect(
      normalizeResponsesEndpoint(
        'https://api.example.com/v1',
        '/v1/responses',
      ).toString(),
      'https://api.example.com/v1/responses',
    );
    expect(
      normalizeResponsesEndpoint(
        'https://api.example.com',
        'https://gateway.example.com/responses',
      ).toString(),
      'https://gateway.example.com/responses',
    );
  });

  test('Responses 视觉请求发送 input_image 并解析 output_text', () async {
    Map<String, dynamic>? requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'resp_test',
            'status': 'completed',
            'output_text': '{"caption":"Responses 已识别"}',
            'usage': {
              'input_tokens': 12,
              'output_tokens': 5,
              'total_tokens': 17,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('responses_vision_');

    final result = await service.complete(
      settings: _settings(protocol: VisionApiRequestProtocol.responses),
      prompt: '分析图片',
      imageFiles: [image],
    );

    expect(result, '{"caption":"Responses 已识别"}');
    expect(requestBody!['model'], 'test-vlm');
    expect(requestBody!['messages'], isNull);
    final input = requestBody!['input'] as List<dynamic>;
    final content =
        (input.single as Map<String, dynamic>)['content'] as List<dynamic>;
    expect((content.first as Map<String, dynamic>)['type'], 'input_text');
    expect((content[1] as Map<String, dynamic>)['type'], 'input_image');
    expect(
      (content[1] as Map<String, dynamic>)['image_url'],
      startsWith('data:image/'),
    );
  });

  test('完整视觉请求支持按调用覆盖响应超时', () async {
    final pendingResponse = Completer<http.Response>();
    final service = VisionStoryboardService(
      client: MockClient((request) => pendingResponse.future),
    );
    addTearDown(service.close);

    await expectLater(
      service.complete(
        settings: _settings(),
        prompt: '生成完整 H3 提示词',
        responseTimeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('完整视觉请求只压缩超限上传副本且不改原图', () async {
    Map<String, dynamic>? requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('压缩请求已接收');
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp(
      'vision_oversized_payload_',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}oversized.bmp');
    final originalBytes = img.encodeBmp(img.Image(width: 1100, height: 1100));
    expect(originalBytes.length, greaterThan(3 * 1024 * 1024));
    await source.writeAsBytes(originalBytes);

    final result = await service.complete(
      settings: _settings(),
      prompt: '分析超限图片',
      imageFiles: [source],
      compressOversizedImages: true,
    );

    expect(result, '压缩请求已接收');
    final messages = requestBody!['messages'] as List<dynamic>;
    final content =
        (messages.single as Map<String, dynamic>)['content'] as List<dynamic>;
    final imagePart = content[1] as Map<String, dynamic>;
    final imageUrl =
        (imagePart['image_url'] as Map<String, dynamic>)['url'] as String;
    expect(imageUrl, startsWith('data:image/jpeg;base64,'));
    final payload = base64Decode(imageUrl.substring(imageUrl.indexOf(',') + 1));
    expect(payload.length, lessThanOrEqualTo(8 * 1024 * 1024));
    expect(img.decodeJpg(payload), isNotNull);
    expect(await source.readAsBytes(), orderedEquals(originalBytes));
  });

  test('完整视觉请求保留 4096 以内的小体积高分辨率图片', () async {
    Map<String, dynamic>? requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('高分辨率图片已接收');
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp(
      'vision_high_resolution_payload_',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}high-res.png');
    final originalBytes = img.encodePng(img.Image(width: 2400, height: 1600));
    expect(originalBytes.length, lessThan(3 * 1024 * 1024));
    await source.writeAsBytes(originalBytes);

    final result = await service.complete(
      settings: _settings(),
      prompt: '分析高分辨率图片',
      imageFiles: [source],
      compressOversizedImages: true,
    );

    expect(result, '高分辨率图片已接收');
    final messages = requestBody!['messages'] as List<dynamic>;
    final content =
        (messages.single as Map<String, dynamic>)['content'] as List<dynamic>;
    final imagePart = content[1] as Map<String, dynamic>;
    final imageUrl =
        (imagePart['image_url'] as Map<String, dynamic>)['url'] as String;
    expect(imageUrl, startsWith('data:image/png;base64,'));
    final payload = base64Decode(imageUrl.substring(imageUrl.indexOf(',') + 1));
    final decoded = img.decodePng(payload);
    expect(decoded, isNotNull);
    expect(decoded!.width, 2400);
    expect(decoded.height, 1600);
    expect(payload, orderedEquals(originalBytes));
    expect(await source.readAsBytes(), orderedEquals(originalBytes));
  });

  test('完整视觉请求将超高分辨率上传副本缩至最长边 4096', () async {
    Map<String, dynamic>? requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse('超高分辨率图片已接收');
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp(
      'vision_ultra_high_resolution_payload_',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File(
      '${root.path}${Platform.pathSeparator}ultra-high-res.png',
    );
    final originalBytes = img.encodePng(img.Image(width: 5000, height: 3200));
    expect(originalBytes.length, lessThan(3 * 1024 * 1024));
    await source.writeAsBytes(originalBytes);

    final result = await service.complete(
      settings: _settings(),
      prompt: '分析超高分辨率图片',
      imageFiles: [source],
      compressOversizedImages: true,
    );

    expect(result, '超高分辨率图片已接收');
    final messages = requestBody!['messages'] as List<dynamic>;
    final content =
        (messages.single as Map<String, dynamic>)['content'] as List<dynamic>;
    final imagePart = content[1] as Map<String, dynamic>;
    final imageUrl =
        (imagePart['image_url'] as Map<String, dynamic>)['url'] as String;
    expect(imageUrl, startsWith('data:image/jpeg;base64,'));
    final payload = base64Decode(imageUrl.substring(imageUrl.indexOf(',') + 1));
    final decoded = img.decodeJpg(payload);
    expect(decoded, isNotNull);
    expect(decoded!.width, 4096);
    expect(decoded.height, lessThanOrEqualTo(4096));
    expect(await source.readAsBytes(), orderedEquals(originalBytes));
  });

  test('视觉服务以 Base64 图片调用 chat completions 并解析 JSON 文本', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'caption': '角色看向窗外',
                    'detail': '角色站在室内看向明亮窗户。',
                    'scene': '室内',
                    'props': '窗户',
                    'people': '角色站立',
                    'expression': '神情专注，视线望向窗外',
                    'body_action': '站在窗边微微前倾',
                    'movement_trend': '身体朝右侧窗户靠近',
                    'sound_design': '衣料随身体前倾产生一次自然摩擦声，与动作同步',
                    'camera_movement': '推',
                    'shot_size': '中景',
                    'composition': '人物位于画面左侧，窗户在右侧',
                    'subject_direction': '面向右侧',
                    'gaze_direction': '看向右侧窗外',
                    'action_stage': '准备',
                    'spatial_relation': '角色站在窗边并靠近窗户',
                    'chronology_cue': '动作前',
                    'camera_angle': '眼平中景，侧面观察',
                    'visual_focus': '窗外光线与角色专注视线',
                    'lighting_mood': '柔和窗光，安静期待',
                    'color_palette': '冷白与浅蓝灰',
                    'narrative_function': '推进',
                    'transition_hint': '适合承接开场后切向窗外目标',
                  }),
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

    final root = await Directory.systemTemp.createTemp('vision_service_');
    addTearDown(() => root.delete(recursive: true));
    final image = File('${root.path}${Platform.pathSeparator}frame.png');
    await image.writeAsBytes([1, 2, 3]);

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
    );

    expect(result.caption, '角色看向窗外');
    expect(result.scene, '室内');
    expect(result.expression, '神情专注，视线望向窗外');
    expect(result.bodyAction, '站在窗边微微前倾');
    expect(result.movementTrend, '身体朝右侧窗户靠近');
    expect(result.soundDesign, contains('与动作同步'));
    expect(result.cameraMovement, '推');
    expect(result.shotSize, '中景');
    expect(result.composition, '人物位于画面左侧，窗户在右侧');
    expect(result.subjectDirection, '面向右侧');
    expect(result.gazeDirection, '看向右侧窗外');
    expect(result.actionStage, '准备');
    expect(result.spatialRelation, '角色站在窗边并靠近窗户');
    expect(result.chronologyCue, '动作前');
    expect(result.cameraAngle, '眼平中景，侧面观察');
    expect(result.visualFocus, '窗外光线与角色专注视线');
    expect(result.lightingMood, '柔和窗光，安静期待');
    expect(result.colorPalette, '冷白与浅蓝灰');
    expect(result.narrativeFunction, '推进');
    expect(result.transitionHint, '适合承接开场后切向窗外目标');
    expect(result.hasStoryboardOrderingCues, isTrue);
    final dimensions = VideoFrameAnalysisFieldMapper.fromVision(result);
    expect(
      dimensions.keys,
      containsAll([
        'caption',
        'detail',
        'scene',
        'props',
        'people',
        'expression',
        'bodyAction',
        'movementTrend',
        'cameraMovement',
        'shotSize',
        'composition',
        'subjectDirection',
        'gazeDirection',
        'actionStage',
        'spatialRelation',
        'chronologyCue',
        'cameraAngle',
        'visualFocus',
        'lightingMood',
        'colorPalette',
        'narrativeFunction',
        'transitionHint',
      ]),
    );
    expect(dimensions['cameraMovement'], '推');
    expect(dimensions['visualFocus'], '窗外光线与角色专注视线');
    expect(requests.single, isNot(contains('max_tokens')));
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('镜头画面感'));
    expect(prompt, contains('即梦 / Seedance 2.0 成熟导演语法'));
    expect(prompt, contains('空间层 + 时间层'));
    expect(prompt, contains('一个镜头尽量只指定一种有动机的主运镜'));
    expect(prompt, contains('身体动势、动作趋势、表情变化潜力、视线方向'));
    expect(prompt, contains('播放速度规则（最高优先级）'));
    expect(prompt, contains('缓慢推近、平稳跟随、末段缓停只表示摄影机自身移动速度'));
    expect(prompt, contains('不要写成孤立标签'));
    expect(prompt, contains('神态'));
    expect(prompt, contains('姿态动作'));
    expect(prompt, contains('运动趋势'));
    expect(prompt, contains('sound_design'));
    expect(prompt, contains('真实时间速度'));
    expect(prompt, contains('禁止慢放、时间拉伸'));
    expect(prompt, contains('向左'));
    expect(prompt, contains('向右'));
    expect(prompt, contains('起身'));
    expect(prompt, contains('景别'));
    expect(prompt, contains('镜头运镜'));
    expect(prompt, contains('先比较同一镜头的起始/当前/结束帧构图变化'));
    expect(prompt, contains('从腰部/下半身抬到上半身/脸部'));
    expect(prompt, contains('不要写“推”'));
    expect(prompt, contains('仅人物从下半身变成上半身'));
    expect(prompt, contains('正跟随'));
    expect(prompt, contains('人物朝向'));
    expect(prompt, contains('以观看图片时的画面左/右为准'));
    expect(prompt, contains('动作阶段'));
    expect(prompt, contains('机位角度'));
    expect(prompt, contains('视觉焦点'));
    expect(prompt, contains('光线情绪'));
    expect(prompt, contains('色彩调性'));
    expect(prompt, contains('色彩调性只能描述整张画面的色温'));
    expect(prompt, contains('禁止写服装、配饰、道具、墙面、地面、皮革、条纹、肤色、头发等具体对象的颜色'));
    expect(prompt, contains('镜头叙事功能'));
    expect(prompt, contains('剪辑承接'));
    final imagePart = content.last as Map<String, dynamic>;
    expect(imagePart['type'], 'image_url');
    expect(
      (imagePart['image_url'] as Map<String, dynamic>)['url'],
      startsWith('data:image/png;base64,'),
    );
  });

  test('手动镜头组的四帧图片在同一个视觉 API 请求中按顺序提交', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _chatResponse(
          jsonEncode({
            'frames': [
              for (var index = 1; index <= 4; index++)
                {'caption': '第 $index 帧', 'detail': '手动镜头组的第 $index 个动作阶段。'},
            ],
            'motion': {
              'is_same_shot': true,
              'observed_camera_movement': '升降',
              'designed_camera_movement': '从首帧连续升降至结束帧',
              'shot_segments': [
                {
                  'shot_index': 1,
                  'start_frame': 1,
                  'end_frame': 4,
                  'scene': '同一室内场景',
                  'shot_size': '中景到近景',
                  'camera_movement': '连续升降',
                  'action': '人物完成同一条连续动作',
                  'transition_to_next': '',
                },
              ],
            },
          }),
        );
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp('vision_manual_group_');
    addTearDown(() => root.delete(recursive: true));
    final images = <File>[];
    for (var index = 1; index <= 4; index++) {
      images.add(
        await File(
          '${root.path}${Platform.pathSeparator}frame-$index.png',
        ).writeAsBytes([index]),
      );
    }

    final result = await service.analyzeShotGroupImages(
      settings: _settings(),
      imageFiles: images,
      shotNumber: 3,
    );

    expect(requests, hasLength(1));
    expect(result.frames.map((frame) => frame.caption), [
      '第 1 帧',
      '第 2 帧',
      '第 3 帧',
      '第 4 帧',
    ]);
    expect(result.motion.shotSegments, hasLength(1));
    expect(result.motion.shotSegments.single.startFrame, 1);
    expect(result.motion.shotSegments.single.endFrame, 4);
    expect(result.motion.shotSegments.single.cameraMovement, '连续升降');
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('按时间顺序提供 4 张图片'));
    expect(prompt, contains('不得预设它们一定属于同一镜头'));
    expect(prompt, contains('不得把图片数量机械等同于镜头数量'));
    expect(prompt, contains('前一帧结束姿态就是后一帧动作起点'));
    expect(prompt, contains('不得逐帧重启动作'));
    expect(prompt, contains('shot_segments'));
    final imageParts = content
        .whereType<Map<String, dynamic>>()
        .where((part) => part['type'] == 'image_url')
        .toList(growable: false);
    expect(imageParts, hasLength(4));
    expect(
      imageParts.map(
        (part) => (part['image_url'] as Map<String, dynamic>)['url'],
      ),
      everyElement(startsWith('data:image/png;base64,')),
    );
  });

  test('视觉请求把完整官方 Skill 正文和逐字段契约一起发送到模型', () async {
    late Map<String, dynamic> requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse(
          jsonEncode({
            'caption': '产品进入品牌主视觉',
            'detail': '产品真实机制触发可见结果。',
            'narrative_function': '广告产品记忆点',
          }),
        );
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp(
      'vision_style_contract_',
    );
    addTearDown(() => root.delete(recursive: true));
    final image = await File(
      '${root.path}${Platform.pathSeparator}frame.png',
    ).writeAsBytes([1, 2, 3]);

    final style = H3PromptStyle.resolve('brand-promo');
    final completeSkill = H3SkillDocument(
      style: style,
      sourceRevision: H3PromptStyle.officialSourceRevision,
      files: const {
        'skills/brand-promo-video-generator/SKILL.cn.md': '''
## 步骤 1：上传素材并确认简报
先核验 LOGO、产品、功能与受众。
## 步骤 10：交付
输出成片、来源摘要和改进建议。
## 失败恢复
资产不可用时停止并索要原件。
''',
      },
    );
    await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
      creativeBrief:
          '''
内容类型：品牌宣传短片。
${completeSkill.toVisionModelContext()}
叙事结构：用户意图→真实机制→产品证据→行动号召。
画面材质：锁定品牌色、LOGO 和产品结构。
''',
    );

    final content = requestBody['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('已选镜头叙事风格执行契约（强制）'));
    expect(prompt, contains('【MiniMax-H3 完整官方 Skill（强制执行）】'));
    expect(prompt, contains('本次完整加载文件数：1'));
    expect(prompt, contains('## 步骤 1：上传素材并确认简报'));
    expect(prompt, contains('## 步骤 10：交付'));
    expect(prompt, contains('## 失败恢复'));
    expect(prompt, contains('【完整官方 Skill 结束】'));
    expect(prompt, contains('用户意图→真实机制→产品证据→行动号召'));
    expect(prompt, contains('不能只在 detail 中写一句风格名'));
    expect(prompt, contains('各字段必须互相一致地体现同一种镜头语法'));
    expect(prompt, contains('图片可见事实和用户已给事实优先'));
    expect(prompt, contains('当前镜头对应的阶段'));
  });

  test('视频帧解析按上一帧当前帧下一帧顺序联合判断动作连续性', () async {
    late Map<String, dynamic> requestBody;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _chatResponse(
          jsonEncode({
            'caption': '人物从坐姿开始起身',
            'detail': '对比前后帧可见人物由坐姿抬升为站姿。',
            'movement_trend': '身体向上起身',
            'action_stage': '进行',
            'continues_from_previous': 'true',
            'continues_to_next': true,
          }),
        );
      }),
    );
    addTearDown(service.close);
    final root = await Directory.systemTemp.createTemp('vision_sequence_');
    addTearDown(() => root.delete(recursive: true));
    final files = <File>[];
    for (var index = 0; index < 3; index++) {
      files.add(
        await File(
          '${root.path}${Platform.pathSeparator}$index.png',
        ).writeAsBytes([index + 1]),
      );
    }

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: files[1],
      previousImageFile: files[0],
      nextImageFile: files[2],
      sequenceNo: 2,
      rowIndex: 0,
      columnIndex: 1,
    );

    final content = requestBody['messages'][0]['content'] as List<dynamic>;
    expect(content, hasLength(4));
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('上一帧、当前帧、下一帧'));
    expect(prompt, contains('禁止根据单帧姿态猜测运动'));
    expect(prompt, contains('画面中心/边缘参照物位移'));
    expect(prompt, contains('主体和背景整体尺度持续变大/变小'));
    expect(result.movementTrend, '身体向上起身');
    expect(result.actionStage, '进行');
    expect(result.continuesFromPrevious, isTrue);
    expect(result.continuesToNext, isTrue);
  });

  test('Qwen3 视觉请求会显式关闭思考模式', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _chatResponse(
          jsonEncode({'caption': '画面主体居中', 'detail': '画面中主体位于中央位置。'}),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_qwen_no_think_');
    addTearDown(() => image.parent.delete(recursive: true));

    await service.analyzeImage(
      settings: _settings(visionModel: 'qwen3.5-9b-vlm'),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
    );

    final request = requests.single;
    expect(request, isNot(contains('max_tokens')));
    expect(request['enable_thinking'], isFalse);
    expect(
      request['chat_template_kwargs'],
      isA<Map>().having((value) => value['enable_thinking'], 'enable', isFalse),
    );
    final content = request['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, startsWith('/no_think\n'));
  });

  test('Qwen3 视觉请求允许手动开启思考模式', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _chatResponse(
          jsonEncode({'caption': '画面主体居中', 'detail': '画面中主体位于中央位置。'}),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_qwen_think_');
    addTearDown(() => image.parent.delete(recursive: true));

    await service.analyzeImage(
      settings: _settings(visionModel: 'qwen3.5-9b-vlm'),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
      allowThinking: true,
    );

    final request = requests.single;
    expect(request, isNot(contains('max_tokens')));
    expect(request['enable_thinking'], isTrue);
    expect(
      request['chat_template_kwargs'],
      isA<Map>().having((value) => value['enable_thinking'], 'enable', isTrue),
    );
    final content = request['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, startsWith('/think\n'));
  });

  test('单图解析兼容数组和嵌套文本字段', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return _chatResponse(
          jsonEncode({
            'caption': '女模特站在酒吧招牌旁',
            'detail': '女模特在复古砖墙旁回望镜头。',
            'scene': {'text': '复古街道'},
            'props': ['“BAR”字样招牌', '砖墙', '老式汽车'],
            'people': ['女模特', '回望镜头'],
          }),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_compatible_fields_');
    addTearDown(() => image.parent.delete(recursive: true));

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 12,
      rowIndex: 2,
      columnIndex: 1,
    );

    expect(result.scene, '复古街道');
    expect(result.props, '“BAR”字样招牌、砖墙、老式汽车');
    expect(result.people, '女模特、回望镜头');
    expect(result.recoveryMode, VisionImageRecoveryMode.none);
  });

  test('单图非法 JSON 会使用原始响应自动修复', () async {
    final requests = <Map<String, dynamic>>[];
    final invalidJson =
        '{"caption":"女模特站在酒吧旁","detail":"女模特在砖墙旁回望",'
        '"props":""BAR"字样的复古招牌"}';
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (requests.length == 1) {
          return _chatResponse(invalidJson);
        }
        return _chatResponse(
          jsonEncode({
            'caption': '女模特站在酒吧旁',
            'detail': '女模特在砖墙旁回望',
            'props': '“BAR”字样的复古招牌',
          }),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_json_repair_');
    addTearDown(() => image.parent.delete(recursive: true));

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 12,
      rowIndex: 2,
      columnIndex: 1,
    );

    expect(result.props, '“BAR”字样的复古招牌');
    expect(result.recoveryMode, VisionImageRecoveryMode.jsonRepair);
    expect(result.requestCount, 2);
    expect(result.recoveryErrors.single, contains('Unexpected character'));
    final repairContent =
        requests[1]['messages'][0]['content'] as List<dynamic>;
    final repairPrompt =
        (repairContent.first as Map<String, dynamic>)['text'] as String;
    expect(repairPrompt, contains('只修复语法'));
    expect(repairPrompt, contains(invalidJson));
    expect(
      repairContent.any((part) => part is Map && part['type'] == 'image_url'),
      isFalse,
    );
  });

  test('单图首次服务异常时只重试当前图片一次', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.Response('{"error":"model crashed"}', 400);
        }
        return _chatResponse(
          jsonEncode({'caption': '女模特走过街道', 'detail': '女模特沿复古街道向右行走。'}),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_image_retry_');
    addTearDown(() => image.parent.delete(recursive: true));

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
    );

    expect(result.recoveryMode, VisionImageRecoveryMode.imageRetry);
    expect(result.requestCount, 2);
    expect(requestCount, 2);
  });

  test('完整解析连续异常时使用精简专业字段兜底', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        if (requestCount < 4) {
          return _chatResponse('{invalid json');
        }
        return _chatResponse(
          jsonEncode({
            'caption': '女模特在复古招牌旁驻足',
            'detail': '女模特在砖墙与金属招牌旁侧身回望。',
            'scene': '复古街道',
            'props': '“BAR”字样招牌、砖墙',
            'visual_focus': '女模特与金属招牌',
            'narrative_function': '推进',
            'transition_hint': '承接街头漫步镜头',
          }),
        );
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_simplified_fallback_');
    addTearDown(() => image.parent.delete(recursive: true));

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 12,
      rowIndex: 2,
      columnIndex: 1,
    );

    expect(result.recoveryMode, VisionImageRecoveryMode.simplifiedFallback);
    expect(result.requestCount, 4);
    expect(result.caption, '女模特在复古招牌旁驻足');
    expect(result.visualFocus, '女模特与金属招牌');
    expect(result.recoveryErrors, hasLength(3));
  });

  test('单图全部恢复失败时保留分阶段诊断信息', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        return _chatResponse('{invalid response $requestCount');
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_recovery_diagnostics_');
    addTearDown(() => image.parent.delete(recursive: true));

    final future = service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 12,
      rowIndex: 2,
      columnIndex: 1,
    );

    await expectLater(
      future,
      throwsA(
        isA<VisionImageAnalysisException>()
            .having((error) => error.requestCount, 'requestCount', 4)
            .having((error) => error.recoveryErrors.length, 'recoveryErrors', 4)
            .having(
              (error) => error.rawResponse,
              'rawResponse',
              allOf(contains('[响应 1]'), contains('[响应 4]')),
            ),
      ),
    );
    expect(requestCount, 4);
  });

  test('单图恢复链路被取消后不会继续发起补救请求', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        if (!started.isCompleted) {
          started.complete();
        }
        return response.future;
      }),
    );
    addTearDown(service.close);
    final image = await _testImage('vision_recovery_cancel_');
    addTearDown(() => image.parent.delete(recursive: true));

    final analysisFuture = service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
    );
    await started.future;
    service.cancelActiveRequests();
    response.complete(_chatResponse('{invalid json'));

    await expectLater(
      analysisFuture,
      throwsA(predicate((error) => error.toString().contains('请求已取消'))),
    );
    expect(requestCount, 1);
  });

  test('视觉服务会把男女称呼规范为模特称呼', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'caption': '女子在窗边看向男子',
                    'detail': '女子站在窗边，男子从门口走入。',
                    'scene': '室内',
                    'props': '窗户、门',
                    'people': '女子回头，男子进门',
                    'expression': '女子神情迟疑，男子表情平静',
                    'body_action': '女子站立，男子行走',
                    'movement_trend': '男子向前靠近',
                    'shot_size': '中景',
                    'composition': '女子在左，男子在右',
                    'subject_direction': '女子面向右侧，男子面向左侧',
                    'gaze_direction': '女子看向男子',
                    'action_stage': '进行',
                    'spatial_relation': '女子靠近窗户，男子位于门口',
                    'chronology_cue': '动作中',
                  }),
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

    final root = await Directory.systemTemp.createTemp('vision_terms_');
    addTearDown(() => root.delete(recursive: true));
    final image = File('${root.path}${Platform.pathSeparator}frame.png');
    await image.writeAsBytes([1, 2, 3]);

    final result = await service.analyzeImage(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
    );

    expect(result.caption, '女模特在窗边看向男模特');
    expect(result.detail, '女模特站在窗边，男模特从门口走入。');
    expect(result.people, '女模特回头，男模特进门');
    expect(result.expression, '女模特神情迟疑，男模特表情平静');
    expect(result.composition, '女模特在左，男模特在右');
  });

  test('摘要结果返回占位文字时使用逐图结果兜底', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'outline': '故事板大纲',
                    'content': '故事板内容概述',
                    'scenes': '出现的主要场景',
                    'props': '关键道具和视觉元素',
                  }),
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

    final result = await service.summarizeStoryboard(
      settings: _settings(),
      analyses: const [
        VisionImageAnalysis(
          caption: '女子在风中凝视远方',
          detail: '女子站在庭院中看向远方。',
          scene: '庭院',
          props: '牛仔衬衫',
          people: '女子凝视',
          expression: '神情凝重，视线望向远方',
          bodyAction: '站在风中保持警觉',
          movementTrend: '身体朝右侧微转',
          shotSize: '中景',
          composition: '人物居中，背景为庭院',
          subjectDirection: '三分之二侧面朝右',
          gazeDirection: '看向画面右侧远方',
          actionStage: '建立',
          spatialRelation: '女子站在庭院中央',
          chronologyCue: '开场建立',
          rawResponse: '{}',
        ),
        VisionImageAnalysis(
          caption: '女子与马匹在牧场互动',
          detail: '女子靠近马匹，背景是牧场。',
          scene: '牧场',
          props: '马匹、围栏',
          people: '女子抚摸马匹',
          expression: '眼神柔和，专注看向马匹',
          bodyAction: '伸手靠近马匹',
          movementTrend: '向马匹靠近',
          shotSize: '中景',
          composition: '女子在左，马匹在右',
          subjectDirection: '面向右侧马匹',
          gazeDirection: '看向马匹',
          actionStage: '进行',
          spatialRelation: '女子靠近马匹左侧',
          chronologyCue: '动作中',
          rawResponse: '{}',
        ),
      ],
    );

    expect(result.outline, '镜头围绕女模特在风中凝视远方，并过渡到女模特与马匹在牧场互动展开，形成一段连续故事。');
    expect(
      result.content,
      '在庭院与牧场之间，镜头依次呈现女模特在风中凝视远方，并过渡到女模特与马匹在牧场互动，神态聚焦神情凝重，视线望向远方与眼神柔和，专注看向马匹，姿态动作包括站在风中保持警觉，并过渡到伸手靠近马匹，运动趋势表现为身体朝右侧微转与向马匹靠近，人物动作、视线、神态与运动趋势被连成一段完整画面。',
    );
    expect(result.scenes, '庭院、牧场');
    expect(result.props, '牛仔衬衫、马匹、围栏');
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('不要逐条罗列'));
    expect(prompt, contains('不要把逐图短句用分号直接拼接'));
    expect(
      content.any((part) => part is Map && part['type'] == 'image_url'),
      isFalse,
    );
  });

  test('连贯化宫格文本会按图片数量返回 captions', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'captions': ['女子先在窗边回望', '随后男子走向门口'],
                  }),
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

    final result = await service.rewriteStoryboardCaptions(
      settings: _settings(),
      analyses: const [
        VisionImageAnalysis(
          caption: '女子看窗外',
          detail: '女子站在窗边，光线从窗外照入。',
          scene: '室内窗边',
          props: '窗户',
          people: '女子站立',
          expression: '神情迟疑',
          bodyAction: '站在窗边回头',
          movementTrend: '身体转向右侧',
          shotSize: '中景',
          composition: '人物在窗边偏左',
          subjectDirection: '身体右转',
          gazeDirection: '回看画面右侧',
          actionStage: '准备',
          spatialRelation: '女子站在窗户旁',
          chronologyCue: '动作前',
          rawResponse: '{}',
        ),
        VisionImageAnalysis(
          caption: '女子走向门口',
          detail: '女子离开窗边，走向门口。',
          scene: '室内门口',
          props: '门',
          people: '女子行走',
          expression: '视线看向前方',
          bodyAction: '迈步向门口移动',
          movementTrend: '向前行走',
          shotSize: '全景',
          composition: '人物位于通向门口的空间中',
          subjectDirection: '面向前方门口',
          gazeDirection: '看向门口',
          actionStage: '进行',
          spatialRelation: '女子从窗边走向门口',
          chronologyCue: '动作中',
          rawResponse: '{}',
        ),
      ],
    );

    expect(result.captions, ['女模特先在窗边回望。', '随后男模特走向门口。']);
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('数量必须与输入图片数量完全一致'));
    expect(prompt, contains('像连续镜头的一部分'));
    expect(prompt, contains('视觉焦点'));
    expect(prompt, contains('光色氛围'));
    expect(prompt, contains('镜头功能'));
    expect(prompt, contains('剪辑承接'));
    expect(prompt, contains('不要写成孤立标签'));
  });

  test('连贯化缺少中间编号时只补全缺项且不会错位', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        final content = requestCount == 1
            ? {
                'storyContext': '女模特从室内走向门口',
                'captions': [
                  {'sequenceNo': 1, 'text': '开场女模特整理衣装'},
                  {'sequenceNo': 3, 'text': '最后女模特走出门口'},
                ],
              }
            : {
                'captions': [
                  {'sequenceNo': 2, 'text': '随后女模特转身看向门口'},
                ],
              };
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(content)},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(service.close);

    final result = await service.rewriteStoryboardCaptions(
      settings: _settings(),
      analyses: _sampleAnalysesForCount(3),
    );

    expect(result.captions, ['开场女模特整理衣装。', '随后女模特转身看向门口。', '最后女模特走出门口。']);
    expect(result.initialReturnedCount, 2);
    expect(result.repairedSequenceNos, [2]);
    expect(result.fallbackSequenceNos, isEmpty);
    expect(requestCount, 2);
  });

  test('连贯化缺项补全失败时只回退对应原始 caption', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        if (requestCount > 1) {
          return http.Response('{"error":"model crashed"}', 400);
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'captions': [
                      {'sequenceNo': 1, 'text': '开场女模特走向门口'},
                    ],
                  }),
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

    final result = await service.rewriteStoryboardCaptions(
      settings: _settings(),
      analyses: _sampleAnalyses(),
    );

    expect(result.captions, ['开场女模特走向门口。', '最后，女模特看窗外。']);
    expect(result.repairedSequenceNos, isEmpty);
    expect(result.fallbackSequenceNos, [2]);
    expect(requestCount, 3);
  });

  test('连贯化首次服务崩溃时会有限重试', () async {
    var requestCount = 0;
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.Response('{"error":"model crashed"}', 400);
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'captions': [
                      {'sequenceNo': 1, 'text': '开场女模特走向门口'},
                      {'sequenceNo': 2, 'text': '随后女模特看向窗外'},
                    ],
                  }),
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

    final result = await service.rewriteStoryboardCaptions(
      settings: _settings(),
      analyses: _sampleAnalyses(),
    );

    expect(result.fallbackSequenceNos, isEmpty);
    expect(requestCount, 2);
  });

  test('图片修改建议会带入全局逐图多维度解析', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'advice': '强化人物视线与动作承接',
                    'prompt': '保留原图主体，强化人物看向门口的视线和前行动作。',
                  }),
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

    final root = await Directory.systemTemp.createTemp('vision_service_');
    addTearDown(() => root.delete(recursive: true));
    final image = File('${root.path}${Platform.pathSeparator}frame.png');
    await image.writeAsBytes([1, 2, 3]);
    final analyses = _sampleAnalyses();

    final result = await service.suggestImageEditPrompt(
      settings: _settings(),
      imageFile: image,
      sequenceNo: 1,
      rowIndex: 0,
      columnIndex: 0,
      currentCaption: '女子走向门口',
      previousCaption: '',
      nextCaption: '女子看窗外',
      rowCaption: '女子在室内移动',
      storyboardSummary: '测试摘要：女子从窗边走向门口。',
      currentAnalysis: analyses.first,
      previousAnalysis: null,
      nextAnalysis: analyses.last,
      storyboardAnalyses: analyses,
    );

    expect(result.advice, '强化人物视线与动作承接');
    expect(result.prompt, contains('保留原图主体'));
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('当前分镜多维解析'));
    expect(prompt, contains('前一分镜多维解析'));
    expect(prompt, contains('后一分镜多维解析'));
    expect(prompt, contains('全局逐图解析'));
    expect(prompt, contains('测试摘要'));
    expect(prompt, contains('景别'));
    expect(prompt, contains('空间关系'));
    expect(prompt, contains('综合设计要求'));
    expect(
      content.any((part) => part is Map && part['type'] == 'image_url'),
      isTrue,
    );
  });

  test('视觉服务会按解析文本请求故事板重排序', () async {
    final requests = <Map<String, dynamic>>[];
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'order': [2, 1],
                  }),
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

    final result = await service.suggestStoryboardOrder(
      settings: _settings(),
      analyses: _sampleAnalyses(),
    );

    expect(result.order, [2, 1]);
    final content = requests.single['messages'][0]['content'] as List<dynamic>;
    final prompt = (content.first as Map<String, dynamic>)['text'] as String;
    expect(prompt, contains('order 数组'));
    expect(prompt, contains('原始图片编号'));
    expect(prompt, contains('专业分镜师'));
    expect(prompt, contains('建立镜头'));
    expect(prompt, contains('动作阶段'));
    expect(prompt, contains('人物朝向'));
    expect(prompt, contains('候选故事板'));
    expect(prompt, contains('保守模式'));
    expect(prompt, contains('最小改动原则'));
    expect(prompt, contains('镜头功能'));
    expect(prompt, contains('叙事功能'));
    expect(prompt, contains('视觉焦点'));
    expect(prompt, contains('剪辑承接'));
    expect(prompt, contains('完成端点'));
    expect(prompt, contains('景别不是时间线'));
    expect(prompt, contains('不天然等于结尾'));
    expect(prompt, contains('广告产品记忆点'));
    expect(prompt, contains('packshot'));
    expect(prompt, contains('不是默认脸部或局部特写'));
    expect(
      content.any((part) => part is Map && part['type'] == 'image_url'),
      isFalse,
    );
  });

  test('视觉服务兼容嵌套零基对象形式的重排序编号', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'result': {
                      'order': [
                        {'index': 1},
                        {'index': 0},
                      ],
                    },
                  }),
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

    final result = await service.suggestStoryboardOrder(
      settings: _settings(),
      analyses: _sampleAnalyses(),
    );

    expect(result.order, [2, 1]);
  });

  test('视觉服务会补全少量缺失的重排序编号', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'order': [4, 3, 5, 9, 1, 6, 8, 2],
                  }),
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

    final result = await service.suggestStoryboardOrder(
      settings: _settings(),
      analyses: _sampleAnalysesForCount(9),
    );

    expect(result.order, [4, 3, 5, 9, 1, 6, 7, 8, 2]);
  });

  test('视觉服务会拒绝重复的重排序编号', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'order': [2, 2],
                  }),
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

    expect(
      service.suggestStoryboardOrder(
        settings: _settings(),
        analyses: _sampleAnalyses(),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('视觉服务的 order 异常会携带原始响应摘要', () async {
    final service = VisionStoryboardService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'order': [2, 2],
                    'note': 'bad duplicated order',
                  }),
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

    expect(
      service.suggestStoryboardOrder(
        settings: _settings(),
        analyses: _sampleAnalyses(),
      ),
      throwsA(
        isA<FormatException>()
            .having((error) => error.message, 'message', contains('原始响应'))
            .having(
              (error) => error.message,
              'message',
              contains('bad duplicated order'),
            ),
      ),
    );
  });
}

http.Response _chatResponse(String content) {
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<File> _testImage(String prefix) async {
  final root = await Directory.systemTemp.createTemp(prefix);
  final image = File('${root.path}${Platform.pathSeparator}frame.png');
  await image.writeAsBytes([1, 2, 3]);
  return image;
}

AppSettings _settings({
  String visionModel = 'test-vlm',
  VisionApiRequestProtocol protocol = VisionApiRequestProtocol.chatCompletions,
}) {
  final visionConfig = VisionApiConfig(
    id: 'test-vision',
    name: '测试视觉模型',
    baseUrl: '127.0.0.1:12345',
    apiKey: 'test-key',
    model: visionModel,
    requestProtocol: protocol,
  );
  return AppSettings(
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
    visionModel: visionModel,
    visionApiConfigs: [visionConfig],
    activeVisionApiConfigId: visionConfig.id,
    imageGenerationApiBaseUrl: 'https://grsai.dakka.com.cn',
    imageGenerationApiKey: 'test-image-key',
    imageGenerationGeminiApiKey: 'test-gemini-key',
    imageGenerationModel: 'nano-banana-fast',
    updateReleaseApiUrl: '',
    autoInstallUpdates: false,
    updateDownloadMode: UpdateDownloadMode.automatic,
    updateManualProxyUrl: 'http://127.0.0.1:7890',
  );
}

List<VisionImageAnalysis> _sampleAnalyses() {
  return const [
    VisionImageAnalysis(
      caption: '女子走向门口',
      detail: '女子离开窗边，走向门口。',
      scene: '室内门口',
      props: '门',
      people: '女子行走',
      expression: '视线看向前方',
      bodyAction: '迈步向门口移动',
      movementTrend: '向前行走',
      shotSize: '全景',
      composition: '门口位于画面前方',
      subjectDirection: '面向门口',
      gazeDirection: '看向前方',
      actionStage: '进行',
      spatialRelation: '女子从窗边向门口移动',
      chronologyCue: '动作中',
      rawResponse: '{}',
    ),
    VisionImageAnalysis(
      caption: '女子看窗外',
      detail: '女子站在窗边，光线从窗外照入。',
      scene: '室内窗边',
      props: '窗户',
      people: '女子站立',
      expression: '神情迟疑',
      bodyAction: '站在窗边回头',
      movementTrend: '身体转向右侧',
      shotSize: '中景',
      composition: '窗户在人物右侧',
      subjectDirection: '身体右转',
      gazeDirection: '看向窗外',
      actionStage: '准备',
      spatialRelation: '女子站在窗边',
      chronologyCue: '动作前',
      rawResponse: '{}',
    ),
  ];
}

List<VisionImageAnalysis> _sampleAnalysesForCount(int count) {
  final samples = _sampleAnalyses();
  return [
    for (var i = 0; i < count; i++)
      samples[i % samples.length].withCaption('样例分镜 ${i + 1}'),
  ];
}
