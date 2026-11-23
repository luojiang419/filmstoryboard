import 'dart:io';

import '../../../core/database/app_database.dart';
import '../data/project_directories.dart';
import 'project_manifest.dart';

enum ProjectHealth { available, missing, invalid, newerVersion }

class ProjectEntry {
  const ProjectEntry({
    required this.projectId,
    required this.indexPath,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOpenedAt,
    required this.health,
  });

  final String projectId;
  final String indexPath;
  final String displayName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastOpenedAt;
  final ProjectHealth health;

  bool get exists => health == ProjectHealth.available;
}

class ProjectSession {
  ProjectSession({
    required this.manifest,
    required this.directories,
    required this.database,
    required RandomAccessFile lockFile,
  }) : _lockFile = lockFile;

  final ProjectManifest manifest;
  final ProjectDirectories directories;
  final AppDatabase database;
  final RandomAccessFile _lockFile;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      try {
        database.checkpoint();
      } finally {
        database.dispose();
      }
    } finally {
      try {
        await _lockFile.unlock();
      } finally {
        await _lockFile.close();
      }
    }
  }
}

class ProjectException implements Exception {
  const ProjectException(this.message);

  final String message;

  @override
  String toString() => message;
}
