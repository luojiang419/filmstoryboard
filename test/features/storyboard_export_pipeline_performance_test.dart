import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:filmstoryboard/features/exporter/data/storyboard_export_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '10 个高分辨率画板连续 JPG 导出保持事件循环响应和目标尺寸解码',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'storyboard_export_pipeline_',
      );
      addTearDown(() => root.delete(recursive: true));
      final sourceFile = await _createSourceImage(root, 'source.png');
      final boards = [
        for (var index = 0; index < 10; index++)
          _board(
            id: 'board-$index',
            name: '高分辨率画板 ${index + 1}',
            sourcePath: sourceFile.path,
          ),
      ];
      final decodedWidths = <(int, int)>[];
      final progress = <double>[];
      var heartbeatCount = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => heartbeatCount++,
      );
      final exported = <File>[];

      try {
        for (var index = 0; index < boards.length; index++) {
          final files = await const StoryboardExportService().exportBoard(
            board: boards[index],
            format: StoryboardExportFormat.jpg,
            outputPath: p.join(root.path, 'export-$index.jpg'),
            onProgress: progress.add,
            onSourceDecoded: (intrinsicWidth, decodedWidth) =>
                decodedWidths.add((intrinsicWidth, decodedWidth)),
          );
          exported.addAll(files);
        }
      } finally {
        heartbeat.cancel();
      }

      expect(heartbeatCount, greaterThan(0));
      expect(exported, hasLength(10));
      expect(decodedWidths, hasLength(10));
      expect(
        decodedWidths.every(
          (widths) => widths.$1 == 2400 && widths.$2 == widths.$1,
        ),
        isTrue,
      );
      expect(progress.where((value) => value == 1), hasLength(10));
      for (var index = 0; index < exported.length; index++) {
        final decoded = img.decodeJpg(await exported[index].readAsBytes());
        expect(decoded, isNotNull);
        expect(decoded!.width, greaterThanOrEqualTo(2400));
        expect(
          decoded.height,
          greaterThanOrEqualTo(boards[index].withAdaptiveHeight().height),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('取消画板渲染会释放当前任务且不留下最终文件或 part 文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_cancel_',
    );
    addTearDown(() => root.delete(recursive: true));
    final sourceFile = await _createSourceImage(root, 'source.png');
    final board = _board(
      id: 'cancel-board',
      name: '取消测试',
      sourcePath: sourceFile.path,
      rows: 3,
      columns: 3,
    );
    var cancelled = false;
    final output = File(p.join(root.path, 'cancelled.png'));

    await expectLater(
      const StoryboardExportService().exportBoard(
        board: board,
        format: StoryboardExportFormat.png,
        outputPath: output.path,
        isCancelled: () => cancelled,
        onProgress: (progress) {
          if (progress >= 0.2) {
            cancelled = true;
          }
        },
      ),
      throwsA(isA<StoryboardExportCancelled>()),
    );

    expect(output.existsSync(), isFalse);
    expect(File('${output.path}.part').existsSync(), isFalse);
  });
}

Future<File> _createSourceImage(Directory root, String name) async {
  final image = img.Image(width: 2400, height: 1350);
  img.fill(image, color: img.ColorRgb8(72, 118, 166));
  final file = File(p.join(root.path, name));
  await file.writeAsBytes(img.encodePng(image));
  return file;
}

StoryboardBoard _board({
  required String id,
  required String name,
  required String sourcePath,
  int rows = 1,
  int columns = 1,
}) {
  final items = [
    for (var index = 0; index < rows * columns; index++)
      StoryboardItem(
        asset: StoryboardCutAsset(
          id: 'asset-$id-$index',
          imageId: 'image-$id-$index',
          sourceName: p.basename(sourcePath),
          path: sourcePath,
          indexNo: index + 1,
        ),
        caption: '',
        slotIndex: index,
      ),
  ];
  return StoryboardBoard(
    id: id,
    name: name,
    width: 1920,
    height: StoryboardBoard.heightForLayout(
      width: 1920,
      rows: rows,
      columns: columns,
    ),
    rows: rows,
    columns: columns,
    gap: 18,
    items: items,
    storyDescriptionEnabled: false,
    rowCaptions: [for (var index = 0; index < rows; index++) ''],
  );
}
