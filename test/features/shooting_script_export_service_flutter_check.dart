import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/exporter/data/shooting_script_export_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认文件名使用画板名称、拍摄脚本和日期', () {
    expect(
      shootingScriptExportFileName(
        boardName: '  画板:01/镜头*  ',
        date: DateTime(2026, 7, 12),
      ),
      '画板_01_镜头_-拍摄脚本-20260712.xlsx',
    );
    expect(
      shootingScriptExportFileName(
        boardName: '   ',
        date: DateTime(2026, 7, 12),
      ),
      '画板-拍摄脚本-20260712.xlsx',
    );
  });

  test('拍摄脚本在一个文件中创建多个画板 Sheet，并按当前顺序写入字段和图片', () async {
    final root = await Directory.systemTemp.createTemp('shooting_script_');
    addTearDown(() => root.delete(recursive: true));
    final firstImage = await _writeImage(root, 'first.png', 255, 0, 0);
    final secondImage = await _writeImage(root, 'second.png', 0, 0, 255);
    final output = await const ShootingScriptExportService().export(
      boards: [
        _board(
          id: 'board-1',
          name: '画板/一',
          items: [
            _item(secondImage, id: 'second', slotIndex: 1, caption: ''),
            _item(firstImage, id: 'first', slotIndex: 0, caption: '人工确认内容'),
          ],
        ),
        _board(
          id: 'board-2',
          name: '画板二',
          items: [_item(firstImage, id: 'third', slotIndex: 0, caption: '第二页')],
        ),
      ],
      analysisBatches: {
        'board-1': _batch('board-1', [
          _analysis(
            id: 'a-first',
            boardId: 'board-1',
            assetId: 'first',
            caption: '解析短句',
            detail: '解析详情',
            shotSize: '近景',
            cameraMovement: '推',
          ),
          _analysis(
            id: 'a-second',
            boardId: 'board-1',
            assetId: 'second',
            caption: '第二镜解析',
            detail: '第二镜详情',
            shotSize: '全景',
            cameraMovement: '固定',
          ),
        ]),
        'board-2': _batch('board-2', [
          _analysis(
            id: 'a-third',
            boardId: 'board-2',
            assetId: 'third',
            caption: '第三镜解析',
            detail: '第三镜详情',
            shotSize: '中景',
            cameraMovement: '摇',
          ),
        ]),
      },
      outputPath: '${root.path}${Platform.pathSeparator}shooting-script.xlsx',
    );

    final files = _archiveFiles(await output.readAsBytes());
    final workbook = utf8.decode(files['xl/workbook.xml']!);
    final firstSheet = utf8.decode(files['xl/worksheets/sheet1.xml']!);
    final secondSheet = utf8.decode(files['xl/worksheets/sheet2.xml']!);

    expect(output.existsSync(), isTrue);
    expect(workbook, contains('name="画板_一"'));
    expect(workbook, contains('name="画板二"'));
    expect(firstSheet, contains('<v>1</v>'));
    expect(firstSheet, contains('人工确认内容'));
    expect(firstSheet, contains('近景'));
    expect(firstSheet, contains('推'));
    expect(firstSheet, contains('第二镜解析'));
    expect(
      RegExp(r'<c r="I3"[^>]*\/>').hasMatch(firstSheet),
      isTrue,
      reason: '图片列不能重复写入画面内容',
    );
    expect(secondSheet, contains('第二页'));
    expect(
      firstSheet.indexOf('<pageMargins '),
      lessThan(firstSheet.indexOf('<drawing ')),
      reason: 'OOXML 要求 pageMargins 位于 drawing 之前，否则 Excel 会替换整个工作表',
    );
    expect(
      secondSheet.indexOf('<pageMargins '),
      lessThan(secondSheet.indexOf('<drawing ')),
    );
    expect(files.keys.where((key) => key.startsWith('xl/media/')).length, 3);
    expect(files.containsKey('xl/drawings/drawing1.xml'), isTrue);
    expect(files.containsKey('xl/drawings/drawing2.xml'), isTrue);
  });

  test('拍摄脚本会扩展超过模板的镜头行，并保留景别和运镜校验范围', () async {
    final root = await Directory.systemTemp.createTemp('shooting_script_rows_');
    addTearDown(() => root.delete(recursive: true));
    final image = await _writeImage(root, 'source.png', 0, 255, 0);
    final items = List.generate(
      24,
      (index) => _item(
        image,
        id: 'asset-$index',
        slotIndex: index,
        caption: '镜头$index',
      ),
    );
    final output = await const ShootingScriptExportService().export(
      boards: [_board(id: 'board-many', name: '24宫格', items: items)],
      analysisBatches: const {},
      outputPath: '${root.path}${Platform.pathSeparator}many.xlsx',
    );

    final sheet = utf8.decode(
      _archiveFiles(await output.readAsBytes())['xl/worksheets/sheet1.xml']!,
    );

    expect(sheet, contains('<dimension ref="A1:Y26"/>'));
    expect(sheet, contains('D3:D26'));
    expect(sheet, contains('E3:E26'));
    expect(sheet, contains('r="A26"'));
    expect(sheet, contains('镜头23'));
  });

  test('拍摄脚本会移除 Excel XML 不支持的控制字符', () async {
    final root = await Directory.systemTemp.createTemp('shooting_script_xml_');
    addTearDown(() => root.delete(recursive: true));
    final image = await _writeImage(root, 'source.png', 0, 255, 0);
    final output = await const ShootingScriptExportService().export(
      boards: [
        _board(
          id: 'board-invalid-xml',
          name: '控制字符画板',
          items: [
            _item(
              image,
              id: 'invalid-xml',
              slotIndex: 0,
              caption: '前半段\u0000中间\u000B后半段',
            ),
          ],
        ),
      ],
      analysisBatches: const {},
      outputPath: '${root.path}${Platform.pathSeparator}invalid-xml.xlsx',
    );

    final sheet = utf8.decode(
      _archiveFiles(await output.readAsBytes())['xl/worksheets/sheet1.xml']!,
    );

    expect(sheet, contains('前半段中间后半段'));
    expect(sheet, isNot(contains('\u0000')));
    expect(sheet, isNot(contains('\u000B')));
  });
}

