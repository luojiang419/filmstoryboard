import '../../shooting_script/domain/shooting_script_workflow_models.dart';
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

    final lines = <String>[
      '只输出一张完成的分镜图。画面目标：$normalizedInstruction',
      if (hasSceneReference)
        '复刻图片1的主体动作、人物与产品位置、景别、机位、构图和透视；不得继承图片1的场景、背景或环境光。'
      else
        '复刻图片1的动作、构图、机位和光影，并保持主体位置、景别、透视和光影方向。',
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
    final supplement = plan.normalizedSupplement.trim();
    if (supplement.isNotEmpty && supplement != normalizedInstruction) {
      lines.add('补充关系：$supplement');
    }
    lines.add(
      hasSceneReference
          ? '统一保持真实比例与透视、自然接触与穿戴、正确遮挡和清晰材质细节；环境光、色温、阴影与空间氛围以场景参考图为准，让人物和产品自然融入新背景。'
          : '统一保持真实比例与透视、自然接触与穿戴、正确遮挡、清晰材质细节，以及与图片1一致的光照方向和空间关系。',
    );
    return lines.join('\n');
  }

  String compile({
    required String instruction,
    required List<LightweightReplicationReference> references,
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
    return <String>[
      normalizedInstruction,
      if (clauses.isNotEmpty) '${clauses.join('，')}。',
      if (hasSceneReference) ...[
        '复刻图片1的主体动作、人物与产品位置、景别、机位、构图和透视；不得继承图片1的场景、背景或环境光。',
        ..._sceneReplacementLines(sceneImageNumbers),
        '环境光、色温和阴影以场景参考图为准，让人物与产品自然融入新背景。',
      ] else
        '复刻图片1的动作、构图、机位和光影，让所有参考元素自然处于同一画面。',
      '只输出一张完成的分镜图。',
    ].join('\n');
  }

  static String _referenceClause(LightweightReplicationReference reference) {
    final image = '图片${reference.imageNumber}';
    final name = reference.name.trim();
    final named = name.isEmpty ? image : '$image中的“$name”';
    final slot = reference.slotLabel.trim();
    return switch (reference.type) {
      ReplicateAssetType.character => '使用$named作为${slot.isEmpty ? '人物' : slot}',
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
      lines.add('模特$label以图片${models[index].imageNumber}为身份与外观参考。');
      if (index < plan.productGroups.length) {
        lines.add(
          '模特$label与产品${plan.productGroups[index].label}一一对应，产品不得跨模特互换、串用或混搭。',
        );
      }
    }
  }

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
