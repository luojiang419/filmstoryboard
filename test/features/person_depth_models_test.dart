import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:filmstoryboard/features/replicate/data/person_depth_models.dart';
import 'package:filmstoryboard/features/replicate/presentation/depth_model_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    '官方固定 revision 真实断点续传与完整 SHA-256',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'depth-real-download-',
      );
      try {
        for (final spec in PersonDepthModels.defaults) {
          final source = File(
            p.join(Platform.environment['DEPTH_MODEL_SOURCE']!, spec.path),
          );
          final part = File(p.join(root.path, 'models', '${spec.path}.part'));
          await part.parent.create(recursive: true);
          await source
              .openRead(0, spec.size - 1024 * 1024)
              .pipe(part.openWrite());
        }
        final progress = <DepthModelProgress>[];
        await PersonDepthModels(
          clientFactory: () => _RealHttpOverrides().createHttpClient(null),
        ).ensure(root, progress.add);
        expect(progress.last.percent, 100);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['DEPTH_MODEL_SOURCE'] == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  for (final behavior in [
    'fresh',
    'resume',
    'ignore-range',
    'corrupt',
    'retry',
  ]) {
    test('模型下载与完整性验证：$behavior', () async {
      final root = await Directory.systemTemp.createTemp('depth-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List.generate(4096, (i) => i % 256);
      final target = File(
        p.join(root.path, 'models', 'test', 'model.safetensors'),
      );
      final part = File('${target.path}.part');
      await target.parent.create(recursive: true);
      if (behavior == 'resume' || behavior == 'ignore-range') {
        await part.writeAsBytes(bytes.sublist(0, 1024));
      }
      if (behavior == 'corrupt') {
        await target.writeAsBytes(List.filled(bytes.length, 1));
      }
      var requests = 0;
      final ranges = <String?>[];
      server.listen((request) async {
        requests++;
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        if (behavior == 'retry' && requests == 1) {
          request.response.statusCode = 503;
        } else if (behavior == 'resume') {
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 1024-4095/4096',
          );
          request.response.add(bytes.sublist(1024));
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final downloader = PersonDepthModels(
        clientFactory: () => _RealHttpOverrides().createHttpClient(null),
        files: [
          DepthModelFile(
            'test/model.safetensors',
            'http://127.0.0.1:${server.port}/model',
            bytes.length,
            sha256.convert(bytes).toString(),
          ),
        ],
      );
      final progress = <DepthModelProgress>[];
      await downloader.ensure(root, progress.add);
      expect(await target.readAsBytes(), bytes);
      expect(await part.exists(), isFalse);
      expect(progress.last.percent, 100);
      expect(
        progress.take(progress.length - 1).every((v) => v.percent < 100),
        isTrue,
      );
      if (behavior == 'resume' || behavior == 'ignore-range') {
        expect(ranges.first, 'bytes=1024-');
      }
      if (behavior == 'retry') expect(requests, 2);
      final before = requests;
      await downloader.ensure(root, progress.add);
      expect(requests, before, reason: '有效模型不应重复下载');
    });
  }

  test('错误 SHA-256 不会覆盖已有模型，也不会报告 100%', () async {
    final root = await Directory.systemTemp.createTemp('depth-bad-hash-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final target = File(p.join(root.path, 'models', 'model'));
    await target.parent.create(recursive: true);
    await target.writeAsBytes([9, 9, 9]);
    final progress = <DepthModelProgress>[];
    await expectLater(
      PersonDepthModels(
        clientFactory: () => _RealHttpOverrides().createHttpClient(null),
        files: [
          DepthModelFile(
            'model',
            'http://127.0.0.1:${server.port}/model',
            3,
            sha256.convert([4, 5, 6]).toString(),
          ),
        ],
      ).ensure(root, progress.add),
      throwsStateError,
    );
    expect(await target.readAsBytes(), [9, 9, 9]);
    expect(progress.every((v) => v.percent < 100), isTrue);
  });

  testWidgets('下载百分比与进度条同步，校验完成显示 100%', (tester) async {
    final progress = ValueNotifier<DepthModelProgress?>(null);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DepthModelProgressPanel(progress: progress)),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    progress.value = const DepthModelProgress('正在下载', 37, 100);
    await tester.pump();
    expect(find.text('37%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .37,
    );
    progress.value = const DepthModelProgress('模型已就绪', 100, 100);
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
  });
}

class _RealHttpOverrides extends HttpOverrides {}
