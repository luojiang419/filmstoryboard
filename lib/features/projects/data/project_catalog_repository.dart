import 'dart:io';
import 'dart:isolate';

import '../../../core/database/app_database.dart';
import '../domain/project_manifest.dart';
import '../domain/project_models.dart';

class ProjectCatalogRepository {
  const ProjectCatalogRepository(this._database);

  final AppDatabase _database;

  List<ProjectEntry> load() => _inspectRecords(_database.listProjectCatalog());

  Future<List<ProjectEntry>> loadAsync() {
    final records = _database.listProjectCatalog();
    return Isolate.run(() => _inspectRecords(records));
  }

  static List<ProjectEntry> _inspectRecords(
    List<ProjectCatalogRecord> records,
  ) {
    final entries = <ProjectEntry>[];
    for (final record in records) {
      final indexFile = File(record.indexPath);
      var health = ProjectHealth.available;
      var displayName = record.displayName;
      var updatedAt = DateTime.parse(record.updatedAt);
      if (!indexFile.existsSync()) {
        health = ProjectHealth.missing;
      } else {
        try {
          final manifest = ProjectManifest.decode(indexFile.readAsStringSync());
          displayName = manifest.name;
          updatedAt = manifest.updatedAt;
        } on UnsupportedError {
          health = ProjectHealth.newerVersion;
        } catch (_) {
          health = ProjectHealth.invalid;
        }
      }
      entries.add(
        ProjectEntry(
          projectId: record.projectId,
          indexPath: record.indexPath,
          displayName: displayName,
          createdAt: DateTime.parse(record.createdAt),
          updatedAt: updatedAt,
          lastOpenedAt: DateTime.parse(record.lastOpenedAt),
          health: health,
        ),
      );
    }
    return entries;
  }

  void register(
    ProjectManifest manifest,
    File indexFile, {
    DateTime? openedAt,
  }) {
    final timestamp = (openedAt ?? DateTime.now()).toUtc().toIso8601String();
    _database.upsertProjectCatalog(
      ProjectCatalogRecord(
        projectId: manifest.projectId,
        indexPath: indexFile.absolute.path,
        displayName: manifest.name,
        createdAt: manifest.createdAt.toUtc().toIso8601String(),
        updatedAt: manifest.updatedAt.toUtc().toIso8601String(),
        lastOpenedAt: timestamp,
      ),
    );
  }

  void remove(String projectId) => _database.removeProjectCatalog(projectId);
}
