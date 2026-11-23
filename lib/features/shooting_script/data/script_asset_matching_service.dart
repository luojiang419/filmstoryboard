import '../../settings/domain/app_settings.dart';
import '../../replicate/domain/replicate_models.dart';
import '../domain/shooting_asset_library_models.dart';
import '../domain/script_asset_slot_policy.dart';
import '../domain/shooting_script_models.dart';

class ScriptAssetMatchCandidate {
  const ScriptAssetMatchCandidate({
    required this.assetId,
    required this.confidence,
    required this.reason,
    this.preferredSortOrder,
  });

  final String assetId;
  final double confidence;
  final String reason;
  final int? preferredSortOrder;
}

class ScriptAssetMatchResult {
  const ScriptAssetMatchResult({
    required this.candidates,
    required this.usedModel,
  });

  final List<ScriptAssetMatchCandidate> candidates;
  final bool usedModel;
}

/// Matches controlled asset names in storyboard text without sending images or
/// text to a remote model. Duplicate names are deliberately left unbound.
class ScriptAssetMatchingService {
  const ScriptAssetMatchingService();

  Future<ScriptAssetMatchResult> match({
    required AppSettings settings,
    required ScriptShot shot,
    required List<ShootingAssetLibraryItem> assets,
  }) async {
    if (assets.isEmpty) {
      return const ScriptAssetMatchResult(candidates: [], usedModel: false);
    }
    return ScriptAssetMatchResult(
      candidates: _matchNames(shot, assets),
      usedModel: false,
    );
  }

  void cancel() {}

  void close() {}

  List<ScriptAssetMatchCandidate> _matchNames(
    ScriptShot shot,
    List<ShootingAssetLibraryItem> assets,
  ) {
    final contexts = [
      (
        label: '镜头文案',
        value:
            '${shot.visual} ${shot.content} ${shot.freeCreationDescription} '
            '${shot.prompt} ${shot.replicationInstructions}',
      ),
      (label: '场景字段', value: shot.scene),
      (label: '产品编码字段', value: shot.productCode),
      (label: '穿搭字段', value: shot.productStyling),
    ];
    final normalizedContexts = [
      for (final context in contexts)
        (label: context.label, value: _normalize(context.value)),
    ];
    final names = <String, List<_NameEntry>>{};
    for (final asset in assets) {
      if (const {
        ReplicateAssetType.video,
        ReplicateAssetType.audio,
      }.contains(asset.type)) {
        continue;
      }
      _addName(names, asset.name, asset, isAlias: false);
      for (final alias in asset.aliases) {
        _addName(names, alias, asset, isAlias: true);
      }
    }
    final candidates = <String, ScriptAssetMatchCandidate>{};
    for (final context in normalizedContexts) {
      final text = context.value;
      if (text.isEmpty) continue;
      for (final entry in names.entries) {
        if (!text.contains(entry.key) || entry.value.length != 1) continue;
        final match = entry.value.single;
        final candidate = ScriptAssetMatchCandidate(
          assetId: match.asset.id,
          confidence: match.isAlias ? 0.96 : 1.0,
          reason:
              '${match.isAlias ? '别名' : '标准名称'}“${match.value}”命中${context.label}',
          preferredSortOrder: _slotHintForAsset(match.asset)?.sortOrder,
        );
        final existing = candidates[candidate.assetId];
        if (existing == null || candidate.confidence > existing.confidence) {
          candidates[candidate.assetId] = candidate;
        }
      }
    }
    for (final candidate in _matchSlotNames(shot, assets)) {
      _keepStrongerCandidate(candidates, candidate);
    }
    for (final candidate in _matchDescriptions(normalizedContexts, assets)) {
      _keepStrongerCandidate(candidates, candidate);
    }
    for (final candidate in _matchWardrobeSlots(shot, assets)) {
      _keepStrongerCandidate(candidates, candidate);
    }
    final result = candidates.values.toList()
      ..sort((a, b) {
        final confidence = b.confidence.compareTo(a.confidence);
        if (confidence != 0) return confidence;
        final leftOrder = a.preferredSortOrder ?? 1 << 30;
        final rightOrder = b.preferredSortOrder ?? 1 << 30;
        final slot = leftOrder.compareTo(rightOrder);
        return slot != 0 ? slot : a.assetId.compareTo(b.assetId);
      });
    return result;
  }

  List<ScriptAssetMatchCandidate> _matchSlotNames(
    ScriptShot shot,
    List<ShootingAssetLibraryItem> assets,
  ) {
    final characterCount = ScriptAssetSlotPolicy.recognizedCharacterCount(
      shot: shot,
    );
    final result = <ScriptAssetMatchCandidate>[];
    for (final asset in assets) {
      if (_isUnsupported(asset)) continue;
      final hint = _slotHintForAsset(asset);
      if (hint == null || hint.kind == ScriptAssetPresetSlotKind.scene) {
        continue;
      }
      final index = hint.kind == ScriptAssetPresetSlotKind.character
          ? hint.characterIndex
          : hint.productIndex;
      if (index >= characterCount) continue;
      result.add(
        ScriptAssetMatchCandidate(
          assetId: asset.id,
          confidence: 0.94,
          reason:
              '资产名称“${asset.name.trim()}”命中${hint.label(characterCount: characterCount)}槽位',
          preferredSortOrder: hint.sortOrder,
        ),
      );
    }
    return result;
  }

