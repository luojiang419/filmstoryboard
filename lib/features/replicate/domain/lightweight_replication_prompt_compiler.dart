import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import 'line_art_color_style_prompt_compiler.dart';
import 'replicate_models.dart';
import 'quick_replication_reference.dart';

class LightweightReplicationReference {
  const LightweightReplicationReference({
    required this.imageNumber,
    required this.type,
    required this.name,
    this.slotLabel = '',
  });

  final int imageNumber;
  final ReplicateAssetType type;
  final String name;
  final String slotLabel;
}

class LightweightReplicationPromptCompiler {
  const LightweightReplicationPromptCompiler();

  String compilePlan({
    required String instruction,
    required QuickReplicationPlan plan,
    ReplicateSourceFrameMode sourceFrameMode =
        ReplicateSourceFrameMode.colorReference,
    LineArtColorStyleSelectionSnapshot? colorStyleSnapshot,
  }) {
    final normalizedInstruction = instruction.trim();
    if (normalizedInstruction.isEmpty) {
      throw ArgumentError.value(instruction, 'instruction', '快速复刻说明不能为空');
    }
    _validatePlanOrder(plan);

    final sceneImageNumbers = [
      for (final reference in plan.references)
        if (reference.role == QuickReferenceRole.scene) reference.imageNumber,
    ];
    final hasSceneReference = sceneImageNumbers.isNotEmpty;
    final hasModelReference = plan.references.any(
      (reference) => reference.role == QuickReferenceRole.model,
    );
    final hasProductReference = plan.references.any(
      (reference) => const {
        QuickReferenceRole.product,
        QuickReferenceRole.clothing,
        QuickReferenceRole.shoes,
        QuickReferenceRole.accessory,
        QuickReferenceRole.prop,
      }.contains(reference.role),
    );
    final route = _combinationRoute(
      hasModel: hasModelReference,
      hasProduct: hasProductReference,
      hasScene: hasSceneReference,
    );

    final lines = <String>[
      '只输出一张完成的分镜图。画面目标：$normalizedInstruction',
      '【组合路由】${route.$1}：${route.$2}',
      if (sourceFrameMode == ReplicateSourceFrameMode.lineArt)
        LineArtColorStylePromptCompiler.lineArtSourceFrameAuthority,
      if (hasSceneReference)
        '复刻图片1的主体动作、人物与产品位置、景别、机位、构图和透视；不得继承图片1的场景、背景或环境光。'
      else
        sourceFrameMode == ReplicateSourceFrameMode.lineArt
            ? '复刻图片1的动作、构图、机位、主体位置、景别和透视；图片1不提供颜色、材质、环境外观或环境光色。'
            : '复刻图片1的动作、构图、机位和光影，并保持主体位置、景别、透视和光影方向。',
    ];
    _addSceneReplacementLines(lines, sceneImageNumbers);
    _addModelLines(lines, plan);
    for (final group in plan.productGroups) {
      lines.add(_productGroupClause(group, plan));
    }
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.clothing,
      '作为服装参考，并自然穿着在对应人物身上',
    );
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.shoes,
      '作为鞋子参考，并保持与脚部姿态和地面接触自然',
    );
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.accessory,
      '作为配饰参考，并保持穿戴位置、尺度和遮挡自然',
    );
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.prop,
      '作为道具参考，并保持持握、摆放和接触关系自然',
    );
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.styleReference,
      '只提供整体视觉风格、质感和色调参考',
    );
    _addRoleLines(
      lines,
      plan,
      QuickReferenceRole.otherReference,
      '按该图说明提供对应视觉参考',
    );

    final described = <String>[];
    for (final assignment in plan.assignments) {
      final description = assignment.normalizedDescription.trim();
      if (description.isEmpty) continue;
      described.add('图片${assignment.imageNumber}说明：$description');
    }
    if (described.isNotEmpty) lines.add('${described.join('；')}。');
    _addColorStyleBlock(
      lines,
      sourceFrameMode: sourceFrameMode,
      snapshot: colorStyleSnapshot,
    );
    final supplement = plan.normalizedSupplement.trim();
    if (supplement.isNotEmpty && supplement != normalizedInstruction) {
      lines.add('补充关系：$supplement');
    }
    lines.add(
      hasSceneReference
          ? '统一保持真实比例与透视、自然接触与穿戴、正确遮挡和清晰材质细节；环境光、色温、阴影与空间氛围以场景参考图为准，让人物和产品自然融入新背景。'
          : sourceFrameMode == ReplicateSourceFrameMode.lineArt
          ? '统一保持真实比例与透视、自然接触与穿戴、正确遮挡和清晰材质细节；环境外观与环境光色由主体/场景资产和全片色彩圣经决定。'
          : '统一保持真实比例与透视、自然接触与穿戴、正确遮挡、清晰材质细节，以及与图片1一致的光照方向和空间关系。',
    );
    return lines.join('\n');
  }

  String compile({
    required String instruction,
    required List<LightweightReplicationReference> references,
    ReplicateSourceFrameMode sourceFrameMode =
        ReplicateSourceFrameMode.colorReference,
    LineArtColorStyleSelectionSnapshot? colorStyleSnapshot,
  }) {
    final normalizedInstruction = instruction.trim();
    if (normalizedInstruction.isEmpty) {
      throw ArgumentError.value(instruction, 'instruction', '快速复刻说明不能为空');
    }

    final clauses = <String>[
      for (final reference in references) _referenceClause(reference),
    ];
    final sceneImageNumbers = [
      for (final reference in references)
        if (reference.type == ReplicateAssetType.scene) reference.imageNumber,
    ];
    final hasSceneReference = sceneImageNumbers.isNotEmpty;
    final hasModelReference = references.any(
      (reference) => reference.type == ReplicateAssetType.character,
    );
    final hasProductReference = references.any(
      (reference) =>
          reference.type == ReplicateAssetType.product ||
          reference.type == ReplicateAssetType.prop,
    );
    final route = _combinationRoute(
      hasModel: hasModelReference,
      hasProduct: hasProductReference,
      hasScene: hasSceneReference,
    );
    final lines = <String>[
      normalizedInstruction,
      '【组合路由】${route.$1}：${route.$2}',
      if (sourceFrameMode == ReplicateSourceFrameMode.lineArt)
        LineArtColorStylePromptCompiler.lineArtSourceFrameAuthority,
      if (clauses.isNotEmpty) '${clauses.join('，')}。',
      if (hasSceneReference) ...[
        '复刻图片1的主体动作、人物与产品位置、景别、机位、构图和透视；不得继承图片1的场景、背景或环境光。',
        ..._sceneReplacementLines(sceneImageNumbers),
        '环境光、色温和阴影以场景参考图为准，让人物与产品自然融入新背景。',
      ] else
        sourceFrameMode == ReplicateSourceFrameMode.lineArt
            ? '复刻图片1的动作、构图、机位和主体位置，让所有参考元素自然处于同一画面；图片1不提供颜色、材质、环境外观或环境光色。'
            : '复刻图片1的动作、构图、机位和光影，让所有参考元素自然处于同一画面。',
    ];
    _addColorStyleBlock(
      lines,
      sourceFrameMode: sourceFrameMode,
      snapshot: colorStyleSnapshot,
    );
    lines.add('只输出一张完成的分镜图。');
    return lines.join('\n');
  }

  static void _addColorStyleBlock(
    List<String> lines, {
    required ReplicateSourceFrameMode sourceFrameMode,
    required LineArtColorStyleSelectionSnapshot? snapshot,
  }) {
    if (sourceFrameMode != ReplicateSourceFrameMode.lineArt) return;
    lines.add(
      const LineArtColorStylePromptCompiler().compileBlock(
        sourceFrameMode: ReplicateSourceFrameMode.lineArt,
        snapshot: snapshot,
      ),
    );
  }

  static String _referenceClause(LightweightReplicationReference reference) {
    final image = '图片${reference.imageNumber}';
    final name = reference.name.trim();
    final named = name.isEmpty ? image : '$image中的“$name”';
    final slot = reference.slotLabel.trim();
    return switch (reference.type) {
      ReplicateAssetType.character =>
        '只使用$named的身份、脸部、发型、肤色和体型替换${slot.isEmpty ? '对应人物' : slot}；不使用该图的服装、姿势和背景',
      ReplicateAssetType.product =>
        '让对应人物穿着或使用$named${slot.isEmpty ? '' : '（$slot）'}',
      ReplicateAssetType.scene => '使用$named作为背景环境',
      ReplicateAssetType.prop => '使用$named作为道具',
      ReplicateAssetType.reference ||
      ReplicateAssetType.other => '参考$named${slot.isEmpty ? '' : '（$slot）'}',
      ReplicateAssetType.video ||
      ReplicateAssetType.audio => throw ArgumentError('快速图片复刻不支持视频或音频参考'),
    };
  }

  static void _validatePlanOrder(QuickReplicationPlan plan) {
    for (var index = 0; index < plan.references.length; index++) {
      final expectedImageNumber = index + 2;
      if (plan.references[index].imageNumber != expectedImageNumber) {
        throw ArgumentError(
          '快速引用顺序不连续：第${index + 1}项应为图片$expectedImageNumber，'
          '实际为图片${plan.references[index].imageNumber}',
        );
      }
    }
  }

  static void _addRoleLines(
    List<String> lines,
    QuickReplicationPlan plan,
    QuickReferenceRole role,
    String purpose,
  ) {
    final images = [
      for (final reference in plan.references)
        if (reference.role == role) '图片${reference.imageNumber}',
    ];
    if (images.isNotEmpty) lines.add('${images.join('、')}$purpose。');
  }

  static void _addModelLines(List<String> lines, QuickReplicationPlan plan) {
    final models = [
      for (final reference in plan.references)
        if (reference.role == QuickReferenceRole.model) reference,
    ];
    for (var index = 0; index < models.length; index++) {
      final label = QuickReplicationLocalPlanner.productLabelForIndex(index);
      lines.add(
        '模特$label只以图片${models[index].imageNumber}为身份、脸部、发型、肤色和体型参考；不继承该图的服装、姿势和背景。',
      );
      if (index < plan.productGroups.length) {
        lines.add(
          '模特$label与产品${plan.productGroups[index].label}一一对应，产品不得跨模特互换、串用或混搭。',
        );
      }
    }
    if (models.isNotEmpty && plan.productGroups.isEmpty) {
      lines.add('没有绑定产品的模特槽位继续穿着图片1中的原服装、鞋帽和配饰。');
    }
  }

  static (String, String) _combinationRoute({
    required bool hasModel,
    required bool hasProduct,
    required bool hasScene,
  }) => switch ((hasModel, hasProduct, hasScene)) {
    (false, false, false) => ('M0-P0-S0 · 全部保留', '空资产格沿用图片1，只执行明确指定的局部调整。'),
    (true, false, false) => ('M1-P0-S0 · 仅替换模特', '只替换人物身份，原服装、产品与场景保持图片1不变。'),
    (false, true, false) => (
      'M0-P1-S0 · 仅替换产品',
      '保留原人物身份与场景，按原穿着、持拿或摆放关系替换产品。',
    ),
    (false, false, true) => ('M0-P0-S1 · 仅替换场景', '保留原人物与产品，只重建环境外观和环境光。'),
    (true, true, false) => ('M1-P1-S0 · 模特与产品', '同槽位模特穿着或使用对应产品，保持原动作与场景。'),
    (true, false, true) => ('M1-P0-S1 · 模特与场景', '替换人物身份并进入新场景，原服装与产品保持不变。'),
    (false, true, true) => ('M0-P1-S1 · 产品与场景', '原人物穿着或使用对应产品并进入新场景。'),
    (true, true, true) => (
      'M1-P1-S1 · 模特、产品与场景',
      '同槽位模特穿着或使用对应产品，保持原动作并进入新场景。',
    ),
  };

  static void _addSceneReplacementLines(
    List<String> lines,
    List<int> imageNumbers,
  ) => lines.addAll(_sceneReplacementLines(imageNumbers));

  static List<String> _sceneReplacementLines(List<int> imageNumbers) {
    if (imageNumbers.isEmpty) return const [];
    final images = imageNumbers.map((number) => '图片$number').join('、');
    final authority = imageNumbers.length == 1
        ? '$images是新场景与背景的唯一权威来源'
        : '$images共同定义新场景与背景，且优先级高于图片1环境';
    return [
      '$authority，必须完整替换图片1的原背景。',
      '禁止继承图片1中的建筑、家具、道路、地面、植物、天空及其他环境元素；按图片1的机位、构图和透视自然重构场景参考图。',
    ];
  }

  static String _productGroupClause(
    QuickProductGroup group,
    QuickReplicationPlan plan,
  ) {
    final master = '图片${group.masterImageNumber}';
    if (group.detailImageNumbers.isEmpty) {
      return '产品${group.label}以$master为主图，保持完整轮廓、版型、比例、颜色、材质和整体结构。';
    }
    final details = group.detailImageNumbers
        .map((imageNumber) => '图片$imageNumber')
        .join('、');
    final detailClauses = <String>[];
    for (final imageNumber in group.detailImageNumbers) {
      final assignment = plan.assignments.firstWhere(
        (item) => item.imageNumber == imageNumber,
      );
      if (assignment.normalizedDescription.trim().isEmpty) {
        detailClauses.add(
          '图片$imageNumber补充产品${group.label}可见的局部结构、材质、接缝、表面处理和工艺细节',
        );
      }
    }
    final clauses = [
      '产品${group.label}以$master为主图，保持完整轮廓、版型、比例、颜色、材质和整体结构；$details只补充产品${group.label}的局部结构与工艺证据，整体形态以$master为准',
      ...detailClauses,
    ];
    return '${clauses.join('；')}。';
  }
}
