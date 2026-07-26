enum ImageGenerationProviderProtocol { gemini, grsai, apiMart }

enum ImageGenerationApiRoute {
  grsaiUnified,
  geminiGenerateContent,
  geminiInteractions,
  apiMartImages,
  apiMartGrok,
  apiMartMidjourney,
}

class ImageGenerationProviderConnection {
  const ImageGenerationProviderConnection({
    required this.providerId,
    required this.providerLabel,
    required this.protocol,
    required this.apiBaseUrl,
    required this.apiKey,
  });

  final String providerId;
  final String providerLabel;
  final ImageGenerationProviderProtocol protocol;
  final String apiBaseUrl;
  final String apiKey;
}

class ImageGenerationModelDescriptor {
  const ImageGenerationModelDescriptor({
    required this.id,
    required this.apiModel,
    required this.label,
    required this.providerId,
    required this.familyId,
    required this.protocol,
    required this.route,
    required this.aspectRatios,
    required this.resolutions,
    this.qualities = const ['auto'],
    this.supportsReferenceImages = true,
    this.maxReferenceImages = 10,
    this.referenceApiModel,
  });

  /// Stable app-side selection id. Provider prefixes prevent model-id clashes.
  final String id;
  final String apiModel;
  final String label;
  final String providerId;
  final String familyId;
  final ImageGenerationProviderProtocol protocol;
  final ImageGenerationApiRoute route;
  final List<String> aspectRatios;
  final List<String> resolutions;
  final List<String> qualities;
  final bool supportsReferenceImages;
  final int maxReferenceImages;

  /// Some providers use a distinct model id for image editing.
  final String? referenceApiModel;

  bool get isApiMart => protocol == ImageGenerationProviderProtocol.apiMart;
  bool get supportsQuality => qualities.length > 1;
}

class ImageGenerationModelFamily {
  const ImageGenerationModelFamily({
    required this.id,
    required this.label,
    required this.modelIds,
  });

  final String id;
  final String label;
  final List<String> modelIds;
}

class ImageGenerationModelProvider {
  const ImageGenerationModelProvider({
    required this.id,
    required this.label,
    required this.families,
  });

  final String id;
  final String label;
  final List<ImageGenerationModelFamily> families;
}

class ImageGenerationCatalog {
  static const defaultAspectRatios = [
    'auto',
    '1:1',
    '16:9',
    '9:16',
    '4:3',
    '3:4',
    '3:2',
    '2:3',
  ];

  static const defaultResolutions = ['1K', '2K', '4K'];
  static const qualityOptions = ['auto', 'low', 'medium', 'high'];

  static const _wideAspectRatios = [
    'auto',
    '1:1',
    '3:2',
    '2:3',
    '4:3',
    '3:4',
    '5:4',
    '4:5',
    '16:9',
    '9:16',
    '21:9',
  ];

  static const _gpt2AspectRatios = [
    'auto',
    '1:1',
    '3:2',
    '2:3',
    '4:3',
    '3:4',
    '5:4',
    '4:5',
    '16:9',
    '9:16',
    '2:1',
    '1:2',
    '3:1',
    '1:3',
    '21:9',
    '9:21',
  ];

  static const _seedreamAspectRatios = [
    'auto',
    '1:1',
    '4:3',
    '3:4',
    '16:9',
    '9:16',
    '3:2',
    '2:3',
    '21:9',
    '9:21',
  ];

  static const _seedream5LiteAspectRatios = [
    'auto',
    '1:1',
    '4:3',
    '3:4',
    '16:9',
    '9:16',
    '3:2',
    '2:3',
    '21:9',
  ];

  static const _gptImage2FourKAspectRatios = {
    '16:9',
    '9:16',
    '2:1',
    '1:2',
    '21:9',
    '9:21',
  };

