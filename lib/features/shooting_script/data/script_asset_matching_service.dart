import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
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

/// Matches a script shot with reusable assets. A small deterministic shortlist
/// keeps the multimodal request bounded; the model then sees the shot image,
/// candidate asset images, names and descriptions together.
class ScriptAssetMatchingService {
  ScriptAssetMatchingService({VisionStoryboardService? visionService})
    : _visionService = visionService ?? VisionStoryboardService(),
      _ownsVisionService = visionService == null;

  final VisionStoryboardService _visionService;
  final bool _ownsVisionService;

  Future<ScriptAssetMatchResult> match({
    required AppSettings settings,
    required ScriptShot shot,
    required List<ShootingAssetLibraryItem> assets,
  }) async {
    if (assets.isEmpty) {
      return const ScriptAssetMatchResult(candidates: [], usedModel: false);
    }
    final ranked = _rankLocally(shot, assets);
    final shortlist = ranked.isNotEmpty
        ? ranked.take(6).toList()
        : [
            for (final asset in assets.take(6))
              _RankedAsset(
                asset: asset,
                score: 0,
                reason: '名称和描述无明显重合，交由画面匹配确认',
              ),
          ];
    try {
      final prompt = _matchingPrompt(shot, shortlist);
      final imageFiles = <File>[
        if (File(shot.framePath).existsSync()) File(shot.framePath),
        for (final asset in shortlist)
          if (File(asset.asset.path).existsSync()) File(asset.asset.path),
      ];
      final raw = await _visionService.complete(
        settings: settings,
        prompt: prompt,
        imageFiles: imageFiles,
        maxTokens: 900,
      );
      final parsed = _parseCandidates(raw, shortlist);
      if (parsed.isNotEmpty) {
        return ScriptAssetMatchResult(candidates: parsed, usedModel: true);
      }
    } catch (_) {
      // A model outage should not prevent deterministic matching from being
      // useful. The controller exposes the source as rule-based in this case.
    }
    return ScriptAssetMatchResult(
      candidates: [
        for (final item in ranked)
          ScriptAssetMatchCandidate(
            assetId: item.asset.id,
            confidence: item.score,
            reason: item.reason,
          ),
      ],
      usedModel: false,
    );
  }

  void cancel() => _visionService.cancelActiveRequests();

  void close() {
    if (_ownsVisionService) _visionService.close();
  }

  List<_RankedAsset> _rankLocally(
    ScriptShot shot,
    List<ShootingAssetLibraryItem> assets,
  ) {
    final shotText = [
      shot.visual,
      shot.content,
      shot.scene,
      shot.productCode,
      shot.productStyling,
    ].join(' ');
    final shotTokens = _tokens(shotText).toSet();
    final ranked = <_RankedAsset>[];
    for (final asset in assets) {
      final assetText = '${asset.name} ${asset.description}';
      final tokens = _tokens(assetText).toSet();
      final overlap = shotTokens.intersection(tokens).length;
      final denominator = shotTokens.union(tokens).length;
      var score = denominator == 0 ? 0.0 : overlap / denominator;
      if (shotText.contains(asset.name.trim()) &&
          asset.name.trim().isNotEmpty) {
        score += 0.55;
      }
      if (shot.scene.trim().isNotEmpty &&
          asset.type.name == 'scene' &&
          (asset.name.contains(shot.scene) ||
              asset.description.contains(shot.scene))) {
        score += 0.25;
      }
      if (score >= 0.08) {
        ranked.add(
          _RankedAsset(
            asset: asset,
            score: score.clamp(0.0, 1.0),
            reason: overlap == 0
                ? '资产类型和镜头上下文候选'
                : '名称/描述与镜头字段存在 $overlap 个语义词重合',
          ),
        );
      }
    }
    ranked.sort((first, second) => second.score.compareTo(first.score));
    return ranked;
  }

  String _matchingPrompt(ScriptShot shot, List<_RankedAsset> shortlist) {
    final buffer = StringBuffer()
      ..writeln('你是拍摄脚本资产匹配器。第一张图片是当前镜头，后续图片按列表顺序对应资产。')
      ..writeln('只能从候选资产 ID 中选择，不得生成新 ID。')
      ..writeln('根据镜头画面、镜头文字、资产名称和资产描述判断哪些资产实际适用于该镜头。')
      ..writeln(
        '镜头：${shot.visual}；${shot.content}；场景：${shot.scene}；景别：${shot.shotSize}',
      )
      ..writeln('候选资产：');
    for (final item in shortlist) {
      buffer.writeln(
        '${item.asset.id} | 类型=${item.asset.type.name} | 名称=${item.asset.name} | 描述=${item.asset.description}',
      );
    }
    buffer
      ..writeln(
        '只返回 JSON：{"matches":[{"asset_id":"候选ID","confidence":0.0,"reason":"一句话理由"}]}',
      )
      ..writeln('不适用的资产不要返回；confidence 必须在 0 到 1 之间。');
    return buffer.toString();
  }

  List<ScriptAssetMatchCandidate> _parseCandidates(
    String raw,
    List<_RankedAsset> shortlist,
  ) {
    final validIds = {for (final item in shortlist) item.asset.id};
    try {
      final object = _extractJson(raw);
      final matches = object['matches'];
      if (matches is! List) return const [];
      final result = <ScriptAssetMatchCandidate>[];
      for (final item in matches) {
        if (item is! Map) continue;
        final id = item['asset_id']?.toString() ?? '';
        if (!validIds.contains(id)) continue;
        final confidence = item['confidence'] is num
            ? (item['confidence'] as num).toDouble()
            : double.tryParse('${item['confidence']}') ?? 0;
        result.add(
          ScriptAssetMatchCandidate(
            assetId: id,
            confidence: confidence.clamp(0.0, 1.0),
            reason: item['reason']?.toString() ?? '模型匹配',
          ),
        );
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _extractJson(String raw) {
    final trimmed = raw.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('资产匹配模型未返回 JSON');
    }
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('资产匹配 JSON 结构异常');
    }
    return decoded;
  }

  static Iterable<String> _tokens(String value) sync* {
    for (final match in RegExp(
      r'[A-Za-z0-9_]+|[\u4e00-\u9fff]',
    ).allMatches(value)) {
      yield match.group(0)!.toLowerCase();
    }
  }
}

class _RankedAsset {
  const _RankedAsset({
    required this.asset,
    required this.score,
    required this.reason,
  });

  final ShootingAssetLibraryItem asset;
  final double score;
  final String reason;
}
