import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/video_analysis/application/video_storyboard_bridge.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('视频解析结果按数据库帧顺序转换为故事板图片和摘要', () {
    final now = DateTime.utc(2026, 8, 2);
    final video = SourceVideo(
      id: 'video-1',
      originalPath: r'C:\input\demo.mp4',
      fileName: 'demo.mp4',
      storedPath: 'videos/demo.mp4',
      durationMs: 3000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 3,
      successfulFrames: 2,
      failedFrames: 1,
      status: ProcessingStatus.partial,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    final frames = [
      _videoFrame(id: 'frame-2', videoId: video.id, index: 2, now: now),
      _videoFrame(id: 'frame-0', videoId: video.id, index: 0, now: now),
      _videoFrame(id: 'frame-1', videoId: video.id, index: 1, now: now),
    ];
    final result = VideoStoryboardBridge.build(
      video: video,
      frames: frames,
      frameAnalyses: [
        _frameAnalysis(
          id: 'analysis-2',
          videoId: video.id,
          frameId: 'frame-2',
          sequenceNo: 3,
          caption: '第三个已解析镜头',
          now: now,
        ),
        _frameAnalysis(
          id: 'analysis-0',
          videoId: video.id,
          frameId: 'frame-0',
          sequenceNo: 1,
          caption: '第一个已解析镜头',
          now: now,
        ),
        _frameAnalysis(
          id: 'analysis-failed',
          videoId: video.id,
          frameId: 'frame-1',
          sequenceNo: 2,
          caption: '失败结果不应入板',
          status: ProcessingStatus.failed,
          now: now,
        ),
      ],
      shots: const [],
      summary: VideoSummary(
        id: 'summary-1',
        videoId: video.id,
        fields: const {
          'outline': '开场到产品展示',
          'content': '人物展示产品核心卖点',
          'scenes': '厨房',
          'props': '产品包装',
        },
        rawResponse: '{}',
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: now,
      ),
      resolveFramePath: (frame) => 'resolved/${frame.id}.jpg',
    );

    expect(result.sourceId, 'video:video-1');
    expect(result.boardName, 'demo · 视频解析故事板');
    expect(result.images.map((image) => image.stableId), [
      'video-frame:frame-0',
      'video-frame:frame-2',
    ]);
    expect(result.images.map((image) => image.caption), [
      '第一个已解析镜头',
      '第三个已解析镜头',
    ]);
    expect(result.images.first.path, 'resolved/frame-0.jpg');
    expect(result.summary?.outline, '开场到产品展示');
  });

  test('长视频的全部解析镜头会生成同一张故事板', () {
    final now = DateTime.utc(2026, 8, 3);
    final video = SourceVideo(
      id: 'long-video',
      originalPath: 'long-video.mp4',
      fileName: 'long-video.mp4',
      storedPath: 'videos/long-video.mp4',
      durationMs: 101000,
      frameRate: 24,
      width: 1920,
      height: 1080,
      hasAudio: true,
      frameCount: 101,
      successfulFrames: 101,
      failedFrames: 0,
      status: ProcessingStatus.completed,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    final frames = [
      for (var index = 0; index < 101; index++)
        _videoFrame(
          id: 'long-frame-$index',
          videoId: video.id,
          index: index,
          now: now,
        ),
    ];
    final analyses = [
      for (var index = 0; index < 101; index++)
        _frameAnalysis(
          id: 'long-analysis-$index',
          videoId: video.id,
          frameId: 'long-frame-$index',
          sequenceNo: index + 1,
          caption: '镜头 ${index + 1}',
          now: now,
        ),
    ];

    final boards = VideoStoryboardBridge.buildSegments(
      video: video,
      frames: frames,
      frameAnalyses: analyses,
      shots: const [],
      summary: null,
      resolveFramePath: (frame) => 'resolved/${frame.id}.jpg',
    );

    expect(boards, hasLength(1));
    expect(boards.single.images, hasLength(101));
    expect(boards.single.sourceId, 'video:long-video');
    expect(boards.single.boardName, 'long-video · 视频解析故事板');
  });

  test('视频故事板生成后可触发多模态解析并写入连贯文本', () async {
    final root = await Directory.systemTemp.createTemp(
      'video_storyboard_vision_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(
      database,
      directories,
      visionDefaultsText: 'url:127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
    );
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final visionService = _FakeVideoStoryboardVisionService();
    final controller = StoryboardController(
      database: database,
      directories: directories,
      settingsController: settingsController,
      visionService: visionService,
    );
    addTearDown(() async {
      controller.dispose();
      visionService.close();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final now = DateTime.utc(2026, 8, 2);
    final firstFrame = await _writeFrame(
      directories.frames,
      'video-frame-1.png',
      img.ColorRgb8(220, 80, 70),
    );
    final secondFrame = await _writeFrame(
      directories.frames,
      'video-frame-2.png',
      img.ColorRgb8(60, 120, 220),
    );
    final video = SourceVideo(
      id: 'video-vision',
      originalPath: r'C:\input\reference.mp4',
      fileName: 'reference.mp4',
      storedPath: 'videos/reference.mp4',
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
    final frames = [
      _videoFrame(id: 'frame-1', videoId: video.id, index: 0, now: now),
      _videoFrame(id: 'frame-2', videoId: video.id, index: 1, now: now),
    ];
    final storyboard = VideoStoryboardBridge.build(
      video: video,
      frames: frames,
      frameAnalyses: [
        _frameAnalysis(
          id: 'analysis-1',
          videoId: video.id,
          frameId: 'frame-1',
          sequenceNo: 1,
          caption: '女模特在花廊里微笑',
          now: now,
        ),
        _frameAnalysis(
          id: 'analysis-2',
          videoId: video.id,
          frameId: 'frame-2',
          sequenceNo: 2,
          caption: '女模特背身走在花廊中',
          now: now,
        ),
      ],
      shots: const [],
      summary: null,
      resolveFramePath: (frame) =>
          frame.id == 'frame-1' ? firstFrame.path : secondFrame.path,
    );

    final boardId = await controller.createOrReplaceBoardFromExternalImages(
      sourceId: storyboard.sourceId,
      boardName: storyboard.boardName,
      images: storyboard.images,
      summary: storyboard.summary,
    );
    expect(boardId, 'external-board:video:video-vision');
    expect(controller.value.selectedBoard!.items.map((item) => item.caption), [
      '女模特在花廊里微笑',
      '女模特背身走在花廊中',
    ]);

    await controller.analyzeSelectedBoardWithVision();

    final board = controller.value.selectedBoard!;
    expect(visionService.analyzeImageCount, 2);
    expect(board.items.map((item) => item.caption), [
      '开场，女模特在花廊回眸微笑。',
      '随后，女模特背身向前走入花廊。',
    ]);
    expect(board.summary?.outline, '女模特在花廊中由回眸转入前行');
    expect(controller.value.message, '故事板自动解析完成，已连贯填入 2 条描述');
  });

  test('视频焦点帧重复生成时更新同一故事板并保留来源和镜头文案', () async {
    final root = await Directory.systemTemp.createTemp(
      'video_storyboard_bridge_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final controller = StoryboardController(
      database: database,
      directories: directories,
    );
    addTearDown(() async {
      controller.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final firstFrame = await _writeFrame(
      directories.frames,
      'frame-1.png',
      img.ColorRgb8(220, 80, 70),
    );
    final secondFrame = await _writeFrame(
      directories.frames,
      'frame-2.png',
      img.ColorRgb8(60, 120, 220),
    );
    final images = [
      StoryboardExternalImage(
        stableId: 'video-frame:frame-1',
        sourceName: 'reference.mp4',
        path: firstFrame.path,
        width: 64,
        height: 36,
        caption: '产品从暗处进入主光区',
      ),
      StoryboardExternalImage(
        stableId: 'video-frame:frame-2',
        sourceName: 'reference.mp4',
        path: secondFrame.path,
        width: 64,
        height: 36,
        caption: '特写展示产品纹理',
      ),
    ];

    final firstBoardId = await controller
        .createOrReplaceBoardFromExternalImages(
          sourceId: 'video:video-1',
          boardName: 'reference · 焦点镜头',
          images: images,
        );
    final secondBoardId = await controller
        .createOrReplaceBoardFromExternalImages(
          sourceId: 'video:video-1',
          boardName: 'reference · 焦点镜头',
          images: [
            images.first,
            StoryboardExternalImage(
              stableId: images.last.stableId,
              sourceName: images.last.sourceName,
              path: images.last.path,
              width: images.last.width,
              height: images.last.height,
              caption: '更新后的产品纹理特写',
            ),
          ],
        );

    expect(firstBoardId, 'external-board:video:video-1');
    expect(secondBoardId, firstBoardId);
    expect(
      controller.value.boards.where((board) => board.id == firstBoardId),
      hasLength(1),
    );
    final board = controller.value.selectedBoard!;
    expect(board.items, hasLength(2));
    expect(board.items.map((item) => item.asset.id), [
      'external-cut:video-frame:frame-1',
      'external-cut:video-frame:frame-2',
    ]);
    expect(board.items.last.caption, '更新后的产品纹理特写');
    expect(
      board.items.every((item) => item.asset.sourceName == 'reference.mp4'),
      isTrue,
    );
    expect(
      database.listCutResults().where(
        (record) => record.taskId == 'external-task:video:video-1',
      ),
      hasLength(2),
    );
  });
}

VideoFrame _videoFrame({
  required String id,
  required String videoId,
  required int index,
  required DateTime now,
}) {
  return VideoFrame(
    id: id,
    videoId: videoId,
    index: index,
    timestampMs: index * 1000,
    path: 'frames/$id.jpg',
    width: 1920,
    height: 1080,
    sharpness: 0.8,
    brightness: 0.5,
    motionScore: 0,
    perceptualHash: 'hash-$id',
    isFocus: false,
    isSelected: true,
    status: ProcessingStatus.completed,
    errorMessage: '',
    createdAt: now,
  );
}

VideoFrameAnalysis _frameAnalysis({
  required String id,
  required String videoId,
  required String frameId,
  required int sequenceNo,
  required String caption,
  required DateTime now,
  ProcessingStatus status = ProcessingStatus.completed,
}) {
  return VideoFrameAnalysis(
    id: id,
    videoId: videoId,
    frameId: frameId,
    sequenceNo: sequenceNo,
    dimensions: {'caption': caption},
    rawResponse: '{}',
    status: status,
    errorMessage: status == ProcessingStatus.completed ? '' : 'failed',
    createdAt: now,
    updatedAt: now,
  );
}

Future<File> _writeFrame(
  Directory directory,
  String name,
  img.Color color,
) async {
  final image = img.Image(width: 64, height: 36);
  img.fill(image, color: color);
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(img.encodePng(image));
  return file;
}

class _FakeVideoStoryboardVisionService extends VisionStoryboardService {
  int analyzeImageCount = 0;

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
    analyzeImageCount++;
    return VisionImageAnalysis(
      caption: sequenceNo == 1 ? '女模特回眸微笑' : '女模特背身前行',
      detail: sequenceNo == 1 ? '女模特站在玫瑰花廊下回眸微笑' : '女模特背对镜头沿花廊继续向前',
      scene: '户外花廊',
      props: '玫瑰、透明棚顶',
      people: '女模特',
      expression: sequenceNo == 1 ? '回眸微笑' : '表情不可见',
      bodyAction: sequenceNo == 1 ? '站立回眸' : '背身行走',
      movementTrend: sequenceNo == 1 ? '转身回望' : '远离镜头',
      cameraMovement: '固定',
      shotSize: sequenceNo == 1 ? '中景' : '全景',
      composition: sequenceNo == 1 ? '人物偏左，花廊纵深延伸' : '人物居中，花廊形成引导线',
      subjectDirection: sequenceNo == 1 ? '三分之二侧面看向镜头' : '背对镜头',
      gazeDirection: sequenceNo == 1 ? '看向镜头' : '不明显',
      actionStage: sequenceNo == 1 ? '建立' : '推进',
      spatialRelation: '人物位于花廊通道中',
      chronologyCue: sequenceNo == 1 ? '开场建立' : '动作推进',
      cameraAngle: '眼平视角',
      visualFocus: sequenceNo == 1 ? '女模特的回眸笑容' : '女模特背影和花廊纵深',
      lightingMood: '明亮自然光',
      colorPalette: '清爽蓝绿与暖黄色',
      narrativeFunction: sequenceNo == 1 ? '建立' : '推进',
      transitionHint: sequenceNo == 1 ? '适合开场' : '承接上一回眸动作',
      rawResponse: '{}',
    );
  }

  @override
  Future<VisionStoryboardCaptionRewriteResult> rewriteStoryboardCaptions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
    void Function(int completed, int total)? onProgress,
  }) async {
    onProgress?.call(1, 1);
    return const VisionStoryboardCaptionRewriteResult(
      captions: ['开场，女模特在花廊回眸微笑。', '随后，女模特背身向前走入花廊。'],
      rawResponse: '{}',
      initialReturnedCount: 2,
    );
  }

  @override
  Future<VisionStoryboardSummaryResult> summarizeStoryboard({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
  }) async {
    return const VisionStoryboardSummaryResult(
      outline: '女模特在花廊中由回眸转入前行',
      content: '画面从女模特在花廊下回眸微笑开始，随后转为背身向前行走，形成轻松连续的游园片段。',
      scenes: '户外花廊',
      props: '玫瑰、透明棚顶',
      rawResponse: '{}',
    );
  }
}
