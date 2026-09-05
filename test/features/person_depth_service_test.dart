import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/person_depth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
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

    PersonDepthService.createPreview(masterPath, previewPath, 3, 2);

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

  test('深度组件解析要求 worker 与两组模型同时存在', () async {
    final root = await Directory.systemTemp.createTemp(
      'person_depth_component_',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = PersonDepthService(componentRoot: root);
    expect(service.resolveComponent(), throwsStateError);

    for (final relative in [
      p.join('runtime', 'person-depth-worker.exe'),
      p.join('models', 'depth-anything-v2-large', 'model.safetensors'),
      p.join('models', 'birefnet', 'model.safetensors'),
    ]) {
      final file = File(p.join(root.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([1]);
    }
    expect((await service.resolveComponent()).path, root.absolute.path);
  });
}
