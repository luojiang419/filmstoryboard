import '../../replicate/domain/replicate_models.dart';
import 'shooting_script_models.dart';
import 'shooting_script_workflow_models.dart';

enum ScriptAssetPresetSlotKind { character, product, productDetail, scene }

class ScriptAssetPresetSlot {
  const ScriptAssetPresetSlot._({
    required this.kind,
    this.characterIndex = 0,
    this.productIndex = 0,
  });

  const ScriptAssetPresetSlot.character(int index)
    : this._(kind: ScriptAssetPresetSlotKind.character, characterIndex: index);

  const ScriptAssetPresetSlot.product([int index = 0])
    : this._(kind: ScriptAssetPresetSlotKind.product, productIndex: index);

  const ScriptAssetPresetSlot.productDetail([int index = 0])
    : this._(
        kind: ScriptAssetPresetSlotKind.productDetail,
        productIndex: index,
      );

  const ScriptAssetPresetSlot.scene()
    : this._(kind: ScriptAssetPresetSlotKind.scene);

  final ScriptAssetPresetSlotKind kind;
  final int characterIndex;
  final int productIndex;

  String get key => switch (kind) {
    ScriptAssetPresetSlotKind.character => 'character-$characterIndex',
    ScriptAssetPresetSlotKind.product =>
      productIndex == 0 ? 'product' : 'product-$productIndex',
    ScriptAssetPresetSlotKind.productDetail =>
      productIndex == 0 ? 'product-detail' : 'product-detail-$productIndex',
    ScriptAssetPresetSlotKind.scene => 'scene',
  };

  int get sortOrder => switch (kind) {
    ScriptAssetPresetSlotKind.character =>
      ScriptAssetSlotPolicy.characterSortOrderBase + characterIndex,
    ScriptAssetPresetSlotKind.product =>
      ScriptAssetSlotPolicy.productSortOrderForIndex(productIndex),
    ScriptAssetPresetSlotKind.productDetail =>
      ScriptAssetSlotPolicy.productDetailSortOrderForIndex(productIndex),
    ScriptAssetPresetSlotKind.scene => ScriptAssetSlotPolicy.sceneSortOrder,
  };

  ReplicateAssetType get preferredAssetType => switch (kind) {
    ScriptAssetPresetSlotKind.character => ReplicateAssetType.character,
    ScriptAssetPresetSlotKind.product ||
    ScriptAssetPresetSlotKind.productDetail => ReplicateAssetType.product,
    ScriptAssetPresetSlotKind.scene => ReplicateAssetType.scene,
  };

  String label({required int characterCount}) => switch (kind) {
    ScriptAssetPresetSlotKind.character =>
      characterCount > 1
          ? '模特${ScriptAssetSlotPolicy.characterSuffix(characterIndex)}'
          : '模特',
    ScriptAssetPresetSlotKind.product =>
      characterCount > 1
          ? '产品${ScriptAssetSlotPolicy.characterSuffix(productIndex)}'
          : '产品',
    ScriptAssetPresetSlotKind.productDetail =>
      characterCount > 1
          ? '产品细节${ScriptAssetSlotPolicy.characterSuffix(productIndex)}'
          : '产品细节',
    ScriptAssetPresetSlotKind.scene => '场景（可选）',
  };

  bool accepts(ReplicateAssetType type) => switch (kind) {
    ScriptAssetPresetSlotKind.character => type == ReplicateAssetType.character,
    ScriptAssetPresetSlotKind.product ||
    ScriptAssetPresetSlotKind.productDetail => const {
      ReplicateAssetType.product,
      ReplicateAssetType.reference,
      ReplicateAssetType.other,
    }.contains(type),
    ScriptAssetPresetSlotKind.scene => const {
      ReplicateAssetType.scene,
      ReplicateAssetType.reference,
      ReplicateAssetType.other,
    }.contains(type),
  };

