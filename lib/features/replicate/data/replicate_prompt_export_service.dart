import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../shooting_script/domain/shooting_script_models.dart';
import '../domain/replicate_models.dart';

/// 将步骤 3 的表格数据导出为可继续编辑的 XLSX。
///
/// 复用拍摄脚本模板的字体、边框和冻结行样式，但按步骤 3 的列顺序
/// 重新构造工作表；“操作”列属于界面交互，不写入文件。
class ReplicatePromptExportService {
  const ReplicatePromptExportService();

  static const _templateAsset = 'docs/拍摄脚本模版.xlsx';
  static const _firstDataRow = 3;
  static const _templateLastDataRow = 15;
  static const _imageWidth = 168;
  static const _imageHeight = 112;

  static const _headers = [
    '复刻分镜',
    '镜号',
    '时长',
    '画面描述',
    '景别',
    '构图',
    '机位',
    '光影/氛围',
    '色彩',
    '视觉焦点',
    '剪辑衔接',
    '对白/旁白',
    '音效',
    '运镜',
    '最终提示词',
  ];

  Future<File> export({
    required ShootingScript script,
    required List<ScriptShot> shots,
    required List<ShotPrompt> prompts,
    required List<ReplicatedShotImage> replicatedImages,
    required String outputPath,
  }) async {
    if (prompts.isEmpty) {
      throw const FormatException('当前没有可导出的提示词');
    }

    final templateData = await rootBundle.load(_templateAsset);
    final entries = _readArchive(
      templateData.buffer.asUint8List(
        templateData.offsetInBytes,
        templateData.lengthInBytes,
      ),
    );
    final templateSheet = _textEntry(entries, 'xl/worksheets/sheet1.xml');
    final workbookXml = _textEntry(entries, 'xl/workbook.xml');
    final contentTypesXml = _textEntry(entries, '[Content_Types].xml');
    final shotById = <String, ScriptShot>{
      for (final shot in shots) shot.id: shot,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in replicatedImages) image.scriptShotId: image,
    };
    final sortedPrompts = [...prompts]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final rows = <_PromptExportRow>[];
    for (final prompt in sortedPrompts) {
      final shot = prompt.scriptShotId == null
          ? null
          : shotById[prompt.scriptShotId];
      rows.add(
        await _PromptExportRow.fromShot(
          shot: shot,
          prompt: prompt,
          replicatedImage: shot == null ? null : replicaByShotId[shot.id],
        ),
      );
    }

