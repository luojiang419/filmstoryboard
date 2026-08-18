import '../../storyboard/domain/image_generation_model_catalog.dart';

bool usesGemini3ImagePrompting(String model) {
  final descriptor = ImageGenerationCatalog.descriptorFor(model);
  final apiModel = descriptor?.apiModel.toLowerCase() ?? '';
  return ImageGenerationCatalog.isNanoBananaProModel(model) ||
      (apiModel.startsWith('gemini-3') && apiModel.contains('image'));
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
  if (preserveReferenceComposition && hasReferenceImages) {
    return '$normalizedPrompt\n\n'
        '【Gemini 3 精确多图复刻执行协议】这是受控的多参考图编辑任务，不是自由创作、拼贴、风格迁移或相似画面重做。'
        '严格按上文“图片1、图片2……”的编号和角色定义读取输入，不得调换图片编号，也不得把多张参考图的身份、脸部、服装、产品结构、材质或颜色平均融合。'
        '图片1提供空间与摄影约束：画幅、景别、机位、透视、槽位位置、姿态、视线、动作、接触、遮挡、光线方向、色温、明暗和景深；只有“原帧主体处理计划”明确标记保留的主体，才允许继续使用图片1中的对应外观。'
        '严格执行上文“原帧主体处理计划”：保留项完整沿用图片1中的对应主体，替换项只从指定资产取得外观，移除项必须消失并自然补全背景；不得把未标记保留的原人物或原产品外观带入成图。'
        '图片2及后续素材图只提供各自被指定的目标特征；主视图定义完整身份或产品整体，局部细节裁切只补充局部证据；忽略素材图自身的背景、版式、机位、姿势、光照和调色。'
        '若同一人物或产品有多张参考图，只把它们视为同一目标的互补证据，不得生成混合身份、混合穿搭、混合包装或额外副本。'
        '执行前在内部逐项核对：主体处理计划已逐项完成、图片编号与资产角色对应正确、人物与产品一一绑定、图片1左右方向未镜像、原帧调色未漂移、未出现未指定文字或标识；不要输出核对过程。'
        '最终只输出一张完成的复刻分镜画面，不要输出解释、标题、镜号、字幕、对话气泡、Logo、水印、界面元素或无关文字。';
  }
  final referenceInstruction = !hasReferenceImages
      ? ''
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
