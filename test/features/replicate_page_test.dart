import 'dart:io';

import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/presentation/replicate_page.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('一键复刻页展示三步流并从镜头确认进入素材准备', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('replicate_page_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
    });
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: '页面测试脚本');
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(content: '人物拿起产品并看向镜头', shotSize: '中景'),
    );
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    addTearDown(() async {
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          replicateControllerProvider.overrideWithValue(replicateController),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: ReplicatePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('replicate-page')), findsOneWidget);
    expect(find.text('确认镜头'), findsOneWidget);
    expect(find.text('准备素材'), findsOneWidget);
    expect(find.text('合成提示词'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '人物拿起产品并看向镜头'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('replicate-next-assets')));
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const ValueKey('replicate-prepare-assets-step')),
      findsOneWidget,
    );
    expect(find.text('本任务提示词规则'), findsOneWidget);
    expect(find.text('人物'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(820, 700);
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('replicate-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
