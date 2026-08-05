import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
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

  test('点击生成后会立即把提交中的任务写入页面状态', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final frame = await File(
      '${fixture.root.path}/video-source.png',
    ).writeAsBytes([1, 2, 3]);
    final shot = fixture.shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      framePath: frame.path,
      durationSeconds: 2,
      prompt: '以图片1作为首帧，镜头缓慢推进。',
    );
    fixture.shootingController.updateShot(updatedShot);
    fixture.controller.value = fixture.controller.value.copyWith(
      shots: [updatedShot],
      drafts: {
        updatedShot.id: VideoGenerationDraft(
          id: 'draft-${updatedShot.id}',
          scriptId: updatedShot.scriptId,
          shotId: updatedShot.id,
          sourcePrompt: updatedShot.prompt,
          klingPrompt: updatedShot.prompt,
          promptMode: VideoPromptMode.klingOptimized,
          updatedAt: DateTime.now().toUtc(),
        ),
      },
      identity: const KlingIdentity(
        userId: 'user-1',
        imageToVideoModels: [
          KlingModelSpec(
            model: 'kling-video-v3_0_omni',
            alias: '可灵 o3',
            description: '',
            arguments: [
              KlingArgumentSpec(
                name: 'duration',
                required: false,
                defaultValue: '5',
                allowedValues: ['2', '3', '5'],
                description: '',
              ),
            ],
          ),
        ],
      ),
      account: const KlingAccount(
        userId: 'user-1',
        membershipType: 'pro',
        membershipDescription: '专业版',
        availableCredits: 88,
      ),
    );
    fixture.controller.selectModel('kling-video-v3_0_omni');
    final preparedShot = fixture.controller.value.shots.single;
    expect(fixture.controller.value.drafts[preparedShot.id], isNotNull);
    expect(fixture.controller.value.profile?.model, 'kling-video-v3_0_omni');
    expect(fixture.controller.sourceImageFileFor(preparedShot), isNotNull);
    expect(fixture.controller.canGenerateShot(preparedShot), isTrue);

    final generation = fixture.controller.generateShot(preparedShot);
    for (var attempt = 0; attempt < 20; attempt++) {
      if (fixture.controller.value.tasks.isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (var attempt = 0; attempt < 20; attempt++) {
      final tasks = fixture.controller.value.tasks;
      if (tasks.isNotEmpty &&
          tasks.single.status == VideoGenerationTaskStatus.submitting) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final activeTask = fixture.controller.value.tasks.single;
    expect(activeTask.shotId, updatedShot.id);
    expect(
      activeTask.status,
      isIn([
        VideoGenerationTaskStatus.submitting,
        VideoGenerationTaskStatus.queued,
      ]),
    );
    expect(activeTask.localPath, endsWith('.mp4'));
    expect(fixture.controller.value.isBusy, isFalse);
    expect(fixture.controller.value.isGeneratingAll, isFalse);

    fixture.fakeCli.completeQueryAsFailed();
    await generation;
  });

  test('单格连续生成时新任务先显示排队等待且不锁住页面', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    fixture.controller.value = fixture.controller.value.copyWith(
      identity: const KlingIdentity(
        userId: 'user-1',
        imageToVideoModels: [
          KlingModelSpec(
            model: 'kling-video-v3_0_omni',
            alias: '可灵 o3',
            description: '',
            arguments: [
              KlingArgumentSpec(
                name: 'duration',
                required: false,
                defaultValue: '5',
                allowedValues: ['2', '3', '5'],
                description: '',
              ),
            ],
          ),
        ],
      ),
      account: const KlingAccount(
        userId: 'user-1',
        membershipType: 'pro',
        membershipDescription: '专业版',
        availableCredits: 88,
      ),
    );
    fixture.controller.selectModel('kling-video-v3_0_omni');

    final firstFrame = await File(
      p.join(fixture.root.path, 'queue-first.png'),
    ).writeAsBytes([1, 2, 3]);
    final secondFrame = await File(
      p.join(fixture.root.path, 'queue-second.png'),
    ).writeAsBytes([4, 5, 6]);
    final addedFirst = fixture.shootingController.addShot()!;
    final firstShot = addedFirst.copyWith(
      framePath: firstFrame.path,
      durationSeconds: 2,
      prompt: '第一个排队生成镜头。',
    );
    fixture.shootingController.updateShot(firstShot);
    final addedSecond = fixture.shootingController.addShot()!;
    final secondShot = addedSecond.copyWith(
      framePath: secondFrame.path,
      durationSeconds: 2,
      prompt: '第二个排队生成镜头。',
    );
    fixture.shootingController.updateShot(secondShot);
    await Future<void>.delayed(Duration.zero);

    final firstGeneration = fixture.controller.generateShot(firstShot);
    await _waitUntil(
      () => fixture.controller.value.tasks.any(
        (task) =>
            task.shotId == firstShot.id &&
            (task.status == VideoGenerationTaskStatus.submitting ||
                task.status == VideoGenerationTaskStatus.queued),
      ),
    );

    final secondGeneration = fixture.controller.generateShot(secondShot);
    await _waitUntil(
      () => fixture.controller.value.tasks.any(
        (task) =>
            task.shotId == secondShot.id &&
            task.status == VideoGenerationTaskStatus.draft,
      ),
    );

    expect(fixture.controller.value.isBusy, isFalse);
    expect(fixture.controller.value.isGeneratingAll, isFalse);
    expect(
      fixture.controller.value.tasks
          .firstWhere((task) => task.shotId == secondShot.id)
          .localPath,
      endsWith('.mp4'),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await firstGeneration;
    await secondGeneration;
  });

  test('首尾帧模式视频生成只提交手动配对首帧并合计中间时长', () async {
    final root = await Directory.systemTemp.createTemp(
      'video-generation-start-end-',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    await settingsController.setVideoStartEndFrameModeEnabled(true);
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '手动首尾帧脚本');
    final frame1 = await File('${root.path}/frame-1.png').writeAsBytes([1]);
    final frame2 = await File('${root.path}/frame-2.png').writeAsBytes([2]);
    final frame3 = await File('${root.path}/frame-3.png').writeAsBytes([3]);
    final first = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(
        framePath: frame1.path,
        durationSeconds: 1,
        prompt: '镜头1提示词',
      ),
    );
    final middle = shootingController.addShot()!;
    shootingController.updateShot(
      middle.copyWith(
        framePath: frame2.path,
        durationSeconds: 2,
        prompt: '镜头2提示词',
      ),
    );
    final tail = shootingController.addShot()!;
    shootingController.updateShot(
      tail.copyWith(
        framePath: frame3.path,
        durationSeconds: 3,
        prompt: '镜头3提示词',
      ),
    );
    final replicateRepository = ReplicateRepository(database);
    final replicateController = ReplicateController(
      repository: replicateRepository,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    replicateController.selectStartFrame(first.id);
    replicateController.setTailFrame(tail.id);
    final firstReplica = await File(
      '${root.path}/replicated-first.png',
    ).writeAsBytes([11]);
    final tailReplica = await File(
      '${root.path}/replicated-tail.png',
    ).writeAsBytes([12]);
    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'replicated-${first.id}',
        runId: replicateController.value.run!.id,
        scriptShotId: first.id,
        shotNumber: first.shotNumber,
        originalFramePath: frame1.path,
        generatedFramePath: firstReplica.path,
        assetIds: const [],
        prompt: '',
        model: 'test',
        rawResponse: '',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    replicateController.refresh();
    final controller = VideoGenerationController(
      repository: VideoGenerationRepository(database),
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

    expect(controller.generationTargets().map((shot) => shot.id), [first.id]);
    expect(controller.canGenerateShot(middle), isFalse);
    expect(controller.desiredDurationFor(first), 6);
    final currentTail = controller.actionSequenceFor(first).tail;
    expect(currentTail.id, tail.id);
    expect(
      p.normalize(controller.sourceImageFileFor(first)?.path ?? ''),
      p.normalize(firstReplica.path),
    );
    expect(
      p.normalize(controller.sourceImageFileFor(currentTail)?.path ?? ''),
      p.normalize(frame3.path),
      reason: '尾帧未复刻时应回退原尾帧提交视频生成',
    );

    replicateRepository.upsertReplicatedShotImage(
      ReplicatedShotImage(
        id: 'replicated-${tail.id}',
        runId: replicateController.value.run!.id,
        scriptShotId: tail.id,
        shotNumber: tail.shotNumber,
        originalFramePath: frame3.path,
        generatedFramePath: tailReplica.path,
        assetIds: const [],
        prompt: '',
        model: 'test',
        rawResponse: '',
        status: ProcessingStatus.completed,
        errorMessage: '',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    replicateController.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(
      p.normalize(controller.sourceImageFileFor(currentTail)?.path ?? ''),
      p.normalize(tailReplica.path),
      reason: '尾帧完成复刻后应优先提交新的复刻尾帧',
    );
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

  test('本地 API 与可灵 CLI 来回切换时复用已登录可灵状态', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);

    final loginResult = await fixture.controller.startLoginAuthorization();
    expect(loginResult, KlingLoginAuthorizationStatus.completed);
    expect(fixture.fakeCli.startedCount, 1);
    expect(fixture.fakeCli.whoAmICount, 1);

    const apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local',
      name: 'MiniMax 本地',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: AppSettings.defaultVideoGenerationApiBaseUrl,
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.usesConfiguredVideoGenerationApi, isTrue);
    expect(fixture.controller.value.identity, isNull);
    expect(fixture.controller.value.account, isNull);

    await fixture.settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultKlingCliVideoGenerationConfigId,
    );
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.usesConfiguredVideoGenerationApi, isFalse);
    expect(fixture.controller.value.identity?.userId, 'user-1');
    expect(fixture.controller.value.account?.availableCredits, 88);
    expect(fixture.fakeCli.startedCount, 1);
    expect(fixture.fakeCli.whoAmICount, 1);
  });

  test('视频 API 初始化不会自动恢复历史超时任务并锁住生成入口', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    const apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local',
      name: 'MiniMax 本地',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: AppSettings.defaultVideoGenerationApiBaseUrl,
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    final shot = fixture.shootingController.addShot()!;
    final now = DateTime.now().toUtc();
    VideoGenerationRepository(fixture.database).upsertTask(
      VideoGenerationTask(
        id: 'timed-out-task',
        scriptId: shot.scriptId,
        shotId: shot.id,
        generationId: 'generation-timeout',
        model: AppSettings.defaultVideoGenerationModel,
        durationSeconds: 5,
        promptMode: VideoPromptMode.klingOptimized,
        prompt: '历史超时任务',
        status: VideoGenerationTaskStatus.timedOut,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await fixture.controller.initializeEnvironment();
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.usesConfiguredVideoGenerationApi, isTrue);
    expect(fixture.controller.value.isBusy, isFalse);
    expect(fixture.controller.value.message, '视频生成 API 已就绪');
  });

  test('视频 API 恢复查询遇到任务不存在会直接重新提交该镜头', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var missingQueryCount = 0;
    var retrySubmitCount = 0;
    var retryQueryCount = 0;
    server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/jobs/missing') {
        missingQueryCount++;
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'detail': '任务不存在'}));
        await request.response.close();
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/generate-upload') {
        retrySubmitCount++;
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'retry-job'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/jobs/retry-job') {
        retryQueryCount++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'completed',
              'content_url': '/outputs/retry.mp4',
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/outputs/retry.mp4') {
        request.response.add([7, 6, 5, 4]);
        await request.response.close();
        return;
      }
      request.response.statusCode = 500;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final frame = await File(
      p.join(fixture.root.path, 'retry-source.png'),
    ).writeAsBytes([1, 2, 3]);
    final shot = fixture.shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      framePath: frame.path,
      durationSeconds: 2,
      prompt: '以图片1作为首帧，镜头缓慢推进。',
    );
    fixture.shootingController.updateShot(updatedShot);
    await Future<void>.delayed(Duration.zero);

    final baseUrl = 'http://${server.address.host}:${server.port}';
    final apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-retry',
      name: 'MiniMax 本地',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: baseUrl,
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    final now = DateTime.now().toUtc();
    VideoGenerationRepository(fixture.database).upsertTask(
      VideoGenerationTask(
        id: 'stale-task',
        scriptId: updatedShot.scriptId,
        shotId: updatedShot.id,
        generationId: 'missing',
        model: AppSettings.defaultVideoGenerationModel,
        durationSeconds: 2,
        promptMode: VideoPromptMode.klingOptimized,
        prompt: '历史任务',
        status: VideoGenerationTaskStatus.running,
        localPath: p.join(fixture.root.path, 'stale.mp4'),
        createdAt: now,
        updatedAt: now,
      ),
    );

    await fixture.controller.initializeEnvironment();
    await _waitUntil(
      () =>
          fixture.controller.value.isBusy == false &&
          retrySubmitCount == 1 &&
          fixture.controller.value.tasks.any(
            (task) =>
                task.generationId == 'retry-job' &&
                task.status == VideoGenerationTaskStatus.completed,
          ),
    );

    expect(missingQueryCount, 1);
    expect(retrySubmitCount, 1);
    expect(retryQueryCount, 1);
    final stale = VideoGenerationRepository(
      fixture.database,
    ).getTask('stale-task');
    expect(stale?.status, VideoGenerationTaskStatus.failed);
    expect(
      VideoGenerationTaskService.shouldRetryMissingVideoApiTask(stale!),
      isTrue,
    );
    final retried = fixture.controller.value.tasks.firstWhere(
      (task) => task.generationId == 'retry-job',
    );
    expect(File(retried.localPath).readAsBytesSync(), [7, 6, 5, 4]);
  });

  test('本地视频 API 可选择生成比例、分辨率和步数', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    const apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local',
      name: 'MiniMax 本地',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: AppSettings.defaultVideoGenerationApiBaseUrl,
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.usesConfiguredVideoGenerationApi, isTrue);
    expect(fixture.controller.selectedVideoApiAspectRatio, '16:9');
    expect(
      fixture.controller.selectedVideoApiResolution,
      '0.2MP 16:9 - 608x352',
    );
    expect(fixture.controller.selectedVideoApiSteps, 12);

    fixture.controller.updateVideoApiAspectRatio('9:16');
    expect(fixture.controller.selectedVideoApiAspectRatio, '9:16');
    expect(
      fixture.controller.videoApiResolutionsForAspect('9:16'),
      contains('0.4MP 9:16 - 480x864'),
    );

    fixture.controller.updateVideoApiResolution('0.4MP 9:16 - 480x864');
    fixture.controller.updateVideoApiSteps(18);

    expect(fixture.controller.selectedVideoApiSubmissionParameters, {
      'resolution': '0.4MP 9:16 - 480x864',
      'steps': '18',
    });
    expect(fixture.controller.videoApiParameterSummary, contains('生成比例：9:16'));
    expect(
      fixture.controller.videoApiParameterSummary,
      contains('分辨率：0.4MP 9:16 - 480x864'),
    );
    expect(fixture.controller.videoApiParameterSummary, contains('步数：18'));
  });

  test('生成视频可另存为自定义路径并自动补齐 mp4 扩展名', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final source = await File(
      p.join(fixture.root.path, 'source-video.mp4'),
    ).writeAsBytes([1, 2, 3, 4]);
    final now = DateTime.now().toUtc();
    final targetWithoutExtension = p.join(fixture.root.path, 'exports', '镜头02');

    final saved = await fixture.controller.saveGeneratedVideoCopy(
      VideoGenerationTask(
        id: 'task-download',
        scriptId: fixture.shootingController.value.selectedScriptId,
        shotId: 'shot-download',
        generationId: 'generation-download',
        model: 'kling-video-v3_0_omni',
        durationSeconds: 5,
        promptMode: VideoPromptMode.klingOptimized,
        prompt: '保存测试',
        status: VideoGenerationTaskStatus.completed,
        localPath: source.path,
        createdAt: now,
        updatedAt: now,
      ),
      targetWithoutExtension,
    );

    expect(saved?.path, '$targetWithoutExtension.mp4');
    expect(await saved!.readAsBytes(), [1, 2, 3, 4]);
    expect(fixture.controller.value.message, contains('视频已保存到'));
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

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待条件超时');
}

