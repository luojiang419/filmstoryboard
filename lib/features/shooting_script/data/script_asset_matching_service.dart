import '../../settings/domain/app_settings.dart';
import '../../replicate/domain/replicate_models.dart';
import '../domain/shooting_asset_library_models.dart';
import '../domain/shooting_script_models.dart';

class ScriptAssetMatchCandidate {
  const ScriptAssetMatchCandidate({
    required this.assetId,
    required this.confidence,
    required this.reason,
  });

  final String assetId;
  final double confidence;
  final String reason;
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
      (label: '镜头文案', value: '${shot.visual} ${shot.content} ${shot.prompt}'),
      (label: '场景字段', value: shot.scene),
      (label: '产品字段', value: '${shot.productCode} ${shot.productStyling}'),
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
    for (final context in contexts) {
      final text = _normalize(context.value);
      if (text.isEmpty) continue;
      for (final entry in names.entries) {
        if (!text.contains(entry.key) || entry.value.length != 1) continue;
        final match = entry.value.single;
        final candidate = ScriptAssetMatchCandidate(
          assetId: match.asset.id,
          confidence: match.isAlias ? 0.96 : 1.0,
          reason:
              '${match.isAlias ? '别名' : '标准名称'}“${match.value}”命中${context.label}',
        );
        final existing = candidates[candidate.assetId];
        if (existing == null || candidate.confidence > existing.confidence) {
          candidates[candidate.assetId] = candidate;
        }
      }
    }
    final result = candidates.values.toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return result;
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
