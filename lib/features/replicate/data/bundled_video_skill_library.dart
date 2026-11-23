import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../settings/domain/video_generation_api_config.dart';

enum BundledVideoSkillKind { klingCli, libTvCli, minimaxH3 }

class BundledVideoSkillDocument {
  const BundledVideoSkillDocument({
    required this.kind,
    required this.label,
    required this.sourceRevision,
    required this.files,
  });

  final BundledVideoSkillKind kind;
  final String label;
  final String sourceRevision;
  final Map<String, String> files;

  int get fileCount => files.length;

  String toVisionModelContext() {
    final buffer = StringBuffer()
      ..writeln('【软件内置视频提示词 Skill（仅供当前后端）】')
      ..writeln('目标后端：$label')
      ..writeln('固定资源版本：$sourceRevision')
      ..writeln('本次按需加载文件数：$fileCount')
      ..writeln('执行边界：')
      ..writeln('1. 只读取下面属于当前目标后端的提示词 Skill，不得套用其他视频模型的格式、字段、标签或示例。')
      ..writeln('2. 只把素材引用、提示词结构、动作、运镜和必要约束落实到当前镜头；提交和生成由软件执行。')
      ..writeln('3. 模型与参数以软件运行时配置为准；不得输出命令、账号、URL、任务 ID 或执行声明。')
      ..writeln('4. 用户素材和画面可见事实优先；不得从示例复制主体、服装、产品、颜色或剧情。');
    for (final entry in files.entries) {
      buffer
        ..writeln()
        ..writeln('<bundled_video_skill_file path="${entry.key}">')
        ..writeln(entry.value.trim())
        ..writeln('</bundled_video_skill_file>');
    }
    buffer.writeln('【软件内置视频提示词 Skill 结束】');
    return buffer.toString().trim();
  }
}

abstract interface class VideoSkillLibrary {
  Future<BundledVideoSkillDocument?> loadForConfig(
    VideoGenerationApiConfig? config,
  );
}

class BundledVideoSkillLibrary implements VideoSkillLibrary {
  BundledVideoSkillLibrary({AssetBundle? assetBundle})
    : _assetBundle = assetBundle;

  static const _cliAssetRoot = 'assets/video_cli_skills/';
  static const _h3AssetRoot = 'assets/minimax_h3_skills/';

  static const Map<BundledVideoSkillKind, List<String>> runtimeFiles = {
    BundledVideoSkillKind.klingCli: ['kling-cli/prompt-guide.md'],
    BundledVideoSkillKind.libTvCli: [
      'libtv-cli/prompt-guides/image-to-video-prompt-guide.md',
    ],
    BundledVideoSkillKind.minimaxH3: [
      'skills/h3-prompt-writing/SKILL.md',
      'skills/h3-prompt-writing/references/base-cn.txt',
      'skills/h3-prompt-writing/references/ref-cn.txt',
    ],
  };

  final AssetBundle? _assetBundle;
  final Map<BundledVideoSkillKind, Future<BundledVideoSkillDocument>> _cache =
      {};

  AssetBundle get _bundle => _assetBundle ?? rootBundle;

  @override
  Future<BundledVideoSkillDocument?> loadForConfig(
    VideoGenerationApiConfig? config,
  ) {
    final kind = kindForConfig(config);
    if (kind == null) return Future.value();
    return _cache.putIfAbsent(kind, () => _load(kind));
  }

  static BundledVideoSkillKind? kindForConfig(
    VideoGenerationApiConfig? config,
  ) {
    if (config == null) return null;
    if (config.isLibTvCli) return BundledVideoSkillKind.libTvCli;
    if (config.isKlingCli) return BundledVideoSkillKind.klingCli;
    if (config.supportsLocalH3SkillRouting) {
      return BundledVideoSkillKind.minimaxH3;
    }
    return null;
  }

  Future<BundledVideoSkillDocument> _load(BundledVideoSkillKind kind) async {
    final paths = runtimeFiles[kind];
    if (paths == null || paths.isEmpty) {
      throw StateError('未配置 ${kind.name} 的内置 Skill 文件清单');
    }
    final root = kind == BundledVideoSkillKind.minimaxH3
        ? _h3AssetRoot
        : _cliAssetRoot;
    final files = <String, String>{};
    for (final path in paths) {
      final assetPath = '$root$path';
      final content = await _loadString(assetPath);
      if (content.trim().isEmpty) {
        throw FormatException('内置视频 Skill 文件为空：$path');
      }
      files[path] = content;
    }
    return BundledVideoSkillDocument(
      kind: kind,
      label: switch (kind) {
        BundledVideoSkillKind.klingCli => '可灵 CLI',
        BundledVideoSkillKind.libTvCli => 'LibTV CLI · Seedance 2.0',
        BundledVideoSkillKind.minimaxH3 => 'MiniMax H3',
      },
      sourceRevision: switch (kind) {
        BundledVideoSkillKind.klingCli => '可灵图生视频规则 1.0',
        BundledVideoSkillKind.libTvCli =>
          'Doubao Seedance 2.0 官方指南精炼版 / 2026-06-08',
        BundledVideoSkillKind.minimaxH3 =>
          'b7227fa6a6206e9fb30562383d39e53cf3866a48 / 中文适配',
      },
      files: Map.unmodifiable(files),
    );
  }

  Future<String> _loadString(String assetPath) async {
    try {
      return await _bundle.loadString(assetPath);
    } catch (_) {
      if (_assetBundle != null || !kDebugMode) rethrow;
      final sourceFile = File(assetPath);
      if (!await sourceFile.exists()) rethrow;
      return sourceFile.readAsString();
    }
  }
}
