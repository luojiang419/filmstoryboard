import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/onboarding/application/onboarding_controller.dart';
import 'package:filmstoryboard/features/onboarding/data/onboarding_repository.dart';
import 'package:filmstoryboard/features/onboarding/domain/onboarding_step.dart';

void main() {
  late Directory root;
  late AppDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('onboarding_');
    database = await AppDatabase.open(File(p.join(root.path, 'app.sqlite')));
  });

  tearDown(() async {
    database.dispose();
    await root.delete(recursive: true);
  });

  test('全新安装标记为待引导且初始化不会覆盖已有状态', () {
    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: true,
    );
    final repository = OnboardingRepository(database);

    expect(repository.isFirstRunPending, isTrue);
    expect(repository.completedVersion, OnboardingRepository.pendingVersion);

    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: false,
    );
    expect(repository.completedVersion, OnboardingRepository.pendingVersion);
  });

  test('已有数据库升级时默认完成引导以免打扰老用户', () {
    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: false,
    );
    final repository = OnboardingRepository(database);

    expect(repository.isFirstRunPending, isFalse);
    expect(repository.completedVersion, OnboardingRepository.currentVersion);
  });

  test('自动引导遍历全部步骤并在完成后回到设计页', () {
    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: true,
    );
    final repository = OnboardingRepository(database);
    final controller = OnboardingController(repository: repository);
    addTearDown(controller.dispose);

    expect(controller.shouldStartAutomatically, isTrue);
    controller.start(originTabIndex: 3, automatic: true);
    expect(controller.visible, isTrue);
    expect(controller.currentStep, onboardingSteps.first);

    for (var index = 1; index < onboardingSteps.length; index += 1) {
      controller.next();
      expect(controller.stepIndex, index);
      expect(controller.currentStep, onboardingSteps[index]);
    }
    controller.next();

    expect(controller.visible, isFalse);
    expect(controller.takeExitTabIndex(), 0);
    expect(controller.takeExitTabIndex(), isNull);
    expect(controller.shouldStartAutomatically, isFalse);
    expect(repository.completedVersion, OnboardingRepository.currentVersion);
  });

  test('手动重新播放后跳过会恢复播放前页面', () {
    OnboardingRepository.initializeInstallation(
      database: database,
      isFreshInstall: false,
    );
    final controller = OnboardingController(
      repository: OnboardingRepository(database),
    );
    addTearDown(controller.dispose);

    controller.start(originTabIndex: 3);
    controller.next();
    controller.next();
    controller.previous();
    expect(controller.stepIndex, 1);

    controller.skip();
    expect(controller.visible, isFalse);
    expect(controller.takeExitTabIndex(), 3);
  });
}
