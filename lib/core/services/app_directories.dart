import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_directories.dart';

class AppDirectories implements WorkspaceDirectories {
  const AppDirectories({
    required this.executableDirectory,
    required this.data,
    required this.projects,
    required this.imports,
    required this.cuts,
    required this.storyboards,
    required this.storyboardFolders,
    required this.generatedImages,
    required this.exports,
    required this.updates,
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

  final Directory executableDirectory;
  final Directory data;
  final Directory projects;
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
  final Directory updates;
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
  Directory get workspaceRoot => data;

  @override
  File get databaseFile => File(p.join(database.path, 'storyboard.sqlite'));

  List<Directory> get all => [
    data,
    projects,
    imports,
    cuts,
    storyboards,
    storyboardFolders,
    generatedImages,
    exports,
    updates,
    database,
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

  static Future<AppDirectories> create({Directory? executableDirectory}) async {
    final root =
        executableDirectory ?? File(Platform.resolvedExecutable).parent;
    final data = Directory(p.join(root.path, 'data'));
    final directories = AppDirectories(
      executableDirectory: root,
      data: data,
      projects: Directory(p.join(data.path, 'project')),
      imports: Directory(p.join(data.path, 'imports')),
      cuts: Directory(p.join(data.path, 'cuts')),
      storyboards: Directory(p.join(data.path, 'storyboards')),
      storyboardFolders: Directory(
        p.join(data.path, 'storyboards', 'custom_folders'),
      ),
      generatedImages: Directory(p.join(data.path, 'generated_images')),
      exports: Directory(p.join(data.path, 'exports')),
      updates: Directory(p.join(data.path, 'updates')),
      database: Directory(p.join(data.path, 'database')),
      temp: Directory(p.join(data.path, 'temp')),
      logs: Directory(p.join(data.path, 'logs')),
      videos: Directory(p.join(data.path, 'videos')),
      frames: Directory(p.join(data.path, 'frames')),
      analyses: Directory(p.join(data.path, 'analyses')),
      reports: Directory(p.join(data.path, 'reports')),
      scripts: Directory(p.join(data.path, 'scripts')),
      assets: Directory(p.join(data.path, 'assets')),
      prompts: Directory(p.join(data.path, 'prompts')),
    );

    for (final directory in directories.all) {
      if (!directory.existsSync()) {
        try {
          await directory.create(recursive: true);
        } catch (_) {
          if (directory.path != directories.projects.path) {
            rethrow;
          }
          // 默认工程目录不可写时仍允许应用启动，创建工程时再引导选择自定义位置。
        }
      }
    }
    return directories;
  }
}
