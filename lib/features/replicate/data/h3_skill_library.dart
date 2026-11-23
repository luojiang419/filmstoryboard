import 'package:flutter/services.dart';

import '../domain/h3_prompt_style.dart';

class H3SkillDocument {
  const H3SkillDocument({
    required this.style,
    required this.sourceRevision,
    required this.files,
  });

  final H3PromptStyle style;
  final String sourceRevision;
  final Map<String, String> files;

  int get fileCount => files.length;

  int get characterCount =>
      files.values.fold<int>(0, (total, content) => total + content.length);

  String toVisionModelContext() {
    final buffer = StringBuffer()
      ..writeln('【MiniMax-H3 完整官方 Skill（强制执行）】')
      ..writeln('所选叙事风格：${style.label}（${style.id}）')
      ..writeln('官方目录：${style.officialSkillPath}')
      ..writeln('固定源码版本：$sourceRevision')
      ..writeln('本次完整加载文件数：$fileCount')
      ..writeln('执行要求：')
      ..writeln('1. 下面是所选 Skill 的完整中文正文和它引用的全部参考文档，不是摘要。必须先阅读全文，再构建当前镜头脚本。')
      ..writeln('2. 按 Skill 的阶段、门禁、模板、视觉语法、连续性、声音和质检要求执行；当前任务没有提供的事实不得虚构。')
      ..writeln('3. Skill 中属于后续图像生成、视频生成、拼接或终检的步骤，用于预留镜头连续性和交付条件，不要伪造这些步骤已经完成。')
      ..writeln('4. 用户素材与画面可见事实优先于示例；示例只能学习结构，不能照抄示例中的人物、品牌、歌词、文案或产品事实。')
      ..writeln('5. 每个 <official_skill_file> 块都必须完整阅读，不能只执行第一个文件。');
    for (final entry in files.entries) {
      buffer
        ..writeln()
        ..writeln('<official_skill_file path="${entry.key}">')
        ..writeln(entry.value.trim())
        ..writeln('</official_skill_file>');
    }
    buffer.writeln('【完整官方 Skill 结束】');
    return buffer.toString().trim();
  }
}

abstract interface class H3SkillLibrary {
  Future<H3SkillDocument> loadForStyle(H3PromptStyle style);
}

class BundledH3SkillLibrary implements H3SkillLibrary {
  BundledH3SkillLibrary({AssetBundle? assetBundle})
    : _assetBundle = assetBundle;

  static const assetRoot = 'assets/minimax_h3_skills/';

  static const Map<String, List<String>> _runtimeFilesByStyle = {
    '3d-animation-short': [
      'skills/3d-animation-short-generator/SKILL.cn.md',
      'skills/3d-animation-short-generator/references/fallback-policy.md',
      'skills/3d-animation-short-generator/references/model-selection.md',
      'skills/3d-animation-short-generator/references/qc-checklist.md',
      'skills/3d-animation-short-generator/references/shot-table-spec.md',
      'skills/3d-animation-short-generator/references/storyboard-guidelines.md',
    ],
    'brand-promo': ['skills/brand-promo-video-generator/SKILL.cn.md'],
    'co-op-game-intro': [
      'skills/co-op-game-intro-generator/SKILL.cn.md',
      'skills/co-op-game-intro-generator/references/h3-confirmation-image-template.md',
      'skills/co-op-game-intro-generator/references/h3-video-prompt-template.md',
    ],
    'handdrawn-live': ['skills/handdrawn-live-video-generator/SKILL.cn.md'],
    'minimalist-product-ad': [
      'skills/minimalist-product-ad-generator/SKILL.cn.md',
    ],
    'music-video-subtitle': [
      'skills/music-video-subtitle-generator/SKILL.cn.md',
    ],
    'paper-collage-explainer': [
      'skills/paper-collage-explainer-generator/SKILL.cn.md',
    ],
    'papercraft-stop-motion': [
      'skills/papercraft-stop-motion-explainer/SKILL.cn.md',
    ],
  };

  final AssetBundle? _assetBundle;
  final Map<String, Future<H3SkillDocument>> _cache = {};

  AssetBundle get _bundle => _assetBundle ?? rootBundle;

  @override
  Future<H3SkillDocument> loadForStyle(H3PromptStyle style) {
    return _cache.putIfAbsent(style.id, () => _load(style));
  }

  Future<H3SkillDocument> _load(H3PromptStyle style) async {
    final paths = _runtimeFilesByStyle[style.id];
    if (paths == null || paths.isEmpty) {
      throw StateError('未配置叙事风格 ${style.label} 的官方 Skill 文件清单');
    }
    final files = <String, String>{};
    for (final path in paths) {
      final content = await _bundle.loadString('$assetRoot$path');
      if (content.trim().isEmpty) {
        throw FormatException('官方 Skill 文件为空：$path');
      }
      files[path] = content;
    }
    return H3SkillDocument(
      style: style,
      sourceRevision: H3PromptStyle.officialSourceRevision,
      files: Map.unmodifiable(files),
    );
  }
}
