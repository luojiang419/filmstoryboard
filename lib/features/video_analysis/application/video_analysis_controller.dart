import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/app_settings.dart';
import '../../shooting_script/application/script_analysis_controller.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../data/analysis_report_export_service.dart';
import '../data/ffmpeg_frame_extractor.dart';
import '../data/frame_quality_service.dart';
import '../data/video_analysis_repository.dart';
import '../data/video_import_service.dart';
import '../domain/video_analysis_models.dart';
import 'video_analysis_service.dart';
import 'video_storyboard_bridge.dart';

final videoAnalysisControllerProvider = Provider<VideoAnalysisController>(
  (ref) {
    final repository = VideoAnalysisRepository(ref.watch(appDatabaseProvider));
    final controller = VideoAnalysisController(
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      repository: repository,
      storyboardController: ref.watch(storyboardControllerProvider),
      shootingScriptController: ref.watch(shootingScriptControllerProvider),
      scriptAnalysisController: ref.watch(scriptAnalysisControllerProvider),
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
    settingsControllerProvider,
    storyboardControllerProvider,
    shootingScriptControllerProvider,
    scriptAnalysisControllerProvider,
  ],
);

enum VideoFrameFilter { all, focus, pending, failed }

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
    this.isGeneratingStoryboard = false,
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
  final bool isGeneratingStoryboard;
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

  bool get isBusy =>
      isImporting || isAnalyzing || isExporting || isGeneratingStoryboard;

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
    bool? isGeneratingStoryboard,
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
    isGeneratingStoryboard:
        isGeneratingStoryboard ?? this.isGeneratingStoryboard,
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
    StoryboardController? storyboardController,
    ShootingScriptController? shootingScriptController,
    ShootingScriptAnalysisController? scriptAnalysisController,
    VideoAnalysisService? analysisService,
    AnalysisReportExportService reportExportService =
        const AnalysisReportExportService(),
    Uuid uuid = const Uuid(),
  }) : _directories = directories,
       _settingsController = settingsController,
       _repository = repository,
       _storyboardController = storyboardController,
       _shootingScriptController = shootingScriptController,
       _scriptAnalysisController = scriptAnalysisController,
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
  final StoryboardController? _storyboardController;
  final ShootingScriptController? _shootingScriptController;
  final ShootingScriptAnalysisController? _scriptAnalysisController;
  final VideoAnalysisService _analysisService;
  final AnalysisReportExportService _reportExportService;
  final Uuid _uuid;
  bool _continueAnalysis = true;
  bool _cancelAnalysisRequested = false;
  final _removedFrameUndoHistory = <String, List<_RemovedVideoFrame>>{};
  final _removedFrameRedoHistory = <String, List<_RemovedVideoFrame>>{};

  bool get canUndoFrameRemoval {
    final videoId = value.selectedVideoId;
    return videoId.isNotEmpty &&
        (_removedFrameUndoHistory[videoId]?.isNotEmpty ?? false);
  }

  bool get canRedoFrameRemoval {
    final videoId = value.selectedVideoId;
    return videoId.isNotEmpty &&
        (_removedFrameRedoHistory[videoId]?.isNotEmpty ?? false);
  }

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
      _removedFrameUndoHistory.remove(videoId);
      _removedFrameRedoHistory.remove(videoId);
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

  Future<void> importVideo(File file) => importVideos([file]);

  /// 依次处理所选视频，避免 FFmpeg 与视觉模型请求相互抢占资源。
  /// 全自动模式下，每个视频提取完候选帧后立即继续后续链路；普通模式
  /// 则等待用户选择“解析全部”或“继续未完成”。
  Future<void> importVideos(List<File> files) async {
    if (value.isBusy) {
      return;
    }
    final selectedFiles = files
        .where((file) => file.path.trim().isNotEmpty)
        .toList(growable: false);
    if (selectedFiles.isEmpty) {
      return;
    }
    for (final file in selectedFiles) {
      final imported = await _importSingleVideo(file);
      if (imported && _settingsController.value.fullAutomationEnabled) {
        await startAnalysis(forceAll: true);
      }
    }
  }

  Future<bool> _importSingleVideo(File file) async {
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
            isSelected: true,
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
              isSelected: true,
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
      return true;
    } catch (error) {
      value = value.copyWith(
        isImporting: false,
        message: '',
        errorMessage: '视频导入失败：$error',
      );
      return false;
    }
  }

  void setFocusFrame(String frameId) {
    final frame = value.frames.where((item) => item.id == frameId).firstOrNull;
    if (frame == null) {
      return;
    }
    _repository.upsertVideoFrame(frame.copyWith(isFocus: true));
    _loadSelectedVideo(selectedFrameId: frameId);
  }

  Future<void> startAnalysis({
    bool retryFailedOnly = false,
    bool forceAll = false,
    bool allVideos = false,
  }) async {
    final video = value.selectedVideo;
    if (video == null || value.isBusy) {
      return;
    }
    final targets = <_VideoAnalysisTarget>[];
    for (final candidate in allVideos ? value.videos : [video]) {
      final analyses = _repository.listVideoFrameAnalyses(candidate.id);
      final analysisByFrame = {
        for (final analysis in analyses) analysis.frameId: analysis,
      };
      final frames = _repository.listVideoFrames(candidate.id).where((frame) {
        final analysis = analysisByFrame[frame.id];
        if (retryFailedOnly) {
          return analysis?.status == ProcessingStatus.failed;
        }
        if (forceAll) {
          return true;
        }
        return analysis?.status != ProcessingStatus.completed;
      }).toList();
      if (frames.isNotEmpty) {
        targets.add(_VideoAnalysisTarget(video: candidate, frames: frames));
      }
    }
    if (targets.isEmpty) {
      value = value.copyWith(
        message: retryFailedOnly ? '没有需要重试的失败帧' : '没有待解析的视频帧',
      );
      return;
    }
    _continueAnalysis = true;
    _cancelAnalysisRequested = false;
    value = value.copyWith(
      isAnalyzing: true,
      isPaused: false,
      completedProgress: 0,
      totalProgress: targets.fold<int>(
        0,
        (sum, target) => sum + target.frames.length,
      ),
      message: allVideos
          ? '正在逐个解析已添加的视频…'
          : retryFailedOnly
          ? '正在重试失败帧…'
          : '正在逐帧解析…',
      errorMessage: '',
    );
    try {
      var completedBefore = 0;
      var interrupted = false;
      final followUpMessages = <String>[];
      final followUpErrors = <String>[];
      for (var index = 0; index < targets.length; index++) {
        final target = targets[index];
        if (!_continueAnalysis) {
          interrupted = true;
          break;
        }
        value = value.copyWith(
          message: allVideos
              ? '正在解析 ${target.video.fileName}（${index + 1}/${targets.length}）…'
              : null,
        );
        var result = await _analysisService.analyzeFrames(
          settings: _settingsController.value,
          video: target.video,
          frames: target.frames,
          resolveFrame: resolveFrame,
          shouldContinue: () => _continueAnalysis,
          onProgress: (completed, total) {
            value = value.copyWith(
              completedProgress: completedBefore + completed,
              message: completed == total
                  ? '候选帧解析完成，正在汇总 ${target.video.fileName}…'
                  : null,
            );
          },
          onFrameCompleted: (_) => _loadSelectedVideo(notifyMessage: false),
        );
        completedBefore += target.frames.length;
        if (!result.interrupted &&
            _settingsController.value.fullAutomationEnabled &&
            result.failedCount > 0) {
          value = value.copyWith(message: '存在失败帧，将在一分钟后自动重试…');
          await Future<void>.delayed(const Duration(minutes: 1));
          if (_continueAnalysis) {
            final failedFrames = _repository
                .listVideoFrames(target.video.id)
                .where((frame) => frame.status == ProcessingStatus.failed)
                .toList();
            if (failedFrames.isNotEmpty) {
              result = await _analysisService.analyzeFrames(
                settings: _settingsController.value,
                video: target.video,
                frames: failedFrames,
                resolveFrame: resolveFrame,
                shouldContinue: () => _continueAnalysis,
                onProgress: (completed, total) {
                  value = value.copyWith(
                    completedProgress: completedBefore,
                    message:
                        '正在自动重试 ${target.video.fileName} 的失败帧 $completed/$total…',
                  );
                },
                onFrameCompleted: (_) =>
                    _loadSelectedVideo(notifyMessage: false),
              );
            }
          }
        }
        if (result.interrupted) {
          interrupted = true;
          break;
        }
        final followUp = await _createFollowUpArtifacts(target.video);
        if (followUp.message.isNotEmpty) {
          followUpMessages.add(followUp.message.substring(1));
        }
        if (followUp.errorMessage.isNotEmpty) {
          followUpErrors.add(followUp.errorMessage);
        }
      }
      _loadSelectedVideo(notifyMessage: false);
      final targetVideoIds = targets.map((target) => target.video.id).toSet();
      final completedCount = _repository
          .listSourceVideos()
          .where((candidate) => targetVideoIds.contains(candidate.id))
          .expand(
            (candidate) => _repository.listVideoFrameAnalyses(candidate.id),
          )
          .where((analysis) => analysis.status == ProcessingStatus.completed)
          .length;
      final failedCount = _repository
          .listSourceVideos()
          .where((candidate) => targetVideoIds.contains(candidate.id))
          .expand(
            (candidate) => _repository.listVideoFrameAnalyses(candidate.id),
          )
          .where((analysis) => analysis.status == ProcessingStatus.failed)
          .length;
      final wasCancelled = _cancelAnalysisRequested;
      value = value.copyWith(
        isAnalyzing: false,
        isPaused: interrupted && !wasCancelled,
        message: interrupted
            ? wasCancelled
                  ? '解析已取消，可重新开始处理剩余帧'
                  : '解析已暂停，可继续处理剩余帧'
            : '解析完成：成功 $completedCount，失败 $failedCount${followUpMessages.isEmpty ? '' : '；${followUpMessages.join('；')}'}',
        errorMessage: followUpErrors.join('\n'),
      );
    } catch (error) {
      // 无论汇总、存储或模型请求在哪个阶段异常，都必须收敛忙碌状态。
      // 否则界面会永久显示“解析中”，且无法再次开始或重试。
      _loadSelectedVideo(notifyMessage: false);
      value = value.copyWith(
        isAnalyzing: false,
        isPaused: false,
        message: '',
        errorMessage: '视频解析未完成：$error',
      );
    } finally {
      _cancelAnalysisRequested = false;
    }
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

  Future<bool> generateStoryboardForSelectedVideo() async {
    final video = value.selectedVideo;
    if (video == null || value.isBusy) {
      return false;
    }
    value = value.copyWith(
      isGeneratingStoryboard: true,
      message: '正在生成故事板和拍摄脚本…',
      errorMessage: '',
    );
    try {
      final result = await _createFollowUpArtifacts(video);
      final generated = result.createdBoardCount > 0;
      value = value.copyWith(
        isGeneratingStoryboard: false,
        message: generated
            ? '已生成 ${result.createdBoardCount} 个故事板、${result.createdScriptCount} 个拍摄脚本'
            : '',
        errorMessage: result.errorMessage,
      );
      return generated;
    } catch (error) {
      value = value.copyWith(
        isGeneratingStoryboard: false,
        message: '',
        errorMessage: '生成故事板和拍摄脚本失败：$error',
      );
      return false;
    }
  }

  Future<_FollowUpArtifactsResult> _createFollowUpArtifacts(
    SourceVideo video,
  ) async {
    final storyboardController = _storyboardController;
    final shootingScriptController = _shootingScriptController;
    if (storyboardController == null || shootingScriptController == null) {
      return const _FollowUpArtifactsResult(
        errorMessage: '自动创建故事板和拍摄脚本不可用，请重新打开工程后重试',
      );
    }
    final frames = _repository.listVideoFrames(video.id);
    final analyses = _repository.listVideoFrameAnalyses(video.id);
    final storyboards = VideoStoryboardBridge.buildSegments(
      video: video,
      frames: frames,
      frameAnalyses: analyses,
      shots: _repository.listVideoShots(video.id),
      summary: _repository.getVideoSummary(video.id),
      resolveFramePath: (frame) => resolveFrame(frame).path,
    );
    var createdBoardCount = 0;
    var createdScriptCount = 0;
    final scripts = <String>[];
    final failures = <String>[];
    for (final storyboard in storyboards) {
      final boardId = await storyboardController
          .createOrReplaceBoardFromExternalImages(
            sourceId: storyboard.sourceId,
            boardName: storyboard.boardName,
            images: storyboard.images,
            summary: storyboard.summary,
          );
      if (boardId == null) {
        failures.add(storyboard.boardName);
        continue;
      }
      final board = storyboardController.value.boards
          .where((item) => item.id == boardId)
          .firstOrNull;
      if (board == null) {
        failures.add(storyboard.boardName);
        continue;
      }
      createdBoardCount++;
      // 初始脚本必须关联新建的故事板：这样故事板编辑会持续同步到脚本，
      // 也不再需要用户手动点击“从当前故事板生成”。
      final script = shootingScriptController.createForStoryboard(
        board,
        sourceVideoId: video.id,
      );
      createdScriptCount++;
      scripts.add(script.id);
    }
    final result = _FollowUpArtifactsResult(
      createdBoardCount: createdBoardCount,
      createdScriptCount: createdScriptCount,
      errorMessage: failures.isEmpty
          ? ''
          : '自动创建失败：${failures.join('、')}，请检查视频帧文件后重试',
    );
    if (!_settingsController.value.fullAutomationEnabled || scripts.isEmpty) {
      return result;
    }
    final scriptAnalysisController = _scriptAnalysisController;
    if (scriptAnalysisController == null) return result;
    final failedScriptIds = <String>[];
    for (final scriptId in scripts) {
      shootingScriptController.selectScript(scriptId);
      await scriptAnalysisController.analyzeAll();
      if (scriptAnalysisController.value.failedCount > 0) {
        failedScriptIds.add(scriptId);
      }
    }
    if (failedScriptIds.isEmpty) return result;
    value = value.copyWith(message: '分镜脚本有失败项，将在一分钟后自动重试…');
    await Future<void>.delayed(const Duration(minutes: 1));
    if (_continueAnalysis) {
      for (final scriptId in failedScriptIds) {
        shootingScriptController.selectScript(scriptId);
        await scriptAnalysisController.analyzeAll(onlyFailed: true);
      }
    }
    return result;
  }

  Future<void> resumeAnalysis() => startAnalysis();

  void removeFrame(String frameId) {
    if (value.isBusy) {
      value = value.copyWith(message: '当前正在处理视频，暂不能移除视频帧');
      return;
    }
    final frame = value.frames.where((item) => item.id == frameId).firstOrNull;
    if (frame == null) return;
    final videoId = frame.videoId;
    final entry = _RemovedVideoFrame(
      frame: frame,
      analysis: value.frameAnalyses
          .where((analysis) => analysis.frameId == frame.id)
          .firstOrNull,
      affectedShots: value.shots
          .where((shot) => shot.frameIds.contains(frame.id))
          .toList(growable: false),
    );
    _repository.deleteVideoFrame(frame.id);
    _pushFrameHistory(_removedFrameUndoHistory, videoId, entry);
    _removedFrameRedoHistory.remove(videoId);
    final nextFrameId = value.selectedFrameId == frame.id
        ? value.frames.where((item) => item.id != frame.id).firstOrNull?.id ??
              ''
        : value.selectedFrameId;
    _loadSelectedVideo(
      selectedFrameId: nextFrameId,
      message: '已移除视频帧 #${frame.index + 1}，可撤销恢复',
    );
  }

  void undoFrameRemoval() {
    if (value.isBusy || !canUndoFrameRemoval) return;
    final videoId = value.selectedVideoId;
    final entry = _removedFrameUndoHistory[videoId]!.removeLast();
    _repository.upsertVideoFrame(entry.frame);
    if (entry.analysis != null) {
      _repository.upsertVideoFrameAnalysis(entry.analysis!);
    }
    for (final shot in entry.affectedShots) {
      _repository.upsertVideoShot(shot);
    }
    _pushFrameHistory(_removedFrameRedoHistory, videoId, entry);
    _loadSelectedVideo(
      selectedFrameId: entry.frame.id,
      message: '已恢复视频帧 #${entry.frame.index + 1}',
    );
  }

  void redoFrameRemoval() {
    if (value.isBusy || !canRedoFrameRemoval) return;
    final videoId = value.selectedVideoId;
    final entry = _removedFrameRedoHistory[videoId]!.removeLast();
    _repository.deleteVideoFrame(entry.frame.id);
    _pushFrameHistory(_removedFrameUndoHistory, videoId, entry);
    final nextFrameId = value.selectedFrameId == entry.frame.id
        ? value.frames
                  .where((frame) => frame.id != entry.frame.id)
                  .firstOrNull
                  ?.id ??
              ''
        : value.selectedFrameId;
    _loadSelectedVideo(
      selectedFrameId: nextFrameId,
      message: '已再次移除视频帧 #${entry.frame.index + 1}',
    );
  }

  void _pushFrameHistory(
    Map<String, List<_RemovedVideoFrame>> historyByVideoId,
    String videoId,
    _RemovedVideoFrame entry,
  ) {
    final history = historyByVideoId.putIfAbsent(videoId, () => []);
    history.add(entry);
    if (history.length > 100) {
      history.removeAt(0);
    }
  }

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
        resolveFrame: resolveFrame,
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
    String? message,
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
      message: message ?? (notifyMessage ? value.message : null),
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

  @override
  void dispose() {
    _continueAnalysis = false;
    _analysisService.visionService
      ..cancelActiveRequests()
      ..close();
    super.dispose();
  }
}

class _VideoAnalysisTarget {
  const _VideoAnalysisTarget({required this.video, required this.frames});

  final SourceVideo video;
  final List<VideoFrame> frames;
}

class _RemovedVideoFrame {
  const _RemovedVideoFrame({
    required this.frame,
    required this.analysis,
    required this.affectedShots,
  });

  final VideoFrame frame;
  final VideoFrameAnalysis? analysis;
  final List<VideoShot> affectedShots;
}

class _FollowUpArtifactsResult {
  const _FollowUpArtifactsResult({
    this.createdBoardCount = 0,
    this.createdScriptCount = 0,
    this.errorMessage = '',
  });

  final int createdBoardCount;
  final int createdScriptCount;
  final String errorMessage;

  String get message {
    if (createdBoardCount == 0 && createdScriptCount == 0) return '';
    return '；已自动创建 $createdBoardCount 个故事板、$createdScriptCount 个拍摄脚本';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
