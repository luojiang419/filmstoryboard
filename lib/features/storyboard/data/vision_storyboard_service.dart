import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/services/vision_request_rate_limiter.dart';
import '../../settings/domain/app_settings.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import 'vision_caption_coherence_service.dart';

enum VisionImageRecoveryMode {
  none,
  jsonRepair,
  imageRetry,
  simplifiedFallback,
}

class VisionImageAnalysisException implements Exception {
  const VisionImageAnalysisException({
    required this.sequenceNo,
    required this.requestCount,
    required this.recoveryErrors,
    required this.rawResponse,
  });

  final int sequenceNo;
  final int requestCount;
  final List<String> recoveryErrors;
  final String rawResponse;

  @override
  String toString() {
    return '第 $sequenceNo 张图片解析在 $requestCount 次请求后仍失败：'
        '${recoveryErrors.join('；')}';
  }
}

class VisionImageAnalysis {
  const VisionImageAnalysis({
    required this.caption,
    required this.detail,
    required this.scene,
    required this.props,
    required this.people,
    required this.expression,
    required this.bodyAction,
    required this.movementTrend,
    required this.shotSize,
    this.cameraMovement = '',
    required this.composition,
    required this.subjectDirection,
    required this.gazeDirection,
    required this.actionStage,
    required this.spatialRelation,
    required this.chronologyCue,
    this.cameraAngle = '',
    this.visualFocus = '',
    this.lightingMood = '',
    this.colorPalette = '',
    this.narrativeFunction = '',
    this.transitionHint = '',
    this.recoveryMode = VisionImageRecoveryMode.none,
    this.requestCount = 1,
    this.recoveryErrors = const [],
    required this.rawResponse,
  });

  final String caption;
  final String detail;
  final String scene;
  final String props;
  final String people;
  final String expression;
  final String bodyAction;
  final String movementTrend;
  final String cameraMovement;
  final String shotSize;
  final String composition;
  final String subjectDirection;
  final String gazeDirection;
  final String actionStage;
  final String spatialRelation;
  final String chronologyCue;
  final String cameraAngle;
  final String visualFocus;
  final String lightingMood;
  final String colorPalette;
  final String narrativeFunction;
  final String transitionHint;
  final VisionImageRecoveryMode recoveryMode;
  final int requestCount;
  final List<String> recoveryErrors;
  final String rawResponse;

  bool get hasStoryboardOrderingCues {
    return shotSize.trim().isNotEmpty ||
        composition.trim().isNotEmpty ||
        subjectDirection.trim().isNotEmpty ||
        gazeDirection.trim().isNotEmpty ||
        actionStage.trim().isNotEmpty ||
        spatialRelation.trim().isNotEmpty ||
        chronologyCue.trim().isNotEmpty ||
        visualFocus.trim().isNotEmpty ||
        narrativeFunction.trim().isNotEmpty ||
        transitionHint.trim().isNotEmpty;
  }

  VisionImageAnalysis withCaption(String caption) {
    return VisionImageAnalysis(
      caption: normalizeVisionModelRoleTerms(caption),
      detail: detail,
      scene: scene,
      props: props,
      people: people,
      expression: expression,
      bodyAction: bodyAction,
      movementTrend: movementTrend,
      cameraMovement: cameraMovement,
      shotSize: shotSize,
      composition: composition,
      subjectDirection: subjectDirection,
      gazeDirection: gazeDirection,
      actionStage: actionStage,
      spatialRelation: spatialRelation,
      chronologyCue: chronologyCue,
      cameraAngle: cameraAngle,
      visualFocus: visualFocus,
      lightingMood: lightingMood,
      colorPalette: colorPalette,
      narrativeFunction: narrativeFunction,
      transitionHint: transitionHint,
      recoveryMode: recoveryMode,
      requestCount: requestCount,
      recoveryErrors: recoveryErrors,
      rawResponse: rawResponse,
    );
  }
}

class VisionStoryboardSummaryResult {
  const VisionStoryboardSummaryResult({
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
    required this.rawResponse,
  });

  final String outline;
  final String content;
  final String scenes;
  final String props;
  final String rawResponse;
}

class VisionVideoDimensionResult {
  const VisionVideoDimensionResult({
    required this.dimensions,
    required this.rawResponse,
  });

  final Map<String, String> dimensions;
  final String rawResponse;
}

class VisionStoryboardCaptionRewriteResult {
  const VisionStoryboardCaptionRewriteResult({
    required this.captions,
    required this.rawResponse,
    this.initialReturnedCount = 0,
    this.repairedSequenceNos = const [],
    this.fallbackSequenceNos = const [],
    this.diagnostics = const {},
  });

  final List<String> captions;
  final String rawResponse;
  final int initialReturnedCount;
  final List<int> repairedSequenceNos;
  final List<int> fallbackSequenceNos;
  final Map<String, Object?> diagnostics;
}

class _VisionRequestCancelledException implements Exception {
  const _VisionRequestCancelledException();

  @override
  String toString() => '视觉模型请求已取消';
}

class VisionStoryboardOrderResult {
  const VisionStoryboardOrderResult({
    required this.order,
    required this.rawResponse,
  });

  final List<int> order;
  final String rawResponse;
}

class VisionImageEditSuggestion {
  const VisionImageEditSuggestion({
    required this.advice,
    required this.prompt,
    required this.rawResponse,
  });

  final String advice;
  final String prompt;
  final String rawResponse;
}

class VisionStoryboardService {
  VisionStoryboardService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static const _maxMissingOrderRepairCount = 2;

  static const requestTimeout = Duration(seconds: 120);

  http.Client _client;
  final bool _ownsClient;
  bool _closed = false;
  var _cancelGeneration = 0;

  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    _validateSettings(settings);
    final bytes = await imageFile.readAsBytes();
    final mimeType = _mimeTypeForPath(imageFile.path);
    final imageDataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final requestGeneration = _cancelGeneration;
    final responses = <String>[];
    final recoveryErrors = <String>[];
    var requestCount = 0;

    Future<String> request({
      required String prompt,
      String? image,
      required int maxTokens,
    }) async {
      _throwIfCancelled(requestGeneration);
      requestCount++;
      final content = await _createChatCompletion(
        settings: settings,
        prompt: prompt,
        imageDataUrl: image,
        maxTokens: maxTokens,
        allowThinking: allowThinking,
      );
      responses.add(content);
      return content;
    }

