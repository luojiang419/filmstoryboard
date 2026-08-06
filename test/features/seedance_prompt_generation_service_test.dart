import 'package:filmstoryboard/features/replicate/data/seedance_prompt_generation_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  const service = SeedancePromptGenerationService();
  final now = DateTime.utc(2026, 8, 2);

  test('按即梦规则顺序生成主体、镜头、风格和约束且不暴露 Asset ID', () {
    final shot = _shot(now).copyWith(
      cameraMovement: '缓慢推镜',
      composition: '主体位于画面右侧，左侧留白',
      cameraAngle: '平视角度',
      lightingMood: '自然漫射光，明亮清新',
      colorPalette: '暖橙色、绿色与蓝天白云',
      visualFocus: '人物面部表情与产品色彩对比',
      transitionHint: '适合作为中段人物特写插入',
    );
    final assets = [
      _asset(
        now,
        id: 'internal-character-id',
        type: ReplicateAssetType.character,
        name: '现代模特',
        description: '短发、白衬衫、银色耳饰的女人',
        path: 'character.png',
        number: 1,
      ),
      _asset(
        now,
        id: 'internal-product-id',
        type: ReplicateAssetType.product,
        name: '玻璃精华瓶',
        description: '透明瓶身、银色泵头',
        path: 'product.png',
        number: 2,
      ),
      _asset(
        now,
        id: 'internal-video-id',
        type: ReplicateAssetType.video,
        name: '参考运镜',
        description: '平稳广告运镜',
        path: 'camera.mp4',
        number: 1,
      ),
      _asset(
        now,
        id: 'internal-audio-id',
        type: ReplicateAssetType.audio,
        name: '参考音乐',
        description: '轻快节奏',
        path: 'music.wav',
        number: 1,
      ),
    ];

    final result = service.generate(
      shot: shot,
      assets: assets,
      globalStyle: '暖白高调商业摄影，真实材质',
      constraints: SeedancePromptGenerationService.defaultConstraints,
    );

    expect(result.prompt, contains('将图片1中的短发、白衬衫、银色耳饰的女人定义为现代模特'));
    expect(result.prompt, contains('将图片2中的透明瓶身、银色泵头定义为产品玻璃精华瓶'));
    expect(result.prompt, contains('参考视频1中的主要运镜'));
    expect(result.prompt, contains('参考音频1中的音色'));
    expect(result.prompt, contains('镜头1：近景，缓慢推镜'));
    expect(result.prompt, contains('时长：3秒'));
    expect(result.prompt, contains('构图：主体位于画面右侧，左侧留白'));
    expect(result.prompt, contains('机位：平视角度'));
    expect(result.prompt, contains('光影/氛围：自然漫射光，明亮清新'));
    expect(result.prompt, contains('色彩：暖橙色、绿色与蓝天白云'));
    expect(result.prompt, contains('视觉焦点：人物面部表情与产品色彩对比'));
    expect(result.prompt, contains('剪辑衔接：适合作为中段人物特写插入'));
    expect(result.prompt, contains('{现在就来试试}'));
    expect(result.prompt, contains('<轻快音乐进入>'));
    expect(result.prompt, contains('全局风格：暖白高调商业摄影'));
    expect(result.prompt, contains('保持无字幕'));
    expect(result.prompt, isNot(contains('internal-character-id')));
    expect(result.prompt, isNot(contains('internal-product-id')));
    expect(result.warnings, isEmpty);
  });

  test('多运镜只保留一种并对过多素材和缺失动作给出可读提示', () {
    final shot = _shot(
      now,
    ).copyWith(content: '', cameraMovement: '缓慢推镜、平稳横移、摇镜');
    final assets = [
      for (var index = 1; index <= 6; index++)
        _asset(
          now,
          id: 'asset-$index',
          type: ReplicateAssetType.scene,
          name: '场景$index',
          description: '场景参考$index',
          path: 'scene-$index.png',
          number: index,
        ),
    ];

    final result = service.generate(
      shot: shot,
      assets: assets,
      globalStyle: '',
      constraints: '',
    );

    expect(result.prompt, contains('缓慢推镜'));
    expect(result.prompt, isNot(contains('平稳横移')));
    expect(result.warnings, contains('原始运镜包含多种方式，已只保留一种主要运镜'));
    expect(result.warnings, contains('画面描述为空，建议补充主体动作与过渡'));
    expect(result.warnings, contains('参考素材超过推荐的 4–5 个，可能降低主体和风格稳定性'));
  });

  test('视频解析脚本会明确以视频1复刻动作、运镜和节奏', () {
    final result = service.generate(
      shot: _shot(now),
      assets: const [],
      globalStyle: '',
      constraints: '',
      videoReferenceInstruction: '参考视频1中的主体动作、镜头语言、节奏与视觉风格，按以下分镜复刻。',
    );

    expect(result.prompt, contains('参考视频1中的主体动作、镜头语言、节奏与视觉风格'));
    expect(result.prompt, contains('镜头1：'));
    expect(result.prompt, contains('全局风格：'));
    expect(result.prompt, contains('整体约束：'));
  });

  test('合成提示词会净化色彩列里的原帧服装和配饰颜色', () {
    final result = service.generate(
      shot: _shot(now).copyWith(colorPalette: '暖灰石墙为底，搭配深棕皮革、黑白条纹与米白长裤的暖中性色调'),
      assets: const [],
      globalStyle: '',
      constraints: '',
    );

    expect(result.prompt, contains('暖中性色调'));
    expect(result.prompt, isNot(contains('皮革')));
    expect(result.prompt, isNot(contains('条纹')));
    expect(result.prompt, isNot(contains('长裤')));
    expect(result.prompt, isNot(contains('石墙')));
  });

  test('镜头字段会剥离具体服装配饰和旧物件但保留动作与资产定义', () {
    final result = service.generate(
      shot: _shot(now).copyWith(
        content: '女模特穿白色阔腿裤和条纹衬衫，右手自然垂挂黑色皮质手提包，缓慢转向镜头',
        composition: '主体位于画面右侧，品牌字 YERAD 居中叠加',
        visualFocus: '黑色软质手提包和彩色条纹',
        sound: '黑色软质手提包产生轻微接触声',
      ),
      assets: [
        _asset(
          now,
          id: 'hero',
          type: ReplicateAssetType.character,
          name: '新模特',
          description: '短发、白衬衫、银色耳饰的女人',
          path: 'hero.png',
          number: 1,
        ),
        _asset(
          now,
          id: 'product',
          type: ReplicateAssetType.product,
          name: '新品背包',
          description: '纯黑通勤双肩包',
          path: 'bag.png',
          number: 2,
        ),
      ],
      globalStyle: '',
      constraints: '',
    );

    expect(result.prompt, contains('短发、白衬衫、银色耳饰的女人'));
    expect(result.prompt, contains('新品背包'));
    expect(result.prompt, contains('缓慢转向镜头'));
    expect(result.prompt, contains('右手自然垂挂'));
    expect(result.prompt, contains('轻微接触声'));
    expect(result.prompt, isNot(contains('白色阔腿裤')));
    expect(result.prompt, isNot(contains('条纹衬衫')));
    expect(result.prompt, isNot(contains('黑色皮质手提包')));
    expect(result.prompt, isNot(contains('黑色软质手提包')));
    expect(result.prompt, isNot(contains('彩色条纹')));
    expect(result.prompt, isNot(contains('YERAD')));
    expect(result.prompt, isNot(contains('品牌字')));
  });

  test('根据画面动作和相邻景别生成差异化动态运镜', () {
    final asset = _asset(
      now,
      id: 'product',
      type: ReplicateAssetType.product,
      name: '产品',
      description: '白色瓶身',
      path: 'product.png',
      number: 1,
    );
    final running = service.generate(
      shot: _shot(
        now,
      ).copyWith(content: '人物从街道左侧奔跑冲向门口', cameraMovement: '固定镜头'),
      assets: [asset],
      globalStyle: '',
      constraints: '',
    );
    final productDetail = service.generate(
      shot: _shot(now).copyWith(content: '人物拿起产品展示瓶身细节', cameraMovement: ''),
      assets: [asset],
      globalStyle: '',
      constraints: '',
    );
    final reveal = service.generate(
      shot: _shot(
        now,
      ).copyWith(content: '建筑与城市空间全貌逐渐展开', cameraMovement: '', shotSize: '全景'),
      assets: [asset],
      globalStyle: '',
      constraints: '',
    );

    expect(running.prompt, contains('平稳跟拍主体'));
    expect(productDetail.prompt, contains('缓慢推近主体'));
    expect(reveal.prompt, contains('缓慢拉远'));
    expect({running.prompt, productDetail.prompt, reveal.prompt}, hasLength(3));
  });
}

ScriptShot _shot(DateTime now) => ScriptShot(
  id: 'shot-1',
  scriptId: 'script-1',
  shotNumber: 1,
  durationSeconds: 3,
  framePath: 'frame.png',
  visual: '',
  content: '现代模特缓慢抬起右手拿起玻璃精华瓶，顺势转向镜头',
  shotSize: '近景',
  cameraMovement: '缓慢推镜、平稳横移',
  cameraNotes: '暖白主光从左前方进入，瓶身高光清晰',
  scene: '白色摄影棚桌面',
  productCode: 'A-01',
  productStyling: '白衬衫与银色饰品',
  dialogue: '现在就来试试',
  sound: '轻快音乐进入',
  prompt: '',
  status: ProcessingStatus.completed,
  updatedAt: now,
);

ReplicateAsset _asset(
  DateTime now, {
  required String id,
  required ReplicateAssetType type,
  required String name,
  required String description,
  required String path,
  required int number,
}) => ReplicateAsset(
  id: id,
  runId: 'run-1',
  type: type,
  name: name,
  description: description,
  path: path,
  referenceNumber: number,
  status: ProcessingStatus.completed,
  createdAt: now,
  updatedAt: now,
);
