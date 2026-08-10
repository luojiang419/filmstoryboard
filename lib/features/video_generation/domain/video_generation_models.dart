enum VideoPromptMode { klingOptimized, h3Optimized, original, edited }

enum VideoGenerationTaskStatus {
  draft,
  submitting,
  queued,
  running,
  completed,
  partialCompleted,
  failed,
  canceled,
  timedOut;

  bool get isTerminal => switch (this) {
    completed || partialCompleted || failed || canceled => true,
    draft || submitting || queued || running || timedOut => false,
  };

  static VideoGenerationTaskStatus fromStorage(Object? value) {
    final normalized = '$value'
        .trim()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .toLowerCase();
    return switch (normalized) {
      'submitting' => submitting,
      'queued' || 'pending' => queued,
      'running' || 'processing' => running,
      'completed' || 'succeed' || 'succeeded' || 'success' => completed,
      'partialcompleted' => partialCompleted,
      'failed' || 'error' => failed,
      'canceled' || 'cancelled' => canceled,
      'timedout' || 'timeout' => timedOut,
      _ => draft,
    };
  }
}

class VideoGenerationProfile {
  const VideoGenerationProfile({
    required this.scriptId,
    this.model = '',
    this.parameters = const {},
    this.promptMode = VideoPromptMode.klingOptimized,
    this.preferWithoutWatermark = true,
    this.directoryName = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String scriptId;
  final String model;
  final Map<String, String> parameters;
  final VideoPromptMode promptMode;
  final bool preferWithoutWatermark;
  final String directoryName;
  final DateTime createdAt;
  final DateTime updatedAt;

  VideoGenerationProfile copyWith({
    String? model,
    Map<String, String>? parameters,
    VideoPromptMode? promptMode,
    bool? preferWithoutWatermark,
    String? directoryName,
    DateTime? updatedAt,
  }) => VideoGenerationProfile(
    scriptId: scriptId,
    model: model ?? this.model,
    parameters: parameters ?? this.parameters,
    promptMode: promptMode ?? this.promptMode,
    preferWithoutWatermark:
        preferWithoutWatermark ?? this.preferWithoutWatermark,
    directoryName: directoryName ?? this.directoryName,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class VideoGenerationDraft {
  const VideoGenerationDraft({
    required this.id,
    required this.scriptId,
    required this.shotId,
    this.sourcePrompt = '',
    this.klingPrompt = '',
    this.h3Prompt = '',
    this.editedPrompt = '',
    this.promptMode = VideoPromptMode.klingOptimized,
    required this.updatedAt,
  });

  final String id;
  final String scriptId;
  final String shotId;
  final String sourcePrompt;
  final String klingPrompt;
  final String h3Prompt;
  final String editedPrompt;
  final VideoPromptMode promptMode;
  final DateTime updatedAt;

  String get selectedPrompt => switch (promptMode) {
    VideoPromptMode.original => sourcePrompt,
    VideoPromptMode.edited => editedPrompt,
    VideoPromptMode.klingOptimized => klingPrompt,
    VideoPromptMode.h3Optimized => h3Prompt,
  };
}

class VideoGenerationTask {
  const VideoGenerationTask({
    required this.id,
    required this.scriptId,
    required this.shotId,
    this.generationId = '',
    required this.model,
    this.parameters = const {},
    required this.durationSeconds,
    required this.promptMode,
    required this.prompt,
    this.creditsBefore,
    this.creditsAfter,
    required this.status,
    this.resultUrl = '',
    this.resultWithoutWatermarkUrl = '',
    this.localPath = '',
    this.usedWatermarkedFallback = false,
    this.errorMessage = '',
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
  });

  final String id;
  final String scriptId;
  final String shotId;
  final String generationId;
  final String model;
  final Map<String, String> parameters;
  final int durationSeconds;
  final VideoPromptMode promptMode;
  final String prompt;
  final int? creditsBefore;
  final int? creditsAfter;
  final VideoGenerationTaskStatus status;
  final String resultUrl;
  final String resultWithoutWatermarkUrl;
  final String localPath;
  final bool usedWatermarkedFallback;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  VideoGenerationTask copyWith({
    String? generationId,
    Map<String, String>? parameters,
    int? creditsBefore,
    int? creditsAfter,
    VideoGenerationTaskStatus? status,
    String? resultUrl,
    String? resultWithoutWatermarkUrl,
    String? localPath,
    bool? usedWatermarkedFallback,
    String? errorMessage,
    DateTime? updatedAt,
    Object? completedAt = _sentinel,
  }) => VideoGenerationTask(
    id: id,
    scriptId: scriptId,
    shotId: shotId,
    generationId: generationId ?? this.generationId,
    model: model,
    parameters: parameters ?? this.parameters,
    durationSeconds: durationSeconds,
    promptMode: promptMode,
    prompt: prompt,
    creditsBefore: creditsBefore ?? this.creditsBefore,
    creditsAfter: creditsAfter ?? this.creditsAfter,
    status: status ?? this.status,
    resultUrl: resultUrl ?? this.resultUrl,
    resultWithoutWatermarkUrl:
        resultWithoutWatermarkUrl ?? this.resultWithoutWatermarkUrl,
    localPath: localPath ?? this.localPath,
    usedWatermarkedFallback:
        usedWatermarkedFallback ?? this.usedWatermarkedFallback,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: identical(completedAt, _sentinel)
        ? this.completedAt
        : completedAt as DateTime?,
  );
}

const _sentinel = Object();
