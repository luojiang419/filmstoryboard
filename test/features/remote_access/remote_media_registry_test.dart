import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只注册当前工程内允许格式且工程关闭后立即失效', () async {
    final root = await Directory.systemTemp.createTemp('remote-media-test-');
    final outside = await Directory.systemTemp.createTemp(
      'remote-media-outside-',
    );
    final directories = ProjectDirectories.fromRoot(root);
    await directories.create();
    final database = await AppDatabase.open(directories.databaseFile);
    final bus = RemoteChangeBus();
    addTearDown(() async {
      database.dispose();
      await bus.close();
      if (root.existsSync()) await root.delete(recursive: true);
      if (outside.existsSync()) await outside.delete(recursive: true);
    });
    final registry = RemoteWorkspaceRegistry(bus)
      ..attachContext(
        RemoteWorkspaceContext(
          projectId: 'media-project',
          projectName: '媒体工程',
          database: database,
          directories: directories,
        ),
      );
    final media = RemoteMediaRegistry(
      workspaceRegistry: registry,
      secret: 'stable-secret',
    );
    final insideImage = File('${directories.frames.path}\\inside.png')
      ..writeAsBytesSync(const [1, 2, 3]);
    final insideSvg = File('${directories.frames.path}\\unsafe.svg')
      ..writeAsStringSync('<svg></svg>');
    final outsideImage = File('${outside.path}\\outside.png')
      ..writeAsBytesSync(const [4, 5, 6]);

    final mediaId = media.registerProjectFile(insideImage.path);

    expect(mediaId, isNotNull);
    expect(media.resolve(mediaId!)?.contentType, 'image/png');
    expect(media.registerProjectFile(insideSvg.path), isNull);
    expect(media.registerProjectFile(outsideImage.path), isNull);

    registry.detach(projectId: 'media-project');
    expect(media.resolve(mediaId), isNull);
  });
}
