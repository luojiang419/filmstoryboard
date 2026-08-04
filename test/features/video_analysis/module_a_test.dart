import 'dart:async';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_analysis_service.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AppDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filmstoryboard-module-a-');
    database = await AppDatabase.open(File('${root.path}/database.sqlite'));
  });

  tearDown(() async {
    database.dispose();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('工程目录包含视频解析、报告、脚本、资产和提示词目录', () async {
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();

    expect(directories.managedDirectories, hasLength(16));
    for (final directory in directories.managedDirectories) {
      expect(directory.existsSync(), isTrue, reason: directory.path);
    }
    expect(directories.videos.path, endsWith('videos'));
    expect(directories.frames.path, endsWith('frames'));
    expect(directories.analyses.path, endsWith('analyses'));
    expect(directories.reports.path, endsWith('reports'));
    expect(directories.scripts.path, endsWith('scripts'));
    expect(directories.assets.path, endsWith('assets'));
    expect(directories.prompts.path, endsWith('prompts'));
  });

  test('旧数据库打开后迁移到模块 A schema 并创建十张新表', () {
    final version = database
        .selectRows('PRAGMA user_version;')
        .single['user_version'];
    expect(version, AppDatabase.currentSchemaVersion);
    for (final table in [
      'source_videos',
      'video_frames',
      'video_shots',
      'video_shot_frames',
      'marketing_analyses',
      'shooting_scripts',
      'script_shots',
      'replicate_runs',
      'replicate_assets',
      'shot_prompts',
      'replicated_shot_images',
    ]) {
      expect(database.countRows(table), 0, reason: table);
    }
    expect(database.integrityCheck(), isTrue);
  });

  test('视频、帧、镜头、报告、脚本和复刻数据可完整往返恢复', () {
    final repository = VideoAnalysisRepository(database);
    final now = DateTime.utc(2026, 8, 2);
    repository.upsertSourceVideo(
      SourceVideo(
        id: 'video-1',
        originalPath: r'C:\input\reference.mp4',
        fileName: 'reference.mp4',
        storedPath: 'videos/video-1/reference.mp4',
        durationMs: 12000,
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
      ),
    );
    for (var index = 0; index < 2; index++) {
      repository.upsertVideoFrame(
        VideoFrame(
          id: 'frame-$index',
          videoId: 'video-1',
          index: index,
          timestampMs: index * 1000,
          path: 'frames/video-1/frame-$index.jpg',
          width: 1920,
          height: 1080,
          sharpness: 0.9,
          brightness: 0.5,
          motionScore: 0.4,
          perceptualHash: 'hash-$index',
          isFocus: index == 0,
          isSelected: true,
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
        ),
      );
    }
    repository.upsertVideoShot(
      VideoShot(
        id: 'shot-1',
        videoId: 'video-1',
        shotNumber: 1,
        startMs: 0,
        endMs: 2000,
        primaryFrameId: 'frame-0',
        frameIds: const ['frame-0', 'frame-1'],
        description: '人物走入场景',
        storyFlow: '建立人物与空间关系',
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertMarketingAnalysis(
      MarketingAnalysis(
        id: 'analysis-1',
        videoId: 'video-1',
        scope: 'marketing',
        dimensions: const {'hook': '前三秒建立冲突'},
        rawResponse: '{}',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertShootingScript(
      ShootingScript(
        id: 'script-1',
        name: '参考脚本',
        sourceStoryboardId: null,
        sourceVideoId: 'video-1',
        status: ShootingScriptStatus.draft,
        version: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertScriptShot(
      ScriptShot(
        id: 'script-shot-1',
        scriptId: 'script-1',
        shotNumber: 1,
        durationSeconds: 2,
        framePath: 'frames/video-1/frame-0.jpg',
        visual: '人物走入画面',
        content: '建立空间',
        shotSize: '中景',
        cameraMovement: '固定',
        cameraNotes: '',
        composition: '主体居中',
        cameraAngle: '平视',
        lightingMood: '柔和自然光',
        colorPalette: '暖白',
        visualFocus: '人物面部',
        transitionHint: '接近景',
        movementTrend: '向前走入',
        actionStage: '进行',
        continuesFromPrevious: true,
        continuesToNext: true,
        scene: '室内',
        productCode: '',
        productStyling: '',
        dialogue: '',
        sound: '环境声',
        prompt: '',
        status: ProcessingStatus.pending,
        updatedAt: now,
      ),
    );
    repository.upsertReplicateRun(
      ReplicateRun(
        id: 'run-1',
        videoId: 'video-1',
        currentStep: ReplicateStep.prepareAssets,
        status: ProcessingStatus.running,
        confirmShotsStatus: ProcessingStatus.completed,
        prepareAssetsStatus: ProcessingStatus.running,
        composePromptsStatus: ProcessingStatus.pending,
        completedCount: 1,
        totalCount: 3,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertReplicateAsset(
      ReplicateAsset(
        id: 'asset-1',
        runId: 'run-1',
        type: ReplicateAssetType.character,
        name: '角色 A',
        description: '短发青年',
        path: 'assets/run-1/character-a.png',
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    repository.upsertShotPrompt(
      ShotPrompt(
        id: 'prompt-1',
        runId: 'run-1',
        shotNumber: 1,
        scriptShotId: 'script-shot-1',
        assetIds: const ['asset-1'],
        prompt: '图片1中的角色走入室内',
        model: 'local-rule-composer',
        rawResponse: '',
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: now,
      ),
    );

    expect(repository.getSourceVideo('video-1')!.fileName, 'reference.mp4');
    expect(repository.listVideoFrames('video-1'), hasLength(2));
    expect(repository.listVideoShots('video-1').single.frameIds, [
      'frame-0',
      'frame-1',
    ]);
    expect(
      repository.listMarketingAnalyses('video-1').single.dimensions['hook'],
      '前三秒建立冲突',
    );
    expect(repository.listShootingScripts().single.name, '参考脚本');
    expect(
      repository.listScriptShots('script-1').single.framePath,
      'frames/video-1/frame-0.jpg',
    );
    final scriptShot = repository.listScriptShots('script-1').single;
    expect(scriptShot.composition, '主体居中');
    expect(scriptShot.cameraAngle, '平视');
    expect(scriptShot.lightingMood, '柔和自然光');
    expect(scriptShot.colorPalette, '暖白');
    expect(scriptShot.visualFocus, '人物面部');
    expect(scriptShot.transitionHint, '接近景');
    expect(scriptShot.movementTrend, '向前走入');
    expect(scriptShot.actionStage, '进行');
    expect(scriptShot.continuesFromPrevious, isTrue);
    expect(scriptShot.continuesToNext, isTrue);
    expect(
      repository.getReplicateRun('run-1')!.currentStep,
      ReplicateStep.prepareAssets,
    );
    expect(repository.listReplicateAssets('run-1').single.referenceNumber, 1);
    expect(repository.listShotPrompts('run-1').single.assetIds, ['asset-1']);
  });

  test('取消视频解析不会把当前请求记为失败帧', () async {
    final repository = VideoAnalysisRepository(database);
    final now = DateTime.utc(2026, 8, 2);
    final video = SourceVideo(
      id: 'video-cancel',
      originalPath: r'C:\input\cancel.mp4',
      fileName: 'cancel.mp4',
      storedPath: 'videos/cancel.mp4',
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
    final frame = VideoFrame(
      id: 'frame-cancel',
      videoId: video.id,
      index: 0,
      timestampMs: 0,
      path: 'frames/cancel.jpg',
      width: 1920,
      height: 1080,
      sharpness: 0.9,
      brightness: 0.5,
      motionScore: 0,
      perceptualHash: 'hash-cancel',
      isFocus: true,
      isSelected: true,
      status: ProcessingStatus.pending,
      errorMessage: '',
      createdAt: now,
    );
    repository
      ..upsertSourceVideo(video)
      ..upsertVideoFrame(frame);
    final visionService = _BlockingVisionStoryboardService();
    final service = VideoAnalysisService(
      repository: repository,
      visionService: visionService,
    );
    var shouldContinue = true;

    final future = service.analyzeFrames(
      settings: _testSettings(),
      video: video,
      frames: [frame],
      shouldContinue: () => shouldContinue,
    );
    await visionService.started.future;
    shouldContinue = false;
    visionService.cancelActiveRequests();

    final result = await future;

    expect(result.interrupted, isTrue);
    expect(repository.listVideoFrameAnalyses(video.id), isEmpty);
    expect(repository.getVideoSummary(video.id), isNull);
    expect(
      repository.listVideoFrames(video.id).single.status,
      ProcessingStatus.pending,
    );
  });

  test('仅 MiniMax-M3 使用 200 路帧解析并发', () {
    final miniMaxSettings = _testSettings().copyWith(
      visionApiBaseUrl: 'https://api.minimaxi.com',
      visionModel: 'MiniMax-M3',
    );

    expect(
      VideoAnalysisService.maxConcurrentFrameRequestsFor(miniMaxSettings),
      200,
    );
    expect(
      VideoAnalysisService.maxConcurrentFrameRequestsFor(
        miniMaxSettings.copyWith(visionModel: 'MiniMax-M2'),
      ),
      1,
    );
    expect(
      VideoAnalysisService.maxConcurrentFrameRequestsFor(
        miniMaxSettings.copyWith(visionApiBaseUrl: 'https://example.com'),
      ),
      1,
    );
  });

  test('MiniMax-M3 会并行处理视频帧', () async {
    final repository = VideoAnalysisRepository(database);
    final now = DateTime.utc(2026, 8, 2);
    final video = SourceVideo(
      id: 'video-parallel',
      originalPath: 'parallel.mp4',
      fileName: 'parallel.mp4',
      storedPath: 'videos/parallel.mp4',
      durationMs: 3000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 3,
      successfulFrames: 0,
      failedFrames: 0,
      status: ProcessingStatus.pending,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    final frames = List.generate(
      3,
      (index) => VideoFrame(
        id: 'frame-parallel-$index',
        videoId: video.id,
        index: index,
        timestampMs: index * 1000,
        path: 'frames/parallel-$index.jpg',
        width: 1920,
        height: 1080,
        sharpness: 0.9,
        brightness: 0.5,
        motionScore: 0,
        perceptualHash: 'hash-parallel-$index',
        isFocus: true,
        isSelected: true,
        status: ProcessingStatus.pending,
        errorMessage: '',
        createdAt: now,
      ),
    );
    repository.upsertSourceVideo(video);
    for (final frame in frames) {
      repository.upsertVideoFrame(frame);
    }
    final visionService = _ConcurrentVisionStoryboardService();
    final service = VideoAnalysisService(
      repository: repository,
      visionService: visionService,
    );

    final result = await service.analyzeFrames(
      settings: _testSettings().copyWith(
        visionApiBaseUrl: 'https://api.minimaxi.com',
        visionModel: 'MiniMax-M3',
      ),
      video: video,
      frames: frames,
    );

    expect(result.completedCount, 3);
    expect(visionService.maxActiveRequests, 3);
  });
}

AppSettings _testSettings() {
  return const AppSettings(
    exportDirectory: '',
    themePreference: AppThemePreference.system,
    cutImageNumberEnabled: false,
    cutImageNumberPosition: CutImageNumberPosition.topLeft,
    cutImageNumberBackgroundOpacity: 0.5,
    cutImageNumberTextScale: 1,
    storyboardSummaryPageEnabled: true,
    visionApiBaseUrl: 'http://127.0.0.1:1234',
    visionApiKey: 'test-key',
    visionModel: 'test-vlm',
    imageGenerationApiBaseUrl: '',
    imageGenerationApiKey: '',
    imageGenerationGeminiApiKey: '',
    imageGenerationModel: '',
    updateReleaseApiUrl: '',
    autoInstallUpdates: false,
    updateDownloadMode: UpdateDownloadMode.automatic,
    updateManualProxyUrl: '',
  );
}

class _BlockingVisionStoryboardService extends VisionStoryboardService {
  final started = Completer<void>();
  final _blocker = Completer<void>();

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
    File? previousImageFile,
    File? nextImageFile,
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await _blocker.future;
    throw const FormatException('cancelled');
  }

  @override
  void cancelActiveRequests() {
    if (!_blocker.isCompleted) {
      _blocker.completeError(const FormatException('cancelled'));
    }
  }
}

class _ConcurrentVisionStoryboardService extends VisionStoryboardService {
  var _activeRequests = 0;
  var maxActiveRequests = 0;

  @override
  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
    File? previousImageFile,
    File? nextImageFile,
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    _activeRequests++;
    if (_activeRequests > maxActiveRequests) {
      maxActiveRequests = _activeRequests;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _activeRequests--;
    return VisionImageAnalysis(
      caption: '镜头 $sequenceNo',
      detail: '测试详情',
      scene: '测试场景',
      props: '',
      people: '',
      expression: '',
      bodyAction: '',
      movementTrend: '',
      shotSize: '中景',
      composition: '',
      subjectDirection: '',
      gazeDirection: '',
      actionStage: '',
      spatialRelation: '',
      chronologyCue: '',
      rawResponse: '{}',
    );
  }

  @override
  Future<VisionStoryboardSummaryResult> summarizeStoryboard({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
  }) async {
    return const VisionStoryboardSummaryResult(
      outline: '测试大纲',
      content: '测试内容',
      scenes: '测试场景',
      props: '',
      rawResponse: '{}',
    );
  }

  @override
  Future<VisionVideoDimensionResult> analyzeVideoDimensions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    required Map<String, String> summary,
    bool allowThinking = false,
  }) async {
    return const VisionVideoDimensionResult(dimensions: {}, rawResponse: '{}');
  }
}