  bool acceptsAsset({
    required ReplicateAssetType type,
    required String name,
    String description = '',
    Iterable<String> aliases = const [],
  }) {
    if (type != ReplicateAssetType.reference &&
        type != ReplicateAssetType.other) {
      return accepts(type);
    }
    final preferredKind = ScriptAssetSlotPolicy.preferredSlotKindForAsset(
      type: type,
      name: name,
      description: description,
      aliases: aliases,
    );
    if (preferredKind == null) return true;
    return switch (preferredKind) {
      ScriptAssetPresetSlotKind.character =>
        kind == ScriptAssetPresetSlotKind.character,
      ScriptAssetPresetSlotKind.product =>
        kind == ScriptAssetPresetSlotKind.product ||
            kind == ScriptAssetPresetSlotKind.productDetail,
      ScriptAssetPresetSlotKind.productDetail =>
        kind == ScriptAssetPresetSlotKind.productDetail,
      ScriptAssetPresetSlotKind.scene =>
        kind == ScriptAssetPresetSlotKind.scene,
    };
  }
}

class ScriptAssetSlotPolicy {
  const ScriptAssetSlotPolicy._();

  static const int characterSortOrderBase = 1000;
  static const int productSortOrder = 2000;
  static const int productDetailSortOrder = 2001;
  static const int additionalProductSortOrderBase = 2100;
  static const int additionalProductDetailSortOrderBase = 2200;
  static const int sceneSortOrder = 3000;
  static const int _maximumRecognizedCharacters = 20;

  static List<ScriptAssetPresetSlot> presetSlotsFor({
    required ScriptShot shot,
    ScriptShotAnalysisRecord? analysis,
    int minimumCharacterCount = 1,
  }) {
    final characterCount = recognizedCharacterCount(
      shot: shot,
      analysis: analysis,
    ).clamp(minimumCharacterCount, _maximumRecognizedCharacters);
    return [
      for (var index = 0; index < characterCount; index++)
        ScriptAssetPresetSlot.character(index),
      for (var index = 0; index < characterCount; index++) ...[
        ScriptAssetPresetSlot.product(index),
        ScriptAssetPresetSlot.productDetail(index),
      ],
      const ScriptAssetPresetSlot.scene(),
    ];
  }

  static int recognizedCharacterCount({
    required ScriptShot shot,
    ScriptShotAnalysisRecord? analysis,
  }) {
    var result = 0;
    final people = analysis?.promptContext.subject['people']?.trim() ?? '';
    if (people.isNotEmpty) {
      result = _countCharacters(people, peopleContext: true);
    }
    for (final text in [
      shot.content,
      shot.visual,
      shot.freeCreationDescription,
      shot.replicationInstructions,
    ]) {
      final count = _countCharacters(text, peopleContext: false);
      if (count > result) result = count;
    }
    return result.clamp(1, _maximumRecognizedCharacters);
  }

  static ScriptAssetPresetSlot? presetSlotForSortOrder(int sortOrder) {
    final characterIndex = sortOrder - characterSortOrderBase;
    if (characterIndex >= 0 && characterIndex < _maximumRecognizedCharacters) {
      return ScriptAssetPresetSlot.character(characterIndex);
    }
    final productDetailIndex = productDetailIndexForSortOrder(sortOrder);
    if (productDetailIndex != null) {
      return ScriptAssetPresetSlot.productDetail(productDetailIndex);
    }
    final productIndex = productIndexForSortOrder(sortOrder);
    if (productIndex != null) {
      return ScriptAssetPresetSlot.product(productIndex);
    }
    if (sortOrder == sceneSortOrder) {
      return const ScriptAssetPresetSlot.scene();
    }
    return null;
  }

  static int productSortOrderForIndex(int index) {
    if (index <= 0) return productSortOrder;
    return additionalProductSortOrderBase + index - 1;
  }

  static int? productIndexForSortOrder(int sortOrder) {
    if (sortOrder == productSortOrder) return 0;
    final index = sortOrder - additionalProductSortOrderBase + 1;
    if (index > 0 && index < _maximumRecognizedCharacters) return index;
    return null;
  }

  static int productDetailSortOrderForIndex(int index) {
    if (index <= 0) return productDetailSortOrder;
    return additionalProductDetailSortOrderBase + index - 1;
  }

  static int? productDetailIndexForSortOrder(int sortOrder) {
    if (sortOrder == productDetailSortOrder) return 0;
    final index = sortOrder - additionalProductDetailSortOrderBase + 1;
    if (index > 0 && index < _maximumRecognizedCharacters) return index;
    return null;
  }

