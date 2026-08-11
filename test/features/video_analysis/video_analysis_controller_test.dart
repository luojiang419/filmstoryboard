import 'dart:async';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_shooting_script_sync_controller.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_controller.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_service.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('移除视频帧可撤销、恢复并还原关联分析和镜头', () async {
    final root = await Directory.systemTemp.createTemp('video_frame_history_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = VideoAnalysisRepository(database);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final now = DateTime.utc(2026, 8, 3);
    const videoId = 'video-history';
    final video = SourceVideo(
      id: videoId,
      originalPath: 'history.mp4',
      fileName: 'history.mp4',
      storedPath: 'videos/history.mp4',
      durationMs: 2000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 2,
      successfulFrames: 2,
      failedFrames: 0,
      status: ProcessingStatus.completed,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    final firstFrame = _frame(videoId, 'frame-history-1', 0, now);
    final secondFrame = _frame(videoId, 'frame-history-2', 1, now);
    repository
      ..upsertSourceVideo(video)
      ..upsertVideoFrame(firstFrame)
      ..upsertVideoFrame(secondFrame)
      ..upsertVideoFrameAnalysis(
        VideoFrameAnalysis(
          id: 'analysis-history-1',
          videoId: videoId,
          frameId: firstFrame.id,
          sequenceNo: 0,
          dimensions: const {'caption': '测试画面'},
          rawResponse: '{}',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: now,
        ),
      )
      ..upsertVideoShot(
        VideoShot(
          id: 'shot-history-1',
          videoId: videoId,
          shotNumber: 1,
          startMs: 0,
          endMs: 2000,
          primaryFrameId: firstFrame.id,
          frameIds: [firstFrame.id, secondFrame.id],
          description: '',
          storyFlow: '',
          status: ProcessingStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      );
    final controller = VideoAnalysisController(
      directories: directories,
      settingsController: settingsController,
      repository: repository,
    );
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    controller.removeFrame(firstFrame.id);
    expect(controller.value.frames.map((frame) => frame.id), [secondFrame.id]);
    expect(controller.canUndoFrameRemoval, isTrue);
    expect(controller.canRedoFrameRemoval, isFalse);
    expect(repository.listVideoFrameAnalyses(videoId), isEmpty);

    controller.undoFrameRemoval();
    expect(repository.listVideoFrames(videoId), hasLength(2));
    expect(
      repository.listVideoFrameAnalyses(videoId).single.frameId,
      firstFrame.id,
    );
    expect(repository.listVideoShots(videoId).single.frameIds, [
      firstFrame.id,
      secondFrame.id,
    ]);
    expect(controller.canRedoFrameRemoval, isTrue);

    controller.redoFrameRemoval();
    expect(repository.listVideoFrames(videoId), hasLength(1));
    expect(repository.listVideoFrameAnalyses(videoId), isEmpty);
  });

  test('未解析候选帧可先创建故事板和脚本并在解析完成后原位回填', () async {
    final root = await Directory.systemTemp.createTemp('video_chain_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = VideoAnalysisRepository(database);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final storyboardController = StoryboardController(
      database: database,
      directories: directories,
      settingsController: settingsController,
    );
    final shootingScriptController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    final syncController = StoryboardShootingScriptSyncController(
      storyboardController: storyboardController,
      shootingScriptController: shootingScriptController,
    );
    final now = DateTime.utc(2026, 8, 3);
    const videoId = 'video-chain';
    final frameFile = File(p.join(directories.frames.path, 'chain-frame.png'));
    final image = img.Image(width: 64, height: 36);
    await frameFile.writeAsBytes(img.encodePng(image));
    final video = SourceVideo(
      id: videoId,
      originalPath: 'chain.mp4',
      fileName: 'chain.mp4',
      storedPath: 'videos/chain.mp4',
      durationMs: 1000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 1,
      successfulFrames: 0,
      failedFrames: 0,
      status: ProcessingStatus.pending,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    final frame = _frame(
      videoId,
      'chain-frame',
      0,
      now,
    ).copyWith(status: ProcessingStatus.pending);
    repository
      ..upsertSourceVideo(video)
      ..upsertVideoFrame(
        VideoFrame(
          id: frame.id,
          videoId: frame.videoId,
          index: frame.index,
          timestampMs: frame.timestampMs,
          path: p.relative(
            frameFile.path,
            from: directories.workspaceRoot.path,
          ),
          width: 64,
          height: 36,
          sharpness: frame.sharpness,
          brightness: frame.brightness,
          motionScore: frame.motionScore,
          perceptualHash: frame.perceptualHash,
          isFocus: false,
          isSelected: true,
          status: ProcessingStatus.pending,
          errorMessage: '',
          createdAt: now,
        ),
      );
    final controller = VideoAnalysisController(
      directories: directories,
      settingsController: settingsController,
      repository: repository,
      storyboardController: storyboardController,
      shootingScriptController: shootingScriptController,
      analysisService: _CompletedVideoAnalysisService(repository: repository),
    );
    addTearDown(() async {
      controller.dispose();
      syncController.dispose();
      shootingScriptController.dispose();
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    expect(await controller.generateStoryboardForSelectedVideo(), isTrue);
    final initialBoard = storyboardController.value.boards.singleWhere(
      (item) => item.id == 'external-board:video:$videoId',
    );
    final initialScript = shootingScriptController.value.scripts.single;
    final initialShot = shootingScriptController.value.shots.single;
    expect(initialBoard.items.single.caption, isEmpty);
    expect(initialShot.content, isEmpty);
    storyboardController
      ..selectBoard(initialBoard.id)
      ..updateCaption(0, '用户在解析期间填写的镜头内容');

    await controller.startAnalysis();

    final board = storyboardController.value.boards.singleWhere(
      (item) => item.id == 'external-board:video:$videoId',
    );
    final script = shootingScriptController.value.scripts.single;
    expect(board.id, initialBoard.id);
    expect(script.id, initialScript.id);
    expect(shootingScriptController.value.shots.single.id, initialShot.id);
    expect(board.items, hasLength(1));
    expect(
      p.normalize(board.items.single.asset.path),
      p.normalize(frameFile.path),
    );
    expect(File(board.items.single.asset.path).existsSync(), isTrue);
    expect(script.sourceStoryboardId, board.id);
    expect(script.sourceVideoId, videoId);
    expect(shootingScriptController.value.shots, hasLength(1));
    expect(
      shootingScriptController.value.shots.single.sourceStoryboardAssetId,
      'external-cut:video-frame:${frame.id}',
    );
    expect(
      shootingScriptController.value.shots.single.sourceVideoFrameId,
      frame.id,
    );
    expect(
      p.normalize(shootingScriptController.value.shots.single.framePath),
      p.normalize(frameFile.path),
    );
    expect(
      File(shootingScriptController.value.shots.single.framePath).existsSync(),
      isTrue,
    );
    expect(board.items.single.caption, '用户在解析期间填写的镜头内容');
    expect(
      shootingScriptController.value.shots.single.content,
      '用户在解析期间填写的镜头内容',
    );
    expect(controller.value.message, contains('已自动创建 1 个故事板、1 个拍摄脚本'));

    storyboardController.deleteBoard(board.id);
    expect(repository.listVideoFrames(videoId), hasLength(1));
    expect(frameFile.existsSync(), isTrue);
    expect(shootingScriptController.value.scripts, isEmpty);

    expect(await controller.generateStoryboardForSelectedVideo(), isTrue);
    expect(
      storyboardController.value.boards.any((item) => item.id == board.id),
      isTrue,
    );
    expect(shootingScriptController.value.scripts, hasLength(1));

    storyboardController.deleteAssetGroup('external-image:video:$videoId');
    expect(repository.listVideoFrames(videoId), hasLength(1));
    expect(frameFile.existsSync(), isTrue);
    expect(
      storyboardController.value.boards.any((item) => item.id == board.id),
      isFalse,
    );
    expect(shootingScriptController.value.scripts, isEmpty);

    expect(await controller.generateStoryboardForSelectedVideo(), isTrue);
    expect(shootingScriptController.value.scripts, hasLength(1));
  });

  test('解析全部视频会跳过已经解析完成的视频帧', () async {
    final root = await Directory.systemTemp.createTemp('video_batch_analysis_');
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = VideoAnalysisRepository(database);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final now = DateTime.utc(2026, 8, 3);
    final firstVideo = _video('video-batch-first', 'first.mp4', now);
    final secondVideo = _video(
      'video-batch-second',
      'second.mp4',
      now.add(const Duration(seconds: 1)),
    );
    repository
      ..upsertSourceVideo(firstVideo)
      ..upsertSourceVideo(secondVideo)
      ..upsertVideoFrame(_frame(firstVideo.id, 'first-frame', 0, now))
      ..upsertVideoFrame(_frame(secondVideo.id, 'second-frame', 0, now))
      ..upsertVideoFrameAnalysis(
        _analysis(firstVideo.id, 'first-frame', 1, now),
      )
      ..upsertMarketingAnalysis(
        MarketingAnalysis(
          id: '${firstVideo.id}-video-dimensions',
          videoId: firstVideo.id,
          scope: 'video',
          dimensions: const {},
          rawResponse: '{}',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
    final analysisService = _CompletedVideoAnalysisService(
      repository: repository,
    );
    final controller = VideoAnalysisController(
      directories: directories,
      settingsController: settingsController,
      repository: repository,
      analysisService: analysisService,
    );
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await controller.startAnalysis(allVideos: true);

    expect(analysisService.analyzedVideoIds, [secondVideo.id]);
    expect(
      repository.listVideoFrameAnalyses(firstVideo.id).single.status,
      ProcessingStatus.completed,
    );
    expect(
      repository.listVideoFrameAnalyses(secondVideo.id).single.status,
      ProcessingStatus.completed,
    );
  });

  test('解析当前视频会重新解析已完成的选中视频', () async {
    final root = await Directory.systemTemp.createTemp(
      'video_current_reanalysis_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = VideoAnalysisRepository(database);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final now = DateTime.utc(2026, 8, 3);
    final firstVideo = _video('video-current-first', 'first.mp4', now);
    final secondVideo = _video(
      'video-current-second',
      'second.mp4',
      now.add(const Duration(seconds: 1)),
    );
    repository
      ..upsertSourceVideo(firstVideo)
      ..upsertSourceVideo(secondVideo)
      ..upsertVideoFrame(_frame(firstVideo.id, 'first-frame', 0, now))
      ..upsertVideoFrame(_frame(secondVideo.id, 'second-frame', 0, now))
      ..upsertVideoFrameAnalysis(
        _analysis(firstVideo.id, 'first-frame', 1, now),
      )
      ..upsertVideoFrameAnalysis(
        _analysis(secondVideo.id, 'second-frame', 1, now),
      );
    final analysisService = _CompletedVideoAnalysisService(
      repository: repository,
    );
    final controller = VideoAnalysisController(
      directories: directories,
      settingsController: settingsController,
      repository: repository,
      analysisService: analysisService,
    );
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    controller.selectVideo(firstVideo.id);
    await controller.startAnalysis(forceAll: true);

    expect(analysisService.analyzedVideoIds, [firstVideo.id]);
    expect(
      repository.listVideoFrameAnalyses(firstVideo.id).single.rawResponse,
      '{}',
    );
    expect(
      repository.listVideoFrameAnalyses(secondVideo.id).single.rawResponse,
      '{"before":"kept"}',
    );
  });

  test('不同视频可并行解析并在切换后恢复各自进度', () async {
    final root = await Directory.systemTemp.createTemp(
      'parallel-video-analysis-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final repository = VideoAnalysisRepository(database);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final now = DateTime.utc(2026, 8, 11);
    final videoA = _video('parallel-video-a', 'a.mp4', now);
    final videoB = _video(
      'parallel-video-b',
      'b.mp4',
      now.add(const Duration(seconds: 1)),
    );
    repository
      ..upsertSourceVideo(videoA)
      ..upsertSourceVideo(videoB)
      ..upsertVideoFrame(
        _frame(
          videoA.id,
          'parallel-frame-a',
          0,
          now,
        ).copyWith(status: ProcessingStatus.pending),
      )
      ..upsertVideoFrame(
        _frame(
          videoB.id,
          'parallel-frame-b',
          0,
          now,
        ).copyWith(status: ProcessingStatus.pending),
      );
    final analysisService = _DeferredVideoAnalysisService(
      repository: repository,
    );
    final controller = VideoAnalysisController(
      directories: directories,
      settingsController: settingsController,
      repository: repository,
      analysisService: analysisService,
    );
    addTearDown(() async {
      controller.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    controller.selectVideo(videoA.id);
    final analysisA = controller.startAnalysis();
    await analysisService.started(videoA.id);
    expect(controller.isAnalysisActiveFor(videoA.id), isTrue);
    expect(controller.value.isAnalyzing, isTrue);

    controller.selectVideo(videoB.id);
    expect(controller.value.isAnalyzing, isFalse);
    final analysisB = controller.startAnalysis();
    await analysisService.started(videoB.id);
    expect(controller.isAnalysisActiveFor(videoB.id), isTrue);
    expect(controller.value.isAnalyzing, isTrue);

    controller.selectVideo(videoA.id);
    expect(controller.value.isAnalyzing, isTrue);
    expect(controller.value.completedProgress, 0);
    controller.cancelAnalysis();
    expect(controller.value.message, '正在取消解析…');
    controller.selectVideo(videoB.id);
    expect(controller.value.isAnalyzing, isTrue);
    expect(controller.value.completedProgress, 0);

    analysisService.release(videoA.id);
    await analysisA;
    expect(controller.isAnalysisActiveFor(videoA.id), isFalse);
    expect(controller.isAnalysisActiveFor(videoB.id), isTrue);
    expect(controller.value.selectedVideoId, videoB.id);
    expect(controller.value.isAnalyzing, isTrue);

    analysisService.release(videoB.id);
    await analysisB;
    expect(controller.isAnalysisActiveFor(videoB.id), isFalse);
    expect(controller.value.isAnalyzing, isFalse);
    expect(repository.listVideoFrameAnalyses(videoA.id), isEmpty);
    expect(repository.listVideoFrameAnalyses(videoB.id), hasLength(1));
  });
}

class _CompletedVideoAnalysisService extends VideoAnalysisService {
  _CompletedVideoAnalysisService({required super.repository});

  final analyzedVideoIds = <String>[];

  @override
  Future<VideoAnalysisRunResult> analyzeFrames({
    required settings,
    required SourceVideo video,
    required List<VideoFrame> frames,
    File Function(VideoFrame frame)? resolveFrame,
    void Function(int completed, int total)? onProgress,
    void Function(VideoFrameAnalysis analysis)? onFrameCompleted,
    bool Function()? shouldContinue,
  }) async {
    analyzedVideoIds.add(video.id);
    for (var index = 0; index < frames.length; index++) {
      final frame = frames[index];
      final now = DateTime.now().toUtc();
      final analysis = VideoFrameAnalysis(
        id: '${video.id}-${frame.id}',
        videoId: video.id,
        frameId: frame.id,
        sequenceNo: index + 1,
        dimensions: const {'caption': '自动生成的测试镜头'},
        rawResponse: '{}',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      );
      repository
        ..upsertVideoFrameAnalysis(analysis)
        ..upsertVideoFrame(frame.copyWith(status: ProcessingStatus.completed));
      onFrameCompleted?.call(analysis);
      onProgress?.call(index + 1, frames.length);
    }
    return VideoAnalysisRunResult(
      completedCount: frames.length,
      failedCount: 0,
      summary: null,
    );
  }
}

class _DeferredVideoAnalysisService extends _CompletedVideoAnalysisService {
  _DeferredVideoAnalysisService({required super.repository});

  final _startedByVideoId = <String, Completer<void>>{};
  final _releaseByVideoId = <String, Completer<void>>{};

  Future<void> started(String videoId) =>
      (_startedByVideoId[videoId] ??= Completer<void>()).future;

  void release(String videoId) {
    final completer = _releaseByVideoId[videoId] ??= Completer<void>();
    if (!completer.isCompleted) completer.complete();
  }

  @override
  Future<VideoAnalysisRunResult> analyzeFrames({
    required settings,
    required SourceVideo video,
    required List<VideoFrame> frames,
    File Function(VideoFrame frame)? resolveFrame,
    void Function(int completed, int total)? onProgress,
    void Function(VideoFrameAnalysis analysis)? onFrameCompleted,
    bool Function()? shouldContinue,
  }) async {
    final started = _startedByVideoId[video.id] ??= Completer<void>();
    if (!started.isCompleted) started.complete();
    await (_releaseByVideoId[video.id] ??= Completer<void>()).future;
    if (shouldContinue?.call() == false) {
      return const VideoAnalysisRunResult(
        completedCount: 0,
        failedCount: 0,
        summary: null,
        interrupted: true,
      );
    }
    return super.analyzeFrames(
      settings: settings,
      video: video,
      frames: frames,
      resolveFrame: resolveFrame,
      onProgress: onProgress,
      onFrameCompleted: onFrameCompleted,
      shouldContinue: shouldContinue,
    );
  }
}

VideoFrame _frame(String videoId, String id, int index, DateTime createdAt) =>
    VideoFrame(
      id: id,
      videoId: videoId,
      index: index,
      timestampMs: index * 1000,
      path: 'frames/$id.jpg',
      width: 1920,
      height: 1080,
      sharpness: 0.9,
      brightness: 0.5,
      motionScore: 0.1,
      perceptualHash: 'hash-$id',
      isFocus: index == 0,
      isSelected: true,
      status: ProcessingStatus.completed,
      errorMessage: '',
      createdAt: createdAt,
    );

VideoFrameAnalysis _analysis(
  String videoId,
  String frameId,
  int sequenceNo,
  DateTime createdAt,
) => VideoFrameAnalysis(
  id: 'existing-$frameId',
  videoId: videoId,
  frameId: frameId,
  sequenceNo: sequenceNo,
  dimensions: const {'caption': '已有解析'},
  rawResponse: '{"before":"kept"}',
  status: ProcessingStatus.completed,
  errorMessage: '',
  createdAt: createdAt,
  updatedAt: createdAt,
);

SourceVideo _video(String id, String fileName, DateTime createdAt) =>
    SourceVideo(
      id: id,
      originalPath: fileName,
      fileName: fileName,
      storedPath: 'videos/$fileName',
      durationMs: 1000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 1,
      successfulFrames: 0,
      failedFrames: 0,
      status: ProcessingStatus.pending,
      errorMessage: '',
      createdAt: createdAt,
      updatedAt: createdAt,
    );
