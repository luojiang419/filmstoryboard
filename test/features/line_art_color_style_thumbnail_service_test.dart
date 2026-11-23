import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/line_art_color_style_thumbnail_service.dart';
import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory assets;
  late LineArtColorStyleThumbnailService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('color_style_thumbnail_');
    assets = Directory(p.join(root.path, 'assets'));
    service = LineArtColorStyleThumbnailService(
      projectRoot: root,
      projectAssetsRoot: assets,
      now: () => DateTime.utc(2026, 8, 21, 8),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('导入图片时中心裁切并生成960x540项目托管JPEG', () async {
    final sourceImage = img.Image(width: 1200, height: 1200);
    img.fill(sourceImage, color: img.ColorRgb8(40, 80, 120));
    final source = File(p.join(root.path, 'source.png'));
    await source.writeAsBytes(img.encodePng(sourceImage));

    final imported = await service.importThumbnail(
      presetId: '../客户 红毯',
      source: source,
    );

    expect(imported.reference.type, ColorStyleThumbnailType.projectFile);
    expect(imported.reference.path, startsWith('assets'));
    expect(await imported.file.exists(), isTrue);
    expect(
      p.isWithin(
        p.normalize(service.managedDirectory.path),
        p.normalize(imported.file.path),
      ),
      isTrue,
    );
    final decoded = img.decodeJpg(await imported.file.readAsBytes())!;
    expect(decoded.width, LineArtColorStyleThumbnailService.thumbnailWidth);
    expect(decoded.height, LineArtColorStyleThumbnailService.thumbnailHeight);
    expect(
      service.resolveProjectFile(imported.reference).path,
      imported.file.path,
    );
  });

  test('拒绝伪图片、无效扩展名和超过10MB的文件', () async {
    final fakeJpg = File(p.join(root.path, 'fake.jpg'));
    await fakeJpg.writeAsString('not an image');
    await expectLater(
      service.importThumbnail(presetId: 'fake', source: fakeJpg),
      throwsA(isA<FormatException>()),
    );

    final unsupported = File(p.join(root.path, 'source.gif'));
    await unsupported.writeAsBytes([1, 2, 3]);
    await expectLater(
      service.importThumbnail(presetId: 'gif', source: unsupported),
      throwsA(isA<FormatException>()),
    );

    final oversized = File(p.join(root.path, 'large.png'));
    await oversized.writeAsBytes(
      List<int>.filled(LineArtColorStyleThumbnailService.maxSourceBytes + 1, 0),
    );
    await expectLater(
      service.importThumbnail(presetId: 'large', source: oversized),
      throwsA(isA<FormatException>()),
    );
  });

  test('仅允许解析和删除项目托管目录内的缩略图', () async {
    final outside = File(p.join(root.path, 'do-not-delete.jpg'));
    await outside.writeAsBytes([1, 2, 3]);
    final traversal = ColorStyleThumbnailReference.projectFile(
      p.join(
        'assets',
        'color_style_thumbnails',
        '..',
        '..',
        '..',
        'do-not-delete.jpg',
      ),
    );

    expect(
      () => service.resolveProjectFile(traversal),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      service.removeManagedThumbnail(traversal),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.exists(), isTrue);

    final sourceImage = img.Image(width: 32, height: 18);
    final source = File(p.join(root.path, 'valid.jpg'));
    await source.writeAsBytes(img.encodeJpg(sourceImage));
    final imported = await service.importThumbnail(
      presetId: 'valid',
      source: source,
    );
    await service.removeManagedThumbnail(imported.reference);
    expect(await imported.file.exists(), isFalse);
  });
}
