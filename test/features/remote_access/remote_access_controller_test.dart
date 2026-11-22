import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_controller.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_media_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/data/remote_access_repository.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_auth_models.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('控制器默认关闭并可持久化启停、端口和配对会话', () async {
    final root = await Directory.systemTemp.createTemp(
      'filmstoryboard-remote-controller-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final webRoot = Directory('${root.path}${Platform.pathSeparator}web');
    await webRoot.create();
    await File(
      '${webRoot.path}${Platform.pathSeparator}index.html',
    ).writeAsString('<!doctype html><title>Remote</title>');
    final changeBus = RemoteChangeBus();
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus);
    final mediaRegistry = RemoteMediaRegistry(
      workspaceRegistry: workspaceRegistry,
    );
    final repository = RemoteAccessRepository(database);
    final controller = RemoteAccessController(
      repository: repository,
      directories: directories,
      facade: RemoteAccessFacade(
        workspaceRegistry: workspaceRegistry,
        changeBus: changeBus,
        mediaRegistry: mediaRegistry,
      ),
      changeBus: changeBus,
      mediaRegistry: mediaRegistry,
      webRootOverride: webRoot,
    );
    addTearDown(() async {
      controller.dispose();
      await changeBus.close();
      database.dispose();
      await root.delete(recursive: true);
    });

    await controller.initialize();
    expect(controller.config.enabled, isFalse);
    expect(controller.isRunning, isFalse);

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await controller.setPort(port);
    await controller.setEnabled(true);

    expect(controller.isRunning, isTrue);
    expect(controller.webAssetsAvailable, isTrue);
    expect(controller.localAccessUrl, 'http://127.0.0.1:$port');
    final pairing = controller.createPairingCode(RemoteAccessRole.director);
    expect(pairing.code, matches(RegExp(r'^\d{6}$')));

    await controller.setEnabled(false);
    expect(controller.isRunning, isFalse);
    expect(controller.sessions, isEmpty);
    expect(repository.load().enabled, isFalse);
    expect(repository.load().port, port);
  });
}
