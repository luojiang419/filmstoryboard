import 'dart:async';
import 'dart:io';

import '../../settings/domain/video_generation_api_config.dart';
import '../data/kling_cli_models.dart';
import '../data/kling_cli_service.dart';
import '../data/libtv_cli_models.dart';
import '../data/libtv_cli_service.dart';
import '../data/minimax_video_api_service.dart';
import '../data/video_generation_repository.dart';
import '../domain/video_generation_models.dart';

typedef VideoResultDownload = Future<File> Function(String url, File target);
typedef VideoGenerationDelay = Future<void> Function(Duration duration);

class VideoGenerationSubmission {
  const VideoGenerationSubmission({
    required this.task,
    required this.sourceImagePath,
    this.referenceImagePaths = const [],
    this.scriptName = '',
    required this.outputFile,
  });

  final VideoGenerationTask task;
  final String sourceImagePath;
  final List<String> referenceImagePaths;
  final String scriptName;
  final File outputFile;
}

class VideoGenerationTaskService {
  VideoGenerationTaskService({
    required VideoGenerationRepository repository,
    required KlingCliService cliService,
    VideoResultDownload? download,
    VideoGenerationDelay? delay,
    void Function(VideoGenerationTask task)? onTaskChanged,
    this.pollInterval = const Duration(seconds: 3),
    Duration? pollTimeout,
    VideoGenerationApiConfig? videoApiConfig,
    MiniMaxVideoApiService? videoApiService,
    LibTvCliService? libTvCliService,
  }) : _repository = repository,
       _cliService = cliService,
       _download = download ?? const KlingResultDownloader().download,
       _delay = delay ?? Future<void>.delayed,
       _onTaskChanged = onTaskChanged,
       _videoApiConfig = videoApiConfig,
       _videoApiService = videoApiService ?? MiniMaxVideoApiService(),
       _libTvCliService = libTvCliService ?? const LibTvCliService(),
       pollTimeout =
           pollTimeout ??
           (videoApiConfig?.isHttpApi == true
               ? localVideoApiPollTimeout
               : defaultVideoGenerationPollTimeout);

  final VideoGenerationRepository _repository;
  final KlingCliService _cliService;
  final VideoResultDownload _download;
  final VideoGenerationDelay _delay;
  final void Function(VideoGenerationTask task)? _onTaskChanged;
  final VideoGenerationApiConfig? _videoApiConfig;
  final MiniMaxVideoApiService _videoApiService;
  final LibTvCliService _libTvCliService;
  final Duration pollInterval;
  final Duration pollTimeout;

  static const missingVideoApiTaskRetryMessage = 'MiniMax 视频任务不存在，已自动重新提交。';

  static bool shouldRetryMissingVideoApiTask(VideoGenerationTask task) =>
      task.status == VideoGenerationTaskStatus.failed &&
      task.errorMessage == missingVideoApiTaskRetryMessage;

