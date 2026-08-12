import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/resolve_plugin_installer.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/presentation/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('设置页插件菜单可从 data 内置包执行安装', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final Directory bundleRoot;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'settings-resolve-plugin-widget-',
      );
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      bundleRoot = await _createBundle(root);
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final calls = <(String, List<String>, bool)>[];
    final installer = ResolvePluginInstaller(
      bundleRoot: bundleRoot.path,
      platformIsWindows: true,
      processRunner: (executable, arguments, {required runInShell}) async {
        calls.add((executable, arguments, runInShell));
        return ProcessResult(1, 0, '', '');
      },
    );
    addTearDown(() async {
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
          resolvePluginInstallerProvider.overrideWithValue(installer),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );

    final menu = find.byKey(const ValueKey('settings-function-menu'));
    final pluginsItem = find.byKey(const ValueKey('settings-menu-plugins'));
    await tester.drag(menu, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(pluginsItem);
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('install-resolve-plugin-button'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'powershell.exe');
    expect(calls.single.$2, contains('-ElevateIfNeeded'));
    expect(
      calls.single.$2,
      contains(
        p.join(bundleRoot.path, ResolvePluginInstaller.pluginDirectoryName),
      ),
    );
    expect(find.textContaining('达芬奇插件文件已复制'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<Directory> _createBundle(Directory root) async {
  final bundleRoot = Directory(p.join(root.path, 'data', 'resolve_plugin'));
  final windows = Directory(p.join(bundleRoot.path, 'windows'));
  final plugin = Directory(
    p.join(bundleRoot.path, ResolvePluginInstaller.pluginDirectoryName),
  );
  await windows.create(recursive: true);
  await plugin.create(recursive: true);
  await File(
    p.join(windows.path, ResolvePluginInstaller.installScriptName),
  ).writeAsString('# test installer');
  await File(p.join(plugin.path, 'manifest.xml')).writeAsString('<Plugin/>');
  await File(p.join(plugin.path, 'package.json')).writeAsString('{}');
  await File(p.join(plugin.path, 'main.js')).writeAsString('');
  return bundleRoot;
}
