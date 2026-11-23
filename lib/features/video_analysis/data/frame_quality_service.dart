import 'dart:io';

import 'package:image/image.dart' as img;

class FrameQualityThresholds {
  const FrameQualityThresholds({
    this.minimumSharpness = 0.25,
    this.minimumBrightness = 0.08,
    this.maximumBrightness = 0.92,
  });

  final double minimumSharpness;
  final double minimumBrightness;
  final double maximumBrightness;
}

class FrameQualityMetrics {
  const FrameQualityMetrics({
    required this.width,
    required this.height,
    required this.sharpness,
    required this.brightness,
    required this.motionScore,
    required this.perceptualHash,
  });

  final int width;
  final int height;
  final double sharpness;
  final double brightness;
  final double motionScore;
  final String perceptualHash;
}

class FrameQualityResult {
  const FrameQualityResult({
    required this.isFocus,
    required this.isDuplicate,
    required this.errorMessage,
  });

  final bool isFocus;
  final bool isDuplicate;
  final String errorMessage;
}

class FrameQualityService {
  const FrameQualityService({this.thresholds = const FrameQualityThresholds()});

  final FrameQualityThresholds thresholds;

  Future<FrameQualityMetrics> analyze(
    File file, {
    String previousHash = '',
  }) async {
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) {
      throw FormatException('无法读取视频帧：${file.path}');
    }
    final step = (decoded.width * decoded.height / 250000).sqrtCeil();
    var luminanceTotal = 0.0;
    var gradientTotal = 0.0;
    var count = 0;
    for (var y = 0; y < decoded.height; y += step) {
      for (var x = 0; x < decoded.width; x += step) {
        final value = _luminance(decoded.getPixel(x, y));
        luminanceTotal += value;
        if (x + step < decoded.width) {
          gradientTotal += (value - _luminance(decoded.getPixel(x + step, y)))
              .abs();
        }
        if (y + step < decoded.height) {
          gradientTotal += (value - _luminance(decoded.getPixel(x, y + step)))
              .abs();
        }
        count++;
      }
    }
    final hash = _averageHash(decoded);
    return FrameQualityMetrics(
      width: decoded.width,
      height: decoded.height,
      sharpness: count == 0
          ? 0
          : (gradientTotal / (count * 2 * 255)).clamp(0, 1),
      brightness: count == 0 ? 0 : (luminanceTotal / (count * 255)).clamp(0, 1),
      motionScore: previousHash.isEmpty
          ? 0
          : _hashDistance(hash, previousHash) / 64,
      perceptualHash: hash,
    );
  }

  FrameQualityResult assess({
    required double sharpness,
    required double brightness,
    required String perceptualHash,
    Set<String> knownHashes = const {},
    int maximumDuplicateDistance = 4,
  }) {
    final duplicate =
        perceptualHash.isNotEmpty &&
        knownHashes.any(
          (hash) =>
              _hashDistance(perceptualHash, hash) <= maximumDuplicateDistance,
        );
    final messages = <String>[];
    if (sharpness < thresholds.minimumSharpness) {
      messages.add('画面清晰度偏低');
    }
    if (brightness < thresholds.minimumBrightness ||
        brightness > thresholds.maximumBrightness) {
      messages.add('曝光异常');
    }
    if (duplicate) {
      messages.add('与已有帧重复');
    }
    return FrameQualityResult(
      isFocus: messages.isEmpty,
      isDuplicate: duplicate,
      errorMessage: messages.join('；'),
    );
  }

  static double _luminance(img.Pixel pixel) {
    return 0.2126 * pixel.r.toDouble() +
        0.7152 * pixel.g.toDouble() +
        0.0722 * pixel.b.toDouble();
  }

  static String _averageHash(img.Image image) {
    final values = <double>[];
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final sourceX = ((x + 0.5) * image.width / 8).floor().clamp(
          0,
          image.width - 1,
        );
        final sourceY = ((y + 0.5) * image.height / 8).floor().clamp(
          0,
          image.height - 1,
        );
        values.add(_luminance(image.getPixel(sourceX, sourceY)));
      }
    }
    final average = values.reduce((a, b) => a + b) / values.length;
    var bits = BigInt.zero;
    for (final value in values) {
      bits = (bits << 1) | (value >= average ? BigInt.one : BigInt.zero);
    }
    return bits.toRadixString(16).padLeft(16, '0');
  }

  static int _hashDistance(String first, String second) {
    if (first.length != second.length || first.isEmpty) {
      return 64;
    }
    final a = BigInt.tryParse(first, radix: 16);
    final b = BigInt.tryParse(second, radix: 16);
    if (a == null || b == null) {
      return first == second ? 0 : 64;
    }
    var value = a ^ b;
    var count = 0;
    while (value > BigInt.zero) {
      count++;
      value &= value - BigInt.one;
    }
    return count;
  }
}

extension on double {
  int sqrtCeil() {
    if (this <= 1) {
      return 1;
    }
    var result = 1;
    while (result * result < this) {
      result++;
    }
    return result;
  }
}
