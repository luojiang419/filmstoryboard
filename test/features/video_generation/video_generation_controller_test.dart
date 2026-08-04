import 'dart:async';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('模型清单到达后自动选择可灵 o3，并使用 16:9、1080p', () async {
    final root = await Directory.systemTemp.createTemp(
      'video-generation-controller-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '默认参数测试');
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final repository = VideoGenerationRepository(database);
    final controller = VideoGenerationController(
      repository: repository,
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    addTearDown(() async {
      controller.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    controller.value = controller.value.copyWith(
      identity: const KlingIdentity(
        userId: 'test-user',
        imageToVideoModels: [
          KlingModelSpec(
            model: 'kling-video-v2_6',
            alias: '可灵2.6',
            description: '普通图生视频模型',
            arguments: [],
          ),
          KlingModelSpec(
            model: 'kling-video-v3_0_omni',
            alias: 'kling3.0-omni, 可灵o3, video-o3',
            description: '全能视频模型',
            arguments: [
              KlingArgumentSpec(
                name: 'prompt',
                required: true,
                defaultValue: '',
                allowedValues: [],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'duration',
                required: false,
                defaultValue: '5',
                allowedValues: ['3', '5', '10'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'aspect_ratio',
                required: false,
                defaultValue: '9:16',
                allowedValues: ['16:9', '9:16', '1:1'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'resolution',
                required: false,
                defaultValue: '4k',
                allowedValues: ['720p', '1080p', '4k'],
                description: '',
              ),
            ],
          ),
        ],
      ),
    );

    shootingController.addShot();

    expect(controller.value.profile?.model, 'kling-video-v3_0_omni');
    expect(controller.value.profile?.parameters['aspect_ratio'], '16:9');
    expect(controller.value.profile?.parameters['resolution'], '1080p');
    expect(
      repository.getProfile(controller.value.selectedScriptId)?.parameters,
      containsPair('resolution', '1080p'),
    );
  });

  test('没有复刻分镜图时使用脚本镜头原图作为视频生成首帧', () async {
    final root = await Directory.systemTemp.createTemp(
      'video-generation-source-image-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '自建故事脚本');
    final frame = await File(
      '${root.path}/manual-frame.png',
    ).writeAsBytes([1, 2, 3]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(
        framePath: frame.path,
        content: '女模特在厨房展示产品',
        shotSize: '中景',
        cameraMovement: '缓慢推进',
        prompt: '以图片1作为首帧，女模特自然展示产品。',
      ),
    );
    final replicateController = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    final repository = VideoGenerationRepository(database);
    final controller = VideoGenerationController(
      repository: repository,
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: shootingController,
      replicateController: replicateController,
      directories: directories,
      settingsController: settingsController,
    );
    addTearDown(() async {
      controller.dispose();
      replicateController.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final currentShot = controller.value.shots.single;

    expect(controller.replicatedImageFor(currentShot.id), isNull);
    expect(
      p.normalize(controller.sourceImageFileFor(currentShot)?.path ?? ''),
      p.normalize(frame.path),
    );
    expect(controller.canGenerateShot(currentShot), isTrue);
    expect(controller.generationTargets().map((item) => item.id), [
      currentShot.id,
    ]);
  });

  test('可灵授权等待以 whoAmI 成功作为真实登录完成信号', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 2),
    );
    addTearDown(fixture.dispose);

    final result = await fixture.controller.startLoginAuthorization();

    expect(result, KlingLoginAuthorizationStatus.completed);
    expect(fixture.fakeCli.startedCount, 1);
    expect(fixture.controller.value.identity?.userId, 'user-1');
    expect(fixture.controller.value.account?.availableCredits, 88);
    expect(
      fixture.controller.value.loginAuthorizationStatus,
      KlingLoginAuthorizationStatus.completed,
    );
  });

  test('取消可灵授权会停止等待并终止登录进程', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(),
    );
    addTearDown(fixture.dispose);

    final authorization = fixture.controller.startLoginAuthorization();
    await Future<void>.delayed(Duration.zero);
    fixture.controller.cancelLoginAuthorization();
    final result = await authorization;

    expect(result, KlingLoginAuthorizationStatus.canceled);
    expect(fixture.fakeCli.killedCount, 1);
    expect(
      fixture.controller.value.loginAuthorizationStatus,
      KlingLoginAuthorizationStatus.canceled,
    );
  });

  test('拉起浏览器后未完成授权会超时而不是卡住', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(),
      loginAuthorizationTimeout: const Duration(milliseconds: 20),
      loginAuthorizationPollInterval: const Duration(milliseconds: 2),
    );
    addTearDown(fixture.dispose);

    final result = await fixture.controller.startLoginAuthorization();

    expect(result, KlingLoginAuthorizationStatus.timedOut);
    expect(fixture.fakeCli.startedCount, 1);
    expect(fixture.fakeCli.killedCount, 1);
    expect(fixture.controller.value.identity, isNull);
    expect(fixture.controller.value.errorMessage, contains('未检测到可灵授权完成'));
  });
}

Future<_ControllerFixture> _createControllerFixture({
  required _FakeKlingCliService cliService,
  Duration loginAuthorizationTimeout = const Duration(seconds: 1),
  Duration loginAuthorizationPollInterval = const Duration(milliseconds: 1),
}) async {
  final root = await Directory.systemTemp.createTemp('video-generation-login-');
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final settingsRepository = SettingsRepository(database, directories);
  final settingsController = SettingsController(
    repository: settingsRepository,
    initialSettings: settingsRepository.load(),
  );
  final shootingController = ShootingScriptController(
    repository: ShootingScriptRepository(database),
    directories: directories,
  )..createEmpty(name: '可灵登录测试');
  final replicateController = ReplicateController(
    repository: ReplicateRepository(database),
    shootingScriptController: shootingController,
    directories: directories,
    settingsController: settingsController,
  );
  final controller = VideoGenerationController(
    repository: VideoGenerationRepository(database),
    videoRepository: VideoAnalysisRepository(database),
    shootingScriptController: shootingController,
    replicateController: replicateController,
    directories: directories,
    settingsController: settingsController,
    cliService: cliService,
    loginAuthorizationTimeout: loginAuthorizationTimeout,
    loginAuthorizationPollInterval: loginAuthorizationPollInterval,
  );
  controller.value = controller.value.copyWith(
    environment: const KlingCliEnvironment(
      nodePath: r'C:\tools\node.exe',
      nodeVersion: 'v20.0.0',
      npmPath: r'C:\tools\npm.cmd',
      klingPath: r'C:\tools\kling.cmd',
      klingVersion: 'kling-cli 0.1.3',
      errorMessage: '',
    ),
  );
  return _ControllerFixture(
    root: root,
    database: database,
    settingsController: settingsController,
    shootingController: shootingController,
    replicateController: replicateController,
    controller: controller,
    fakeCli: cliService,
  );
}

class _ControllerFixture {
  const _ControllerFixture({
    required this.root,
    required this.database,
    required this.settingsController,
    required this.shootingController,
    required this.replicateController,
    required this.controller,
    required this.fakeCli,
  });

  final Directory root;
  final AppDatabase database;
  final SettingsController settingsController;
  final ShootingScriptController shootingController;
  final ReplicateController replicateController;
  final VideoGenerationController controller;
  final _FakeKlingCliService fakeCli;

  Future<void> dispose() async {
    controller.dispose();
    replicateController.dispose();
    shootingController.dispose();
    settingsController.dispose();
    database.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

class _FakeKlingCliService extends KlingCliService {
  _FakeKlingCliService({this.succeedAfterAttempts});

  final int? succeedAfterAttempts;
  int startedCount = 0;
  int killedCount = 0;
  int whoAmICount = 0;
  final List<Completer<int>> _exitCompleters = [];

  @override
  Future<KlingLoginProcess> startLogin() async {
    startedCount++;
    final exitCompleter = Completer<int>();
    _exitCompleters.add(exitCompleter);
    return KlingLoginProcess(
      exitCode: exitCompleter.future,
      kill: ([signal = ProcessSignal.sigterm]) {
        killedCount++;
        if (!exitCompleter.isCompleted) exitCompleter.complete(-1);
        return true;
      },
      stderr: () => 'login canceled',
    );
  }

  @override
  Future<KlingIdentity> whoAmI() async {
    whoAmICount++;
    final threshold = succeedAfterAttempts;
    if (threshold == null || whoAmICount < threshold) {
      throw const KlingCliException('未登录');
    }
    return const KlingIdentity(
      userId: 'user-1',
      imageToVideoModels: [
        KlingModelSpec(
          model: 'kling-video-v3_0_omni',
          alias: '可灵 o3',
          description: '',
          arguments: [],
        ),
      ],
    );
  }

  @override
  Future<KlingAccount> account() async => const KlingAccount(
    userId: 'user-1',
    membershipType: 'pro',
    membershipDescription: '专业版',
    availableCredits: 88,
  );
}