  static final models = <ImageGenerationModelDescriptor>[
    // Existing models keep their raw ids for persisted-setting compatibility.
    ImageGenerationModelDescriptor(
      id: 'gemini-3-pro-image',
      apiModel: 'gemini-3-pro-image',
      label: 'Gemini 3 Pro Image',
      providerId: 'gemini',
      familyId: 'gemini-image',
      protocol: ImageGenerationProviderProtocol.gemini,
      route: ImageGenerationApiRoute.geminiInteractions,
      aspectRatios: defaultAspectRatios,
      resolutions: defaultResolutions,
      maxReferenceImages: 11,
    ),
    ImageGenerationModelDescriptor(
      id: 'gemini-3.1-flash-image',
      apiModel: 'gemini-3.1-flash-image',
      label: 'Gemini 3.1 Flash Image',
      providerId: 'gemini',
      familyId: 'gemini-image',
      protocol: ImageGenerationProviderProtocol.gemini,
      route: ImageGenerationApiRoute.geminiInteractions,
      aspectRatios: [..._wideAspectRatios, '1:4', '4:1', '1:8', '8:1'],
      resolutions: ['0.5K', '1K', '2K', '4K'],
      maxReferenceImages: 14,
    ),
    ImageGenerationModelDescriptor(
      id: 'gemini-3-pro-image-preview',
      apiModel: 'gemini-3-pro-image-preview',
      label: 'Gemini 3 Pro Image Preview',
      providerId: 'gemini',
      familyId: 'gemini-image',
      protocol: ImageGenerationProviderProtocol.gemini,
      route: ImageGenerationApiRoute.geminiGenerateContent,
      aspectRatios: defaultAspectRatios,
      resolutions: defaultResolutions,
    ),
    ImageGenerationModelDescriptor(
      id: 'gemini-3.1-flash-image-preview',
      apiModel: 'gemini-3.1-flash-image-preview',
      label: 'Gemini 3.1 Flash Image Preview',
      providerId: 'gemini',
      familyId: 'gemini-image',
      protocol: ImageGenerationProviderProtocol.gemini,
      route: ImageGenerationApiRoute.geminiGenerateContent,
      aspectRatios: defaultAspectRatios,
      resolutions: defaultResolutions,
    ),
    for (final item in <(String, String)>[
      ('nano-banana', 'Nano Banana'),
      ('nano-banana-2', 'Nano Banana 2'),
      ('nano-banana-fast', 'Nano Banana Fast'),
      ('nano-banana-pro', 'Nano Banana Pro'),
      ('nano-banana-pro-4k-vip', 'Nano Banana Pro 4K VIP'),
      ('nano-banana-pro-cl', 'Nano Banana Pro CL'),
      ('nano-banana-pro-vip', 'Nano Banana Pro VIP'),
      ('nano-banana-pro-vt', 'Nano Banana Pro VT'),
    ])
      ImageGenerationModelDescriptor(
        id: item.$1,
        apiModel: item.$1,
        label: item.$2,
        providerId: 'grsai',
        familyId: 'nano-banana',
        protocol: ImageGenerationProviderProtocol.grsai,
        route: ImageGenerationApiRoute.grsaiUnified,
        aspectRatios: defaultAspectRatios,
        resolutions: defaultResolutions,
      ),
    ImageGenerationModelDescriptor(
      id: 'gpt-image-2',
      apiModel: 'gpt-image-2',
      label: 'GPT Image 2',
      providerId: 'grsai',
      familyId: 'gpt-image',
      protocol: ImageGenerationProviderProtocol.grsai,
      route: ImageGenerationApiRoute.grsaiUnified,
      aspectRatios: _gpt2AspectRatios,
      resolutions: defaultResolutions,
      qualities: qualityOptions,
    ),
    ImageGenerationModelDescriptor(
      id: 'gpt-image-2-vip',
      apiModel: 'gpt-image-2-vip',
      label: 'GPT Image 2 VIP',
      providerId: 'grsai',
      familyId: 'gpt-image',
      protocol: ImageGenerationProviderProtocol.grsai,
      route: ImageGenerationApiRoute.grsaiUnified,
      aspectRatios: _gpt2AspectRatios,
      resolutions: defaultResolutions,
      qualities: qualityOptions,
    ),

    // APIMart model ids are namespaced because some ids also exist in GRSai.
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-2.5-flash-image-preview',
      apiModel: 'gemini-2.5-flash-image-preview',
      label: 'Nano Banana',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _wideAspectRatios,
      resolutions: ['1K'],
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-2.5-flash-image-preview-official',
      apiModel: 'gemini-2.5-flash-image-preview-official',
      label: 'Nano Banana Official',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _wideAspectRatios,
      resolutions: ['1K'],
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-3-pro-image-preview',
      apiModel: 'gemini-3-pro-image-preview',
      label: 'Nano Banana Pro',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _wideAspectRatios,
      resolutions: defaultResolutions,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-3-pro-image-preview-official',
      apiModel: 'gemini-3-pro-image-preview-official',
      label: 'Nano Banana Pro Official',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _wideAspectRatios,
      resolutions: defaultResolutions,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-3.1-flash-image-preview',
      apiModel: 'gemini-3.1-flash-image-preview',
      label: 'Nano Banana 2',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: [..._wideAspectRatios, '1:4', '4:1', '1:8', '8:1'],
      resolutions: ['0.5K', '1K', '2K', '4K'],
      maxReferenceImages: 14,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-3.1-flash-image-preview-official',
      apiModel: 'gemini-3.1-flash-image-preview-official',
      label: 'Nano Banana 2 Official',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: [..._wideAspectRatios, '1:4', '4:1', '1:8', '8:1'],
      resolutions: ['0.5K', '1K', '2K', '4K'],
      maxReferenceImages: 14,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gemini-3.1-flash-lite-image',
      apiModel: 'gemini-3.1-flash-lite-image',
      label: 'Nano Banana 2 Lite',
      providerId: 'apimart',
      familyId: 'apimart-nano-banana',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _wideAspectRatios,
      resolutions: ['1K'],
      maxReferenceImages: 14,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:imagen-4.0-apimart',
      apiModel: 'imagen-4.0-apimart',
      label: 'Imagen 4.0',
      providerId: 'apimart',
      familyId: 'apimart-imagen',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '4:3', '3:4', '16:9', '9:16'],
      resolutions: ['auto'],
      supportsReferenceImages: false,
      maxReferenceImages: 0,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gpt-image-1-official',
      apiModel: 'gpt-image-1-official',
      label: 'GPT Image 1 Official',
      providerId: 'apimart',
      familyId: 'apimart-gpt-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '3:2', '2:3'],
      resolutions: ['auto'],
      qualities: qualityOptions,
      maxReferenceImages: 15,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gpt-image-1.5-official',
      apiModel: 'gpt-image-1.5-official',
      label: 'GPT Image 1.5 Official',
      providerId: 'apimart',
      familyId: 'apimart-gpt-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '3:2', '2:3'],
      resolutions: ['auto'],
      qualities: qualityOptions,
      maxReferenceImages: 15,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gpt-image-2',
      apiModel: 'gpt-image-2',
      label: 'GPT Image 2',
      providerId: 'apimart',
      familyId: 'apimart-gpt-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _gpt2AspectRatios,
      resolutions: defaultResolutions,
      maxReferenceImages: 16,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:gpt-image-2-official',
      apiModel: 'gpt-image-2-official',
      label: 'GPT Image 2 Official',
      providerId: 'apimart',
      familyId: 'apimart-gpt-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _gpt2AspectRatios,
      resolutions: defaultResolutions,
      qualities: qualityOptions,
      maxReferenceImages: 16,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:doubao-seedance-4-0',
      apiModel: 'doubao-seedance-4-0',
      label: 'Seedream 4.0',
      providerId: 'apimart',
      familyId: 'apimart-seedream',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _seedreamAspectRatios,
      resolutions: ['1K', '2K', '4K'],
      maxReferenceImages: 10,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:doubao-seedance-4-5',
      apiModel: 'doubao-seedance-4-5',
      label: 'Seedream 4.5',
      providerId: 'apimart',
      familyId: 'apimart-seedream',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _seedreamAspectRatios,
      resolutions: ['2K', '4K'],
      maxReferenceImages: 10,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:doubao-seedream-5-0-lite',
      apiModel: 'doubao-seedream-5-0-lite',
      label: 'Seedream 5.0 Lite',
      providerId: 'apimart',
      familyId: 'apimart-seedream',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _seedream5LiteAspectRatios,
      resolutions: ['2K', '3K'],
      maxReferenceImages: 10,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:doubao-seedream-5-0-pro',
      apiModel: 'doubao-seedream-5-0-pro',
      label: 'Seedream 5.0 Pro',
      providerId: 'apimart',
      familyId: 'apimart-seedream',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: _seedreamAspectRatios,
      resolutions: ['1K', '2K'],
      maxReferenceImages: 10,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:qwen-image-2.0',
      apiModel: 'qwen-image-2.0',
      label: 'Qwen Image 2.0',
      providerId: 'apimart',
      familyId: 'apimart-qwen-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3'],
      resolutions: ['1K', '2K'],
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:qwen-image-2.0-pro',
      apiModel: 'qwen-image-2.0-pro',
      label: 'Qwen Image 2.0 Pro',
      providerId: 'apimart',
      familyId: 'apimart-qwen-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3'],
      resolutions: ['1K', '2K'],
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:z-image-turbo',
      apiModel: 'z-image-turbo',
      label: 'Z-Image Turbo',
      providerId: 'apimart',
      familyId: 'apimart-z-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3'],
      resolutions: ['1K', '2K'],
      supportsReferenceImages: false,
      maxReferenceImages: 0,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:grok-imagine-1.5-apimart',
      apiModel: 'grok-imagine-1.5-apimart',
      referenceApiModel: 'grok-imagine-1.5-edit-apimart',
      label: 'Grok Imagine 1.5',
      providerId: 'apimart',
      familyId: 'apimart-grok-imagine',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartGrok,
      aspectRatios: ['1:1', '16:9', '9:16', '3:2', '2:3'],
      resolutions: ['auto'],
      maxReferenceImages: 10,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:wan2.7-image',
      apiModel: 'wan2.7-image',
      label: 'Wan 2.7 Image',
      providerId: 'apimart',
      familyId: 'apimart-wan-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'],
      resolutions: ['1K', '2K'],
      maxReferenceImages: 9,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:wan2.7-image-pro',
      apiModel: 'wan2.7-image-pro',
      label: 'Wan 2.7 Image Pro',
      providerId: 'apimart',
      familyId: 'apimart-wan-image',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartImages,
      aspectRatios: ['1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'],
      resolutions: ['1K', '2K', '4K'],
      maxReferenceImages: 9,
    ),
    ImageGenerationModelDescriptor(
      id: 'apimart:midjourney',
      apiModel: 'midjourney',
      label: 'Midjourney',
      providerId: 'apimart',
      familyId: 'apimart-midjourney',
      protocol: ImageGenerationProviderProtocol.apiMart,
      route: ImageGenerationApiRoute.apiMartMidjourney,
      aspectRatios: _wideAspectRatios,
      resolutions: ['auto'],
      maxReferenceImages: 16,
    ),
  ];

  static const providers = <ImageGenerationModelProvider>[
    ImageGenerationModelProvider(
      id: 'gemini',
      label: 'Gemini',
      families: [
        ImageGenerationModelFamily(
          id: 'gemini-image',
          label: 'Gemini Image',
          modelIds: ['gemini-3-pro-image', 'gemini-3.1-flash-image'],
        ),
      ],
    ),
    ImageGenerationModelProvider(
      id: 'grsai',
      label: 'GRSai',
      families: [
        ImageGenerationModelFamily(
          id: 'nano-banana',
          label: 'Nano Banana',
          modelIds: [
            'nano-banana',
            'nano-banana-2',
            'nano-banana-fast',
            'nano-banana-pro',
            'nano-banana-pro-4k-vip',
            'nano-banana-pro-cl',
            'nano-banana-pro-vip',
            'nano-banana-pro-vt',
          ],
        ),
        ImageGenerationModelFamily(
          id: 'gpt-image',
          label: 'GPT Image',
          modelIds: ['gpt-image-2', 'gpt-image-2-vip'],
        ),
      ],
    ),
    ImageGenerationModelProvider(
      id: 'apimart',
      label: 'APIMart',
      families: [
        ImageGenerationModelFamily(
          id: 'apimart-nano-banana',
          label: 'Nano Banana',
          modelIds: [
            'apimart:gemini-2.5-flash-image-preview',
            'apimart:gemini-2.5-flash-image-preview-official',
            'apimart:gemini-3-pro-image-preview',
            'apimart:gemini-3-pro-image-preview-official',
            'apimart:gemini-3.1-flash-image-preview',
            'apimart:gemini-3.1-flash-image-preview-official',
            'apimart:gemini-3.1-flash-lite-image',
          ],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-imagen',
          label: 'Imagen',
          modelIds: ['apimart:imagen-4.0-apimart'],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-gpt-image',
          label: 'GPT Image',
          modelIds: [
            'apimart:gpt-image-1-official',
            'apimart:gpt-image-1.5-official',
            'apimart:gpt-image-2',
            'apimart:gpt-image-2-official',
          ],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-seedream',
          label: 'Seedream',
          modelIds: [
            'apimart:doubao-seedance-4-0',
            'apimart:doubao-seedance-4-5',
            'apimart:doubao-seedream-5-0-lite',
            'apimart:doubao-seedream-5-0-pro',
          ],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-qwen-image',
          label: 'Qwen Image',
          modelIds: ['apimart:qwen-image-2.0', 'apimart:qwen-image-2.0-pro'],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-z-image',
          label: 'Z-Image',
          modelIds: ['apimart:z-image-turbo'],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-grok-imagine',
          label: 'Grok Imagine',
          modelIds: ['apimart:grok-imagine-1.5-apimart'],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-wan-image',
          label: 'Wan Image',
          modelIds: ['apimart:wan2.7-image', 'apimart:wan2.7-image-pro'],
        ),
        ImageGenerationModelFamily(
          id: 'apimart-midjourney',
          label: 'Midjourney',
          modelIds: ['apimart:midjourney'],
        ),
      ],
    ),
  ];

  static final Map<String, ImageGenerationModelDescriptor> _byId = {
    for (final model in models) model.id: model,
  };

  static final Map<String, ImageGenerationModelProvider> _providerById = {
    for (final provider in providers) provider.id: provider,
  };

  static ImageGenerationModelDescriptor? descriptorFor(String modelId) {
    return _byId[modelId.trim()];
  }

  static ImageGenerationModelProvider? providerFor(String modelId) {
    final descriptor = descriptorFor(modelId);
    return descriptor == null ? null : _providerById[descriptor.providerId];
  }

  static String labelFor(String modelId) {
    return descriptorFor(modelId)?.label ?? modelId;
  }

  static String providerLabelFor(String modelId) {
    return providerFor(modelId)?.label ?? '图片生成';
  }

  static bool isApiMartModel(String modelId) {
    return descriptorFor(modelId)?.isApiMart ?? false;
  }

  static String apiModelFor(String modelId, {required bool hasReferences}) {
    final descriptor = descriptorFor(modelId);
    if (descriptor == null) {
      return modelId.trim();
    }
    if (hasReferences && descriptor.referenceApiModel != null) {
      return descriptor.referenceApiModel!;
    }
    return descriptor.apiModel;
  }

  static List<String> resolutionsFor(String modelId, String aspectRatio) {
    final descriptor = descriptorFor(modelId);
    if (descriptor == null) {
      return defaultResolutions;
    }
    final normalizedAspectRatio = aspectRatio.trim().toLowerCase();
    if (descriptor.isApiMart &&
        descriptor.apiModel.startsWith('gpt-image-2') &&
        !_gptImage2FourKAspectRatios.contains(normalizedAspectRatio)) {
      return [
        for (final resolution in descriptor.resolutions)
          if (resolution.toUpperCase() != '4K') resolution,
      ];
    }
    return descriptor.resolutions;
  }
}
