import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/app/app_shell.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/onboarding/data/onboarding_repository.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/updater/application/updater_controller.dart';
import 'package:filmstoryboard/features/updater/data/updater_service.dart';
import 'package:filmstoryboard/features/updater/domain/app_update_config.dart';

void main() {
  testWidgets('旧裁切页签索引会迁移到视频解析', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('app_shell_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      database
        ..setSetting('appShellSelectedTabIndex', '0')
        ..setSetting('updateReleaseApiUrl', '');
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final updaterController = _NoopUpdaterController(
      settingsController: settingsController,
      settingsRepository: repository,
      directories: directories,
    );
    addTearDown(() async {
      updaterController.dispose();
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
          updaterControllerProvider.overrideWithValue(updaterController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const AppShell(enableWindowControls: false),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('设计分镜图'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-analysis-page')), findsOneWidget);
    expect(find.text('多宫格裁切'), findsNothing);
    expect(find.byKey(const ValueKey('app-shell-bottom-tabs')), findsOneWidget);
    final bottomTabsCenter = tester.getCenter(
      find.byKey(const ValueKey('app-shell-bottom-tabs')),
    );
    final logicalWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(bottomTabsCenter.dx, closeTo(logicalWidth / 2, 0.5));
    expect(database.getSetting('appShellSelectedTabIndex'), '1');
    expect(database.getSetting('appShellSelectedTabIndexVersion'), '4');
    expect(find.byKey(const ValueKey('app-shell-tab-一键复刻')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('app-shell-tab-拍摄脚本')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shooting-script-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('create-empty-shooting-script')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('create-empty-shooting-script')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '合并流程脚本');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shooting-script-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shooting-script-workflow')),
      findsOneWidget,
    );
    expect(find.text('确认镜头'), findsOneWidget);
    expect(find.text('准备资产'), findsOneWidget);
    expect(find.text('合成提示词'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('start-replicate-from-shooting-script')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('shooting-script-left-resize-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('shooting-script-right-resize-handle')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('collapse-script-sidebar')));
    await tester.pump();
    expect(find.byKey(const ValueKey('expand-script-sidebar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('expand-script-sidebar')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('collapse-asset-library-panel')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('expand-asset-library-panel')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('app-shell-tab-设置')));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(database.getSetting('appShellSelectedTabIndex'), '5');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('工程入口会并入底部统一导航并可触发返回首页', (tester) async {
    var closeInvoked = false;
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('app_shell_project_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      database.setSetting('updateReleaseApiUrl', '');
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final updaterController = _NoopUpdaterController(
      settingsController: settingsController,
      settingsRepository: repository,
      directories: directories,
    );
    addTearDown(() async {
      updaterController.dispose();
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
          updaterControllerProvider.overrideWithValue(updaterController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: AppShell(
            enableWindowControls: false,
            projectName: '测试工程',
            onCloseProject: () async {
              closeInvoked = true;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('查看使用教程'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-help-action')),
      findsOneWidget,
    );

    expect(find.byKey(const ValueKey('app-shell-bottom-tabs')), findsOneWidget);
    expect(find.text('测试工程'), findsOneWidget);
    expect(find.text('${AppUpdateConfig.windowTitle} — 测试工程'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-project-to-home')), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('close-project-to-home')))
          .height,
      40,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('app-shell-tab-设计分镜图'))).height,
      40,
    );

    await tester.tap(find.byKey(const ValueKey('close-project-to-home')));
    await tester.pump();

    expect(closeInvoked, isTrue);

    await settingsController.setNavigationPosition(AppNavigationPosition.left);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-shell-left-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-shell-bottom-tabs')), findsNothing);
    expect(database.getSetting('navigationPosition'), 'left');
    expect(find.byKey(const ValueKey('app-shell-tab-视频解析')), findsOneWidget);

    await settingsController.setNavigationPosition(
      AppNavigationPosition.bottom,
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(720, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('app-shell-bottom-tabs')), findsOneWidget);
  });

  testWidgets('首次进入工程显示引导且重播不会污染页面记忆', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('app_shell_onboarding_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      OnboardingRepository.initializeInstallation(
        database: database,
        isFreshInstall: true,
      );
      database.setSetting('updateReleaseApiUrl', '');
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final updaterController = _NoopUpdaterController(
      settingsController: settingsController,
      settingsRepository: repository,
      directories: directories,
    );
    addTearDown(() async {
      updaterController.dispose();
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
          updaterControllerProvider.overrideWithValue(updaterController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const AppShell(enableWindowControls: false, initialTabIndex: 3),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('onboarding-overlay')), findsOneWidget);
    expect(find.text('从参考视频，到可执行的复刻方案'), findsOneWidget);
    expect(database.getSetting('appShellSelectedTabIndex'), isNull);

    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump(const Duration(milliseconds: 240));
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.text('把参考视频拆成可追溯镜头'), findsOneWidget);
    expect(database.getSetting('appShellSelectedTabIndex'), isNull);

    await tester.tap(find.byKey(const ValueKey('onboarding-skip')));
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byKey(const ValueKey('onboarding-overlay')), findsNothing);
    expect(
      database.getSetting(OnboardingRepository.completedVersionKey),
      '${OnboardingRepository.currentVersion}',
    );

    await tester.tap(find.byKey(const ValueKey('app-shell-tab-导出')));
    await tester.pump(const Duration(milliseconds: 240));
    expect(database.getSetting('appShellSelectedTabIndex'), '4');

    await tester.tap(find.byKey(const ValueKey('show-onboarding-help')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump(const Duration(milliseconds: 240));
    expect(database.getSetting('appShellSelectedTabIndex'), '4');

    await tester.tap(find.byKey(const ValueKey('onboarding-skip')));
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byKey(const ValueKey('onboarding-overlay')), findsNothing);
    expect(database.getSetting('appShellSelectedTabIndex'), '4');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧工程启动时提醒并一次归纳 AI 修改与手动替换图片', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final Directory root;
    late final AppDirectories directories;
    late final AppDatabase database;
    late final StoryboardController storyboardController;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('app_shell_normalize_');
      directories = await AppDirectories.create(executableDirectory: root);
      database = await AppDatabase.open(directories.databaseFile);
      OnboardingRepository(database).markCompleted();
      database.setSetting('updateReleaseApiUrl', '');
      storyboardController = StoryboardController(
        database: database,
        directories: directories,
      );
      final boardId = storyboardController.value.selectedBoard!.id;
      await _registerLegacyReplacement(
        database: database,
        directories: directories,
        boardId: boardId,
        aiEdited: true,
      );
      await _registerLegacyReplacement(
        database: database,
        directories: directories,
        boardId: boardId,
        aiEdited: false,
      );
      await storyboardController.refreshAssets();
    });
    final repository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: repository,
      initialSettings: repository.load(),
    );
    final updaterController = _NoopUpdaterController(
      settingsController: settingsController,
      settingsRepository: repository,
      directories: directories,
    );
    addTearDown(() async {
      updaterController.dispose();
      storyboardController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          globalDatabaseProvider.overrideWithValue(database),
          appDirectoriesProvider.overrideWithValue(directories),
          appDatabaseProvider.overrideWithValue(database),
          settingsRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWithValue(settingsController),
          storyboardControllerProvider.overrideWithValue(storyboardController),
          updaterControllerProvider.overrideWithValue(updaterController),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: const AppShell(enableWindowControls: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('legacy-asset-normalization-dialog')),
      findsOneWidget,
    );
    expect(find.text('AI 修改：1 张'), findsOneWidget);
    expect(find.text('手动替换：1 张'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('legacy-asset-normalization-now')),
    );
    await tester.pump();
    for (var attempt = 0; attempt < 500; attempt++) {
      if (!storyboardController.value.isNormalizingAssets) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
    expect(
      storyboardController.value.isNormalizingAssets,
      isFalse,
      reason: '归纳操作应在 5 秒内完成，不能让启动弹窗永久阻塞',
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byKey(const ValueKey('legacy-asset-normalization-dialog')),
      findsNothing,
    );
    expect(storyboardController.value.assetNormalizationRequired, isFalse);
    expect(database.getSetting('storyboardAssetNormalizationVersion'), '1');
    expect(database.listCutResults().map((record) => record.imageId).toSet(), {
      'storyboard-ai-edited-images',
      'storyboard-manual-replacement-images',
    });
    expect(
      Directory(
        p.join(directories.generatedImages.path, '画板 1-AI修改'),
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        p.join(directories.generatedImages.path, '画板 1-手动替换'),
      ).existsSync(),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _registerLegacyReplacement({
  required AppDatabase database,
  required AppDirectories directories,
  required String boardId,
  required bool aiEdited,
}) async {
  final kind = aiEdited ? 'ai' : 'manual';
  final directory = aiEdited
      ? Directory(p.join(directories.generatedImages.path, boardId))
      : Directory(
          p.join(
            directories.generatedImages.path,
            boardId,
            'manual_replacements',
          ),
        );
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, '$kind-old.png'));
  await file.writeAsBytes(img.encodePng(img.Image(width: 4, height: 4)));
  final imageId = 'legacy-$kind-image';
  final taskId = 'legacy-$kind-task';
  final resultId = aiEdited
      ? 'generated-cut-legacy-shell'
      : 'replacement-cut-legacy-shell';
  final now = DateTime.now().toIso8601String();
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: file.path,
      originalName: aiEdited ? 'AI修改_旧图.png' : '手动替换_旧图.png',
      storedPath: file.path,
      width: 4,
      height: 4,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: aiEdited ? 'generated' : 'manual-replacement',
      rows: 1,
      columns: 1,
      confidence: 1,
    )
    ..insertCutResult(
      id: resultId,
      taskId: taskId,
      imageId: imageId,
      indexNo: 1,
      path: file.path,
      x: 0,
      y: 0,
      width: 4,
      height: 4,
      selected: true,
    );
}

class _NoopUpdaterController extends UpdaterController {
  _NoopUpdaterController({
    required super.settingsController,
    required super.settingsRepository,
    required AppDirectories directories,
  }) : super(
         service: UpdaterService(directories: directories),
         exitApplication: (_) {},
       );

  @override
  Future<void> beginStartupFlow() async {}
}
