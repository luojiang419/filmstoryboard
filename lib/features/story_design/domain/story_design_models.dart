class StoryDesignResult {
  const StoryDesignResult({
    required this.id,
    required this.path,
    required this.remoteUrl,
    required this.prompt,
    required this.model,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.createdAt,
    this.generationDuration = Duration.zero,
    this.selected = true,
  });

  final String id;
  final String path;
  final String remoteUrl;
  final String prompt;
  final String model;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final DateTime createdAt;
  final Duration generationDuration;
  final bool selected;

  StoryDesignResult copyWith({bool? selected}) {
    return StoryDesignResult(
      id: id,
      path: path,
      remoteUrl: remoteUrl,
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      imageSize: imageSize,
      quality: quality,
      createdAt: createdAt,
      generationDuration: generationDuration,
      selected: selected ?? this.selected,
    );
  }
}

enum StoryDesignGenerationTaskStatus { running, succeeded, failed }

class StoryDesignGenerationTask {
  const StoryDesignGenerationTask({
    required this.id,
    required this.prompt,
    required this.model,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.startedAt,
    this.status = StoryDesignGenerationTaskStatus.running,
    this.completedAt,
    this.errorMessage = '',
    this.resultId = '',
  });

  final String id;
  final String prompt;
  final String model;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final DateTime startedAt;
  final StoryDesignGenerationTaskStatus status;
  final DateTime? completedAt;
  final String errorMessage;
  final String resultId;

  bool get isRunning => status == StoryDesignGenerationTaskStatus.running;
  bool get isSucceeded => status == StoryDesignGenerationTaskStatus.succeeded;
  bool get isFailed => status == StoryDesignGenerationTaskStatus.failed;

  Duration elapsedAt(DateTime now) {
    final end = completedAt ?? now;
    final elapsed = end.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  StoryDesignGenerationTask copyWith({
    StoryDesignGenerationTaskStatus? status,
    DateTime? completedAt,
    String? errorMessage,
    String? resultId,
  }) {
    return StoryDesignGenerationTask(
      id: id,
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      imageSize: imageSize,
      quality: quality,
      startedAt: startedAt,
      status: status ?? this.status,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      resultId: resultId ?? this.resultId,
    );
  }
}

class StoryDesignState {
  const StoryDesignState({
    required this.prompt,
    required this.model,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.referenceImagePaths,
    required this.batchCount,
    required this.gridCount,
    required this.portraitGrid,
    required this.generationTasks,
    required this.results,
    required this.message,
  });

  factory StoryDesignState.initial({required String model}) {
    return StoryDesignState(
      prompt: '',
      model: model,
      aspectRatio: 'auto',
      imageSize: '1K',
      quality: 'auto',
      referenceImagePaths: const [],
      batchCount: 1,
      gridCount: 0,
      portraitGrid: false,
      generationTasks: const [],
      results: const [],
      message: '输入提示词后生成设计分镜图',
    );
  }

  final String prompt;
  final String model;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final List<String> referenceImagePaths;
  final int batchCount;
  final int gridCount;
  final bool portraitGrid;
  final List<StoryDesignGenerationTask> generationTasks;
  final List<StoryDesignResult> results;
  final String message;

  bool get isGenerating => generationTasks.any((task) => task.isRunning);
  int get activeTaskCount =>
      generationTasks.where((task) => task.isRunning).length;
  int get completedCount =>
      generationTasks.where((task) => task.isSucceeded).length;
  int get failedCount => generationTasks.where((task) => task.isFailed).length;
  int get totalCount => generationTasks.length;

  int get selectedResultCount =>
      results.where((result) => result.selected).length;

  List<String> get selectedResultPaths => [
    for (final result in results)
      if (result.selected) result.path,
  ];

  double? get progress {
    if (!isGenerating || totalCount <= 0) {
      return null;
    }
    return (completedCount + failedCount) / totalCount;
  }

  StoryDesignState copyWith({
    String? prompt,
    String? model,
    String? aspectRatio,
    String? imageSize,
    String? quality,
    List<String>? referenceImagePaths,
    int? batchCount,
    int? gridCount,
    bool? portraitGrid,
    List<StoryDesignGenerationTask>? generationTasks,
    List<StoryDesignResult>? results,
    String? message,
  }) {
    return StoryDesignState(
      prompt: prompt ?? this.prompt,
      model: model ?? this.model,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      imageSize: imageSize ?? this.imageSize,
      quality: quality ?? this.quality,
      referenceImagePaths: referenceImagePaths ?? this.referenceImagePaths,
      batchCount: batchCount ?? this.batchCount,
      gridCount: gridCount ?? this.gridCount,
      portraitGrid: portraitGrid ?? this.portraitGrid,
      generationTasks: generationTasks ?? this.generationTasks,
      results: results ?? this.results,
      message: message ?? this.message,
    );
  }
}
