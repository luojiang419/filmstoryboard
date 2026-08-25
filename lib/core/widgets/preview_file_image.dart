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

/// Displays a local preview using a decode size derived from its viewport.
///
/// This keeps thumbnail grids from decoding an original multi-megapixel file
/// when only a small card is visible, while preserving the same image
/// provider semantics and error handling as [Image.file].
class PreviewFileImage extends StatelessWidget {
  const PreviewFileImage({
    super.key,
    required this.path,
    this.fit = BoxFit.contain,
    this.errorBuilder,
    this.maxCacheWidth = defaultPreviewImageMaxCacheWidth,
  });

  final String path;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final int maxCacheWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Image(
        image: previewFileImageProvider(
          path: path,
          logicalWidth: constraints.maxWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          maxCacheWidth: maxCacheWidth,
        ),
        fit: fit,
        errorBuilder: errorBuilder,
      ),
    );
  }
}
