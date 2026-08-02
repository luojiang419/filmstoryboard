import 'package:path/path.dart' as p;

import '../../settings/domain/app_settings.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../domain/replicate_models.dart';

class SeedancePromptResult {
  const SeedancePromptResult({
    required this.prompt,
    required this.assetIds,
    required this.warnings,
  });

  final String prompt;
  final List<String> assetIds;
  final List<String> warnings;
}

class SeedancePromptGenerationService {
  const SeedancePromptGenerationService();

  static const defaultGlobalStyle = AppSettings.defaultReplicateGlobalStyle;
  static const defaultConstraints = AppSettings.defaultReplicateConstraints;

  SeedancePromptResult generate({
    required ScriptShot shot,
    required List<ReplicateAsset> assets,
    required String globalStyle,
    required String constraints,
  }) {
    final readyAssets =
        assets.where((asset) => asset.path.trim().isNotEmpty).toList()
          ..sort((first, second) {
            final byKind = mediaKind(
              first,
            ).index.compareTo(mediaKind(second).index);
            return byKind != 0
                ? byKind
                : first.referenceNumber.compareTo(second.referenceNumber);
          });
    String clean(String value) {
      var result = value.trim();
      for (final asset in readyAssets) {
        result = result.replaceAll(asset.id, asset.name.trim());
      }
      return result.replaceAll(RegExp(r'\s+'), ' ');
    }

    final definitions = <String>[];
    for (final asset in readyAssets) {
      final reference = referenceLabel(asset);
      final name = clean(asset.name).isEmpty ? reference : clean(asset.name);
      final description = clean(asset.description);
      final feature = description.isEmpty ? name : description;
      definitions.add(switch (asset.type) {
        ReplicateAssetType.character =>
          '将$reference中的$feature定义为$name，后续始终使用$name指代该主体',
        ReplicateAssetType.product =>
          '将$reference中的$feature定义为产品$name，保持产品外观和结构一致',
        ReplicateAssetType.scene => '$reference作为$name的场景与空间关系参考',
        ReplicateAssetType.prop => '将$reference中的$feature定义为道具$name，保持其外观稳定',
        ReplicateAssetType.video => '参考$reference中的主要运镜、动作节奏和转场方式',
        ReplicateAssetType.audio => '参考$reference中的音色、音乐节奏和环境氛围',
        ReplicateAssetType.reference ||
        ReplicateAssetType.other => '参考$reference中的$feature',
      });
    }

    final movement = _singleCameraMovement(clean(shot.cameraMovement));
    final shotOpening = [
      clean(shot.shotSize),
      movement,
    ].where((value) => value.isNotEmpty).join('，');
    final body = <String>[
      if (shotOpening.isNotEmpty) shotOpening,
      clean(shot.content),
      if (clean(shot.scene).isNotEmpty) '场景位于${clean(shot.scene)}',
      clean(shot.cameraNotes),
      if (clean(shot.dialogue).isNotEmpty)
        '人物说道{${_stripBrackets(clean(shot.dialogue))}}',
      if (clean(shot.sound).isNotEmpty)
        '<${_stripBrackets(clean(shot.sound))}>',
    ].where((value) => value.isNotEmpty).toList();
    final style = clean(globalStyle).isEmpty
        ? defaultGlobalStyle
        : clean(globalStyle);
    final constraintText = clean(constraints).isEmpty
        ? defaultConstraints
        : clean(constraints);
    final sections = <String>[
      if (definitions.isNotEmpty) '主体与素材定义：${definitions.join('；')}。',
      '镜头${shot.shotNumber}：${body.join('；')}。',
      '全局风格：$style。',
      '整体约束：$constraintText。',
    ];
    final prompt = sections.join('\n\n');
    return SeedancePromptResult(
      prompt: prompt,
      assetIds: [for (final asset in readyAssets) asset.id],
      warnings: validate(prompt: prompt, shot: shot, assets: readyAssets),
    );
  }