  static ScriptAssetPresetSlotKind? preferredSlotKindForAsset({
    required ReplicateAssetType type,
    required String name,
    String description = '',
    Iterable<String> aliases = const [],
  }) {
    if (type == ReplicateAssetType.character) {
      return ScriptAssetPresetSlotKind.character;
    }
    if (type == ReplicateAssetType.scene) {
      return ScriptAssetPresetSlotKind.scene;
    }
    if (type == ReplicateAssetType.product) {
      return _containsProductDetail('$name ${aliases.join(' ')} $description')
          ? ScriptAssetPresetSlotKind.productDetail
          : ScriptAssetPresetSlotKind.product;
    }
    if (type != ReplicateAssetType.reference &&
        type != ReplicateAssetType.other) {
      return null;
    }

    final identity = '$name ${aliases.join(' ')}';
    final identityScene = _containsScene(identity);
    final identityCharacter = _containsCharacter(identity);
    final identityProduct = _containsProduct(identity);
    if (identityScene && !identityCharacter && !identityProduct) {
      return ScriptAssetPresetSlotKind.scene;
    }
    if (identityCharacter != identityProduct && !identityScene) {
      return identityCharacter
          ? ScriptAssetPresetSlotKind.character
          : _containsProductDetail(identity)
          ? ScriptAssetPresetSlotKind.productDetail
          : ScriptAssetPresetSlotKind.product;
    }
    if (_containsProductDetail(identity)) {
      return ScriptAssetPresetSlotKind.productDetail;
    }

    final descriptionCharacter = _containsCharacter(description);
    final descriptionProduct = _containsProduct(description);
    final descriptionScene = _containsScene(description);
    if (descriptionScene && !descriptionCharacter && !descriptionProduct) {
      return ScriptAssetPresetSlotKind.scene;
    }
    if (descriptionCharacter == descriptionProduct || descriptionScene) {
      return null;
    }
    return descriptionCharacter
        ? ScriptAssetPresetSlotKind.character
        : _containsProductDetail(description)
        ? ScriptAssetPresetSlotKind.productDetail
        : ScriptAssetPresetSlotKind.product;
  }

  static ReplicateAssetType effectiveTypeForSlotting({
    required ReplicateAssetType type,
    required String name,
    String description = '',
    Iterable<String> aliases = const [],
  }) {
    if (type != ReplicateAssetType.reference &&
        type != ReplicateAssetType.other) {
      return type;
    }
    return switch (preferredSlotKindForAsset(
      type: type,
      name: name,
      description: description,
      aliases: aliases,
    )) {
      ScriptAssetPresetSlotKind.character => ReplicateAssetType.character,
      ScriptAssetPresetSlotKind.product ||
      ScriptAssetPresetSlotKind.productDetail => ReplicateAssetType.product,
      ScriptAssetPresetSlotKind.scene => ReplicateAssetType.scene,
      null => type,
    };
  }

  static int? preferredSortOrderForAsset({
    required ReplicateAssetType type,
    required String name,
    String description = '',
    Iterable<String> aliases = const [],
    required Set<int> occupiedSortOrders,
    int maximumProductCount = 1,
  }) {
    final kind = preferredSlotKindForAsset(
      type: type,
      name: name,
      description: description,
      aliases: aliases,
    );
    if (kind == ScriptAssetPresetSlotKind.character) {
      for (var index = 0; index < _maximumRecognizedCharacters; index++) {
        final sortOrder = characterSortOrderBase + index;
        if (!occupiedSortOrders.contains(sortOrder)) return sortOrder;
      }
      return null;
    }
    if (kind == ScriptAssetPresetSlotKind.productDetail) {
      for (var index = 0; index < maximumProductCount; index++) {
        final sortOrder = productDetailSortOrderForIndex(index);
        if (!occupiedSortOrders.contains(sortOrder)) return sortOrder;
      }
      return null;
    }
    if (kind == ScriptAssetPresetSlotKind.product) {
      for (var index = 0; index < maximumProductCount; index++) {
        final sortOrder = productSortOrderForIndex(index);
        if (!occupiedSortOrders.contains(sortOrder)) return sortOrder;
      }
    }
    if (kind == ScriptAssetPresetSlotKind.scene &&
        !occupiedSortOrders.contains(sceneSortOrder)) {
      return sceneSortOrder;
    }
    return null;
  }

