import 'line_art_color_style_preset.dart';

/// 线稿模式的唯一色彩圣经编译器。
///
/// 快速复刻和精准复刻都必须调用这里生成完全相同的文本块；该类不依赖
/// Flutter、数据库或控制器，便于在生成前、重试和恢复链路中复用并单测。
class LineArtColorStylePromptCompiler {
  const LineArtColorStylePromptCompiler();

  /// 返回应插入提示词的冻结色彩块。彩色原帧模式返回空字符串。
  String compileBlock({
    required ReplicateSourceFrameMode sourceFrameMode,
    required LineArtColorStyleSelectionSnapshot? snapshot,
  }) {
    if (sourceFrameMode != ReplicateSourceFrameMode.lineArt) return '';
    final frozen = snapshot;
    if (frozen == null || !frozen.hasValidFingerprint) {
      throw StateError('线稿模式缺少有效的冻结色彩快照');
    }
    final swatches = frozen.swatches.join('、');
    return <String>[
      '【全片统一色彩圣经｜冻结指纹 ${frozen.fingerprint}】',
      '本批次所有镜头必须严格共用同一套全局色彩分级规则；不得按单镜头改变色温、对比度、饱和度、阴影、高光或颗粒。',
      '色彩预设“${frozen.presetName}”（v${frozen.presetVersion}）：${frozen.prompt}',
      if (swatches.isNotEmpty) '参考色板（仅作全局分级方向，不是主体换色指令）：$swatches。',
      '该色彩圣经只控制全局色彩关系、对比、阴影、高光、滚降与颗粒；不得重定义人物身份、肤色、服装/产品本色、Logo、文字、构图、动作、姿态、位置、接触或遮挡。人物、产品、服装和场景资产的局部本色与材质证据优先于全局分级。',
      lineArtOutputStyleAuthority,
    ].join('\n');
  }

  /// 把冻结色彩块追加到已有提示词，供快速链路及非 Nano 精确链路使用。
  String append({
    required String prompt,
    required ReplicateSourceFrameMode sourceFrameMode,
    required LineArtColorStyleSelectionSnapshot? snapshot,
  }) {
    final base = prompt.trim();
    final block = compileBlock(
      sourceFrameMode: sourceFrameMode,
      snapshot: snapshot,
    );
    if (block.isEmpty) return base;
    if (base.isEmpty) return block;
    return '$base\n$block';
  }

  /// 线稿模式下图片1的结构权威声明。颜色、材质和环境外观必须显式剥离。
  static const lineArtSourceFrameAuthority =
      '【线稿原帧权威边界】线稿模式下，图片1只提供画幅、机位、景别、透视、构图、人物/产品姿态、位置、尺度、接触和遮挡关系；图片1不提供颜色、材质、环境外观、环境光色、色温、阴影、反射或颗粒权威。上述被剥离的视觉属性必须来自对应人物/产品/场景资产与冻结的全片色彩圣经。';

  /// 线稿只负责结构参考，最终交付仍必须是可用于影视沟通的真实摄影质感。
  ///
  /// 该约束放在统一编译器中，确保快速复刻、精准复刻和 Nano Banana Pro
  /// 不会因为只修改了图片 1 的来源权限，就把输出媒介误生成成线稿。
  static const lineArtOutputStyleAuthority =
      '【线稿模式最终成图风格硬约束】线稿仅作为结构参考，最终必须输出电影级真实摄影质感的分镜静帧（photorealistic live-action cinematic storyboard still），具有极致清晰的皮肤、面部、手指、织物、皮革、金属、玻璃、木材和环境纹理细节，真实光照、材质反射、景深、空气透视与自然细颗粒；色彩按冻结的全片色彩圣经执行（允许其定义的电影级黑白调色）。严禁输出黑白线稿、铅笔稿、墨线、边缘描线、漫画、插画、卡通、扁平色块、草图、姿态人偶、分镜板框线或任何绘画滤镜。';
}
