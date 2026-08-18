import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../settings/domain/api_endpoint_normalizer.dart';
import '../domain/image_generation_model_catalog.dart';
import 'image_generation_diagnostic_logger.dart';

export '../domain/image_generation_model_catalog.dart';

class ImageGenerationRequest {
  const ImageGenerationRequest({
    required this.provider,
    required this.model,
    required this.prompt,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.referenceImagePaths,
    required this.outputDirectory,
    this.geminiContinuation,
  });

  final ImageGenerationProviderConnection provider;
  final String model;
  final String prompt;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final List<String> referenceImagePaths;
  final Directory outputDirectory;
  final GeminiImageContinuation? geminiContinuation;

  String get apiBaseUrl => provider.apiBaseUrl;
  String get apiKey => provider.apiKey;
}

class ImageGenerationResult {
  const ImageGenerationResult({
    required this.localPath,
    required this.remoteUrl,
    required this.rawResponse,
    this.geminiContinuation,
  });

  final String localPath;
  final String remoteUrl;
  final String rawResponse;
  final GeminiImageContinuation? geminiContinuation;
}

enum GeminiImageContinuationTransport { interactions, generateContent }

class GeminiImageContinuation {
  const GeminiImageContinuation({
    required this.transport,
    required this.apiModel,
    this.previousInteractionId = '',
    this.generateContentHistory = const [],
  });

  final GeminiImageContinuationTransport transport;
  final String apiModel;
  final String previousInteractionId;
  final List<Map<String, Object?>> generateContentHistory;
}

class ImageGenerationModelCatalog {
  static final Map<String, String> labels = {
    for (final model in ImageGenerationCatalog.models) model.id: model.label,
  };

  static final List<String> values = [
    for (final model in ImageGenerationCatalog.models) model.id,
  ];

  static const providerGroups = ImageGenerationCatalog.providers;

  static bool isGeminiModel(String model) {
    return model.trim().toLowerCase().startsWith('gemini-');
  }

  static String providerLabelForModel(String model) {
    return ImageGenerationCatalog.providerLabelFor(model);
  }

  static const defaultAspectRatios = ImageGenerationCatalog.defaultAspectRatios;

  static const defaultImageSizes = ImageGenerationCatalog.defaultResolutions;

  static String labelFor(String model) {
    return ImageGenerationCatalog.labelFor(model);
  }

  static ImageGenerationModelDescriptor? descriptorFor(String model) {
    return ImageGenerationCatalog.descriptorFor(model);
  }

  static List<String> resolutionsFor(String model, String aspectRatio) {
    return ImageGenerationCatalog.resolutionsFor(model, aspectRatio);
  }

  static bool isApiMartModel(String model) {
    return ImageGenerationCatalog.isApiMartModel(model);
  }
}

class GptImageGenerationPreset {
  static const standardModel = 'gpt-image-2';
  static const vipModel = 'gpt-image-2-vip';

  static const aspectRatios = [
    'auto',
    '1:1',
    '3:2',
    '2:3',
    '16:9',
    '9:16',
    '5:4',
    '4:5',
    '4:3',
    '3:4',
    '21:9',
    '9:21',
    '1:3',
    '3:1',
    '2:1',
    '1:2',
  ];

  static const legacyImageSizes = ['1K', '2K', '4K'];
  static const qualityOptions = ['auto', 'low', 'medium', 'high'];
  static const qualityLabels = {
    'auto': '自动',
    'low': '低',
    'medium': '中',
    'high': '高',
  };

  static const Map<String, List<String>> _vipResolutionsByAspectRatio = {
    'auto': [
      'auto',
      '1024x1024',
      '1536x1024',
      '1024x1536',
      '2048x2048',
      '2048x1152',
      '1152x2048',
      '3840x2160',
      '2160x3840',
      '1536x1152',
      '1152x1536',
      '2688x1152',
      '1152x2688',
      '2496x832',
      '832x2496',
      '2048x1024',
      '1024x2048',
      '1280x1024',
      '1024x1280',
    ],
    '1:1': ['auto', '1024x1024', '2048x2048', '2880x2880'],
    '3:2': ['auto', '1536x1024', '3072x2048'],
    '2:3': ['auto', '1024x1536', '2048x3072'],
    '16:9': ['auto', '2048x1152', '3840x2160'],
    '9:16': ['auto', '1152x2048', '2160x3840'],
    '5:4': ['auto', '1280x1024', '2560x2048'],
    '4:5': ['auto', '1024x1280', '2048x2560'],
    '4:3': ['auto', '1536x1152', '3072x2304'],
    '3:4': ['auto', '1152x1536', '2304x3072'],
    '21:9': ['auto', '2688x1152', '3360x1440'],
    '9:21': ['auto', '1152x2688', '1440x3360'],
    '1:3': ['auto', '832x2496', '1248x3744'],
    '3:1': ['auto', '2496x832', '3744x1248'],
    '2:1': ['auto', '2048x1024', '3072x1536'],
    '1:2': ['auto', '1024x2048', '1536x3072'],
  };

  static bool isModel(String model) {
    final trimmed = model.trim();
    return trimmed == standardModel || trimmed == vipModel;
  }

  static bool isVipModel(String model) {
    return model.trim() == vipModel;
  }

  static List<String> getAspectRatioOptions(String model) {
    return isModel(model) ? aspectRatios : const [];
  }

  static List<String> getImageSizeOptions(String model, String aspectRatio) {
    if (!isVipModel(model)) {
      return legacyImageSizes;
    }
    return _vipResolutionsByAspectRatio[normalizeAspectRatio(aspectRatio)] ??
        _vipResolutionsByAspectRatio['auto']!;
  }

  static Map<String, String> getResolutionLabels(
    String model,
    String aspectRatio,
  ) {
    final items = getImageSizeOptions(model, aspectRatio);
    return {for (final item in items) item: resolutionLabel(item)};
  }

  static bool supportsQuality(String model) {
    return isModel(model);
  }

  static bool usesResolutionDropdown(String model) {
    return isVipModel(model);
  }

  static String normalizeAspectRatio(String value) {
    final trimmed = value.trim();
    return aspectRatios.contains(trimmed) ? trimmed : 'auto';
  }

  static String normalizeImageSize({
    required String model,
    required String aspectRatio,
    required String value,
  }) {
    final trimmed = value.trim();
    if (isVipModel(model)) {
      final options = getImageSizeOptions(model, aspectRatio);
      if (options.contains(trimmed)) {
        return trimmed;
      }
      final legacy = trimmed.toUpperCase();
      if (legacyImageSizes.contains(legacy)) {
        return _mapLegacySizeToVipResolution(aspectRatio, legacy);
      }
      return options.first;
    }
    final normalized = trimmed.toUpperCase();
    return legacyImageSizes.contains(normalized)
        ? normalized
        : legacyImageSizes.first;
  }

  static String normalizeQuality(String value) {
    final normalized = value.trim().toLowerCase();
    return qualityOptions.contains(normalized) ? normalized : 'auto';
  }

