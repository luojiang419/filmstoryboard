import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../projects/data/project_path_resolver.dart';

/// Content-based association survives board reorder and project relocation.
class StoryboardDepthRepository {
  StoryboardDepthRepository(this.database, Directory root)
    : resolver = ProjectPathResolver(root);
  final AppDatabase database;
  final ProjectPathResolver resolver;

  static String fingerprint(File source) =>
      sha256.convert(source.readAsBytesSync()).toString();

  void save(String fingerprint, String depthPath) {
    database.setSetting(
      'storyboardDepth:$fingerprint',
      resolver.toStoredPath(depthPath),
    );
  }

  bool wasApplied(String shotId, String fingerprint, String depthPath) {
    try {
      return database.getSetting(
            'appliedStoryboardDepth:$shotId:$fingerprint',
          ) ==
          resolver.toStoredPath(depthPath);
    } on ArgumentError {
      return false;
    }
  }

  void markApplied(String shotId, String fingerprint, String depthPath) {
    database.setSetting(
      'appliedStoryboardDepth:$shotId:$fingerprint',
      resolver.toStoredPath(depthPath),
    );
  }

  String? find(String fingerprint, {String? shotId}) {
    final stored = database.getSetting('storyboardDepth:$fingerprint');
    if (stored == null || stored.isEmpty) return null;
    if (shotId != null &&
        database.getSetting('ignoredStoryboardDepth:$shotId:$fingerprint') ==
            stored) {
      return null;
    }
    try {
      final path = p.isAbsolute(stored)
          ? stored
          : resolver.toRuntimePath(stored);
      return File(path).existsSync() ? path : null;
    } on ArgumentError {
      return null;
    }
  }

  void ignore(String shotId, String fingerprint) {
    database.setSetting(
      'ignoredStoryboardDepth:$shotId:$fingerprint',
      database.getSetting('storyboardDepth:$fingerprint') ?? '',
    );
  }
}
