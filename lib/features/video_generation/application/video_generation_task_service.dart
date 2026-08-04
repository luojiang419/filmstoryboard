import 'dart:async';
import 'dart:io';

import '../data/kling_cli_models.dart';
import '../data/kling_cli_service.dart';
import '../data/video_generation_repository.dart';
import '../domain/video_generation_models.dart';

typedef VideoResultDownload = Future<File> Function(String url, File target);
typedef VideoGenerationDelay = Future<void> Function(Duration duration);

class VideoGenerationSubmission {
  const VideoGenerationSubmission({
    required this.task,
    required this.sourceImagePath,
    this.tailImagePath = '',
    required this.outputFile,
  });

  final VideoGenerationTask task;
  final String sourceImagePath;
  final String tailImagePath;
  final File outputFile;
}

class VideoGenerationTaskService {
  VideoGenerationTaskService({
    required VideoGenerationRepository repository,
    required KlingCliService cliService,
    VideoResultDownload? download,
    VideoGenerationDelay? delay,
    this.pollInterval = const Duration(seconds: 3),
    this.pollTimeout = const Duration(minutes: 15),
  }) : _repository = repository,
       _cliService = cliService,
       _download = download ?? const KlingResultDownloader().download,
       _delay = delay ?? Future<void>.delayed;

  final VideoGenerationRepository _repository;
  final KlingCliService _cliService;
  final VideoResultDownload _download;
  final VideoGenerationDelay _delay;
  final Duration pollInterval;
  final Duration pollTimeout;

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
    if (submission.tailImagePath.isNotEmpty &&
        !File(submission.tailImagePath).existsSync()) {
      throw const KlingCliException('首尾帧模式缺少尾帧图，已阻止提交。');
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
    _repository.upsertTask(current);
    if (isCanceled?.call() == true) {
      current = current.copyWith(
        status: VideoGenerationTaskStatus.canceled,
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
      _repository.upsertTask(current);
      return current;
    }
    try {
      final submissionResult = await _cliService.submitImageToVideo(
        model: current.model,
        imagePath: submission.sourceImagePath,
        tailImagePath: submission.tailImagePath,
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
      _repository.upsertTask(current);
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
      _repository.upsertTask(current);
      return current;
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
    var current = task;
    final deadline = DateTime.now().toUtc().add(pollTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      if (isCanceled?.call() == true) {
        current = current.copyWith(
          status: VideoGenerationTaskStatus.canceled,
          updatedAt: DateTime.now().toUtc(),
          completedAt: DateTime.now().toUtc(),
        );
        _repository.upsertTask(current);
        return current;
      }
      try {
        final result = await _cliService.queryTask(current.generationId);
        current = await _applyQueryResult(current, result, outputFile);
        _repository.upsertTask(current);
        if (current.status.isTerminal) return current;
        if (current.status == VideoGenerationTaskStatus.timedOut) {
          return current;
        }
      } catch (error) {
        current = current.copyWith(
          errorMessage: '$error',
          updatedAt: DateTime.now().toUtc(),
        );
        _repository.upsertTask(current);
      }
      await _delay(pollInterval);
    }
    current = current.copyWith(
      status: VideoGenerationTaskStatus.timedOut,
      errorMessage: '查询超过 15 分钟，可稍后继续查询；不会自动重新提交。',
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertTask(current);
    return current;
  }

  Future<List<VideoGenerationTask>> submitBatch(
    List<VideoGenerationSubmission> submissions, {
    bool Function()? isCanceled,
  }) => _runWithConcurrency(
    submissions,
    2,
    (submission) => submitAndTrack(submission, isCanceled: isCanceled),
  );

  Future<List<VideoGenerationTask>> resumePending({
    required File Function(VideoGenerationTask task) outputForTask,
    bool Function()? isCanceled,
  }) {
    final tasks = _repository.listRecoverableTasks();
    return _runWithConcurrency(
      tasks,
      2,
      (task) => pollExisting(
        task,
        outputFile: outputForTask(task),
        isCanceled: isCanceled,
      ),
    );
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
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < items.length) {
        final index = nextIndex++;
        results[index] = await action(items[index]);
      }
    }

    await Future.wait(
      List.generate(items.length.clamp(1, concurrency), (_) => worker()),
    );
    return results.cast<R>();
  }
}
