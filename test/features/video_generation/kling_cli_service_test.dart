import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:test/test.dart';

void main() {
  test('结果下载会完整关闭临时文件并原子落盘', () async {
    final root = await Directory.systemTemp.createTemp('kling-download-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      if (root.existsSync()) await root.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.add(List<int>.generate(4096, (index) => index % 251));
      await request.response.close();
    });
    final destination = File('${root.path}/镜头001-v1.mp4');

    final downloaded = await const KlingResultDownloader().download(
      'http://${server.address.host}:${server.port}/result.mp4',
      destination,
    );

    expect(downloaded.path, destination.path);
    expect(await downloaded.length(), 4096);
    expect(File('${destination.path}.part').existsSync(), isFalse);
  });

  test('CLI 解析器要求 Node 18+ 并优先解析 kling.cmd', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      if (executable == 'where.exe') {
        return ProcessResult(1, 0, 'C:\\bin\\${arguments.single}\r\n', '');
      }
      if (arguments.single == '--version' && executable.endsWith('node')) {
        return ProcessResult(1, 0, 'v18.20.0', '');
      }
      return ProcessResult(1, 0, 'kling-cli 0.1.3', '');
    }

    final environment = await KlingCliResolver(processRunner: runner).resolve();
    expect(environment.isReady, isTrue);
    expect(environment.klingPath, endsWith('kling.cmd'));
    expect(KlingCliResolver.parseNodeMajor('v17.9.1'), 17);
  });

  test('CLI 服务兼容 camel/snake JSON 并以独立参数提交', () async {
    final calls = <List<String>>[];
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calls.add(arguments);
      final command = arguments.first;
      final body = switch (command) {
        'who_am_i' => {
          'user': {'user_id': 7},
          'available_models': {
            'image_to_video': {
              'models': [
                {
                  'model': 'kling-video-v3_0_turbo',
                  'alias': 'v3-turbo',
                  'arguments': [
                    {
                      'name': 'duration',
                      'required': false,
                      'default': '5',
                      'allowed_values': ['3', '5'],
                    },
                  ],
                  'inputs': [
                    {
                      'name': 'first_image',
                      'required': true,
                      'description': 'Source image URL',
                    },
                  ],
                },
              ],
            },
          },
        },
        'image_to_video' => {
          'data': {'generation_id': 'generation-1'},
        },
        'query_tasks' => {
          'task': {
            'task_status': 'PARTIAL_COMPLETED',
            'works': [
              {
                'url': 'https://example.test/watermark.mp4',
                'url_without_watermark': 'https://example.test/clean.mp4',
              },
            ],
          },
        },
        _ => <String, Object?>{},
      };
      return ProcessResult(1, 0, jsonEncode({'ok': true, 'body': body}), '');
    }

    final service = KlingCliService(
      executable: r'C:\bin\kling.cmd',
      processRunner: runner,
    );
    final identity = await service.whoAmI();
    final submission = await service.submitImageToVideo(
      model: identity.imageToVideoModels.single.model,
      imagePath: r'C:\frames\replicated 01.png',
      tailImagePath: r'C:\frames\replicated 03.png',
      parameters: const {'duration': '5', 'resolution': '1080p'},
      prompt: '人物缓慢转身，镜头轻推',
    );
    final result = await service.queryTask(submission.generationId);

    expect(identity.userId, '7');
    expect(
      identity.imageToVideoModels.single.argument('duration')?.allowedValues,
      ['3', '5'],
    );
    expect(
      identity.imageToVideoModels.single.inputs.single.name,
      'first_image',
    );
    expect(identity.imageToVideoModels.single.supportsStartEndFrames, isFalse);
    expect(submission.generationId, 'generation-1');
    expect(result.status, VideoGenerationTaskStatus.partialCompleted);
    expect(result.urlWithoutWatermark, contains('clean.mp4'));
    final submitArguments = calls.singleWhere(
      (arguments) => arguments.first == 'image_to_video',
    );
    expect(
      submitArguments,
      containsAllInOrder(['--image', r'C:\frames\replicated 01.png']),
    );
    expect(
      submitArguments,
      containsAllInOrder(['--tailImage', r'C:\frames\replicated 03.png']),
    );
    expect(submitArguments.last, '人物缓慢转身，镜头轻推');
  });

  group('任务编排', () {
    late Directory root;
    late AppDatabase database;
    late VideoGenerationRepository repository;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kling-task-service-');
      database = await AppDatabase.open(File('${root.path}/data.sqlite'));
      repository = VideoGenerationRepository(database);
      final now = DateTime.utc(2026, 8, 4);
      database.executeStatement(
        '''
        INSERT INTO shooting_scripts(
          id, name, status, version, created_at, updated_at
        ) VALUES('script-1', '脚本', 'draft', 1, ?, ?);
      ''',
        [now.toIso8601String(), now.toIso8601String()],
      );
      for (var index = 1; index <= 3; index++) {
        database.executeStatement(
          '''
          INSERT INTO script_shots(id, script_id, shot_number, updated_at)
          VALUES(?, 'script-1', ?, ?);
        ''',
          ['shot-$index', index, now.toIso8601String()],
        );
        await File('${root.path}/image-$index.png').writeAsBytes([1, 2, 3]);
      }
    });

    tearDown(() async {
      database.dispose();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('15 分钟超时只提交一次，重启恢复只查询不重投', () async {
      var submitCount = 0;
      Future<ProcessResult> firstRunner(
        String executable,
        List<String> arguments, {
        required bool runInShell,
      }) async {
        if (arguments.first == 'account') {
          return _jsonResult({'userId': 7, 'availableRemainCredits': 100});
        }
        if (arguments.first == 'image_to_video') {
          submitCount++;
          return _jsonResult({'generationId': 'generation-timeout'});
        }
        fail('零超时不应进入查询：$arguments');
      }

      final task = _task(1);
      final timedOut =
          await VideoGenerationTaskService(
            repository: repository,
            cliService: KlingCliService(processRunner: firstRunner),
            pollTimeout: Duration.zero,
          ).submitAndTrack(
            VideoGenerationSubmission(
              task: task,
              sourceImagePath: '${root.path}/image-1.png',
              outputFile: File('${root.path}/result-1.mp4'),
            ),
          );
      expect(submitCount, 1);
      expect(timedOut.status, VideoGenerationTaskStatus.timedOut);

      var queryCount = 0;
      Future<ProcessResult> recoveryRunner(
        String executable,
        List<String> arguments, {
        required bool runInShell,
      }) async {
        if (arguments.first == 'query_tasks') {
          queryCount++;
          return _jsonResult({
            'status': 'COMPLETED',
            'works': [
              {'urlWithoutWatermark': 'https://example.test/result.mp4'},
            ],
          });
        }
        if (arguments.first == 'account') {
          return _jsonResult({'availableRemainCredits': 95});
        }
        fail('恢复阶段禁止重新提交：$arguments');
      }

      final recovered = await VideoGenerationTaskService(
        repository: repository,
        cliService: KlingCliService(processRunner: recoveryRunner),
        download: (url, target) async => target..writeAsBytesSync([4, 5, 6]),
        pollInterval: Duration.zero,
      ).resumePending(outputForTask: (_) => File('${root.path}/result-1.mp4'));
      expect(queryCount, 1);
      expect(submitCount, 1);
      expect(recovered.single.status, VideoGenerationTaskStatus.completed);
      expect(recovered.single.usedWatermarkedFallback, isFalse);
    });

    test('批量生成最多同时执行两个付费提交', () async {
      var activeSubmissions = 0;
      var maximumSubmissions = 0;
      var generationIndex = 0;
      Future<ProcessResult> runner(
        String executable,
        List<String> arguments, {
        required bool runInShell,
      }) async {
        if (arguments.first == 'account') {
          return _jsonResult({'availableRemainCredits': 100});
        }
        if (arguments.first == 'image_to_video') {
          activeSubmissions++;
          maximumSubmissions = maximumSubmissions < activeSubmissions
              ? activeSubmissions
              : maximumSubmissions;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          activeSubmissions--;
          generationIndex++;
          return _jsonResult({'generationId': 'generation-$generationIndex'});
        }
        if (arguments.first == 'query_tasks') {
          return _jsonResult({
            'status': 'COMPLETED',
            'works': [
              {'url': 'https://example.test/result.mp4'},
            ],
          });
        }
        fail('未知命令：$arguments');
      }

      final service = VideoGenerationTaskService(
        repository: repository,
        cliService: KlingCliService(processRunner: runner),
        download: (url, target) async => target..writeAsBytesSync([7]),
        pollInterval: Duration.zero,
      );
      final results = await service.submitBatch([
        for (var index = 1; index <= 3; index++)
          VideoGenerationSubmission(
            task: _task(index),
            sourceImagePath: '${root.path}/image-$index.png',
            outputFile: File('${root.path}/result-$index.mp4'),
          ),
      ]);

      expect(results, hasLength(3));
      expect(maximumSubmissions, 2);
      expect(results.every((task) => task.status.isTerminal), isTrue);
    });
  });
}

VideoGenerationTask _task(int index) {
  final now = DateTime.utc(2026, 8, 4);
  return VideoGenerationTask(
    id: 'task-$index',
    scriptId: 'script-1',
    shotId: 'shot-$index',
    model: 'kling-video-v3_0_turbo',
    parameters: const {'resolution': '1080p'},
    durationSeconds: 5,
    promptMode: VideoPromptMode.klingOptimized,
    prompt: '镜头缓慢运动',
    status: VideoGenerationTaskStatus.draft,
    createdAt: now,
    updatedAt: now,
  );
}

ProcessResult _jsonResult(Map<String, Object?> body) =>
    ProcessResult(1, 0, jsonEncode({'ok': true, 'body': body}), '');
