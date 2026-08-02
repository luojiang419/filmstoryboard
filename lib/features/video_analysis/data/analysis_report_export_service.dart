import 'dart:convert';
import 'dart:io';
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
      '多维度分析': [
        ['分组', '字段', '分析结果'],
        for (final group in videoAnalysisDimensionGroups.entries)
          for (final field in group.value)
            [group.key, field, dimensions[field] ?? ''],
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
    List<MarketingAnalysis> marketing,
  ) async {
    final pages = <List<String>>[
      [
        '${p.basenameWithoutExtension(video.fileName)} 视频多维度分析报告',
        '报告概览',
        '视频：${video.fileName}',
        '时长：${_duration(video.durationMs)}    分辨率：${video.width} × ${video.height}    帧率：${video.frameRate.toStringAsFixed(2)}',
        '候选帧：${frames.length}    成功解析：${analyses.where((item) => item.status == ProcessingStatus.completed).length}',
        '',
        '内容大纲',
        summary.fields['outline'] ?? '暂无',
        '',
        '内容总结',
        summary.fields['content'] ?? '暂无',
      ],
    ];
    for (var start = 0; start < analyses.length; start += 6) {
      final chunk = analyses.skip(start).take(6);
      pages.add([
        '镜头明细 ${start + 1}–${start + chunk.length}',
        for (final analysis in chunk) ...[
          '',
          '镜头 ${analysis.sequenceNo.toString().padLeft(2, '0')}',
          analysis.dimensions['caption'] ?? '暂无画面描述',
          '场景：${analysis.dimensions['scene'] ?? ''}',
          '人物/动作：${analysis.dimensions['people'] ?? ''}；${analysis.dimensions['bodyAction'] ?? ''}',
          '景别/运镜/构图：${analysis.dimensions['shotSize'] ?? ''}；${analysis.dimensions['cameraMovement'] ?? ''}；${analysis.dimensions['composition'] ?? ''}',
        ],
      ]);
    }
    final dimensions = marketing.isEmpty
        ? const <String, String>{}
        : marketing.first.dimensions;
    pages.add([
      '多维度分析',
      for (final group in videoAnalysisDimensionGroups.entries) ...[
        '',
        group.key,
        for (final field in group.value)
          '$field：${dimensions[field]?.trim().isNotEmpty == true ? dimensions[field] : '暂无'}',
      ],
    ]);
    return Future.wait(pages.map(_renderPage));
  }

  Future<Uint8List> _renderPage(List<String> lines) async {
    const width = 1240.0;
    const height = 1754.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFF7F8FA), ui.BlendMode.src);
    final accent = ui.Paint()..color = const ui.Color(0xFF3F51B5);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, width, 20), accent);
    var y = 72.0;
    for (var index = 0; index < lines.length; index++) {
      if (y > height - 90) {
        break;
      }
      final line = lines[index];
      final isTitle = index == 0;
      final isSection =
          !isTitle &&
          line.isNotEmpty &&
          !line.contains('：') &&
          line.length < 24;
      final fontSize = isTitle ? 40.0 : (isSection ? 25.0 : 19.0);
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
            ..addText(line);
      final built = paragraph.build()
        ..layout(const ui.ParagraphConstraints(width: width - 144));
      canvas.drawParagraph(built, ui.Offset(72, y));
      y += built.height + (isTitle ? 30 : 10);
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
