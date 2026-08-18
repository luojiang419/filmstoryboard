import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../domain/replicate_asset_preparation_models.dart';

class FullOutfitSplitView {
  const FullOutfitSplitView({required this.role, required this.path});

  final ReplicateOutfitViewRole role;
  final String path;
}

class FullOutfitCollageSplitter {
  const FullOutfitCollageSplitter();

  static const minimumPanelSize = 64;
  static const minimumHorizontalAspectRatio = 2.2;

  Future<List<FullOutfitSplitView>> splitHorizontalThreeView({
    required File source,
    required Directory outputDirectory,
    required String outputStem,
  }) async {
    if (!source.existsSync()) {
      throw const FormatException('完整穿搭三视图拼图文件不存在');
    }
    final decoded = img.decodeImage(await source.readAsBytes());
    if (decoded == null) {
      throw const FormatException('无法读取完整穿搭三视图拼图');
    }
    if (decoded.width < minimumPanelSize * 3 ||
        decoded.height < minimumPanelSize ||
        decoded.width / decoded.height < minimumHorizontalAspectRatio) {
      throw const FormatException('所选图片不像横向三栏拼图，请分别上传正面、侧面和背面视图');
    }

    const roles = [
      ReplicateOutfitViewRole.front,
      ReplicateOutfitViewRole.side,
      ReplicateOutfitViewRole.back,
    ];
    final crops = <({ReplicateOutfitViewRole role, img.Image image})>[];
    for (var index = 0; index < roles.length; index++) {
      final left = (decoded.width * index / 3).round();
      final right = (decoded.width * (index + 1) / 3).round();
      final width = right - left;
      if (width < minimumPanelSize) {
        throw const FormatException('横向三栏拼图的单栏宽度过小');
      }
      crops.add((
        role: roles[index],
        image: img.copyCrop(
          decoded,
          x: left,
          y: 0,
          width: width,
          height: decoded.height,
        ),
      ));
    }

    await outputDirectory.create(recursive: true);
    final safeStem = outputStem.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final result = <FullOutfitSplitView>[];
    for (final crop in crops) {
      final target = File(
        p.join(outputDirectory.path, '${safeStem}_${crop.role.name}.png'),
      );
      await target.writeAsBytes(img.encodePng(crop.image), flush: true);
      result.add(FullOutfitSplitView(role: crop.role, path: target.path));
    }
    return List.unmodifiable(result);
  }
}
