import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'remote_workspace_registry.dart';

class RemoteMediaResource {
  const RemoteMediaResource({
    required this.id,
    required this.projectId,
    required this.file,
    required this.contentType,
  });

  final String id;
  final String projectId;
  final File file;
  final String contentType;
}

class RemoteMediaRegistry {
  RemoteMediaRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    String? secret,
  }) : _workspaceRegistry = workspaceRegistry,
       _secret = secret ?? _secureSecret();

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final String _secret;
  final Map<String, RemoteMediaResource> _resources = {};

  String? registerProjectFile(String path) {
    final workspace = _workspaceRegistry.current;
    if (workspace == null || path.trim().isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final rootPath = _canonicalDirectory(workspace.directories.root);
    final filePath = _canonicalFile(file);
    if (!_isWithin(rootPath, filePath)) return null;
    final contentType = _contentType(filePath);
    if (contentType == null) return null;
    final id = sha256
        .convert(
          utf8.encode('$_secret\u0000${workspace.projectId}\u0000$filePath'),
        )
        .toString()
        .substring(0, 32);
    _resources[id] = RemoteMediaResource(
      id: id,
      projectId: workspace.projectId,
      file: File(filePath),
      contentType: contentType,
    );
    return id;
  }

  RemoteMediaResource? resolve(String id) {
    final workspace = _workspaceRegistry.current;
    final resource = _resources[id];
    if (workspace == null ||
        resource == null ||
        resource.projectId != workspace.projectId ||
        !resource.file.existsSync()) {
      return null;
    }
    final rootPath = _canonicalDirectory(workspace.directories.root);
    final filePath = _canonicalFile(resource.file);
    if (!_isWithin(rootPath, filePath)) {
      _resources.remove(id);
      return null;
    }
    return RemoteMediaResource(
      id: resource.id,
      projectId: resource.projectId,
      file: File(filePath),
      contentType: resource.contentType,
    );
  }

  static String _canonicalDirectory(Directory directory) {
    final absolute = directory.absolute;
    return absolute.existsSync()
        ? absolute.resolveSymbolicLinksSync()
        : p.normalize(absolute.path);
  }

  static String _canonicalFile(File file) {
    final absolute = file.absolute;
    return absolute.existsSync()
        ? absolute.resolveSymbolicLinksSync()
        : p.normalize(absolute.path);
  }

  static bool _isWithin(String rootPath, String filePath) {
    final normalizedRoot = p.normalize(rootPath).toLowerCase();
    final normalizedFile = p.normalize(filePath).toLowerCase();
    return normalizedFile == normalizedRoot ||
        p.isWithin(normalizedRoot, normalizedFile);
  }

  static String? _contentType(String path) =>
      switch (p.extension(path).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.bmp' => 'image/bmp',
        '.mp4' => 'video/mp4',
        '.mov' => 'video/quicktime',
        '.mkv' => 'video/x-matroska',
        '.webm' => 'video/webm',
        '.mp3' => 'audio/mpeg',
        '.wav' => 'audio/wav',
        '.m4a' => 'audio/mp4',
        '.aac' => 'audio/aac',
        '.ogg' => 'audio/ogg',
        _ => null,
      };

  static String _secureSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