  static String resolveOpenAiSize({
    required String model,
    required String aspectRatio,
    required String imageSize,
  }) {
    final normalizedRatio = normalizeAspectRatio(aspectRatio);
    final normalizedSize = normalizeImageSize(
      model: model,
      aspectRatio: normalizedRatio,
      value: imageSize,
    );
    if (isVipModel(model)) {
      if (normalizedSize != 'auto') {
        return normalizedSize;
      }
      if (normalizedRatio == 'auto') {
        return 'auto';
      }
      return _preferredVipResolution(normalizedRatio) ?? 'auto';
    }
    if (normalizedRatio == 'auto') {
      return 'auto';
    }
    return _legacyResolution(normalizedRatio, normalizedSize);
  }

  static String resolutionLabel(String value) {
    if (value == 'auto') {
      return '自动';
    }
    return value;
  }

  static String _mapLegacySizeToVipResolution(
    String aspectRatio,
    String legacySize,
  ) {
    final options = getImageSizeOptions(
      vipModel,
      aspectRatio,
    ).where((item) => item != 'auto').toList();
    if (options.isEmpty) {
      return 'auto';
    }
    if (legacySize == '4K') {
      return options.last;
    }
    if (legacySize == '2K') {
      return options.length >= 2 ? options[1] : options.last;
    }
    return options.first;
  }

  static String? _preferredVipResolution(String aspectRatio) {
    final items = _vipResolutionsByAspectRatio[aspectRatio];
    if (items == null) {
      return null;
    }
    for (final item in items) {
      if (item != 'auto') {
        return item;
      }
    }
    return null;
  }

  static String _legacyResolution(String aspectRatio, String imageSize) {
    final size = imageSize.toUpperCase();
    final ratio = aspectRatio.toLowerCase();
    if (ratio == '16:9') {
      return size == '4K'
          ? '3840x2160'
          : size == '2K'
          ? '2048x1152'
          : '1536x864';
    }
    if (ratio == '9:16') {
      return size == '4K'
          ? '2160x3840'
          : size == '2K'
          ? '1152x2048'
          : '864x1536';
    }
    if (ratio == '4:3') {
      return size == '4K'
          ? '3072x2304'
          : size == '2K'
          ? '1536x1152'
          : '1152x864';
    }
    if (ratio == '3:4') {
      return size == '4K'
          ? '2304x3072'
          : size == '2K'
          ? '1152x1536'
          : '864x1152';
    }
    if (ratio == '3:2') {
      return size == '4K'
          ? '3072x2048'
          : size == '2K'
          ? '1536x1024'
          : '1216x832';
    }
    if (ratio == '2:3') {
      return size == '4K'
          ? '2048x3072'
          : size == '2K'
          ? '1024x1536'
          : '832x1216';
    }
    if (ratio == '5:4') {
      return size == '4K'
          ? '2560x2048'
          : size == '2K'
          ? '1920x1536'
          : '1280x1024';
    }
    if (ratio == '4:5') {
      return size == '4K'
          ? '2048x2560'
          : size == '2K'
          ? '1536x1920'
          : '1024x1280';
    }
    if (ratio == '21:9') {
      return size == '4K'
          ? '3360x1440'
          : size == '2K'
          ? '2688x1152'
          : '1344x576';
    }
    if (ratio == '9:21') {
      return size == '4K'
          ? '1440x3360'
          : size == '2K'
          ? '1152x2688'
          : '576x1344';
    }
    if (ratio == '3:1') {
      return size == '4K'
          ? '3744x1248'
          : size == '2K'
          ? '2304x768'
          : '1536x512';
    }
    if (ratio == '1:3') {
      return size == '4K'
          ? '1248x3744'
          : size == '2K'
          ? '768x2304'
          : '512x1536';
    }
    if (ratio == '2:1') {
      return size == '4K'
          ? '3072x1536'
          : size == '2K'
          ? '2048x1024'
          : '1536x768';
    }
    if (ratio == '1:2') {
      return size == '4K'
          ? '1536x3072'
          : size == '2K'
          ? '1024x2048'
          : '768x1536';
    }
    return size == '4K'
        ? '2880x2880'
        : size == '2K'
        ? '2048x2048'
        : '1024x1024';
  }
}

class ImageGenerationService {
  static const nanoBananaOriginalReferenceByteLimit = 20 * 1024 * 1024;

  ImageGenerationService({
    http.Client? client,
    http.Client Function()? apiMartUploadClientFactory,
    http.Client Function()? apiMartUploadFallbackClientFactory,
    ImageGenerationDiagnosticLogger? diagnosticLogger,
    Duration apiMartPollInterval = const Duration(seconds: 1),
    Duration apiMartTimeout = const Duration(minutes: 30),
    Duration apiMartUploadTimeout = const Duration(minutes: 2),
    Duration apiMartUploadRetryDelay = const Duration(seconds: 1),
    int apiMartUploadMaxAttempts = 3,
  }) : _client = client ?? http.Client(),
       _apiMartUploadClientFactory =
           apiMartUploadClientFactory ??
           (client == null ? _createDirectApiMartUploadClient : null),
       _apiMartUploadFallbackClientFactory =
           apiMartUploadFallbackClientFactory ??
           (client == null && _hasEnvironmentProxy()
               ? _createEnvironmentApiMartUploadClient
               : null),
       _diagnosticLogger = diagnosticLogger,
       _apiMartPollInterval = apiMartPollInterval,
       _apiMartTimeout = apiMartTimeout,
       _apiMartUploadTimeout = apiMartUploadTimeout,
       _apiMartUploadRetryDelay = apiMartUploadRetryDelay,
       _apiMartUploadMaxAttempts = apiMartUploadMaxAttempts;

  static const apiMartBaseUrl = 'https://api.apimart.ai';

  final http.Client _client;
  final http.Client Function()? _apiMartUploadClientFactory;
  final http.Client Function()? _apiMartUploadFallbackClientFactory;
  final ImageGenerationDiagnosticLogger? _diagnosticLogger;
  final Duration _apiMartPollInterval;
  final Duration _apiMartTimeout;
  final Duration _apiMartUploadTimeout;
  final Duration _apiMartUploadRetryDelay;
  final int _apiMartUploadMaxAttempts;

  static String apiMartUploadProxyFor(Uri _) => 'DIRECT';

  static http.Client _createDirectApiMartUploadClient() {
    final ioClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = apiMartUploadProxyFor;
    return IOClient(ioClient);
  }

  static bool _hasEnvironmentProxy() {
    const names = [
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ];
    return names.any((name) => (Platform.environment[name] ?? '').isNotEmpty);
  }

  static http.Client _createEnvironmentApiMartUploadClient() {
    final ioClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = HttpClient.findProxyFromEnvironment;
    return IOClient(ioClient);
  }

  Future<ImageGenerationResult> generateTextToImage(
    ImageGenerationRequest request,
  ) {
    return _runWithDiagnostics(request, 'text_to_image', () async {
      _validateBaseRequest(request);
      return _generateImage(request);
    });
  }

  Future<ImageGenerationResult> generateEditedImage(
    ImageGenerationRequest request,
  ) {
    return _runWithDiagnostics(request, 'image_edit', () async {
      _validateBaseRequest(request);
      _validateReferenceImages(request);
      return _generateImage(request);
    });
  }

