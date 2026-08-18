import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'dwpose_model_manager.dart';

class DwPosePoint {
  const DwPosePoint(this.x, this.y, this.score);

  final double x;
  final double y;
  final double score;
}

class DwPoseBox {
  const DwPoseBox(this.left, this.top, this.right, this.bottom, this.score);

  final double left;
  final double top;
  final double right;
  final double bottom;
  final double score;

  double get area =>
      math.max(0, right - left + 1) * math.max(0, bottom - top + 1);
}

class DwPoseExtractionResult {
  const DwPoseExtractionResult({
    required this.skeletonFile,
    required this.personCount,
  });

  final File skeletonFile;
  final int personCount;
}

class DwPoseService {
  DwPoseService({OnnxRuntime? runtime}) : _runtime = runtime ?? OnnxRuntime();

  static const detectorSize = 640;
  static const poseWidth = 288;
  static const poseHeight = 384;
  static const simccSplitRatio = 2.0;
  static const keypointThreshold = 0.3;

  final OnnxRuntime _runtime;
  OrtSession? _detectorSession;
  OrtSession? _poseSession;

  Future<DwPoseExtractionResult> extract({
    required File imageFile,
    required File outputFile,
    required DwPoseModelFiles models,
  }) async {
    final decoded = img.decodeImage(await imageFile.readAsBytes());
    if (decoded == null) {
      throw const FormatException('DWPose 无法读取原视频帧');
    }
    final source = img.bakeOrientation(decoded);
    await _ensureSessions(models);
    final boxes = await _detectPeople(source);
    final effectiveBoxes = boxes.isEmpty
        ? [
            DwPoseBox(
              0,
              0,
              source.width.toDouble(),
              source.height.toDouble(),
              1,
            ),
          ]
        : boxes;
    final people = <List<DwPosePoint>>[];
    for (final box in effectiveBoxes) {
      people.add(await _estimatePose(source, box));
    }
    final canvas = renderSkeleton(
      width: source.width,
      height: source.height,
      people: people,
    );
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(img.encodePng(canvas), flush: true);
    return DwPoseExtractionResult(
      skeletonFile: outputFile,
      personCount: people.length,
    );
  }

  Future<void> _ensureSessions(DwPoseModelFiles models) async {
    final options = OrtSessionOptions(
      intraOpNumThreads: math.max(1, Platform.numberOfProcessors - 1),
      interOpNumThreads: 1,
      providers: const [OrtProvider.CPU],
    );
    _detectorSession ??= await _runtime.createSession(
      models.detector.path,
      options: options,
    );
    _poseSession ??= await _runtime.createSession(
      models.pose.path,
      options: options,
    );
  }

  Future<List<DwPoseBox>> _detectPeople(img.Image source) async {
    final scale = math.min(
      detectorSize / source.height,
      detectorSize / source.width,
    );
    final resizedWidth = math.max(1, (source.width * scale).floor());
    final resizedHeight = math.max(1, (source.height * scale).floor());
    final resized = img.copyResize(
      source,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );
    final input = Float32List(3 * detectorSize * detectorSize)
      ..fillRange(0, 3 * detectorSize * detectorSize, 114);
    final plane = detectorSize * detectorSize;
    for (var y = 0; y < resizedHeight; y++) {
      for (var x = 0; x < resizedWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final offset = y * detectorSize + x;
        input[offset] = pixel.b.toDouble();
        input[plane + offset] = pixel.g.toDouble();
        input[2 * plane + offset] = pixel.r.toDouble();
      }
    }
    final tensor = await OrtValue.fromList(input, const [1, 3, 640, 640]);
    try {
      final outputs = await _detectorSession!.run({
        _detectorSession!.inputNames.first: tensor,
      });
      final output = outputs.values.first;
      try {
        final values = await output.asFlattenedList();
        return decodeDetectorOutput(values, imageScale: scale);
      } finally {
        await output.dispose();
      }
    } finally {
      await tensor.dispose();
    }
  }