    final imageRefs = <_PromptImageRef>[];
    var nextImageNumber = 1;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final pngBytes = row.pngBytes;
      if (pngBytes == null) {
        continue;
      }
      final imageName = 'image$nextImageNumber.png';
      nextImageNumber++;
      entries['xl/media/$imageName'] = pngBytes;
      imageRefs.add(
        _PromptImageRef(
          relationshipId: 'rId${imageRefs.length + 1}',
          imageName: imageName,
          row: _firstDataRow + index,
          width: row.displayWidth,
          height: row.displayHeight,
        ),
      );
    }

    final dataEndRow = math.max(
      _templateLastDataRow,
      _firstDataRow + rows.length - 1,
    );
    entries['xl/worksheets/sheet1.xml'] = utf8.encode(
      _buildSheetXml(
        templateSheet,
        rows,
        dataEndRow,
        hasImages: imageRefs.isNotEmpty,
        title: '${script.name} · 合成提示词',
      ),
    );
    entries['xl/workbook.xml'] = utf8.encode(
      _workbookXml(workbookXml, _safeSheetName(script.name)),
    );
    if (imageRefs.isNotEmpty) {
      entries['xl/worksheets/_rels/sheet1.xml.rels'] = utf8.encode(
        _worksheetRelationshipsXml(),
      );
      entries['xl/drawings/drawing1.xml'] = utf8.encode(_drawingXml(imageRefs));
      entries['xl/drawings/_rels/drawing1.xml.rels'] = utf8.encode(
        _drawingRelationshipsXml(imageRefs),
      );
    }
    entries['[Content_Types].xml'] = utf8.encode(
      _contentTypesXml(contentTypesXml, hasImages: imageRefs.isNotEmpty),
    );

    final output = Archive();
    for (final entry in entries.entries) {
      output.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final file = File(_ensureXlsxExtension(outputPath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encodeBytes(output), flush: true);
    return file;
  }

  Map<String, Uint8List> _readArchive(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final result = <String, Uint8List>{};
    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }
      final content = file.readBytes();
      if (content == null) {
        throw FormatException('拍摄脚本模板无法读取：${file.name}');
      }
      result[file.name] = Uint8List.fromList(content);
    }
    return result;
  }

  String _textEntry(Map<String, Uint8List> entries, String path) {
    final value = entries[path];
    if (value == null) {
      throw FormatException('拍摄脚本模板缺少文件：$path');
    }
    return utf8.decode(value);
  }

  String _buildSheetXml(
    String template,
    List<_PromptExportRow> rows,
    int dataEndRow, {
    required bool hasImages,
    required String title,
  }) {
    final dataMatch = RegExp(
      r'<sheetData>.*?</sheetData>',
      dotAll: true,
    ).firstMatch(template);
    if (dataMatch == null) {
      throw const FormatException('拍摄脚本模板缺少数据行');
    }
    final sheetData = dataMatch.group(0)!;
    final sourceTitleRow = _extractRow(sheetData, 1);
    final sourceHeaderRow = _extractRow(sheetData, 2);
    final sourceDataRow = _extractRow(sheetData, _firstDataRow);
    final outputRows = StringBuffer()
      ..write(_titleRow(sourceTitleRow, title))
      ..write(_headerRow(sourceHeaderRow));
    for (var row = _firstDataRow; row <= dataEndRow; row++) {
      final index = row - _firstDataRow;
      outputRows.write(
        _dataRow(sourceDataRow, row, index < rows.length ? rows[index] : null),
      );
    }

    var result = template.replaceRange(
      dataMatch.start,
      dataMatch.end,
      '<sheetData>${outputRows.toString()}</sheetData>',
    );
    result = result.replaceFirst(
      RegExp(r'<dimension ref="A1:Y\d+"/>'),
      '<dimension ref="A1:O$dataEndRow"/>',
    );
    result = result.replaceFirst(
      RegExp(r'<cols>.*?</cols>', dotAll: true),
      _columnsXml(),
    );
    result = result.replaceAll(
      RegExp(r'<mergeCells.*?</mergeCells>', dotAll: true),
      '<mergeCells count="1"><mergeCell ref="A1:O1"/></mergeCells>',
    );
    result = result.replaceAll(
      RegExp(r'<dataValidations.*?</dataValidations>', dotAll: true),
      '',
    );
    result = result.replaceAll(RegExp(r'<drawing\b[^>]*/>'), '');
    result = result.replaceAll(
      'activeCell="R4" sqref="R4"',
      'activeCell="A3" sqref="A3"',
    );
    if (hasImages && !result.contains('<drawing ')) {
      final pageMargins = RegExp(r'<pageMargins\b[^>]*/>').firstMatch(result);
      if (pageMargins == null) {
        throw const FormatException('拍摄脚本模板缺少页边距设置');
      }
      result = result.replaceRange(
        pageMargins.start,
        pageMargins.end,
        '${pageMargins.group(0)}<drawing r:id="rId1"/>',
      );
    }
    return result;
  }

  String _titleRow(String source, String title) {
    return _rowWithCells(source, 1, [
      _cell('A', 1, title, style: 14),
      for (final column in _columns.skip(1)) _cell(column, 1, '', style: 15),
    ]);
  }

  String _headerRow(String source) {
    return _rowWithCells(source, 2, [
      for (var index = 0; index < _headers.length; index++)
        _cell(_columns[index], 2, _headers[index], style: index == 0 ? 3 : 4),
    ]);
  }

  String _dataRow(String source, int row, _PromptExportRow? data) {
    final values =
        data?.values ??
        const <String>[
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ];
    final cells = <String>[];
    for (var index = 0; index < _columns.length; index++) {
      final column = _columns[index];
      final value = values[index];
      final numeric = index == 1 || index == 2;
      final style = switch (index) {
        0 => 7,
        1 || 2 || 4 => 6,
        3 => 8,
        _ => 9,
      };
      cells.add(_cell(column, row, value, style: style, numeric: numeric));
    }
    return _rowWithCells(source, row, cells);
  }

  String _rowWithCells(String source, int row, List<String> cells) {
    final start = source.indexOf('>');
    final end = source.lastIndexOf('</row>');
    if (start < 0 || end < 0 || end <= start) {
      throw const FormatException('拍摄脚本模板行格式无效');
    }
    var attributes = source.substring(0, start + 1);
    attributes = attributes.replaceFirst(RegExp(r'r="\d+"'), 'r="$row"');
    attributes = attributes.replaceFirst(
      RegExp(r'spans="[^"]+"'),
      'spans="1:15"',
    );
    return '$attributes${cells.join()}</row>';
  }

  String _cell(
    String column,
    int row,
    String value, {
    required int style,
    bool numeric = false,
  }) {
    final sanitized = value.trim();
    if (sanitized.isEmpty) {
      return '<c r="$column$row" s="$style"/>';
    }
    if (numeric) {
      return '<c r="$column$row" s="$style"><v>${_xmlEscape(sanitized)}</v></c>';
    }
    return '<c r="$column$row" s="$style" t="inlineStr"><is><t>${_xmlEscape(sanitized)}</t></is></c>';
  }

  String _extractRow(String sheetData, int row) {
    final match = RegExp(
      '<row r="$row".*?</row>',
      dotAll: true,
    ).firstMatch(sheetData);
    if (match == null) {
      throw FormatException('拍摄脚本模板缺少第 $row 行');
    }
    return match.group(0)!;
  }

  String _columnsXml() {
    const widths = [24, 8, 9, 62, 11, 24, 18, 26, 22, 24, 24, 34, 22, 22, 70];
    final columns = StringBuffer('<cols>');
    for (var index = 0; index < widths.length; index++) {
      final number = index + 1;
      columns.write(
        '<col min="$number" max="$number" width="${widths[index]}" customWidth="1"/>',
      );
    }
    columns.write('</cols>');
    return columns.toString();
  }

  String _workbookXml(String template, String sheetName) {
    return template.replaceFirst(
      RegExp(r'<sheet name="[^"]+"'),
      '<sheet name="${_xmlEscape(sheetName)}"',
    );
  }

  String _contentTypesXml(String template, {required bool hasImages}) {
    final extras = StringBuffer();
    if (!template.contains('Extension="png"')) {
      extras.write('<Default Extension="png" ContentType="image/png"/>');
    }
    if (hasImages && !template.contains('/xl/drawings/drawing1.xml')) {
      extras.write(
        '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>',
      );
    }
    return template.replaceFirst('</Types>', '$extras</Types>');
  }

  String _worksheetRelationshipsXml() {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>'
        '</Relationships>';
  }

  String _drawingXml(List<_PromptImageRef> images) {
    final anchors = StringBuffer();
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      anchors.write('''
<xdr:oneCellAnchor>
<xdr:from><xdr:col>0</xdr:col><xdr:colOff>47625</xdr:colOff><xdr:row>${image.row - 1}</xdr:row><xdr:rowOff>47625</xdr:rowOff></xdr:from>
<xdr:ext cx="${image.width * 9525}" cy="${image.height * 9525}"/>
<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="${index + 1}" name="复刻分镜${index + 1}"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="${image.relationshipId}"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${image.width * 9525}" cy="${image.height * 9525}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/>
</xdr:oneCellAnchor>''');
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">$anchors</xdr:wsDr>';
  }

  String _drawingRelationshipsXml(List<_PromptImageRef> images) {
    final relations = images
        .map(
          (image) =>
              '<Relationship Id="${image.relationshipId}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/${image.imageName}"/>',
        )
        .join();
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$relations</Relationships>';
  }

  String _safeSheetName(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'[\\/:?*\[\]]'), '_');
    final base = normalized.isEmpty ? '合成提示词' : normalized;
    const suffix = '-提示词';
    if (base.length <= 31) {
      return base;
    }
    return '${base.substring(0, 31 - suffix.length)}$suffix';
  }

  String _ensureXlsxExtension(String path) {
    return p.extension(path).toLowerCase() == '.xlsx' ? path : '$path.xlsx';
  }

  String _xmlEscape(String value) {
    final sanitized = String.fromCharCodes(
      value.runes.where(
        (character) =>
            character == 0x9 ||
            character == 0xA ||
            character == 0xD ||
            (character >= 0x20 && character <= 0xD7FF) ||
            (character >= 0xE000 && character <= 0xFFFD) ||
            (character >= 0x10000 && character <= 0x10FFFF),
      ),
    );
    return sanitized
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static const _columns = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
  ];
}

