import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/data/h3_skill_library.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/script_multimodal_analysis_service.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('自动解析全部会在非覆盖模式下修正已有污染色彩栏', () async {
    final root = await Directory.systemTemp.createTemp('script_analysis_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '色彩净化脚本');
    final frame = File('${root.path}${Platform.pathSeparator}frame.png');
    await frame.writeAsBytes([1, 2, 3]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(
        framePath: frame.path,
        content: '人工确认内容',
        colorPalette: '暖灰石墙为底，搭配深棕皮革、黑白条纹与米白长裤的暖中性色调',
      ),
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
      analysisService: _FakeAnalysisService(),
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    await analysisController.analyzeAll();

    final updated = shootingController.value.shots.single;
    expect(updated.content, '人工确认内容');
    expect(updated.colorPalette, '暖中性色调');
    expect(updated.colorPalette, isNot(contains('皮革')));
    expect(updated.colorPalette, isNot(contains('条纹')));
    expect(updated.colorPalette, isNot(contains('长裤')));
    expect(updated.colorPalette, isNot(contains('石墙')));
    final record = workflowRepository.getAnalysis(updated.id);
    expect(record?.fieldSources['content'], 'preserved');
    expect(record?.fieldSources['colorPalette'], 'model');
  });

  test('完整官方 Skill 读取失败时中止构建且不静默使用摘要', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_skill_failure_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    await settingsController.setH3PromptStyleId('brand-promo');
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    shootingController.createEmpty(name: 'Skill 缺失测试');
    final frame = await File(
      '${root.path}${Platform.pathSeparator}frame.png',
    ).writeAsBytes([1, 2, 3]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(shot.copyWith(framePath: frame.path));
    final analysisService = _FakeAnalysisService();
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _FailingH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    final completed = await analysisController.buildScript();

    expect(completed, isFalse);
    expect(analysisService.groupCalls, 0);
    expect(analysisService.singleShotCalls, 0);
    expect(
      analysisController.value.errorMessage,
      allOf(contains('读取所选叙事风格的完整官方 Skill 失败'), contains('测试资源缺失')),
    );
  });

  test('解析分镜使用复刻分镜图并覆盖旧原帧解析内容', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_replica_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '复刻图解析脚本');
    final originalFrame = File(
      '${root.path}${Platform.pathSeparator}frame.png',
    );
    await originalFrame.writeAsBytes([1, 2, 3]);
    final replicaFrame = File(
      '${root.path}${Platform.pathSeparator}replica.png',
    );
    await replicaFrame.writeAsBytes([4, 5, 6]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(framePath: originalFrame.path, content: '旧原帧解析内容'),
    );
    final analysisService = _FakeAnalysisService(
      patch: const ScriptShotAnalysisPatch(
        values: {'content': '复刻分镜解析内容', 'cameraMovement': '上摇加推近'},
        fieldConfidence: {'content': 0.9, 'cameraMovement': 0.88},
        promptContext: ScriptShotPromptContext(
          subject: {'people': '女模特'},
          action: {'bodyAction': '抬手展示'},
          camera: {'cameraMovement': '上摇加推近'},
        ),
        rawResponse: '{}',
      ),
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    await analysisController.analyzeAll(
      overwriteExisting: true,
      imagePathOverrides: {shot.id: replicaFrame.path},
      requireImageOverrides: true,
    );

    expect(analysisService.imagePaths, [replicaFrame.path]);
    expect(analysisService.imagePaths, isNot(contains(originalFrame.path)));
    final updated = shootingController.value.shots.single;
    expect(updated.content, '复刻分镜解析内容');
    expect(updated.cameraMovement, '上摇加推近');
    final record = workflowRepository.getAnalysis(updated.id);
    expect(record?.status, ProcessingStatus.completed);
    expect(record?.fieldSources['content'], 'model');
    expect(record?.promptContext.subject['people'], '女模特');
    expect(record?.promptContext.action['bodyAction'], '抬手展示');
    expect(record?.promptContextSchemaVersion, 2);
    expect(
      record?.sourceImageFingerprint,
      'sha256:${sha256.convert([4, 5, 6])}',
    );
    expect(record?.analysisRuleVersion, 5);
  });

  test('解析分镜缺少复刻图时不回退原视频帧', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_missing_replica_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '缺复刻图脚本');
    final originalFrame = File(
      '${root.path}${Platform.pathSeparator}frame.png',
    );
    await originalFrame.writeAsBytes([1, 2, 3]);
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(framePath: originalFrame.path, content: '保留人工内容'),
    );
    final analysisService = _FakeAnalysisService();
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    await analysisController.analyzeAll(
      overwriteExisting: true,
      imagePathOverrides: const {},
      requireImageOverrides: true,
    );

    expect(analysisService.imagePaths, isEmpty);
    expect(shootingController.value.shots.single.content, '保留人工内容');
    final record = workflowRepository.getAnalysis(shot.id);
    expect(record?.status, ProcessingStatus.failed);
    expect(record?.errorMessage, contains('缺少复刻分镜图'));

    final buildCompleted = await analysisController.buildScript(
      requireImageOverrides: true,
    );
    expect(buildCompleted, isFalse);
  });

  test('构建脚本按镜头组只发起一次多帧解析并更新首帧', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_group_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '组级构建脚本');
    final firstFrame = File('${root.path}${Platform.pathSeparator}first.png');
    final secondFrame = File('${root.path}${Platform.pathSeparator}second.png');
    final firstReplica = File(
      '${root.path}${Platform.pathSeparator}first-replica.png',
    );
    final secondReplica = File(
      '${root.path}${Platform.pathSeparator}second-replica.png',
    );
    await firstFrame.writeAsBytes([1, 2, 3]);
    await secondFrame.writeAsBytes([4, 5, 6]);
    await firstReplica.writeAsBytes([7, 8, 9]);
    await secondReplica.writeAsBytes([10, 11, 12]);
    final first = shootingController.addShot()!;
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(
        framePath: firstFrame.path,
        durationSeconds: 8,
        content: '单帧旧内容',
        continuesToNext: true,
      ),
    );
    shootingController.updateShot(
      second.copyWith(
        framePath: secondFrame.path,
        durationSeconds: 0,
        content: '第二帧旧内容',
        continuesFromPrevious: true,
      ),
    );
    final analysisService = _FakeAnalysisService(
      groupPatch: const ScriptShotAnalysisPatch(
        values: {
          'content': '多帧综合后的镜头内容',
          'cameraMovement': '升降',
          'cameraAngle': '轻微上摇到眼平',
          'durationSeconds': '4.0',
          'continuesFromPrevious': 'true',
          'continuesToNext': 'false',
        },
        fieldConfidence: {
          'content': 0.9,
          'cameraMovement': 0.92,
          'cameraAngle': 0.86,
          'durationSeconds': 0.62,
        },
        rawResponse: '{}',
      ),
    );
    await settingsController.setH3PromptStyleId('brand-promo');
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    final buildCompleted = await analysisController.buildScript(
      imagePathOverrides: {
        first.id: firstReplica.path,
        second.id: secondReplica.path,
      },
    );

    expect(buildCompleted, isTrue);
    expect(analysisService.groupSizes, [2]);
    expect(
      analysisService.creativeBriefs,
      everyElement(
        allOf(
          allOf(
            contains('内容类型：品牌宣传短片'),
            contains('【MiniMax-H3 完整官方 Skill（强制执行）】'),
            contains('本次完整加载文件数：1'),
            contains(
              '<official_skill_file path="skills/brand-promo-video-generator/SKILL.cn.md">',
            ),
            contains('## 步骤 1：上传素材并确认简报'),
            contains('## 步骤 10：交付'),
            contains('【完整官方 Skill 结束】'),
          ),
          allOf(
            contains('官方技能：skills/brand-promo-video-generator'),
            contains('叙事结构：'),
            contains('品牌事实表'),
            contains('画面材质：'),
          ),
          allOf(
            contains('动作与连续性：'),
            contains('声音策略：'),
            contains('硬性禁区：'),
            contains('逐字段落实：'),
            contains('不得替代上方完整 Skill'),
            contains('优先于上方 Skill 中的每秒指令或固定时间段'),
            contains('不要在画面描述、动作阶段、运镜、声音或转场字段中写'),
          ),
        ),
      ),
    );
    expect(
      analysisService.storyContexts.last,
      allOf(contains('脚本《组级构建脚本》'), contains('当前处理 镜头 1-2')),
    );
    expect(analysisService.singleShotCalls, 0);
    expect(analysisService.groupCalls, 1);
    expect(analysisService.imagePaths, [firstReplica.path, secondReplica.path]);
    final updatedHead = shootingController.value.shots.first;
    expect(updatedHead.content, '多帧综合后的镜头内容');
    expect(updatedHead.cameraMovement, '升降');
    expect(updatedHead.cameraAngle, '轻微上摇到眼平');
    expect(updatedHead.durationSeconds, 8);
    expect(shootingController.value.shots[1].durationSeconds, 4);
    expect(updatedHead.continuesToNext, isTrue);
    expect(shootingController.value.shots[1].continuesFromPrevious, isTrue);
    final record = workflowRepository.getAnalysis(updatedHead.id);
    expect(record?.status, ProcessingStatus.completed);
    expect(record?.fieldSources['cameraMovement'], 'model');
  });

  test('手动设置镜头3到6后四帧只进入一次组级解析请求', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_manual_group_3_6_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '手动镜头3-6');
    final originalFrames = <File>[];
    final replicaFrames = <File>[];
    for (var index = 1; index <= 6; index++) {
      originalFrames.add(
        await File(
          '${root.path}${Platform.pathSeparator}original-$index.png',
        ).writeAsBytes([index]),
      );
      replicaFrames.add(
        await File(
          '${root.path}${Platform.pathSeparator}replica-$index.png',
        ).writeAsBytes([index + 10]),
      );
    }
    final shots = [
      for (var index = 0; index < 6; index++) shootingController.addShot()!,
    ];
    for (var index = 0; index < shots.length; index++) {
      shootingController.updateShot(
        shots[index].copyWith(framePath: originalFrames[index].path),
      );
    }
    expect(
      shootingController.setContinuousShotRange(
        startShotId: shots[2].id,
        endShotId: shots[5].id,
      ),
      isTrue,
    );
    final analysisService = _FakeAnalysisService();
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    final buildCompleted = await analysisController.buildScript(
      imagePathOverrides: {
        for (var index = 0; index < shots.length; index++)
          shots[index].id: replicaFrames[index].path,
      },
    );

    expect(buildCompleted, isTrue);
    expect(analysisService.groupCalls, 3);
    expect(analysisService.groupSizes, [1, 1, 4]);
    expect(analysisService.singleShotCalls, 0);
    expect(analysisService.imagePaths, [
      for (final frame in replicaFrames) frame.path,
    ]);
    expect(analysisService.storyContexts.last, contains('当前处理 镜头 3-6'));
  });

  test('MiniMax-M3 构建脚本并发处理镜头组且多帧组仍只请求一次', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_concurrent_groups_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    await settingsController.setVisionSettings(
      baseUrl: 'https://api.minimaxi.com',
      apiKey: 'test-key',
      model: 'MiniMax-M3',
    );
    await settingsController.setVisionApiConfigMaxRequestsPerMinute(
      settingsController.value.activeVisionApiConfigId,
      2,
    );
    shootingController.createEmpty(name: '并发组级构建');
    final frames = <File>[];
    for (var index = 0; index < 4; index++) {
      frames.add(
        await File(
          '${root.path}${Platform.pathSeparator}frame-$index.png',
        ).writeAsBytes([index + 1]),
      );
    }
    final shots = [
      for (var index = 0; index < frames.length; index++)
        shootingController.addShot()!,
    ];
    shootingController.updateShot(
      shots[0].copyWith(framePath: frames[0].path, continuesToNext: true),
    );
    shootingController.updateShot(
      shots[1].copyWith(framePath: frames[1].path, continuesFromPrevious: true),
    );
    shootingController.updateShot(shots[2].copyWith(framePath: frames[2].path));
    shootingController.updateShot(shots[3].copyWith(framePath: frames[3].path));
    final analysisService = _FakeAnalysisService(
      groupDelay: const Duration(milliseconds: 40),
    );
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    final buildCompleted = await analysisController.buildScript();

    expect(buildCompleted, isTrue);
    expect(analysisService.groupCalls, 3);
    expect(analysisService.groupSizes, [2, 1, 1]);
    expect(analysisService.maxActiveGroupCalls, 2);
    expect(analysisService.singleShotCalls, 0);
  });

  test('首尾帧组复刻图不完整时整组回退原视频帧组', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_replica_fallback_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '复刻图优先构建');
    final firstOriginal = File(
      '${root.path}${Platform.pathSeparator}first-original.png',
    );
    final firstReplica = File(
      '${root.path}${Platform.pathSeparator}first-replica.png',
    );
    final secondOriginal = File(
      '${root.path}${Platform.pathSeparator}second-original.png',
    );
    await firstOriginal.writeAsBytes([1]);
    await firstReplica.writeAsBytes([2]);
    await secondOriginal.writeAsBytes([3]);
    final first = shootingController.addShot()!;
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(framePath: firstOriginal.path, continuesToNext: true),
    );
    shootingController.updateShot(
      second.copyWith(
        framePath: secondOriginal.path,
        continuesFromPrevious: true,
      ),
    );
    final analysisService = _FakeAnalysisService();
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    await analysisController.buildScript(
      imagePathOverrides: {first.id: firstReplica.path},
    );

    expect(analysisService.singleShotCalls, 0);
    expect(analysisService.groupCalls, 1);
    expect(analysisService.imagePaths, [
      firstOriginal.path,
      secondOriginal.path,
    ]);
  });

  test('普通脚本条目各自优先复刻图且缺失时回退原帧', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_single_source_selection_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    shootingController.createEmpty(name: '普通条目图源选择');
    final firstOriginal = File(
      '${root.path}${Platform.pathSeparator}first-original.png',
    );
    final firstReplica = File(
      '${root.path}${Platform.pathSeparator}first-replica.png',
    );
    final secondOriginal = File(
      '${root.path}${Platform.pathSeparator}second-original.png',
    );
    await firstOriginal.writeAsBytes([1]);
    await firstReplica.writeAsBytes([2]);
    await secondOriginal.writeAsBytes([3]);
    final first = shootingController.addShot()!;
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(framePath: firstOriginal.path),
    );
    shootingController.updateShot(
      second.copyWith(framePath: secondOriginal.path),
    );
    final analysisService = _FakeAnalysisService();
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    await analysisController.buildScript(
      imagePathOverrides: {first.id: firstReplica.path},
    );

    expect(analysisService.groupSizes, [1, 1]);
    expect(analysisService.groupCalls, 2);
    expect(analysisService.imagePaths, [
      firstReplica.path,
      secondOriginal.path,
    ]);
  });

  test('有生成反馈时只重构对应镜头组并将反馈交给视觉模型', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_analysis_feedback_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final repository = ShootingScriptRepository(database);
    final shootingController = ShootingScriptController(
      repository: repository,
      directories: directories,
    );
    addTearDown(() {
      shootingController.dispose();
      settingsController.dispose();
    });
    final script = shootingController.createEmpty(name: '反馈局部重构');
    final firstFrame = await File(
      '${root.path}${Platform.pathSeparator}first.png',
    ).writeAsBytes([1]);
    final secondFrame = await File(
      '${root.path}${Platform.pathSeparator}second.png',
    ).writeAsBytes([2]);
    final first = shootingController.addShot()!;
    final second = shootingController.addShot()!;
    shootingController.updateShot(
      first.copyWith(
        framePath: firstFrame.path,
        content: '上一稿画面一',
        cameraMovement: '慢动作推镜',
        generationFeedback: '画面慢动作，人物表情呆滞，改为正常速度和自然表情',
      ),
    );
    shootingController.updateShot(
      second.copyWith(
        framePath: secondFrame.path,
        content: '未反馈镜头必须保持',
        cameraMovement: '固定',
      ),
    );
    expect(
      repository
          .listShots(script.id)
          .firstWhere((shot) => shot.id == first.id)
          .generationFeedback,
      contains('人物表情呆滞'),
      reason: '反馈必须在点击重构前持久化',
    );
    final analysisService = _FakeAnalysisService(
      groupPatch: const ScriptShotAnalysisPatch(
        values: {'content': '正常速度下人物露出自然表情', 'cameraMovement': '稳定跟拍'},
        fieldConfidence: {'content': 0.9, 'cameraMovement': 0.9},
        rawResponse: '{}',
      ),
    );
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: ShootingScriptWorkflowRepository(database),
      settingsController: settingsController,
      analysisService: analysisService,
      skillLibrary: const _TestH3SkillLibrary(),
    );
    addTearDown(analysisController.dispose);

    final completed = await analysisController.buildScript(
      onlyFeedbackGroups: true,
    );

    expect(completed, isTrue);
    expect(analysisService.groupCalls, 1);
    expect(analysisService.groupSizes, [1]);
    expect(
      analysisService.creativeBriefs.single,
      allOf(
        contains('用户对上一稿的生成反馈'),
        contains('画面慢动作'),
        contains('人物表情呆滞'),
        contains('不得忽略、改写或弱化用户反馈'),
      ),
    );
    final updated = shootingController.value.shots;
    expect(updated.first.content, '正常速度下人物露出自然表情');
    expect(updated.first.cameraMovement, '稳定跟拍');
    expect(updated.first.generationFeedback, isEmpty, reason: '成功应用后应清空已消费反馈');
    expect(updated[1].content, '未反馈镜头必须保持');
    expect(updated[1].cameraMovement, '固定');
    expect(
      repository.listShots(script.id).first.generationFeedback,
      isEmpty,
      reason: '已消费反馈的清空状态必须持久化',
    );
  });
}