  Future<List<DwPosePoint>> _estimatePose(
    img.Image source,
    DwPoseBox box,
  ) async {
    final centerX = (box.left + box.right) / 2;
    final centerY = (box.top + box.bottom) / 2;
    var scaleWidth = (box.right - box.left) * 1.25;
    var scaleHeight = (box.bottom - box.top) * 1.25;
    const aspect = poseWidth / poseHeight;
    if (scaleWidth > scaleHeight * aspect) {
      scaleHeight = scaleWidth / aspect;
    } else {
      scaleWidth = scaleHeight * aspect;
    }
    final input = Float32List(3 * poseWidth * poseHeight);
    final plane = poseWidth * poseHeight;
    const means = [123.675, 116.28, 103.53];
    const deviations = [58.395, 57.12, 57.375];
    for (var y = 0; y < poseHeight; y++) {
      for (var x = 0; x < poseWidth; x++) {
        final sourceX = centerX + (x / poseWidth - 0.5) * scaleWidth;
        final sourceY = centerY + (y / poseHeight - 0.5) * scaleHeight;
        final channels = _bilinearBgr(source, sourceX, sourceY);
        final offset = y * poseWidth + x;
        for (var channel = 0; channel < 3; channel++) {
          input[channel * plane + offset] =
              (channels[channel] - means[channel]) / deviations[channel];
        }
      }
    }
    final tensor = await OrtValue.fromList(input, const [
      1,
      3,
      poseHeight,
      poseWidth,
    ]);
    try {
      final outputs = await _poseSession!.run({
        _poseSession!.inputNames.first: tensor,
      });
      final xOutput = outputs['simcc_x'] ?? outputs.values.first;
      final yOutput = outputs['simcc_y'] ?? outputs.values.last;
      try {
        final simccX = await xOutput.asFlattenedList();
        final simccY = await yOutput.asFlattenedList();
        return decodePoseOutput(
          simccX: simccX,
          simccY: simccY,
          keypointCount: xOutput.shape.length > 1 ? xOutput.shape[1] : 133,
          xBins: xOutput.shape.last,
          yBins: yOutput.shape.last,
          centerX: centerX,
          centerY: centerY,
          scaleWidth: scaleWidth,
          scaleHeight: scaleHeight,
        );
      } finally {
        for (final output in outputs.values.toSet()) {
          await output.dispose();
        }
      }
    } finally {
      await tensor.dispose();
    }
  }

  static List<double> _bilinearBgr(img.Image source, double x, double y) {
    if (x < 0 || y < 0 || x >= source.width - 1 || y >= source.height - 1) {
      return const [0, 0, 0];
    }
    final x0 = x.floor();
    final y0 = y.floor();
    final x1 = x0 + 1;
    final y1 = y0 + 1;
    final wx = x - x0;
    final wy = y - y0;
    final pixels = [
      source.getPixel(x0, y0),
      source.getPixel(x1, y0),
      source.getPixel(x0, y1),
      source.getPixel(x1, y1),
    ];
    double interpolate(double Function(img.Pixel pixel) channel) =>
        channel(pixels[0]) * (1 - wx) * (1 - wy) +
        channel(pixels[1]) * wx * (1 - wy) +
        channel(pixels[2]) * (1 - wx) * wy +
        channel(pixels[3]) * wx * wy;
    return [
      interpolate((pixel) => pixel.b.toDouble()),
      interpolate((pixel) => pixel.g.toDouble()),
      interpolate((pixel) => pixel.r.toDouble()),
    ];
  }

