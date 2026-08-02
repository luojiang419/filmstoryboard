import 'package:filmstoryboard/features/replicate/data/seedance_prompt_generation_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  const service = SeedancePromptGenerationService();
  final now = DateTime.utc(2026, 8, 2);

  test('按 SD2 顺序生成主体、镜头、风格和约束且不暴露 Asset ID', () {
    final shot = _shot(now).copyWith(cameraMovement: '缓慢推镜');
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