class _TestH3SkillLibrary implements H3SkillLibrary {
  const _TestH3SkillLibrary();

  @override
  Future<H3SkillDocument> loadForStyle(H3PromptStyle style) async {
    return H3SkillDocument(
      style: style,
      sourceRevision: H3PromptStyle.officialSourceRevision,
      files: {
        '${style.officialSkillPath}/SKILL.cn.md':
            '''
# ${style.label}

## 步骤 1：上传素材并确认简报

测试环境中的完整 Skill 起始标记。

## 步骤 10：交付

测试环境中的完整 Skill 结束标记。

## 失败恢复

资产不可用：索要授权原件，绝不猜测。
''',
      },
    );
  }
}

class _FailingH3SkillLibrary implements H3SkillLibrary {
  const _FailingH3SkillLibrary();

  @override
  Future<H3SkillDocument> loadForStyle(H3PromptStyle style) {
    throw StateError('测试资源缺失：${style.officialSkillPath}');
  }
}

class _FakeAnalysisService extends ScriptMultimodalAnalysisService {
  _FakeAnalysisService({
    this.patch = const ScriptShotAnalysisPatch(
      values: {'content': '模型识别内容', 'colorPalette': '暖中性色调'},
      fieldConfidence: {'content': 0.84, 'colorPalette': 0.78},
      rawResponse: '{}',
    ),
    ScriptShotAnalysisPatch? groupPatch,
    this.groupDelay = Duration.zero,
  }) : groupPatch = groupPatch ?? patch;