Future<File> _writeImage(
  Directory root,
  String name,
  int r,
  int g,
  int b,
) async {
  final image = img.Image(width: 12, height: 8);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  final file = File('${root.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(img.encodePng(image));
  return file;
}

StoryboardBoard _board({
  required String id,
  required String name,
  required List<StoryboardItem> items,
}) {
  return StoryboardBoard(
    id: id,
    name: name,
    width: 600,
    height: 400,
    rows: 4,
    columns: 6,
    gap: 12,
    items: items,
  );
}

StoryboardItem _item(
  File file, {
  required String id,
  required int slotIndex,
  required String caption,
}) {
  return StoryboardItem(
    asset: StoryboardCutAsset(
      id: id,
      imageId: 'image-$id',
      sourceName: p.basename(file.path),
      path: file.path,
      indexNo: slotIndex + 1,
    ),
    caption: caption,
    slotIndex: slotIndex,
  );
}

VisionAnalysisBatchRecord _batch(
  String boardId,
  List<VisionAnalysisItemRecord> items,
) {
  return VisionAnalysisBatchRecord(
    run: VisionAnalysisRunRecord(
      id: 'run-$boardId',
      boardId: boardId,
      model: 'test',
      status: 'completed',
      totalImages: items.length,
      successCount: items.length,
      errorMessage: '',
      createdAt: '',
      updatedAt: '',
    ),
    items: items,
  );
}

VisionAnalysisItemRecord _analysis({
  required String id,
  required String boardId,
  required String assetId,
  required String caption,
  required String detail,
  required String shotSize,
  required String cameraMovement,
}) {
  return VisionAnalysisItemRecord(
    id: id,
    runId: 'run-$boardId',
    boardId: boardId,
    cutResultId: assetId,
    slotIndex: 0,
    sequenceNo: 1,
    rowIndex: 0,
    columnIndex: 0,
    status: 'success',
    caption: caption,
    detail: detail,
    scene: '',
    props: '',
    people: '',
    expression: '',
    bodyAction: '',
    movementTrend: '',
    cameraMovement: cameraMovement,
    shotSize: shotSize,
    composition: '',
    subjectDirection: '',
    gazeDirection: '',
    actionStage: '',
    spatialRelation: '',
    chronologyCue: '',
    rawResponse: '',
    errorMessage: '',
    createdAt: '',
    updatedAt: '',
  );
}

Map<String, List<int>> _archiveFiles(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return {
    for (final file in archive)
      if (file.isFile) file.name: file.readBytes()!,
  };
}