    String? initialContent;
    try {
      initialContent = await request(
        prompt: _imagePrompt(sequenceNo, rowIndex, columnIndex),
        image: imageDataUrl,
        maxTokens: 1400,
      );
      return _analysisFromContent(
        initialContent,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('initial: $error');
    }

    if (initialContent != null) {
      try {
        onRecovery?.call(VisionImageRecoveryMode.jsonRepair);
        final repairedContent = await request(
          prompt: _imageJsonRepairPrompt(
            sequenceNo: sequenceNo,
            rawResponse: initialContent,
            parseError: recoveryErrors.last,
          ),
          maxTokens: 1400,
        );
        return _analysisFromContent(
          repairedContent,
          recoveryMode: VisionImageRecoveryMode.jsonRepair,
          rawResponse: _joinedRecoveryResponses(responses),
          requestCount: requestCount,
          recoveryErrors: recoveryErrors,
        );
      } catch (error) {
        _throwIfCancelled(requestGeneration);
        recoveryErrors.add('json_repair: $error');
      }
    }

    try {
      onRecovery?.call(VisionImageRecoveryMode.imageRetry);
      final retryContent = await request(
        prompt: _imageRetryPrompt(sequenceNo, rowIndex, columnIndex),
        image: imageDataUrl,
        maxTokens: 1400,
      );
      return _analysisFromContent(
        retryContent,
        recoveryMode: VisionImageRecoveryMode.imageRetry,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('image_retry: $error');
    }

    try {
      onRecovery?.call(VisionImageRecoveryMode.simplifiedFallback);
      final fallbackContent = await request(
        prompt: _simplifiedImagePrompt(sequenceNo, rowIndex, columnIndex),
        image: imageDataUrl,
        maxTokens: 800,
      );
      return _analysisFromContent(
        fallbackContent,
        recoveryMode: VisionImageRecoveryMode.simplifiedFallback,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('simplified_fallback: $error');
      throw VisionImageAnalysisException(
        sequenceNo: sequenceNo,
        requestCount: requestCount,
        recoveryErrors: List.unmodifiable(recoveryErrors.map(_compactForError)),
        rawResponse: _joinedRecoveryResponses(responses),
      );
    }
  }

  VisionImageAnalysis _analysisFromContent(
    String content, {
    VisionImageRecoveryMode recoveryMode = VisionImageRecoveryMode.none,
    required String rawResponse,
    required int requestCount,
    required List<String> recoveryErrors,
  }) {
    final json = _extractJsonObject(content);
    final caption = _stringValue(json, 'caption');
    final detail = _stringValue(json, 'detail');
    if (caption.isEmpty || detail.isEmpty) {
      final missing = [
        if (caption.isEmpty) 'caption',
        if (detail.isEmpty) 'detail',
      ];
      throw FormatException('视觉模型缺少关键字段：${missing.join(', ')}');
    }
    return VisionImageAnalysis(
      caption: caption,
      detail: detail,
      scene: _stringValue(json, 'scene'),
      props: _stringValue(json, 'props'),
      people: _stringValue(json, 'people'),
      expression: _stringValue(json, 'expression'),
      bodyAction: _firstStringValue(json, const ['body_action', 'bodyAction']),
      movementTrend: _firstStringValue(json, const [
        'movement_trend',
        'movementTrend',
      ]),
      cameraMovement: _firstStringValue(json, const [
        'camera_movement',
        'cameraMovement',
      ]),
      shotSize: _firstStringValue(json, const ['shot_size', 'shotSize']),
      composition: _stringValue(json, 'composition'),
      subjectDirection: _firstStringValue(json, const [
        'subject_direction',
        'subjectDirection',
      ]),
      gazeDirection: _firstStringValue(json, const [
        'gaze_direction',
        'gazeDirection',
      ]),
      actionStage: _firstStringValue(json, const [
        'action_stage',
        'actionStage',
      ]),
      spatialRelation: _firstStringValue(json, const [
        'spatial_relation',
        'spatialRelation',
      ]),
      chronologyCue: _firstStringValue(json, const [
        'chronology_cue',
        'chronologyCue',
      ]),
      cameraAngle: _firstStringValue(json, const [
        'camera_angle',
        'cameraAngle',
      ]),
      visualFocus: _firstStringValue(json, const [
        'visual_focus',
        'visualFocus',
      ]),
      lightingMood: _firstStringValue(json, const [
        'lighting_mood',
        'lightingMood',
      ]),
      colorPalette: _firstStringValue(json, const [
        'color_palette',
        'colorPalette',
      ]),
      narrativeFunction: _firstStringValue(json, const [
        'narrative_function',
        'narrativeFunction',
      ]),
      transitionHint: _firstStringValue(json, const [
        'transition_hint',
        'transitionHint',
      ]),
      recoveryMode: recoveryMode,
      requestCount: requestCount,
      recoveryErrors: List.unmodifiable(recoveryErrors),
      rawResponse: rawResponse,
    );
  }

  Future<VisionStoryboardSummaryResult> summarizeStoryboard({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
  }) async {
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _summaryPrompt(analyses),
      maxTokens: 1200,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    return VisionStoryboardSummaryResult(
      outline: _summaryValue(
        json,
        'outline',
        fallback: _fallbackOutline(analyses),
        placeholders: const {'故事板大纲', '大纲'},
      ),
      content: _summaryValue(
        json,
        'content',
        fallback: _fallbackContent(analyses),
        placeholders: const {'故事板内容概述', '内容概述', '故事板内容'},
      ),
      scenes: _summaryValue(
        json,
        'scenes',
        fallback: _fallbackJoinedValues(
          analyses.map((analysis) => analysis.scene),
        ),
        placeholders: const {'出现的主要场景', '主要场景', '场景'},
      ),
      props: _summaryValue(
        json,
        'props',
        fallback: _fallbackJoinedValues(
          analyses.map((analysis) => analysis.props),
        ),
        placeholders: const {'关键道具和视觉元素', '关键道具', '视觉元素', '道具'},
      ),
      rawResponse: content,
    );
  }

  Future<VisionVideoDimensionResult> analyzeVideoDimensions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    required Map<String, String> summary,
    bool allowThinking = false,
  }) async {
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _videoDimensionPrompt(analyses, summary),
      maxTokens: 4200,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    return VisionVideoDimensionResult(
      dimensions: {
        for (final field in videoAnalysisDimensionFields)
          field: _stringValue(json, field),
      },
      rawResponse: content,
    );
  }

