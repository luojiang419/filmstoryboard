import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/script_multimodal_analysis_service.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
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
        rawResponse: '{}',
      ),
    );
    final workflowRepository = ShootingScriptWorkflowRepository(database);
    final analysisController = ShootingScriptAnalysisController(
      shootingScriptController: shootingController,
      repository: workflowRepository,
      settingsController: settingsController,
      analysisService: analysisService,
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
  });
}

class _FakeAnalysisService extends ScriptMultimodalAnalysisService {
  _FakeAnalysisService({
    this.patch = const ScriptShotAnalysisPatch(
      values: {'content': '模型识别内容', 'colorPalette': '暖中性色调'},
      fieldConfidence: {'content': 0.84, 'colorPalette': 0.78},
      rawResponse: '{}',
    ),
  });

  final ScriptShotAnalysisPatch patch;
  final imagePaths = <String>[];

  @override
  Future<ScriptShotAnalysisPatch> analyzeShot({
    required AppSettings settings,
    required ScriptShot shot,
    required File imageFile,
    File? previousImageFile,
    File? nextImageFile,
  }) async {
    imagePaths.add(imageFile.path);
    return patch;
  }
}
