import 'package:filmstoryboard/features/replicate/data/h3_prompt_writing_service.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
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
}
