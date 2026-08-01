import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show DateFormat;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../settings/domain/app_settings.dart';
import '../../storyboard/domain/storyboard_canvas_style.dart';
import '../../storyboard/domain/storyboard_models.dart';

enum StoryboardExportFormat {
  png('PNG', 'png'),
  jpg('JPG', 'jpg'),
  pdf('PDF', 'pdf');

  const StoryboardExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

enum StoryboardExportResolution {
  standard('标准尺寸', '按画板尺寸导出'),
  sourceDetail('原图细节', '自动放大画布，保留源图像素细节');

  const StoryboardExportResolution(this.label, this.description);

  final String label;
  final String description;
}

String storyboardExportFileName({
  required String boardName,
  required StoryboardExportFormat format,
  DateTime? date,
}) {
  final safeBoardName = _safePathSegment(boardName, fallback: '画板');
  final dateText = DateFormat('yyyyMMdd').format(date ?? DateTime.now());
  return '$safeBoardName-$dateText.${format.extension}';
}

class StoryboardBoardImageExportResult {
  const StoryboardBoardImageExportResult({
    required this.directory,
    required this.files,
  });

  final Directory directory;
  final List<File> files;
}

class StoryboardExportCancelled implements Exception {
  const StoryboardExportCancelled();

  @override
  String toString() => '导出已取消';
}

typedef StoryboardExportCancellationCheck = bool Function();
typedef StoryboardExportProgressCallback = void Function(double progress);
typedef StoryboardSourceDecodeObserver =
    void Function(int intrinsicWidth, int decodedWidth);

class StoryboardExportService {
  const StoryboardExportService();

  Future<StoryboardBoardImageExportResult> exportBoardImages({
    required StoryboardBoard board,
    required String outputDirectory,
  }) async {
    final boardName = _safePathSegment(board.name, fallback: '画板');
    final directory = await _createAvailableDirectory(
      p.join(outputDirectory, boardName),
    );
    final exported = <File>[];

    for (var slotIndex = 0; slotIndex < board.slotCount; slotIndex++) {
      final item = board.itemAtSlot(slotIndex);
      if (item == null) {
        continue;
      }
      final source = File(item.asset.path);
      final extension = p.extension(source.path).isEmpty
          ? '.png'
          : p.extension(source.path);
      final target = File(
        p.join(directory.path, '$boardName${slotIndex + 1}$extension'),
      );
      if (!target.parent.existsSync()) {
        await target.parent.create(recursive: true);
      }
      exported.add(await source.copy(target.path));
    }

    return StoryboardBoardImageExportResult(
      directory: directory,
      files: exported,
    );
  }

