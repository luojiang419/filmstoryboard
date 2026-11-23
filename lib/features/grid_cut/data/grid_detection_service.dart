import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/grid_cut_models.dart';

class GridDetectionService {
  const GridDetectionService();

  Future<GridLayout> detectAsync(Uint8List bytes) async {
    final transferable = TransferableTypedData.fromList([bytes]);
    final data = await Isolate.run(() => _detectGridInWorker(transferable));
    return GridLayout(
      imageWidth: data['imageWidth']! as int,
      imageHeight: data['imageHeight']! as int,
      xLines: List<int>.from(data['xLines']! as List),
      yLines: List<int>.from(data['yLines']! as List),
      confidence: data['confidence']! as double,
      usedFallback: data['usedFallback']! as bool,
    );
  }

  GridLayout detect(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw const FormatException('无法解析图片');
    }

    final xLines = _detectAxis(
      length: image.width,
      crossLength: image.height,
      sample: (x, y) => _luminance(image.getPixel(x, y)),
    );
    final yLines = _detectAxis(
      length: image.height,
      crossLength: image.width,
      sample: (y, x) => _luminance(image.getPixel(x, y)),
    );

    final separatorCount =
        math.max(0, xLines.length - 2) + math.max(0, yLines.length - 2);
    final detected = separatorCount > 0;
    final confidence = detected
        ? math.min(0.95, 0.5 + separatorCount * 0.07)
        : 0.0;
    return GridLayout(
      imageWidth: image.width,
      imageHeight: image.height,
      xLines: xLines,
      yLines: yLines,
      confidence: confidence,
      usedFallback: !detected,
    );
  }

  GridLayout evenGrid({
    required int imageWidth,
    required int imageHeight,
    required int rows,
    required int columns,
  }) {
    final xLines = [
      for (var i = 0; i <= columns; i++) (imageWidth * i / columns).round(),
    ];
    final yLines = [
      for (var i = 0; i <= rows; i++) (imageHeight * i / rows).round(),
    ];
    return GridLayout(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      xLines: _normalizeLines(xLines, imageWidth),
      yLines: _normalizeLines(yLines, imageHeight),
      confidence: 0.35,
      usedFallback: true,
    );
  }

  List<int> _detectAxis({
    required int length,
    required int crossLength,
    required int Function(int axis, int cross) sample,
  }) {
    final step = math.max(1, crossLength ~/ 640);
    final scores = List<double>.filled(length, 0);
    final averages = List<double>.filled(length, 0);

    for (var axis = 0; axis < length; axis++) {
      var sum = 0.0;
      var sumSquares = 0.0;
      var count = 0;
      for (var cross = 0; cross < crossLength; cross += step) {
        final value = sample(axis, cross).toDouble();
        sum += value;
        sumSquares += value * value;
        count++;
      }
      final average = sum / count;
      final variance = math.max(0, (sumSquares / count) - average * average);
      final deviation = math.sqrt(variance);
      final whiteness = average > 232
          ? ((average - 232) / 23).clamp(0, 1).toDouble()
          : 0.0;
      final darkness = average < 32
          ? ((32 - average) / 32).clamp(0, 1).toDouble()
          : 0.0;
      final uniformity = (1 - deviation / 70).clamp(0, 1).toDouble();
      averages[axis] = average;
      scores[axis] = math.max(whiteness, darkness) * uniformity;
    }

    for (var axis = 1; axis < length - 1; axis++) {
      final gradient = ((averages[axis - 1] - averages[axis + 1]).abs() / 255)
          .clamp(0, 1)
          .toDouble();
      scores[axis] = math.max(scores[axis], gradient * 0.8);
    }

    final clusters = <_LineCluster>[];
    var start = -1;
    var bestScore = 0.0;
    var bestIndex = 0;
    for (var i = 1; i < length - 1; i++) {
      if (scores[i] >= 0.56) {
        if (start == -1) {
          start = i;
          bestScore = scores[i];
          bestIndex = i;
        } else if (scores[i] > bestScore) {
          bestScore = scores[i];
          bestIndex = i;
        }
      } else if (start != -1) {
        clusters.add(_LineCluster(start, i - 1, bestIndex, bestScore));
        start = -1;
      }
    }
    if (start != -1) {
      clusters.add(_LineCluster(start, length - 2, bestIndex, bestScore));
    }

    final minGap = math.max(24, (length * 0.035).round());
    final lines = <int>[0];
    for (final cluster in clusters) {
      final center = ((cluster.start + cluster.end) / 2).round();
      if (center - lines.last >= minGap && length - center >= minGap) {
        lines.add(center);
      }
    }
    lines.add(length);
    return _normalizeLines(lines, length);
  }

  List<int> _normalizeLines(List<int> lines, int maxValue) {
    final normalized =
        lines.map((line) => line.clamp(0, maxValue).toInt()).toSet().toList()
          ..sort();
    if (normalized.first != 0) {
      normalized.insert(0, 0);
    }
    if (normalized.last != maxValue) {
      normalized.add(maxValue);
    }
    return normalized;
  }

  int _luminance(img.Pixel pixel) {
    return (pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114).round();
  }
}

class _LineCluster {
  const _LineCluster(this.start, this.end, this.bestIndex, this.score);

  final int start;
  final int end;
  final int bestIndex;
  final double score;
}

Map<String, Object> _detectGridInWorker(TransferableTypedData transferable) {
  final bytes = transferable.materialize().asUint8List();
  late final GridLayout layout;
  try {
    layout = const GridDetectionService().detect(bytes);
  } catch (_) {
    throw const FormatException('无法解析图片');
  }
  return {
    'imageWidth': layout.imageWidth,
    'imageHeight': layout.imageHeight,
    'xLines': layout.xLines,
    'yLines': layout.yLines,
    'confidence': layout.confidence,
    'usedFallback': layout.usedFallback,
  };
}
