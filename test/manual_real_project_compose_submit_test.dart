import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/projects/data/project_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/minimax_video_api_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_directories.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  test(
    'manual real project compose prompt and submit one H3 generation',
    () async {
      final enabled = Platform.environment['RUN_REAL_PROJECT_SUBMIT'] == '1';
      if (!enabled) {
        print('REAL_SUBMIT_SKIPPED=1');
        return;
      }

      final appRoot = Directory(r'D:\Program Files\filmstoryboard');
      final projectRoot = Directory(
        r'D:\Program Files\filmstoryboard\data\project\A',
      );
      final appDirectories = await AppDirectories.create(
        executableDirectory: appRoot,
      );
      final projectDirectories = ProjectDirectories.fromRoot(projectRoot);
      final globalDatabase = await AppDatabase.open(
        appDirectories.databaseFile,
      );
      final projectDatabase = await AppDatabase.open(
        projectDirectories.databaseFile,
      );

      SettingsController? settingsController;
      ShootingScriptController? shootingController;
      ShootingAssetLibraryController? libraryController;
      ShootingScriptAssetBindingController? bindingController;
      ReplicateController? replicateController;
      try {
        final settingsRepository = SettingsRepository(
          globalDatabase,
          appDirectories,
        );
        settingsController = SettingsController(
          repository: settingsRepository,
          initialSettings: settingsRepository.load().copyWith(
            activeVideoGenerationApiConfigId:
                AppSettings.defaultMiniMaxVideoGenerationConfigId,
          ),
        );
        final shootingRepository = ShootingScriptRepository(projectDatabase);
        final workflowRepository = ShootingScriptWorkflowRepository(
          projectDatabase,
        );
        shootingController = ShootingScriptController(
          repository: shootingRepository,
          directories: projectDirectories,
        );
        libraryController = ShootingAssetLibraryController(
          repository: ShootingAssetLibraryRepository(
            database: projectDatabase,
            directories: projectDirectories,
          ),
          directories: projectDirectories,
        );
        bindingController = ShootingScriptAssetBindingController(
          repository: workflowRepository,
          shootingScriptController: shootingController,
          libraryController: libraryController,
          settingsController: settingsController,
        );
        replicateController = ReplicateController(
          repository: ReplicateRepository(projectDatabase),
          shootingScriptController: shootingController,
          directories: projectDirectories,
          settingsController: settingsController,
          workflowRepository: workflowRepository,
          assetBindingController: bindingController,
        );
        final activeSettingsController = settingsController;
        final activeShootingController = shootingController;
        final activeReplicateController = replicateController;

        await activeReplicateController.composeAllPrompts();
        if (activeReplicateController.value.errorMessage.isNotEmpty) {
          throw StateError(activeReplicateController.value.errorMessage);
        }
        final prompts = [...activeReplicateController.value.prompts]
          ..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));
        final selectedPrompt = prompts.firstWhere(
          (prompt) =>
              _replicatedImageForShot(
                activeReplicateController.value.replicatedImages,
                prompt.scriptShotId ?? '',
              ) !=
              null,
        );
        final shot = activeShootingController.value.shots.firstWhere(
          (item) => item.id == selectedPrompt.scriptShotId,
        );
        final replicated = _replicatedImageForShot(
          activeReplicateController.value.replicatedImages,
          shot.id,
        )!;
        final sourceImage = File(replicated.generatedFramePath);
        final assets = _confirmedExistingAssetsForShot(
          workflowRepository,
          shot.scriptId,
          shot.id,
        );
        final referenceImagePaths = [
          for (final asset in assets)
            if (p.normalize(asset.path) != p.normalize(sourceImage.path))
              asset.path,
        ];
        final promptText = _videoApiPromptForSubmission(
          selectedPrompt.prompt,
          assets: assets,
        );

        final videoConfig =
            activeSettingsController.value.activeVideoGenerationApiConfig;
        if (videoConfig == null) {
          throw StateError('缺少活动视频生成 API 配置');
        }
        final videoRepository = VideoGenerationRepository(projectDatabase);
        final profile = videoRepository.getProfile(shot.scriptId);
        final parameters = _miniMaxParameters(profile?.parameters ?? const {});
        final directories = VideoGenerationDirectories.resolve(
          projectDirectories: projectDirectories,
          scriptName:
              activeReplicateController.value.selectedScript?.name ?? 'script',
          scriptId: shot.scriptId,
          stableDirectoryName: profile?.directoryName,
        );
        await directories.create();
        final now = DateTime.now().toUtc();
        final task = VideoGenerationTask(
          id: const Uuid().v4(),
          scriptId: shot.scriptId,
          shotId: shot.id,
          model: videoConfig.model,
          parameters: parameters,
          durationSeconds: shot.durationSeconds.round().clamp(1, 15).toInt(),
          promptMode: VideoPromptMode.h3Optimized,
          prompt: promptText,
          status: VideoGenerationTaskStatus.draft,
          localPath: _outputFile(
            directories.results,
            shotNumber: shot.shotNumber,
            version: _nextVersionForShot(videoRepository, shot.id),
          ).path,
          createdAt: now,
          updatedAt: now,
        );
        final submission = VideoGenerationSubmission(
          task: task,
          sourceImagePath: sourceImage.path,
          referenceImagePaths: referenceImagePaths,
          outputFile: File(task.localPath),
        );
        final results = await VideoGenerationTaskService(
          repository: videoRepository,
          cliService: const KlingCliService(),
          videoApiConfig: videoConfig,
          videoApiService: MiniMaxVideoApiService(),
          pollTimeout: Duration.zero,
        ).submitBatch([submission], concurrency: 1);
        final submitted = results.single;

        final raw = _decodeRaw(selectedPrompt.rawResponse);
        print(
          'REAL_SUBMIT_SCRIPT=${activeReplicateController.value.selectedScript?.name}',
        );
        print('REAL_SUBMIT_SHOT=${shot.shotNumber}');
        print('REAL_SUBMIT_TASK_ID=${submitted.id}');
        print('REAL_SUBMIT_GENERATION_ID=${submitted.generationId}');
        print('REAL_SUBMIT_STATUS=${submitted.status.name}');
        print('REAL_SUBMIT_ERROR=${submitted.errorMessage}');
        print('REAL_SUBMIT_MODEL=${submitted.model}');
        print('REAL_SUBMIT_SOURCE_IMAGE=${sourceImage.path}');
        print(
          'REAL_SUBMIT_REFERENCE_IMAGES=${jsonEncode(referenceImagePaths)}',
        );
        print(
          'REAL_SUBMIT_ASSETS=${jsonEncode([
            for (final asset in assets) {'name': asset.name, 'type': asset.type.name, 'path': asset.path},
          ])}',
        );
        print(
          'REAL_SUBMIT_PROMPT_ASSEMBLY=${jsonEncode({'source': raw['promptSource'], 'mode': raw['assemblyMode'], 'analysisStage': raw['analysisStage'], 'visionModelCalls': raw['visionModelCalls']})}',
        );
        print('REAL_SUBMIT_PROMPT_BEGIN');
        print(promptText);
        print('REAL_SUBMIT_PROMPT_END');
      } finally {
        replicateController?.dispose();
        bindingController?.dispose();
        libraryController?.dispose();
        shootingController?.dispose();
        settingsController?.dispose();
        projectDatabase.dispose();
        globalDatabase.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

ReplicatedShotImage? _replicatedImageForShot(
  List<ReplicatedShotImage> images,
  String shotId,
) {
  for (final image in images.reversed) {
    if (image.scriptShotId == shotId &&
        image.status == ProcessingStatus.completed &&
        File(image.generatedFramePath).existsSync()) {
      return image;
    }
  }
  return null;
}

List<ScriptAsset> _confirmedExistingAssetsForShot(
  ShootingScriptWorkflowRepository repository,
  String scriptId,
  String shotId,
) {
  final assetsById = {
    for (final asset in repository.listScriptAssets(scriptId)) asset.id: asset,
  };
  final result = <ScriptAsset>[];
  for (final link in repository.listLinksForShot(shotId)) {
    if (!link.confirmed) continue;
    final asset = assetsById[link.scriptAssetId];
    if (asset == null ||
        asset.status != ProcessingStatus.completed ||
        !File(asset.path).existsSync()) {
      continue;
    }
    result.add(asset);
  }
  return result;
}

String _videoApiPromptForSubmission(
  String prompt, {
  required List<ScriptAsset> assets,
}) {
  final descriptions = [
    '@图片1 是首帧/画面参考图，用于锁定主体外观、场景空间、构图和光影',
    for (var index = 0; index < assets.length; index++)
      '@图片${index + 2} 是${_assetRole(assets[index])}，${_joinNonEmpty([assets[index].name, assets[index].description])}',
  ];
  return [
    '【参考素材补充】${descriptions.join('；')}。请按编号使用参考图，不要混淆资产身份、外观、材质、颜色、服装/造型和标志性细节。',
    prompt,
  ].where((part) => part.trim().isNotEmpty).join('\n');
}

String _assetRole(ScriptAsset asset) => switch (asset.type) {
  ReplicateAssetType.character => '人物资产参考',
  ReplicateAssetType.product => '产品资产参考',
  ReplicateAssetType.scene => '场景资产参考',
  ReplicateAssetType.prop => '道具资产参考',
  ReplicateAssetType.video => '动作视频参考',
  ReplicateAssetType.audio => '声音参考',
  ReplicateAssetType.reference || ReplicateAssetType.other => '综合参考',
};

String _joinNonEmpty(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .join('，');

Map<String, Object?> _decodeRaw(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return const {};
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  } catch (_) {
    return const {};
  }
}

Map<String, String> _miniMaxParameters(Map<String, String> profileParameters) {
  return {
    'resolution':
        profileParameters['minimax_api_resolution'] ??
        profileParameters['resolution'] ??
        '0.2MP 16:9 - 608x352',
    'steps':
        profileParameters['minimax_api_steps'] ??
        profileParameters['steps'] ??
        '12',
  };
}

File _outputFile(
  Directory outputDirectory, {
  required int shotNumber,
  required int version,
}) {
  final number = shotNumber > 0 ? shotNumber.toString().padLeft(3, '0') : '000';
  return File(
    p.join(
      outputDirectory.path,
      'shot-$number-v${version.toString().padLeft(2, '0')}.mp4',
    ),
  );
}

int _nextVersionForShot(VideoGenerationRepository repository, String shotId) {
  final existing = repository.listTasks().where(
    (task) => task.shotId == shotId,
  );
  return existing.length + 1;
}
