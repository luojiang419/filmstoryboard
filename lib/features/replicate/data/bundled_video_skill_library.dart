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
      ..writeln('【软件内置视频后端 Skill（强制读取）】')
      ..writeln('目标后端：$label')
      ..writeln('固定资源版本：$sourceRevision')
      ..writeln('本次按需加载文件数：$fileCount')
      ..writeln('执行边界：')
      ..writeln('1. 你是当前软件所连接的视觉模型，必须阅读下面的完整 Skill 文件，并据此规划适配目标后端的视频提示词。')
      ..writeln('2. CLI 登录、上传、画布、提交、轮询和下载由软件本身执行；不得声称你已经执行命令、登录、扣费或生成。')
      ..writeln('3. 只把 Skill 中与模型能力、素材引用、提示词结构、参数边界和失败纪律有关的规则落实到当前镜头设计。')
      ..writeln(
        '4. 模型清单和动态参数仍以软件运行时读取结果为准；不得用示例虚构模型名、账号、额度、URL 或 generationId。',
      )
      ..writeln('5. 用户素材和画面可见事实优先于示例内容，示例只能学习结构。');
    for (final entry in files.entries) {
      buffer
        ..writeln()
        ..writeln('<bundled_video_skill_file path="${entry.key}">')
        ..writeln(entry.value.trim())
        ..writeln('</bundled_video_skill_file>');
    }
    buffer.writeln('【软件内置视频后端 Skill 结束】');
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
    BundledVideoSkillKind.klingCli: [
      'kling-cli/SKILL.md',
      'kling-cli/reference.md',
      'kling-cli/api-examples.md',
    ],
    BundledVideoSkillKind.libTvCli: [
      'libtv-cli/SKILL.md',
      'libtv-cli/commands/login.md',
      'libtv-cli/commands/account.md',
      'libtv-cli/commands/model.md',
      'libtv-cli/commands/project.md',
      'libtv-cli/commands/upload.md',
      'libtv-cli/commands/node.md',
      'libtv-cli/model-schema/schema.md',
      'libtv-cli/node-types/image.md',
      'libtv-cli/node-types/video.md',
      'libtv-cli/prompt-guides/SD2提示词规则.md',
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
    final identity = [
      config.id,
      config.name,
      config.model,
      config.baseUrl,
    ].join(' ').toLowerCase();
    if (identity.contains('minimax') ||
        RegExp(r'(^|[^a-z0-9])h3([^a-z0-9]|$)').hasMatch(identity)) {
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
        BundledVideoSkillKind.klingCli =>
          '43237a7bc8f500652c4de97462931182e9a125e0 / Skill 0.1.3',
        BundledVideoSkillKind.libTvCli => 'Skill 1.1.3',
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
