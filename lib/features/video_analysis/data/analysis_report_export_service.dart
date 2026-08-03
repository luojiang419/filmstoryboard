import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/video_analysis_models.dart';

enum AnalysisReportFormat {
  xlsx('电子表格', 'xlsx'),
  pdf('便携文档', 'pdf'),
  png('无损图片', 'png'),
  jpg('高质量图片', 'jpg');

  const AnalysisReportFormat(this.label, this.extension);

  final String label;
  final String extension;
}

class AnalysisReportExportResult {
  const AnalysisReportExportResult({required this.files});

  final List<File> files;
}

class AnalysisReportExportService {
  const AnalysisReportExportService();

  Future<AnalysisReportExportResult> export({
    required AnalysisReportFormat format,
    required Directory outputDirectory,
    required SourceVideo video,
    required List<VideoFrame> frames,
    required List<VideoFrameAnalysis> frameAnalyses,
    required VideoSummary summary,
    required List<MarketingAnalysis> marketingAnalyses,
    File Function(VideoFrame frame)? resolveFrame,
  }) async {
    await outputDirectory.create(recursive: true);
    final baseName = _safeFileName(
      '${p.basenameWithoutExtension(video.fileName)}视频多维度分析报告',
    );
    final created = <File>[];
    try {
      if (format == AnalysisReportFormat.xlsx) {
        final file = File(p.join(outputDirectory.path, '$baseName.xlsx'));
        await file.writeAsBytes(
          _xlsxBytes(video, frames, frameAnalyses, summary, marketingAnalyses),
          flush: true,
        );
        created.add(file);
      } else {
        final pages = await _renderPages(
          video,
          frames,
          frameAnalyses,
          summary,
          marketingAnalyses,
          resolveFrame: resolveFrame,
        );
        if (format == AnalysisReportFormat.pdf) {
          final document = pw.Document();
          for (final page in pages) {
            document.addPage(
              pw.Page(
                pageFormat: PdfPageFormat.a4,
                margin: pw.EdgeInsets.zero,
                build: (_) =>
                    pw.Image(pw.MemoryImage(page), fit: pw.BoxFit.fill),
              ),
            );
          }
          final file = File(p.join(outputDirectory.path, '$baseName.pdf'));
          await file.writeAsBytes(await document.save(), flush: true);
          created.add(file);
        } else {
          for (var index = 0; index < pages.length; index++) {
            final extension = format.extension;
            final file = File(
              p.join(
                outputDirectory.path,
                '$baseName-第${(index + 1).toString().padLeft(2, '0')}页.$extension',
              ),
            );
            final bytes = format == AnalysisReportFormat.png
                ? pages[index]
                : _pngToJpg(pages[index]);
            await file.writeAsBytes(bytes, flush: true);
            created.add(file);
          }
        }
      }
      return AnalysisReportExportResult(files: created);
    } catch (_) {
      for (final file in created) {
        if (file.existsSync()) {
          await file.delete();
        }
      }
      rethrow;
    }
  }

