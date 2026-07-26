import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../domain/grid_cut_models.dart';

class GridCropService {
  const GridCropService();

  Future<List<String>> exportCells({
    required Uint8List bytes,
    required GridLayout layout,
    required Iterable<int> cellIndexes,
    required Directory outputDirectory,
    required String baseName,
  }) async {
    final transferable = TransferableTypedData.fromList([bytes]);
    final xLines = List<int>.from(layout.xLines);
    final yLines = List<int>.from(layout.yLines);
    final indexes = cellIndexes.toList(growable: false);
    final outputPath = outputDirectory.path;
    return Isolate.run(
      () => _exportCellsInWorker(
        transferable: transferable,
        imageWidth: layout.imageWidth,
        imageHeight: layout.imageHeight,
        xLines: xLines,
        yLines: yLines,
        confidence: layout.confidence,
        usedFallback: layout.usedFallback,
        cellIndexes: indexes,
        outputPath: outputPath,
        baseName: baseName,
      ),
    );
  }
}

Future<List<String>> _exportCellsInWorker({
  required TransferableTypedData transferable,
  required int imageWidth,
  required int imageHeight,
  required List<int> xLines,
  required List<int> yLines,
  required double confidence,
  required bool usedFallback,
  required List<int> cellIndexes,
  required String outputPath,
  required String baseName,
}) async {
  final bytes = transferable.materialize().asUint8List();
  final image = img.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('无法解析图片');
  }
  final layout = GridLayout(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    xLines: xLines,
    yLines: yLines,
    confidence: confidence,
    usedFallback: usedFallback,
  );
  final outputDirectory = Directory(outputPath);
  if (!outputDirectory.existsSync()) {
    await outputDirectory.create(recursive: true);
  }
  final exported = <String>[];
  for (final cellIndex in cellIndexes) {
    final cell = layout.cellAt(cellIndex);
    final gridNumber = cellIndex + 1;
    final cropped = img.copyCrop(
      image,
      x: cell.x,
      y: cell.y,
      width: cell.width,
      height: cell.height,
    );
    final file = File(p.join(outputPath, '$baseName$gridNumber.png'));
    await file.writeAsBytes(img.encodePng(cropped));
    exported.add(file.path);
  }
  return exported;
}