  static String characterSuffix(int index) {
    var value = index + 1;
    final result = StringBuffer();
    while (value > 0) {
      value--;
      result.writeCharCode(65 + (value % 26));
      value ~/= 26;
    }
    return result.toString().split('').reversed.join();
  }

  static int _countCharacters(String source, {required bool peopleContext}) {
    final text = source.trim();
    if (text.isEmpty) return 0;
    var result = 0;

    void keep(int? value) {
      if (value != null && value > result) result = value;
    }

    final countBeforeRole = RegExp(
      r'([0-9]{1,2}|[一二两三四五六七八九十]{1,3})\s*(?:位|名|个)?\s*(?:男模特|女模特|男模|女模|模特|人物|角色|男人|女人|男性|女性|男生|女生|男孩|女孩|儿童|孩子|人)(?![一-鿿])?',
      caseSensitive: false,
    );
    for (final match in countBeforeRole.allMatches(text)) {
      keep(_parseCount(match.group(1)));
    }

    final countAfterRole = RegExp(
      r'(?:人物|角色|模特|人数|人物数量|模特数量)\s*(?:共|有|数量|为|是|[:：])?\s*([0-9]{1,2}|[一二两三四五六七八九十]{1,3})',
      caseSensitive: false,
    );
    for (final match in countAfterRole.allMatches(text)) {
      keep(_parseCount(match.group(1)));
    }

    final labeledCharacters = <String>{};
    for (final match in RegExp(
      r'(?:模特|人物|角色)\s*([A-Z]|[0-9]{1,2})(?![A-Za-z0-9])',
      caseSensitive: false,
    ).allMatches(text)) {
      final label = match.group(1)!.toUpperCase();
      labeledCharacters.add(label);
      keep(int.tryParse(label) ?? (label.codeUnitAt(0) - 64));
    }
    if (labeledCharacters.length > 1) keep(labeledCharacters.length);

    if (RegExp(r'双人|两人|二人|双模特').hasMatch(text)) {
      keep(2);
    }
    if (RegExp(r'多人|多名模特|多个人物').hasMatch(text)) {
      keep(2);
    }

    if (peopleContext) {
      final roleMentions = RegExp(
        r'模特|人物|角色',
        caseSensitive: false,
      ).allMatches(text).length;
      if (roleMentions > 1) keep(roleMentions);
      if (RegExp(r'另一位|另外一位|另一名|另外一名').hasMatch(text)) {
        keep(2);
      }
    }
    return result;
  }

  static int? _parseCount(String? source) {
    if (source == null || source.isEmpty) return null;
    final numeric = int.tryParse(source);
    if (numeric != null) return numeric;
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (source == '十') return 10;
    final parts = source.split('十');
    if (parts.length == 2) {
      final tens = parts.first.isEmpty ? 1 : digits[parts.first];
      final units = parts.last.isEmpty ? 0 : digits[parts.last];
      if (tens != null && units != null) return tens * 10 + units;
    }
    return digits[source];
  }

  static bool _containsCharacter(String source) => RegExp(
    r'模特|人物|角色|主角|男模|女模|男性|女性|男人|女人|男孩|女孩|儿童|孩子|演员|model|person|character|actor|actress',
    caseSensitive: false,
  ).hasMatch(source);

  static bool _containsProduct(String source) => RegExp(
    r'产品|商品|单品|服装|上衣|外套|衬衫|T恤|裤|裙|鞋|靴|包|帽|眼镜|首饰|项链|耳环|腰带|手表|瓶|包装|product|item',
    caseSensitive: false,
  ).hasMatch(source);

  static bool _containsProductDetail(String source) => RegExp(
    r'产品细节|细节图|细节|特写|局部|材质|纹理|瓶口|接口|接缝|detail|close.?up|texture',
    caseSensitive: false,
  ).hasMatch(source);

  static bool _containsScene(String source) => RegExp(
    r'场景|环境|空间|室内|室外|棚拍|影棚|客厅|卧室|办公室|街道|建筑|背景|scene|environment|location|interior|exterior|background',
    caseSensitive: false,
  ).hasMatch(source);
}
