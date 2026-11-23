import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

const int defaultPreviewImageMaxCacheWidth = 2048;

ImageProvider<Object> previewFileImageProvider({
  required String path,
  required double logicalWidth,
  required double devicePixelRatio,
  int maxCacheWidth = defaultPreviewImageMaxCacheWidth,
}) {
  final provider = FileImage(File(path));
  if (!logicalWidth.isFinite || logicalWidth <= 0) {
    return provider;
  }
  final pixelWidth = logicalWidth * devicePixelRatio;
  const bucketSize = 64;
  final bucketedWidth = (pixelWidth / bucketSize).ceil() * bucketSize;
  final cacheWidth = math
      .max(bucketSize, math.min(maxCacheWidth, bucketedWidth))
      .toInt();
  return ResizeImage.resizeIfNeeded(cacheWidth, null, provider);
}