class _FakeKlingCliService extends KlingCliService {
  _FakeKlingCliService({this.succeedAfterAttempts});

  final int? succeedAfterAttempts;
  int startedCount = 0;
  int killedCount = 0;
  int whoAmICount = 0;
  final List<Completer<int>> _exitCompleters = [];
  Completer<KlingTaskResult>? _queryCompleter;

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

  @override
  Future<KlingSubmissionResult> submitImageToVideo({
    required String model,
    required String imagePath,
    String tailImagePath = '',
    required Map<String, String> parameters,
    required String prompt,
  }) async {
    _queryCompleter ??= Completer<KlingTaskResult>();
    return const KlingSubmissionResult(
      generationId: 'fake-generation-1',
      rawJson: {'ok': true},
    );
  }

  @override
  Future<KlingTaskResult> queryTask(String generationId) {
    _queryCompleter ??= Completer<KlingTaskResult>();
    return _queryCompleter!.future;
  }

  void completeQueryAsFailed() {
    final completer = _queryCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        const KlingTaskResult(
          generationId: 'fake-generation-1',
          status: VideoGenerationTaskStatus.failed,
          url: '',
          urlWithoutWatermark: '',
          errorMessage: '测试结束',
          rawJson: {'ok': false},
        ),
      );
    }
  }
}
