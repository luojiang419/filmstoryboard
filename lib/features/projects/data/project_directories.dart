import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/workspace_directories.dart';

class ProjectDirectories implements WorkspaceDirectories {
  const ProjectDirectories({
    required this.root,
    required this.imports,
    required this.cuts,
    required this.storyboards,
    required this.storyboardFolders,
    required this.generatedImages,
    required this.exports,
    required this.database,
    required this.temp,
    required this.logs,
    required this.videos,
    required this.frames,
    required this.analyses,
    required this.reports,
    required this.scripts,
    required this.assets,
    required this.prompts,
  });

  final Directory root;
  @override
  final Directory imports;
  @override
  final Directory cuts;
  @override
  final Directory storyboards;
  @override
  final Directory storyboardFolders;
  @override
  final Directory generatedImages;
  @override
  final Directory exports;
  @override
  final Directory database;
  @override
  final Directory temp;
  @override
  final Directory logs;
  @override
  final Directory videos;
  @override
  final Directory frames;
  @override
  final Directory analyses;
  @override
  final Directory reports;
  @override
  final Directory scripts;
  @override
  final Directory assets;
  @override
  final Directory prompts;

  @override
  Directory get workspaceRoot => root;

  File get indexFile => File(p.join(root.path, 'project.storyboard'));
  @override
  File get databaseFile => File(p.join(database.path, 'project.sqlite'));
  File get lockFile => File(p.join(database.path, 'project.lock'));

  List<Directory> get managedDirectories => [
    database,
    imports,
    cuts,
    storyboards,
    storyboardFolders,
    generatedImages,
    exports,
    temp,
    logs,
    videos,
    frames,
    analyses,
    reports,
    scripts,
    assets,
    prompts,
  ];

  factory ProjectDirectories.fromRoot(Directory root) {
    final storyboards = Directory(p.join(root.path, 'storyboards'));
    return ProjectDirectories(
      root: root,
      imports: Directory(p.join(root.path, 'imports')),
      cuts: Directory(p.join(root.path, 'cuts')),
      storyboards: storyboards,
      storyboardFolders: Directory(p.join(storyboards.path, 'custom_folders')),
      generatedImages: Directory(p.join(root.path, 'generated_images')),
      exports: Directory(p.join(root.path, 'exports')),
      database: Directory(p.join(root.path, 'database')),
      temp: Directory(p.join(root.path, 'temp')),
      logs: Directory(p.join(root.path, 'logs')),
      videos: Directory(p.join(root.path, 'videos')),
      frames: Directory(p.join(root.path, 'frames')),
      analyses: Directory(p.join(root.path, 'analyses')),
      reports: Directory(p.join(root.path, 'reports')),
      scripts: Directory(p.join(root.path, 'scripts')),
      assets: Directory(p.join(root.path, 'assets')),
      prompts: Directory(p.join(root.path, 'prompts')),
    );
  }

  Future<void> create() async {
    for (final directory in managedDirectories) {
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
    }
  }
}
