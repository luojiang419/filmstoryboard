import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_theme.dart';
import 'app/storyboard_app.dart';
import 'core/bootstrap/app_bootstrap.dart';
import 'core/services/app_directories.dart';
import 'features/updater/data/updater_service.dart';
import 'features/updater/domain/app_update_config.dart';
import 'features/updater/domain/update_models.dart';
import 'features/updater/presentation/app_updater_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final updaterSession = UpdaterService.parseInstallSessionArgs(args);
  if (updaterSession != null) {
    await _runUpdaterSessionApp(updaterSession);
    return;
  }

  final bootstrap = await AppBootstrap.initialize();

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1320, 860),
    minimumSize: Size(1080, 720),
    center: true,
    title: AppUpdateConfig.windowTitle,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      overrides: bootstrap.providerOverrides,
      child: StoryboardApp(
        initialProjectIndexPath: _projectIndexArgument(args),
      ),
    ),
  );
}

String? _projectIndexArgument(List<String> args) {
  for (final argument in args) {
    if (argument.toLowerCase().endsWith('.storyboard')) {
      return argument;
    }
  }
  return null;
}

Future<void> _runUpdaterSessionApp(UpdaterInstallSession session) async {
  final directories = await AppDirectories.create(
    executableDirectory: Directory(session.installRoot),
  );
  final service = UpdaterService(directories: directories);

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(760, 500),
    minimumSize: Size(640, 460),
    center: true,
    title: 'filmstoryboard 正在更新',
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'filmstoryboard 正在更新',
      theme: AppTheme.dark(),
      home: AppUpdaterPage(session: session, service: service),
    ),
  );
}
