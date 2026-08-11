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
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/cli_dependency_installer.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/minimax_video_api_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  test('没有复刻分镜图时使用视频帧图作为视频生成参考图', () async {
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
    expect(
      p.normalize(
        controller.generationReferenceImageFileFor(currentShot)?.path ?? '',
      ),
      p.normalize(frame.path),
    );
    expect(controller.canGenerateShot(currentShot), isTrue);
    expect(controller.generationTargets().map((item) => item.id), [
      currentShot.id,
    ]);
  });

  test('存在复刻分镜图时提交视频生成必须优先使用复刻图', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final frame = await File(
      '${fixture.root.path}/source-frame.png',
    ).writeAsBytes([1, 2, 3]);
    final replicated = await File(
      '${fixture.root.path}/replicated-frame.png',
    ).writeAsBytes([4, 5, 6]);
    final shot = fixture.shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      framePath: frame.path,
      durationSeconds: 2,
      prompt: '以复刻分镜图作为参考，人物向镜头走来。',
    );
    fixture.shootingController.updateShot(updatedShot);
    await Future<void>.delayed(Duration.zero);
    final currentShot = fixture.controller.value.shots.single;
    fixture.controller.value = fixture.controller.value.copyWith(
      replicatedImages: [
        ReplicatedShotImage(
          id: 'replicated-${currentShot.id}',
          runId: 'run-1',
          scriptShotId: currentShot.id,
          shotNumber: currentShot.shotNumber,
          originalFramePath: frame.path,
          generatedFramePath: replicated.path,
          assetIds: const [],
          prompt: '',
          model: 'test',
          rawResponse: '',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      ],
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

    expect(
      p.normalize(
        fixture.controller.generationReferenceImageFileFor(currentShot)?.path ??
            '',
      ),
      p.normalize(replicated.path),
    );

    final generation = fixture.controller.generateShot(currentShot);
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.isNotEmpty);

    expect(
      p.normalize(fixture.fakeCli.submittedImagePaths.single),
      p.normalize(replicated.path),
    );
    expect(
      p.normalize(fixture.fakeCli.submittedImagePaths.single),
      isNot(p.normalize(frame.path)),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await generation;
  });

  test('可灵 CLI 提交时会追加已确认资产图并写入图片编号说明', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final frame = await File(
      '${fixture.root.path}/asset-source.png',
    ).writeAsBytes([1, 2, 3]);
    final heroAsset = await File(
      '${fixture.root.path}/hero-asset.png',
    ).writeAsBytes([4, 5, 6]);
    final shot = fixture.shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      framePath: frame.path,
      durationSeconds: 3,
      prompt: '以图片1作为首帧和主体外观参考；主体与动作：女主角抬头看向镜头。',
    );
    fixture.shootingController.updateShot(updatedShot);
    final workflowRepository = ShootingScriptWorkflowRepository(
      fixture.database,
    );
    final now = DateTime.now().toUtc();
    workflowRepository.upsertScriptAsset(
      ScriptAsset(
        id: 'script-asset-hero',
        scriptId: updatedShot.scriptId,
        type: ReplicateAssetType.character,
        name: '女主角',
        description: '红色外套，短发，银色耳环',
        path: heroAsset.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    workflowRepository.upsertLink(
      ScriptShotAssetLink(
        shotId: updatedShot.id,
        scriptAssetId: 'script-asset-hero',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '手动确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    fixture.controller.value = fixture.controller.value.copyWith(
      shots: [updatedShot],
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
                allowedValues: ['3', '5'],
                description: '',
              ),
            ],
            inputs: [
              KlingInputSpec(name: 'image_1', required: true, description: ''),
              KlingInputSpec(name: 'image_2', required: false, description: ''),
              KlingInputSpec(name: 'image_3', required: false, description: ''),
              KlingInputSpec(name: 'image_4', required: false, description: ''),
              KlingInputSpec(name: 'image_5', required: false, description: ''),
              KlingInputSpec(name: 'image_6', required: false, description: ''),
              KlingInputSpec(name: 'image_7', required: false, description: ''),
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
    await Future<void>.delayed(Duration.zero);
    final preparedShot = fixture.controller.value.shots.single;

    final generation = fixture.controller.generateShot(preparedShot);
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.isNotEmpty);

    expect(
      p.normalize(fixture.fakeCli.submittedImagePaths.single),
      p.normalize(frame.path),
    );
    expect(
      fixture.fakeCli.submittedReferenceImagePaths.single
          .map(p.normalize)
          .toList(),
      [p.normalize(heroAsset.path)],
    );
    expect(fixture.fakeCli.submittedPrompts.single, contains('图片2为角色参考（女主角）'));
    expect(fixture.fakeCli.submittedPrompts.single, isNot(contains('红色外套')));
    expect(
      fixture.fakeCli.submittedPrompts.single,
      isNot(contains('严格保持这些资产')),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await generation;
  });

  test('可灵 CLI 按确认页手动镜头组追加原视频中间帧和资产图', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final firstFrame = await File(
      p.join(fixture.root.path, 'kling-group-first-frame.png'),
    ).writeAsBytes([1]);
    final middleFrame = await File(
      p.join(fixture.root.path, 'kling-group-middle-frame.png'),
    ).writeAsBytes([2]);
    final tailFrame = await File(
      p.join(fixture.root.path, 'kling-group-tail-frame.png'),
    ).writeAsBytes([3]);
    final assetFile = await File(
      p.join(fixture.root.path, 'kling-group-asset.png'),
    ).writeAsBytes([21]);

    final first = fixture.shootingController.addShot()!;
    final middle = fixture.shootingController.addShot()!;
    final tail = fixture.shootingController.addShot()!;
    final updatedFirst = first.copyWith(
      framePath: firstFrame.path,
      durationSeconds: 2,
      content: '人物从门口走入',
      prompt: '以图片1作为首帧和主体外观参考，从图片1自然过渡到图片2。',
    );
    final updatedMiddle = middle.copyWith(
      framePath: middleFrame.path,
      durationSeconds: 2,
      content: '人物抬手展示产品',
      actionStage: '中间动作',
    );
    final updatedTail = tail.copyWith(
      framePath: tailFrame.path,
      durationSeconds: 2,
      content: '人物完成展示',
    );
    fixture.shootingController.updateShot(updatedFirst);
    fixture.shootingController.updateShot(updatedMiddle);
    fixture.shootingController.updateShot(updatedTail);
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.shootingController.setContinuousShotRange(
        startShotId: first.id,
        endShotId: tail.id,
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    final now = DateTime.now().toUtc();
    final workflowRepository = ShootingScriptWorkflowRepository(
      fixture.database,
    );
    workflowRepository.upsertScriptAsset(
      ScriptAsset(
        id: 'kling-group-character',
        scriptId: updatedFirst.scriptId,
        type: ReplicateAssetType.character,
        name: '女主角',
        description: '黑色长发，白色衬衫',
        path: assetFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    workflowRepository.upsertLink(
      ScriptShotAssetLink(
        shotId: updatedMiddle.id,
        scriptAssetId: 'kling-group-character',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '手动确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    fixture.replicateController.refresh();
    await Future<void>.delayed(Duration.zero);

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
                allowedValues: ['5', '10'],
                description: '',
              ),
            ],
            inputs: [
              KlingInputSpec(name: 'image_1', required: true, description: ''),
              KlingInputSpec(name: 'image_2', required: false, description: ''),
              KlingInputSpec(name: 'image_3', required: false, description: ''),
              KlingInputSpec(name: 'image_4', required: false, description: ''),
              KlingInputSpec(name: 'image_5', required: false, description: ''),
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

    final generation = fixture.controller.generateShot(updatedFirst);
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.isNotEmpty);

    expect(
      p.normalize(fixture.fakeCli.submittedImagePaths.single),
      p.normalize(firstFrame.path),
    );
    expect(
      fixture.fakeCli.submittedReferenceImagePaths.single
          .map(p.normalize)
          .toList(),
      [
        p.normalize(middleFrame.path),
        p.normalize(tailFrame.path),
        p.normalize(assetFile.path),
      ],
    );
    expect(
      fixture.fakeCli.submittedPrompts.single,
      contains('图片1至图片3为同一连续动作的顺序参考'),
    );
    expect(fixture.fakeCli.submittedPrompts.single, isNot(contains('镜头2组内')));
    expect(fixture.fakeCli.submittedPrompts.single, isNot(contains('镜头3组内')));
    expect(fixture.fakeCli.submittedPrompts.single, contains('图片4为角色参考（女主角）'));
    expect(
      fixture.fakeCli.submittedPrompts.single,
      isNot(contains('尾帧和动作结果参考')),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await generation;
  });

  test('可灵 CLI 提交时不会携带本地视频 API 私有参数', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final frame = await File(
      '${fixture.root.path}/kling-parameter-source.png',
    ).writeAsBytes([1, 2, 3]);
    final shot = fixture.shootingController.addShot()!;
    fixture.shootingController.updateShot(
      shot.copyWith(
        framePath: frame.path,
        durationSeconds: 5,
        prompt: '以图片1作为首帧和主体外观参考，镜头缓慢推进。',
      ),
    );
    await Future<void>.delayed(Duration.zero);
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
                allowedValues: ['5'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'aspect_ratio',
                required: false,
                defaultValue: '16:9',
                allowedValues: ['16:9'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'resolution',
                required: false,
                defaultValue: '1080p',
                allowedValues: ['1080p'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'imageCount',
                required: false,
                defaultValue: '1',
                allowedValues: ['1'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'prefer_multi_shots',
                required: false,
                defaultValue: 'false',
                allowedValues: ['true', 'false'],
                description: '',
              ),
              KlingArgumentSpec(
                name: 'enable_audio',
                required: false,
                defaultValue: 'false',
                allowedValues: ['true', 'false'],
                description: '',
              ),
            ],
            inputs: [
              KlingInputSpec(name: 'image_1', required: true, description: ''),
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
    fixture.controller.updateParameter('prefer_multi_shots', 'true');
    fixture.controller.updateParameter('enable_audio', 'true');
    fixture.controller.updateParameter('minimax_api_aspect_ratio', '16:9');
    fixture.controller.updateParameter(
      'minimax_api_resolution',
      '0.3MP 16:9 - 736x416',
    );
    fixture.controller.updateParameter('minimax_api_steps', '15');
    final preparedShot = fixture.controller.value.shots.single;

    final generation = fixture.controller.generateShot(preparedShot);
    await _waitUntil(() => fixture.fakeCli.submittedParameters.isNotEmpty);

    expect(fixture.fakeCli.submittedParameters.single, {
      'aspect_ratio': '16:9',
      'resolution': '1080p',
      'imageCount': '1',
      'prefer_multi_shots': 'true',
      'enable_audio': 'true',
      'duration': '5',
    });

    fixture.fakeCli.completeQueryAsFailed();
    await generation;
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
          h3Prompt: '【画面过程描述】0-2秒：镜头缓慢推进。',
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

  test('不同镜头单格生成会立即并发提交且不锁住页面', () async {
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
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.length == 2);

    expect(fixture.controller.value.isBusy, isFalse);
    expect(fixture.controller.value.isGeneratingAll, isFalse);
    expect(
      fixture.controller.value.tasks
          .firstWhere((task) => task.shotId == secondShot.id)
          .localPath,
      endsWith('.mp4'),
    );
    expect(
      fixture.controller.value.tasks
          .firstWhere((task) => task.shotId == secondShot.id)
          .status,
      isIn([
        VideoGenerationTaskStatus.submitting,
        VideoGenerationTaskStatus.queued,
      ]),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await firstGeneration;
    await secondGeneration;
  });

  test('一键生成遇到已运行镜头时只立即提交其他镜头', () async {
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
      p.join(fixture.root.path, 'batch-active-first.png'),
    ).writeAsBytes([1, 2, 3]);
    final secondFrame = await File(
      p.join(fixture.root.path, 'batch-active-second.png'),
    ).writeAsBytes([4, 5, 6]);
    final firstShot = fixture.shootingController.addShot()!.copyWith(
      framePath: firstFrame.path,
      durationSeconds: 2,
      prompt: '已经在生成的镜头。',
    );
    fixture.shootingController.updateShot(firstShot);
    final secondShot = fixture.shootingController.addShot()!.copyWith(
      framePath: secondFrame.path,
      durationSeconds: 2,
      prompt: '应由一键生成立即提交的镜头。',
    );
    fixture.shootingController.updateShot(secondShot);
    await Future<void>.delayed(Duration.zero);

    final firstGeneration = fixture.controller.generateShot(firstShot);
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.length == 1);

    final batchGeneration = fixture.controller.generateAll();
    await _waitUntil(() => fixture.fakeCli.submittedImagePaths.length == 2);

    expect(
      fixture.fakeCli.submittedImagePaths.where(
        (path) => p.normalize(path) == p.normalize(firstFrame.path),
      ),
      hasLength(1),
      reason: '一键生成不得重复提交已运行镜头',
    );
    expect(
      fixture.fakeCli.submittedImagePaths.where(
        (path) => p.normalize(path) == p.normalize(secondFrame.path),
      ),
      hasLength(1),
    );

    fixture.fakeCli.completeQueryAsFailed();
    await firstGeneration;
    await batchGeneration;
  });

  test('取消任务后延迟返回的生成中状态不能覆盖本地取消状态', () async {
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
    final frame = await File(
      p.join(fixture.root.path, 'cancel-race-frame.png'),
    ).writeAsBytes([1, 2, 3]);
    final added = fixture.shootingController.addShot()!;
    final shot = added.copyWith(
      framePath: frame.path,
      durationSeconds: 2,
      prompt: '取消后不得恢复为生成中。',
    );
    fixture.shootingController.updateShot(shot);
    await Future<void>.delayed(Duration.zero);

    final generation = fixture.controller.generateShot(shot);
    await _waitUntil(
      () => fixture.controller.value.tasks.any(
        (task) =>
            task.shotId == shot.id &&
            task.status == VideoGenerationTaskStatus.queued,
      ),
    );
    final activeTask = fixture.controller.value.tasks.firstWhere(
      (task) => task.shotId == shot.id,
    );
    await fixture.controller.cancelTask(activeTask);
    fixture.fakeCli.completeQueryAsRunning();
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.value.tasks
          .firstWhere((task) => task.id == activeTask.id)
          .status,
      VideoGenerationTaskStatus.canceled,
    );
    expect(
      VideoGenerationRepository(
        fixture.database,
      ).getTask(activeTask.id)?.status,
      VideoGenerationTaskStatus.canceled,
    );
    await generation;
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

  test('切换 LibTV 预设后自动检测环境并拉起浏览器授权', () async {
    final libTvCli = _FakeLibTvCliService(succeedAfterAttempts: 2);
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
      libTvCliResolver: const _FakeLibTvCliResolver(),
      libTvCliService: libTvCli,
    );
    addTearDown(fixture.dispose);

    await fixture.settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultLibTvCliVideoGenerationConfigId,
    );
    await _waitUntil(
      () =>
          fixture.controller.value.libTvEnvironment?.isReady == true &&
          fixture.controller.value.errorMessage.contains('LibTV 未登录'),
    );

    expect(fixture.controller.usesLibTvCli, isTrue);
    expect(fixture.controller.shouldRequestActiveCliLogin, isTrue);
    expect(
      fixture.controller.value.profile?.promptMode,
      VideoPromptMode.original,
    );

    final result = await fixture.controller.startLoginAuthorization();

    expect(result, KlingLoginAuthorizationStatus.completed);
    expect(libTvCli.startedCount, 1);
    expect(libTvCli.killedCount, 1);
    expect(fixture.controller.value.libTvAccount?.userId, 'libtv-user-1');
    expect(fixture.controller.value.libTvModel?.modelKey, 'star-video2');
    expect(fixture.controller.shouldRequestActiveCliLogin, isFalse);
    expect(fixture.controller.libTvParameterSummary, contains('分辨率：720p'));

    fixture.controller.updateLibTvAspectRatio('adaptive');
    fixture.controller.updateLibTvResolution('480p');
    fixture.controller.updateLibTvSoundEnabled(false);
    fixture.controller.updateLibTvSearchEnabled(false);

    expect(fixture.controller.selectedLibTvAspectRatio, 'adaptive');
    expect(fixture.controller.selectedLibTvResolution, '480p');
    expect(fixture.controller.selectedLibTvSoundEnabled, isFalse);
    expect(fixture.controller.selectedLibTvSearchEnabled, isFalse);
    expect(fixture.controller.libTvParameterSummary, contains('生成比例：adaptive'));
    expect(fixture.controller.libTvParameterSummary, contains('生成音频：关闭'));
    expect(fixture.controller.libTvParameterSummary, contains('联网增强：关闭'));
  });

  test('缺少 Node 和可灵 CLI 时按区域自动安装并重新检测环境', () async {
    final installer = _FakeCliDependencyInstaller();
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(),
      cliResolver: _InstallAwareKlingCliResolver(installer),
      dependencyInstaller: installer,
    );
    addTearDown(fixture.dispose);
    fixture.controller.value = fixture.controller.value.copyWith(
      environment: const KlingCliEnvironment(
        nodePath: '',
        nodeVersion: '',
        npmPath: '',
        klingPath: '',
        klingVersion: '',
        errorMessage: '未检测到 Node.js',
      ),
    );

    final installed = await fixture.controller.installActiveCli(
      klingRegion: KlingCliInstallRegion.global,
    );

    expect(installed, isTrue);
    expect(installer.nodeInstallCount, 1);
    expect(installer.klingRegions, [KlingCliInstallRegion.global]);
    expect(installer.klingNpmPaths, [r'C:\tools\npm.cmd']);
    expect(fixture.controller.activeCliEnvironmentReady, isTrue);
    expect(
      fixture.controller.value.cliInstallStatus,
      CliDependencyInstallStatus.completed,
    );
    expect(
      fixture
          .settingsController
          .value
          .activeVideoGenerationApiConfig
          ?.klingCliRegion,
      'global',
    );
  });

  test('缺少 LibTV CLI 时调用内置安装器并重新检测环境', () async {
    final installer = _FakeCliDependencyInstaller();
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(),
      libTvCliResolver: _InstallAwareLibTvCliResolver(installer),
      libTvCliService: _FakeLibTvCliService(succeedAfterAttempts: 999),
      dependencyInstaller: installer,
    );
    addTearDown(fixture.dispose);

    await fixture.settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultLibTvCliVideoGenerationConfigId,
    );
    await _waitUntil(
      () => fixture.controller.value.isLoadingEnvironment == false,
    );

    final installed = await fixture.controller.installActiveCli();

    expect(installed, isTrue);
    expect(installer.libTvInstallCount, 1);
    expect(fixture.controller.activeCliEnvironmentReady, isTrue);
    expect(
      fixture.controller.value.cliInstallStatus,
      CliDependencyInstallStatus.completed,
    );
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

  test('切换视频生成 API 时自动匹配提示词风格', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final shot = fixture.shootingController.addShot()!;
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.value.drafts[shot.id]?.promptMode,
      VideoPromptMode.klingOptimized,
    );

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

    expect(
      fixture.controller.value.profile?.promptMode,
      VideoPromptMode.h3Optimized,
    );
    expect(
      fixture.controller.value.drafts[shot.id]?.promptMode,
      VideoPromptMode.h3Optimized,
    );

    const jimengConfig = VideoGenerationApiConfig(
      id: 'test-jimeng',
      name: '即梦视频',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'https://example.test',
      apiKey: '',
      model: 'Seedance 2.0',
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(jimengConfig);
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.value.profile?.promptMode,
      VideoPromptMode.original,
    );
    expect(
      fixture.controller.value.drafts[shot.id]?.promptMode,
      VideoPromptMode.original,
    );

    await fixture.settingsController.setActiveVideoGenerationApiConfig(
      AppSettings.defaultKlingCliVideoGenerationConfigId,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.value.drafts[shot.id]?.promptMode,
      VideoPromptMode.klingOptimized,
    );

    fixture.controller.updateEditedPrompt(shot.id, '手工调整的提示词');
    await fixture.settingsController.setActiveVideoGenerationApiConfig(
      apiConfig.id,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.value.drafts[shot.id]?.promptMode,
      VideoPromptMode.edited,
    );
    expect(
      fixture.controller.value.drafts[shot.id]?.selectedPrompt,
      '手工调整的提示词',
    );
  });

  test('视频 API 初始化会后台续查历史超时任务且不锁住生成入口', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var queryCount = 0;
    var worksCount = 0;
    var downloadCount = 0;
    server.listen((request) async {
      if (request.method == 'GET' &&
          request.uri.path == '/api/jobs/generation-timeout') {
        queryCount++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'running', 'message': '仍在生成中'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/api/works') {
        worksCount++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'items': [
                {'id': 'generation-timeout', 'output': '/outputs/timeout.mp4'},
              ],
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/outputs/timeout.mp4') {
        downloadCount++;
        request.response.add([9, 8, 7, 6]);
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
    final apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local',
      name: 'MiniMax 本地',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://${server.address.host}:${server.port}',
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
        localPath: p.join(fixture.root.path, 'timeout-result.mp4'),
        createdAt: now,
        updatedAt: now,
      ),
    );

    await fixture.controller.initializeEnvironment();
    await _waitUntil(
      () =>
          fixture.controller.value.isBusy == false &&
          queryCount == 1 &&
          worksCount == 1 &&
          downloadCount == 1 &&
          fixture.controller.value.tasks.any(
            (task) =>
                task.generationId == 'generation-timeout' &&
                task.status == VideoGenerationTaskStatus.completed,
          ),
    );

    expect(fixture.controller.usesConfiguredVideoGenerationApi, isTrue);
    expect(fixture.controller.value.isBusy, isFalse);
    expect(fixture.controller.value.message, '已接收 1/1 个超时视频结果');
    final recovered = fixture.controller.value.tasks.singleWhere(
      (task) => task.generationId == 'generation-timeout',
    );
    expect(recovered.scriptId, shot.scriptId);
    expect(recovered.shotId, shot.id);
    expect(File(recovered.localPath).readAsBytesSync(), [9, 8, 7, 6]);
    final storedForShot = VideoGenerationRepository(
      fixture.database,
    ).listTasks(scriptId: shot.scriptId, shotId: shot.id);
    expect(storedForShot, hasLength(1));
    expect(storedForShot.single.status, VideoGenerationTaskStatus.completed);
    expect(storedForShot.single.generationId, 'generation-timeout');
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

  test('本地视频 API 非首尾帧会提交首帧和已确认资产图', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String submittedBody = '';
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/api/generate-upload') {
        final bodyBytes = await request.fold<List<int>>(
          <int>[],
          (buffer, data) => buffer..addAll(data),
        );
        submittedBody = utf8.decode(bodyBytes, allowMalformed: true);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'local-ref-job'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/jobs/local-ref-job') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'completed',
              'content_url': '/outputs/local-ref.mp4',
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/outputs/local-ref.mp4') {
        request.response.add([2, 4, 6, 8]);
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
      p.join(fixture.root.path, 'local-reference-frame.png'),
    ).writeAsBytes([1, 2, 3]);
    final assetFile = await File(
      p.join(fixture.root.path, 'local-reference-asset.png'),
    ).writeAsBytes([4, 5, 6]);
    final shot = fixture.shootingController.addShot()!;
    final updatedShot = shot.copyWith(
      framePath: frame.path,
      durationSeconds: 2,
      prompt: '''subject_definitions:
- <Picture 1>: The opening frame and composition reference.
- <Picture 2>: The transparent drinking glass product reference.
summary: A concise product presentation.
retention_analysis: Retain the glass identity and opening composition.
detailed_description: [Shot 1] The glass remains consistent while the camera moves slowly.
overall_soundscape: Quiet studio ambience.
non_diegetic_music: Minimal ambient music.''',
    );
    fixture.shootingController.updateShot(updatedShot);
    final workflowRepository = ShootingScriptWorkflowRepository(
      fixture.database,
    );
    final now = DateTime.now().toUtc();
    workflowRepository.upsertScriptAsset(
      ScriptAsset(
        id: 'local-asset-product',
        scriptId: updatedShot.scriptId,
        type: ReplicateAssetType.product,
        name: '透明水杯',
        description: '透明玻璃材质，银色杯盖',
        path: assetFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    workflowRepository.upsertLink(
      ScriptShotAssetLink(
        shotId: updatedShot.id,
        scriptAssetId: 'local-asset-product',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '手动确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local-assets',
      name: 'MiniMax 本地资产',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://${server.address.host}:${server.port}',
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    await Future<void>.delayed(Duration.zero);

    await fixture.controller.generateShot(updatedShot);

    expect(submittedBody, contains('name="mode"'));
    expect(submittedBody, contains('references'));
    expect(
      RegExp(r'name="reference_images"').allMatches(submittedBody),
      hasLength(2),
    );
    expect(submittedBody, contains('<Picture 2>: The transparent'));
    expect(submittedBody, isNot(contains('【参考素材补充】')));
    expect(
      RegExp(r'subject_definitions:').allMatches(submittedBody),
      hasLength(1),
    );
    expect(
      fixture.controller.value.tasks.single.status,
      VideoGenerationTaskStatus.completed,
    );
    expect(
      p.basename(fixture.controller.value.tasks.single.localPath),
      '镜头1-v1.mp4',
      reason: '软件实际保存的成片必须使用合并组顺序号且不补零',
    );
  });

  test('本地视频 API 的双帧普通镜头组不使用 last_frame 首尾帧模式', () async {
    var submittedBody = '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/api/generate-upload') {
        final bodyBytes = await request.fold<List<int>>(
          <int>[],
          (buffer, data) => buffer..addAll(data),
        );
        submittedBody = utf8.decode(bodyBytes, allowMalformed: true);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'manual-two-frame-job'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/jobs/manual-two-frame-job') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'completed',
              'content_url': '/outputs/manual-two-frame.mp4',
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/outputs/manual-two-frame.mp4') {
        request.response.add([3, 1, 4]);
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
    final firstFrame = await File(
      p.join(fixture.root.path, 'manual-two-frame-1.png'),
    ).writeAsBytes([1]);
    final secondFrame = await File(
      p.join(fixture.root.path, 'manual-two-frame-2.png'),
    ).writeAsBytes([2]);
    final first = fixture.shootingController.addShot()!;
    final second = fixture.shootingController.addShot()!;
    final freeCreationPrompt = _officialFreeCreationPrompt(
      pictureCount: 2,
      durationSeconds: 4,
    );
    fixture.shootingController.updateShot(
      first.copyWith(
        framePath: firstFrame.path,
        durationSeconds: 1,
        content: '人物拿起产品',
        prompt: freeCreationPrompt,
      ),
    );
    fixture.shootingController.updateShot(
      second.copyWith(
        framePath: secondFrame.path,
        durationSeconds: 4,
        content: '人物完成展示',
      ),
    );
    expect(
      fixture.shootingController.setContinuousShotRange(
        startShotId: first.id,
        endShotId: second.id,
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    fixture.replicateController.setFreeCreationEnabled(true);
    final replicateRepository = ReplicateRepository(fixture.database);
    final now = DateTime.now().toUtc();
    replicateRepository.upsertPrompt(
      ShotPrompt(
        id: 'free-creation-duration-prompt',
        runId: fixture.replicateController.value.run!.id,
        shotNumber: first.shotNumber,
        scriptShotId: first.id,
        assetIds: const [],
        prompt: freeCreationPrompt,
        model: 'MiniMax H3 Ref2VA',
        rawResponse: jsonEncode({
          'h3Prompt': freeCreationPrompt,
          'selectedPromptFormat': 'h3',
          'promptSource': 'freeCreationHolisticVision',
          'aiDurationSeconds': 4,
        }),
        status: ProcessingStatus.completed,
        errorMessage: '',
        updatedAt: now,
      ),
    );
    fixture.replicateController.refresh();
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.controller.desiredDurationFor(first),
      4,
      reason: '普通多帧组应使用拍摄脚本显示的组尾时长，不能取组首的 1 秒',
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(
      VideoGenerationApiConfig(
        id: 'test-manual-two-frame-api',
        name: '双帧普通镜头组',
        kind: VideoGenerationApiConfigKind.httpApi,
        baseUrl: 'http://${server.address.host}:${server.port}',
        apiKey: '',
        model: AppSettings.defaultVideoGenerationModel,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    fixture.controller.updateDesiredDurationFor(first, 7);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.controller.desiredDurationFor(first), 7);
    final synchronizedPrompt = _officialFreeCreationPrompt(
      pictureCount: 2,
      durationSeconds: 7,
    );
    expect(
      fixture.replicateController.value.prompts.single.prompt,
      synchronizedPrompt,
      reason: '确认镜头提示词必须与用户选择的时长同源更新',
    );
    expect(
      fixture.shootingController.value.shots.first.prompt,
      synchronizedPrompt,
    );
    expect(
      fixture.controller.value.drafts[first.id]?.sourcePrompt,
      synchronizedPrompt,
    );
    expect(
      fixture.controller.value.drafts[first.id]?.h3Prompt,
      synchronizedPrompt,
    );

    await fixture.controller.generateShot(first);

    expect(submittedBody, contains('name="mode"'));
    expect(submittedBody, contains('references'));
    expect(
      submittedBody,
      matches(RegExp(r'name="duration"\r?\n\r?\n7(?:\r?\n|--)')),
    );
    expect(submittedBody, contains('7秒视频'));
    expect(submittedBody, isNot(contains('name="last_frame"')));
    expect(
      RegExp(r'name="reference_images"').allMatches(submittedBody),
      hasLength(2),
    );
    final firstImageIndex = submittedBody.indexOf('manual-two-frame-1.png');
    final secondImageIndex = submittedBody.indexOf('manual-two-frame-2.png');
    expect(firstImageIndex, greaterThanOrEqualTo(0));
    expect(secondImageIndex, greaterThan(firstImageIndex));
    expect(submittedBody, contains('<Picture 1>'));
    expect(submittedBody, contains('<Picture 2>'));
    expect(submittedBody, isNot(contains('【参考素材补充】')));
    expect(submittedBody, isNot(contains('参考补充：')));
    expect(submittedBody, isNot(contains('首帧参考图')));
    expect(submittedBody, isNot(contains('尾帧参考图')));
    expect(fixture.controller.value.tasks.single.durationSeconds, 7);
    expect(fixture.controller.value.tasks.single.prompt, synchronizedPrompt);
  });

  test('本地视频 API 按确认页手动镜头组提交全部复刻帧和资产图', () async {
    var submittedBody = '';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/api/generate-upload') {
        final bodyBytes = await request.fold<List<int>>(
          <int>[],
          (buffer, data) => buffer..addAll(data),
        );
        submittedBody = utf8.decode(bodyBytes, allowMalformed: true);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'local-group-job'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/jobs/local-group-job') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'completed',
              'content_url': '/outputs/local-group.mp4',
            }),
          );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/outputs/local-group.mp4') {
        request.response.add([2, 4, 6, 8]);
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
    final firstFrame = await File(
      p.join(fixture.root.path, 'h3-group-first-frame.png'),
    ).writeAsBytes([1]);
    final middleFrame = await File(
      p.join(fixture.root.path, 'h3-group-middle-frame.png'),
    ).writeAsBytes([2]);
    final tailFrame = await File(
      p.join(fixture.root.path, 'h3-group-tail-frame.png'),
    ).writeAsBytes([3]);
    final firstReplica = await File(
      p.join(fixture.root.path, 'h3-group-first-replica.png'),
    ).writeAsBytes([11]);
    final middleReplica = await File(
      p.join(fixture.root.path, 'h3-group-middle-replica.png'),
    ).writeAsBytes([12]);
    final tailReplica = await File(
      p.join(fixture.root.path, 'h3-group-tail-replica.png'),
    ).writeAsBytes([13]);
    final middleAssetFile = await File(
      p.join(fixture.root.path, 'h3-group-middle-product.png'),
    ).writeAsBytes([21]);
    final tailAssetFile = await File(
      p.join(fixture.root.path, 'h3-group-tail-scene.png'),
    ).writeAsBytes([22]);
    final ignoredAudioFile = await File(
      p.join(fixture.root.path, 'h3-group-ignored-audio.mp3'),
    ).writeAsBytes([31, 32]);

    final first = fixture.shootingController.addShot()!;
    final middle = fixture.shootingController.addShot()!;
    final tail = fixture.shootingController.addShot()!;
    final updatedFirst = first.copyWith(
      framePath: firstFrame.path,
      durationSeconds: 2,
      content: '人物从门口走入',
      prompt: 'H3 镜头组提示词',
    );
    final updatedMiddle = middle.copyWith(
      framePath: middleFrame.path,
      durationSeconds: 2,
      content: '人物抬手展示产品',
      actionStage: '中间动作',
    );
    final updatedTail = tail.copyWith(
      framePath: tailFrame.path,
      durationSeconds: 2,
      content: '人物完成展示动作',
    );
    fixture.shootingController.updateShot(updatedFirst);
    fixture.shootingController.updateShot(updatedMiddle);
    fixture.shootingController.updateShot(updatedTail);
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.shootingController.setContinuousShotRange(
        startShotId: first.id,
        endShotId: tail.id,
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    final replicateRepository = ReplicateRepository(fixture.database);
    final now = DateTime.now().toUtc();
    for (final entry in [
      (shot: updatedFirst, frame: firstFrame, replica: firstReplica),
      (shot: updatedMiddle, frame: middleFrame, replica: middleReplica),
      (shot: updatedTail, frame: tailFrame, replica: tailReplica),
    ]) {
      replicateRepository.upsertReplicatedShotImage(
        ReplicatedShotImage(
          id: 'replicated-${entry.shot.id}',
          runId: fixture.replicateController.value.run!.id,
          scriptShotId: entry.shot.id,
          shotNumber: entry.shot.shotNumber,
          originalFramePath: entry.frame.path,
          generatedFramePath: entry.replica.path,
          assetIds: const [],
          prompt: '',
          model: 'test',
          rawResponse: '',
          status: ProcessingStatus.completed,
          errorMessage: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final workflowRepository = ShootingScriptWorkflowRepository(
      fixture.database,
    );
    for (final asset in [
      ScriptAsset(
        id: 'h3-group-audio',
        scriptId: updatedFirst.scriptId,
        type: ReplicateAssetType.audio,
        name: '环境声音参考',
        description: '不应进入 reference_images',
        path: ignoredAudioFile.path,
        referenceNumber: 0,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptAsset(
        id: 'h3-group-product',
        scriptId: updatedFirst.scriptId,
        type: ReplicateAssetType.product,
        name: '透明水杯',
        description: '透明玻璃材质，银色杯盖',
        path: middleAssetFile.path,
        referenceNumber: 1,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptAsset(
        id: 'h3-group-scene',
        scriptId: updatedFirst.scriptId,
        type: ReplicateAssetType.scene,
        name: '展示台场景',
        description: '白色弧形背景与银色台面',
        path: tailAssetFile.path,
        referenceNumber: 2,
        status: ProcessingStatus.completed,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertScriptAsset(asset);
    }
    for (final link in [
      ScriptShotAssetLink(
        shotId: updatedMiddle.id,
        scriptAssetId: 'h3-group-audio',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '音频只用于声音参考，不得作为图片附件提交',
        confirmed: true,
        locked: true,
        sortOrder: -1,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: updatedMiddle.id,
        scriptAssetId: 'h3-group-product',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '中间镜头手动确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: updatedTail.id,
        scriptAssetId: 'h3-group-product',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '尾镜头复用同一资产，验证去重',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
      ScriptShotAssetLink(
        shotId: updatedTail.id,
        scriptAssetId: 'h3-group-scene',
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '尾镜头手动确认',
        confirmed: true,
        locked: true,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      workflowRepository.upsertLink(link);
    }
    fixture.replicateController.refresh();
    await Future<void>.delayed(Duration.zero);

    final apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-local-group',
      name: 'MiniMax 本地镜头组',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://${server.address.host}:${server.port}',
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    await Future<void>.delayed(Duration.zero);

    await fixture.controller.generateShot(updatedFirst);

    expect(submittedBody, contains('name="mode"'));
    expect(submittedBody, contains('references'));
    expect(submittedBody, isNot(contains('name="last_frame"')));
    expect(
      RegExp(r'name="reference_images"').allMatches(submittedBody),
      hasLength(5),
    );
    expect(submittedBody, contains('@图片1至@图片3是同一连续镜头的顺序动作参考'));
    expect(submittedBody, contains('参考补充：'));
    expect(submittedBody, contains('@图片4是产品资产参考'));
    expect(submittedBody, contains('@图片5是场景资产参考'));
    expect(submittedBody, isNot(contains('@图片2是镜头2的顺序动作参考')));
    expect(submittedBody, isNot(contains('@图片3是镜头3的顺序动作参考')));
    expect(submittedBody, isNot(matches(RegExp(r'@图片\d+是镜头\d+'))));
    expect(submittedBody, isNot(contains('【参考素材补充】')));
    expect(submittedBody, isNot(contains('首帧参考图')));
    expect(submittedBody, isNot(contains('尾帧参考图')));
    expect(submittedBody, contains('h3-group-middle-product.png'));
    expect(submittedBody, contains('h3-group-tail-scene.png'));
    expect(submittedBody, isNot(contains('h3-group-ignored-audio.mp3')));
    final orderedReferenceNames = [
      'h3-group-first-replica.png',
      'h3-group-middle-replica.png',
      'h3-group-tail-replica.png',
      'h3-group-middle-product.png',
      'h3-group-tail-scene.png',
    ];
    var previousReferenceIndex = -1;
    for (final name in orderedReferenceNames) {
      final index = submittedBody.indexOf(name);
      expect(index, greaterThan(previousReferenceIndex), reason: name);
      previousReferenceIndex = index;
    }
    expect(
      fixture.controller.value.tasks.single.status,
      VideoGenerationTaskStatus.completed,
    );
    expect(
      p.basename(fixture.controller.value.tasks.single.localPath),
      '镜头1-v1.mp4',
      reason: '合并组成片应按组顺序号实际落盘',
    );
  });

  test('本地视频 API 批量生成会先全部提交到后端队列', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var submitCount = 0;
    final queryCountById = <String, int>{};
    server.listen((request) async {
      if (request.method == 'POST' &&
          request.uri.path == '/api/generate-upload') {
        submitCount++;
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'queued-job-$submitCount'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path.startsWith('/api/jobs/queued-job-')) {
        final id = request.uri.pathSegments.last;
        queryCountById[id] = (queryCountById[id] ?? 0) + 1;
        final firstJobStillWaitingForSecond =
            id == 'queued-job-1' && submitCount < 2;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            firstJobStillWaitingForSecond
                ? {'status': 'running', 'message': '第一个任务仍在生成'}
                : {'status': 'completed', 'content_url': '/outputs/$id.mp4'},
          ),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path.startsWith('/outputs/')) {
        request.response.add([1, 2, 3, submitCount]);
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
    final firstFrame = await File(
      p.join(fixture.root.path, 'local-api-first.png'),
    ).writeAsBytes([1, 2, 3]);
    final secondFrame = await File(
      p.join(fixture.root.path, 'local-api-second.png'),
    ).writeAsBytes([4, 5, 6]);
    final first = fixture.shootingController.addShot()!;
    final second = fixture.shootingController.addShot()!;
    fixture.shootingController.updateShot(
      first.copyWith(
        framePath: firstFrame.path,
        durationSeconds: 2,
        prompt: 'H3 第一条提示词',
      ),
    );
    fixture.shootingController.updateShot(
      second.copyWith(
        framePath: secondFrame.path,
        durationSeconds: 2,
        prompt: 'H3 第二条提示词',
      ),
    );

    final apiConfig = VideoGenerationApiConfig(
      id: 'test-minimax-queue',
      name: 'MiniMax 本地队列',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://${server.address.host}:${server.port}',
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);
    await Future<void>.delayed(Duration.zero);

    final generation = fixture.controller.generateAll();
    await _waitUntil(() => submitCount == 2);
    await generation;

    expect(submitCount, 2);
    expect(queryCountById.keys, containsAll(['queued-job-1', 'queued-job-2']));
    expect(
      fixture.controller.value.tasks.where(
        (task) => task.status == VideoGenerationTaskStatus.completed,
      ),
      hasLength(2),
    );
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

    expect(fixture.controller.videoApiAspectRatios, [
      '21:9',
      '16:9',
      '4:3',
      '1:1',
      '3:4',
      '9:16',
    ]);
    for (final aspectRatio in fixture.controller.videoApiAspectRatios) {
      expect(
        fixture.controller.videoApiResolutionsForAspect(aspectRatio),
        isNotEmpty,
        reason: '$aspectRatio 必须有可提交的本地 H3 分辨率预设',
      );
    }

    fixture.controller.updateVideoApiAspectRatio('21:9');
    expect(fixture.controller.selectedVideoApiAspectRatio, '21:9');
    expect(
      fixture.controller.videoApiResolutionsForAspect('21:9'),
      contains('0.5MP 21:9 - 1120x480'),
    );

    fixture.controller.updateVideoApiResolution('0.3MP 21:9 - 896x384');
    fixture.controller.updateVideoApiSteps(18);

    expect(fixture.controller.selectedVideoApiSubmissionParameters, {
      'resolution': '0.3MP 21:9 - 896x384',
      'steps': '18',
    });
    expect(fixture.controller.videoApiParameterSummary, contains('生成比例：21:9'));
    expect(
      fixture.controller.videoApiParameterSummary,
      contains('分辨率：0.3MP 21:9 - 896x384'),
    );
    expect(fixture.controller.videoApiParameterSummary, contains('步数：18'));
  });

  test('本地 H3 从配置 API 动态更新分辨率与默认值', () async {
    final videoApiService = MiniMaxVideoApiService(
      client: MockClient((request) async {
        expect(request.url.path, '/api/config');
        return http.Response(
          jsonEncode({
            'resolutions': [
              '0.2MP 16:9 - 608x352',
              '0.8MP 16:9 - 1216x704',
              '0.6MP 2:1 - 1088x544',
              'Experimental 123x456',
            ],
            'defaults': {'resolution': '0.8MP 16:9 - 1216x704', 'steps': 18},
          }),
          200,
        );
      }),
    );
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
      videoApiService: videoApiService,
    );
    addTearDown(fixture.dispose);
    const apiConfig = VideoGenerationApiConfig(
      id: 'test-dynamic-minimax-local',
      name: 'MiniMax 本地动态配置',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: AppSettings.defaultVideoGenerationApiBaseUrl,
      apiKey: '',
      model: AppSettings.defaultVideoGenerationModel,
    );
    await fixture.settingsController.saveVideoGenerationApiConfig(apiConfig);

    expect(await fixture.controller.refreshVideoApiConfig(), isTrue);
    expect(fixture.controller.videoApiAspectRatios, ['16:9', '2:1', '其他']);
    expect(fixture.controller.videoApiResolutionsForAspect('16:9'), [
      '0.2MP 16:9 - 608x352',
      '0.8MP 16:9 - 1216x704',
    ]);
    expect(fixture.controller.videoApiResolutionsForAspect('2:1'), [
      '0.6MP 2:1 - 1088x544',
    ]);
    expect(
      fixture.controller.selectedVideoApiResolution,
      '0.8MP 16:9 - 1216x704',
    );
    expect(fixture.controller.selectedVideoApiSteps, 18);

    fixture.controller.updateVideoApiResolution('0.8MP 16:9 - 1216x704');
    expect(fixture.controller.selectedVideoApiSubmissionParameters, {
      'resolution': '0.8MP 16:9 - 1216x704',
      'steps': '18',
    });
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

  test('作品管理删除会同步清理本地视频和任务记录', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final source = await File(
      p.join(fixture.root.path, 'work-management-delete.mp4'),
    ).writeAsBytes([1, 2, 3, 4]);
    final shot = fixture.shootingController.addShot()!;
    final now = DateTime.now().toUtc();
    final task = VideoGenerationTask(
      id: 'task-work-management-delete',
      scriptId: shot.scriptId,
      shotId: shot.id,
      generationId: 'generation-work-management-delete',
      model: 'kling-video-v3_0_omni',
      durationSeconds: 5,
      promptMode: VideoPromptMode.klingOptimized,
      prompt: '删除作品测试',
      status: VideoGenerationTaskStatus.completed,
      localPath: source.path,
      createdAt: now,
      updatedAt: now,
      completedAt: now,
    );
    final repository = VideoGenerationRepository(fixture.database);
    repository.upsertTask(task);

    await fixture.controller.deleteTask(task);

    expect(source.existsSync(), isFalse);
    expect(repository.listTasks().where((item) => item.id == task.id), isEmpty);
  });

  test('当前工程相对路径完成视频可解析到生成视频列可显示文件', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final shot = fixture.shootingController.addShot()!;
    final workspaceRoot = Directory(p.join(fixture.root.path, 'data'));
    final video = await File(
      p.join(workspaceRoot.path, 'videos', 'generated', 'shot-1.mp4'),
    ).create(recursive: true);
    await video.writeAsBytes([1, 2, 3, 4]);
    final storedPath = p
        .relative(video.path, from: workspaceRoot.path)
        .replaceAll('\\', '/');
    final now = DateTime.now().toUtc();
    final task = VideoGenerationTask(
      id: 'relative-video-task',
      scriptId: shot.scriptId,
      shotId: shot.id,
      generationId: 'relative-generation',
      model: AppSettings.defaultVideoGenerationModel,
      durationSeconds: 5,
      promptMode: VideoPromptMode.h3Optimized,
      prompt: '相对路径显示测试',
      status: VideoGenerationTaskStatus.completed,
      localPath: storedPath,
      createdAt: now,
      updatedAt: now,
      completedAt: now,
    );
    fixture.controller.value = fixture.controller.value.copyWith(tasks: [task]);

    expect(fixture.controller.tasksForShot(shot.id).single, task);
    expect(fixture.controller.generatedVideoFileFor(task).existsSync(), isTrue);
    expect(
      p.normalize(fixture.controller.generatedVideoFileFor(task).path),
      p.normalize(video.path),
    );
  });

  test('启动时移除本地成片已删除的完成任务，保留失败任务记录', () async {
    late VideoGenerationTask missingCompleted;
    late VideoGenerationTask failed;
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
      beforeController: (repository, shootingController) {
        final completedShot = shootingController.addShot()!;
        final failedShot = shootingController.addShot()!;
        final now = DateTime.now().toUtc();
        missingCompleted = VideoGenerationTask(
          id: 'missing-completed-video',
          scriptId: completedShot.scriptId,
          shotId: completedShot.id,
          generationId: 'missing-completed-generation',
          model: AppSettings.defaultVideoGenerationModel,
          durationSeconds: 5,
          promptMode: VideoPromptMode.h3Optimized,
          prompt: '手动删除本地成片后的清理测试',
          status: VideoGenerationTaskStatus.completed,
          localPath: 'videos/generated/missing-completed.mp4',
          createdAt: now,
          updatedAt: now,
          completedAt: now,
        );
        failed = VideoGenerationTask(
          id: 'failed-video-task',
          scriptId: failedShot.scriptId,
          shotId: failedShot.id,
          generationId: 'failed-generation',
          model: AppSettings.defaultVideoGenerationModel,
          durationSeconds: 5,
          promptMode: VideoPromptMode.h3Optimized,
          prompt: '失败任务不应被文件扫描删除',
          status: VideoGenerationTaskStatus.failed,
          localPath: 'videos/generated/failed.mp4',
          errorMessage: '生成失败',
          createdAt: now,
          updatedAt: now,
          completedAt: now,
        );
        repository
          ..upsertTask(missingCompleted)
          ..upsertTask(failed);
      },
    );
    addTearDown(fixture.dispose);
    final repository = VideoGenerationRepository(fixture.database);

    expect(repository.getTask(missingCompleted.id), isNull);
    expect(
      repository.getTask(failed.id)?.status,
      VideoGenerationTaskStatus.failed,
    );
    expect(
      fixture.controller.value.tasks.map((task) => task.id),
      isNot(contains(missingCompleted.id)),
    );
    expect(fixture.controller.value.message, contains('已移除 1 条'));
  });

  test('生成页手动修改镜头组时长会写入组尾并同步提示词秒数', () async {
    final fixture = await _createControllerFixture(
      cliService: _FakeKlingCliService(succeedAfterAttempts: 1),
    );
    addTearDown(fixture.dispose);
    final first = fixture.shootingController.addShot()!;
    final tail = fixture.shootingController.addShot()!;
    fixture.shootingController.updateShot(
      first.copyWith(
        durationSeconds: 1,
        content: '人物拿起产品',
        prompt: '镜头组自然完成产品展示',
      ),
    );
    fixture.shootingController.updateShot(
      tail.copyWith(durationSeconds: 4, content: '人物完成展示'),
    );
    expect(
      fixture.shootingController.setContinuousShotRange(
        startShotId: first.id,
        endShotId: tail.id,
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.desiredDurationFor(first), 4);
    expect(
      fixture.controller.value.drafts[first.id]?.h3Prompt,
      contains('4秒视频'),
    );
    fixture.controller.updateEditedPrompt(first.id, '4秒视频，保留用户手动补充。');

    fixture.controller.updateDesiredDurationFor(first, 7);
    await Future<void>.delayed(Duration.zero);

    final shots = fixture.shootingController.value.shots;
    expect(shots.first.durationSeconds, 1);
    expect(shots.last.durationSeconds, 7);
    expect(fixture.controller.desiredDurationFor(first), 7);
    expect(
      fixture.controller.value.drafts[first.id]?.h3Prompt,
      contains('7秒视频'),
    );
    expect(
      fixture.controller.value.drafts[first.id]?.selectedPrompt,
      startsWith('7秒视频'),
    );
  });
}

String _officialFreeCreationPrompt({
  required int pictureCount,
  required int durationSeconds,
}) {
  final definitions = [
    for (var index = 1; index <= pictureCount; index++)
      '- <Picture $index>: 第 $index 张顺序分镜参考。',
  ].join('\n');
  final retention = [
    for (var index = 1; index <= pictureCount; index++)
      '- <Picture $index>: fully_preserved - 保持主体与构图连续。',
  ].join('\n');
  return '''subject_definitions:
$definitions
summary:
[参考生成] $durationSeconds秒视频，人物连续完成产品展示。
retention_analysis:
$retention
detailed_description:
[Shot 1] 从 <Picture 1> 的起始动作自然过渡到 <Picture $pictureCount> 的结束动作。
overall_soundscape:
自然环境声与动作声同步。
non_diegetic_music:
N/A''';
}

Future<_ControllerFixture> _createControllerFixture({
  required _FakeKlingCliService cliService,
  KlingCliResolver? cliResolver,
  LibTvCliResolver? libTvCliResolver,
  _FakeLibTvCliService? libTvCliService,
  CliDependencyInstaller? dependencyInstaller,
  MiniMaxVideoApiService? videoApiService,
  Duration loginAuthorizationTimeout = const Duration(seconds: 1),
  Duration loginAuthorizationPollInterval = const Duration(milliseconds: 1),
  void Function(
    VideoGenerationRepository repository,
    ShootingScriptController shootingController,
  )?
  beforeController,
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
  final videoGenerationRepository = VideoGenerationRepository(database);
  beforeController?.call(videoGenerationRepository, shootingController);
  final controller = VideoGenerationController(
    repository: videoGenerationRepository,
    videoRepository: VideoAnalysisRepository(database),
    workflowRepository: ShootingScriptWorkflowRepository(database),
    shootingScriptController: shootingController,
    replicateController: replicateController,
    directories: directories,
    settingsController: settingsController,
    cliResolver: cliResolver ?? const KlingCliResolver(),
    cliService: cliService,
    libTvCliResolver: libTvCliResolver ?? const LibTvCliResolver(),
    libTvCliService: libTvCliService ?? const LibTvCliService(),
    libTvCliServiceFactory: libTvCliService == null
        ? null
        : (_) => libTvCliService,
    dependencyInstaller: dependencyInstaller ?? const CliDependencyInstaller(),
    videoApiService: videoApiService,
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
  final List<String> submittedImagePaths = [];
  final List<List<String>> submittedReferenceImagePaths = [];
  final List<Map<String, String>> submittedParameters = [];
  final List<String> submittedPrompts = [];
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
    List<String> referenceImagePaths = const [],
    required Map<String, String> parameters,
    required String prompt,
  }) async {
    submittedImagePaths.add(imagePath);
    submittedReferenceImagePaths.add(referenceImagePaths);
    submittedParameters.add(parameters);
    submittedPrompts.add(prompt);
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

  void completeQueryAsRunning() {
    final completer = _queryCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        const KlingTaskResult(
          generationId: 'fake-generation-1',
          status: VideoGenerationTaskStatus.running,
          url: '',
          urlWithoutWatermark: '',
          errorMessage: '',
          rawJson: {'ok': true},
        ),
      );
    }
  }
}

class _FakeCliDependencyInstaller extends CliDependencyInstaller {
  int nodeInstallCount = 0;
  int libTvInstallCount = 0;
  final List<KlingCliInstallRegion> klingRegions = [];
  final List<String> klingNpmPaths = [];

  bool get nodeInstalled => nodeInstallCount > 0;
  bool get klingInstalled => klingRegions.isNotEmpty;
  bool get libTvInstalled => libTvInstallCount > 0;

  @override
  Future<void> installNodeJsLts() async => nodeInstallCount++;

  @override
  Future<void> installKling({
    required KlingCliInstallRegion region,
    required String npmPath,
  }) async {
    klingRegions.add(region);
    klingNpmPaths.add(npmPath);
  }

  @override
  Future<void> installLibTv() async => libTvInstallCount++;
}

class _InstallAwareKlingCliResolver extends KlingCliResolver {
  const _InstallAwareKlingCliResolver(this.installer);

  final _FakeCliDependencyInstaller installer;

  @override
  Future<KlingCliEnvironment> resolve() async {
    if (!installer.nodeInstalled) {
      return const KlingCliEnvironment(
        nodePath: '',
        nodeVersion: '',
        npmPath: '',
        klingPath: '',
        klingVersion: '',
        errorMessage: '未检测到 Node.js',
      );
    }
    if (!installer.klingInstalled) {
      return const KlingCliEnvironment(
        nodePath: r'C:\tools\node.exe',
        nodeVersion: 'v20.0.0',
        npmPath: r'C:\tools\npm.cmd',
        klingPath: '',
        klingVersion: '',
        errorMessage: '未检测到可灵 CLI',
      );
    }
    return const KlingCliEnvironment(
      nodePath: r'C:\tools\node.exe',
      nodeVersion: 'v20.0.0',
      npmPath: r'C:\tools\npm.cmd',
      klingPath: r'C:\tools\kling.cmd',
      klingVersion: 'kling-cli 1.0.0',
      errorMessage: '',
    );
  }
}

class _InstallAwareLibTvCliResolver extends LibTvCliResolver {
  const _InstallAwareLibTvCliResolver(this.installer);

  final _FakeCliDependencyInstaller installer;

  @override
  Future<LibTvCliEnvironment> resolve() async => installer.libTvInstalled
      ? const LibTvCliEnvironment(
          executablePath: r'C:\tools\libtv.exe',
          version: '1.1.3',
          errorMessage: '',
        )
      : const LibTvCliEnvironment(
          executablePath: '',
          version: '',
          errorMessage: '未检测到 LibTV CLI',
        );
}

class _FakeLibTvCliResolver extends LibTvCliResolver {
  const _FakeLibTvCliResolver();

  @override
  Future<LibTvCliEnvironment> resolve() async => const LibTvCliEnvironment(
    executablePath: r'C:\tools\libtv.exe',
    version: '1.1.3',
    errorMessage: '',
  );
}

class _FakeLibTvCliService extends LibTvCliService {
  _FakeLibTvCliService({required this.succeedAfterAttempts});

  final int succeedAfterAttempts;
  int accountInfoCount = 0;
  int startedCount = 0;
  int killedCount = 0;
  final List<Completer<int>> _exitCompleters = [];

  @override
  Future<LibTvRunningProcess> startLogin() async {
    startedCount++;
    final completer = Completer<int>();
    _exitCompleters.add(completer);
    return LibTvRunningProcess(
      exitCode: completer.future,
      kill: ([signal = ProcessSignal.sigterm]) {
        killedCount++;
        if (!completer.isCompleted) completer.complete(-1);
        return true;
      },
      stdout: () => '',
      stderr: () => 'login canceled',
    );
  }

  @override
  Future<LibTvAccountInfo> accountInfo() async {
    accountInfoCount++;
    if (accountInfoCount < succeedAfterAttempts) {
      throw const LibTvCliException('未登录');
    }
    return const LibTvAccountInfo(
      userId: 'libtv-user-1',
      nickname: 'LibTV测试用户',
      accountName: '个人空间',
      teamId: 0,
    );
  }

  @override
  Future<LibTvModelSpec> model(String name) async => const LibTvModelSpec(
    modelName: 'Seedance 2.0',
    modelKey: 'star-video2',
    modality: 'video',
    schema: {},
  );
}