  Future<List<File>> exportBoard({
    required StoryboardBoard board,
    required StoryboardExportFormat format,
    StoryboardExportResolution resolution =
        StoryboardExportResolution.sourceDetail,
    required String outputPath,
    StoryboardCanvasColors canvasColors = StoryboardCanvasStyle.darkColors,
    bool includeSummaryPage = false,
    bool numberEnabled = false,
    CutImageNumberPosition numberPosition = CutImageNumberPosition.topLeft,
    double numberBackgroundOpacity =
        AppSettings.defaultCutImageNumberBackgroundOpacity,
    double numberTextScale = AppSettings.defaultCutImageNumberTextScale,
    bool captionNumberEnabled = true,
    StoryboardExportCancellationCheck? isCancelled,
    StoryboardExportProgressCallback? onProgress,
    StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    _throwIfCancelled(isCancelled);
    final renderBoard = board.withAdaptiveHeight();
    final renderScale = await _resolveRenderScale(
      board: renderBoard,
      resolution: resolution,
      isCancelled: isCancelled,
    );
    final file = File(_ensureExtension(outputPath, format.extension));
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    final exported = <File>[];
    try {
      switch (format) {
        case StoryboardExportFormat.png:
          await _exportPng(
            board: renderBoard,
            renderScale: renderScale,
            file: file,
            exported: exported,
            canvasColors: canvasColors,
            includeSummaryPage: includeSummaryPage,
            numberEnabled: numberEnabled,
            numberPosition: numberPosition,
            numberBackgroundOpacity: numberBackgroundOpacity,
            numberTextScale: numberTextScale,
            captionNumberEnabled: captionNumberEnabled,
            isCancelled: isCancelled,
            onProgress: onProgress,
            onSourceDecoded: onSourceDecoded,
          );
        case StoryboardExportFormat.jpg:
          await _exportJpg(
            board: renderBoard,
            renderScale: renderScale,
            file: file,
            exported: exported,
            canvasColors: canvasColors,
            includeSummaryPage: includeSummaryPage,
            numberEnabled: numberEnabled,
            numberPosition: numberPosition,
            numberBackgroundOpacity: numberBackgroundOpacity,
            numberTextScale: numberTextScale,
            captionNumberEnabled: captionNumberEnabled,
            isCancelled: isCancelled,
            onProgress: onProgress,
            onSourceDecoded: onSourceDecoded,
          );
        case StoryboardExportFormat.pdf:
          await _exportPdf(
            board: renderBoard,
            renderScale: renderScale,
            file: file,
            exported: exported,
            canvasColors: canvasColors,
            includeSummaryPage: includeSummaryPage,
            numberEnabled: numberEnabled,
            numberPosition: numberPosition,
            numberBackgroundOpacity: numberBackgroundOpacity,
            numberTextScale: numberTextScale,
            captionNumberEnabled: captionNumberEnabled,
            isCancelled: isCancelled,
            onProgress: onProgress,
            onSourceDecoded: onSourceDecoded,
          );
      }
      _throwIfCancelled(isCancelled);
      onProgress?.call(1);
      return exported;
    } catch (_) {
      await _deleteFiles(exported);
      await _deleteIfExists(_temporaryFileFor(file));
      await _deleteIfExists(
        _temporaryFileFor(File(_summaryPagePath(file.path))),
      );
      rethrow;
    }
  }

  Future<void> _exportPng({
    required StoryboardBoard board,
    required double renderScale,
    required File file,
    required List<File> exported,
    required StoryboardCanvasColors canvasColors,
    required bool includeSummaryPage,
    required bool numberEnabled,
    required CutImageNumberPosition numberPosition,
    required double numberBackgroundOpacity,
    required double numberTextScale,
    required bool captionNumberEnabled,
    required StoryboardExportCancellationCheck? isCancelled,
    required StoryboardExportProgressCallback? onProgress,
    required StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    final pngBytes = await renderBoardToPng(
      board,
      renderScale: renderScale,
      canvasColors: canvasColors,
      numberEnabled: numberEnabled,
      numberPosition: numberPosition,
      numberBackgroundOpacity: numberBackgroundOpacity,
      numberTextScale: numberTextScale,
      captionNumberEnabled: captionNumberEnabled,
      isCancelled: isCancelled,
      onProgress: (progress) => onProgress?.call(progress * 0.72),
      onSourceDecoded: onSourceDecoded,
    );
    _throwIfCancelled(isCancelled);
    await _atomicWriteBytes(file, pngBytes);
    exported.add(file);
    onProgress?.call(0.78);
    if (_shouldExportSummaryPage(board, includeSummaryPage)) {
      _throwIfCancelled(isCancelled);
      final summaryBytes = await renderSummaryPageToPng(
        board,
        renderScale: renderScale,
        canvasColors: canvasColors,
      );
      _throwIfCancelled(isCancelled);
      final summaryFile = File(_summaryPagePath(file.path));
      await _atomicWriteBytes(summaryFile, summaryBytes);
      exported.add(summaryFile);
    }
  }

  Future<void> _exportJpg({
    required StoryboardBoard board,
    required double renderScale,
    required File file,
    required List<File> exported,
    required StoryboardCanvasColors canvasColors,
    required bool includeSummaryPage,
    required bool numberEnabled,
    required CutImageNumberPosition numberPosition,
    required double numberBackgroundOpacity,
    required double numberTextScale,
    required bool captionNumberEnabled,
    required StoryboardExportCancellationCheck? isCancelled,
    required StoryboardExportProgressCallback? onProgress,
    required StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    final pngBytes = await renderBoardToPng(
      board,
      renderScale: renderScale,
      canvasColors: canvasColors,
      numberEnabled: numberEnabled,
      numberPosition: numberPosition,
      numberBackgroundOpacity: numberBackgroundOpacity,
      numberTextScale: numberTextScale,
      captionNumberEnabled: captionNumberEnabled,
      isCancelled: isCancelled,
      onProgress: (progress) => onProgress?.call(progress * 0.66),
      onSourceDecoded: onSourceDecoded,
    );
    _throwIfCancelled(isCancelled);
    await _writeJpg(file, pngBytes);
    exported.add(file);
    _throwIfCancelled(isCancelled);
    onProgress?.call(0.76);
    if (_shouldExportSummaryPage(board, includeSummaryPage)) {
      final summaryBytes = await renderSummaryPageToPng(
        board,
        renderScale: renderScale,
        canvasColors: canvasColors,
      );
      _throwIfCancelled(isCancelled);
      final summaryFile = File(_summaryPagePath(file.path));
      await _writeJpg(summaryFile, summaryBytes);
      exported.add(summaryFile);
      _throwIfCancelled(isCancelled);
    }
  }

  Future<void> _exportPdf({
    required StoryboardBoard board,
    required double renderScale,
    required File file,
    required List<File> exported,
    required StoryboardCanvasColors canvasColors,
    required bool includeSummaryPage,
    required bool numberEnabled,
    required CutImageNumberPosition numberPosition,
    required double numberBackgroundOpacity,
    required double numberTextScale,
    required bool captionNumberEnabled,
    required StoryboardExportCancellationCheck? isCancelled,
    required StoryboardExportProgressCallback? onProgress,
    required StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    final pngBytes = await renderBoardToPng(
      board,
      renderScale: renderScale,
      canvasColors: canvasColors,
      numberEnabled: numberEnabled,
      numberPosition: numberPosition,
      numberBackgroundOpacity: numberBackgroundOpacity,
      numberTextScale: numberTextScale,
      captionNumberEnabled: captionNumberEnabled,
      isCancelled: isCancelled,
      onProgress: (progress) => onProgress?.call(progress * 0.62),
      onSourceDecoded: onSourceDecoded,
    );
    _throwIfCancelled(isCancelled);
    final pages = <TransferableTypedData>[
      TransferableTypedData.fromList([pngBytes]),
    ];
    if (_shouldExportSummaryPage(board, includeSummaryPage)) {
      final summaryBytes = await renderSummaryPageToPng(
        board,
        renderScale: renderScale,
        canvasColors: canvasColors,
      );
      _throwIfCancelled(isCancelled);
      pages.add(TransferableTypedData.fromList([summaryBytes]));
    }
    onProgress?.call(0.76);
    final temporaryFile = _temporaryFileFor(file);
    await _deleteIfExists(temporaryFile);
    await compute(
      _writePdfInWorker,
      _PdfWriteRequest(
        path: temporaryFile.path,
        width: _scaledPixelDimension(board.width, renderScale),
        height: _scaledPixelDimension(board.height, renderScale),
        pages: pages,
      ),
      debugLabel: 'storyboard-pdf-export',
    );
    _throwIfCancelled(isCancelled);
    await _replaceFile(temporaryFile, file);
    exported.add(file);
  }

  Future<Uint8List> renderBoardToPng(
    StoryboardBoard board, {
    StoryboardExportResolution resolution =
        StoryboardExportResolution.sourceDetail,
    double? renderScale,
    StoryboardCanvasColors canvasColors = StoryboardCanvasStyle.darkColors,
    bool numberEnabled = false,
    CutImageNumberPosition numberPosition = CutImageNumberPosition.topLeft,
    double numberBackgroundOpacity =
        AppSettings.defaultCutImageNumberBackgroundOpacity,
    double numberTextScale = AppSettings.defaultCutImageNumberTextScale,
    bool captionNumberEnabled = true,
    StoryboardExportCancellationCheck? isCancelled,
    StoryboardExportProgressCallback? onProgress,
    StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    _throwIfCancelled(isCancelled);
    final renderBoard = board.withAdaptiveHeight();
    final columns = math.max(1, renderBoard.columns);
    final rows = math.max(1, renderBoard.rows);
    final layout = _BoardRenderLayout(
      board: renderBoard,
      rows: rows,
      columns: columns,
    );
    final showItemCaptions =
        renderBoard.storyDescriptionEnabled &&
        !renderBoard.rowDescriptionEnabled;
    final showRowCaptions =
        renderBoard.storyDescriptionEnabled &&
        renderBoard.rowDescriptionEnabled;
    final itemsBySlot = <int, StoryboardItem>{};
    for (final item in renderBoard.items) {
      itemsBySlot.putIfAbsent(item.slotIndex, () => item);
    }

    final effectiveRenderScale =
        renderScale ??
        await _resolveRenderScale(
          board: renderBoard,
          resolution: resolution,
          isCancelled: isCancelled,
        );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(effectiveRenderScale);
    final size = Size(
      renderBoard.width.toDouble(),
      renderBoard.height.toDouble(),
    );
    final background = Paint()..color = canvasColors.background;
    canvas.drawRect(Offset.zero & size, background);

    _paintBoardTitle(canvas, renderBoard, layout, canvasColors);
    ui.Picture? picture;
    ui.Image? outputImage;
    try {
      for (var i = 0; i < renderBoard.slotCount; i++) {
        _throwIfCancelled(isCancelled);
        final tileRect = layout.slotRect(i);
        _drawPanel(
          canvas,
          tileRect,
          fill: canvasColors.tileBackground,
          canvasColors: canvasColors,
        );

        final item = itemsBySlot[i];
        if (item != null) {
          final caption = item.caption.trim();
          final imageRect = _imageRectForItem(
            tileRect: tileRect,
            layout: layout,
            showItemCaptions: showItemCaptions,
          );
          final padding = math.min(12.0, math.max(6.0, tileRect.width * 0.035));
          final captionHeight = showItemCaptions
              ? layout.itemCaptionHeight
              : 0.0;
          final image = await _decodeUiImageFile(
            item.asset.path,
            targetWidth: math.max(
              1,
              (imageRect.width * effectiveRenderScale).ceil(),
            ),
            onSourceDecoded: onSourceDecoded,
          );
          try {
            _paintStoryboardImage(canvas, imageRect, image, item);
          } finally {
            image.dispose();
          }
          if (numberEnabled) {
            _paintNumberBadge(
              canvas,
              imageRect,
              i + 1,
              numberPosition,
              numberBackgroundOpacity,
              numberTextScale,
            );
          }

          if (showItemCaptions) {
            final captionRect = Rect.fromLTWH(
              tileRect.left + padding,
              imageRect.bottom + 8,
              tileRect.width - padding * 2,
              captionHeight,
            );
            final textRect = captionNumberEnabled
                ? _paintCaptionSequenceBadge(
                    canvas,
                    captionRect,
                    i + 1,
                    renderBoard.captionFontSize,
                    canvasColors,
                  )
                : captionRect;
            if (caption.isNotEmpty) {
              _paintText(
                canvas,
                caption,
                textRect,
                fontFamily: renderBoard.captionFontFamily,
                fontSize: renderBoard.captionFontSize,
                color: canvasColors.text,
                maxLines: null,
              );
            }
          }
        }
        onProgress?.call((i + 1) / math.max(1, renderBoard.slotCount));
      }

      if (showRowCaptions) {
        for (var rowIndex = 0; rowIndex < rows; rowIndex++) {
          final rect = layout.rowCaptionRect(rowIndex);
          _drawPanel(
            canvas,
            rect,
            fill: canvasColors.imageBackground,
            canvasColors: canvasColors,
          );
          final padding = math.min(14.0, math.max(8.0, rect.width * 0.018));
          _paintText(
            canvas,
            renderBoard.rowCaptionAt(rowIndex),
            rect.deflate(padding),
            fontFamily: renderBoard.captionFontFamily,
            fontSize: renderBoard.captionFontSize,
            color: canvasColors.text,
            maxLines: null,
          );
        }
      }
      if (renderBoard.rowDividerEnabled && rows > 1) {
        _paintRowDividers(canvas, renderBoard, layout, canvasColors);
      }

      _throwIfCancelled(isCancelled);
      picture = recorder.endRecording();
      outputImage = await picture.toImage(
        _scaledPixelDimension(renderBoard.width, effectiveRenderScale),
        _scaledPixelDimension(renderBoard.height, effectiveRenderScale),
      );
      final byteData = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) {
        throw const FormatException('无法渲染故事板');
      }
      return byteData.buffer.asUint8List();
    } finally {
      outputImage?.dispose();
      picture?.dispose();
      if (picture == null) {
        recorder.endRecording().dispose();
      }
    }
  }

  Future<Uint8List> renderSummaryPageToPng(
    StoryboardBoard board, {
    double renderScale = 1,
    StoryboardCanvasColors canvasColors = StoryboardCanvasStyle.darkColors,
  }) async {
    final summary = board.summary;
    if (summary == null || summary.isEmpty) {
      throw const FormatException('故事板内容页为空');
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(renderScale);
    final size = Size(board.width.toDouble(), board.height.toDouble());
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = canvasColors.background,
    );

    final margin = math.max(48.0, board.width * 0.055);
    final contentWidth = board.width - margin * 2;
    var y = margin;
    final title = board.name.trim().isEmpty ? '画板' : board.name.trim();
    _paintText(
      canvas,
      title,
      Rect.fromLTWH(margin, y, contentWidth, 72),
      fontFamily: board.captionFontFamily,
      fontSize: math.max(38.0, board.width * 0.032),
      color: canvasColors.text,
      maxLines: 1,
    );
    y += 96;

    for (final section in [
      ('大纲', summary.outline),
      ('内容', summary.content),
      ('场景', summary.scenes),
      ('道具', summary.props),
    ]) {
      y = _paintSummarySection(
        canvas,
        title: section.$1,
        body: section.$2,
        x: margin,
        y: y,
        width: contentWidth,
        fontFamily: board.captionFontFamily,
        canvasColors: canvasColors,
      );
      y += 22;
    }

    ui.Picture? picture;
    ui.Image? image;
    try {
      picture = recorder.endRecording();
      image = await picture.toImage(
        _scaledPixelDimension(board.width, renderScale),
        _scaledPixelDimension(board.height, renderScale),
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw const FormatException('无法渲染故事板内容页');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image?.dispose();
      picture?.dispose();
      if (picture == null) {
        recorder.endRecording().dispose();
      }
    }
  }

  double _paintSummarySection(
    Canvas canvas, {
    required String title,
    required String body,
    required double x,
    required double y,
    required double width,
    required String fontFamily,
    required StoryboardCanvasColors canvasColors,
  }) {
    _paintText(
      canvas,
      title,
      Rect.fromLTWH(x, y, width, 42),
      fontFamily: fontFamily,
      fontSize: 28,
      color: canvasColors.accent,
      maxLines: 1,
    );
    final bodyRect = Rect.fromLTWH(x, y + 48, width, 210);
    _paintText(
      canvas,
      body.trim().isEmpty ? '暂无内容' : body,
      bodyRect,
      fontFamily: fontFamily,
      fontSize: 22,
      color: canvasColors.text,
      maxLines: 5,
    );
    return y +
        48 +
        _textHeight(
          body.trim().isEmpty ? '暂无内容' : body,
          width,
          fontFamily: fontFamily,
          fontSize: 22,
          maxLines: 5,
        );
  }

  Future<double> _resolveRenderScale({
    required StoryboardBoard board,
    required StoryboardExportResolution resolution,
    StoryboardExportCancellationCheck? isCancelled,
  }) async {
    if (resolution == StoryboardExportResolution.standard) {
      return 1;
    }

    final rows = math.max(1, board.rows);
    final columns = math.max(1, board.columns);
    final layout = _BoardRenderLayout(
      board: board,
      rows: rows,
      columns: columns,
    );
    final showItemCaptions =
        board.storyDescriptionEnabled && !board.rowDescriptionEnabled;
    final itemsBySlot = <int, StoryboardItem>{};
    for (final item in board.items) {
      itemsBySlot.putIfAbsent(item.slotIndex, () => item);
    }
    final sourceSizes = <String, Size>{};
    var scale = 1.0;
    for (var slotIndex = 0; slotIndex < board.slotCount; slotIndex++) {
      _throwIfCancelled(isCancelled);
      final item = itemsBySlot[slotIndex];
      if (item == null) {
        continue;
      }
      final imageRect = _imageRectForItem(
        tileRect: layout.slotRect(slotIndex),
        layout: layout,
        showItemCaptions: showItemCaptions,
      );
      final sourceSize = sourceSizes[item.asset.path] ??=
          await _readUiImageSize(item.asset.path);
      scale = math.max(
        scale,
        math.max(
          sourceSize.width / imageRect.width,
          sourceSize.height / imageRect.height,
        ),
      );
    }
    return scale;
  }

  Rect _imageRectForItem({
    required Rect tileRect,
    required _BoardRenderLayout layout,
    required bool showItemCaptions,
  }) {
    final padding = math.min(12.0, math.max(6.0, tileRect.width * 0.035));
    final captionHeight = showItemCaptions ? layout.itemCaptionHeight : 0.0;
    return Rect.fromLTWH(
      tileRect.left + padding,
      tileRect.top + padding,
      math.max(1.0, tileRect.width - padding * 2),
      math.max(
        1.0,
        tileRect.height -
            padding * 2 -
            captionHeight -
            (showItemCaptions ? 8 : 0),
      ),
    );
  }

  Future<Size> _readUiImageSize(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  int _scaledPixelDimension(int logicalDimension, double renderScale) {
    return math.max(1, (logicalDimension * renderScale).ceil());
  }

  void _paintStoryboardImage(
    Canvas canvas,
    Rect rect,
    ui.Image image,
    StoryboardItem item,
  ) {
    canvas.save();
    if (item.flipHorizontal || item.flipVertical) {
      canvas
        ..translate(rect.center.dx, rect.center.dy)
        ..scale(
          item.flipHorizontal ? -1.0 : 1.0,
          item.flipVertical ? -1.0 : 1.0,
        )
        ..translate(-rect.center.dx, -rect.center.dy);
    }
    paintImage(
      canvas: canvas,
      rect: rect,
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
    canvas.restore();
  }

  void _paintBoardTitle(
    Canvas canvas,
    StoryboardBoard board,
    _BoardRenderLayout layout,
    StoryboardCanvasColors canvasColors,
  ) {
    final painter =
        TextPainter(
          text: TextSpan(
            text: board.name.trim().isEmpty ? '画板' : board.name.trim(),
            style: TextStyle(
              color: canvasColors.text,
              fontFamily: board.captionFontFamily,
              fontSize: StoryboardBoard.titleFontSizeFor(board.captionFontSize),
              height: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          maxLines: 1,
          ellipsis: '...',
          textAlign: _exportTitleTextAlign(board.titleAlignment),
          textDirection: TextDirection.ltr,
        )..layout(
          minWidth: layout.titleRect.width,
          maxWidth: layout.titleRect.width,
        );
    painter.paint(
      canvas,
      Offset(
        layout.titleRect.left,
        layout.titleRect.top +
            math.max(0.0, (layout.titleRect.height - painter.height) / 2),
      ),
    );
  }

  TextAlign _exportTitleTextAlign(StoryboardTitleAlignment alignment) {
    return switch (alignment) {
      StoryboardTitleAlignment.left => TextAlign.left,
      StoryboardTitleAlignment.center => TextAlign.center,
      StoryboardTitleAlignment.right => TextAlign.right,
    };
  }

  void _paintNumberBadge(
    Canvas canvas,
    Rect rect,
    int number,
    CutImageNumberPosition position,
    double backgroundOpacity,
    double textScale,
  ) {
    final shortestSide = math.min(rect.width, rect.height);
    if (shortestSide < 12) {
      return;
    }

    final text = number.toString();
    final opacity = backgroundOpacity.clamp(0.0, 1.0).toDouble();
    final fontScale = textScale.clamp(0.7, 1.6).toDouble();
    final painter = TextPainter(
      text: const TextSpan(),
      textDirection: TextDirection.ltr,
    );
    var radius = math.max(8.0, shortestSide * 0.07 * fontScale);
    painter.text = TextSpan(
      text: text,
      style: TextStyle(
        color: const Color(0xFF161616),
        fontSize: math.max(8.0, radius * 0.9),
        fontWeight: FontWeight.w800,
        height: 1,
      ),
    );
    painter.layout();
    radius = math.max(radius, math.max(painter.width, painter.height) / 2 + 6);
    radius = radius.clamp(6.0, math.max(6.0, shortestSide / 2 - 2)).toDouble();
    final margin = math.max(4.0, radius * 0.35);

    var center = Offset(
      rect.left + radius + margin,
      rect.top + radius + margin,
    );
    switch (position) {
      case CutImageNumberPosition.topLeft:
        break;
      case CutImageNumberPosition.bottomLeft:
        center = Offset(
          rect.left + radius + margin,
          rect.bottom - radius - margin,
        );
        break;
      case CutImageNumberPosition.topRight:
        center = Offset(
          rect.right - radius - margin,
          rect.top + radius + margin,
        );
        break;
      case CutImageNumberPosition.bottomRight:
        center = Offset(
          rect.right - radius - margin,
          rect.bottom - radius - margin,
        );
        break;
      case CutImageNumberPosition.center:
        center = rect.center;
        break;
    }

    center = Offset(
      center.dx.clamp(rect.left + radius, rect.right - radius).toDouble(),
      center.dy.clamp(rect.top + radius, rect.bottom - radius).toDouble(),
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.08),
    );
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }

  Rect _paintCaptionSequenceBadge(
    Canvas canvas,
    Rect rect,
    int number,
    double fontSize,
    StoryboardCanvasColors canvasColors,
  ) {
    if (rect.isEmpty) {
      return rect;
    }
    final badgeWidth = math
        .max(28.0, math.min(44.0, fontSize * 2.0))
        .clamp(1.0, rect.width)
        .toDouble();
    final badgeRect = Rect.fromLTWH(
      rect.left,
      rect.top,
      badgeWidth,
      rect.height,
    );
    final radius = RRect.fromRectAndRadius(badgeRect, const Radius.circular(6));
    canvas.drawRRect(
      radius,
      Paint()..color = canvasColors.accent.withValues(alpha: 0.16),
    );
    canvas.drawRRect(
      radius,
      Paint()
        ..color = canvasColors.accent.withValues(alpha: 0.38)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final painter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          color: canvasColors.text,
          fontSize: math.max(10.0, fontSize * 0.72),
          height: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: badgeWidth);
    painter.paint(
      canvas,
      Offset(
        badgeRect.left + (badgeRect.width - painter.width) / 2,
        badgeRect.top + (badgeRect.height - painter.height) / 2,
      ),
    );

    const textGap = 6.0;
    final textLeft = math.min(rect.right, badgeRect.right + textGap);
    return Rect.fromLTRB(textLeft, rect.top, rect.right, rect.bottom);
  }

  Future<ui.Image> _decodeUiImageFile(
    String path, {
    required int targetWidth,
    StoryboardSourceDecodeObserver? onSourceDecoded,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final decodeWidth = math.max(1, math.min(descriptor.width, targetWidth));
      codec = await descriptor.instantiateCodec(targetWidth: decodeWidth);
      final frame = await codec.getNextFrame();
      onSourceDecoded?.call(descriptor.width, frame.image.width);
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  void _drawPanel(
    Canvas canvas,
    Rect rect, {
    required Color fill,
    required StoryboardCanvasColors canvasColors,
  }) {
    final radius = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(radius, Paint()..color = fill);
    canvas.drawRRect(
      radius,
      Paint()
        ..color = canvasColors.slotBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _paintRowDividers(
    Canvas canvas,
    StoryboardBoard board,
    _BoardRenderLayout layout,
    StoryboardCanvasColors canvasColors,
  ) {
    final paint = Paint()
      ..color = canvasColors.mutedText.withValues(
        alpha: board.rowDividerOpacity,
      )
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final left = layout.gap;
    final right = board.width - layout.gap;
    for (var rowIndex = 0; rowIndex < layout.rows - 1; rowIndex++) {
      final y = layout.dividerY(rowIndex);
      if (board.rowDividerStyle == StoryboardDividerStyle.solid) {
        canvas.drawLine(Offset(left, y), Offset(right, y), paint);
        continue;
      }
      const dashWidth = 10.0;
      const dashGap = 7.0;
      var x = left;
      while (x < right) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(right, x + dashWidth), y),
          paint,
        );
        x += dashWidth + dashGap;
      }
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Rect rect, {
    required String fontFamily,
    required double fontSize,
    required Color color,
    required int? maxLines,
  }) {
    if (text.trim().isEmpty || rect.isEmpty) {
      return;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          height: 1.25,
          fontFamily: fontFamily,
        ),
      ),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, rect.width));
    painter.paint(canvas, rect.topLeft);
  }

  double _textHeight(
    String text,
    double width, {
    required String fontFamily,
    required double fontSize,
    required int maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.25,
          fontFamily: fontFamily,
        ),
      ),
      maxLines: maxLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, width));
    return painter.height;
  }

  bool _shouldExportSummaryPage(
    StoryboardBoard board,
    bool includeSummaryPage,
  ) {
    final summary = board.summary;
    return includeSummaryPage && summary != null && !summary.isEmpty;
  }

  Future<void> _writeJpg(File file, Uint8List pngBytes) async {
    final temporaryFile = _temporaryFileFor(file);
    await _deleteIfExists(temporaryFile);
    await compute(
      _writeJpgInWorker,
      _JpgWriteRequest(
        path: temporaryFile.path,
        pngBytes: TransferableTypedData.fromList([pngBytes]),
      ),
      debugLabel: 'storyboard-jpg-export',
    );
    await _replaceFile(temporaryFile, file);
  }

  Future<void> _atomicWriteBytes(File file, Uint8List bytes) async {
    final temporaryFile = _temporaryFileFor(file);
    await _deleteIfExists(temporaryFile);
    await temporaryFile.writeAsBytes(bytes);
    await _replaceFile(temporaryFile, file);
  }

  File _temporaryFileFor(File file) => File('${file.path}.part');

  Future<void> _replaceFile(File source, File target) async {
    if (target.existsSync()) {
      await target.delete();
    }
    await source.rename(target.path);
  }

  Future<void> _deleteFiles(Iterable<File> files) async {
    for (final file in files) {
      await _deleteIfExists(file);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (!file.existsSync()) {
      return;
    }
    try {
      await file.delete();
    } on FileSystemException {
      // 清理失败不覆盖原始导出异常。
    }
  }

  void _throwIfCancelled(StoryboardExportCancellationCheck? isCancelled) {
    if (isCancelled?.call() == true) {
      throw const StoryboardExportCancelled();
    }
  }

  String _ensureExtension(String path, String extension) {
    final normalizedExtension = '.$extension';
    if (path.toLowerCase().endsWith(normalizedExtension)) {
      return path;
    }
    return '$path$normalizedExtension';
  }

  String _summaryPagePath(String path) {
    final extension = p.extension(path);
    if (extension.isEmpty) {
      return '$path-内容页';
    }
    return '${path.substring(0, path.length - extension.length)}-内容页$extension';
  }

  Future<Directory> _createAvailableDirectory(String path) async {
    var directory = Directory(path);
    if (!directory.existsSync()) {
      return directory.create(recursive: true);
    }
    if (_directoryIsEmpty(directory)) {
      return directory;
    }

    var index = 2;
    while (true) {
      directory = Directory('$path-$index');
      if (!directory.existsSync()) {
        return directory.create(recursive: true);
      }
      if (_directoryIsEmpty(directory)) {
        return directory;
      }
      index++;
    }
  }

  bool _directoryIsEmpty(Directory directory) {
    try {
      return directory.listSync().isEmpty;
    } on FileSystemException {
      return false;
    }
  }
}

class _JpgWriteRequest {
  const _JpgWriteRequest({required this.path, required this.pngBytes});

  final String path;
  final TransferableTypedData pngBytes;
}

void _writeJpgInWorker(_JpgWriteRequest request) {
  final pngBytes = request.pngBytes.materialize().asUint8List();
  final decoded = img.decodePng(pngBytes);
  if (decoded == null) {
    throw const FormatException('无法生成 JPG');
  }
  File(request.path).writeAsBytesSync(img.encodeJpg(decoded, quality: 92));
}

class _PdfWriteRequest {
  const _PdfWriteRequest({
    required this.path,
    required this.width,
    required this.height,
    required this.pages,
  });

  final String path;
  final int width;
  final int height;
  final List<TransferableTypedData> pages;
}

Future<void> _writePdfInWorker(_PdfWriteRequest request) async {
  final document = pw.Document();
  for (final transferable in request.pages) {
    final pngBytes = transferable.materialize().asUint8List();
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          request.width.toDouble(),
          request.height.toDouble(),
        ),
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Image(pw.MemoryImage(pngBytes), fit: pw.BoxFit.contain),
        ),
      ),
    );
  }
  await File(request.path).writeAsBytes(await document.save());
}

String _safePathSegment(String value, {required String fallback}) {
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[. ]+$'), '');
  final safe = normalized.isEmpty ? fallback : normalized;
  const reservedNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  return reservedNames.contains(safe.toUpperCase()) ? '${safe}_' : safe;
}

class _BoardRenderLayout {
  _BoardRenderLayout({
    required this.board,
    required this.rows,
    required this.columns,
  }) {
    titleHeight = StoryboardBoard.titleHeightFor(board.captionFontSize);
    cellWidth = math.max(1.0, (board.width - gap * (columns + 1)) / columns);
    rowBandHeight = math.max(
      1.0,
      (board.height - titleHeight - gap - gap * (rows + 1)) / rows,
    );
    final showRowCaptions =
        board.storyDescriptionEnabled && board.rowDescriptionEnabled;
    final showItemCaptions =
        board.storyDescriptionEnabled && !board.rowDescriptionEnabled;
    rowCaptionHeight = showRowCaptions
        ? StoryboardBoard.maxRowCaptionHeight(
            width: board.width.toDouble(),
            gap: board.gap,
            rows: rows,
            rowCaptions: board.rowCaptions,
            fontSize: board.captionFontSize,
          )
        : 0.0;
    itemCaptionHeight = showItemCaptions
        ? StoryboardBoard.maxItemCaptionHeight(
            width: board.width.toDouble(),
            gap: board.gap,
            columns: columns,
            items: board.items,
            fontSize: board.captionFontSize,
          )
        : 0.0;
    rowCaptionGap = rowCaptionHeight > 0
        ? math.min(12.0, math.max(6.0, gap * 0.45))
        : 0.0;
    cellHeight = math.max(
      1.0,
      rowBandHeight - rowCaptionHeight - rowCaptionGap,
    );
  }

  final StoryboardBoard board;
  final int rows;
  final int columns;
  late final double cellWidth;
  late final double cellHeight;
  late final double rowBandHeight;
  late final double titleHeight;
  late final double rowCaptionHeight;
  late final double itemCaptionHeight;
  late final double rowCaptionGap;

  double get gap => board.gap;

  double get gridTop => gap + titleHeight + gap;

  Rect get titleRect => Rect.fromLTWH(
    gap,
    gap,
    math.max(1.0, board.width - gap * 2),
    titleHeight,
  );

  Rect slotRect(int index) {
    final row = index ~/ columns;
    final column = index % columns;
    return Rect.fromLTWH(
      gap + column * (cellWidth + gap),
      gridTop + row * (rowBandHeight + gap),
      cellWidth,
      cellHeight,
    );
  }

  Rect rowCaptionRect(int rowIndex) {
    return Rect.fromLTWH(
      gap,
      gridTop + rowIndex * (rowBandHeight + gap) + cellHeight + rowCaptionGap,
      board.width - gap * 2,
      rowCaptionHeight,
    );
  }

  double dividerY(int rowIndex) {
    return gridTop + (rowIndex + 1) * rowBandHeight + (rowIndex + 0.5) * gap;
  }
}
