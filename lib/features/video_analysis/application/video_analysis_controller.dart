import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/app_settings.dart';
import '../data/analysis_report_export_service.dart';
import '../data/ffmpeg_frame_extractor.dart';
import '../data/frame_quality_service.dart';
import '../data/video_analysis_repository.dart';
import '../data/video_import_service.dart';
import '../domain/video_analysis_models.dart';
import 'video_analysis_service.dart';

final videoAnalysisControllerProvider = Provider<VideoAnalysisController>(
  (ref) {
    final repository = VideoAnalysisRepository(ref.watch(appDatabaseProvider));
    final controller = VideoAnalysisController(
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      repository: repository,
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
    settingsControllerProvider,
  ],
);

enum VideoFrameFilter { all, focus, selected, pending, failed }

class VideoImportPreview {
  const VideoImportPreview({
    required this.metadata,
    required this.estimatedCandidateFrames,
  });

  final VideoMetadata metadata;
  final int estimatedCandidateFrames;
}

class VideoAnalysisState {
  const VideoAnalysisState({
    this.videos = const [],
    this.frames = const [],
    this.shots = const [],
    this.frameAnalyses = const [],
    this.marketingAnalyses = const [],
    this.summary,
    this.selectedVideoId = '',
    this.selectedFrameId = '',
    this.sceneFilter = '',
    this.shotFilterId = '',
    this.filter = VideoFrameFilter.all,
    this.isImporting = false,
    this.isAnalyzing = false,
    this.isPaused = false,
    this.isExporting = false,
    this.completedProgress = 0,
    this.totalProgress = 0,
    this.message = '',
    this.errorMessage = '',
  });

  final List<SourceVideo> videos;
  final List<VideoFrame> frames;
  final List<VideoShot> shots;
  final List<VideoFrameAnalysis> frameAnalyses;
  final List<MarketingAnalysis> marketingAnalyses;
  final VideoSummary? summary;
  final String selectedVideoId;
  final String selectedFrameId;
  final String sceneFilter;
  final String shotFilterId;
  final VideoFrameFilter filter;
  final bool isImporting;
  final bool isAnalyzing;
  final bool isPaused;
  final bool isExporting;
  final int completedProgress;
  final int totalProgress;
  final String message;
  final String errorMessage;

  SourceVideo? get selectedVideo {
    for (final video in videos) {
      if (video.id == selectedVideoId) {
        return video;
      }
    }
    return null;
  }

  VideoFrame? get selectedFrame {
    for (final frame in frames) {
      if (frame.id == selectedFrameId) {
        return frame;
      }
    }
    return null;
  }

  VideoFrameAnalysis? get selectedFrameAnalysis {
    for (final analysis in frameAnalyses) {
      if (analysis.frameId == selectedFrameId) {
        return analysis;
      }
    }
    return null;
  }

  List<String> get scenes =>
      frameAnalyses
          .map((analysis) => analysis.dimensions['scene']?.trim() ?? '')
          .where((scene) => scene.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

  List<VideoFrame> get visibleFrames {
    final analysisByFrame = {
      for (final analysis in frameAnalyses) analysis.frameId: analysis,
    };
    final shotFrameIds = shotFilterId.isEmpty
        ? null
        : shots
              .where((shot) => shot.id == shotFilterId)
              .expand((shot) => shot.frameIds)
              .toSet();
    return frames.where((frame) {
      final matchesStatus = switch (filter) {
        VideoFrameFilter.all => true,
        VideoFrameFilter.focus => frame.isFocus,
        VideoFrameFilter.selected => frame.isSelected,
        VideoFrameFilter.pending => frame.status == ProcessingStatus.pending,
        VideoFrameFilter.failed => frame.status == ProcessingStatus.failed,
      };
      final matchesScene =
          sceneFilter.isEmpty ||
          analysisByFrame[frame.id]?.dimensions['scene'] == sceneFilter;
      final matchesShot =
          shotFrameIds == null || shotFrameIds.contains(frame.id);
      return matchesStatus && matchesScene && matchesShot;
    }).toList();
  }

  bool get isBusy => isImporting || isAnalyzing || isExporting;

  VideoAnalysisState copyWith({
    List<SourceVideo>? videos,
    List<VideoFrame>? frames,
    List<VideoShot>? shots,
    List<VideoFrameAnalysis>? frameAnalyses,
    List<MarketingAnalysis>? marketingAnalyses,
    VideoSummary? summary,
    bool clearSummary = false,
    String? selectedVideoId,
    String? selectedFrameId,
    String? sceneFilter,
    String? shotFilterId,
    VideoFrameFilter? filter,
    bool? isImporting,
    bool? isAnalyzing,
    bool? isPaused,
    bool? isExporting,
    int? completedProgress,
    int? totalProgress,
    String? message,
    String? errorMessage,
  }) => VideoAnalysisState(
    videos: videos ?? this.videos,
    frames: frames ?? this.frames,
    shots: shots ?? this.shots,
    frameAnalyses: frameAnalyses ?? this.frameAnalyses,
    marketingAnalyses: marketingAnalyses ?? this.marketingAnalyses,
    summary: clearSummary ? null : summary ?? this.summary,
    selectedVideoId: selectedVideoId ?? this.selectedVideoId,
    selectedFrameId: selectedFrameId ?? this.selectedFrameId,
    sceneFilter: sceneFilter ?? this.sceneFilter,
    shotFilterId: shotFilterId ?? this.shotFilterId,
    filter: filter ?? this.filter,
    isImporting: isImporting ?? this.isImporting,
    isAnalyzing: isAnalyzing ?? this.isAnalyzing,
    isPaused: isPaused ?? this.isPaused,
    isExporting: isExporting ?? this.isExporting,
    completedProgress: completedProgress ?? this.completedProgress,
    totalProgress: totalProgress ?? this.totalProgress,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class VideoAnalysisController extends ValueNotifier<VideoAnalysisState> {
  VideoAnalysisController({
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    required VideoAnalysisRepository repository,
    VideoAnalysisService? analysisService,
    AnalysisReportExportService reportExportService =
        const AnalysisReportExportService(),
    Uuid uuid = const Uuid(),
  }) : _directories = directories,
       _settingsController = settingsController,
       _repository = repository,
       _analysisService =
           analysisService ?? VideoAnalysisService(repository: repository),
       _reportExportService = reportExportService,
       _uuid = uuid,
       super(const VideoAnalysisState()) {
    refresh();
  }

  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final VideoAnalysisRepository _repository;
  final VideoAnalysisService _analysisService;
  final AnalysisReportExportService _reportExportService;
  final Uuid _uuid;
  bool _continueAnalysis = true;
  bool _cancelAnalysisRequested = false;

  void refresh({String? selectVideoId}) {
    final videos = _repository.listSourceVideos();
    final selectedId =
        selectVideoId ??
        (videos.any((video) => video.id == value.selectedVideoId)
            ? value.selectedVideoId
            : (videos.isEmpty ? '' : videos.first.id));
    value = value.copyWith(videos: videos, selectedVideoId: selectedId);
    _loadSelectedVideo();
  }

  void selectVideo(String videoId) {
    if (value.selectedVideoId == videoId) {
      return;
    }
    value = value.copyWith(
      selectedVideoId: videoId,
      selectedFrameId: '',
      clearSummary: true,
      message: '',
      errorMessage: '',
    );
    _loadSelectedVideo();
  }

  Future<void> removeVideo(String videoId) async {
    if (value.isBusy) {
      value = value.copyWith(message: '当前正在处理视频，请完成后再移除');
      return;
    }
    final video = value.videos.where((item) => item.id == videoId).firstOrNull;
    if (video == null) {
      return;
    }

    final wasSelected = value.selectedVideoId == videoId;
    try {
      _repository.deleteSourceVideo(videoId);
      await _deleteStoredVideoArtifacts(video);
      final remaining = _repository.listSourceVideos();
      final nextSelectedId = wasSelected
          ? (remaining.isEmpty ? '' : remaining.first.id)
          : value.selectedVideoId;
      value = value.copyWith(
        videos: remaining,
        selectedVideoId: nextSelectedId,
        selectedFrameId: wasSelected ? '' : null,
        clearSummary: wasSelected,
        message: '已移除参考视频：${video.fileName}',
        errorMessage: '',
      );
      if (wasSelected) {
        _loadSelectedVideo();
      }
    } catch (error) {
      value = value.copyWith(errorMessage: '移除参考视频失败：$error');
    }
  }

  void selectFrame(String frameId) {
    value = value.copyWith(selectedFrameId: frameId);
  }

  void setFilter(VideoFrameFilter filter) {
    value = value.copyWith(filter: filter);
  }

  void setSceneFilter(String scene) {
    value = value.copyWith(sceneFilter: scene);
  }

  void setShotFilter(String shotId) {
    value = value.copyWith(shotFilterId: shotId);
  }

  Future<void> importVideo(File file) async {
    if (value.isBusy) {
      return;
    }
    value = value.copyWith(
      isImporting: true,
      isPaused: false,
      message: '正在读取视频并提取候选帧…',
      errorMessage: '',
      completedProgress: 0,
      totalProgress: 0,
    );
    final settings = _settingsController.value;
    final intervalSeconds = _effectiveIntervalSeconds(settings);
    final extractor = FfmpegFrameExtractor(
      ffmpegExecutable: settings.ffmpegExecutable,
      ffprobeExecutable: settings.ffprobeExecutable,
    );
    try {
      final result =
          await VideoImportService(
            directories: _directories,
            extractor: extractor,
          ).importVideo(
            file,
            frameInterval: Duration(
              milliseconds: (intervalSeconds * 1000).round(),
            ),
            strategy: settings.videoFrameExtractionStrategy,
            sceneThreshold: settings.videoSceneThreshold,
          );
      _repository.upsertSourceVideo(
        result.video.copyWith(status: ProcessingStatus.pending),
      );
      final qualityService = FrameQualityService(
        thresholds: FrameQualityThresholds(
          minimumSharpness: settings.videoMinimumSharpness,
        ),
      );
      final knownHashes = <String>{};
      var previousHash = '';
      var failed = 0;
      for (var index = 0; index < result.frameFiles.length; index++) {
        final extracted = result.frameFiles[index];
        try {
          final metrics = await qualityService.analyze(
            extracted.file,
            previousHash: previousHash,
          );
          final quality = qualityService.assess(
            sharpness: metrics.sharpness,
            brightness: metrics.brightness,
            perceptualHash: metrics.perceptualHash,
            knownHashes: knownHashes,
          );
          final frame = VideoFrame(
            id: _uuid.v4(),
            videoId: result.video.id,
            index: extracted.index,
            timestampMs: extracted.timestampMs,
            path: _relativePath(extracted.file),
            width: metrics.width,
            height: metrics.height,
            sharpness: metrics.sharpness,
            brightness: metrics.brightness,
            motionScore: metrics.motionScore,
            perceptualHash: metrics.perceptualHash,
            isFocus: quality.isFocus,
            isSelected: quality.isFocus,
            status: ProcessingStatus.pending,
            errorMessage: quality.errorMessage,
            createdAt: DateTime.now().toUtc(),
          );
          _repository.upsertVideoFrame(frame);
          if (!quality.isDuplicate) {
            knownHashes.add(metrics.perceptualHash);
          }
          previousHash = metrics.perceptualHash;
        } catch (error) {
          failed++;
          _repository.upsertVideoFrame(
            VideoFrame(
              id: _uuid.v4(),
              videoId: result.video.id,
              index: extracted.index,
              timestampMs: extracted.timestampMs,
              path: _relativePath(extracted.file),
              width: 0,
              height: 0,
              sharpness: 0,
              brightness: 0,
              motionScore: 0,
              perceptualHash: '',
              isFocus: false,
              isSelected: false,
              status: ProcessingStatus.failed,
              errorMessage: '$error',
              createdAt: DateTime.now().toUtc(),
            ),
          );
        }
        value = value.copyWith(
          completedProgress: index + 1,
          totalProgress: result.frameFiles.length,
        );
      }
      _repository.upsertSourceVideo(
        result.video.copyWith(
          status: failed == 0
              ? ProcessingStatus.pending
              : ProcessingStatus.partial,
          failedFrames: failed,
          successfulFrames: result.frameFiles.length - failed,
          errorMessage: failed == 0 ? '' : '$failed 个候选帧无法读取',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      value = value.copyWith(isImporting: false, message: '候选帧提取完成，可开始视觉解析');
      refresh(selectVideoId: result.video.id);
    } catch (error) {
      value = value.copyWith(
        isImporting: false,
        message: '',
        errorMessage: '视频导入失败：$error',
      );
    }
  }

  Future<VideoImportPreview?> inspectVideo(File file) async {
    if (value.isBusy) {
      return null;
    }
    value = value.copyWith(message: '正在读取视频元数据…', errorMessage: '');
    final settings = _settingsController.value;
    try {
      final metadata = await FfmpegFrameExtractor(
        ffmpegExecutable: settings.ffmpegExecutable,
        ffprobeExecutable: settings.ffprobeExecutable,
      ).probe(file);
      final estimate = _estimateCandidateFrames(metadata, settings);
      value = value.copyWith(message: '视频信息读取完成，请确认抽帧');
      return VideoImportPreview(
        metadata: metadata,
        estimatedCandidateFrames: estimate,
      );
    } catch (error) {
      value = value.copyWith(message: '', errorMessage: '无法读取视频信息：$error');
      return null;
    }
  }

  void toggleFrameSelected(String frameId) {
    final frame = value.frames.where((item) => item.id == frameId).firstOrNull;
    if (frame == null) {
      return;
    }
    _repository.upsertVideoFrame(frame.copyWith(isSelected: !frame.isSelected));
    _loadSelectedVideo(selectedFrameId: frameId);
  }

  void setFocusFrame(String frameId) {
    final frame = value.frames.where((item) => item.id == frameId).firstOrNull;
    if (frame == null) {
      return;
    }
    _repository.upsertVideoFrame(
      frame.copyWith(isFocus: true, isSelected: true),
    );
    _loadSelectedVideo(selectedFrameId: frameId);
  }

  Future<void> startAnalysis({
    bool retryFailedOnly = false,
    bool forceAll = false,
  }) async {
    final video = value.selectedVideo;
    if (video == null || value.isBusy) {
      return;
    }
    final analysisByFrame = {
      for (final analysis in value.frameAnalyses) analysis.frameId: analysis,
    };
    final frames = value.frames.where((frame) {
      if (!frame.isSelected) {
        return false;
      }
      final analysis = analysisByFrame[frame.id];
      if (retryFailedOnly) {
        return analysis?.status == ProcessingStatus.failed;
      }
      if (forceAll) {
        return true;
      }
      return analysis?.status != ProcessingStatus.completed;
    }).toList();
    if (frames.isEmpty) {
      value = value.copyWith(
        message: retryFailedOnly ? '没有需要重试的失败帧' : '没有待解析的已选帧',
      );
      return;
    }
    _continueAnalysis = true;
    _cancelAnalysisRequested = false;
    value = value.copyWith(
      isAnalyzing: true,
      isPaused: false,
      completedProgress: 0,
      totalProgress: frames.length,
      message: retryFailedOnly ? '正在重试失败帧…' : '正在逐帧解析…',
      errorMessage: '',
    );
    final result = await _analysisService.analyzeFrames(
      settings: _settingsController.value,
      video: video,
      frames: frames,
      resolveFrame: resolveFrame,
      shouldContinue: () => _continueAnalysis,
      onProgress: (completed, total) {
        value = value.copyWith(
          completedProgress: completed,
          totalProgress: total,
        );
      },
      onFrameCompleted: (_) => _loadSelectedVideo(notifyMessage: false),
    );
    _loadSelectedVideo(notifyMessage: false);
    final wasCancelled = _cancelAnalysisRequested;
    value = value.copyWith(
      isAnalyzing: false,
      isPaused: result.interrupted && !wasCancelled,
      message: result.interrupted
          ? wasCancelled
                ? '解析已取消，可重新开始处理剩余帧'
                : '解析已暂停，可继续处理剩余帧'
          : '解析完成：成功 ${result.completedCount}，失败 ${result.failedCount}',
    );
    _cancelAnalysisRequested = false;
  }

  void pauseAnalysis() {
    if (!value.isAnalyzing) {
      return;
    }
    _continueAnalysis = false;
    value = value.copyWith(message: '正在等待当前帧完成后暂停…');
  }

  void cancelAnalysis() {
    if (!value.isAnalyzing) {
      return;
    }
    _cancelAnalysisRequested = true;
    _continueAnalysis = false;
    _analysisService.visionService.cancelActiveRequests();
    value = value.copyWith(isPaused: false, message: '正在取消解析…');
  }

  void setVisibleFramesSelected(bool selected) {
    final frames = List<VideoFrame>.from(value.visibleFrames);
    for (final frame in frames) {
      _repository.upsertVideoFrame(frame.copyWith(isSelected: selected));
    }
    _loadSelectedVideo();
  }

  Future<void> resumeAnalysis() => startAnalysis();

  Future<AnalysisReportExportResult?> exportReport(
    AnalysisReportFormat format,
  ) async {
    final video = value.selectedVideo;
    final summary = value.summary;
    if (video == null || summary == null || value.isBusy) {
      return null;
    }
    value = value.copyWith(
      isExporting: true,
      message: '正在导出 ${format.label} 报告…',
      errorMessage: '',
    );
    try {
      final result = await _reportExportService.export(
        format: format,
        outputDirectory: Directory(_settingsController.value.exportDirectory),
        video: video,
        frames: value.frames,
        frameAnalyses: value.frameAnalyses,
        summary: summary,
        marketingAnalyses: value.marketingAnalyses,
      );
      value = value.copyWith(
        isExporting: false,
        message:
            '报告已导出：${result.files.map((file) => p.basename(file.path)).join('、')}',
      );
      return result;
    } catch (error) {
      value = value.copyWith(
        isExporting: false,
        message: '',
        errorMessage: '报告导出失败：$error',
      );
      return null;
    }
  }

  File resolveFrame(VideoFrame frame) {
    final normalized = frame.path.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(_directories.workspaceRoot.path, normalized),
    );
  }

  File resolveVideo(SourceVideo video) {
    final normalized = video.storedPath.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(_directories.workspaceRoot.path, normalized),
    );
  }

  Future<void> _deleteStoredVideoArtifacts(SourceVideo video) async {
    final storedFile = resolveVideo(video);
    final storedDirectory = Directory(p.dirname(storedFile.path));
    if (_isSafeChild(_directories.videos, storedFile) &&
        storedFile.existsSync()) {
      await storedFile.delete();
    }
    if (_isSafeChild(_directories.videos, storedDirectory) &&
        storedDirectory.existsSync()) {
      await storedDirectory.delete(recursive: true);
    }

    final frameDirectory = Directory(
      p.join(_directories.frames.path, p.basename(storedDirectory.path)),
    );
    if (_isSafeChild(_directories.frames, frameDirectory) &&
        frameDirectory.existsSync()) {
      await frameDirectory.delete(recursive: true);
    }
  }

  static bool _isSafeChild(Directory base, FileSystemEntity target) {
    final basePath = p.normalize(p.absolute(base.path)).toLowerCase();
    final targetPath = p.normalize(p.absolute(target.path)).toLowerCase();
    final relative = p.relative(targetPath, from: basePath);
    return relative != '.' &&
        relative != '..' &&
        !relative.startsWith('..${p.separator}') &&
        !p.isAbsolute(relative);
  }

  void _loadSelectedVideo({
    String? selectedFrameId,
    bool notifyMessage = true,
  }) {
    final videoId = value.selectedVideoId;
    if (videoId.isEmpty) {
      value = value.copyWith(
        frames: const [],
        shots: const [],
        frameAnalyses: const [],
        marketingAnalyses: const [],
        selectedFrameId: '',
        sceneFilter: '',
        shotFilterId: '',
        clearSummary: true,
      );
      return;
    }
    final frames = _repository.listVideoFrames(videoId);
    final selectedId =
        selectedFrameId ??
        (frames.any((frame) => frame.id == value.selectedFrameId)
            ? value.selectedFrameId
            : (frames.isEmpty ? '' : frames.first.id));
    value = value.copyWith(
      videos: _repository.listSourceVideos(),
      frames: frames,
      shots: _repository.listVideoShots(videoId),
      frameAnalyses: _repository.listVideoFrameAnalyses(videoId),
      marketingAnalyses: _repository.listMarketingAnalyses(videoId),
      summary: _repository.getVideoSummary(videoId),
      clearSummary: _repository.getVideoSummary(videoId) == null,
      selectedFrameId: selectedId,
      message: notifyMessage ? value.message : null,
    );
  }

  String _relativePath(File file) => p
      .relative(
        file.absolute.path,
        from: _directories.workspaceRoot.absolute.path,
      )
      .replaceAll('\\', '/');

  static double _effectiveIntervalSeconds(AppSettings settings) {
    if (settings.videoFrameExtractionStrategy ==
        VideoFrameExtractionStrategy.highFidelity) {
      return settings.videoFrameIntervalSeconds.clamp(0.1, 0.25).toDouble();
    }
    return settings.videoFrameIntervalSeconds;
  }

  static int _estimateCandidateFrames(
    VideoMetadata metadata,
    AppSettings settings,
  ) {
    if (metadata.durationMs <= 0) {
      return 0;
    }
    final durationSeconds = metadata.durationMs / 1000;
    if (settings.videoFrameExtractionStrategy ==
        VideoFrameExtractionStrategy.perFrame) {
      return (durationSeconds * metadata.frameRate).ceil();
    }
    return (durationSeconds / _effectiveIntervalSeconds(settings)).ceil();
  }

  @override
  void dispose() {
    _continueAnalysis = false;
    _analysisService.visionService
      ..cancelActiveRequests()
      ..close();
    super.dispose();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
