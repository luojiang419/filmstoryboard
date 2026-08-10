import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
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

  test('多帧镜头组的 IO 点使用首帧到末帧的精确时间区间', () async {
    final root = await Directory.systemTemp.createTemp('source-group-preview-');
    addTearDown(() => root.delete(recursive: true));
    final sourceVideo = await File('${root.path}/source.mp4').writeAsBytes([1]);
    final firstFrameFile = await File(
      '${root.path}/first.jpg',
    ).writeAsBytes([1]);
    final lastFrameFile = await File('${root.path}/last.jpg').writeAsBytes([1]);
    final now = DateTime.utc(2026, 8, 7);
    final range = const SourceVideoPreviewResolver().resolve(
      video: SourceVideo(
        id: 'video-1',
        originalPath: sourceVideo.path,
        fileName: 'source.mp4',
        storedPath: sourceVideo.path,
        durationMs: 10000,
        frameRate: 25,
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
      frames: [
        VideoFrame(
          id: 'frame-1',
          videoId: 'video-1',
          index: 0,
          timestampMs: 1200,
          path: firstFrameFile.path,
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
        VideoFrame(
          id: 'frame-2',
          videoId: 'video-1',
          index: 1,
          timestampMs: 6800,
          path: lastFrameFile.path,
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
        sourceVideoFrameId: 'frame-1',
        framePath: firstFrameFile.path,
      ),
      endShot: _shot().copyWith(
        shotNumber: 2,
        sourceVideoFrameId: 'frame-2',
        framePath: lastFrameFile.path,
      ),
      workspaceRoot: root,
    );

    expect(range, isNotNull);
    expect(range!.inPoint, const Duration(milliseconds: 1200));
    expect(range.outPoint, const Duration(milliseconds: 6800));
    expect(
      p.normalize(range.thumbnailFile!.path),
      p.normalize(firstFrameFile.path),
    );
  });

  test('可灵提示词移除未传入引用并压缩为动作与运镜骨架', () {
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: '图片1中的人物挥手，视频2作为动作参考',
    );

    expect(prompt, contains('人物从桌边起身'));
    expect(prompt, contains('暖色咖啡馆'));
    expect(prompt, contains('中景'));
    expect(prompt, contains('缓慢推近'));
    expect(prompt, contains('窗边柔光'));
    expect(prompt, contains('保持产品外观不变'));
    expect(prompt, isNot(contains('主体与动作：')));
    expect(prompt, isNot(contains('背景与运动：')));
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

  test('可灵首尾帧动作组用自然阶段保留中间过程且不写内部镜号和秒表', () {
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

    expect(prompt, contains('图片1为首帧，图片2为尾帧'));
    expect(prompt, contains('单镜头连续完成'));
    expect(prompt, contains('开头：'));
    expect(prompt, contains('随后：'));
    expect(prompt, contains('最后：'));
    expect(prompt, contains('女模特抬手并继续前行'));
    expect(prompt, isNot(contains('原镜头')));
    expect(prompt, isNot(contains('镜头4')));
    expect(prompt, isNot(matches(RegExp(r'\d+(?:\.\d+)?(?:秒|s)[-—至到]'))));
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
    expect(_occurrences(prompt, '【整体要求补充】'), 0);
    expect(_occurrences(prompt, '【声音设计】'), 0);
    expect(_occurrences(prompt, '非叙事性音乐：'), 1);
    expect(prompt, isNot(contains('主体与素材定义：')));
    expect(prompt, isNot(contains('镜头5：全景')));
    expect(prompt, isNot(contains('整体约束：不要字幕')));
  });

  test('H3 本地拼接把所选叙事风格作为独立成片锁且不同风格结果可辨识', () {
    final productStyle = H3PromptStyle.resolve('minimalist-product-ad');
    final brandStyle = H3PromptStyle.resolve('brand-promo');
    final productPrompt = const H3VideoPromptAdapter().adapt(
      _shot(),
      narrativeStyle: productStyle.videoPromptInstruction,
    );
    final brandPrompt = const H3VideoPromptAdapter().adapt(
      _shot(),
      narrativeStyle: brandStyle.videoPromptInstruction,
    );

    expect(productPrompt, contains('【镜头叙事风格】'));
    expect(productPrompt, contains('产品本体颜色'));
    expect(productPrompt, contains('3–5 个英文词'));
    expect(productPrompt, isNot(contains('场景/意图')));
    expect(brandPrompt, contains('【镜头叙事风格】'));
    expect(brandPrompt, contains('场景/意图'));
    expect(brandPrompt, contains('不虚构任何功能'));
    expect(brandPrompt, isNot(contains('3–5 个英文词')));
    expect(productPrompt, isNot(brandPrompt));
    expect(_occurrences(productPrompt, '【镜头叙事风格】'), 1);
  });

  test('8 个官方风格都能生成唯一且未被截掉开头的 H3 成片风格段', () {
    final prompts = <String>{};
    for (final style in H3PromptStyle.values.skip(1)) {
      final prompt = const H3VideoPromptAdapter().adapt(
        _shot(),
        narrativeStyle: style.videoPromptInstruction,
      );
      expect(prompt, contains('【镜头叙事风格】'), reason: style.id);
      expect(
        prompt,
        contains(style.videoPromptInstruction.substring(0, 24)),
        reason: style.id,
      );
      prompts.add(prompt);
    }
    expect(prompts, hasLength(8));
  });

  test('H3 官方六段提示词在视频提交前保持原样直通', () {
    const officialPrompt = '''subject_definitions:
- <Picture 1>: Opening frame.
- <Picture 2>: Product identity.
summary: Product presentation.
retention_analysis: Retain composition and product identity.
detailed_description: [Shot 1] The camera moves slowly.
overall_soundscape: Quiet studio ambience.
non_diegetic_music: Minimal ambient music.''';

    final prompt = const H3VideoPromptAdapter().adapt(
      _shot(),
      sourcePrompt: officialPrompt,
      availableImageReferences: 2,
      globalStyle: '不应再次注入的风格',
      narrativeStyle: '不应再次注入的叙事风格',
    );

    expect(prompt, officialPrompt);
    expect(prompt, isNot(contains('【核心创意】')));
    expect(prompt, isNot(contains('【镜头叙事风格】')));
    expect(_occurrences(prompt, 'subject_definitions:'), 1);
    expect(_occurrences(prompt, 'non_diegetic_music:'), 1);
  });

  test('H3 多帧镜头组默认按顺序动作参考而非精确关键帧处理', () {
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

    expect(prompt, contains('@图片1至@图片3'));
    expect(prompt, contains('顺序动作参考'));
    expect(prompt, isNot(contains('首帧')));
    expect(prompt, isNot(contains('尾帧')));
    expect(prompt, contains('5秒视频'));
    expect(prompt, isNot(contains('15秒视频')));
  });

  test('H3 普通多帧组使用拍摄脚本显示的组尾时长', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot().copyWith(durationSeconds: 1),
      actionSequence: [
        _shot().copyWith(shotNumber: 1, durationSeconds: 1),
        _shot().copyWith(shotNumber: 2, durationSeconds: 4),
      ],
      availableImageReferences: 2,
      useStartEndFrameReferences: false,
    );

    expect(prompt, contains('4秒视频'));
    expect(prompt, isNot(contains('1秒视频')));
  });

  test('H3 明确首尾帧模式只绑定两张精确帧并禁止切镜', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot().copyWith(shotNumber: 1, content: '人物开始拿起产品'),
      actionSequence: [
        _shot().copyWith(shotNumber: 1, content: '人物开始拿起产品'),
        _shot().copyWith(shotNumber: 3, content: '人物完成展示动作'),
      ],
      availableImageReferences: 2,
      useStartEndFrameReferences: true,
    );

    expect(prompt, contains('@图片1是首帧，@图片2是尾帧'));
    expect(prompt, contains('从@图片1状态开始'));
    expect(prompt, contains('自然到达@图片2状态'));
    expect(prompt, contains('单镜头连续完成，不切镜'));
    expect(prompt, contains('开头：从@图片1状态开始'));
    expect(prompt, contains('最后：自然到达@图片2状态'));
    expect(prompt, isNot(contains('0秒-')));
  });

  test('H3 普通手动镜头组使用多参考图语义而不是首尾帧语义', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot().copyWith(shotNumber: 4, content: '人物走入画面'),
      actionSequence: [
        _shot().copyWith(shotNumber: 4, content: '人物走入画面'),
        _shot().copyWith(shotNumber: 5, content: '人物抬手展示产品'),
        _shot().copyWith(shotNumber: 6, content: '人物完成展示动作'),
      ],
      availableImageReferences: 3,
      useStartEndFrameReferences: false,
    );

    expect(prompt, contains('@图片1至@图片3'));
    expect(prompt, isNot(contains('依次对应镜头')));
    expect(prompt, isNot(contains('镜头4至6')));
    expect(prompt, contains('衔接@图片1'));
    expect(prompt, contains('衔接@图片2'));
    expect(prompt, contains('衔接@图片3'));
    expect(prompt, isNot(contains('首帧参考图')));
    expect(prompt, isNot(contains('尾帧参考图')));
    expect(prompt, isNot(contains('只补足@图片1到@图片2之间')));
    expect(prompt, contains('5秒视频'));
    expect(prompt, isNot(contains('15秒视频')));
    expect(prompt, contains('开头：衔接@图片1'));
    expect(prompt, contains('随后：衔接@图片2'));
    expect(prompt, contains('最后：衔接@图片3'));
    expect(prompt, isNot(matches(RegExp(r'\d+(?:\.\d+)?秒-\d+(?:\.\d+)?秒'))));
  });

  test('H3 连续多帧只输出组级事实和阶段变化，不泄漏分析证据', () {
    final head = _shot().copyWith(
      shotNumber: 7,
      content:
          '金发女模特身穿牛仔套装，斜挎焦糖色小包，从画面左侧向右行走；'
          '金发女模特继续向右行走；金发女模特持续向右行走',
      scene: '古典建筑立面前的人行道',
      cameraMovement: '摄影机与人物同步匀速水平右移，保持主体比例稳定',
      cameraNotes:
          '镜头目的：推进街拍节奏；速度曲线：恒定匀速；'
          '参考原运镜：水平右移；多帧证据：背景持续向左流动',
      composition: '起：人物位于左侧三分之一 → 落：人物位于中部偏左',
      cameraAngle: '腰部齐平略偏下，轻微仰拍',
      lightingMood: '柔和自然日光从左上方洒落，人物发丝形成暖色高光',
      colorPalette: '冷暖对比，整体自然高级',
      visualFocus: '焦点锁定人物面部与包体轮廓',
      sound:
          '音效设计：脚步声、布料摩擦和包扣轻响；'
          '同步要求：所有声音按画面事件逐一对齐；'
          '非叙事性音乐：低频克制的无歌词氛围音乐',
    );
    final prompt = const H3VideoPromptAdapter().adapt(
      head,
      actionSequence: [
        head.copyWith(actionStage: '起步', movementTrend: '右侧前景逐渐退出'),
        _shot().copyWith(
          shotNumber: 8,
          content: '模特保持自然步态向右行走，包袋与发梢轻微摆动',
          actionStage: '行进',
          movementTrend: '背景铁艺与石墙向左移动',
        ),
        _shot().copyWith(
          shotNumber: 9,
          content: '模特移动到画面中部偏左并稳定收束',
          actionStage: '收束',
          movementTrend: '左下出现新前景遮挡，右侧石柱入画',
        ),
      ],
      availableImageReferences: 3,
      useStartEndFrameReferences: false,
      constraints: '不新增人物或文字',
    );

    expect(prompt, contains('@图片1至@图片3'));
    expect(prompt, contains('顺序动作参考'));
    expect(prompt, isNot(contains('锁定该镜头')));
    expect(prompt, isNot(contains('多帧证据')));
    expect(prompt, isNot(contains('参考原运镜')));
    expect(prompt, isNot(contains('镜头目的')));
    expect(prompt, isNot(contains('摄影备注')));
    expect(_occurrences(prompt, head.cameraMovement), 1);
    expect(_occurrences(prompt, head.scene), 1);
    expect(_occurrences(prompt, '【声音设计】'), 0);
    expect(_occurrences(prompt, '非叙事性音乐：'), 1);
    expect(prompt, contains('开头：衔接@图片1'));
    expect(prompt, contains('最后：衔接@图片3'));
    expect(prompt, isNot(matches(RegExp(r'\d+(?:\.\d+)?秒-\d+(?:\.\d+)?秒'))));
    expect(prompt.length, lessThanOrEqualTo(800));
  });

  test('可灵普通多帧镜头组使用顺序参考和自然阶段而不是内部镜号秒表', () {
    final prompt = const KlingVideoPromptAdapter().adapt(
      _shot().copyWith(shotNumber: 4, content: '人物走入画面'),
      actionSequence: [
        _shot().copyWith(shotNumber: 4, content: '人物走入画面'),
        _shot().copyWith(shotNumber: 5, content: '人物抬手展示产品'),
        _shot().copyWith(shotNumber: 6, content: '人物完成展示动作'),
      ],
      availableImageReferences: 3,
      useStartEndFrameReferences: false,
    );

    expect(prompt, contains('图片1至图片3为同一连续动作的顺序参考'));
    expect(prompt, contains('开头：人物走入画面'));
    expect(prompt, contains('随后：人物抬手展示产品'));
    expect(prompt, contains('最后：人物完成展示动作'));
    expect(prompt, isNot(contains('原镜头')));
    expect(prompt, isNot(contains('镜头4')));
    expect(prompt, isNot(contains('第1阶段')));
    expect(prompt, isNot(matches(RegExp(r'\d+(?:\.\d+)?(?:秒|s)[-—至到]'))));
    expect(prompt.length, lessThanOrEqualTo(500));
  });

  test('可灵连续多帧不复述服装、摄影分析证据和冗长声音规则', () {
    final head = _shot().copyWith(
      shotNumber: 7,
      content: '金发女模特身穿深蓝牛仔背心、白色内搭和牛仔短裤，斜挎焦糖色小包，从左向右行走',
      scene: '古典建筑立面前的人行道',
      cameraMovement: '摄影机与人物同步匀速水平右移，保持主体比例稳定',
      cameraNotes: '镜头目的：推进街拍节奏；参考原运镜：水平右移；多帧证据：背景持续向左流动',
      composition: '人物从左侧三分之一移动到中部偏左',
      lightingMood: '柔和自然日光从左上方洒落',
      sound: '音效设计：脚步声、布料摩擦和包扣轻响；同步要求：所有声音按画面事件逐一对齐；禁止慢放和时间拉伸',
    );
    final prompt = const KlingVideoPromptAdapter().adapt(
      head,
      actionSequence: [
        head,
        _shot().copyWith(shotNumber: 8, content: '模特保持自然步态向右行走'),
        _shot().copyWith(shotNumber: 9, content: '模特移动到画面中部偏左并稳定收束'),
      ],
      availableImageReferences: 3,
      useStartEndFrameReferences: false,
    );

    expect(prompt, contains('图片1至图片3'));
    expect(prompt, contains('摄影机与人物同步匀速水平右移'));
    expect(prompt, isNot(contains('牛仔背心')));
    expect(prompt, isNot(contains('白色内搭')));
    expect(prompt, isNot(contains('焦糖色小包')));
    expect(prompt, isNot(contains('镜头目的')));
    expect(prompt, isNot(contains('参考原运镜')));
    expect(prompt, isNot(contains('多帧证据')));
    expect(prompt, isNot(contains('同步要求')));
    expect(prompt, isNot(contains('禁止慢放')));
    expect(prompt.length, lessThanOrEqualTo(500));
  });

  test('H3 非官方草稿将动作音效与配乐分离并压缩同步规则', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot().copyWith(
        sound: '音效设计：鞋底落地声逐次同步；同步要求：保持自然瞬态；非叙事性音乐：N/A（除非脚本明确指定）',
      ),
    );

    expect(prompt, contains('鞋底落地声逐次同步'));
    expect(prompt, contains('保持真实速度和自然音高'));
    expect(prompt, isNot(contains('禁止因慢动作、缓慢运镜或舒缓情绪而慢放声音')));
    expect(prompt, contains('非叙事性音乐：N/A'));
    expect(prompt, isNot(contains('非叙事性音乐：音效设计')));
    expect(prompt, contains('画面：'));
    expect(prompt, isNot(contains('0-5秒')));
  });

  test('H3 只保留总时长并移除叙事风格中的逐秒安排', () {
    final prompt = const H3VideoPromptAdapter().adapt(
      _shot(),
      narrativeStyle: '0-2秒：人物起身；2-5秒：走向产品；第3秒出现高光。',
    );

    expect(prompt, contains('5秒视频'));
    expect(prompt, contains('人物起身'));
    expect(prompt, contains('走向产品'));
    expect(prompt, isNot(contains('第3秒')));
    expect(prompt, isNot(contains('出现品牌Logo')));
    expect(prompt, isNot(contains('0-5秒')));
    expect(prompt, isNot(matches(RegExp(r'\d+(?:\.\d+)?秒-\d+(?:\.\d+)?秒'))));
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
