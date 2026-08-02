import 'dart:convert';
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
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('三步复刻任务可恢复，素材编号删除后不复用并能导出提示词', () async {
    final root = await Directory.systemTemp.createTemp('replicate_flow_');
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
    );
    late ReplicateController controller;
    addTearDown(() async {
      controller.dispose();
      shootingController.dispose();
      settingsController.dispose();
      database.dispose();
      await root.delete(recursive: true);
    });

    final script = shootingController.createEmpty(name: '夏日产品片');
    final shot = shootingController.addShot()!;
    shootingController.updateShot(
      shot.copyWith(
        content: '模特缓慢拿起玻璃杯并转向窗边',
        shotSize: '中景',
        cameraMovement: '缓慢推镜、横移',
        dialogue: '今天也要清爽一点',
        sound: '冰块碰撞声',
      ),
    );

    controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.selectedScriptId, script.id);
    expect(controller.moveToStep(ReplicateStep.prepareAssets), isFalse);

    controller.toggleShotConfirmed(shot.id, true);
    expect(controller.moveToStep(ReplicateStep.prepareAssets), isTrue);

    final firstSource = File('${root.path}/first.png');
    await firstSource.writeAsBytes([137, 80, 78, 71], flush: true);
    final first = await controller.importAsset(
      sourcePath: firstSource.path,
      type: ReplicateAssetType.character,
      name: '女主角',
      description: '短发，浅色亚麻衬衫',
    );
    expect(first?.referenceNumber, 1);
    await controller.deleteAsset(first!.id);
    controller.dispose();

    controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.run?.confirmedShotIds, contains(shot.id));

    final secondSource = File('${root.path}/second.png');
    await secondSource.writeAsBytes([137, 80, 78, 71, 13], flush: true);
    final second = await controller.importAsset(
      sourcePath: secondSource.path,
      type: ReplicateAssetType.product,
      name: '气泡水',
      description: '透明玻璃瓶，蓝色标签',
    );
    expect(second?.referenceNumber, 2);
    expect(controller.moveToStep(ReplicateStep.composePrompts), isTrue);

    await controller.composeAllPrompts();
    expect(controller.value.prompts, hasLength(1));
    final prompt = controller.value.prompts.single.prompt;
    expect(prompt, contains('图片2'));
    expect(prompt, contains('镜头1'));
    expect(prompt, contains('无字幕'));
    expect(prompt, isNot(contains(second!.id)));
    expect(controller.value.run?.completedCount, 1);
    expect(shootingController.value.shots.single.prompt, prompt);

    final exported = await controller.exportPrompts();
    expect(exported, isNotNull);
    expect(exported!.textFile.existsSync(), isTrue);
    expect(exported.jsonFile.existsSync(), isTrue);
    final json = jsonDecode(await exported.jsonFile.readAsString());
    expect(json['model'], ReplicateController.promptModel);
    expect(json['prompts'], hasLength(1));

    controller.dispose();
    controller = ReplicateController(
      repository: ReplicateRepository(database),
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    expect(controller.value.prompts.single.prompt, prompt);
    expect(controller.value.run?.currentStep, ReplicateStep.composePrompts);

    final restoredShot = shootingController.value.shots.single;
    shootingController.updateShot(
      restoredShot.copyWith(content: '外部页面修改后的镜头内容'),
    );
    expect(
      controller.value.run?.composePromptsStatus,
      ProcessingStatus.pending,
      reason: '脚本内容变化后，旧提示词必须明确标记为待重新合成',
    );
  });
}
