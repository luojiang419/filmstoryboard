import 'package:path/path.dart' as p;

import '../../settings/domain/app_settings.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
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
    ScriptShot? previousShot,
    ScriptShot? nextShot,
    String? videoReferenceInstruction,
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

    final movement = _cameraMovementForShot(
      shot,
      previousShot: previousShot,
      nextShot: nextShot,
    );
    final shotOpening = [
      clean(shot.shotSize),
      movement,
    ].where((value) => value.isNotEmpty).join('，');
    final visualAnalysis = <String>[
      if (clean(shot.composition).isNotEmpty) '构图：${clean(shot.composition)}',
      if (clean(shot.cameraAngle).isNotEmpty) '机位：${clean(shot.cameraAngle)}',
      if (clean(shot.lightingMood).isNotEmpty)
        '光影/氛围：${clean(shot.lightingMood)}',
      if (clean(shot.colorPalette).isNotEmpty) '色彩：${clean(shot.colorPalette)}',
      if (clean(shot.visualFocus).isNotEmpty) '视觉焦点：${clean(shot.visualFocus)}',
      if (clean(shot.transitionHint).isNotEmpty)
        '剪辑衔接：${clean(shot.transitionHint)}',
      if (clean(shot.cameraNotes).isNotEmpty) '摄影备注：${clean(shot.cameraNotes)}',
    ].join('；');
    final body = <String>[
      if (shotOpening.isNotEmpty) shotOpening,
      if (shot.durationSeconds > 0) '时长：${_durationText(shot.durationSeconds)}',
      clean(shot.content),
      if (clean(shot.scene).isNotEmpty) '场景位于${clean(shot.scene)}',
      if (visualAnalysis.isNotEmpty) '综合视觉分析：$visualAnalysis',
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
      if (clean(videoReferenceInstruction ?? '').isNotEmpty)
        clean(videoReferenceInstruction ?? ''),
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

  SeedancePromptResult generateFromScriptAssets({
    required ScriptShot shot,
    required List<ScriptAsset> assets,
    required String globalStyle,
    required String constraints,
    ScriptShot? previousShot,
    ScriptShot? nextShot,
    String? videoReferenceInstruction,
  }) {
    final promptAssets = [
      for (final asset in assets)
        ReplicateAsset(
          id: asset.id,
          runId: asset.scriptId,
          type: asset.type,
          name: asset.name,
          description: asset.description,
          path: asset.path,
          referenceNumber: asset.referenceNumber,
          status: asset.status,
          createdAt: asset.createdAt,
          updatedAt: asset.updatedAt,
        ),
    ];
    return generate(
      shot: shot,
      assets: promptAssets,
      globalStyle: globalStyle,
      constraints: constraints,
      previousShot: previousShot,
      nextShot: nextShot,
      videoReferenceInstruction: videoReferenceInstruction,
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

  static String _durationText(double seconds) {
    if (seconds == seconds.roundToDouble()) {
      return '${seconds.toInt()}秒';
    }
    return '${seconds.toStringAsFixed(1)}秒';
  }

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

  static String _cameraMovementForShot(
    ScriptShot shot, {
    ScriptShot? previousShot,
    ScriptShot? nextShot,
  }) {
    final explicit = _singleCameraMovement(shot.cameraMovement.trim());
    final explicitIsFixed = explicit.contains('固定') || explicit.contains('静止');
    if (explicit.isNotEmpty && !explicitIsFixed) return explicit;

    final visualText = [
      shot.visual,
      shot.content,
      shot.cameraNotes,
      shot.composition,
      shot.cameraAngle,
      shot.lightingMood,
      shot.colorPalette,
      shot.visualFocus,
      shot.transitionHint,
      shot.scene,
    ].join(' ');
    bool containsAny(Iterable<String> terms) => terms.any(visualText.contains);

    if (containsAny(const ['航拍', '无人机', '俯冲', '高空', '鸟瞰'])) {
      return '航拍俯冲或平稳升降，突出空间纵深与运动方向';
    }
    if (containsAny(const ['环绕', '旋转展示', '转台', '绕行', '360度'])) {
      return '缓慢环绕主体，连续展示外观与空间关系';
    }
    if (containsAny(const [
      '奔跑',
      '跑向',
      '追逐',
      '快走',
      '行走',
      '走向',
      '移动',
      '驶过',
      '骑行',
      '飞行',
      '冲向',
    ])) {
      return '平稳跟拍主体，速度与主体移动趋势一致';
    }
    if (containsAny(const ['向左', '向右', '左侧', '右侧', '横向', '掠过', '转向', '转身'])) {
      return '平稳横摇跟随主体方向，保持动作连续';
    }
    if (containsAny(const [
      '拿起',
      '举起',
      '展示',
      '特写',
      '细节',
      '靠近',
      '凝视',
      '表情',
      '打开',
      '触碰',
    ])) {
      return '缓慢推近主体，聚焦关键动作与细节变化';
    }
    if (containsAny(const [
      '全景',
      '远景',
      '展开',
      '揭示',
      '人群',
      '城市',
      '建筑',
      '环境全貌',
      '空间关系',
    ])) {
      return '缓慢拉远，逐步揭示环境全貌与空间关系';
    }
    final previousScale = _shotScale(previousShot?.shotSize ?? '');
    final currentScale = _shotScale(shot.shotSize);
    if (previousScale != null && currentScale != null) {
      if (currentScale < previousScale) {
        return '缓慢推近，承接上一镜并强化当前视觉焦点';
      }
      if (currentScale > previousScale) {
        return '缓慢拉远，承接上一镜并扩展环境信息';
      }
    }
    final nextScale = _shotScale(nextShot?.shotSize ?? '');
    if (currentScale != null && nextScale != null && nextScale < currentScale) {
      return '轻微推近，为下一镜的近景细节建立视觉动势';
    }
    return explicitIsFixed ? '固定镜头，保持画面稳定' : '轻微平稳推近，保持自然呼吸感';
  }

  static int? _shotScale(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    if (normalized.contains('特写')) return 0;
    if (normalized.contains('中近景')) return 2;
    if (normalized.contains('近景')) return 1;
    if (normalized.contains('中景')) return 3;
    if (normalized.contains('全景')) return 5;
    if (normalized.contains('远景')) return 6;
    return null;
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
