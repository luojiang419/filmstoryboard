import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/full_outfit_collage_splitter.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('横向三视图只在本地按三栏拆成独立正侧背文件', () async {
    final root = await Directory.systemTemp.createTemp('outfit_split_');
    addTearDown(() => root.delete(recursive: true));
    final source = File(p.join(root.path, 'three-view.png'));
    final image = img.Image(width: 300, height: 100);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        if (x < 100) {
          image.setPixelRgb(x, y, 255, 0, 0);
        } else if (x < 200) {
          image.setPixelRgb(x, y, 0, 255, 0);
        } else {
          image.setPixelRgb(x, y, 0, 0, 255);
        }
      }
    }
    await source.writeAsBytes(img.encodePng(image));

    final views = await const FullOutfitCollageSplitter()
        .splitHorizontalThreeView(
          source: source,
          outputDirectory: Directory(p.join(root.path, 'views')),
          outputStem: 'model-a',
        );

    expect(views.map((view) => view.role), const [
      ReplicateOutfitViewRole.front,
      ReplicateOutfitViewRole.side,
      ReplicateOutfitViewRole.back,
    ]);
    expect(views.map((view) => view.path).toSet(), hasLength(3));
    final front = img.decodeImage(await File(views[0].path).readAsBytes())!;
    final side = img.decodeImage(await File(views[1].path).readAsBytes())!;
    final back = img.decodeImage(await File(views[2].path).readAsBytes())!;
    expect((front.width, front.height), (100, 100));
    expect(front.getPixel(0, 0).r, 255);
    expect(side.getPixel(0, 0).g, 255);
    expect(back.getPixel(0, 0).b, 255);
  });

  test('非横向三栏图片拒绝静默拆分', () async {
    final root = await Directory.systemTemp.createTemp('outfit_split_reject_');
    addTearDown(() => root.delete(recursive: true));
    final source = File(p.join(root.path, 'single.png'));
    await source.writeAsBytes(
      img.encodePng(img.Image(width: 128, height: 128)),
    );
    final output = Directory(p.join(root.path, 'views'));

    await expectLater(
      const FullOutfitCollageSplitter().splitHorizontalThreeView(
        source: source,
        outputDirectory: output,
        outputStem: 'single',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(output.existsSync(), isFalse);
  });
}
