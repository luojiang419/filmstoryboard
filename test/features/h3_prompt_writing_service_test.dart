import 'package:filmstoryboard/features/replicate/data/h3_prompt_writing_service.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:filmstoryboard/features/storyboard/domain/cinematic_motion_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = H3PromptWritingService();

  test('Ref2VA 指令内置官方六段结构和稳定图片编号', () {
    final instruction = service.buildRewriteInstruction(
      draft: '镜头1：人物展示产品。',
      durationSeconds: 6,
      storyboardImageCount: 1,
      references: const [
        H3PromptReference(
          pictureNumber: 2,
          role: '产品外观',
          name: '新品背包',
          description: '哑光黑硬挺结构',
        ),
      ],
    );

    expect(instruction, contains('Ref2VA 全参考模式'));
    expect(instruction, contains('subject_definitions:'));
    expect(instruction, contains('retention_analysis:'));
    expect(instruction, contains('detailed_description:'));
    expect(instruction, contains('<Picture 1> 是复刻分镜图'));
    expect(instruction, contains('<Picture 2> 是产品外观参考'));
    expect(instruction, contains('所有描述性正文必须使用简体中文'));
    expect(instruction, contains('即梦 / Seedance 2.0 成熟导演语法作为基线'));
    expect(instruction, contains('一个物理镜头尽量只使用一种有动机的主运镜'));
    expect(instruction, contains('按真实时间速度播放'));
    expect(instruction, contains('禁止把视觉上的慢动作'));
    expect(instruction, contains('禁止时间拉伸'));
    expect(instruction, contains('未明确要求配乐时必须写 N/A'));
    expect(
      instruction,
      isNot(contains('Write all rewrite sections in English')),
    );
  });

  test('通用 H3 默认不注入风格约束以兼容现有调用', () {
    final instruction = service.buildRewriteInstruction(
      draft: '镜头1：人物展示产品。',
      durationSeconds: 6,
      storyboardImageCount: 1,
    );

    expect(instruction, isNot(contains('选定风格：')));
    expect(instruction, isNot(contains('风格化约束（')));
    expect(instruction, contains('空间层 + 时间层'));
  });

  test('慢动作只接受剧情描述中的明确正向授权', () {
    expect(
      CinematicMotionPolicy.hasExplicitSlowMotionIntent('人物落地时使用慢动作，突出冲击力'),
      isTrue,
    );
    expect(
      CinematicMotionPolicy.hasExplicitSlowMotionIntent('以120fps升格拍摄落水瞬间'),
      isTrue,
    );
    expect(
      CinematicMotionPolicy.hasExplicitSlowMotionIntent('不要慢动作，摄影机缓慢推近人物表情'),
      isFalse,
      reason: '慢速运镜不是慢动作授权，否定要求也不能被误判为授权',
    );
    expect(
      CinematicMotionPolicy.hasExplicitSlowMotionIntent('平稳跟随并在结尾缓停'),
      isFalse,
    );
  });

  test('未授权时 H3 指令禁止慢动作且结果校验会拦截', () {
    final instruction = service.buildRewriteInstruction(
      draft: '人物向前奔跑。',
      durationSeconds: 6,
      storyboardImageCount: 1,
    );
    expect(instruction, contains('播放速度规则（最高优先级）'));
    expect(instruction, contains('缓慢推近/平稳跟随/末段缓停'));
    expect(instruction, contains('不能覆盖本条'));

    const prompt = '''subject_definitions:
<Picture 1> 是人物动作参考。

summary:
[参考生成] 6秒视频，人物完成一次奔跑动作。

retention_analysis:
<Picture 1> ([Shot 1] 动作参考): fully_preserved - 保留人物与场景。

detailed_description:
[Shot 1] 人物以慢动作向前奔跑，摄影机同步跟随。

overall_soundscape:
脚步声与动作同步。

non_diegetic_music:
N/A''';
    expect(
      service.validationErrors(prompt),
      contains('用户未授权慢动作，最终提示词不得包含慢动作、慢放、升格或变速慢放'),
    );
    expect(service.validationErrors(prompt, allowSlowMotion: true), isEmpty);
  });

  test('8 个风格均将精炼约束注入视觉改写指令', () {
    for (final style in H3PromptStyle.values.skip(1)) {
      final instruction = service.buildRewriteInstruction(
        draft: '镜头1：人物展示产品。',
        durationSeconds: 6,
        storyboardImageCount: 1,
        style: style,
      );

      expect(instruction, contains('选定风格：${style.label}（${style.id}）'));
      expect(
        instruction,
        contains(style.visualPromptInstruction.trim()),
        reason: style.id,
      );
      expect(instruction, contains('不得改变官方字段顺序'), reason: style.id);
    }
  });

  test('清理思考标签和代码围栏后验证 Ref2VA 字段顺序', () {
    const raw = '''
<think>分析过程</think>
```text
subject_definitions:
<Picture 1> 是分镜、构图、场景、动作和光线的主要参考。

summary:
[参考生成] 一支展示产品外观与动作的短片。

retention_analysis:
<Picture 1> ([Shot 1] 分镜锚点): fully_preserved - 保留主体位置、构图、场景和光线方向。

detailed_description:
目标视频使用电影级商业广告质感和柔和侧光。
[Shot 1] 中景展示产品，摄影机以小幅度缓慢推近，产品结构与参考图保持一致。

overall_soundscape:
柔和的室内空间底噪持续存在，伴随轻微的材质摩擦声。

non_diegetic_music:
N/A
```
''';

    final normalized = service.normalize(raw);
    expect(normalized, startsWith('subject_definitions:'));
    expect(service.isValid(normalized), isTrue);
  });

  test('字段缺失或乱序时拒绝视觉模型结果', () {
    const invalid = '''
subject_definitions:
<Picture 1> is a reference.

detailed_description:
[Shot 1] A product appears.

summary:
[reference generation] Product video.
''';

    expect(service.isValid(invalid), isFalse);
  });

  test('字段结构正确但正文为英文时拒绝并触发中文回退', () {
    const english = '''
subject_definitions:
<Picture 1> is the storyboard reference.

summary:
[reference generation] A short product video.

retention_analysis:
<Picture 1>: fully_preserved - composition is retained.

detailed_description:
[Shot 1] A product appears in a medium shot while the camera pushes in slowly.

overall_soundscape:
Soft room tone and subtle fabric movement.

non_diegetic_music:
N/A
''';

    expect(service.isValid(english), isFalse);
  });

  test('自由创作校验附件编号与 summary 中的唯一 AI 时长', () {
    const prompt = '''subject_definitions:
<Picture 1> 是起始分镜图，用于定义人物位置和构图。
<Picture 2> 是结束分镜图，用于定义产品特写。

summary:
[参考生成] 7秒视频，完成从人物动作到产品特写的连续展示。

retention_analysis:
<Picture 1> ([Shot 1] 起始构图): fully_preserved - 保留人物位置和室内光线。
<Picture 2> ([Shot 1] 结束构图): fully_preserved - 保留产品外形和材质。

detailed_description:
[参考生成] 画面采用清晰克制的商业影像质感。
[Shot 1] 人物从 <Picture 1> 中的位置平稳拿起产品，摄影机缓慢推近，最后以 <Picture 2> 定义的材质和构图完成特写。

overall_soundscape:
安静的室内底噪持续存在，保留手部与产品接触的自然摩擦声。

non_diegetic_music:
N/A''';

    expect(
      service.validationErrors(
        prompt,
        referenceImageCount: 2,
        requireAiDuration: true,
      ),
      isEmpty,
    );
    expect(service.extractDurationSeconds(prompt), 7);
  });

  test('自由创作拒绝重复时长、超范围时长和错误附件编号', () {
    const invalid = '''subject_definitions:
<Picture 1> 是起始分镜图。
<Picture 3> 是不存在的附件。

summary:
[参考生成] 16秒视频，生成连续的产品展示。

retention_analysis:
<Picture 1> ([Shot 1] 构图): fully_preserved - 保留主体和光线。

detailed_description:
[参考生成] 画面保持清晰稳定的商业影像风格。
[Shot 1] 人物用自然速度拿起产品，摄影机缓慢推近，整个动作持续 16秒视频。

overall_soundscape:
安静的室内底噪和产品接触声与动作同步。

non_diegetic_music:
N/A''';

    final errors = service.validationErrors(
      invalid,
      referenceImageCount: 2,
      requireAiDuration: true,
    );
    expect(errors, contains('全文必须且只能出现一个“X秒视频”'));
    expect(errors, contains('缺少附件引用 <Picture 2>'));
    expect(errors.any((error) => error.contains('Picture 编号')), isTrue);
    expect(service.extractDurationSeconds(invalid), isNull);
  });

  test('方案 A 只有明确切镜文字才允许多镜头', () {
    expect(
      H3PromptWritingService.shouldUseSingleContinuousShot(
        description: '同一段攀爬动作从全景连续推进到近景，镜头始终跟随人物。',
        storyboardImageCount: 3,
      ),
      isTrue,
      reason: '单纯景别变化和连续推进不能被解释为切镜',
    );
    expect(
      H3PromptWritingService.shouldUseSingleContinuousShot(
        description: '第一个镜头低角度跟随攀爬，随后硬切到第二个镜头的脚部近景。',
        storyboardImageCount: 3,
      ),
      isFalse,
    );
    expect(
      H3PromptWritingService.hasExplicitMultiShotIntent(
        '人物继续攀爬，[Shot 2] 切至顶部俯拍。',
      ),
      isTrue,
    );
    expect(
      H3PromptWritingService.hasExplicitMultiShotIntent(
        '不要切镜，不得出现第二个镜头，保持一镜到底。',
      ),
      isFalse,
    );
    expect(
      H3PromptWritingService.hasExplicitMultiShotIntent('镜头 3 的当前剧情描述'),
      isFalse,
      reason: '拍摄脚本条目编号不是多镜头创作指令',
    );
  });

  test('单连续镜头指令把多图定义为阶段帧并拒绝 Shot 2', () {
    final instruction = service.buildRewriteInstruction(
      draft: '人物在三张连续画面中完成攀爬动作。',
      durationSeconds: 10,
      storyboardImageCount: 3,
      singleContinuousShot: true,
    );

    expect(instruction, contains('当前目标镜头结构：单一连续镜头（最高优先级）'));
    expect(instruction, contains('同一物理镜头按时间顺序抽取的动作阶段帧'));
    expect(instruction, contains('禁止把 Picture N 映射成 Shot N'));
    expect(instruction, contains('必须且只能出现一次 [Shot 1]'));
    expect(instruction, contains('不是新镜头首帧'));
    expect(
      service.validationErrors(
        '不合格的输出',
        referenceImageCount: 3,
        requireAiDuration: true,
        singleContinuousShot: true,
      ),
      isNotEmpty,
      reason: '缺失字段的首轮输出应返回校验错误并进入修复请求，不能抛出 RangeError',
    );

    const splitPrompt = '''subject_definitions:
<Picture 1> 是攀爬动作的开始阶段。
<Picture 2> 是攀爬动作的中间阶段。
<Picture 3> 是攀爬动作的结束阶段。

summary:
[参考生成] 10秒视频，人物连续向上攀爬。

retention_analysis:
<Picture 1> ([Shot 1] 动作参考): fully_preserved - 保留开始姿态。
<Picture 2> ([Shot 2] 动作参考): fully_preserved - 保留中间姿态。
<Picture 3> ([Shot 2] 动作参考): fully_preserved - 保留结束姿态。

detailed_description:
[Shot 1] 人物从第一张图片的姿态开始向上攀爬。
[Shot 2] 在 00:05.000，镜头切换到第二张图片的构图，人物继续攀爬。

overall_soundscape:
自然风声与鞋底摩擦岩石的声音保持同步。

non_diegetic_music:
N/A''';

    expect(
      service.validationErrors(
        splitPrompt,
        referenceImageCount: 3,
        requireAiDuration: true,
        singleContinuousShot: true,
      ),
      contains('单一连续镜头模式只允许 [Shot 1]，不得出现 [Shot 2] 或更高编号'),
    );
    expect(
      service.validationErrors(
        splitPrompt,
        referenceImageCount: 3,
        requireAiDuration: true,
      ),
      isEmpty,
      reason: '明确多镜头模式仍允许合法的 Shot 2',
    );
  });
}
