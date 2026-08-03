import 'package:filmstoryboard/features/story_design/domain/gemini_storyboard_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('仅 Gemini 3 图像模型启用官方分镜提示词规则', () {
    expect(usesGemini3ImagePrompting('gemini-3-pro-image'), isTrue);
    expect(
      usesGemini3ImagePrompting('apimart:gemini-3-pro-image-preview'),
      isTrue,
    );
    expect(usesGemini3ImagePrompting('nano-banana-fast'), isFalse);
    expect(usesGemini3ImagePrompting('apimart:gpt-image-2'), isFalse);
  });

  test('参考图场景会加入身份与美术连续性约束', () {
    final prompt = buildGeminiStoryboardPrompt(
      '角色在清晨抵达海边',
      hasReferenceImages: true,
    );

    expect(prompt, startsWith('角色在清晨抵达海边'));
    expect(prompt, contains('所附参考图只用于锁定人物身份'));
    expect(prompt, contains('不要机械拼贴或照抄参考图版式'));
    expect(prompt, contains('不要添加标题、镜号、字幕'));
  });

  test('复刻场景将原帧构图作为硬约束，素材图仅用于替换实体', () {
    final prompt = buildGeminiStoryboardPrompt(
      '图片1是原视频帧，图片2是新模特',
      hasReferenceImages: true,
      preserveReferenceComposition: true,
    );

    expect(prompt, contains('图片1是本镜头唯一的构图母版'));
    expect(prompt, contains('图片1的色彩风格、色温、明暗关系、光影层次和景深也是硬约束'));
    expect(prompt, contains('以查看图片1时的画面左/右为唯一坐标系'));
    expect(prompt, contains('严禁水平镜像、左右颠倒、反向朝向或交换左右侧构图'));
    expect(prompt, contains('其余参考图只用于替换人物、产品、场景和道具'));
    expect(prompt, isNot(contains('不要机械拼贴或照抄参考图版式')));
  });
}