  List<String> validate({
    required String prompt,
    required ScriptShot shot,
    required List<ReplicateAsset> assets,
  }) {
    final warnings = <String>[];
    if (!prompt.contains('镜头${shot.shotNumber}')) {
      warnings.add('缺少镜头时序标识');
    }
    if (shot.content.trim().isEmpty) {
      warnings.add('画面描述为空，建议补充主体动作与过渡');
    }
    if (_movementTerms(shot.cameraMovement).length > 1) {
      warnings.add('原始运镜包含多种方式，已只保留一种主要运镜');
    }
    if (assets.length > 5) {
      warnings.add('参考素材超过推荐的 4–5 个，可能降低主体和风格稳定性');
    }
    for (final asset in assets) {
      if (prompt.contains(asset.id)) {
        warnings.add('提示词包含内部素材 ID：${asset.name}');
      }
      if (!prompt.contains(referenceLabel(asset))) {
        warnings.add('素材 ${asset.name} 未使用稳定的模型引用编号');
      }
    }
    if (!prompt.contains('无字幕') && !prompt.contains('避免生成任何文字')) {
      warnings.add('缺少无字幕约束');
    }
    if (!prompt.contains('Logo') || !prompt.contains('水印')) {
      warnings.add('缺少 Logo 或水印约束');
    }
    return warnings;
  }

  static ReplicateMediaKind mediaKind(ReplicateAsset asset) {
    return switch (asset.type) {
      ReplicateAssetType.video => ReplicateMediaKind.video,
      ReplicateAssetType.audio => ReplicateMediaKind.audio,
      ReplicateAssetType.character ||
      ReplicateAssetType.product ||
      ReplicateAssetType.scene ||
      ReplicateAssetType.prop => ReplicateMediaKind.image,
      ReplicateAssetType.reference ||
      ReplicateAssetType.other => _mediaKindFromPath(asset.path),
    };
  }

  static String referenceLabel(ReplicateAsset asset) {
    final prefix = switch (mediaKind(asset)) {
      ReplicateMediaKind.image => '图片',
      ReplicateMediaKind.video => '视频',
      ReplicateMediaKind.audio => '音频',
    };
    return '$prefix${asset.referenceNumber}';
  }

  static ReplicateMediaKind _mediaKindFromPath(String path) {
    final extension = p.extension(path).toLowerCase();
    if (const {
      '.mp4',
      '.mov',
      '.mkv',
      '.avi',
      '.webm',
      '.m4v',
    }.contains(extension)) {
      return ReplicateMediaKind.video;
    }
    if (const {
      '.mp3',
      '.wav',
      '.m4a',
      '.aac',
      '.flac',
      '.ogg',
    }.contains(extension)) {
      return ReplicateMediaKind.audio;
    }
    return ReplicateMediaKind.image;
  }

  static String _stripBrackets(String value) =>
      value.replaceAll(RegExp(r'[{}<>【】]'), '').trim();

  static String _singleCameraMovement(String value) {
    if (value.isEmpty) {
      return '';
    }
    final firstSegment = value.split(RegExp(r'[，,、；;+/]')).first.trim();
    final terms = _movementTerms(firstSegment);
    if (terms.isEmpty || terms.length == 1) {
      return firstSegment;
    }
    return terms.first;
  }

  static List<String> _movementTerms(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    const patterns = <String, List<String>>{
      '固定镜头': ['固定', '静止'],
      '缓慢推镜': ['推镜', '推近', '推进'],
      '缓慢拉镜': ['拉镜', '拉远'],
      '平稳摇镜': ['摇镜', '摇摄'],
      '平稳横移': ['横移', '移镜'],
      '平稳跟拍': ['跟拍', '跟随'],
      '缓慢环绕': ['环绕'],
      '平稳升降': ['升镜', '降镜', '升降'],
      '航拍': ['航拍', '无人机', '俯冲'],
    };
    final result = <String>[];
    for (final entry in patterns.entries) {
      if (entry.value.any(normalized.contains)) {
        result.add(entry.key);
      }
    }
    return result;
  }
}

enum ReplicateMediaKind { image, video, audio }
