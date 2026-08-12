import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'remote_workspace_registry.dart';

class RemoteVideoUpload {
  const RemoteVideoUpload({
    required this.id,
    required this.projectId,
    required this.fileName,
    required this.file,
    required this.size,
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final String fileName;
  final File file;
  final int size;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'fileName': fileName,
    'size': size,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

class RemoteUploadException implements Exception {
  const RemoteUploadException(this.code, this.message);

  final String code;
  final String message;
}

class RemoteUploadRegistry {
  RemoteUploadRegistry({
    required RemoteWorkspaceRegistry workspaceRegistry,
    Uuid uuid = const Uuid(),
    DateTime Function()? now,
  }) : _workspaceRegistry = workspaceRegistry,
       _uuid = uuid,
       _now = now ?? DateTime.now;

  static const videoExtensions = {
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
    '.webm',
    '.m4v',
  };

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final Uuid _uuid;
  final DateTime Function() _now;
  final Map<String, RemoteVideoUpload> _uploads = {};

  Future<RemoteVideoUpload> receiveVideo({
    required String fileName,
    required Stream<List<int>> bytes,
    required int maxBytes,
    int? declaredLength,
  }) async {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      throw const RemoteUploadException('workspace_unavailable', '桌面端当前没有打开工程');
    }
    final safeName = _safeFileName(fileName);
    final extension = p.extension(safeName).toLowerCase();
    if (!videoExtensions.contains(extension)) {
      throw const RemoteUploadException(
        'unsupported_video_format',
        '仅支持 MP4、MOV、MKV、AVI、WebM 和 M4V 视频',
      );
    }
    if (maxBytes <= 0 ||
        (declaredLength != null && declaredLength > maxBytes)) {
      throw const RemoteUploadException('upload_too_large', '视频超过允许的上传大小');
    }
    final directory = Directory(
      p.join(workspace.directories.temp.path, 'remote_uploads'),
    );
    await directory.create(recursive: true);
    final id = _uuid.v4();
    final file = File(p.join(directory.path, '$id$extension'));
    var received = 0;
    final sink = file.openWrite(mode: FileMode.writeOnly);
    try {
      await for (final chunk in bytes) {
        received += chunk.length;
        if (received > maxBytes) {
          throw const RemoteUploadException('upload_too_large', '视频超过允许的上传大小');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (received == 0) {
        throw const RemoteUploadException('empty_upload', '上传视频不能为空');
      }
      if (declaredLength != null &&
          declaredLength >= 0 &&
          received != declaredLength) {
        throw const RemoteUploadException('upload_incomplete', '上传视频大小与声明不一致');
      }
      final upload = RemoteVideoUpload(
        id: id,
        projectId: workspace.projectId,
        fileName: safeName,
        file: file,
        size: received,
        createdAt: _now().toUtc(),
      );
      _uploads[id] = upload;
      _prune();
      return upload;
    } catch (_) {
      await sink.close();
      if (file.existsSync()) await file.delete();
      rethrow;
    }
  }

  RemoteVideoUpload? claimCurrentProject(String uploadId) {
    final projectId = _workspaceRegistry.current?.projectId;
    final upload = _uploads.remove(uploadId);
    if (upload == null ||
        upload.projectId != projectId ||
        !upload.file.existsSync()) {
      return null;
    }
    return upload;
  }

  Future<void> discard(RemoteVideoUpload upload) async {
    _uploads.remove(upload.id);
    if (upload.file.existsSync()) await upload.file.delete();
  }

  void _prune() {
    final cutoff = _now().toUtc().subtract(const Duration(hours: 24));
    final expired = _uploads.values
        .where((upload) => upload.createdAt.isBefore(cutoff))
        .toList();
    for (final upload in expired) {
      _uploads.remove(upload.id);
      if (upload.file.existsSync()) {
        try {
          upload.file.deleteSync();
        } on FileSystemException {
          // 后续清理周期重试，不影响当前上传。
        }
      }
    }
  }

  static String _safeFileName(String source) {
    final base = p.basename(source.trim());
    final safe = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw const RemoteUploadException('invalid_file_name', '视频文件名无效');
    }
    if (safe.length <= 180) return safe;
    final extension = p.extension(safe);
    final stem = p.basenameWithoutExtension(safe);
    final stemLimit = (180 - extension.length).clamp(1, 160);
    return '${stem.substring(0, stem.length.clamp(0, stemLimit))}$extension';
  }
}