class _PromptExportRow {
  const _PromptExportRow({
    required this.values,
    required this.pngBytes,
    required this.displayWidth,
    required this.displayHeight,
  });

  final List<String> values;
  final Uint8List? pngBytes;
  final int displayWidth;
  final int displayHeight;

  static Future<_PromptExportRow> fromShot({
    required ScriptShot? shot,
    required ShotPrompt prompt,
    required ReplicatedShotImage? replicatedImage,
  }) async {
    Uint8List? pngBytes;
    var displayWidth = 1;
    var displayHeight = 1;
    final generatedPath = replicatedImage?.generatedFramePath.trim() ?? '';
    final imagePath =
        generatedPath.isNotEmpty && File(generatedPath).existsSync()
        ? generatedPath
        : shot?.framePath.trim() ?? '';
    if (imagePath.isNotEmpty && File(imagePath).existsSync()) {
      try {
        final image = img.decodeImage(await File(imagePath).readAsBytes());
        if (image != null) {
          final scale = math.min(
            ReplicatePromptExportService._imageWidth / image.width,
            ReplicatePromptExportService._imageHeight / image.height,
          );
          pngBytes = Uint8List.fromList(img.encodePng(image));
          displayWidth = math.max(1, (image.width * scale).round());
          displayHeight = math.max(1, (image.height * scale).round());
        }
      } on Object {
        // 导出提示词不应因为某一帧损坏而失败，图片槽位保持空白即可。
      }
    }
    return _PromptExportRow(
      values: [
        '',
        '${shot?.shotNumber ?? prompt.shotNumber}',
        shot == null ? '' : _durationText(shot.durationSeconds),
        shot?.content ?? '',
        shot?.shotSize ?? '',
        shot?.composition ?? '',
        shot?.cameraAngle ?? '',
        shot?.lightingMood ?? '',
        shot?.colorPalette ?? '',
        shot?.visualFocus ?? '',
        shot?.transitionHint ?? '',
        shot?.dialogue ?? '',
        shot?.sound ?? '',
        shot?.cameraMovement ?? '',
        prompt.prompt,
      ],
      pngBytes: pngBytes,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
    );
  }

  static String _durationText(double seconds) {
    if (seconds == seconds.roundToDouble()) {
      return seconds.toInt().toString();
    }
    return seconds.toStringAsFixed(1);
  }
}

class _PromptImageRef {
  const _PromptImageRef({
    required this.relationshipId,
    required this.imageName,
    required this.row,
    required this.width,
    required this.height,
  });

  final String relationshipId;
  final String imageName;
  final int row;
  final int width;
  final int height;
}
