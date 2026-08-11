import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/video_generation/data/libtv_cli_models.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_resolver.dart';
import 'package:filmstoryboard/features/video_generation/data/libtv_cli_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LibTV resolver 优先使用 PATH 中的命令并读取版本', () async {
    final calls = <List<String>>[];
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calls.add([executable, ...arguments]);
      if (executable == (Platform.isWindows ? 'where.exe' : 'which')) {
        return ProcessResult(1, 0, r'C:\Users\tester\.libtv\libtv.exe', '');
      }
      return ProcessResult(2, 0, '1.1.3', '');
    }

    final environment = await LibTvCliResolver(
      processRunner: runner,
      fallbackCandidates: const [],
    ).resolve();

    expect(environment.isReady, isTrue);
    expect(environment.version, '1.1.3');
    expect(calls.last, contains('--version'));
  });

  test('LibTV service 解析账号与 Seedance 2.0 模型', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      if (arguments.first == 'account') {
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'user': {'uuid': 'user-1', 'nickname': '测试用户'},
            'activeAccount': {'accountName': '个人空间', 'teamId': 0},
            'teamId': 0,
          }),
          '',
        );
      }
      return ProcessResult(
        2,
        0,
        jsonEncode({
          'modelName': 'Seedance 2.0',
          'modelKey': 'star-video2',
          'modality': 'video',
          'schema': {
            'config': {'settings': []},
          },
        }),
        '',
      );
    }

    final service = LibTvCliService(processRunner: runner);
    final account = await service.accountInfo();
    final model = await service.model('Seedance 2.0');

    expect(account.userId, 'user-1');
    expect(account.accountName, '个人空间');
    expect(model.modelKey, 'star-video2');
  });

  test('即梦图片引用会转换为 LibTV 节点引用并补齐未引用首帧', () {
    expect(
      LibTvCliService.promptWithNodeReferences(
        '镜头1：图片1中的女孩走向@图片2，保持无字幕。',
        const ['node-a', 'node-b'],
      ),
      '镜头1：{{Node node-a}}中的女孩走向{{Node node-b}}，保持无字幕。',
    );
    expect(
      LibTvCliService.promptWithNodeReferences('固定镜头，人物缓慢抬手。', const [
        'node-a',
      ]),
      startsWith('参考{{Node node-a}}作为起始画面'),
    );
  });

  test('生成链路复用脚本画布、上传图片并同步读取视频结果', () async {
    final root = await Directory.systemTemp.createTemp('libtv-service-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.png')
      ..writeAsBytesSync([1, 2, 3]);
    final calls = <List<String>>[];
    var uploadIndex = 0;
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calls.add(arguments);
      if (arguments.take(2).join(' ') == 'project list') {
        return ProcessResult(1, 0, jsonEncode({'projects': []}), '');
      }
      if (arguments.take(2).join(' ') == 'project create') {
        return ProcessResult(2, 0, jsonEncode({'uuid': 'project-1'}), '');
      }
      if (arguments.first == 'upload') {
        uploadIndex += 1;
        return ProcessResult(
          3,
          0,
          jsonEncode({'nodeKey': 'image-$uploadIndex'}),
          '',
        );
      }
      fail('unexpected command: $arguments');
    }

    Future<LibTvRunningProcess> starter(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      calls.add(arguments);
      return LibTvRunningProcess(
        exitCode: Future.value(0),
        kill: ([signal = ProcessSignal.sigterm]) => true,
        stdout: () => jsonEncode({
          'nodeKey': 'video-1',
          'taskId': 'remote-task-1',
          'data': {
            'results': [
              {'url': 'https://cdn.example.com/result.mp4'},
            ],
          },
        }),
        stderr: () => '',
      );
    }

    final result =
        await LibTvCliService(
          processRunner: runner,
          processStarter: starter,
        ).generateImageToVideo(
          scriptId: 'script-1234567890',
          scriptName: '测试脚本',
          taskId: 'task-1234567890',
          prompt: '镜头1：图片1中的人物缓慢转头。',
          sourceImagePath: source.path,
          ratio: 'adaptive',
          resolution: '480p',
          durationSeconds: 5,
          enableSound: false,
          searchEnabled: false,
        );

    expect(result.projectUuid, 'project-1');
    expect(result.videoUrl, 'https://cdn.example.com/result.mp4');
    final generateCall = calls.last;
    expect(generateCall, containsAllInOrder(['node', 'create']));
    expect(generateCall, contains('model=Seedance 2.0'));
    expect(generateCall, contains('ratio=adaptive'));
    expect(generateCall, contains('resolution=480p'));
    expect(generateCall, contains('enableSound=off'));
    expect(generateCall, contains('search_enabled=0'));
    final promptIndex = generateCall.indexOf('--prompt');
    expect(promptIndex, greaterThanOrEqualTo(0));
    expect(
      generateCall[promptIndex + 1],
      contains('{{Node image-1}}中的人物缓慢转头。'),
    );
    expect(generateCall, containsAllInOrder(['--left', 'image-1', '--run']));
  });

  test('生成等待期间取消会终止 CLI 进程', () async {
    final root = await Directory.systemTemp.createTemp('libtv-cancel-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.png')
      ..writeAsBytesSync([1]);
    var killed = false;
    var canceled = false;
    final never = Completer<int>();
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      required bool runInShell,
    }) async {
      if (arguments.take(2).join(' ') == 'project list') {
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'projects': [
              {
                'name': LibTvCliService.scriptProjectName('script-1', '测试'),
                'uuid': 'project-1',
              },
            ],
          }),
          '',
        );
      }
      return ProcessResult(2, 0, jsonEncode({'nodeKey': 'image-1'}), '');
    }

    final service = LibTvCliService(
      processRunner: runner,
      processStarter: (executable, arguments, {required runInShell}) async =>
          LibTvRunningProcess(
            exitCode: never.future,
            kill: ([signal = ProcessSignal.sigterm]) {
              killed = true;
              return true;
            },
            stdout: () => '',
            stderr: () => '',
          ),
      delay: (_) async => canceled = true,
    );

    await expectLater(
      service.generateImageToVideo(
        scriptId: 'script-1',
        scriptName: '测试',
        taskId: 'task-1',
        prompt: '测试',
        sourceImagePath: source.path,
        durationSeconds: 5,
        isCanceled: () => canceled,
      ),
      throwsA(isA<LibTvGenerationCanceledException>()),
    );
    expect(killed, isTrue);
  });
}
