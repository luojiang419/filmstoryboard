import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/domain/h3_video_prompt_adapter.dart';
import 'package:filmstoryboard/features/video_generation/domain/kling_duration_matcher.dart';
import 'package:filmstoryboard/features/video_generation/domain/kling_video_prompt_adapter.dart';
import 'package:filmstoryboard/features/video_generation/domain/source_video_preview_range.dart';
import 'package:test/test.dart';

void main() {
  test('IO 点严格按视频帧前后秒数截取并在首尾收窄', () {
    expect(
      SourceVideoPreviewRange.aroundFrame(
        sourceVideo: File('source.mp4'),
        timestampMs: 500,
        sourceDurationMs: 10000,
      ).inPoint,
      Duration.zero,
    );
    expect(
      SourceVideoPreviewRange.aroundFrame(
        sourceVideo: File('source.mp4'),
        timestampMs: 9500,
        sourceDurationMs: 10000,
      ).inPoint,
      const Duration(milliseconds: 8000),
    );
    final centered = SourceVideoPreviewRange.aroundFrame(
      sourceVideo: File('source.mp4'),
      timestampMs: 5000,
      sourceDurationMs: 10000,
    );
    expect(centered.inPoint, const Duration(milliseconds: 3500));
    expect(centered.duration, const Duration(milliseconds: 3000));
    final customized = SourceVideoPreviewRange.aroundFrame(
      sourceVideo: File('source.mp4'),
      timestampMs: 5000,
      sourceDurationMs: 10000,
      paddingSeconds: 2.5,
    );
    expect(customized.inPoint, const Duration(milliseconds: 2500));
    expect(customized.outPoint, const Duration(milliseconds: 7500));
    final short = SourceVideoPreviewRange.aroundFrame(
      sourceVideo: File('source.mp4'),
      timestampMs: 1800,
      sourceDurationMs: 2000,
    );
    expect(short.inPoint, const Duration(milliseconds: 300));
    expect(short.duration, const Duration(milliseconds: 1700));
  });

  test('源帧关联缺失时按帧路径恢复预览，并在缓存缺失时回退原始视频', () async {
    final root = await Directory.systemTemp.createTemp('source-preview-');
    addTearDown(() => root.delete(recursive: true));
    final originalVideo = await File(
      '${root.path}/original.mp4',
    ).writeAsBytes([1]);
    final frameFile = await File('${root.path}/frame.jpg').writeAsBytes([1]);
    final now = DateTime.utc(2026, 8, 4);
    final range = const SourceVideoPreviewResolver().resolve(
      video: SourceVideo(
        id: 'video-1',
        originalPath: originalVideo.path,
        fileName: 'original.mp4',
        storedPath: 'videos/missing.mp4',
        durationMs: 8000,
        frameRate: 25,
        width: 1920,
        height: 1080,
        hasAudio: true,
        frameCount: 1,
        successfulFrames: 1,
        failedFrames: 0,
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      ),
      frames: [
        VideoFrame(
          id: 'frame-1',
          videoId: 'video-1',
          index: 0,
          timestampMs: 4200,
          path: frameFile.path,
          width: 1920,
          height: 1080,
          sharpness: 1,
          brightness: 1,
          motionScore: 0,
          perceptualHash: '',
          isFocus: true,
          isSelected: true,
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
        ),
      ],
      shot: _shot().copyWith(
        sourceVideoFrameId: null,
        framePath: frameFile.path,
      ),
      workspaceRoot: root,
    );

    expect(range, isNotNull);
    expect(
      p.normalize(range!.sourceVideo.path),
      p.normalize(originalVideo.path),
    );
    expect(range.inPoint, const Duration(milliseconds: 2700));
    expect(p.normalize(range.thumbnailFile!.path), p.normalize(frameFile.path));
  });

  test('可灵提示词移除未传入引用并按动作背景镜头光影约束重组', () {
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: '图片1中的人物挥手，视频2作为动作参考',
    );

    expect(prompt, contains('主体与动作：人物从桌边起身'));
    expect(prompt, contains('背景与运动：暖色咖啡馆'));
    expect(prompt, contains('镜头语言：中景，缓慢推近'));
    expect(prompt, contains('光影氛围：窗边柔光'));
    expect(prompt, contains('约束：保持产品外观不变'));
    expect(prompt, isNot(contains('图片1')));
    expect(prompt, isNot(contains('视频2')));
  });

  test('步骤3已选择可灵时不再二次包裹提示词', () {
    const official = '以图片1作为首帧和主体外观参考；主体与动作：人物转身；镜头语言：缓慢推近';
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: official,
      availableImageReferences: 1,
    );

    expect(prompt, official);
  });

  test('首尾帧动作组提示词保留中间动作过程', () {
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot().copyWith(
        shotNumber: 4,
        content: '女模特开始从门口向前走',
        actionStage: '准备',
        movementTrend: '向前',
      ),
      actionSequence: [
        _shot().copyWith(
          shotNumber: 4,
          content: '女模特开始从门口向前走',
          actionStage: '准备',
          movementTrend: '向前',
        ),
        _shot().copyWith(
          shotNumber: 5,
          content: '女模特抬手并继续前行',
          actionStage: '进行',
          movementTrend: '向前行走并抬手',
        ),
        _shot().copyWith(
          shotNumber: 6,
          content: '女模特完成抬手展示动作',
          actionStage: '结果',
          movementTrend: '动作完成',
        ),
      ],
      availableImageReferences: 2,
    );

    expect(prompt, contains('尾帧和动作结果参考'));
    expect(prompt, contains('图片1作为首帧'));
    expect(prompt, contains('图片2作为尾帧'));
    expect(prompt, contains('从图片1自然过渡到图片2'));
    expect(prompt, contains('镜头1，5s，首帧（原镜头4）'));
    expect(prompt, contains('镜头2，5s，中间动作（原镜头5）'));
    expect(prompt, contains('镜头3，5s，尾帧（原镜头6）'));
    expect(prompt, contains('女模特抬手并继续前行'));
  });

  test('旧版输入图片可灵提示词会归一为图片1引用', () {
    const oldOfficial = '以输入图片作为首帧和主体外观参考；主体与动作：人物转身';
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: oldOfficial,
      availableImageReferences: 1,
    );

    expect(prompt, startsWith('以图片1作为首帧和主体外观参考'));
    expect(prompt, isNot(contains('以输入图片作为首帧')));
  });

  test('H3 提示词不会把已结构化提示词再次塞入核心创意', () {
    const structuredSource = '''
【参考素材说明】
@图片1 是画面参考图。

【核心创意】
5秒视频，主体与素材定义：将图片1中的产品定义为产品。

镜头5：全景，推；时长：5秒。

全局风格：顶级广告质感。

整体约束：不要字幕、不要水印。

【画面过程描述】
0-5秒：全景，推。

【声音设计】
N/A

非叙事性音乐：N/A
''';

    final prompt = const H3VideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: structuredSource,
      availableImageReferences: 1,
      globalStyle: '顶级广告质感',
    );

    expect(_occurrences(prompt, '【参考素材说明】'), 1);
    expect(_occurrences(prompt, '【核心创意】'), 1);
    expect(_occurrences(prompt, '【画面过程描述】'), 1);
    expect(_occurrences(prompt, '【整体要求补充】'), 1);
    expect(_occurrences(prompt, '【声音设计】'), 1);
    expect(_occurrences(prompt, '非叙事性音乐：'), 1);
    expect(prompt, isNot(contains('主体与素材定义：')));
    expect(prompt, isNot(contains('镜头5：全景')));
    expect(prompt, isNot(contains('整体约束：不要字幕')));
  });

  test('H3 多帧镜头组按实际参考帧顺序编号', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot().copyWith(shotNumber: 1, content: '人物走入画面'),
      actionSequence: [
        _shot().copyWith(shotNumber: 1, content: '人物走入画面'),
        _shot().copyWith(
          shotNumber: 2,
          content: '人物抬手展示产品',
          actionStage: '中间动作',
        ),
        _shot().copyWith(shotNumber: 3, content: '人物完成展示动作'),
      ],
      availableImageReferences: 3,
    );

    expect(prompt, contains('@图片1 是首帧参考图'));
    expect(prompt, contains('@图片2 是镜头2中间动作参考帧'));
    expect(prompt, contains('@图片3 是尾帧参考图'));
  });

  test('时长按动态允许值取最近值，相同差值选择较短值', () {
    const matcher = KlingDurationMatcher();
    expect(matcher.closest(desiredSeconds: 7.5, allowed: [5, 10]), 5);
    expect(matcher.closest(desiredSeconds: 8.6, allowed: [3, 5, 9, 10]), 9);
    expect(
      matcher.forModel(
        desiredSeconds: 12.8,
        model: const KlingModelSpec(
          model: 'dynamic-model',
          alias: '',
          description: '',
          arguments: [
            KlingArgumentSpec(
              name: 'duration',
              required: false,
              defaultValue: '5',
              allowedValues: ['3', '5', '10', '15'],
              description: '',
            ),
          ],
        ),
      ),
      15,
    );
  });
}

int _occurrences(String text, String pattern) =>
    RegExp(RegExp.escape(pattern)).allMatches(text).length;

ScriptShot _shot() => ScriptShot(
  id: 'shot-1',
  scriptId: 'script-1',
  shotNumber: 1,
  durationSeconds: 5,
  framePath: 'frame.jpg',
  visual: '',
  content: '人物从桌边起身',
  shotSize: '中景',
  cameraMovement: '缓慢推近',
  cameraNotes: '',
  scene: '暖色咖啡馆',
  productCode: '',
  productStyling: '',
  dialogue: '',
  sound: '',
  prompt: '',
  replicationInstructions: '保持产品外观不变',
  lightingMood: '窗边柔光',
  status: ProcessingStatus.completed,
  updatedAt: DateTime.utc(2026, 8, 4),
);
