import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppDatabase database;
  late VideoGenerationRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('libtv-task-service-');
    final directories = await AppDirectories.create(executableDirectory: root);
    database = await AppDatabase.open(directories.databaseFile);
    repository = VideoGenerationRepository(database);
    final now = DateTime.utc(2026, 8, 11).toIso8601String();
    database.executeStatement(
      '''
      INSERT INTO shooting_scripts(
        id, name, status, version, created_at, updated_at
      ) VALUES('script-1', 'LibTV测试脚本', 'draft', 1, ?, ?);
      ''',
      [now, now],
    );
    database.executeStatement(
      '''
      INSERT INTO script_shots(id, script_id, shot_number, updated_at)
      VALUES('shot-1', 'script-1', 1, ?);
      ''',
      [now],
    );
    await File(
      '${root.path}${Platform.pathSeparator}source.png',
    ).writeAsBytes([1, 2, 3]);
  });

  tearDown(() async {
    database.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('LibTV 同步终态会下载视频并保存画布与节点标识', () async {
    final fake = _FakeLibTvCliService();
    final service = VideoGenerationTaskService(
      repository: repository,
      cliService: const KlingCliService(),
      libTvCliService: fake,
      videoApiConfig: const VideoGenerationApiConfig(
        id: 'default-libtv-cli',
        name: 'LibTV CLI · 即梦 2.0',
        kind: VideoGenerationApiConfigKind.libTvCli,
        baseUrl: '',
        apiKey: '',
        model: 'Seedance 2.0',
      ),
      download: (url, target) async => target..writeAsBytesSync([4, 5, 6]),
    );
    final result = await service.submitAndTrack(
      VideoGenerationSubmission(
        task: _task(),
        sourceImagePath: '${root.path}${Platform.pathSeparator}source.png',
        scriptName: 'LibTV测试脚本',
        outputFile: File('${root.path}${Platform.pathSeparator}result.mp4'),
      ),
    );

    expect(fake.submittedScriptName, 'LibTV测试脚本');
    expect(fake.submittedRatio, 'adaptive');
    expect(fake.submittedResolution, '480p');
    expect(fake.submittedEnableSound, isFalse);
    expect(fake.submittedSearchEnabled, isFalse);
    expect(result.status, VideoGenerationTaskStatus.completed);
    expect(result.generationId, 'remote-task-1');
    expect(result.parameters[libTvProjectUuidParameter], 'project-1');
    expect(result.parameters[libTvNodeKeyParameter], 'video-node-1');
    expect(File(result.localPath).existsSync(), isTrue);
    expect(
      repository.listTasks(scriptId: 'script-1').single.status,
      VideoGenerationTaskStatus.completed,
    );
  });

  test('LibTV 生成取消会保存 canceled 而不是 failed', () async {
    final service = VideoGenerationTaskService(
      repository: repository,
      cliService: const KlingCliService(),
      libTvCliService: _FakeLibTvCliService(cancel: true),
      videoApiConfig: const VideoGenerationApiConfig(
        id: 'default-libtv-cli',
        name: 'LibTV CLI · 即梦 2.0',
        kind: VideoGenerationApiConfigKind.libTvCli,
        baseUrl: '',
        apiKey: '',
        model: 'Seedance 2.0',
      ),
    );

    final result = await service.submitAndTrack(
      VideoGenerationSubmission(
        task: _task(),
        sourceImagePath: '${root.path}${Platform.pathSeparator}source.png',
        outputFile: File('${root.path}${Platform.pathSeparator}result.mp4'),
      ),
    );

    expect(result.status, VideoGenerationTaskStatus.canceled);
    expect(result.errorMessage, isEmpty);
  });
}

VideoGenerationTask _task() {
  final now = DateTime.utc(2026, 8, 11);
  return VideoGenerationTask(
    id: 'task-1',
    scriptId: 'script-1',
    shotId: 'shot-1',
    model: 'Seedance 2.0',
    parameters: const {
      'ratio': 'adaptive',
      'resolution': '480p',
      'enableSound': 'off',
      'search_enabled': '0',
    },
    durationSeconds: 5,
    promptMode: VideoPromptMode.original,
    prompt: '镜头1：人物缓慢转头。',
    status: VideoGenerationTaskStatus.draft,
    createdAt: now,
    updatedAt: now,
  );
}

class _FakeLibTvCliService extends LibTvCliService {
  _FakeLibTvCliService({this.cancel = false});

  final bool cancel;
  String submittedScriptName = '';
  String submittedRatio = '';
  String submittedResolution = '';
  bool? submittedEnableSound;
  bool? submittedSearchEnabled;

  @override
  Future<LibTvGenerationResult> generateImageToVideo({
    required String scriptId,
    required String scriptName,
    required String taskId,
    required String prompt,
    required String sourceImagePath,
    List<String> referenceImagePaths = const [],
    String modelName = LibTvCliService.seedance20ModelName,
    String ratio = '16:9',
    String resolution = '720p',
    required int durationSeconds,
    bool enableSound = true,
    bool searchEnabled = true,
    bool Function()? isCanceled,
  }) async {
    submittedScriptName = scriptName;
    submittedRatio = ratio;
    submittedResolution = resolution;
    submittedEnableSound = enableSound;
    submittedSearchEnabled = searchEnabled;
    if (cancel) throw const LibTvGenerationCanceledException();
    return const LibTvGenerationResult(
      projectUuid: 'project-1',
      nodeKey: 'video-node-1',
      taskId: 'remote-task-1',
      videoUrl: 'https://cdn.example.com/result.mp4',
      rawJson: {},
    );
  }
}