  Future<VisionStoryboardCaptionRewriteResult> rewriteStoryboardCaptions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (analyses.isEmpty) {
      return const VisionStoryboardCaptionRewriteResult(
        captions: [],
        rawResponse: '',
      );
    }
    _validateSettings(settings);
    final requestGeneration = _cancelGeneration;
    final coherenceService = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        _throwIfCancelled(requestGeneration);
        final completion = await _createChatCompletionDetailed(
          settings: settings,
          prompt: prompt,
          maxTokens: maxTokens,
          allowThinking: allowThinking,
        );
        _throwIfCancelled(requestGeneration);
        return completion;
      },
      shouldRethrow: (error) => error is _VisionRequestCancelledException,
    );
    final coherence = await coherenceService.rewrite(
      sources: [
        for (var index = 0; index < analyses.length; index++)
          VisionCaptionSource(
            sequenceNo: index + 1,
            caption: normalizeVisionModelRoleTerms(analyses[index].caption),
            scene: normalizeVisionModelRoleTerms(analyses[index].scene),
            bodyAction: normalizeVisionModelRoleTerms(
              analyses[index].bodyAction,
            ),
            actionStage: normalizeVisionModelRoleTerms(
              analyses[index].actionStage,
            ),
            visualFocus: normalizeVisionModelRoleTerms(
              analyses[index].visualFocus,
            ),
            lightingMood: normalizeVisionModelRoleTerms(
              analyses[index].lightingMood,
            ),
            narrativeFunction: normalizeVisionModelRoleTerms(
              analyses[index].narrativeFunction,
            ),
            transitionHint: normalizeVisionModelRoleTerms(
              analyses[index].transitionHint,
            ),
          ),
      ],
      onProgress: onProgress,
    );
    return VisionStoryboardCaptionRewriteResult(
      captions: coherence.captions
          .map(normalizeVisionModelRoleTerms)
          .toList(growable: false),
      rawResponse: coherence.rawResponse,
      initialReturnedCount: coherence.initialReturnedCount,
      repairedSequenceNos: coherence.repairedSequenceNos,
      fallbackSequenceNos: coherence.localFallbackSequenceNos,
      diagnostics: coherence.diagnostics,
    );
  }

  Future<VisionStoryboardOrderResult> suggestStoryboardOrder({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
  }) async {
    if (analyses.isEmpty) {
      return const VisionStoryboardOrderResult(order: [], rawResponse: '');
    }
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _orderPrompt(analyses),
      maxTokens: (500 + analyses.length * 60).clamp(700, 1800).toInt(),
    );
    try {
      final json = _extractJsonObject(content);
      return VisionStoryboardOrderResult(
        order: _orderListValue(json, analyses.length),
        rawResponse: content,
      );
    } on FormatException catch (error) {
      throw FormatException(
        '${error.message}；原始响应：${_compactForError(content)}',
      );
    }
  }

  Future<VisionImageEditSuggestion> suggestImageEditPrompt({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String currentCaption,
    required String previousCaption,
    required String nextCaption,
    required String rowCaption,
    required String storyboardSummary,
    required VisionImageAnalysis currentAnalysis,
    required VisionImageAnalysis? previousAnalysis,
    required VisionImageAnalysis? nextAnalysis,
    required List<VisionImageAnalysis> storyboardAnalyses,
  }) async {
    _validateSettings(settings);
    final bytes = await imageFile.readAsBytes();
    final mimeType = _mimeTypeForPath(imageFile.path);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _imageEditSuggestionPrompt(
        sequenceNo: sequenceNo,
        rowIndex: rowIndex,
        columnIndex: columnIndex,
        currentCaption: currentCaption,
        previousCaption: previousCaption,
        nextCaption: nextCaption,
        rowCaption: rowCaption,
        storyboardSummary: storyboardSummary,
        currentAnalysis: currentAnalysis,
        previousAnalysis: previousAnalysis,
        nextAnalysis: nextAnalysis,
        storyboardAnalyses: storyboardAnalyses,
      ),
      imageDataUrl: 'data:$mimeType;base64,${base64Encode(bytes)}',
      maxTokens: 1400,
    );
    final json = _extractJsonObject(content);
    final prompt = _stringValue(json, 'prompt');
    if (prompt.trim().isEmpty) {
      throw const FormatException('视觉模型未返回可用的修改提示词');
    }
    return VisionImageEditSuggestion(
      advice: _stringValue(json, 'advice'),
      prompt: prompt,
      rawResponse: content,
    );
  }

  void cancelActiveRequests() {
    _cancelGeneration++;
    if (!_ownsClient || _closed) {
      return;
    }
    _client.close();
    _client = http.Client();
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _client.close();
  }

  void _throwIfCancelled(int requestGeneration) {
    if (_closed || requestGeneration != _cancelGeneration) {
      throw const _VisionRequestCancelledException();
    }
  }

  Future<String> _createChatCompletion({
    required AppSettings settings,
    required String prompt,
    String? imageDataUrl,
    List<String> imageDataUrls = const [],
    required int maxTokens,
    bool allowThinking = false,
  }) async {
    final completion = await _createChatCompletionDetailed(
      settings: settings,
      prompt: prompt,
      imageDataUrl: imageDataUrl,
      imageDataUrls: imageDataUrls,
      maxTokens: maxTokens,
      allowThinking: allowThinking,
    );
    return completion.content;
  }

  /// Runs a JSON-oriented chat completion for workflow features that need to
  /// compare several local images in one request.
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
  }) async {
    _validateSettings(settings);
    final imageDataUrls = <String>[];
    for (final imageFile in imageFiles) {
      if (!imageFile.existsSync()) continue;
      final bytes = await imageFile.readAsBytes();
      imageDataUrls.add(
        'data:${_mimeTypeForPath(imageFile.path)};base64,${base64Encode(bytes)}',
      );
    }
    return _createChatCompletion(
      settings: settings,
      prompt: prompt,
      imageDataUrls: imageDataUrls,
      maxTokens: maxTokens,
      allowThinking: allowThinking,
    );
  }

  Future<VisionChatCompletion> _createChatCompletionDetailed({
    required AppSettings settings,
    required String prompt,
    String? imageDataUrl,
    List<String> imageDataUrls = const [],
    required int maxTokens,
    bool allowThinking = false,
  }) async {
    await VisionRequestRateLimiter.waitForRequestSlot(settings);
    final endpoint = normalizeChatCompletionsEndpoint(
      settings.visionApiBaseUrl,
    );
    final disableThinking = _shouldDisableThinking(
      settings,
      allowThinking: allowThinking,
    );
    final enableThinking = _shouldEnableThinking(settings, allowThinking);
    final content = <Map<String, Object?>>[
      {
        'type': 'text',
        'text': disableThinking
            ? '/no_think\n$prompt'
            : enableThinking
            ? '/think\n$prompt'
            : prompt,
      },
      for (final image in [
        ...?imageDataUrl == null ? null : [imageDataUrl],
        ...imageDataUrls,
      ])
        {
          'type': 'image_url',
          'image_url': {'url': image},
        },
    ];
    final response = await _client
        .post(
          endpoint,
          headers: {
            'Content-Type': 'application/json',
            if (settings.visionApiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${settings.visionApiKey.trim()}',
          },
          body: jsonEncode({
            'model': settings.visionModel.trim(),
            'messages': [
              {'role': 'user', 'content': content},
            ],
            'temperature': 0,
            if (disableThinking) ...{
              'chat_template_kwargs': {'enable_thinking': false},
              'enable_thinking': false,
            },
            if (enableThinking) ...{
              'chat_template_kwargs': {'enable_thinking': true},
              'enable_thinking': true,
            },
          }),
        )
        .timeout(
          requestTimeout,
          onTimeout: () {
            throw TimeoutException(
              '视觉模型请求超时：超过 ${requestTimeout.inSeconds} 秒未响应',
            );
          },
        );
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('视觉模型请求失败：${response.statusCode} $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('视觉模型响应不是 JSON 对象');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('视觉模型响应缺少 choices');
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      throw const FormatException('视觉模型 choices 格式异常');
    }
    final message = firstChoice['message'];
    if (message is! Map<String, dynamic>) {
      throw const FormatException('视觉模型响应缺少 message');
    }
    final messageContent = message['content'];
    final String text;
    if (messageContent is String) {
      text = messageContent;
    } else if (messageContent is List) {
      text = messageContent
          .map((item) {
            if (item is Map && item['text'] != null) {
              return item['text'].toString();
            }
            return item.toString();
          })
          .join('\n');
    } else {
      throw const FormatException('视觉模型响应缺少文本内容');
    }
    final usage = decoded['usage'];
    return VisionChatCompletion(
      content: text,
      finishReason: firstChoice['finish_reason']?.toString() ?? '',
      promptTokens: usage is Map ? _nullableInt(usage['prompt_tokens']) : null,
      completionTokens: usage is Map
          ? _nullableInt(usage['completion_tokens'])
          : null,
      totalTokens: usage is Map ? _nullableInt(usage['total_tokens']) : null,
    );
  }

  int? _nullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  bool _shouldDisableThinking(
    AppSettings settings, {
    required bool allowThinking,
  }) {
    return !allowThinking && _supportsThinkingToggle(settings);
  }

  bool _shouldEnableThinking(AppSettings settings, bool allowThinking) {
    return allowThinking && _supportsThinkingToggle(settings);
  }

  bool _supportsThinkingToggle(AppSettings settings) {
    final model = settings.visionModel.trim().toLowerCase();
    return model.contains('qwen3') || model.contains('qwen-3');
  }

  void _validateSettings(AppSettings settings) {
    if (settings.visionApiBaseUrl.trim().isEmpty) {
      throw const FormatException('请先填写视觉模型 API 地址');
    }
    if (settings.visionModel.trim().isEmpty) {
      throw const FormatException('请先填写视觉模型名称');
    }
  }

  String _imagePrompt(int sequenceNo, int rowIndex, int columnIndex) {
    return '''
你正在为故事板自动生成画面描述，并为后续自动重排序提取专业镜头线索。
请分析第 $sequenceNo 张图片，它位于第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列。
描述要有镜头画面感：把主体、环境、动作、情绪、光线、视觉焦点和镜头意图连成一句自然中文。
称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。
请额外细分神态、姿态动作、运动趋势、景别、构图、人物朝向、视线方向、动作阶段、空间关系、时间进度线索、机位角度、视觉焦点、光线情绪、色彩调性、镜头叙事功能和剪辑承接。
景别只能从全景/中景/近景/特写/大全景/远景/中近景/大特写中选择一个；动作阶段优先判断为建立/准备/进行/反应/结果/收束/静态。
人物朝向和视线方向需要写清楚面向左/右/正面/背向/三分之二侧面，以及看向画内主体、画外方向、镜头或不明显。
运动趋势包括向左、向右、靠近、远离、起身、坐下、转身等可见方向或动作变化。
镜头叙事功能优先从建立、推进、揭示、证明、反应、转折、结果、收束、广告产品记忆点、静态展示中选择；剪辑承接要说明更适合切入、承接、插入、反应、回到结果或收尾。
不要写成孤立标签，不要只罗列“人物+动作+地点”，不要编造图片里看不见的剧情。
无法从画面判断时，相关字段写“静止不明显”“不明显”或“无人物/不适用”，不要猜剧情。
只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。
JSON 必须能被标准解析器直接解析；所有字段值必须是字符串，不能返回数组或嵌套对象。
画面内的文字或招牌请使用中文引号“”，禁止在 JSON 字符串内部直接使用未转义的英文双引号。
返回前检查双引号转义、逗号和括号是否完整。
JSON 字段：
{
  "caption": "适合填入故事板文本框的中文画面句，45字以内；不拥挤时优先体现视觉焦点、关键动作、镜头意图或方向",
  "detail": "详细描述画面主体、动作、构图、光线、情绪、神态、视觉焦点和重要信息",
  "scene": "场景/地点/环境",
  "props": "画面中重要道具、物体或视觉元素",
  "people": "人物、角色或动作；没有则写空字符串",
  "expression": "面部神态、视线方向和情绪状态；没有人物则写空字符串",
  "body_action": "身体姿态和正在发生的动作，例如站立、倚靠、伸手、起身、回头",
 "movement_trend": "可见方向、位移或动作趋势，例如向右行走、身体左转、准备起身；无法判断则写静止不明显",
  "camera_movement": "镜头运镜，只能从固定、推、拉、摇、移、跟、环绕、升降、正跟随、倒跟随、手持、平移、摇移中选择一个；单张画面无法可靠判断时写空字符串",
  "shot_size": "景别，只能从全景、中景、近景、特写、大全景、远景、中近景、大特写中选择一个；无法判断时写空字符串",
  "composition": "构图和主体位置，例如主体居中、左侧留白、右侧前景遮挡、俯视/仰视",
  "subject_direction": "人物或主体朝向，例如面向右侧、背对镜头、正面看向镜头、无人物/不适用",
  "gaze_direction": "视线方向和看向目标，例如看向画面左侧、看向门口、看向画外、不明显",
  "action_stage": "动作进度阶段，例如建立、准备、进行、反应、结果、收束、静态",
  "spatial_relation": "主体与场景/道具/他人的空间关系，例如从门外进入室内、靠近桌面、站在马匹左侧",
  "chronology_cue": "时间或叙事进度线索，例如开场建立、动作前、动作中、动作后、反应镜头、结尾收束、不明显",
  "camera_angle": "机位、角度或镜头感，例如眼平中景、低角度仰拍、俯视、侧面观察、过肩、产品三分之二角度",
  "visual_focus": "观众第一眼会注意到的主体、表情、动作、道具、Logo、材质或信息点",
  "lighting_mood": "光线来源、明暗关系和情绪，例如柔和窗光、硬侧光、高调商业光、低调悬疑光、暖色余晖",
  "color_palette": "主要色彩和风格倾向，例如冷蓝灰、暖金色、黑白高反差、清爽白绿、品牌主色",
  "narrative_function": "镜头叙事功能，例如建立、推进、揭示、证明、反应、转折、结果、收束、广告产品记忆点、静态展示",
  "transition_hint": "剪辑承接建议，例如适合开场、承接上一动作、作为中段插入细节、接反应镜头、回到结果、适合收尾"
}
''';
  }

  String _imageRetryPrompt(int sequenceNo, int rowIndex, int columnIndex) {
    return '''
上一次解析第 $sequenceNo 张图片时，模型响应无法通过标准 JSON 校验。
请重新观察图片并完整分析，不要复用上一次的错误格式。
特别注意：JSON 字符串内部禁止出现未转义英文双引号；画面文字统一使用中文引号“”。

${_imagePrompt(sequenceNo, rowIndex, columnIndex)}
''';
  }

  String _imageJsonRepairPrompt({
    required int sequenceNo,
    required String rawResponse,
    required String parseError,
  }) {
    return '''
请修复第 $sequenceNo 张图片视觉解析结果的 JSON 结构。
只修复语法、引号转义和字段类型，不改变原有视觉事实，不添加新剧情。
只返回一个可被标准 JSON 解析器直接解析的对象，不要使用 Markdown，不要解释。
所有字段值必须是字符串；数组请用中文顿号连接为字符串；画面文字使用中文引号“”。
必须保留 caption 和 detail 两个关键字段。

解析错误：
$parseError

待修复原始响应：
$rawResponse
''';
  }

  String _simplifiedImagePrompt(int sequenceNo, int rowIndex, int columnIndex) {
    return '''
请对第 $sequenceNo 张故事板图片执行稳定的精简视觉解析，它位于第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列。
只根据画面可见内容描述，不编造剧情。成年女性称为“女模特”，成年男性称为“男模特”。
只返回一个可被标准 JSON 解析器直接解析的对象，不要使用 Markdown，不要解释。
所有字段值必须是字符串，画面文字使用中文引号“”，禁止使用未转义英文双引号。
JSON 字段：
{
  "caption": "45字以内的专业故事板画面句",
  "detail": "主体、动作、环境、构图、光线和情绪的具体描述",
  "scene": "场景与环境",
  "props": "关键道具与视觉元素",
  "people": "人物与可见动作",
  "body_action": "身体姿态和动作",
  "movement_trend": "可见运动方向或静止不明显",
  "shot_size": "景别",
  "composition": "构图与主体位置",
  "visual_focus": "第一视觉焦点",
  "narrative_function": "建立、推进、揭示、反应、结果、收束或静态展示",
  "transition_hint": "与前后镜头的剪辑承接建议"
}
''';
  }

  String _joinedRecoveryResponses(List<String> responses) {
    return [
      for (var i = 0; i < responses.length; i++)
        '[响应 ${i + 1}]\n${responses[i]}',
    ].join('\n\n');
  }

  String _summaryPrompt(List<VisionImageAnalysis> analyses) {
    final buffer = StringBuffer()
      ..writeln('请根据以下逐图视觉解析结果，归纳整个故事板。')
      ..writeln('只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。')
      ..writeln('字段值必须写具体内容，不要照抄字段说明或输出“故事板大纲”“故事板内容概述”等占位词。')
      ..writeln('称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。')
      ..writeln(
        '请按镜头顺序归纳主角、视觉焦点、镜头功能、景别推进、人物朝向、视线方向、动作阶段、运动趋势、场景变化、光色氛围、视觉风格和关键道具。',
      )
      ..writeln('整体描述必须像一个连续画面段落，不要逐条罗列，不要把逐图短句用分号直接拼接。')
      ..writeln('JSON 字段：')
      ..writeln('{')
      ..writeln('  "outline": "一句具体故事线，60字以内，体现主角和视觉推进",')
      ..writeln('  "content": "一段完整中文概述，说明故事板讲了什么，包含连续的场景、神态、动作、运动趋势和情绪",')
      ..writeln('  "scenes": "用顿号分隔的具体场景/地点",')
      ..writeln('  "props": "用顿号分隔的关键道具和视觉元素"')
      ..writeln('}')
      ..writeln()
      ..writeln('逐图内容：');
    for (var i = 0; i < analyses.length; i++) {
      final item = analyses[i];
      buffer
        ..writeln('${i + 1}. ${item.caption}')
        ..writeln('详细：${item.detail}')
        ..writeln('场景：${item.scene}')
        ..writeln('道具：${item.props}')
        ..writeln('人物动作：${item.people}')
        ..writeln('神态情绪：${item.expression}')
        ..writeln('姿态动作：${item.bodyAction}')
        ..writeln('运动趋势：${item.movementTrend}')
        ..writeln('景别：${item.shotSize}')
        ..writeln('构图：${item.composition}')
        ..writeln('主体朝向：${item.subjectDirection}')
        ..writeln('视线方向：${item.gazeDirection}')
        ..writeln('动作阶段：${item.actionStage}')
        ..writeln('空间关系：${item.spatialRelation}')
        ..writeln('进度线索：${item.chronologyCue}')
        ..writeln('机位角度：${item.cameraAngle}')
        ..writeln('视觉焦点：${item.visualFocus}')
        ..writeln('光线情绪：${item.lightingMood}')
        ..writeln('色彩调性：${item.colorPalette}')
        ..writeln('叙事功能：${item.narrativeFunction}')
        ..writeln('剪辑承接：${item.transitionHint}')
        ..writeln();
    }
    return buffer.toString();
  }

  String _videoDimensionPrompt(
    List<VisionImageAnalysis> analyses,
    Map<String, String> summary,
  ) {
    final buffer = StringBuffer()
      ..writeln('你是一名资深短视频广告策略师、剪辑导演和转化分析师。')
      ..writeln('请基于下面可见的逐镜头事实，完成整条参考视频的多维度专业拆解。')
      ..writeln(
        '商业规则参考：Google ABCD（Attention、Branding、Connection、Direction），以及 TikTok Creative Codes 的 Hook-Body-Close、刺激留存、声音和明确 CTA。',
      )
      ..writeln('只返回一个扁平 JSON 对象，不要 Markdown，不要解释，不要新增字段。')
      ..writeln('不得编造画面中不存在的产品、品牌、价格、福利、证明、评论或 CTA；无法确认时明确写“未在可见画面中确认”。')
      ..writeln(
        '每个字段尽量写“可见证据 → 商业作用 → 缺口/优化建议”，至少一个完整句子；不要只写“吸引用户、节奏较快、画面高级”等空泛结论。',
      )
      ..writeln(
        'ABCD 字段必须分别判断注意力、品牌识别、人与内容的情感连接、行动指引是否成立；Hook-Body-Close 必须标出三段内容和断点。',
      )
      ..writeln('如果某项只依赖音频、字幕、落地页或视频比例而当前输入没有事实，必须明确标记未确认，不要用行业常识代替证据。')
      ..writeln('JSON 必须包含以下全部字段，键名必须完全一致：')
      ..writeln(videoAnalysisDimensionFields.join('、'))
      ..writeln('JSON 示例结构（每个值都要换成真实分析）：');
    buffer.writeln('{');
    for (var index = 0; index < videoAnalysisDimensionFields.length; index++) {
      final field = videoAnalysisDimensionFields[index];
      final comma = index == videoAnalysisDimensionFields.length - 1 ? '' : ',';
      buffer.writeln('  "$field": "证据；商业作用；缺口或优化建议"$comma');
    }
    buffer
      ..writeln('}')
      ..writeln('视频级已有摘要：')
      ..writeln('大纲：${summary['outline'] ?? ''}')
      ..writeln('内容：${summary['content'] ?? ''}')
      ..writeln('逐镜头事实：');
    for (var index = 0; index < analyses.length; index++) {
      final item = analyses[index];
      buffer
        ..writeln('镜头 ${index + 1}：${item.caption}')
        ..writeln('场景/人物/动作：${item.scene}；${item.people}；${item.bodyAction}')
        ..writeln('道具/产品：${item.props}')
        ..writeln(
          '景别/运镜/构图：${item.shotSize}；${item.cameraMovement}；${item.composition}',
        )
        ..writeln(
          '焦点/光色/功能：${item.visualFocus}；${item.lightingMood}；${item.colorPalette}；${item.narrativeFunction}',
        );
    }
    return buffer.toString();
  }

  String _orderPrompt(List<VisionImageAnalysis> analyses) {
    final buffer = StringBuffer()
      ..writeln('请根据以下逐图视觉解析结果，判断故事板镜头最自然、最连贯的观看顺序。')
      ..writeln('只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。')
      ..writeln('必须返回 order 数组，数组内容是原始图片编号，使用 1 到 ${analyses.length} 的整数。')
      ..writeln('order 必须包含每一张图片且只能出现一次，不能新增、删除或重复编号。')
      ..writeln('请像专业分镜师一样校正当前顺序，优先依据可见信息，不要按文件名机械排序。')
      ..writeln('称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。')
      ..writeln(
        '导演式判断：优先使用逐图的叙事功能、视觉焦点和剪辑承接来标注每张图的镜头功能，例如建立、推进、揭示、证明、反应、转折、结果、收束或广告产品记忆点；最终只返回 order。',
      )
      ..writeln('每张图都要回答“它让画面状态改变了什么”：从初始状态，到可见动作或信息揭示，再到改变后的状态。')
      ..writeln(
        '当前 1 到 ${analyses.length} 的顺序已经是一个候选故事板；你的任务是校正明显错位，而不是从零重新编排。',
      )
      ..writeln('保守模式：默认输出原顺序 [1, 2, ...]；只有发现明确错位时，才返回不同顺序。')
      ..writeln('如果图片更像同一人物、产品或场景的写真/展示图，而不是连续动作故事板，必须保持原顺序。')
      ..writeln('重排序不是重新编故事：只有在画面里有明确动作因果、空间连续、视线承接或收束线索时才移动图片。')
      ..writeln('采用最小改动原则：证据不足时保留原相对顺序；如果当前顺序已经合理，直接返回 [1, 2, ...]。')
      ..writeln('不要为了满足景别变化、情绪起伏或抽象主题而跨段搬动图片；避免把照片组重新编成不存在的剧情。')
      ..writeln('排序规则按优先级执行：')
      ..writeln('1. 先找建立镜头：远景/全景/空镜、场景交代、主体尚未动作的画面通常靠前。')
      ..writeln(
        '2. 再按动作阶段推进：准备 -> 进行 -> 反应/转折 -> 结果 -> 收束；起身、转身、靠近、接触、离开要形成因果。',
      )
      ..writeln('3. 保持人物朝向、视线方向和运动方向的连续性：看向某物通常在目标或反应镜头前后形成关系。')
      ..writeln('4. 保持空间关系连续：同一场景、相邻位置、靠近/远离关系优先连在一起，场景切换需要有转场或结果线索。')
      ..writeln('5. 使用景别推进辅助判断，但景别不是时间线：特写/大特写可作为中段细节、材质证明、情绪反应或信息揭示，不天然等于结尾。')
      ..writeln('6. 使用情绪和道具线索补充判断：情绪从平静到紧张再到缓和，道具从出现、被注意、被使用到产生结果。')
      ..writeln('7. 使用机位、光色和视觉焦点判断节奏：同一功能的镜头不要堆在一起，插入细节后要回到人物动作、产品结果或关系变化。')
      ..writeln('8. 对同一人物、同一风格但缺少明确剧情因果的照片组，应优先维持局部连续，不要跨场景来回穿插。')
      ..writeln(
        '9. 选择最后一张前先判断完成端点：剧情结尾应落在可见结果、关系变化、离开、停顿、回望或余韵；仍在进行中的行走/动作通常不应作为最终镜头。',
      )
      ..writeln(
        '10. 如果是产品、品牌或广告画面，结尾优先选择使用结果、利益被证明、产品三分之二英雄角度、包装/Logo清晰或明确 end-card/packshot，而不是默认脸部或局部特写。',
      )
      ..writeln(
        '11. 如果最后候选是特写，但它只是细节插入、反应、动作中或信息铺垫，应把它放在对应动作/结果之前；只有承担结果、记忆点或余韵时才适合收尾。',
      )
      ..writeln('如果规则冲突，优先可见动作因果，其次空间连续，其次完成端点，其次景别推进；仍无法判断时才返回原顺序。')
      ..writeln('JSON 字段：')
      ..writeln('{')
      ..writeln('  "order": [1, 2, 3]')
      ..writeln('}')
      ..writeln()
      ..writeln('逐图内容：');
    for (var i = 0; i < analyses.length; i++) {
      final item = analyses[i];
      buffer
        ..writeln('${i + 1}. caption：${item.caption}')
        ..writeln('详细：${item.detail}')
        ..writeln('场景：${item.scene}')
        ..writeln('道具：${item.props}')
        ..writeln('人物动作：${item.people}')
        ..writeln('神态情绪：${item.expression}')
        ..writeln('姿态动作：${item.bodyAction}')
        ..writeln('运动趋势：${item.movementTrend}')
        ..writeln('景别：${item.shotSize}')
        ..writeln('构图：${item.composition}')
        ..writeln('主体朝向：${item.subjectDirection}')
        ..writeln('视线方向：${item.gazeDirection}')
        ..writeln('动作阶段：${item.actionStage}')
        ..writeln('空间关系：${item.spatialRelation}')
        ..writeln('进度线索：${item.chronologyCue}')
        ..writeln('机位角度：${item.cameraAngle}')
        ..writeln('视觉焦点：${item.visualFocus}')
        ..writeln('光线情绪：${item.lightingMood}')
        ..writeln('色彩调性：${item.colorPalette}')
        ..writeln('叙事功能：${item.narrativeFunction}')
        ..writeln('剪辑承接：${item.transitionHint}')
        ..writeln();
    }
    return buffer.toString();
  }

  String _imageEditSuggestionPrompt({
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String currentCaption,
    required String previousCaption,
    required String nextCaption,
    required String rowCaption,
    required String storyboardSummary,
    required VisionImageAnalysis currentAnalysis,
    required VisionImageAnalysis? previousAnalysis,
    required VisionImageAnalysis? nextAnalysis,
    required List<VisionImageAnalysis> storyboardAnalyses,
  }) {
    return '''
你是一名专业分镜导演和 AI 图片修改提示词设计师。
请结合当前图片、前后镜头、全局故事板摘要和逐图多维度视觉解析，判断这张分镜最值得优化的地方，并给出可直接用于图生图/图片修改模型的中文提示词。

上下文：
- 当前图片序号：第 $sequenceNo 张
- 当前宫格位置：第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列
- 当前格文字：${_emptyAsNone(currentCaption)}
- 前一格文字：${_emptyAsNone(previousCaption)}
- 后一格文字：${_emptyAsNone(nextCaption)}
- 当前行描述：${_emptyAsNone(rowCaption)}
- 故事板概述：${_emptyAsNone(storyboardSummary)}

当前分镜多维解析：
${_imageEditAnalysisBlock(currentAnalysis)}

前一分镜多维解析：
${_nullableImageEditAnalysisBlock(previousAnalysis)}

后一分镜多维解析：
${_nullableImageEditAnalysisBlock(nextAnalysis)}

全局逐图解析：
${_storyboardAnalysisList(storyboardAnalyses)}

综合设计要求：
1. 先从全局故事顺序判断当前分镜承担的叙事功能：建立、推进、反应、转折、结果或收束。
2. 再结合当前图片可见内容，选择一个最值得优化的方向，不要同时提出互相冲突的改动。
3. 镜头角度、景别、构图、人物朝向、视线方向、神态、姿态、动作阶段、运动趋势、空间关系、道具、服装、场景和光线必须与前后镜头连续。
4. 提示词必须明确保留原图主体、身份、核心场景、构图关系和故事连续性，只强化必要的画面信息。
5. 不要编造图片里没有依据的新角色、新剧情或大幅改变场景；不要输出无关参数。
6. 称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。

只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。
JSON 字段：
{
  "advice": "给用户看的中文修改建议，说明应该优化哪些点，100字以内",
  "prompt": "给图片生成 API 的中文修改提示词，120到260字；必须明确保留原图主体、角色身份、场景和整体连续性，并说明具体要修改或强化的镜头角度、人物状态、道具、服装、光线、构图或动作承接；不要写无关参数"
}
''';
  }

  String _nullableImageEditAnalysisBlock(VisionImageAnalysis? analysis) {
    if (analysis == null) {
      return '无';
    }
    return _imageEditAnalysisBlock(analysis);
  }

  String _imageEditAnalysisBlock(VisionImageAnalysis analysis) {
    return [
      '画面短句：${_emptyAsNone(analysis.caption)}',
      '详细描述：${_emptyAsNone(analysis.detail)}',
      '场景：${_emptyAsNone(analysis.scene)}',
      '道具：${_emptyAsNone(analysis.props)}',
      '人物动作：${_emptyAsNone(analysis.people)}',
      '神态情绪：${_emptyAsNone(analysis.expression)}',
      '姿态动作：${_emptyAsNone(analysis.bodyAction)}',
      '运动趋势：${_emptyAsNone(analysis.movementTrend)}',
      '景别：${_emptyAsNone(analysis.shotSize)}',
      '构图：${_emptyAsNone(analysis.composition)}',
      '主体朝向：${_emptyAsNone(analysis.subjectDirection)}',
      '视线方向：${_emptyAsNone(analysis.gazeDirection)}',
      '动作阶段：${_emptyAsNone(analysis.actionStage)}',
      '空间关系：${_emptyAsNone(analysis.spatialRelation)}',
      '进度线索：${_emptyAsNone(analysis.chronologyCue)}',
      '机位角度：${_emptyAsNone(analysis.cameraAngle)}',
      '视觉焦点：${_emptyAsNone(analysis.visualFocus)}',
      '光线情绪：${_emptyAsNone(analysis.lightingMood)}',
      '色彩调性：${_emptyAsNone(analysis.colorPalette)}',
      '叙事功能：${_emptyAsNone(analysis.narrativeFunction)}',
      '剪辑承接：${_emptyAsNone(analysis.transitionHint)}',
    ].join('\n');
  }

  String _storyboardAnalysisList(List<VisionImageAnalysis> analyses) {
    if (analyses.isEmpty) {
      return '无';
    }
    final buffer = StringBuffer();
    for (var i = 0; i < analyses.length; i++) {
      buffer
        ..writeln('${i + 1}. ${_emptyAsNone(analyses[i].caption)}')
        ..writeln('   详细：${_emptyAsNone(analyses[i].detail)}')
        ..writeln(
          '   场景/道具：${_emptyAsNone(analyses[i].scene)}；${_emptyAsNone(analyses[i].props)}',
        )
        ..writeln(
          '   人物/神态/动作：${_emptyAsNone(analyses[i].people)}；${_emptyAsNone(analyses[i].expression)}；${_emptyAsNone(analyses[i].bodyAction)}',
        )
        ..writeln(
          '   镜头/构图/方向：${_emptyAsNone(analyses[i].shotSize)}；${_emptyAsNone(analyses[i].composition)}；${_emptyAsNone(analyses[i].subjectDirection)}；${_emptyAsNone(analyses[i].gazeDirection)}',
        )
        ..writeln(
          '   连续性：${_emptyAsNone(analyses[i].movementTrend)}；${_emptyAsNone(analyses[i].actionStage)}；${_emptyAsNone(analyses[i].spatialRelation)}；${_emptyAsNone(analyses[i].chronologyCue)}',
        )
        ..writeln(
          '   导演/光色/剪辑：${_emptyAsNone(analyses[i].cameraAngle)}；${_emptyAsNone(analyses[i].visualFocus)}；${_emptyAsNone(analyses[i].lightingMood)}；${_emptyAsNone(analyses[i].colorPalette)}；${_emptyAsNone(analyses[i].narrativeFunction)}；${_emptyAsNone(analyses[i].transitionHint)}',
        );
    }
    return buffer.toString().trimRight();
  }

  String _emptyAsNone(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '无' : normalizeVisionModelRoleTerms(trimmed);
  }

  Map<String, dynamic> _extractJsonObject(String text) {
    final trimmed = text.trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // 继续尝试从模型解释文本中提取 JSON 对象。
    }
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('视觉模型未返回可解析的 JSON');
    }
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const FormatException('视觉模型 JSON 格式异常');
  }

  String _stringValue(Map<String, dynamic> json, String key) {
    return _coerceTextValue(json[key]);
  }

  String _coerceTextValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is List) {
      return value
          .map(_coerceTextValue)
          .where((item) => item.isNotEmpty)
          .join('、')
          .trim();
    }
    if (value is Map) {
      for (final key in const ['text', 'caption', 'name', 'value']) {
        final preferred = _coerceTextValue(value[key]);
        if (preferred.isNotEmpty) {
          return preferred;
        }
      }
      return value.values
          .map(_coerceTextValue)
          .where((item) => item.isNotEmpty)
          .join('、')
          .trim();
    }
    return normalizeVisionModelRoleTerms(value.toString().trim());
  }

  String _firstStringValue(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = _stringValue(json, key);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  List<int> _orderListValue(Map<String, dynamic> json, int expectedCount) {
    final value = _findOrderValue(json);
    final items = switch (value) {
      List list => list,
      String text => _numbersFromText(text),
      _ => null,
    };
    if (items == null) {
      throw const FormatException('视觉模型未返回 order 数组');
    }
    final order = <int>[];
    for (final item in items) {
      final number = _orderNumberFromItem(item);
      if (number == null) {
        throw const FormatException('视觉模型 order 包含非数字编号');
      }
      order.add(number);
    }
    final normalizedOrder = _normalizeOrderNumbers(order, expectedCount);
    final repairedOrder = _repairMissingOrderNumbers(
      normalizedOrder,
      expectedCount,
    );
    final unique = repairedOrder.toSet();
    final validRange = normalizedOrder.every(
      (number) => number >= 1 && number <= expectedCount,
    );
    if (repairedOrder.length != expectedCount ||
        unique.length != expectedCount ||
        !validRange) {
      final invalidNumbers = normalizedOrder
          .where((number) => number < 1 || number > expectedCount)
          .toList();
      throw FormatException(
        '视觉模型 order 数量异常：期望 $expectedCount，实际 ${normalizedOrder.length}'
        '，唯一 ${unique.length}'
        '${invalidNumbers.isEmpty ? '' : '，无效编号 ${invalidNumbers.join(', ')}'}'
        '，解析值 ${normalizedOrder.join(', ')}',
      );
    }
    return repairedOrder;
  }

  Object? _findOrderValue(Object? value) {
    if (value is List) {
      return value;
    }
    if (value is! Map) {
      return null;
    }
    const keys = [
      'order',
      'orders',
      'sorted_order',
      'sortedOrder',
      'sequence',
      'indices',
      '排序',
    ];
    for (final key in keys) {
      if (value.containsKey(key)) {
        return value[key];
      }
    }
    const nestedKeys = ['result', 'data', 'output', 'answer', 'content'];
    for (final key in nestedKeys) {
      final nested = _findOrderValue(value[key]);
      if (nested != null) {
        return nested;
      }
    }
    if (value.length == 1) {
      return _findOrderValue(value.values.single);
    }
    return null;
  }

  int? _orderNumberFromItem(Object? item) {
    if (item is num) {
      return item.toInt();
    }
    if (item is String) {
      return _numberFromText(item);
    }
    if (item is Map) {
      const keys = [
        'index',
        'id',
        'order',
        'number',
        'no',
        'image',
        'image_no',
        'imageNo',
        'original',
        'original_index',
        'originalIndex',
      ];
      for (final key in keys) {
        final number = _orderNumberFromItem(item[key]);
        if (number != null) {
          return number;
        }
      }
      if (item.length == 1) {
        return _orderNumberFromItem(item.values.single);
      }
    }
    return null;
  }

  List<int> _normalizeOrderNumbers(List<int> order, int expectedCount) {
    final unique = order.toSet();
    final zeroBased =
        order.length == expectedCount &&
        unique.length == expectedCount &&
        order.every((number) => number >= 0 && number < expectedCount);
    if (zeroBased) {
      return [for (final number in order) number + 1];
    }
    final incompleteZeroBased =
        order.isNotEmpty &&
        order.length < expectedCount &&
        unique.length == order.length &&
        order.contains(0) &&
        !order.contains(expectedCount) &&
        order.every((number) => number >= 0 && number < expectedCount);
    if (incompleteZeroBased) {
      return [for (final number in order) number + 1];
    }
    return order;
  }

  List<int> _repairMissingOrderNumbers(List<int> order, int expectedCount) {
    final unique = order.toSet();
    final validRange = order.every(
      (number) => number >= 1 && number <= expectedCount,
    );
    if (order.length == expectedCount ||
        unique.length != order.length ||
        !validRange) {
      return order;
    }

    final missing = [
      for (var number = 1; number <= expectedCount; number++)
        if (!unique.contains(number)) number,
    ];
    if (missing.length > _maxMissingOrderRepairCount) {
      return order;
    }

    final repaired = [...order];
    for (final number in missing) {
      var inserted = false;
      for (var before = number - 1; before >= 1; before--) {
        final index = repaired.indexOf(before);
        if (index != -1) {
          repaired.insert(index + 1, number);
          inserted = true;
          break;
        }
      }
      if (inserted) {
        continue;
      }
      for (var after = number + 1; after <= expectedCount; after++) {
        final index = repaired.indexOf(after);
        if (index != -1) {
          repaired.insert(index, number);
          inserted = true;
          break;
        }
      }
      if (!inserted) {
        repaired.add(number);
      }
    }
    return repaired;
  }

  List<int> _numbersFromText(String text) {
    return [
      for (final match in RegExp(r'-?\d+').allMatches(text))
        int.parse(match.group(0)!),
    ];
  }

  int? _numberFromText(String text) {
    final trimmed = text.trim();
    final parsed = int.tryParse(trimmed);
    if (parsed != null) {
      return parsed;
    }
    final match = RegExp(r'-?\d+').firstMatch(trimmed);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(0)!);
  }

  String _compactForError(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 600) {
      return compact;
    }
    return '${compact.substring(0, 600)}...';
  }

  String _summaryValue(
    Map<String, dynamic> json,
    String key, {
    required String fallback,
    required Set<String> placeholders,
  }) {
    final value = _stringValue(json, key);
    if (value.isEmpty || _isPlaceholder(value, placeholders)) {
      return fallback;
    }
    return value;
  }

  bool _isPlaceholder(String value, Set<String> placeholders) {
    final normalized = _normalizeSummaryText(value);
    return placeholders
        .map(_normalizeSummaryText)
        .any((placeholder) => normalized == placeholder);
  }

  String _normalizeSummaryText(String value) {
    return value.replaceAll(RegExp(r'[\s:：,，.。;；、]'), '').trim();
  }

  String _fallbackOutline(List<VisionImageAnalysis> analyses) {
    return composeVisionAnalysesOutline(analyses);
  }

  String _fallbackContent(List<VisionImageAnalysis> analyses) {
    return composeVisionAnalysesDescription(analyses);
  }

  String _fallbackJoinedValues(Iterable<String> values) {
    return _uniqueNonEmptyTexts(values).join('、');
  }

  String _mimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/png';
  }
}