  List<ScriptAssetMatchCandidate> _matchDescriptions(
    List<({String label, String value})> contexts,
    List<ShootingAssetLibraryItem> assets,
  ) {
    final matches = <_DescriptionCandidate>[];
    for (final asset in assets) {
      if (_isUnsupported(asset)) continue;
      _DescriptionMatch? best;
      for (final context in contexts) {
        if (context.value.isEmpty) continue;
        final current = _descriptionMatch(asset.description, context.value);
        if (current == null ||
            (best != null && current.confidence <= best.confidence)) {
          continue;
        }
        best = current.withContextLabel(context.label);
      }
      if (best == null) continue;
      matches.add(
        _DescriptionCandidate(
          asset: asset,
          match: best,
          slotHint: _slotHintForAsset(asset),
        ),
      );
    }

    final ambiguousKeys = <String, int>{};
    for (final candidate in matches) {
      if (candidate.slotHint != null) continue;
      final key = '${_assetKind(candidate.asset)}:${candidate.match.evidence}';
      ambiguousKeys[key] = (ambiguousKeys[key] ?? 0) + 1;
    }
    return [
      for (final candidate in matches)
        if (candidate.slotHint != null ||
            ambiguousKeys['${_assetKind(candidate.asset)}:${candidate.match.evidence}'] ==
                1)
          ScriptAssetMatchCandidate(
            assetId: candidate.asset.id,
            confidence: candidate.match.confidence,
            reason:
                '描述片段“${candidate.match.evidence}”模糊命中${candidate.match.contextLabel}',
            preferredSortOrder: candidate.slotHint?.sortOrder,
          ),
    ];
  }

  static _DescriptionMatch? _descriptionMatch(
    String description,
    String normalizedContext,
  ) {
    final segments = description
        .split(RegExp(r'[\s,，。；;、/|:：()（）\[\]【】]+'))
        .map(_semanticText)
        .where((value) => value.length >= 2)
        .toSet();
    _DescriptionMatch? best;
    for (final segment in segments) {
      if (_isGenericSemanticText(segment)) continue;
      if (normalizedContext.contains(segment)) {
        final confidence = segment.length >= 6
            ? 0.92
            : segment.length >= 4
            ? 0.88
            : segment.length == 3
            ? 0.84
            : 0.8;
        final current = _DescriptionMatch(
          confidence: confidence,
          evidence: segment,
        );
        if (best == null || current.confidence > best.confidence) {
          best = current;
        }
        continue;
      }
      final common = _longestCommonSubstring(segment, normalizedContext);
      if (common.length < 3 || _isGenericSemanticText(common)) continue;
      final confidence = 0.8 + (common.length.clamp(3, 7) - 2) * 0.02;
      final current = _DescriptionMatch(
        confidence: confidence,
        evidence: common,
      );
      if (best == null || current.confidence > best.confidence) {
        best = current;
      }
    }
    return best;
  }

  List<ScriptAssetMatchCandidate> _matchWardrobeSlots(
    ScriptShot shot,
    List<ShootingAssetLibraryItem> assets,
  ) {
    final styling = _normalize(shot.productStyling);
    if (styling.isEmpty) return const [];
    final result = <ScriptAssetMatchCandidate>[];
    for (final slot in _wardrobeSlots.entries) {
      if (!slot.value.any((term) => styling.contains(_normalize(term)))) {
        continue;
      }
      final matches = [
        for (final asset in assets)
          if (_isWardrobeAsset(asset) &&
              _assetMatchesWardrobeSlot(asset, slot.value))
            asset,
      ];
      if (matches.length != 1) continue;
      final asset = matches.single;
      result.add(
        ScriptAssetMatchCandidate(
          assetId: asset.id,
          confidence: 0.9,
          reason: '资产类别“${slot.key}”命中穿搭字段',
          preferredSortOrder: _slotHintForAsset(asset)?.sortOrder,
        ),
      );
    }
    return result;
  }

  static bool _isWardrobeAsset(ShootingAssetLibraryItem asset) =>
      switch (asset.type) {
        ReplicateAssetType.product ||
        ReplicateAssetType.prop ||
        ReplicateAssetType.reference ||
        ReplicateAssetType.other => true,
        _ => false,
      };

  static bool _isUnsupported(ShootingAssetLibraryItem asset) => const {
    ReplicateAssetType.video,
    ReplicateAssetType.audio,
  }.contains(asset.type);

  static String _assetKind(ShootingAssetLibraryItem asset) =>
      ScriptAssetSlotPolicy.effectiveTypeForSlotting(
        type: asset.type,
        name: asset.name,
        description: asset.description,
        aliases: asset.aliases,
      ).name;

