import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/presentation/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('设置页解析维度可独立取消并即时持久化', (tester) async {
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'settings_analysis_dimensions_',
      );
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
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
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    final menu = find.byKey(const ValueKey('settings-function-menu'));
    final analysisItem = find.byKey(
      const ValueKey('settings-menu-analysisDimensions'),
    );
    await tester.scrollUntilVisible(
      analysisItem,
      300,
      scrollable: find.descendant(of: menu, matching: find.byType(Scrollable)),
    );
    await tester.tap(analysisItem);
    await tester.pumpAndSettle();

    final multiFinder = find.byKey(
      const ValueKey('video-analysis-multi-dimension-checkbox'),
    );
    final shotFinder = find.byKey(
      const ValueKey('video-analysis-shot-details-checkbox'),
    );
    expect(tester.widget<CheckboxListTile>(multiFinder).value, isTrue);
    expect(tester.widget<CheckboxListTile>(shotFinder).value, isTrue);

    await tester.tap(multiFinder);
    await tester.pump();
    await tester.tap(shotFinder);
    await tester.pump();

    expect(
      settingsController.value.videoAnalysisMultiDimensionEnabled,
      isFalse,
    );
    expect(settingsController.value.videoAnalysisShotDetailsEnabled, isFalse);
    expect(database.getSetting('videoAnalysisMultiDimensionEnabled'), 'false');
    expect(database.getSetting('videoAnalysisShotDetailsEnabled'), 'false');
  });
}
