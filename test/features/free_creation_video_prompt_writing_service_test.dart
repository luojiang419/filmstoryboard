import 'package:filmstoryboard/features/replicate/data/free_creation_video_prompt_writing_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = FreeCreationVideoPromptWritingService();

  test('可灵指令只描述动作运镜并明确拒绝 H3 字段和静态属性猜测', () {
    final instruction = service.buildRewriteInstruction(
      format: ShotPromptFormat.kling,
      userDescription: '女性徒步者持续向上攀登，低角度跟随。',
      referenceRoles: const ['第一个动作阶段帧', '第二个动作阶段帧'],
      singleContinuousShot: true,
      explicitMultiShotIntent: false,
      allowSlowMotion: false,
      backendSkillContext: '可灵独立规则',
    );

    expect(instruction, contains('可灵图生视频'));
    expect(instruction, contains('不得重新猜测或枚举'));
    expect(instruction, contains('不得套用 MiniMax H3'));
    expect(instruction, contains('最终正文不得超过 500 个字符'));
  });

  test('可灵和即梦校验拒绝 H3 泄漏及超长文本', () {
    expect(
      service.validationErrors(
        '8秒视频。[参考生成] <Subject 1> 在画面中移动。',
        ShotPromptFormat.kling,
      ),
      contains('混入了 H3 字段或引用语法'),
    );
    expect(
      service.validationErrors(
        '8秒视频。${List.filled(400, '动作继续。').join()}',
        ShotPromptFormat.sd2,
      ),
      contains('超过 1800 个字符'),
    );
  });

  test('模型原生简洁提示词通过校验并提取时长', () {
    const prompt =
        '8秒视频。图片1至图片3作为同一连续镜头的顺序动作参考。保持图片中的主体和场景一致，女性徒步者持续向上攀登，低角度镜头平稳跟随，无切镜。';

    expect(service.validationErrors(prompt, ShotPromptFormat.kling), isEmpty);
    expect(service.extractDurationSeconds(prompt), 8);
  });
}