  Future<ImageGenerationResult> _runWithDiagnostics(
    ImageGenerationRequest request,
    String operation,
    Future<ImageGenerationResult> Function() action,
  ) async {
    final logger = _diagnosticLogger;
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_diagnosticSequence++}';
    final stopwatch = Stopwatch()..start();
    final details = <String, Object?>{
      'request_id': requestId,
      'operation': operation,
      'provider': request.provider.providerId,
      'endpoint': _safeEndpoint(request.apiBaseUrl),
      'model': request.model,
      'aspect_ratio': request.aspectRatio,
      'resolution': request.imageSize,
      'quality': request.quality,
      'reference_count': request.referenceImagePaths.length,
    };
    await logger?.write('started', details);
    try {
      final result = await action();
      await logger?.write('succeeded', {
        ...details,
        'duration_ms': stopwatch.elapsedMilliseconds,
      });
      return result;
    } catch (error) {
      await logger?.write('failed', {
        ...details,
        'duration_ms': stopwatch.elapsedMilliseconds,
        'error_type': error.runtimeType.toString(),
        'error': ImageGenerationDiagnosticLogger.safeError(error),
      });
      rethrow;
    }
  }

  static var _diagnosticSequence = 0;

  String _safeEndpoint(String value) {
    final trimmed = value.trim();
    final candidate = _hasScheme(trimmed) ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      return 'invalid';
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  Future<ImageGenerationResult> _generateImage(
    ImageGenerationRequest request,
  ) async {
    if (!request.outputDirectory.existsSync()) {
      await request.outputDirectory.create(recursive: true);
    }

    final descriptor = ImageGenerationModelCatalog.descriptorFor(request.model);
    if (descriptor?.protocol == ImageGenerationProviderProtocol.gemini) {
      return _generateGeminiImage(request, descriptor!);
    }
    if (descriptor?.isApiMart ?? false) {
      return _generateApiMartImage(request, descriptor!);
    }

    final generateUri = _apiUri(request.apiBaseUrl, '/v1/api/generate');
    final resultUri = _apiUri(request.apiBaseUrl, '/v1/api/result');
    final body = await _buildRequestBody(request);

    var responseData = await _postJson(
      generateUri,
      apiKey: request.apiKey,
      body: body,
    );

    for (var poll = 0; poll < 180; poll++) {
      final status = responseData['status']?.toString() ?? '';
      final urls = _resultUrls(responseData);
      if (status == 'succeeded' && urls.isNotEmpty) {
        final remoteUrl = urls.first;
        final rawResponse = _compactRawResponse(responseData);
        final localPath = await _downloadImage(
          remoteUrl,
          request.outputDirectory,
        );
        await _writeMetadata(
          localPath: localPath,
          remoteUrl: remoteUrl,
          request: request,
          rawResponse: rawResponse,
        );
        return ImageGenerationResult(
          localPath: localPath,
          remoteUrl: remoteUrl,
          rawResponse: rawResponse,
        );
      }
      if (status == 'failed') {
        throw HttpException(_errorMessage(responseData, '图片生成失败'));
      }

      final id = responseData['id']?.toString() ?? '';
      if (id.isEmpty) {
        throw HttpException(_errorMessage(responseData, '图片生成接口未返回任务 ID'));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      responseData = await _getJson(
        resultUri.replace(queryParameters: {'id': id}),
        apiKey: request.apiKey,
      );
    }

    throw const HttpException('图片生成超时，请稍后重试');
  }

  Future<ImageGenerationResult> _generateGeminiImage(
    ImageGenerationRequest request,
    ImageGenerationModelDescriptor descriptor,
  ) {
    if (descriptor.route == ImageGenerationApiRoute.geminiInteractions) {
      final fallbackApiModel = descriptor.geminiGenerateContentFallbackApiModel;
      if (!_isGoogleGeminiEndpoint(request.apiBaseUrl) &&
          fallbackApiModel != null) {
        return _generateGeminiGenerateContentImage(
          request,
          descriptor,
          apiModelOverride: fallbackApiModel,
        );
      }
      return _generateGeminiInteractionImage(request, descriptor);
    }
    return _generateGeminiGenerateContentImage(request, descriptor);
  }

  Future<ImageGenerationResult> _generateGeminiInteractionImage(
    ImageGenerationRequest request,
    ImageGenerationModelDescriptor descriptor,
  ) async {
    final apiModel = descriptor.apiModel.trim();
    final continuation = _validateGeminiContinuation(
      request.geminiContinuation,
      transport: GeminiImageContinuationTransport.interactions,
      apiModel: apiModel,
    );
    final references = await _prepareGeminiReferenceInputs(
      request.referenceImagePaths,
    );
    final input = <Map<String, Object?>>[
      {'type': 'text', 'text': request.prompt.trim()},
      for (final reference in references) reference.interactionPart,
    ];

    final responseFormat = <String, Object?>{
      'type': 'image',
      'aspect_ratio': request.aspectRatio.trim() == 'auto'
          ? '1:1'
          : _normalizeDefaultAspectRatio(request.aspectRatio),
      'image_size': _normalizeDefaultImageSize(request.imageSize),
    };
    final endpoint = _apiUri(request.apiBaseUrl, '/v1beta/interactions');
    final requestRecord = _geminiRequestRecord(
      route: 'interactions',
      endpoint: endpoint,
      apiModel: apiModel,
      references: references,
      continuation: continuation,
    );
    final responseData = await _postGeminiJson(
      endpoint,
      apiBaseUrl: request.apiBaseUrl,
      apiKey: request.apiKey,
      body: {
        'model': apiModel,
        'input': input,
        'response_format': responseFormat,
        'store': true,
        if (continuation != null)
          'previous_interaction_id': continuation.previousInteractionId,
      },
    );
    final inlineImage =
        _geminiInteractionImage(responseData) ??
        _geminiInlineImage(responseData);
    if (inlineImage == null) {
      throw HttpException(_errorMessage(responseData, 'Gemini API 未返回图片数据'));
    }
    return _saveGeminiInlineResult(
      inlineImage: inlineImage,
      request: request,
      responseData: responseData,
      requestRecord: requestRecord,
      continuation: _geminiInteractionContinuation(
        responseData,
        apiModel: apiModel,
      ),
    );
  }

  Future<ImageGenerationResult> _generateGeminiGenerateContentImage(
    ImageGenerationRequest request,
    ImageGenerationModelDescriptor descriptor, {
    String? apiModelOverride,
  }) async {
    final model = (apiModelOverride ?? descriptor.apiModel).trim();
    final continuation = _validateGeminiContinuation(
      request.geminiContinuation,
      transport: GeminiImageContinuationTransport.generateContent,
      apiModel: model,
    );
    final references = await _prepareGeminiReferenceInputs(
      request.referenceImagePaths,
    );
    final parts = <Map<String, Object?>>[
      {'text': request.prompt.trim()},
      for (final reference in references) reference.generateContentPart,
    ];
    final endpoint = _apiUri(
      request.apiBaseUrl,
      '/v1beta/models/${Uri.encodeComponent(model)}:generateContent',
    );
    final currentUserContent = <String, Object?>{
      'role': 'user',
      'parts': parts,
    };
    final contents = <Map<String, Object?>>[
      if (continuation != null) ...continuation.generateContentHistory,
      currentUserContent,
    ];
    final requestRecord = _geminiRequestRecord(
      route: apiModelOverride == null
          ? 'generateContent'
          : 'thirdPartyGenerateContentCompatibility',
      endpoint: endpoint,
      apiModel: model,
      references: references,
      continuation: continuation,
    );
    final body = <String, Object?>{
      'contents': contents,
      'generationConfig': {
        'responseModalities': ['TEXT', 'IMAGE'],
        'imageConfig': {
          'aspectRatio': request.aspectRatio.trim() == 'auto'
              ? '1:1'
              : _normalizeDefaultAspectRatio(request.aspectRatio),
          'imageSize': _normalizeDefaultImageSize(request.imageSize),
        },
      },
    };
    final responseData = await _postJson(
      endpoint,
      apiKey: request.apiKey,
      body: body,
    );
    final inlineImage = _geminiInlineImage(responseData);
    if (inlineImage == null) {
      throw HttpException(_errorMessage(responseData, 'Gemini API 未返回图片数据'));
    }

    return _saveGeminiInlineResult(
      inlineImage: inlineImage,
      request: request,
      responseData: responseData,
      requestRecord: requestRecord,
      continuation: _geminiGenerateContentContinuation(
        responseData,
        apiModel: model,
        requestContents: contents,
      ),
    );
  }

  Future<ImageGenerationResult> _saveGeminiInlineResult({
    required _GeminiInlineImage inlineImage,
    required ImageGenerationRequest request,
    required Map<String, dynamic> responseData,
    required Map<String, Object?> requestRecord,
    required GeminiImageContinuation? continuation,
  }) async {
    final localPath = await _saveInlineImage(
      inlineImage.data,
      inlineImage.mimeType,
      request.outputDirectory,
    );
    final rawResponse = _compactRawResponse(responseData);
    await _writeMetadata(
      localPath: localPath,
      remoteUrl: '',
      request: request,
      rawResponse: rawResponse,
      requestRecord: requestRecord,
    );
    return ImageGenerationResult(
      localPath: localPath,
      remoteUrl: '',
      rawResponse: rawResponse,
      geminiContinuation: continuation,
    );
  }

  Future<String> _prepareGeminiReferenceImage(String input) async {
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      return _prepareReferenceImage(
        input,
        originalByteLimit: nanoBananaOriginalReferenceByteLimit,
      );
    }
    final response = await _client.get(Uri.parse(input));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Gemini 参考图下载失败：${response.statusCode}');
    }
    final mimeType =
        response.headers['content-type']?.split(';').first.trim() ??
        _mimeTypeForImagePath(input);
    return 'data:$mimeType;base64,${base64Encode(response.bodyBytes)}';
  }

  Future<List<_PreparedGeminiReference>> _prepareGeminiReferenceInputs(
    List<String> inputs,
  ) async {
    final references = <_PreparedGeminiReference>[];
    for (var requestIndex = 0; requestIndex < inputs.length; requestIndex++) {
      final source = inputs[requestIndex].trim();
      if (source.isEmpty) {
        continue;
      }
      final dataUri = await _prepareGeminiReferenceImage(source);
      final separator = dataUri.indexOf(',');
      if (separator <= 5 ||
          !dataUri.substring(0, separator).contains(';base64')) {
        throw const FormatException('Gemini 参考图格式无效');
      }
      references.add(
        _PreparedGeminiReference(
          source: source,
          requestIndex: requestIndex,
          mimeType: dataUri.substring(5, separator).split(';').first,
          data: dataUri.substring(separator + 1),
        ),
      );
    }
    return references;
  }

  GeminiImageContinuation? _validateGeminiContinuation(
    GeminiImageContinuation? continuation, {
    required GeminiImageContinuationTransport transport,
    required String apiModel,
  }) {
    if (continuation == null) {
      return null;
    }
    if (continuation.transport != transport) {
      throw const FormatException('Gemini 续轮状态与当前 API 路由不匹配');
    }
    if (continuation.apiModel.trim() != apiModel) {
      throw FormatException(
        'Gemini 续轮模型 ${continuation.apiModel} 与当前模型 $apiModel 不一致',
      );
    }
    if (transport == GeminiImageContinuationTransport.interactions &&
        continuation.previousInteractionId.trim().isEmpty) {
      throw const FormatException('Gemini Interactions 续轮缺少上一轮 interaction ID');
    }
    if (transport == GeminiImageContinuationTransport.generateContent &&
        continuation.generateContentHistory.isEmpty) {
      throw const FormatException('Gemini generateContent 续轮缺少上一轮完整历史');
    }
    return continuation;
  }

  Map<String, Object?> _geminiRequestRecord({
    required String route,
    required Uri endpoint,
    required String apiModel,
    required List<_PreparedGeminiReference> references,
    required GeminiImageContinuation? continuation,
  }) {
    return {
      'protocol': 'gemini',
      'route': route,
      'endpoint': endpoint.toString(),
      'apiModel': apiModel,
      'inputOrder': [
        {'position': 0, 'type': 'text'},
        for (var index = 0; index < references.length; index++)
          {
            'position': index + 1,
            'type': 'referenceImage',
            'referenceIndex': index,
            'sourceRequestIndex': references[index].requestIndex,
          },
      ],
      'orderedReferences': [
        for (var index = 0; index < references.length; index++)
          {
            'referenceIndex': index,
            'sourceRequestIndex': references[index].requestIndex,
            'source': references[index].source,
            'mimeType': references[index].mimeType,
          },
      ],
      'continuation': continuation == null
          ? const {'mode': 'initial'}
          : {
              'mode': 'followUp',
              'transport': continuation.transport.name,
              if (continuation.previousInteractionId.isNotEmpty)
                'previousInteractionId': continuation.previousInteractionId,
              if (continuation.generateContentHistory.isNotEmpty)
                'historyContentCount':
                    continuation.generateContentHistory.length,
            },
    };
  }

  GeminiImageContinuation? _geminiInteractionContinuation(
    Map<String, dynamic> responseData, {
    required String apiModel,
  }) {
    final interactionId = responseData['id']?.toString().trim() ?? '';
    if (interactionId.isEmpty) {
      return null;
    }
    return GeminiImageContinuation(
      transport: GeminiImageContinuationTransport.interactions,
      apiModel: apiModel,
      previousInteractionId: interactionId,
    );
  }

  GeminiImageContinuation? _geminiGenerateContentContinuation(
    Map<String, dynamic> responseData, {
    required String apiModel,
    required List<Map<String, Object?>> requestContents,
  }) {
    final modelContent = _geminiModelContent(responseData);
    if (modelContent == null) {
      return null;
    }
    return GeminiImageContinuation(
      transport: GeminiImageContinuationTransport.generateContent,
      apiModel: apiModel,
      generateContentHistory: [...requestContents, modelContent],
    );
  }

  Map<String, Object?>? _geminiModelContent(Map<String, dynamic> responseData) {
    final candidates = responseData['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return null;
    }
    final candidate = candidates.first;
    if (candidate is! Map || candidate['content'] is! Map) {
      return null;
    }
    final content = Map<String, Object?>.from(candidate['content'] as Map);
    content.putIfAbsent('role', () => 'model');
    return content;
  }

  _GeminiInlineImage? _geminiInlineImage(Map<String, dynamic> data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return null;
    }
    final candidate = candidates.first;
    if (candidate is! Map) {
      return null;
    }
    final content = candidate['content'];
    if (content is! Map || content['parts'] is! List) {
      return null;
    }
    for (final part in content['parts'] as List) {
      if (part is! Map) {
        continue;
      }
      final inlineData = part['inlineData'] ?? part['inline_data'];
      if (inlineData is! Map) {
        continue;
      }
      final encoded = inlineData['data']?.toString().trim() ?? '';
      if (encoded.isEmpty) {
        continue;
      }
      final mimeType =
          inlineData['mimeType']?.toString().trim() ??
          inlineData['mime_type']?.toString().trim() ??
          'image/png';
      return _GeminiInlineImage(data: encoded, mimeType: mimeType);
    }
    return null;
  }

  _GeminiInlineImage? _geminiInteractionImage(Map<String, dynamic> data) {
    final direct = data['output_image'] ?? data['outputImage'];
    if (direct is Map) {
      final image = _geminiInteractionImageBlock(direct);
      if (image != null) {
        return image;
      }
    }

    final steps = data['steps'] ?? data['outputs'];
    if (steps is! List) {
      return null;
    }
    for (final step in steps) {
      if (step is! Map) {
        continue;
      }
      final content = step['content'];
      if (content is List) {
        for (final block in content) {
          if (block is! Map) {
            continue;
          }
          final image = _geminiInteractionImageBlock(block);
          if (image != null) {
            return image;
          }
        }
      } else if (content is Map) {
        final image = _geminiInteractionImageBlock(content);
        if (image != null) {
          return image;
        }
      }
    }
    return null;
  }

  _GeminiInlineImage? _geminiInteractionImageBlock(Map block) {
    final type = block['type']?.toString().trim().toLowerCase() ?? '';
    if (type.isNotEmpty && type != 'image') {
      return null;
    }
    final encoded =
        block['data']?.toString().trim() ??
        block['base64']?.toString().trim() ??
        '';
    if (encoded.isEmpty) {
      return null;
    }
    final mimeType =
        block['mime_type']?.toString().trim() ??
        block['mimeType']?.toString().trim() ??
        'image/png';
    return _GeminiInlineImage(data: encoded, mimeType: mimeType);
  }

  Future<String> _saveInlineImage(
    String encoded,
    String mimeType,
    Directory outputDirectory,
  ) async {
    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException('Gemini API 返回的图片数据不是有效 Base64');
    }
    final timestamp = DateTime.now();
    final extension = switch (mimeType.toLowerCase()) {
      'image/jpeg' => '.jpg',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      _ => '.png',
    };
    final fileName =
        'generated_${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}_'
        '${timestamp.millisecond.toString().padLeft(3, '0')}$extension';
    final target = _uniqueFile(outputDirectory, fileName);
    await target.writeAsBytes(bytes);
    return target.path;
  }

  Future<ImageGenerationResult> _generateApiMartImage(
    ImageGenerationRequest request,
    ImageGenerationModelDescriptor descriptor,
  ) async {
    final normalizedAspectRatio = _normalizeCatalogOption(
      request.aspectRatio,
      descriptor.aspectRatios,
    );
    final supportedResolutions = ImageGenerationCatalog.resolutionsFor(
      request.model,
      normalizedAspectRatio,
    );
    final hasSupportedResolution = supportedResolutions.any(
      (item) => item.toLowerCase() == request.imageSize.trim().toLowerCase(),
    );
    if (!hasSupportedResolution) {
      throw FormatException(
        '${descriptor.label} 的 $normalizedAspectRatio 比例不支持 '
        '${request.imageSize.trim()} 分辨率，可选：${supportedResolutions.join('、')}',
      );
    }

    final inputReferences = request.referenceImagePaths
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (inputReferences.isNotEmpty && !descriptor.supportsReferenceImages) {
      throw FormatException('${descriptor.label} 不支持参考图或图片修改');
    }
    if (inputReferences.length > descriptor.maxReferenceImages) {
      throw FormatException(
        '${descriptor.label} 最多支持 ${descriptor.maxReferenceImages} 张参考图',
      );
    }

    final references = <String>[];
    for (final input in inputReferences) {
      references.add(
        await _prepareApiMartReferenceImage(
          input,
          apiBaseUrl: request.apiBaseUrl,
          apiKey: request.apiKey,
        ),
      );
    }

    final hasReferences = references.isNotEmpty;
    final submitUri = _apiMartSubmitUri(
      request.apiBaseUrl,
      descriptor,
      hasReferences: hasReferences,
    );
    final submitBody = _buildApiMartRequestBody(
      request,
      descriptor,
      references: references,
    );
    final submitted = await _postJson(
      submitUri,
      apiKey: request.apiKey,
      body: submitBody,
    );
    final taskId = _apiMartTaskId(submitted);
    if (taskId.isEmpty) {
      throw HttpException(_errorMessage(submitted, 'APIMart 未返回任务 ID'));
    }

    final taskUri = _apiUri(
      request.apiBaseUrl,
      '/v1/tasks/${Uri.encodeComponent(taskId)}',
    ).replace(queryParameters: const {'language': 'zh'});
    final polling = Stopwatch()..start();
    var lastStatus = 'submitted';
    while (polling.elapsed < _apiMartTimeout) {
      final taskData = await _getJson(taskUri, apiKey: request.apiKey);
      final task = _apiMartTask(taskData);
      final status = task['status']?.toString().toLowerCase() ?? '';
      if (status.isNotEmpty) {
        lastStatus = status;
      }
      if (status == 'completed') {
        final urls = _apiMartResultUrls(task);
        if (urls.isEmpty) {
          throw HttpException(_errorMessage(taskData, 'APIMart 任务完成但未返回图片'));
        }
        final remoteUrl = urls.first;
        final rawResponse = _compactRawResponse(taskData);
        final localPath = await _downloadImage(
          remoteUrl,
          request.outputDirectory,
        );
        await _writeMetadata(
          localPath: localPath,
          remoteUrl: remoteUrl,
          request: request,
          rawResponse: rawResponse,
        );
        return ImageGenerationResult(
          localPath: localPath,
          remoteUrl: remoteUrl,
          rawResponse: rawResponse,
        );
      }
      if (status == 'failed' || status == 'cancelled') {
        throw HttpException(
          _errorMessage(
            task,
            status == 'cancelled' ? 'APIMart 图片生成任务已取消' : 'APIMart 图片生成失败',
          ),
        );
      }
      await Future<void>.delayed(_apiMartPollInterval);
    }
    throw HttpException(
      'APIMart 任务等待 ${_formatDuration(_apiMartTimeout)} 后仍未完成'
      '（当前状态：$lastStatus，任务 ID：$taskId）。任务可能仍在服务端继续执行。',
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inMinutes > 0 && duration.inSeconds % 60 == 0) {
      return '${duration.inMinutes} 分钟';
    }
    return '${duration.inSeconds} 秒';
  }

  Uri _apiMartSubmitUri(
    String apiBaseUrl,
    ImageGenerationModelDescriptor descriptor, {
    required bool hasReferences,
  }) {
    final path = switch (descriptor.route) {
      ImageGenerationApiRoute.apiMartMidjourney => '/v1/midjourney/generations',
      ImageGenerationApiRoute.apiMartGrok when hasReferences =>
        '/v1/images/edits',
      _ => '/v1/images/generations',
    };
    return _apiUri(apiBaseUrl, path);
  }

  Map<String, Object?> _buildApiMartRequestBody(
    ImageGenerationRequest request,
    ImageGenerationModelDescriptor descriptor, {
    required List<String> references,
  }) {
    final aspectRatio = _normalizeCatalogOption(
      request.aspectRatio,
      descriptor.aspectRatios,
    );
    var resolution = _normalizeCatalogOption(
      request.imageSize,
      ImageGenerationCatalog.resolutionsFor(request.model, aspectRatio),
    );
    final hasReferences = references.isNotEmpty;

    if (descriptor.apiModel == 'wan2.7-image-pro' &&
        hasReferences &&
        resolution == '4K') {
      resolution = '2K';
    }

    if (descriptor.route == ImageGenerationApiRoute.apiMartMidjourney) {
      return <String, Object?>{
        'prompt': request.prompt.trim(),
        'size': aspectRatio,
        'version': '6.1',
        'speed': 'fast',
        if (hasReferences) 'image_urls': references,
      };
    }

    final body = <String, Object?>{
      'model': ImageGenerationCatalog.apiModelFor(
        request.model,
        hasReferences: hasReferences,
      ),
      'prompt': request.prompt.trim(),
      'n': 1,
    };
    if (descriptor.route == ImageGenerationApiRoute.apiMartGrok &&
        hasReferences) {
      body['image_urls'] = references;
      return body;
    }

    body['size'] = aspectRatio;
    if (resolution.toLowerCase() != 'auto') {
      body['resolution'] = descriptor.apiModel.startsWith('gpt-image-2')
          ? resolution.toLowerCase()
          : resolution;
    }
    if (descriptor.supportsQuality) {
      body['quality'] = _normalizeCatalogOption(
        request.quality.toLowerCase(),
        descriptor.qualities,
      );
    }
    if (hasReferences) {
      body['image_urls'] = references;
    }
    return body;
  }

  String _normalizeCatalogOption(String value, List<String> options) {
    if (options.isEmpty) {
      return 'auto';
    }
    final trimmed = value.trim();
    for (final option in options) {
      if (option.toLowerCase() == trimmed.toLowerCase()) {
        return option;
      }
    }
    return options.first;
  }

  String _apiMartTaskId(Map<String, dynamic> data) {
    final payload = data['data'];
    if (payload is List && payload.isNotEmpty && payload.first is Map) {
      return (payload.first as Map)['task_id']?.toString() ?? '';
    }
    if (payload is Map) {
      return payload['task_id']?.toString() ?? payload['id']?.toString() ?? '';
    }
    return data['task_id']?.toString() ?? data['id']?.toString() ?? '';
  }

  Map<String, dynamic> _apiMartTask(Map<String, dynamic> data) {
    final payload = data['data'];
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return data;
  }

  List<String> _apiMartResultUrls(Map<String, dynamic> task) {
    final result = task['result'];
    if (result is! Map) {
      return const [];
    }
    final images = result['images'];
    if (images is! List) {
      return const [];
    }
    final urls = <String>[];
    for (final image in images) {
      if (image is! Map) {
        continue;
      }
      final value = image['url'];
      if (value is String && value.trim().isNotEmpty) {
        urls.add(value.trim());
      } else if (value is List) {
        urls.addAll(
          value
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty),
        );
      }
    }
    return urls;
  }

  Future<String> _prepareApiMartReferenceImage(
    String input, {
    required String apiBaseUrl,
    required String apiKey,
  }) async {
    if (input.startsWith('http://') || input.startsWith('https://')) {
      return input;
    }

    final uploadUri = _apiUri(apiBaseUrl, '/v1/uploads/images');
    Object? lastError;
    final attempts = _apiMartUploadMaxAttempts < 1
        ? 1
        : _apiMartUploadMaxAttempts;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final clientFactory = _apiMartUploadClientFactory;
      final uploadClient = clientFactory?.call() ?? _client;
      try {
        final upload = await _buildApiMartUploadRequest(
          input,
          uploadUri: uploadUri,
          apiKey: apiKey,
        );
        final response = await (() async {
          final streamed = await uploadClient.send(upload);
          return http.Response.fromStream(streamed);
        })().timeout(_apiMartUploadTimeout);
        final data = _decodeJsonResponse(response);
        final url = data['url']?.toString().trim() ?? '';
        if (url.isEmpty) {
          throw HttpException(_errorMessage(data, 'APIMart 上传参考图未返回 URL'));
        }
        return url;
      } on Object catch (error) {
        if (!_isRetryableApiMartUploadError(error)) {
          rethrow;
        }
        lastError = error;
        await _diagnosticLogger?.write('reference_upload_retry', {
          'endpoint': _safeEndpoint(apiBaseUrl),
          'network_route': 'direct',
          'attempt': attempt,
          'max_attempts': attempts,
          'error': ImageGenerationDiagnosticLogger.safeError(error),
        });
        if (attempt < attempts && _apiMartUploadRetryDelay > Duration.zero) {
          await Future<void>.delayed(_apiMartUploadRetryDelay * attempt);
        }
      } finally {
        if (clientFactory != null) {
          uploadClient.close();
        }
      }
    }

    final fallbackFactory = _apiMartUploadFallbackClientFactory;
    if (fallbackFactory != null) {
      final fallbackClient = fallbackFactory();
      try {
        final upload = await _buildApiMartUploadRequest(
          input,
          uploadUri: uploadUri,
          apiKey: apiKey,
        );
        final response = await (() async {
          final streamed = await fallbackClient.send(upload);
          return http.Response.fromStream(streamed);
        })().timeout(_apiMartUploadTimeout);
        final data = _decodeJsonResponse(response);
        final url = data['url']?.toString().trim() ?? '';
        if (url.isEmpty) {
          throw HttpException(_errorMessage(data, 'APIMart 上传参考图未返回 URL'));
        }
        await _diagnosticLogger?.write('reference_upload_fallback_succeeded', {
          'endpoint': _safeEndpoint(apiBaseUrl),
          'network_route': 'environment_proxy',
        });
        return url;
      } on Object catch (error) {
        if (!_isRetryableApiMartUploadError(error)) {
          rethrow;
        }
        lastError = error;
        await _diagnosticLogger?.write('reference_upload_fallback_failed', {
          'endpoint': _safeEndpoint(apiBaseUrl),
          'network_route': 'environment_proxy',
          'error': ImageGenerationDiagnosticLogger.safeError(error),
        });
      } finally {
        fallbackClient.close();
      }
    }
    throw HttpException(
      'APIMart 参考图上传失败（直连已尝试 $attempts 次'
      '${fallbackFactory == null ? '，未检测到环境代理' : '，环境代理回退也失败'}）：'
      '${_apiMartUploadErrorMessage(lastError)}',
    );
  }

  Future<http.MultipartRequest> _buildApiMartUploadRequest(
    String input, {
    required Uri uploadUri,
    required String apiKey,
  }) async {
    final upload = http.MultipartRequest('POST', uploadUri)
      ..headers.addAll(_headers(apiKey));
    if (input.startsWith('data:')) {
      final separator = input.indexOf(',');
      if (separator <= 0 ||
          !input.substring(0, separator).contains(';base64')) {
        throw const FormatException('APIMart 参考图 Data URI 格式无效');
      }
      final header = input.substring(0, separator);
      final mimeType = header.substring(5).split(';').first;
      final bytes = base64Decode(input.substring(separator + 1));
      upload.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'reference.${_extensionForMimeType(mimeType)}',
        ),
      );
    } else {
      final file = File(input);
      if (!await file.exists()) {
        throw FileSystemException('参考图不存在', input);
      }
      if (await file.length() > 20 * 1024 * 1024) {
        throw FileSystemException('APIMart 参考图不能超过 20MB', input);
      }
      upload.files.add(await http.MultipartFile.fromPath('file', input));
    }
    return upload;
  }

  bool _isRetryableApiMartUploadError(Object error) {
    return error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException;
  }

  String _apiMartUploadErrorMessage(Object? error) {
    if (error == null) {
      return '未知网络错误';
    }
    if (error is TimeoutException) {
      return '超过 ${_formatDuration(_apiMartUploadTimeout)} 未完成';
    }
    return error.toString();
  }

  String _extensionForMimeType(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'png',
    };
  }

  void close() {
    _client.close();
  }

  Future<Map<String, Object?>> _buildRequestBody(
    ImageGenerationRequest request,
  ) async {
    final images = <String>[];
    final descriptor = ImageGenerationModelCatalog.descriptorFor(request.model);
    final preserveOriginal = descriptor?.familyId == 'nano-banana';
    for (final path in request.referenceImagePaths) {
      final normalized = path.trim();
      if (normalized.isEmpty) {
        continue;
      }
      images.add(
        await _prepareReferenceImage(
          normalized,
          originalByteLimit: preserveOriginal
              ? nanoBananaOriginalReferenceByteLimit
              : 0,
        ),
      );
    }

    final model = request.model.trim();
    final body = <String, Object?>{
      'model': model,
      'prompt': request.prompt.trim(),
      'images': images,
      'replyType': 'json',
    };
    if (GptImageGenerationPreset.isModel(model)) {
      body['aspectRatio'] = GptImageGenerationPreset.resolveOpenAiSize(
        model: model,
        aspectRatio: request.aspectRatio,
        imageSize: request.imageSize,
      );
      body['quality'] = GptImageGenerationPreset.normalizeQuality(
        request.quality,
      );
    } else {
      body['aspectRatio'] = _normalizeDefaultAspectRatio(request.aspectRatio);
      body['imageSize'] = _normalizeDefaultImageSize(request.imageSize);
    }
    return body;
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri, {
    required String apiKey,
    required Map<String, Object?> body,
  }) async {
    final response = await _client.post(
      uri,
      headers: _headers(apiKey, json: true),
      body: jsonEncode(body),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> _postGeminiJson(
    Uri uri, {
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, Object?> body,
  }) async {
    final response = await _client.post(
      uri,
      headers: _geminiHeaders(apiBaseUrl, apiKey, json: true),
      body: jsonEncode(body),
    );
    return _decodeJsonResponse(response);
  }

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    required String apiKey,
  }) async {
    final response = await _client.get(uri, headers: _headers(apiKey));
    return _decodeJsonResponse(response);
  }

  Map<String, String> _headers(String apiKey, {bool json = false}) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
    };
  }

  Map<String, String> _geminiHeaders(
    String apiBaseUrl,
    String apiKey, {
    bool json = false,
  }) {
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
    };
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      return headers;
    }
    if (_isGoogleGeminiEndpoint(apiBaseUrl)) {
      headers['x-goog-api-key'] = trimmedKey;
    } else {
      headers['Authorization'] = 'Bearer $trimmedKey';
    }
    return headers;
  }

  bool _isGoogleGeminiEndpoint(String apiBaseUrl) {
    try {
      final host = Uri.parse(_apiOrigin(apiBaseUrl)).host.toLowerCase();
      return host == 'generativelanguage.googleapis.com';
    } on FormatException {
      return false;
    }
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw HttpException('图片生成接口响应不是 JSON：$body');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        _errorMessage(decoded, '图片生成请求失败：${response.statusCode}'),
      );
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('图片生成接口响应不是 JSON 对象');
  }

  Future<String> _prepareReferenceImage(
    String input, {
    int originalByteLimit = 0,
  }) async {
    if (input.startsWith('data:') ||
        input.startsWith('http://') ||
        input.startsWith('https://')) {
      return input;
    }

    final file = File(input);
    if (!await file.exists()) {
      throw FileSystemException('参考图不存在', input);
    }
    final bytes = await file.readAsBytes();
    if (originalByteLimit > 0 && bytes.length <= originalByteLimit) {
      final mimeType = _mimeTypeForImagePath(input);
      return 'data:$mimeType;base64,${base64Encode(bytes)}';
    }
    final transferable = TransferableTypedData.fromList([bytes]);
    return Isolate.run(
      () => _prepareReferenceImageInWorker(transferable, input),
    );
  }

  Future<String> _downloadImage(String url, Directory outputDirectory) async {
    final response = await _client.get(Uri.parse(url));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('图片下载失败：${response.statusCode}');
    }
    final timestamp = DateTime.now();
    final fileName =
        'generated_${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}_'
        '${timestamp.millisecond.toString().padLeft(3, '0')}${_extensionForUrl(url)}';
    final target = _uniqueFile(outputDirectory, fileName);
    await target.writeAsBytes(response.bodyBytes);
    return target.path;
  }

  Future<void> _writeMetadata({
    required String localPath,
    required String remoteUrl,
    required ImageGenerationRequest request,
    required String rawResponse,
    Map<String, Object?> requestRecord = const {},
  }) async {
    final file = File('$localPath.json');
    await file.writeAsString(
      jsonEncode({
        'prompt': request.prompt,
        'model': request.model,
        'aspectRatio': request.aspectRatio,
        'imageSize': request.imageSize,
        'quality': request.quality,
        'remoteUrl': remoteUrl,
        'referenceImages': request.referenceImagePaths,
        if (requestRecord.isNotEmpty) 'requestRecord': requestRecord,
        'rawResponse': rawResponse,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  String _compactRawResponse(Map<String, dynamic> responseData) {
    final omissions = _ImageResponseOmissions();
    final compacted =
        _compactResponseValue(responseData, omissions: omissions)
            as Map<String, dynamic>;
    if (omissions.hasEntries) {
      compacted['payloadOmissions'] = omissions.toJson();
    }
    return jsonEncode(compacted);
  }

  Object? _compactResponseValue(
    Object? value, {
    required _ImageResponseOmissions omissions,
    String parentKey = '',
  }) {
    if (value is List) {
      return [
        for (final item in value)
          _compactResponseValue(
            item,
            omissions: omissions,
            parentKey: parentKey,
          ),
      ];
    }
    if (value is! Map) {
      return value;
    }

    final compacted = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final normalizedKey = key.replaceAll('_', '').toLowerCase();
      final entryValue = entry.value;
      if (_isEncodedImagePayload(
        key: normalizedKey,
        parentKey: parentKey,
        value: entryValue,
      )) {
        omissions.addImagePayload(entryValue);
        continue;
      }
      compacted[key] = _compactResponseValue(
        entryValue,
        omissions: omissions,
        parentKey: key,
      );
    }
    return compacted;
  }

  bool _isEncodedImagePayload({
    required String key,
    required String parentKey,
    required Object? value,
  }) {
    if (value is! String || value.isEmpty) {
      return false;
    }
    if (key == 'b64json' ||
        key == 'imagedata' ||
        key == 'imagebase64' ||
        key == 'base64image') {
      return true;
    }
    final normalizedParent = parentKey.replaceAll('_', '').toLowerCase();
    if (key == 'data' && normalizedParent == 'inlinedata') {
      return true;
    }
    if (key == 'data' &&
        const {'content', 'image', 'outputimage'}.contains(normalizedParent)) {
      return _looksLikeBase64Payload(value);
    }
    return value.startsWith('data:image/') && value.contains(';base64,');
  }

  bool _looksLikeBase64Payload(String value) {
    if (value.length < 256) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9+/=\r\n]+$').hasMatch(value);
  }

  void _validateBaseRequest(ImageGenerationRequest request) {
    final descriptor = ImageGenerationModelCatalog.descriptorFor(request.model);
    if (descriptor == null) {
      throw FormatException('不支持的图片生成模型：${request.model}');
    }
    if (descriptor.providerId != request.provider.providerId ||
        descriptor.protocol != request.provider.protocol) {
      throw FormatException(
        '${descriptor.label} 属于 ${ImageGenerationModelCatalog.providerLabelForModel(request.model)}，'
        '不能使用 ${request.provider.providerLabel} 配置',
      );
    }
    if (request.geminiContinuation != null &&
        descriptor.protocol != ImageGenerationProviderProtocol.gemini) {
      throw const FormatException('只有 Gemini 图片模型支持 Gemini 续轮状态');
    }
    if (request.apiBaseUrl.trim().isEmpty) {
      throw FormatException('请先填写 ${request.provider.providerLabel} API 地址');
    }
    if (request.provider.protocol == ImageGenerationProviderProtocol.apiMart) {
      ApiEndpointNormalizer.normalizeApiMartBaseUrl(request.apiBaseUrl);
    }
    if (request.apiKey.trim().isEmpty) {
      throw FormatException('请先填写 ${request.provider.providerLabel} API Key');
    }
    if (request.model.trim().isEmpty) {
      throw const FormatException('请先选择图片生成模型');
    }
    if (request.prompt.trim().isEmpty) {
      throw const FormatException('请先输入生成提示词');
    }
  }

  void _validateReferenceImages(ImageGenerationRequest request) {
    if (request.referenceImagePaths.isEmpty &&
        request.geminiContinuation == null) {
      throw const FormatException('至少需要一张参考图');
    }
  }

  List<String> _resultUrls(Map<String, dynamic> data) {
    final results = data['results'];
    if (results is! List) {
      return const [];
    }
    return [
      for (final item in results)
        if (item is Map && item['url'] != null) item['url'].toString(),
    ].where((url) => url.trim().isNotEmpty).toList();
  }

  String _errorMessage(Object? data, String fallback) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] != null) {
        return error['message'].toString();
      }
      if (error is String && error.trim().isNotEmpty) {
        return error.trim();
      }
      for (final key in const ['message', 'msg', 'detail', 'failure_reason']) {
        final value = data[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
      final payload = data['data'];
      if (payload is Map) {
        return _errorMessage(payload, fallback);
      }
    }
    return fallback;
  }

  Uri _apiUri(String apiBaseUrl, String pathSuffix) {
    final origin = _apiOrigin(apiBaseUrl);
    return Uri.parse('$origin$pathSuffix');
  }

  String _apiOrigin(String apiBaseUrl) {
    final trimmed = apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final withScheme = _hasScheme(trimmed)
        ? trimmed
        : '${_defaultSchemeFor(trimmed)}://$trimmed';
    final uri = Uri.parse(withScheme);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
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

  String _normalizeDefaultAspectRatio(String value) {
    final trimmed = value.trim();
    return ImageGenerationModelCatalog.defaultAspectRatios.contains(trimmed)
        ? trimmed
        : 'auto';
  }

  String _normalizeDefaultImageSize(String value) {
    final normalized = value.trim().toUpperCase();
    return ImageGenerationModelCatalog.defaultImageSizes.contains(normalized)
        ? normalized
        : '1K';
  }

  String _extensionForUrl(String url) {
    final extension = p.extension(Uri.parse(url).path).toLowerCase();
    if (const {'.png', '.jpg', '.jpeg', '.webp'}.contains(extension)) {
      return extension;
    }
    return '.png';
  }

  File _uniqueFile(Directory directory, String fileName) {
    final extension = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    var candidate = File(p.join(directory.path, fileName));
    var index = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(directory.path, '${baseName}_$index$extension'));
      index++;
    }
    return candidate;
  }
}