  Future<VideoGenerationTask> submitAndTrack(
    VideoGenerationSubmission submission, {
    bool Function()? isCanceled,
  }) async {
    final task = submission.task;
    if (task.status != VideoGenerationTaskStatus.draft ||
        task.generationId.isNotEmpty) {
      throw const KlingCliException('该视频生成任务已经提交，禁止重复扣费提交。');
    }
    if (!File(submission.sourceImagePath).existsSync()) {
      throw const KlingCliException('缺少生成首帧图，当前镜头不可生成视频。');
    }
    final videoApiConfig = _videoApiConfig;
    if (videoApiConfig?.isLibTvCli == true) {
      return _submitAndTrackLibTv(submission, isCanceled: isCanceled);
    }
    if (videoApiConfig != null &&
        videoApiConfig.isHttpApi &&
        videoApiConfig.baseUrl.trim().isNotEmpty) {
      return _submitAndTrackVideoApi(
        submission,
        videoApiConfig,
        isCanceled: isCanceled,
      );
    }
    KlingAccount? account;
    try {
      account = await _cliService.account();
    } catch (_) {
      // 账户摘要不可用不应伪装成付费提交失败；提交错误仍由 CLI 原样返回。
    }
    var current = task.copyWith(
      creditsBefore: account?.availableCredits,
      status: VideoGenerationTaskStatus.submitting,
      localPath: submission.outputFile.path,
      updatedAt: DateTime.now().toUtc(),
    );
    _upsertTask(current);
    if (isCanceled?.call() == true) {
      current = current.copyWith(
        status: VideoGenerationTaskStatus.canceled,
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
      _upsertTask(current);
      return current;
    }
    try {
      final submissionResult = await _cliService.submitImageToVideo(
        model: current.model,
        imagePath: submission.sourceImagePath,
        referenceImagePaths: submission.referenceImagePaths,
        parameters: {
          ...current.parameters,
          'duration': '${current.durationSeconds}',
        },
        prompt: current.prompt,
      );
      current = current.copyWith(
        generationId: submissionResult.generationId,
        status: VideoGenerationTaskStatus.queued,
        updatedAt: DateTime.now().toUtc(),
      );
      _upsertTask(current);
      return pollExisting(
        current,
        outputFile: submission.outputFile,
        isCanceled: isCanceled,
      );
    } catch (error) {
      current = current.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: '$error',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
      _upsertTask(current);
      return current;
    }
  }

  Future<VideoGenerationTask> _submitAndTrackLibTv(
    VideoGenerationSubmission submission, {
    bool Function()? isCanceled,
  }) async {
    var current = submission.task.copyWith(
      status: VideoGenerationTaskStatus.submitting,
      localPath: submission.outputFile.path,
      updatedAt: DateTime.now().toUtc(),
    );
    _upsertTask(current);
    if (isCanceled?.call() == true) {
      current = _canceledTask(current);
      _upsertTask(current);
      return current;
    }
    try {
      final result = await _libTvCliService.generateImageToVideo(
        scriptId: current.scriptId,
        scriptName: submission.scriptName,
        taskId: current.id,
        prompt: current.prompt,
        sourceImagePath: submission.sourceImagePath,
        referenceImagePaths: submission.referenceImagePaths,
        modelName: current.model.trim().isEmpty
            ? LibTvCliService.seedance20ModelName
            : current.model.trim(),
        durationSeconds: current.durationSeconds,
        parameters: current.parameters,
        isCanceled: isCanceled,
      );
      if (isCanceled?.call() == true) {
        current = _canceledTask(current);
        _upsertTask(current);
        return current;
      }
      final file = await _download(result.videoUrl, submission.outputFile);
      current = current.copyWith(
        generationId: result.taskId.isNotEmpty ? result.taskId : result.nodeKey,
        parameters: {
          ...current.parameters,
          libTvProjectUuidParameter: result.projectUuid,
          libTvNodeKeyParameter: result.nodeKey,
        },
        status: VideoGenerationTaskStatus.completed,
        resultUrl: result.videoUrl,
        resultWithoutWatermarkUrl: result.videoUrl,
        localPath: file.path,
        usedWatermarkedFallback: false,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
    } on LibTvGenerationCanceledException {
      current = _canceledTask(current);
    } catch (error) {
      current = current.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: '$error',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
    }
    _upsertTask(current);
    return current;
  }

  Future<VideoGenerationTask> _submitAndTrackVideoApi(
    VideoGenerationSubmission submission,
    VideoGenerationApiConfig config, {
    bool Function()? isCanceled,
  }) async {
    final current = await _submitVideoApiOnly(
      submission,
      config,
      isCanceled: isCanceled,
    );
    if (current.status.isTerminal) return current;
    return _pollExistingVideoApi(
      current,
      config,
      outputFile: submission.outputFile,
      isCanceled: isCanceled,
    );
  }

  Future<VideoGenerationTask> _submitVideoApiOnly(
    VideoGenerationSubmission submission,
    VideoGenerationApiConfig config, {
    bool Function()? isCanceled,
  }) async {
    var current = submission.task.copyWith(
      status: VideoGenerationTaskStatus.submitting,
      localPath: submission.outputFile.path,
      updatedAt: DateTime.now().toUtc(),
    );
    _upsertTask(current);
    if (isCanceled?.call() == true) {
      current = _canceledTask(current);
      _upsertTask(current);
      return current;
    }
    try {
      final submissionResult = await _videoApiService.submitImageToVideo(
        config: config,
        imagePath: submission.sourceImagePath,
        referenceImagePaths: submission.referenceImagePaths,
        parameters: {
          ...current.parameters,
          'duration': '${current.durationSeconds}',
        },
        prompt: current.prompt,
      );
      current = current.copyWith(
        generationId: submissionResult.generationId,
        status: VideoGenerationTaskStatus.queued,
        updatedAt: DateTime.now().toUtc(),
      );
      _upsertTask(current);
      return current;
    } catch (error) {
      current = current.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: '$error',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
      _upsertTask(current);
      return current;
    }
  }

  Future<VideoGenerationTask> _pollExistingVideoApi(
    VideoGenerationTask task,
    VideoGenerationApiConfig config, {
    required File outputFile,
    bool Function()? isCanceled,
  }) async {
    var current = task;
    final deadline = DateTime.now().toUtc().add(pollTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      if (isCanceled?.call() == true) {
        await _cancelRemoteVideoApiTask(config, current.generationId);
        current = _canceledTask(current);
        _upsertTask(current);
        return current;
      }
      try {
        final result = await _videoApiService.queryTask(
          config: config,
          generationId: current.generationId,
        );
        current = await _applyVideoApiQueryResult(current, result, outputFile);
        _upsertTask(current);
        if (current.status.isTerminal) return current;
      } on MiniMaxVideoApiTaskNotFoundException {
        current = _markMissingVideoApiTaskForRetry(current);
        _upsertTask(current);
        return current;
      } catch (error) {
        if (_isMissingVideoApiTaskError(error)) {
          current = _markMissingVideoApiTaskForRetry(current);
          _upsertTask(current);
          return current;
        }
        current = current.copyWith(
          errorMessage: '$error',
          updatedAt: DateTime.now().toUtc(),
        );
        _upsertTask(current);
      }
      await _delay(pollInterval);
    }
    current = current.copyWith(
      status: VideoGenerationTaskStatus.timedOut,
      errorMessage: '查询超过 15 分钟，可稍后继续查询；不会自动重新提交。',
      updatedAt: DateTime.now().toUtc(),
    );
    _upsertTask(current);
    return current;
  }

  VideoGenerationTask _markMissingVideoApiTaskForRetry(
    VideoGenerationTask task,
  ) => task.copyWith(
    status: VideoGenerationTaskStatus.failed,
    errorMessage: missingVideoApiTaskRetryMessage,
    updatedAt: DateTime.now().toUtc(),
    completedAt: DateTime.now().toUtc(),
  );

  bool _isMissingVideoApiTaskError(Object error) =>
      error is MiniMaxVideoApiTaskNotFoundException ||
      '$error'.contains('MiniMax 视频任务不存在') ||
      '$error'.contains('任务不存在');

  Future<VideoGenerationTask> _applyVideoApiQueryResult(
    VideoGenerationTask task,
    MiniMaxVideoApiTaskResult result,
    File outputFile,
  ) async {
    final now = DateTime.now().toUtc();
    if (result.status != VideoGenerationTaskStatus.completed) {
      return task.copyWith(
        status: result.status,
        errorMessage: result.errorMessage,
        updatedAt: now,
        completedAt: result.status.isTerminal ? now : null,
      );
    }
    if (result.url.trim().isEmpty) {
      return task.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: 'MiniMax 视频任务已完成，但响应中没有可下载的视频地址。',
        updatedAt: now,
        completedAt: now,
      );
    }
    try {
      final file = await _download(result.url, outputFile);
      return task.copyWith(
        status: result.status,
        resultUrl: result.url,
        resultWithoutWatermarkUrl: result.url,
        localPath: file.path,
        usedWatermarkedFallback: false,
        errorMessage: '',
        updatedAt: now,
        completedAt: now,
      );
    } catch (error) {
      return task.copyWith(
        status: VideoGenerationTaskStatus.failed,
        resultUrl: result.url,
        errorMessage: '视频生成完成，但下载失败：$error',
        updatedAt: now,
        completedAt: now,
      );
    }
  }

  Future<VideoGenerationTask> pollExisting(
    VideoGenerationTask task, {
    required File outputFile,
    bool Function()? isCanceled,
  }) async {
    if (task.generationId.isEmpty) {
      throw const KlingCliException('缺少 generationId，不能恢复查询。');
    }
    final videoApiConfig = _videoApiConfig;
    if (videoApiConfig?.isLibTvCli == true) {
      return _resumeInterruptedLibTvTask(task, outputFile);
    }
    if (videoApiConfig != null &&
        videoApiConfig.isHttpApi &&
        videoApiConfig.baseUrl.trim().isNotEmpty) {
      return _pollExistingVideoApi(
        task,
        videoApiConfig,
        outputFile: outputFile,
        isCanceled: isCanceled,
      );
    }
    var current = task;
    final deadline = DateTime.now().toUtc().add(pollTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      if (isCanceled?.call() == true) {
        current = current.copyWith(
          status: VideoGenerationTaskStatus.canceled,
          updatedAt: DateTime.now().toUtc(),
          completedAt: DateTime.now().toUtc(),
        );
        _upsertTask(current);
        return current;
      }
      try {
        final result = await _cliService.queryTask(current.generationId);
        current = await _applyQueryResult(current, result, outputFile);
        _upsertTask(current);
        if (current.status.isTerminal) return current;
        if (current.status == VideoGenerationTaskStatus.timedOut) {
          return current;
        }
      } catch (error) {
        current = current.copyWith(
          errorMessage: '$error',
          updatedAt: DateTime.now().toUtc(),
        );
        _upsertTask(current);
      }
      await _delay(pollInterval);
    }
    current = current.copyWith(
      status: VideoGenerationTaskStatus.timedOut,
      errorMessage: '查询超过 15 分钟，可稍后继续查询；不会自动重新提交。',
      updatedAt: DateTime.now().toUtc(),
    );
    _upsertTask(current);
    return current;
  }

  Future<VideoGenerationTask> _resumeInterruptedLibTvTask(
    VideoGenerationTask task,
    File outputFile,
  ) async {
    final resultUrl = task.resultWithoutWatermarkUrl.trim().isNotEmpty
        ? task.resultWithoutWatermarkUrl.trim()
        : task.resultUrl.trim();
    VideoGenerationTask current;
    if (resultUrl.isNotEmpty) {
      try {
        final file = await _download(resultUrl, outputFile);
        current = task.copyWith(
          status: VideoGenerationTaskStatus.completed,
          localPath: file.path,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
          completedAt: DateTime.now().toUtc(),
        );
      } catch (error) {
        current = task.copyWith(
          status: VideoGenerationTaskStatus.failed,
          errorMessage: 'LibTV 视频结果恢复下载失败：$error',
          updatedAt: DateTime.now().toUtc(),
          completedAt: DateTime.now().toUtc(),
        );
      }
    } else {
      current = task.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: 'LibTV CLI 同步生成因应用退出而中断；请在对应 LibTV 画布检查节点后手动重试。',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
    }
    _upsertTask(current);
    return current;
  }

  Future<List<VideoGenerationTask>> submitBatch(
    List<VideoGenerationSubmission> submissions, {
    bool Function()? isCanceled,
    bool Function(String taskId)? isTaskCanceled,
    int? concurrency,
  }) {
    final videoApiConfig = _videoApiConfig;
    if (videoApiConfig?.isLibTvCli == true) {
      return _runWithConcurrency(
        submissions,
        concurrency ?? libTvCliBatchConcurrency,
        (submission) => submitAndTrack(
          submission,
          isCanceled: () =>
              isCanceled?.call() == true ||
              isTaskCanceled?.call(submission.task.id) == true,
        ),
      );
    }
    if (videoApiConfig != null &&
        videoApiConfig.isHttpApi &&
        videoApiConfig.baseUrl.trim().isNotEmpty) {
      return _submitVideoApiBatchAndTrack(
        submissions,
        videoApiConfig,
        isCanceled: isCanceled,
        isTaskCanceled: isTaskCanceled,
      );
    }
    return _runWithConcurrency(
      submissions,
      concurrency ?? defaultVideoGenerationBatchConcurrency,
      (submission) => submitAndTrack(
        submission,
        isCanceled: () =>
            isCanceled?.call() == true ||
            isTaskCanceled?.call(submission.task.id) == true,
      ),
    );
  }

  Future<List<VideoGenerationTask>> _submitVideoApiBatchAndTrack(
    List<VideoGenerationSubmission> submissions,
    VideoGenerationApiConfig config, {
    bool Function()? isCanceled,
    bool Function(String taskId)? isTaskCanceled,
  }) async {
    final submitted = <({VideoGenerationTask task, File outputFile})>[];
    for (final submission in submissions) {
      final current = await _submitVideoApiOnly(
        submission,
        config,
        isCanceled: () =>
            isCanceled?.call() == true ||
            isTaskCanceled?.call(submission.task.id) == true,
      );
      submitted.add((task: current, outputFile: submission.outputFile));
    }
    if (submitted.isEmpty) return const [];
    return _runWithConcurrency(submitted, submitted.length, (entry) {
      final task = entry.task;
      if (task.status.isTerminal || task.generationId.trim().isEmpty) {
        return Future.value(task);
      }
      return _pollExistingVideoApi(
        task,
        config,
        outputFile: entry.outputFile,
        isCanceled: () =>
            isCanceled?.call() == true || isTaskCanceled?.call(task.id) == true,
      );
    });
  }

  Future<List<VideoGenerationTask>> resumePending({
    required File Function(VideoGenerationTask task) outputForTask,
    bool Function()? isCanceled,
    bool Function(String taskId)? isTaskCanceled,
    bool includeTimedOut = true,
    int? concurrency,
  }) {
    final tasks = _repository.listRecoverableTasks(
      includeTimedOut: includeTimedOut,
    );
    return _runWithConcurrency(
      tasks,
      concurrency ?? defaultVideoGenerationBatchConcurrency,
      (task) => pollExisting(
        task,
        outputFile: outputForTask(task),
        isCanceled: () =>
            isCanceled?.call() == true || isTaskCanceled?.call(task.id) == true,
      ),
    );
  }

  void _upsertTask(VideoGenerationTask task) {
    _repository.upsertTask(task);
    _onTaskChanged?.call(task);
  }

  VideoGenerationTask _canceledTask(VideoGenerationTask task) => task.copyWith(
    status: VideoGenerationTaskStatus.canceled,
    errorMessage: '',
    updatedAt: DateTime.now().toUtc(),
    completedAt: DateTime.now().toUtc(),
  );

  Future<void> _cancelRemoteVideoApiTask(
    VideoGenerationApiConfig config,
    String generationId,
  ) async {
    if (generationId.trim().isEmpty) return;
    try {
      await _videoApiService.cancelTask(
        config: config,
        generationId: generationId,
      );
    } catch (_) {
      // 本地取消要立即响应；远端若已完成或不可达，后续查询/恢复再处理。
    }
  }

  Future<VideoGenerationTask> _applyQueryResult(
    VideoGenerationTask task,
    KlingTaskResult result,
    File outputFile,
  ) async {
    final now = DateTime.now().toUtc();
    if (result.status != VideoGenerationTaskStatus.completed &&
        result.status != VideoGenerationTaskStatus.partialCompleted) {
      return task.copyWith(
        status: result.status == VideoGenerationTaskStatus.draft
            ? VideoGenerationTaskStatus.running
            : result.status,
        errorMessage: result.errorMessage,
        updatedAt: now,
        completedAt: result.status.isTerminal ? now : null,
      );
    }
    final preferred = result.urlWithoutWatermark.trim();
    final fallback = result.url.trim();
    final selectedUrl = preferred.isNotEmpty ? preferred : fallback;
    if (selectedUrl.isEmpty) {
      return task.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: '可灵任务已完成，但响应中没有可下载的视频地址。',
        updatedAt: now,
        completedAt: now,
      );
    }
    try {
      final file = await _download(selectedUrl, outputFile);
      int? creditsAfter;
      try {
        creditsAfter = (await _cliService.account()).availableCredits;
      } catch (_) {
        // 结果已成功落盘时，账户摘要失败不改变生成结果。
      }
      return task.copyWith(
        status: result.status,
        resultUrl: result.url,
        resultWithoutWatermarkUrl: result.urlWithoutWatermark,
        localPath: file.path,
        usedWatermarkedFallback: preferred.isEmpty,
        creditsAfter: creditsAfter,
        errorMessage: '',
        updatedAt: now,
        completedAt: now,
      );
    } catch (error) {
      return task.copyWith(
        status: VideoGenerationTaskStatus.failed,
        resultUrl: result.url,
        resultWithoutWatermarkUrl: result.urlWithoutWatermark,
        errorMessage: '视频生成完成，但下载失败：$error\n可灵官方结果 URL 仅 24 小时有效，请尽快重新下载。',
        updatedAt: now,
        completedAt: now,
      );
    }
  }

  Future<List<R>> _runWithConcurrency<T, R>(
    List<T> items,
    int concurrency,
    Future<R> Function(T item) action,
  ) async {
    if (items.isEmpty) return const [];
    final workerCount = concurrency.clamp(1, items.length);
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < items.length) {
        final index = nextIndex++;
        results[index] = await action(items[index]);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<R>();
  }
}

const localVideoApiBatchConcurrency = 1;
const libTvCliBatchConcurrency = 1;
const klingCliBatchConcurrency = 2;
const libTvProjectUuidParameter = '_libtvProjectUuid';
const libTvNodeKeyParameter = '_libtvNodeKey';
const defaultVideoGenerationBatchConcurrency = klingCliBatchConcurrency;
const defaultVideoGenerationPollTimeout = Duration(minutes: 15);
const localVideoApiPollTimeout = Duration(hours: 2);
