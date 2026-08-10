import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_task_service.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/kling_cli_service.dart';
import 'package:filmstoryboard/features/video_generation/data/minimax_video_api_service.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('CLI 进程输出遇到非 UTF-8 字节时使用兼容编码而不抛异常', () {
    expect(decodeKlingProcessOutput(utf8.encode('可灵正常输出')), '可灵正常输出');
    expect(decodeKlingProcessOutput(const [0xd6, 0xd0]), isNotEmpty);
  });

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

  test('CLI 解析器在 PATH 缺失时回退查找 npm 全局目录', () async {
    final root = await Directory.systemTemp.createTemp('kling-npm-prefix-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final kling = File(
      p.join(root.path, Platform.isWindows ? 'kling.cmd' : 'kling'),
    );
    await kling.writeAsString('');
    final cliEntryPoint = File(
      p.join(root.path, 'node_modules', '@klingai', 'cli-cn', 'dist', 'cli.js'),
    );
    await cliEntryPoint.parent.create(recursive: true);
    await cliEntryPoint.writeAsString('');
    final calls = <({String executable, List<String> arguments, bool shell})>[];

    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calls.add((
        executable: executable,
        arguments: List<String>.of(arguments),
        shell: runInShell,
      ));
      if (executable == 'where.exe') {
        final command = arguments.single;
        if (command == 'node') {
          return ProcessResult(1, 0, r'C:\bin\node.exe', '');
        }
        if (command == 'npm.cmd') {
          return ProcessResult(1, 0, r'C:\bin\npm.cmd', '');
        }
        if (command == 'kling.cmd') {
          return ProcessResult(1, 1, '', 'not found');
        }
      }
      if (arguments.length == 1 &&
          arguments.single == '--version' &&
          executable.endsWith('node.exe')) {
        return ProcessResult(1, 0, 'v24.15.0', '');
      }
      if (arguments.length == 2 &&
          arguments[0] == 'prefix' &&
          arguments[1] == '-g') {
        return ProcessResult(1, 0, root.path, '');
      }
      if (arguments.length == 2 &&
          arguments.first == cliEntryPoint.path &&
          arguments.last == '--version' &&
          executable.endsWith('node.exe')) {
        return ProcessResult(1, 0, 'kling-cli 0.1.3', '');
      }
      return ProcessResult(1, 1, '', 'unexpected $executable $arguments');
    }

    final environment = await KlingCliResolver(processRunner: runner).resolve();

    expect(environment.isReady, isTrue);
    expect(p.normalize(environment.klingPath), p.normalize(kling.path));
    if (Platform.isWindows) {
      expect(
        p.normalize(environment.klingEntryPointPath),
        p.normalize(cliEntryPoint.path),
      );
      expect(environment.commandExecutable, r'C:\bin\node.exe');
      expect(environment.commandArgumentsPrefix, [cliEntryPoint.path]);
      expect(environment.commandRunInShell, isFalse);
      expect(
        calls.any(
          (call) =>
              call.executable == r'C:\bin\node.exe' &&
              call.shell == false &&
              call.arguments.length == 2 &&
              call.arguments.first == cliEntryPoint.path &&
              call.arguments.last == '--version',
        ),
        isTrue,
      );
    }
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
      referenceImagePaths: const [
        r'C:\assets\hero.png',
        r'C:\assets\product.png',
      ],
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
      containsAllInOrder(['--image', r'C:\assets\hero.png']),
    );
    expect(
      submitArguments,
      containsAllInOrder(['--image', r'C:\assets\product.png']),
    );
    expect(
      submitArguments,
      containsAllInOrder(['--tailImage', r'C:\frames\replicated 03.png']),
    );
    expect(submitArguments.last, '人物缓慢转身，镜头轻推');
  });

  test('CLI 服务通过 Node 入口提交超长提示词且不启用 Windows shell', () async {
    const cliEntryPoint =
        r'C:\Users\tester\AppData\Roaming\npm\node_modules\@klingai\cli-cn\dist\cli.js';
    final prompt = List.filled(9000, '镜').join();
    String? calledExecutable;
    List<String>? calledArguments;
    bool? calledRunInShell;

    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calledExecutable = executable;
      calledArguments = List<String>.of(arguments);
      calledRunInShell = runInShell;
      return ProcessResult(
        1,
        0,
        jsonEncode({
          'ok': true,
          'body': {'generationId': 'long-prompt-generation'},
        }),
        '',
      );
    }

    final service = KlingCliService(
      executable: r'C:\Program Files\nodejs\node.exe',
      argumentPrefix: const [cliEntryPoint],
      runInShell: false,
      processRunner: runner,
    );
    final result = await service.submitImageToVideo(
      model: 'kling-video-v3_0_omni',
      imagePath: r'D:\project\frame.png',
      parameters: const {'duration': '5'},
      prompt: prompt,
    );

    expect(result.generationId, 'long-prompt-generation');
    expect(calledExecutable, r'C:\Program Files\nodejs\node.exe');
    expect(calledRunInShell, isFalse);
    expect(calledArguments?.first, cliEntryPoint);
    expect(calledArguments?[1], 'image_to_video');
    expect(calledArguments?.last, prompt);
  });

  test('MiniMax 本地视频 API 非首尾帧按多参考图 multipart 提交', () async {
    final root = await Directory.systemTemp.createTemp('minimax-api-ref-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final image = File('${root.path}/reference.png')
      ..writeAsBytesSync([1, 2, 3]);
    final character = File('${root.path}/character.png')
      ..writeAsBytesSync([4, 5, 6]);
    final product = File('${root.path}/product.png')
      ..writeAsBytesSync([7, 8, 9]);
    final requests = <http.BaseRequest>[];
    final client = MockClient.streaming((request, bodyStream) async {
      requests.add(request);
      if (request.url.path == '/api/generate-upload') {
        expect(request, isA<http.MultipartRequest>());
        final multipart = request as http.MultipartRequest;
        expect(multipart.headers['Authorization'], 'Bearer local-key');
        expect(multipart.fields['mode'], 'references');
        expect(multipart.fields['prompt'], '镜头缓慢运动');
        expect(multipart.fields['resolution'], '0.2MP 16:9 - 608x352');
        expect(multipart.fields['duration'], '2');
        expect(multipart.files.map((file) => file.field), [
          'reference_images',
          'reference_images',
          'reference_images',
        ]);
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"id":"job-ref"}')),
          200,
        );
      }
      if (request.url.path == '/api/jobs/job-ref') {
        expect(request.headers['Authorization'], 'Bearer local-key');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              '{"status":"completed","content_url":"/outputs/ref.mp4"}',
            ),
          ),
          200,
        );
      }
      return http.StreamedResponse(Stream.value(const []), 404);
    });

    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: 'local-key',
      model: 'minimax-h3-local',
    );

    final submission = await service.submitImageToVideo(
      config: config,
      imagePath: image.path,
      referenceImagePaths: [character.path, product.path],
      parameters: const {'resolution': '0.2MP 16:9 - 608x352', 'duration': '2'},
      prompt: '镜头缓慢运动',
    );
    final result = await service.queryTask(
      config: config,
      generationId: submission.generationId,
    );

    expect(submission.generationId, 'job-ref');
    expect(result.status, VideoGenerationTaskStatus.completed);
    expect(result.url, 'http://127.0.0.1:7860/outputs/ref.mp4');
    expect(requests.map((request) => request.url.path), [
      '/api/generate-upload',
      '/api/jobs/job-ref',
    ]);
  });

  test('MiniMax 本地视频 API 首尾帧按 keyframes multipart 提交', () async {
    final root = await Directory.systemTemp.createTemp('minimax-api-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final image = File('${root.path}/first.png')..writeAsBytesSync([1, 2, 3]);
    final tail = File('${root.path}/last.png')..writeAsBytesSync([4, 5, 6]);
    final requests = <http.BaseRequest>[];
    final client = MockClient.streaming((request, bodyStream) async {
      requests.add(request);
      if (request.url.path == '/api/generate-upload') {
        expect(request, isA<http.MultipartRequest>());
        final multipart = request as http.MultipartRequest;
        expect(multipart.headers['Authorization'], 'Bearer local-key');
        expect(multipart.fields['mode'], 'keyframes');
        expect(multipart.fields['prompt'], '镜头缓慢运动');
        expect(multipart.fields['resolution'], '0.2MP 16:9 - 608x352');
        expect(multipart.fields['duration'], '2');
        expect(
          multipart.files.map((file) => file.field),
          containsAllInOrder(['first_frame', 'last_frame']),
        );
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"id":"job-1"}')),
          200,
        );
      }
      if (request.url.path == '/api/jobs/job-1') {
        expect(request.headers['Authorization'], 'Bearer local-key');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              '{"status":"completed","content_url":"/outputs/result.mp4"}',
            ),
          ),
          200,
        );
      }
      return http.StreamedResponse(Stream.value(const []), 404);
    });

    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: 'local-key',
      model: 'minimax-h3-local',
    );

    final submission = await service.submitImageToVideo(
      config: config,
      imagePath: image.path,
      tailImagePath: tail.path,
      parameters: const {'resolution': '0.2MP 16:9 - 608x352', 'duration': '2'},
      prompt: '镜头缓慢运动',
    );
    final result = await service.queryTask(
      config: config,
      generationId: submission.generationId,
    );

    expect(submission.generationId, 'job-1');
    expect(result.status, VideoGenerationTaskStatus.completed);
    expect(result.url, 'http://127.0.0.1:7860/outputs/result.mp4');
    expect(requests.map((request) => request.url.path), [
      '/api/generate-upload',
      '/api/jobs/job-1',
    ]);
  });

  test('MiniMax 运行中 message 不作为错误状态提示', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/works') {
        return http.Response.bytes(
          utf8.encode('{"items":[]}'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(request.url.path, '/api/jobs/job-running');
      return http.Response.bytes(
        utf8.encode(
          '{"status":"running","message":"正在启动隐藏 ComfyUI 后端并加载 H3 模型"}',
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: '',
      model: 'minimax-h3-local',
    );

    final result = await service.queryTask(
      config: config,
      generationId: 'job-running',
    );

    expect(result.status, VideoGenerationTaskStatus.running);
    expect(result.errorMessage, isEmpty);
    expect(requests, ['/api/jobs/job-running', '/api/works']);
  });

  test('MiniMax 排队但前方无任务时按当前生成任务显示', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/works') {
        return http.Response.bytes(
          utf8.encode('{"items":[]}'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      expect(request.url.path, '/api/jobs/job-next');
      return http.Response.bytes(
        utf8.encode('{"status":"queued","jobs_ahead":0,"message":"等待开始"}'),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: '',
      model: 'minimax-h3-local',
    );

    final result = await service.queryTask(
      config: config,
      generationId: 'job-next',
    );

    expect(result.status, VideoGenerationTaskStatus.running);
    expect(requests, ['/api/jobs/job-next', '/api/works']);
  });

  test('MiniMax 任务接口未完成但作品库已有成片时优先同步作品结果', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/jobs/job-finished-in-works') {
        return http.Response.bytes(
          utf8.encode('{"status":"running","message":"仍在查询后端任务"}'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/works') {
        return http.Response.bytes(
          utf8.encode(
            '{"data":{"items":[{"generation_id":"job-finished-in-works","content_url":"/outputs/from-works.mp4"}]}}',
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('', 500);
    });
    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: '',
      model: 'minimax-h3-local',
    );

    final result = await service.queryTask(
      config: config,
      generationId: 'job-finished-in-works',
    );

    expect(result.status, VideoGenerationTaskStatus.completed);
    expect(result.url, 'http://127.0.0.1:7860/outputs/from-works.mp4');
    expect(requests, ['/api/jobs/job-finished-in-works', '/api/works']);
  });

  test('MiniMax 任务内存丢失但作品已落盘时从作品库恢复完成结果', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/jobs/job-completed') {
        return http.Response.bytes(
          utf8.encode('{"detail":"任务不存在"}'),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/works') {
        return http.Response.bytes(
          utf8.encode(
            '{"items":[{"id":"job-completed","output":"/outputs/done.mp4"}]}',
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('', 500);
    });
    final service = MiniMaxVideoApiService(client: client);
    const config = VideoGenerationApiConfig(
      id: 'minimax',
      name: 'MiniMax H3 本地',
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: '',
      model: 'minimax-h3-local',
    );

    final result = await service.queryTask(
      config: config,
      generationId: 'job-completed',
    );

    expect(result.status, VideoGenerationTaskStatus.completed);
    expect(result.url, 'http://127.0.0.1:7860/outputs/done.mp4');
    expect(requests, ['/api/jobs/job-completed', '/api/works']);
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

    test('MiniMax 本地视频 API 默认等待上限对齐后端长任务', () {
      expect(defaultVideoGenerationPollTimeout, const Duration(minutes: 15));
      expect(localVideoApiPollTimeout, const Duration(hours: 2));
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

    test('MiniMax 恢复查询遇到任务不存在会立即结束等待并标记可重试', () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/api/works') {
          return http.Response('{"items":[]}', 200);
        }
        expect(request.url.path, '/api/jobs/missing-job');
        return http.Response.bytes(
          utf8.encode('{"detail":"任务不存在"}'),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      const config = VideoGenerationApiConfig(
        id: 'minimax',
        name: 'MiniMax H3 本地',
        baseUrl: 'http://127.0.0.1:7860',
        apiKey: '',
        model: 'minimax-h3-local',
      );
      final now = DateTime.utc(2026, 8, 4);
      final staleTask = _task(1).copyWith(
        generationId: 'missing-job',
        status: VideoGenerationTaskStatus.running,
        localPath: '${root.path}/result-1.mp4',
        updatedAt: now,
      );
      repository.upsertTask(staleTask);

      final recovered = await VideoGenerationTaskService(
        repository: repository,
        cliService: const KlingCliService(),
        videoApiConfig: config,
        videoApiService: MiniMaxVideoApiService(client: client),
        pollInterval: Duration.zero,
        delay: (_) {
          fail('任务不存在时不应继续等待下一轮轮询');
        },
      ).resumePending(outputForTask: (_) => File('${root.path}/result-1.mp4'));

      expect(requests, ['/api/jobs/missing-job', '/api/works']);
      expect(recovered.single.status, VideoGenerationTaskStatus.failed);
      expect(
        VideoGenerationTaskService.shouldRetryMissingVideoApiTask(
          recovered.single,
        ),
        isTrue,
      );
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

    test('批量生成指定并发 1 时按队列串行提交', () async {
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
      ], concurrency: localVideoApiBatchConcurrency);

      expect(results, hasLength(3));
      expect(maximumSubmissions, 1);
      expect(results.map((task) => task.generationId), [
        'generation-1',
        'generation-2',
        'generation-3',
      ]);
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
