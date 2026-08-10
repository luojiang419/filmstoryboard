import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('最终提示词只引用当前镜头已确认的脚本资产', () async {
    final root = await Directory.systemTemp.createTemp('bound_prompt_');
    addTearDown(() => root.delete(recursive: true));
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final scriptController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    );
    scriptController.createEmpty(name: '绑定提示词脚本');
    final shot = scriptController.addShot()!.copyWith(
      content: '主角在客厅拿起产品',
      scene: '客厅',
    );
    scriptController.updateShot(shot);
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final now = DateTime.utc(2026, 1, 1);
    final hero = ScriptAsset(
      id: 'script-hero',
      scriptId: scriptController.value.selectedScript!.id,
      type: ReplicateAssetType.character,
      name: '主角',
      description: '白衬衫人物',
      path: 'hero.png',
      referenceNumber: 1,
      status: ProcessingStatus.completed,
      createdAt: now,
      updatedAt: now,
    );
    final unused = ScriptAsset(
      id: 'script-unused',
      scriptId: hero.scriptId,
      type: hero.type,
      name: '未使用场景',
      description: '完全不同的森林',
      path: 'forest.png',
      referenceNumber: 2,
      status: ProcessingStatus.completed,
      createdAt: now,
      updatedAt: now,
    );
    workflowRepository.upsertScriptAsset(hero);
    workflowRepository.upsertScriptAsset(unused);
    workflowRepository.upsertLink(
      ScriptShotAssetLink(
        shotId: shot.id,
        scriptAssetId: hero.id,
        matchSource: ScriptAssetMatchSource.manual,
        confidence: 1,
        matchReason: '人工确认',
        confirmed: true,
        locked: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: scriptController,
      directories: directories,
      settingsController: settingsController,
      workflowRepository: workflowRepository,
    );
    addTearDown(() {
      controller.dispose();
      scriptController.dispose();
      settingsController.dispose();
    });

    controller.confirmAllShots();
    expect(controller.moveToStep(ReplicateStep.prepareAssets), isTrue);
    expect(controller.moveToStep(ReplicateStep.composePrompts), isTrue);
    await controller.composeAllPrompts();

    final prompt = controller.value.prompts.single;
    expect(prompt.assetIds, [hero.id]);
    expect(controller.promptFormatFor(prompt), ShotPromptFormat.kling);
    expect(prompt.prompt, contains('图片1为起始画面与主体参考'));
    expect(
      controller.promptTextFor(prompt, ShotPromptFormat.sd2),
      contains('白衬衫人物'),
    );
    expect(
      controller.promptTextFor(prompt, ShotPromptFormat.h3),
      contains('【参考素材说明】'),
    );
    expect(
      controller.promptTextFor(prompt, ShotPromptFormat.h3),
      contains('人物参考'),
    );
    expect(prompt.prompt, isNot(contains('完全不同的森林')));
    expect(
      controller.promptTextFor(prompt, ShotPromptFormat.sd2),
      isNot(contains('完全不同的森林')),
    );
  });
}
