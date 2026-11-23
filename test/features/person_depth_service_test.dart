import 'dart:io';
import 'dart:convert';

import 'package:filmstoryboard/features/replicate/data/person_depth_service.dart';
import 'package:filmstoryboard/features/replicate/data/depth_map_configuration.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('人物与专业模式参数分开保存', () async {
    final root = await Directory.systemTemp.createTemp('depth_config_');
    addTearDown(() => root.delete(recursive: true));
    final store = DepthMapConfigurationStore(
      File(p.join(root.path, 'depth.json')),
    );
    await store.save(
      const DepthMapConfiguration(
        person: DepthMapControls(contrast: 122, smooth: 2),
        professional: DepthMapControls(
          farPoint: 8,
          nearPoint: 92,
          brightness: 12,
        ),
      ),
    );

    final restored = await store.load();
    expect(restored.controlsFor(DepthProcessingMode.person).contrast, 122);
    expect(restored.controlsFor(DepthProcessingMode.professional).farPoint, 8);
    expect(
      restored.controlsFor(DepthProcessingMode.professional).brightness,
      12,
    );
  });

  test('中文和非 BMP 路径通过 ASCII JSON 无损传给 Windows worker', () {
    final payload = {'input': r'G:\DATA\影视复刻 (2)\镜头😀.jpg'};
    final wire = PersonDepthService.encodeRequest(payload);
    expect(wire.codeUnits.every((unit) => unit < 128), isTrue);
    expect(jsonDecode(wire), payload);
  });

  test(
    '真实安装版通过 Dart 服务生成中文路径原帧深度和预览',
    () async {
      final service = PersonDepthService(
        componentRoot: Directory(Platform.environment['DEPTH_COMPONENT']!),
      );
      final target = await Directory.systemTemp.createTemp('深度通信验证-');
      try {
        final result = await service.extract(
          imageFile: File(Platform.environment['DEPTH_INPUT']!),
          outputFile: File(p.join(target.path, '中文深度.png')),
        );
        expect(result.width, 1920);
        expect(result.height, 1080);
        expect(
          img.decodePng(await result.depthFile.readAsBytes())!.format,
          img.Format.uint8,
        );
        expect(
          img.decodePng(await result.masterFile.readAsBytes())!.format,
          img.Format.uint16,
        );
      } finally {
        service.close();
        await target.delete(recursive: true);
      }
    },
    skip: Platform.environment['DEPTH_INPUT'] == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('16-bit 原尺寸深度母版转换为无损灰度 PNG', () async {
    final root = await Directory.systemTemp.createTemp('person_depth_preview_');
    addTearDown(() => root.delete(recursive: true));
    final master = img.Image(
      width: 3,
      height: 2,
      format: img.Format.uint16,
      numChannels: 1,
    );
    master.setPixelR(0, 0, 0);
    master.setPixelR(1, 0, 32768);
    master.setPixelR(2, 0, 65535);
    final masterPath = p.join(root.path, 'shot-depth-16bit.png');
    final previewPath = p.join(root.path, 'shot-depth.png');
    File(masterPath).writeAsBytesSync(img.encodePng(master));

    await PersonDepthService.createPreviewAsync(masterPath, previewPath, 3, 2);

    final preview = img.decodePng(File(previewPath).readAsBytesSync());
    expect(preview, isNotNull);
    expect(preview!.width, 3);
    expect(preview.height, 2);
    expect(preview.format, img.Format.uint8);
    expect(preview.numChannels, 1);
    expect(preview.getPixel(0, 0).r, 0);
    expect(preview.getPixel(1, 0).r, closeTo(128, 1));
    expect(preview.getPixel(2, 0).r, 255);
  });

  test('持久化参数会改变深度预览映射', () async {
    final root = await Directory.systemTemp.createTemp('depth_lut_preview_');
    addTearDown(() => root.delete(recursive: true));
    final master =
        img.Image(
            width: 3,
            height: 1,
            format: img.Format.uint16,
            numChannels: 1,
          )
          ..setPixelR(0, 0, 0)
          ..setPixelR(1, 0, 32768)
          ..setPixelR(2, 0, 65535);
    final masterPath = p.join(root.path, 'master.png');
    final previewPath = p.join(root.path, 'preview.png');
    File(masterPath).writeAsBytesSync(img.encodePng(master));

    await PersonDepthService.createPreviewAsync(
      masterPath,
      previewPath,
      3,
      1,
      const DepthMapControls(farPoint: 25, nearPoint: 75),
    );

    final preview = img.decodePng(File(previewPath).readAsBytesSync())!;
    expect(preview.getPixel(0, 0).r, 0);
    expect(preview.getPixel(1, 0).r, closeTo(128, 1));
    expect(preview.getPixel(2, 0).r, 255);
  });

  test('深度组件解析允许模型缺失以便随后自动下载', () async {
    final root = await Directory.systemTemp.createTemp(
      'person_depth_component_',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = PersonDepthService(componentRoot: root);
    await expectLater(service.resolveComponent(), throwsStateError);

    for (final relative in [p.join('runtime', 'person-depth-worker.exe')]) {
      final file = File(p.join(root.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([1]);
    }
    expect((await service.resolveComponent()).path, root.absolute.path);
  });
}