String composeVisionAnalysesOutline(List<VisionImageAnalysis> analyses) {
  final captions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.caption),
  ).map(_trimSentenceEnd).take(3).toList();
  if (captions.isEmpty) {
    return '';
  }
  if (captions.length == 1) {
    return _ensureChineseSentence(captions.single);
  }
  return '镜头围绕${_joinSequence(captions)}展开，形成一段连续故事。';
}

String composeVisionAnalysesDescription(List<VisionImageAnalysis> analyses) {
  final captions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.caption),
  ).map(_trimSentenceEnd).toList();
  if (captions.isEmpty) {
    return '';
  }
  final cueText = _analysisCueText(analyses);
  if (captions.length == 1) {
    return _ensureChineseSentence('${captions.single}$cueText');
  }

  final scenes = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.scene),
  ).map(_trimSentenceEnd).take(3).toList();
  final scenePrefix = scenes.isEmpty
      ? ''
      : scenes.length == 1
      ? '在${scenes.single}中，'
      : '在${_joinNames(scenes)}之间，';
  return '$scenePrefix镜头依次呈现${_joinSequence(captions)}$cueText，人物动作、视线、神态与运动趋势被连成一段完整画面。';
}

String _analysisCueText(List<VisionImageAnalysis> analyses) {
  final expressions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.expression),
  ).map(_trimSentenceEnd).take(3).toList();
  final actions = _uniqueNonEmptyTexts(
    analyses.map(
      (analysis) => analysis.bodyAction.trim().isNotEmpty
          ? analysis.bodyAction
          : analysis.people,
    ),
  ).map(_trimSentenceEnd).take(3).toList();
  final movements = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.movementTrend),
  ).map(_trimSentenceEnd).take(3).toList();
  final focuses = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.visualFocus),
  ).map(_trimSentenceEnd).take(3).toList();
  final moods = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.lightingMood),
  ).map(_trimSentenceEnd).take(2).toList();
  final functions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.narrativeFunction),
  ).map(_trimSentenceEnd).take(3).toList();

  final cues = <String>[
    if (expressions.isNotEmpty) '神态聚焦${_joinNames(expressions)}',
    if (actions.isNotEmpty) '姿态动作包括${_joinSequence(actions)}',
    if (movements.isNotEmpty) '运动趋势表现为${_joinNames(movements)}',
    if (focuses.isNotEmpty) '视觉焦点落在${_joinNames(focuses)}',
    if (moods.isNotEmpty) '光线情绪呈现${_joinNames(moods)}',
    if (functions.isNotEmpty) '镜头功能形成${_joinSequence(functions)}',
  ];
  if (cues.isEmpty) {
    return '';
  }
  return '，${cues.join('，')}';
}

