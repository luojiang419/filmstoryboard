import '../../storyboard/domain/image_generation_model_catalog.dart';

bool usesGemini3ImagePrompting(String model) {
  final descriptor = ImageGenerationCatalog.descriptorFor(model);
  final apiModel = descriptor?.apiModel.toLowerCase() ?? '';
  return apiModel.startsWith('gemini-3') && apiModel.contains('image');
}

String buildGeminiStoryboardPrompt(
  String prompt, {
  required bool hasReferenceImages,
  bool preserveReferenceComposition = false,
}) {
  final normalizedPrompt = prompt.trim();
  if (normalizedPrompt.isEmpty) {
    return normalizedPrompt;
  }
  final referenceInstruction = !hasReferenceImages
      ? ''
      : preserveReferenceComposition
      ? '图片1是本镜头唯一的构图母版，必须严格保持其画幅、景别、机位、透视、主体位置、姿态、视线、遮挡、光线方向与叙事时刻；'
            '图片1的色彩风格、色温、明暗关系、光影层次和景深也是硬约束；'
            '必须以查看图片1时的画面左/右为唯一坐标系，保持主体左右位置、朝向、视线、身体倾斜、肢体和道具方向；严禁水平镜像、左右颠倒、反向朝向或交换左右侧构图；'
            '其余参考图只用于替换人物、产品、场景和道具的视觉实体，绝不改变图片1的画面布局或调色。'
      : '所附参考图只用于锁定人物身份、服装/产品关键特征、场景材质与整体美术连续性；'
            '不要机械拼贴或照抄参考图版式，应让它们自然服务于本次镜头叙事。';
  return '$normalizedPrompt\n\n'
      '【Gemini 3 分镜图像指令】将上述创意理解为一段完整、连贯的视觉叙事，生成一张可直接用于影视前期沟通的高质量分镜图。'
      '优先清楚呈现主体是谁、正在做什么、身处什么环境，以及画面的叙事重点；在不违背用户指定美术风格的前提下，补全合理的前景、中景、背景、道具、材质与空间关系。'
      '为每个镜头明确匹配景别、机位、焦段感、主体位置、视线/动作方向和景深；光线必须有可辨识的方向、色温与情绪，并让阴影、反射和环境氛围保持物理与视觉一致。'
      '画面应有电影级构图、清晰的视觉焦点和可读的动作瞬间，人物、服装、场景、色彩脚本与道具在连续镜头中保持稳定，同时让景别、机位或动作自然推进。'
      '$referenceInstruction'
      '输出仅包含完成的分镜画面；不要添加标题、镜号、字幕、对话气泡、Logo、水印、界面元素或无关文字。';
}