  Uint8List _xlsxBytes(
    SourceVideo video,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> analyses,
    VideoSummary summary,
    List<MarketingAnalysis> marketing,
  ) {
    final dimensions = marketing.isEmpty
        ? const <String, String>{}
        : marketing.first.dimensions;
    final analysisByFrame = {
      for (final analysis in analyses) analysis.frameId: analysis,
    };
    final sheets = <String, List<List<String>>>{
      '多维度分析': [
        ['分组', '字段', '分析结果'],
        for (final group in videoAnalysisDimensionGroups.entries)
          for (final field in group.value)
            [group.key, field, dimensions[field] ?? ''],
      ],
      '概览': [
        ['字段', '内容'],
        ['视频文件', video.fileName],
        ['时长', _duration(video.durationMs)],
        ['分辨率', '${video.width} × ${video.height}'],
        ['帧率', video.frameRate.toStringAsFixed(2)],
        ['音轨', video.hasAudio ? '有' : '无'],
        ['候选帧', '${frames.length}'],
        [
          '成功解析',
          '${analyses.where((item) => item.status == ProcessingStatus.completed).length}',
        ],
        ['内容大纲', summary.fields['outline'] ?? ''],
        ['内容总结', summary.fields['content'] ?? ''],
      ],
      '镜头明细': [
        [
          '帧缩略图路径',
          '序号',
          '时间戳',
          '状态',
          '画面描述',
          '场景',
          '人物',
          '动作',
          '景别',
          '运镜',
          '构图',
          '光影',
          '色彩',
        ],
        for (final frame in frames)
          [
            frame.path,
            '${frame.index + 1}',
            _duration(frame.timestampMs),
            (analysisByFrame[frame.id]?.status ?? frame.status).name,
            analysisByFrame[frame.id]?.dimensions['caption'] ?? '',
            analysisByFrame[frame.id]?.dimensions['scene'] ?? '',
            analysisByFrame[frame.id]?.dimensions['people'] ?? '',
            analysisByFrame[frame.id]?.dimensions['bodyAction'] ?? '',
            analysisByFrame[frame.id]?.dimensions['shotSize'] ?? '',
            analysisByFrame[frame.id]?.dimensions['cameraMovement'] ?? '',
            analysisByFrame[frame.id]?.dimensions['composition'] ?? '',
            analysisByFrame[frame.id]?.dimensions['lightingMood'] ?? '',
            analysisByFrame[frame.id]?.dimensions['colorPalette'] ?? '',
          ],
      ],
      '模型原始结果': [
        ['序号', '帧 ID', '状态', '错误', '原始结果'],
        for (final analysis in analyses)
          [
            '${analysis.sequenceNo}',
            analysis.frameId,
            analysis.status.name,
            analysis.errorMessage,
            analysis.rawResponse,
          ],
        [
          '视频汇总',
          video.id,
          summary.status.name,
          summary.errorMessage,
          summary.rawResponse,
        ],
      ],
    };
    final entries = <String, Uint8List>{
      '[Content_Types].xml': _utf8(_contentTypes(sheets.length)),
      '_rels/.rels': _utf8(_rootRelationships),
      'xl/workbook.xml': _utf8(_workbook(sheets.keys.toList())),
      'xl/_rels/workbook.xml.rels': _utf8(
        _workbookRelationships(sheets.length),
      ),
      'xl/styles.xml': _utf8(_styles),
    };
    var index = 1;
    for (final rows in sheets.values) {
      entries['xl/worksheets/sheet$index.xml'] = _utf8(_worksheet(rows));
      index++;
    }
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  Future<List<Uint8List>> _renderPages(
    SourceVideo video,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> analyses,
    VideoSummary summary,
    List<MarketingAnalysis> marketing, {
    File Function(VideoFrame frame)? resolveFrame,
  }) async {
    final dimensions = marketing.isEmpty
        ? const <String, String>{}
        : marketing.first.dimensions;
    final reportTitle =
        '${p.basenameWithoutExtension(video.fileName)} 视频多维度分析报告';
    final renderedPages = <Uint8List>[];
    renderedPages.addAll(
      await _renderTablePages(
        title: reportTitle,
        continuationTitle: '多维度分析',
        subtitle:
            '视频：${video.fileName}    时长：${_duration(video.durationMs)}    分辨率：${video.width} × ${video.height}    帧率：${video.frameRate.toStringAsFixed(2)}',
        columns: const ['分组', '分析维度', '分析结果'],
        columnWidths: const [220, 255, 621],
        rows: [
          for (final group in videoAnalysisDimensionGroups.entries)
            for (final field in group.value)
              _ReportTableRow([
                group.key,
                field,
                dimensions[field]?.trim().isNotEmpty == true
                    ? _displayDimensionValue(dimensions[field]!)
                    : '暂无（未在可见画面中确认）',
              ]),
        ],
        mergeFirstColumn: true,
      ),
    );

    renderedPages.addAll(
      await _renderPage([
        _ReportLine('报告概览', level: 0),
        _ReportLine('视频：${video.fileName}'),
        _ReportLine(
          '时长：${_duration(video.durationMs)}    分辨率：${video.width} × ${video.height}    帧率：${video.frameRate.toStringAsFixed(2)}',
        ),
        _ReportLine(
          '候选帧：${frames.length}    成功解析：${analyses.where((item) => item.status == ProcessingStatus.completed).length}',
        ),
        _ReportLine('内容大纲', level: 1),
        _ReportLine(summary.fields['outline'] ?? '暂无'),
        _ReportLine('内容总结', level: 1),
        _ReportLine(summary.fields['content'] ?? '暂无'),
      ]),
    );

    final analysisByFrame = {
      for (final analysis in analyses) analysis.frameId: analysis,
    };
    if (frames.isEmpty) {
      renderedPages.addAll(
        await _renderTablePages(
          title: '镜头明细',
          columns: const ['序号', '时间', '缩略图', '画面 / 场景', '人物 / 动作', '镜头语言'],
          columnWidths: const [72, 100, 190, 250, 250, 234],
          rows: const [
            _ReportTableRow(['-', '-', '-', '暂无可用视频帧', '-', '-']),
          ],
        ),
      );
    } else {
      renderedPages.addAll(
        await _renderTablePages(
          title: '镜头明细',
          subtitle: '缩略图与分析字段按列对齐，便于快速核对画面、动作和镜头语言。',
          columns: const ['序号', '时间', '缩略图', '画面 / 场景', '人物 / 动作', '镜头语言'],
          columnWidths: const [72, 100, 190, 250, 250, 234],
          rows: [
            for (final frame in frames)
              _ReportTableRow(
                [
                  (analysisByFrame[frame.id]?.sequenceNo ?? frame.index + 1)
                      .toString()
                      .padLeft(2, '0'),
                  _duration(frame.timestampMs),
                  '',
                  _shotValue(analysisByFrame[frame.id], 'caption'),
                  '${_shotValue(analysisByFrame[frame.id], 'people')}\n${_shotValue(analysisByFrame[frame.id], 'bodyAction')}',
                  '${_shotValue(analysisByFrame[frame.id], 'shotSize')} / ${_shotValue(analysisByFrame[frame.id], 'cameraMovement')}\n${_shotValue(analysisByFrame[frame.id], 'composition')}',
                ],
                imagePath: _thumbnailPath(frame, resolveFrame),
                imageCellIndex: 2,
              ),
          ],
        ),
      );
    }
    return _addPageNumbers(renderedPages);
  }

  static String _displayDimensionValue(String value) =>
      value.trim().replaceFirst(RegExp(r'^证据\s*[：:]\s*'), '');

  String _shotValue(VideoFrameAnalysis? analysis, String key) {
    final dimensions = analysis?.dimensions ?? const <String, String>{};
    return dimensions[key]?.trim().isNotEmpty == true ? dimensions[key]! : '暂无';
  }

  String? _thumbnailPath(
    VideoFrame frame,
    File Function(VideoFrame frame)? resolveFrame,
  ) {
    final file = resolveFrame?.call(frame) ?? File(frame.path);
    return file.existsSync() ? file.path : null;
  }

  Future<List<Uint8List>> _renderTablePages({
    required String title,
    String? subtitle,
    String? continuationTitle,
    required List<String> columns,
    required List<double> columnWidths,
    required List<_ReportTableRow> rows,
    bool mergeFirstColumn = false,
  }) async {
    const width = 1240.0;
    const height = 1754.0;
    const bottomPadding = 90.0;
    final header = _ReportTableRow(columns);
    final headerHeight = _tableRowHeight(header, columnWidths, isHeader: true);
    final chunks = <List<_ReportTableRow>>[];
    var currentChunk = <_ReportTableRow>[];
    var y = _tableStartY(title, subtitle) + headerHeight;

    for (final row in rows) {
      final rowHeight = _tableRowHeight(row, columnWidths);
      if (currentChunk.isNotEmpty && y + rowHeight > height - bottomPadding) {
        chunks.add(currentChunk);
        currentChunk = <_ReportTableRow>[];
        y = _tableStartY(title, subtitle) + headerHeight;
      }
      currentChunk.add(row);
      y += rowHeight;
    }
    if (currentChunk.isNotEmpty || chunks.isEmpty) {
      chunks.add(currentChunk);
    }

    final renderedPages = <Uint8List>[];
    for (var index = 0; index < chunks.length; index++) {
      renderedPages.add(
        await _renderTablePage(
          title: index == 0 ? title : continuationTitle ?? title,
          subtitle: index == 0 ? subtitle : null,
          header: header,
          rows: chunks[index],
          columnWidths: columnWidths,
          width: width,
          height: height,
          mergeFirstColumn: mergeFirstColumn,
        ),
      );
    }
    return renderedPages;
  }

  double _tableStartY(String title, String? subtitle) {
    const width = 1096.0;
    final titleParagraph = _tableParagraph(
      title,
      width: width,
      fontSize: 34,
      bold: true,
      color: const ui.Color(0xFF1A237E),
    );
    var y = 62.0 + titleParagraph.height + 10;
    if (subtitle != null && subtitle.trim().isNotEmpty) {
      final subtitleParagraph = _tableParagraph(
        subtitle,
        width: width,
        fontSize: 16,
        color: const ui.Color(0xFF5F6368),
      );
      y += subtitleParagraph.height + 12;
    }
    return y + 4;
  }

  double _tableRowHeight(
    _ReportTableRow row,
    List<double> columnWidths, {
    bool isHeader = false,
  }) {
    var height = isHeader ? 34.0 : 24.0;
    for (var index = 0; index < row.cells.length; index++) {
      final isImageCell =
          row.imagePath != null &&
          row.imageCellIndex == index &&
          row.imagePath!.isNotEmpty;
      if (isImageCell) {
        height = math.max(height, 100.0);
        continue;
      }
      final paragraph = _tableParagraph(
        row.cells[index],
        width: columnWidths[index] - 16,
        fontSize: isHeader ? 15 : 14,
        bold: isHeader,
        color: isHeader
            ? const ui.Color(0xFF1A237E)
            : const ui.Color(0xFF202124),
      );
      height = math.max(height, paragraph.height + 16);
    }
    return height;
  }

  ui.Paragraph _tableParagraph(
    String text, {
    required double width,
    required double fontSize,
    bool bold = false,
    required ui.Color color,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: fontSize,
              fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
              height: 1.25,
            ),
          )
          ..pushStyle(ui.TextStyle(color: color))
          ..addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: width));
  }

  Future<Uint8List> _renderTablePage({
    required String title,
    required String? subtitle,
    required _ReportTableRow header,
    required List<_ReportTableRow> rows,
    required List<double> columnWidths,
    required double width,
    required double height,
    required bool mergeFirstColumn,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFF7F8FA), ui.BlendMode.src);
    final accent = ui.Paint()..color = const ui.Color(0xFF3F51B5);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, width, 20), accent);

    final titleParagraph = _tableParagraph(
      title,
      width: width - 144,
      fontSize: 34,
      bold: true,
      color: const ui.Color(0xFF1A237E),
    );
    var y = 62.0;
    canvas.drawParagraph(titleParagraph, ui.Offset(72, y));
    y += titleParagraph.height + 10;
    if (subtitle != null && subtitle.trim().isNotEmpty) {
      final subtitleParagraph = _tableParagraph(
        subtitle,
        width: width - 144,
        fontSize: 16,
        color: const ui.Color(0xFF5F6368),
      );
      canvas.drawParagraph(subtitleParagraph, ui.Offset(72, y));
      y += subtitleParagraph.height + 12;
    }
    y += 4;

    final headerHeight = _tableRowHeight(header, columnWidths, isHeader: true);
    await _drawTableRow(
      canvas,
      header,
      rowTop: y,
      rowHeight: headerHeight,
      columnWidths: columnWidths,
      isHeader: true,
    );
    y += headerHeight;
    final rowTops = <double>[];
    final rowHeights = <double>[];
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final rowHeight = _tableRowHeight(row, columnWidths);
      rowTops.add(y);
      rowHeights.add(rowHeight);
      await _drawTableRow(
        canvas,
        row,
        rowTop: y,
        rowHeight: rowHeight,
        columnWidths: columnWidths,
        isHeader: false,
        alternate: index.isOdd,
        skipFirstColumn: mergeFirstColumn,
      );
      y += rowHeight;
    }
    if (mergeFirstColumn) {
      _drawMergedFirstColumnCells(
        canvas,
        rows: rows,
        rowTops: rowTops,
        rowHeights: rowHeights,
        columnWidth: columnWidths.first,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) {
      throw StateError('分析报告页面渲染失败');
    }
    return data.buffer.asUint8List();
  }

  Future<void> _drawTableRow(
    ui.Canvas canvas,
    _ReportTableRow row, {
    required double rowTop,
    required double rowHeight,
    required List<double> columnWidths,
    required bool isHeader,
    bool alternate = false,
    bool skipFirstColumn = false,
  }) async {
    const left = 72.0;
    final background = ui.Paint()
      ..color = isHeader
          ? const ui.Color(0xFFE1E6F4)
          : (alternate
                ? const ui.Color(0xFFF0F2F7)
                : const ui.Color(0xFFFFFFFF));
    final border = ui.Paint()
      ..color = const ui.Color(0xFFC9CEDA)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    var leftOffset = left;
    for (var index = 0; index < columnWidths.length; index++) {
      final cellWidth = columnWidths[index];
      if (skipFirstColumn && index == 0) {
        leftOffset += cellWidth;
        continue;
      }
      final rect = ui.Rect.fromLTWH(leftOffset, rowTop, cellWidth, rowHeight);
      canvas.drawRect(rect, background);
      canvas.drawRect(rect, border);
      final isImageCell =
          row.imagePath != null &&
          row.imageCellIndex == index &&
          row.imagePath!.isNotEmpty;
      if (isImageCell) {
        final image = await _decodeImage(File(row.imagePath!));
        if (image != null) {
          final destination = ui.Rect.fromLTWH(
            leftOffset + 8,
            rowTop + 8,
            cellWidth - 16,
            math.min(84, rowHeight - 16),
          );
          _drawImageCover(canvas, image, destination);
          image.dispose();
        }
      } else {
        final paragraph = _tableParagraph(
          row.cells[index],
          width: cellWidth - 16,
          fontSize: isHeader ? 15 : 14,
          bold: isHeader,
          color: isHeader
              ? const ui.Color(0xFF1A237E)
              : const ui.Color(0xFF202124),
        );
        canvas.drawParagraph(paragraph, ui.Offset(leftOffset + 8, rowTop + 8));
      }
      leftOffset += cellWidth;
    }
  }

  void _drawMergedFirstColumnCells(
    ui.Canvas canvas, {
    required List<_ReportTableRow> rows,
    required List<double> rowTops,
    required List<double> rowHeights,
    required double columnWidth,
  }) {
    const left = 72.0;
    final border = ui.Paint()
      ..color = const ui.Color(0xFFC9CEDA)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1;
    var start = 0;
    while (start < rows.length) {
      final group = rows[start].cells.first;
      var end = start + 1;
      while (end < rows.length && rows[end].cells.first == group) {
        end++;
      }
      final top = rowTops[start];
      final height = rowTops[end - 1] + rowHeights[end - 1] - top;
      final rect = ui.Rect.fromLTWH(left, top, columnWidth, height);
      canvas.drawRect(
        rect,
        ui.Paint()
          ..color = start.isOdd
              ? const ui.Color(0xFFF0F2F7)
              : const ui.Color(0xFFFFFFFF),
      );
      canvas.drawRect(rect, border);
      final paragraph = _tableParagraph(
        group,
        width: columnWidth - 16,
        fontSize: 14,
        color: const ui.Color(0xFF202124),
      );
      canvas.drawParagraph(
        paragraph,
        ui.Offset(left + 8, top + (height - paragraph.height) / 2),
      );
      start = end;
    }
  }

  Future<List<Uint8List>> _addPageNumbers(List<Uint8List> pages) async {
    final numberedPages = <Uint8List>[];
    for (var index = 0; index < pages.length; index++) {
      numberedPages.add(
        await _addPageNumber(
          pages[index],
          pageNumber: index + 1,
          totalPages: pages.length,
        ),
      );
    }
    return numberedPages;
  }

  Future<Uint8List> _addPageNumber(
    Uint8List page, {
    required int pageNumber,
    required int totalPages,
  }) async {
    const width = 1240.0;
    const height = 1754.0;
    final codec = await ui.instantiateImageCodec(page);
    final frame = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(frame.image, ui.Offset.zero, ui.Paint());
    final paragraph = _tableParagraph(
      '第 $pageNumber / $totalPages 页',
      width: 160,
      fontSize: 14,
      color: const ui.Color(0xFF5F6368),
    );
    canvas.drawParagraph(paragraph, ui.Offset(width - 72 - 160, height - 48));
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    frame.image.dispose();
    codec.dispose();
    if (data == null) {
      throw StateError('分析报告页码渲染失败');
    }
    return data.buffer.asUint8List();
  }

  Future<List<Uint8List>> _renderPage(List<_ReportLine> lines) async {
    const width = 1240.0;
    const height = 1754.0;
    const bottomPadding = 90.0;
    final pageLines = <List<_ReportLine>>[];
    var currentPage = <_ReportLine>[];
    var y = 72.0;

    for (final line in lines) {
      final metrics = _lineMetrics(line, width);
      final lineHeight = metrics.contentHeight + (line.level == 0 ? 30 : 16);
      if (currentPage.isNotEmpty && y + lineHeight > height - bottomPadding) {
        pageLines.add(currentPage);
        currentPage = <_ReportLine>[];
        y = 72.0;
      }
      currentPage.add(line);
      y += lineHeight;
    }
    if (currentPage.isNotEmpty) {
      pageLines.add(currentPage);
    }
    return Future.wait(
      pageLines.map((page) => _renderSinglePage(page, width, height)),
    );
  }

  _ReportLineMetrics _lineMetrics(_ReportLine line, double width) {
    final isTitle = line.level == 0;
    final isSection = line.level == 1;
    final fontSize = isTitle ? 40.0 : (isSection ? 25.0 : 19.0);
    final textWidth = width - 144;
    final paragraphBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: fontSize,
              fontWeight: isTitle || isSection
                  ? ui.FontWeight.w700
                  : ui.FontWeight.w400,
              height: 1.45,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: isTitle
                  ? const ui.Color(0xFF1A237E)
                  : const ui.Color(0xFF202124),
            ),
          )
          ..addText(line.text);
    final paragraph = paragraphBuilder.build()
      ..layout(ui.ParagraphConstraints(width: textWidth));
    return _ReportLineMetrics(
      paragraph: paragraph,
      contentHeight: paragraph.height,
    );
  }

  Future<Uint8List> _renderSinglePage(
    List<_ReportLine> lines,
    double width,
    double height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFF7F8FA), ui.BlendMode.src);
    final accent = ui.Paint()..color = const ui.Color(0xFF3F51B5);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, width, 20), accent);
    var y = 72.0;
    for (final line in lines) {
      final isTitle = line.level == 0;
      final isSection = line.level == 1;
      final fontSize = isTitle ? 40.0 : (isSection ? 25.0 : 19.0);
      final textWidth = width - 144;
      final paragraph =
          (ui.ParagraphBuilder(
              ui.ParagraphStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: fontSize,
                fontWeight: isTitle || isSection
                    ? ui.FontWeight.w700
                    : ui.FontWeight.w400,
                height: 1.45,
              ),
            )..pushStyle(
              ui.TextStyle(
                color: isTitle
                    ? const ui.Color(0xFF1A237E)
                    : const ui.Color(0xFF202124),
              ),
            ))
            ..addText(line.text);
      final built = paragraph.build()
        ..layout(ui.ParagraphConstraints(width: textWidth));
      canvas.drawParagraph(built, ui.Offset(72, y));
      y += built.height + (isTitle ? 30 : 16);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) {
      throw StateError('分析报告页面渲染失败');
    }
    return data.buffer.asUint8List();
  }

  Future<ui.Image?> _decodeImage(File file) async {
    try {
      final codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 360,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void _drawImageCover(ui.Canvas canvas, ui.Image image, ui.Rect destination) {
    final sourceAspect = image.width / image.height;
    final destinationAspect = destination.width / destination.height;
    ui.Rect source;
    if (sourceAspect > destinationAspect) {
      final sourceWidth = image.height * destinationAspect;
      source = ui.Rect.fromLTWH(
        (image.width - sourceWidth) / 2,
        0,
        sourceWidth,
        image.height.toDouble(),
      );
    } else {
      final sourceHeight = image.width / destinationAspect;
      source = ui.Rect.fromLTWH(
        0,
        (image.height - sourceHeight) / 2,
        image.width.toDouble(),
        sourceHeight,
      );
    }
    canvas.drawImageRect(image, source, destination, ui.Paint());
  }

  Uint8List _pngToJpg(Uint8List png) {
    final decoded = img.decodePng(png);
    if (decoded == null) {
      throw StateError('报告页面无法转换为 JPG');
    }
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
  }

  String _worksheet(List<List<String>> rows) {
    final buffer = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    );
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      buffer.write('<row r="${rowIndex + 1}">');
      for (
        var columnIndex = 0;
        columnIndex < rows[rowIndex].length;
        columnIndex++
      ) {
        final reference = '${_columnName(columnIndex)}${rowIndex + 1}';
        buffer.write(
          '<c r="$reference" t="inlineStr"><is><t xml:space="preserve">'
          '${_xml(rows[rowIndex][columnIndex])}</t></is></c>',
        );
      }
      buffer.write('</row>');
    }
    buffer.write('</sheetData></worksheet>');
    return buffer.toString();
  }

  String _workbook(List<String> names) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>${[for (var i = 0; i < names.length; i++) '<sheet name="${_xml(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>';

  String _workbookRelationships(int count) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${[for (var i = 1; i <= count; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
      '<Relationship Id="rId${count + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';

  String _contentTypes(int count) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '${[for (var i = 1; i <= count; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '</Types>';

  static const _rootRelationships =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';

  static const _styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="1"><font><sz val="11"/><name val="Microsoft YaHei"/><family val="2"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';

  static Uint8List _utf8(String value) =>
      Uint8List.fromList(utf8.encode(value));

  static String _columnName(int index) {
    var value = index + 1;
    var result = '';
    while (value > 0) {
      value--;
      result = String.fromCharCode(65 + value % 26) + result;
      value ~/= 26;
    }
    return result;
  }

  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();

  static String _duration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$minutes:$seconds.$millis';
  }
}

class _ReportLine {
  const _ReportLine(this.text, {this.level = 2});

  final String text;
  final int level;
}

class _ReportLineMetrics {
  const _ReportLineMetrics({
    required this.paragraph,
    required this.contentHeight,
  });

  final ui.Paragraph paragraph;
  final double contentHeight;
}

class _ReportTableRow {
  const _ReportTableRow(this.cells, {this.imagePath, this.imageCellIndex});

  final List<String> cells;
  final String? imagePath;
  final int? imageCellIndex;
}