  static List<DwPoseBox> decodeDetectorOutput(
    List<dynamic> values, {
    required double imageScale,
  }) {
    const strides = [8, 16, 32];
    final candidates = <DwPoseBox>[];
    var row = 0;
    for (final stride in strides) {
      final size = detectorSize ~/ stride;
      for (var gridY = 0; gridY < size; gridY++) {
        for (var gridX = 0; gridX < size; gridX++, row++) {
          final offset = row * 85;
          final score =
              (values[offset + 4] as num).toDouble() *
              (values[offset + 5] as num).toDouble();
          if (score <= 0.3) continue;
          final centerX = ((values[offset] as num).toDouble() + gridX) * stride;
          final centerY =
              ((values[offset + 1] as num).toDouble() + gridY) * stride;
          final width =
              math.exp((values[offset + 2] as num).toDouble()) * stride;
          final height =
              math.exp((values[offset + 3] as num).toDouble()) * stride;
          candidates.add(
            DwPoseBox(
              (centerX - width / 2) / imageScale,
              (centerY - height / 2) / imageScale,
              (centerX + width / 2) / imageScale,
              (centerY + height / 2) / imageScale,
              score,
            ),
          );
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final kept = <DwPoseBox>[];
    for (final box in candidates) {
      if (kept.every((other) => _iou(box, other) <= 0.45)) kept.add(box);
    }
    return kept;
  }

  static double _iou(DwPoseBox a, DwPoseBox b) {
    final width = math.max(
      0,
      math.min(a.right, b.right) - math.max(a.left, b.left) + 1,
    );
    final height = math.max(
      0,
      math.min(a.bottom, b.bottom) - math.max(a.top, b.top) + 1,
    );
    final intersection = width * height;
    return intersection / (a.area + b.area - intersection);
  }

  static List<DwPosePoint> decodePoseOutput({
    required List<dynamic> simccX,
    required List<dynamic> simccY,
    required int keypointCount,
    required int xBins,
    required int yBins,
    required double centerX,
    required double centerY,
    required double scaleWidth,
    required double scaleHeight,
  }) {
    final original = <DwPosePoint>[];
    for (var key = 0; key < keypointCount; key++) {
      var xIndex = 0;
      var yIndex = 0;
      var xScore = double.negativeInfinity;
      var yScore = double.negativeInfinity;
      for (var index = 0; index < xBins; index++) {
        final score = (simccX[key * xBins + index] as num).toDouble();
        if (score > xScore) {
          xScore = score;
          xIndex = index;
        }
      }
      for (var index = 0; index < yBins; index++) {
        final score = (simccY[key * yBins + index] as num).toDouble();
        if (score > yScore) {
          yScore = score;
          yIndex = index;
        }
      }
      final modelX = xIndex / simccSplitRatio;
      final modelY = yIndex / simccSplitRatio;
      original.add(
        DwPosePoint(
          modelX / poseWidth * scaleWidth + centerX - scaleWidth / 2,
          modelY / poseHeight * scaleHeight + centerY - scaleHeight / 2,
          math.min(xScore, yScore),
        ),
      );
    }
    if (original.length < 133) return original;
    final neck = DwPosePoint(
      (original[5].x + original[6].x) / 2,
      (original[5].y + original[6].y) / 2,
      original[5].score > keypointThreshold &&
              original[6].score > keypointThreshold
          ? math.min(original[5].score, original[6].score)
          : 0,
    );
    final remapped = [...original.take(17), neck, ...original.skip(17)];
    const sources = [17, 6, 8, 10, 7, 9, 12, 14, 16, 13, 15, 2, 1, 4, 3];
    const targets = [1, 2, 3, 4, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16, 17];
    final sourceCopy = [...remapped];
    for (var index = 0; index < targets.length; index++) {
      remapped[targets[index]] = sourceCopy[sources[index]];
    }
    return remapped;
  }

  static img.Image renderSkeleton({
    required int width,
    required int height,
    required List<List<DwPosePoint>> people,
  }) {
    final canvas = img.Image(width: width, height: height);
    const bodyEdges = [
      [1, 2],
      [1, 5],
      [2, 3],
      [3, 4],
      [5, 6],
      [6, 7],
      [1, 8],
      [8, 9],
      [9, 10],
      [1, 11],
      [11, 12],
      [12, 13],
      [1, 0],
      [0, 14],
      [14, 16],
      [0, 15],
      [15, 17],
    ];
    const colors = [
      [255, 0, 0],
      [255, 85, 0],
      [255, 170, 0],
      [255, 255, 0],
      [170, 255, 0],
      [85, 255, 0],
      [0, 255, 0],
      [0, 255, 85],
      [0, 255, 170],
      [0, 255, 255],
      [0, 170, 255],
      [0, 85, 255],
      [0, 0, 255],
      [85, 0, 255],
      [170, 0, 255],
      [255, 0, 255],
      [255, 0, 170],
    ];
    const handEdges = [
      [0, 1],
      [1, 2],
      [2, 3],
      [3, 4],
      [0, 5],
      [5, 6],
      [6, 7],
      [7, 8],
      [0, 9],
      [9, 10],
      [10, 11],
      [11, 12],
      [0, 13],
      [13, 14],
      [14, 15],
      [15, 16],
      [0, 17],
      [17, 18],
      [18, 19],
      [19, 20],
    ];
    final thickness = math.max(2, math.min(width, height) ~/ 240);
    for (final points in people) {
      if (points.length < 134) continue;
      for (var index = 0; index < bodyEdges.length; index++) {
        final first = points[bodyEdges[index][0]];
        final second = points[bodyEdges[index][1]];
        if (!_visible(first) || !_visible(second)) continue;
        final color = colors[index % colors.length];
        img.drawLine(
          canvas,
          x1: first.x.round(),
          y1: first.y.round(),
          x2: second.x.round(),
          y2: second.y.round(),
          color: img.ColorRgb8(color[0], color[1], color[2]),
          thickness: thickness * 2,
          antialias: true,
        );
      }
      for (var index = 0; index < 18; index++) {
        final point = points[index];
        if (!_visible(point)) continue;
        final color = colors[index % colors.length];
        img.fillCircle(
          canvas,
          x: point.x.round(),
          y: point.y.round(),
          radius: thickness * 2,
          color: img.ColorRgb8(color[0], color[1], color[2]),
        );
      }
      for (final handStart in const [92, 113]) {
        for (var index = 0; index < handEdges.length; index++) {
          final first = points[handStart + handEdges[index][0]];
          final second = points[handStart + handEdges[index][1]];
          if (!_visible(first) || !_visible(second)) continue;
          final color = _hsvColor(index / handEdges.length);
          img.drawLine(
            canvas,
            x1: first.x.round(),
            y1: first.y.round(),
            x2: second.x.round(),
            y2: second.y.round(),
            color: color,
            thickness: thickness,
            antialias: true,
          );
        }
        for (var index = 0; index < 21; index++) {
          final point = points[handStart + index];
          if (!_visible(point)) continue;
          img.fillCircle(
            canvas,
            x: point.x.round(),
            y: point.y.round(),
            radius: math.max(1, thickness),
            color: img.ColorRgb8(255, 0, 0),
          );
        }
      }
      for (var index = 24; index < 92; index++) {
        final point = points[index];
        if (!_visible(point)) continue;
        img.fillCircle(
          canvas,
          x: point.x.round(),
          y: point.y.round(),
          radius: math.max(1, thickness - 1),
          color: img.ColorRgb8(255, 255, 255),
        );
      }
    }
    return canvas;
  }

  static bool _visible(DwPosePoint point) =>
      point.score > keypointThreshold && point.x >= 0 && point.y >= 0;

  static img.ColorRgb8 _hsvColor(double hue) {
    final h = hue * 6;
    final sector = h.floor();
    final fraction = h - sector;
    final q = (255 * (1 - fraction)).round();
    final t = (255 * fraction).round();
    return switch (sector % 6) {
      0 => img.ColorRgb8(255, t, 0),
      1 => img.ColorRgb8(q, 255, 0),
      2 => img.ColorRgb8(0, 255, t),
      3 => img.ColorRgb8(0, q, 255),
      4 => img.ColorRgb8(t, 0, 255),
      _ => img.ColorRgb8(255, 0, q),
    };
  }

  Future<void> close() async {
    await _detectorSession?.close();
    await _poseSession?.close();
    _detectorSession = null;
    _poseSession = null;
  }

  static File outputFileFor({
    required Directory directory,
    required String shotId,
  }) => File(p.join(directory.path, '$shotId-dwpose.png'));
}