Iterable<String> _uniqueNonEmptyTexts(Iterable<String> values) sync* {
  final seen = <String>{};
  for (final value in values) {
    final trimmed = normalizeVisionModelRoleTerms(value.trim());
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    yield trimmed;
  }
}

String _trimSentenceEnd(String value) {
  return value.replaceAll(RegExp(r'[\s。！？!?；;，,、]+$'), '').trim();
}

String normalizeVisionModelRoleTerms(String value) {
  return value.replaceAll('女子', '女模特').replaceAll('男子', '男模特');
}

String _ensureChineseSentence(String value) {
  final trimmed = _trimSentenceEnd(value);
  return trimmed.isEmpty ? '' : '$trimmed。';
}

String _joinSequence(List<String> values) {
  if (values.length == 1) {
    return values.single;
  }
  if (values.length == 2) {
    return '${values.first}，并过渡到${values.last}';
  }
  return '${values.take(values.length - 1).join('、')}，并过渡到${values.last}';
}

String _joinNames(List<String> values) {
  if (values.length == 1) {
    return values.single;
  }
  if (values.length == 2) {
    return '${values.first}与${values.last}';
  }
  return '${values.take(values.length - 1).join('、')}与${values.last}';
}

Uri normalizeChatCompletionsEndpoint(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('API 地址不能为空');
  }
  final withScheme = _hasScheme(trimmed)
      ? trimmed
      : '${_defaultSchemeFor(trimmed)}://$trimmed';
  final uri = Uri.parse(withScheme);
  final path = _normalizedChatPath(uri.path);
  return uri.replace(path: path, query: null, fragment: null);
}

bool _hasScheme(String value) {
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
}

String _defaultSchemeFor(String value) {
  final host = value.split('/').first.split(':').first.toLowerCase();
  final isIpv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
  if (host == 'localhost' || host == '127.0.0.1' || isIpv4) {
    return 'http';
  }
  return 'https';
}

String _normalizedChatPath(String path) {
  final normalized = path.isEmpty ? '/' : path.replaceAll(RegExp(r'/+$'), '');
  if (normalized.endsWith('/v1/chat/completions') ||
      normalized.endsWith('/chat/completions')) {
    return normalized;
  }
  if (normalized == '/' || normalized.isEmpty) {
    return '/v1/chat/completions';
  }
  if (normalized.endsWith('/v1')) {
    return '$normalized/chat/completions';
  }
  return '$normalized/v1/chat/completions';
}