  static ScriptAssetPresetSlot? _slotHintForAsset(
    ShootingAssetLibraryItem asset,
  ) {
    final identity = [asset.name, ...asset.aliases].join(' ');
    final character = RegExp(
      r'(?:模特|人物|角色|model|person|character)\s*([a-z]|[0-9]{1,2})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(identity);
    if (character != null) {
      final index = _slotIndex(character.group(1));
      if (index != null) return ScriptAssetPresetSlot.character(index);
    }
    final product = RegExp(
      r'(?:服装|衣服|穿搭|产品|商品|单品|clothing|outfit|product)\s*([a-z]|[0-9]{1,2})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(identity);
    if (product != null) {
      final index = _slotIndex(product.group(1));
      if (index != null) return ScriptAssetPresetSlot.product(index);
    }
    return null;
  }

  static int? _slotIndex(String? value) {
    if (value == null || value.isEmpty) return null;
    final numeric = int.tryParse(value);
    if (numeric != null) return numeric <= 0 ? null : numeric - 1;
    final code = value.toUpperCase().codeUnitAt(0);
    return code >= 65 && code <= 90 ? code - 65 : null;
  }

  static void _keepStrongerCandidate(
    Map<String, ScriptAssetMatchCandidate> candidates,
    ScriptAssetMatchCandidate candidate,
  ) {
    final existing = candidates[candidate.assetId];
    if (existing == null || candidate.confidence > existing.confidence) {
      candidates[candidate.assetId] = candidate;
    }
  }

  static String _semanticText(String value) {
    var result = _normalize(value);
    for (final noise in _descriptionNoiseTerms) {
      result = result.replaceAll(noise, '');
    }
    return result;
  }

  static bool _isGenericSemanticText(String value) =>
      value.length < 2 || _genericSemanticTexts.contains(value);

  static String _longestCommonSubstring(String left, String right) {
    if (left.isEmpty || right.isEmpty) return '';
    var bestLength = 0;
    var bestEnd = 0;
    var previous = List<int>.filled(right.length + 1, 0);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        if (left.codeUnitAt(leftIndex - 1) !=
            right.codeUnitAt(rightIndex - 1)) {
          continue;
        }
        current[rightIndex] = previous[rightIndex - 1] + 1;
        if (current[rightIndex] > bestLength) {
          bestLength = current[rightIndex];
          bestEnd = leftIndex;
        }
      }
      previous = current;
    }
    return left.substring(bestEnd - bestLength, bestEnd);
  }

  static bool _assetMatchesWardrobeSlot(
    ShootingAssetLibraryItem asset,
    List<String> slotTerms,
  ) {
    final values = [asset.name, ...asset.aliases].map(_normalize);
    final normalizedTerms = slotTerms.map(_normalize).toList(growable: false);
    return values.any(
      (value) => normalizedTerms.any(
        (term) => value == term || value.startsWith(term),
      ),
    );
  }

  void _addName(
    Map<String, List<_NameEntry>> names,
    String value,
    ShootingAssetLibraryItem asset, {
    required bool isAlias,
  }) {
    final normalized = _normalize(value);
    if (normalized.isEmpty) return;
    final entries = names.putIfAbsent(normalized, () => []);
    if (entries.any((entry) => entry.asset.id == asset.id)) return;
    entries.add(
      _NameEntry(asset: asset, value: value.trim(), isAlias: isAlias),
    );
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  static const _wardrobeSlots = <String, List<String>>{
    '上装': ['上装', '上衣', '外套', '衬衫', 'T恤', 't恤', '马甲'],
    '下装': ['下装', '裤', '裙'],
    '鞋子': ['鞋子', '鞋', '靴'],
    '配饰': ['配饰', '包', '帽', '眼镜', '首饰', '项链', '耳环', '腰带'],
  };

  static const _descriptionNoiseTerms = <String>[
    '参考图片',
    '参考图',
    '资产图片',
    '资产图',
    '图片',
    '照片',
    '综合参考',
  ];

  static const _genericSemanticTexts = <String>{
    '参考',
    '资产',
    '人物',
    '模特',
    '角色',
    '服装',
    '衣服',
    '产品',
    '商品',
    '单品',
    '场景',
    '环境',
    '全身',
    '正面',
    '背面',
  };
}

class _NameEntry {
  const _NameEntry({
    required this.asset,
    required this.value,
    required this.isAlias,
  });

  final ShootingAssetLibraryItem asset;
  final String value;
  final bool isAlias;
}

class _DescriptionCandidate {
  const _DescriptionCandidate({
    required this.asset,
    required this.match,
    required this.slotHint,
  });

  final ShootingAssetLibraryItem asset;
  final _DescriptionMatch match;
  final ScriptAssetPresetSlot? slotHint;
}

class _DescriptionMatch {
  const _DescriptionMatch({
    required this.confidence,
    required this.evidence,
    this.contextLabel = '',
  });

  final double confidence;
  final String evidence;
  final String contextLabel;

  _DescriptionMatch withContextLabel(String label) => _DescriptionMatch(
    confidence: confidence,
    evidence: evidence,
    contextLabel: label,
  );
}