  final ScriptShotAnalysisPatch patch;
  final ScriptShotAnalysisPatch groupPatch;
  final Duration groupDelay;
  final imagePaths = <String>[];
  final groupSizes = <int>[];
  int singleShotCalls = 0;
  int groupCalls = 0;
  int activeGroupCalls = 0;
  int maxActiveGroupCalls = 0;
  final creativeBriefs = <String>[];
  final storyContexts = <String>[];
  final neighboringCameraPlans = <String>[];

  @override
  Future<ScriptShotAnalysisPatch> analyzeShot({
    required AppSettings settings,
    required ScriptShot shot,
    required File imageFile,
    File? previousImageFile,
    File? nextImageFile,
    String creativeBrief = '',
    String storyContext = '',
  }) async {
    singleShotCalls++;
    imagePaths.add(imageFile.path);
    creativeBriefs.add(creativeBrief);
    storyContexts.add(storyContext);
    return patch;
  }

  @override
  Future<ScriptShotAnalysisPatch> analyzeShotGroup({
    required AppSettings settings,
    required List<ScriptShot> shots,
    required List<File> imageFiles,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
  }) async {
    groupCalls++;
    activeGroupCalls++;
    if (activeGroupCalls > maxActiveGroupCalls) {
      maxActiveGroupCalls = activeGroupCalls;
    }
    groupSizes.add(shots.length);
    imagePaths.addAll(imageFiles.map((file) => file.path));
    creativeBriefs.add(creativeBrief);
    storyContexts.add(storyContext);
    neighboringCameraPlans.add(neighboringCameraPlan);
    try {
      if (groupDelay > Duration.zero) {
        await Future<void>.delayed(groupDelay);
      }
      return groupPatch;
    } finally {
      activeGroupCalls--;
    }
  }
}