class _ImageResponseOmissions {
  var imagePayloadCount = 0;
  var imagePayloadCharacters = 0;

  bool get hasEntries => imagePayloadCount > 0;

  void addImagePayload(Object? value) {
    imagePayloadCount++;
    if (value is String) {
      imagePayloadCharacters += value.length;
    }
  }

  Map<String, int> toJson() => {
    if (imagePayloadCount > 0) ...{
      'imagePayloadCount': imagePayloadCount,
      'imagePayloadCharacters': imagePayloadCharacters,
    },
  };
}

class _PreparedGeminiReference {
  const _PreparedGeminiReference({
    required this.source,
    required this.requestIndex,
    required this.mimeType,
    required this.data,
  });

  final String source;
  final int requestIndex;
  final String mimeType;
  final String data;

  Map<String, Object?> get interactionPart => {
    'type': 'image',
    'mime_type': mimeType,
    'data': data,
  };

  Map<String, Object?> get generateContentPart => {
    'inline_data': {'mime_type': mimeType, 'data': data},
  };
}

class _GeminiInlineImage {
  const _GeminiInlineImage({required this.data, required this.mimeType});

  final String data;
  final String mimeType;
}

String _prepareReferenceImageInWorker(
  TransferableTypedData transferable,
  String input,
) {
  final bytes = transferable.materialize().asUint8List();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    final mimeType = _mimeTypeForImagePath(input);
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  var current = decoded;
  if (current.width > 1536 || current.height > 1536) {
    current = current.width >= current.height
        ? img.copyResize(current, width: 1536)
        : img.copyResize(current, height: 1536);
  }

  var quality = 82;
  var encoded = img.encodeJpg(current, quality: quality);
  while (encoded.length > 900 * 1024 && quality > 45) {
    quality -= 10;
    encoded = img.encodeJpg(current, quality: quality);
  }
  if (encoded.length > 900 * 1024 &&
      (current.width > 1024 || current.height > 1024)) {
    current = current.width >= current.height
        ? img.copyResize(current, width: 1024)
        : img.copyResize(current, height: 1024);
    quality = 72;
    encoded = img.encodeJpg(current, quality: quality);
    while (encoded.length > 900 * 1024 && quality > 40) {
      quality -= 8;
      encoded = img.encodeJpg(current, quality: quality);
    }
  }

  return 'data:image/jpeg;base64,${base64Encode(encoded)}';
}

String _mimeTypeForImagePath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'image/png';
}
