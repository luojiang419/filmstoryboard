import 'dart:io';

import 'package:path/path.dart' as p;

class ProjectPathResolver {
  ProjectPathResolver(Directory projectRoot)
    : _root = p.normalize(projectRoot.absolute.path);

  final String _root;

  String toStoredPath(String runtimePath) {
    final normalized = p.normalize(File(runtimePath).absolute.path);
    if (!p.isWithin(_root, normalized)) {
      throw ArgumentError.value(runtimePath, 'runtimePath', '路径不在工程目录内');
    }
    return p.relative(normalized, from: _root).replaceAll('\\', '/');
  }

  String toRuntimePath(String storedPath) {
    if (!isSafeRelativePath(storedPath)) {
      throw ArgumentError.value(storedPath, 'storedPath', '工程相对路径无效');
    }
    final resolved = p.normalize(
      p.joinAll([_root, ...storedPath.replaceAll('\\', '/').split('/')]),
    );
    if (!p.isWithin(_root, resolved)) {
      throw ArgumentError.value(storedPath, 'storedPath', '工程路径越界');
    }
    return resolved;
  }

  static bool isSafeRelativePath(String value) {
    final trimmed = value.trim().replaceAll('\\', '/');
    if (trimmed.isEmpty || p.isAbsolute(trimmed)) {
      return false;
    }
    final parts = trimmed.split('/');
    return !parts.any((part) => part.isEmpty || part == '.' || part == '..');
  }
}
