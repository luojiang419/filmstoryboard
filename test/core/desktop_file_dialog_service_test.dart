import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:filmstoryboard/core/services/desktop_file_dialog_service.dart';
import 'package:filmstoryboard/core/services/windows_sta_file_dialog_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory fallback;
  late List<Map<String, Object?>> events;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_dialog_service_test_');
    fallback = await Directory('${root.path}/fallback').create();
    events = [];
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('打开前让出一帧并把有效初始目录传给原生选择器', () async {
    final preferred = await Directory('${root.path}/preferred').create();
    var yielded = false;
    String? receivedDirectory;
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async => yielded = true,
      eventSink: (event) async => events.add(event),
      openFileDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            confirmButtonText,
          }) async {
            expect(yielded, isTrue);
            receivedDirectory = initialDirectory;
            return XFile('${preferred.path}/image.png');
          },
    );
    addTearDown(service.dispose);

    final result = await service.openFile(
      source: 'test.single',
      initialDirectory: preferred.path,
    );

    expect(result, isNotNull);
    expect(receivedDirectory, preferred.absolute.path);
    expect(events.map((event) => event['phase']), ['requested', 'completed']);
  });

  test('失效目录和 UNC 目录都会回退到应用本地目录', () async {
    final received = <String?>[];
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async {},
      eventSink: (event) async => events.add(event),
      openFilesDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            confirmButtonText,
          }) async {
            received.add(initialDirectory);
            return const [];
          },
    );
    addTearDown(service.dispose);

    await service.openFiles(
      source: 'test.missing',
      initialDirectory: '${root.path}/missing',
    );
    await service.openFiles(
      source: 'test.unc',
      initialDirectory: r'\\offline-server\share',
    );

    expect(received, [fallback.absolute.path, fallback.absolute.path]);
  });

  test('全局忙碌期间拒绝第二个请求且不重复打开原生窗口', () async {
    final firstResult = Completer<XFile?>();
    final firstShown = Completer<void>();
    var openFileCalls = 0;
    var openFilesCalls = 0;
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async {},
      eventSink: (event) async => events.add(event),
      openFileDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            confirmButtonText,
          }) {
            openFileCalls += 1;
            firstShown.complete();
            return firstResult.future;
          },
      openFilesDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            confirmButtonText,
          }) async {
            openFilesCalls += 1;
            return const [];
          },
    );
    addTearDown(service.dispose);

    final first = service.openFile(source: 'test.first');
    await firstShown.future;
    expect(service.isBusy.value, isTrue);

    final second = await service.openFiles(source: 'test.second');
    expect(second, isEmpty);
    expect(openFileCalls, 1);
    expect(openFilesCalls, 0);
    expect(events.any((event) => event['phase'] == 'rejected_busy'), isTrue);

    firstResult.complete(null);
    await first;
    expect(service.isBusy.value, isFalse);
  });

  test('慢请求只记录 watchdog 告警并等待真实结果', () async {
    final result = Completer<XFile?>();
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async {},
      warningThresholds: const [Duration(milliseconds: 5)],
      eventSink: (event) async => events.add(event),
      openFileDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            confirmButtonText,
          }) => result.future,
    );
    addTearDown(service.dispose);

    final request = service.openFile(source: 'test.slow');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.any((event) => event['phase'] == 'slow'), isTrue);
    expect(service.isBusy.value, isTrue);

    result.complete(null);
    await request;
    expect(events.last['phase'], 'completed');
  });

  test('原生异常会释放全局锁并保留失败事件', () async {
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async {},
      eventSink: (event) async => events.add(event),
      saveFileDialog:
          ({
            acceptedTypeGroups = const [],
            initialDirectory,
            suggestedName,
            confirmButtonText,
            canCreateDirectories,
          }) => throw StateError('dialog failed'),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.getSaveLocation(source: 'test.failure'),
      throwsStateError,
    );

    expect(service.isBusy.value, isFalse);
    expect(events.last['phase'], 'failed');
  });

  test('Windows 默认路由把多选参数发送到独立 STA MethodChannel', () async {
    const channel = MethodChannel('filmstoryboard/native_file_dialog');
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object?>{
            'cancelled': false,
            'paths': <String>['${fallback.path}/one.png'],
            'activeFilterIndex': 0,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = DesktopFileDialogService(
      defaultDirectory: fallback,
      beforeShow: () async {},
      eventSink: (event) async => events.add(event),
      useWindowsStaFileDialog: true,
      windowsStaFileDialogClient: const WindowsStaFileDialogClient(
        channel: channel,
      ),
    );
    addTearDown(service.dispose);
    const typeGroup = XTypeGroup(label: 'Images', extensions: ['.png', 'jpg']);

    final result = await service.openFiles(
      source: 'test.windows_route',
      acceptedTypeGroups: const [typeGroup],
      confirmButtonText: '导入',
    );

    expect(receivedCall?.method, 'openFiles');
    final arguments = receivedCall?.arguments as Map<Object?, Object?>;
    expect(arguments['initialDirectory'], fallback.absolute.path);
    expect(arguments['confirmButtonText'], '导入');
    expect(arguments['suggestedName'], isNull);
    expect(arguments['filters'], [
      <String, Object?>{
        'label': 'Images',
        'extensions': <String>['png', 'jpg'],
      },
    ]);
    expect(result.single.path, '${fallback.path}/one.png');
    expect(events.map((event) => event['phase']), ['requested', 'completed']);
  });

  test('Windows 保存结果保留建议文件名和活动过滤器', () async {
    const channel = MethodChannel('filmstoryboard/native_file_dialog');
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object?>{
            'cancelled': false,
            'paths': <String>['${fallback.path}/story.pdf'],
            'activeFilterIndex': 1,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    const groups = [
      XTypeGroup(label: 'Text', extensions: ['txt']),
      XTypeGroup(label: 'PDF', extensions: ['pdf']),
    ];
    const client = WindowsStaFileDialogClient(channel: channel);

    final result = await client.getSaveLocation(
      acceptedTypeGroups: groups,
      initialDirectory: fallback.path,
      suggestedName: 'story.pdf',
      confirmButtonText: '保存',
    );

    expect(receivedCall?.method, 'save');
    final arguments = receivedCall?.arguments as Map<Object?, Object?>;
    expect(arguments['suggestedName'], 'story.pdf');
    expect(arguments['confirmButtonText'], '保存');
    expect(result?.path, '${fallback.path}/story.pdf');
    expect(result?.activeFilter, same(groups[1]));
  });

  test('Windows 客户端沿用 file_selector 的扩展名过滤器校验', () async {
    const client = WindowsStaFileDialogClient();

    await expectLater(
      client.openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Images', mimeTypes: ['image/png']),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('业务代码不再绕过统一服务直接打开文件对话框', () {
    final directCall = RegExp(
      r'(^|[^\w.])(openFile|openFiles|getSaveLocation)\s*\(',
      multiLine: true,
    );
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File ||
          !entity.path.endsWith('.dart') ||
          (entity.path.endsWith('desktop_file_dialog_service.dart') ||
              entity.path.endsWith('windows_sta_file_dialog_client.dart'))) {
        continue;
      }
      if (directCall.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });
}
