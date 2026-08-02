import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:test/test.dart';

void main() {
  test('创建完整 data 目录结构', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_dirs_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);

    expect(directories.data.existsSync(), isTrue);
    expect(directories.imports.existsSync(), isTrue);
    expect(directories.cuts.existsSync(), isTrue);
    expect(directories.storyboards.existsSync(), isTrue);
    expect(directories.storyboardFolders.existsSync(), isTrue);
    expect(directories.generatedImages.existsSync(), isTrue);
    expect(directories.exports.existsSync(), isTrue);
    expect(directories.updates.existsSync(), isTrue);
    expect(directories.database.existsSync(), isTrue);
    expect(directories.temp.existsSync(), isTrue);
    expect(directories.logs.existsSync(), isTrue);
    expect(
      directories.databaseFile.path,
      p.join(root.path, 'data', 'database', 'storyboard.sqlite'),
    );
    expect(
      directories.storyboardFolders.path,
      p.join(root.path, 'data', 'storyboards', 'custom_folders'),
    );
    expect(
      directories.generatedImages.path,
      p.join(root.path, 'data', 'generated_images'),
    );
    expect(directories.updates.path, p.join(root.path, 'data', 'updates'));
  });
}
