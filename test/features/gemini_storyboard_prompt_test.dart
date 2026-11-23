import 'package:filmstoryboard/features/story_design/domain/gemini_storyboard_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('Gemini 3 与 Nano Banana Pro 家族启用官方分镜提示词规则', () {
    expect(usesGemini3ImagePrompting('gemini-3-pro-image'), isTrue);
    expect(usesGemini3ImagePrompting('gemini-3-pro-image-preview'), isTrue);
    expect(
      usesGemini3ImagePrompting('apimart:gemini-3-pro-image-preview'),
      isTrue,
    );
    expect(usesGemini3ImagePrompting('nano-banana-pro'), isTrue);
    expect(usesGemini3ImagePrompting('nano-banana-pro-vip'), isTrue);
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

    expect(prompt, contains('【Gemini 3 精确多图复刻执行协议】'));
    expect(prompt, contains('不是自由创作、拼贴、风格迁移或相似画面重做'));
    expect(prompt, contains('严格按上文“图片1、图片2……”的编号和角色定义读取输入'));
    expect(prompt, contains('图片1提供空间与摄影约束'));
    expect(prompt, contains('明确标记保留的主体'));
    expect(prompt, contains('严格执行上文“原帧主体处理计划”'));
    expect(prompt, contains('保留项完整沿用图片1中的对应主体'));
    expect(prompt, contains('不得把未标记保留的原人物或原产品外观带入成图'));
    expect(prompt, contains('移除项必须消失并自然补全背景'));
    expect(prompt, contains('不得把多张参考图的身份、脸部、服装、产品结构、材质或颜色平均融合'));
    expect(prompt, contains('主视图定义完整身份或产品整体'));
    expect(prompt, contains('局部细节裁切只补充局部证据'));
    expect(prompt, contains('图片1左右方向未镜像'));
    expect(prompt, isNot(contains('不要机械拼贴或照抄参考图版式')));
    expect(prompt, isNot(contains('补全合理的前景、中景、背景')));
    expect(prompt, isNot(contains('让景别、机位或动作自然推进')));
  });
}
