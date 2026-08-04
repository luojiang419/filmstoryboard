import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/workspace_directories.dart';

class VideoGenerationDirectories {
  const VideoGenerationDirectories({required this.root, required this.results});

  final Directory root;
  final Directory results;

  static VideoGenerationDirectories resolve({
    required WorkspaceDirectories projectDirectories,
    required String scriptName,
    required String scriptId,
    String? stableDirectoryName,
  }) {
    final shortId = _shortId(scriptId);
    final requestedName = stableDirectoryName?.trim().isNotEmpty == true
        ? stableDirectoryName!.trim()
        : scriptName;
    final safeBase = _safeName(requestedName);
    final suffix = '-$shortId';
    final baseWithoutSuffix = safeBase.endsWith(suffix)
        ? safeBase.substring(0, safeBase.length - suffix.length)
        : safeBase;
    final directoryName = '${_truncate(baseWithoutSuffix, 48)}$suffix';
    final root = Directory(
      p.join(projectDirectories.videos.path, 'generated', directoryName),
    );
    return VideoGenerationDirectories(
      root: root,
      results: Directory(p.join(root.path, '生成结果')),
    );
  }

  Future<void> create() async {
    await results.create(recursive: true);
  }

  static String _safeName(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return normalized.isEmpty ? '拍摄脚本' : normalized;
  }

  static String _shortId(String value) {
    final normalized = value.trim();
    if (normalized.length <= 8) return normalized;
    return normalized.substring(0, 8);
  }

  static String _truncate(String value, int maxLength) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) return normalized;
    return normalized.substring(0, maxLength).trimRight();
  }
}
