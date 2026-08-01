import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:storyboard_grid_app/app/app_theme.dart';
import 'package:storyboard_grid_app/features/exporter/data/storyboard_export_service.dart';
import 'package:storyboard_grid_app/features/settings/domain/app_settings.dart';
import 'package:storyboard_grid_app/features/storyboard/domain/storyboard_canvas_style.dart';
import 'package:storyboard_grid_app/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认导出文件名使用画板名称加日期', () {
    final fileName = storyboardExportFileName(
      boardName: '  画板:01/镜头*  ',
      format: StoryboardExportFormat.pdf,
      date: DateTime(2026, 7, 10),
    );

    expect(fileName, '画板_01_镜头_-20260710.pdf');
    expect(fileName.startsWith('A001'), isFalse);
    expect(
      storyboardExportFileName(
        boardName: '   ',
        format: StoryboardExportFormat.png,
        date: DateTime(2026, 7, 10),
      ),
      '画板-20260710.png',
    );
  });

  test('故事板内容页标题使用画板名称', () async {
    const summary = StoryboardSummary(
      outline: '角色进入房间',
      content: '角色观察环境。',
      scenes: '室内',
      props: '门、窗',
    );
    const firstBoard = StoryboardBoard(
      id: 'board-1',
      name: '画板 Alpha',
      width: 640,
      height: 640,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [],
      summary: summary,
    );
    const secondBoard = StoryboardBoard(
      id: 'board-1',
      name: '画板 Beta',
      width: 640,
      height: 640,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [],
      summary: summary,
    );
    const service = StoryboardExportService();

    final firstBytes = await service.renderSummaryPageToPng(firstBoard);
    final secondBytes = await service.renderSummaryPageToPng(secondBoard);

    expect(firstBytes, isNot(equals(secondBytes)));
  });

  test('导出空故事板时背景像素使用共享深灰背景色', () async {
    const board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 120,
      height: 120,
      rows: 2,
      columns: 2,
      gap: 12,
      items: [],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes);

    expect(image, isNotNull);
    final pixel = image!.getPixel(0, 0);
    expect(pixel.r, 0x24);
    expect(pixel.g, 0x2A);
    expect(pixel.b, 0x2E);
    expect(StoryboardCanvasStyle.background, isNotNull);
  });

  test('浅色主题导出的 PNG 使用浅色画布背景', () async {
    const board = StoryboardBoard(
      id: 'board-light',
      name: '浅色画板',
      width: 120,
      height: 120,
      rows: 2,
      columns: 2,
      gap: 12,
      items: [],
    );
    final root = await Directory.systemTemp.createTemp(
      'storyboard_light_export_',
    );
    final canvasColors = StoryboardCanvasStyle.fromColorScheme(
      AppTheme.light().colorScheme,
    );

    try {
      final files = await const StoryboardExportService().exportBoard(
        board: board,
        format: StoryboardExportFormat.png,
        outputPath: p.join(root.path, 'light-board.png'),
        canvasColors: canvasColors,
      );
      final image = img.decodePng(await files.single.readAsBytes());

      expect(image, isNotNull);
      final pixel = image!.getPixel(0, 0);
      expect(pixel.r, _colorByte(canvasColors.background.r));
      expect(pixel.g, _colorByte(canvasColors.background.g));
      expect(pixel.b, _colorByte(canvasColors.background.b));
      expect(canvasColors.background, isNot(StoryboardCanvasStyle.background));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('原图细节模式会按源图像素放大画布，标准模式保持画板尺寸', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_source_detail_',
    );
    addTearDown(() => root.delete(recursive: true));
    final sourceFile = File('${root.path}${Platform.pathSeparator}source.png');
    final sourceImage = img.Image(width: 240, height: 135);
    img.fill(sourceImage, color: img.ColorRgb8(40, 90, 150));
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'source-detail-board',
      name: '原图细节',
      width: 120,
      height: 120,
      rows: 1,
      columns: 1,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'source-detail-asset',
            imageId: 'source-detail-image',
            sourceName: 'source.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '',
          slotIndex: 0,
        ),
      ],
    );
    const service = StoryboardExportService();

    final standard = img.decodePng(
      await service.renderBoardToPng(
        board,
        resolution: StoryboardExportResolution.standard,
      ),
    )!;
    var intrinsicWidth = 0;
    var decodedWidth = 0;
    final sourceDetail = img.decodePng(
      await service.renderBoardToPng(
        board,
        onSourceDecoded: (intrinsic, decoded) {
          intrinsicWidth = intrinsic;
          decodedWidth = decoded;
        },
      ),
    )!;

    expect(standard.width, board.withAdaptiveHeight().width);
    expect(sourceDetail.width, greaterThanOrEqualTo(sourceImage.width));
    expect(sourceDetail.height, greaterThanOrEqualTo(sourceImage.height));
    expect(intrinsicWidth, sourceImage.width);
    expect(decodedWidth, intrinsicWidth);
  });

  test('竖屏模式导出每行一张16比9图片的纵向画布', () async {
    const board = StoryboardBoard(
      id: 'board-portrait',
      name: '竖屏画板',
      width: 360,
      height: 360,
      rows: 2,
      columns: 1,
      gap: 12,
      items: [],
      portraitMode: true,
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;

    expect(image.width, 360);
    expect(image.height, board.adaptiveHeight());
    expect(image.height, greaterThan(image.width));
    expect(board.columns, 1);
    expect(board.imageAspectRatio, 16 / 9);
  });

  test('导出故事板会绘制画板名称并应用标题对齐', () async {
    const baseBoard = StoryboardBoard(
      id: 'board-title',
      name: 'TITLE',
      width: 360,
      height: 240,
      rows: 1,
      columns: 1,
      gap: 12,
      storyDescriptionEnabled: false,
      items: [],
    );
    const service = StoryboardExportService();

    final leftImage = img.decodePng(
      await service.renderBoardToPng(
        baseBoard.copyWith(titleAlignment: StoryboardTitleAlignment.left),
      ),
    )!;
    final rightImage = img.decodePng(
      await service.renderBoardToPng(
        baseBoard.copyWith(titleAlignment: StoryboardTitleAlignment.right),
      ),
    )!;
    final titleBottom = (baseBoard.gap + StoryboardBoard.titleHeightFor(22))
        .ceil();

    expect(
      _countBrightPixels(
        leftImage,
        x1: 0,
        y1: 0,
        x2: leftImage.width ~/ 3,
        y2: titleBottom,
      ),
      greaterThan(
        _countBrightPixels(
          leftImage,
          x1: leftImage.width * 2 ~/ 3,
          y1: 0,
          x2: leftImage.width - 1,
          y2: titleBottom,
        ),
      ),
    );
    expect(
      _countBrightPixels(
        rightImage,
        x1: rightImage.width * 2 ~/ 3,
        y1: 0,
        x2: rightImage.width - 1,
        y2: titleBottom,
      ),
      greaterThan(
        _countBrightPixels(
          rightImage,
          x1: 0,
          y1: 0,
          x2: rightImage.width ~/ 3,
          y2: titleBottom,
        ),
      ),
    );
  });

  test('导出故事板会在行间距中心绘制可关闭的虚线分割线', () async {
    const board = StoryboardBoard(
      id: 'board-divider',
      name: '分割线画板',
      width: 120,
      height: 120,
      rows: 2,
      columns: 2,
      gap: 12,
      storyDescriptionEnabled: false,
      rowDividerOpacity: 1,
      items: [],
    );
    const service = StoryboardExportService();

    final enabled = img.decodePng(await service.renderBoardToPng(board))!;
    final disabled = img.decodePng(
      await service.renderBoardToPng(board.copyWith(rowDividerEnabled: false)),
    )!;
    final dividerY = _exportDividerY(board, 0).round();
    final enabledPixel = enabled.getPixel(15, dividerY);
    final disabledPixel = disabled.getPixel(15, dividerY);

    expect(enabledPixel.r, greaterThan(disabledPixel.r));
    expect(enabledPixel.g, greaterThan(disabledPixel.g));
    expect(enabledPixel.b, greaterThan(disabledPixel.b));
  });

  test('导出故事板按宫格位渲染并保留前置空位', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_slot_',
    );
    addTearDown(() => root.delete(recursive: true));

    final redFile = File('${root.path}${Platform.pathSeparator}red.png');
    final redImage = img.Image(width: 10, height: 10);
    img.fill(redImage, color: img.ColorRgb8(255, 0, 0));
    await redFile.writeAsBytes(img.encodePng(redImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 100,
      height: 100,
      rows: 2,
      columns: 2,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-red',
            imageId: 'image-1',
            sourceName: 'red.png',
            path: redFile.path,
            indexNo: 1,
          ),
          caption: '',
          slotIndex: 3,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;
    final emptySlot = _exportSlotRect(board, 0);
    final redSlot = _exportSlotRect(board, 3);
    final emptyPixel = image.getPixel(
      emptySlot.centerX.round(),
      emptySlot.centerY.round(),
    );
    final redPixel = image.getPixel(
      redSlot.centerX.round(),
      redSlot.centerY.round(),
    );

    expect(emptyPixel.r, 0x1A);
    expect(emptyPixel.g, 0x20);
    expect(emptyPixel.b, 0x24);
    expect(redPixel.r, greaterThan(220));
    expect(redPixel.g, lessThan(40));
    expect(redPixel.b, lessThan(40));
  });

  test('关闭故事描述后导出不保留文本空间', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_no_caption_',
    );
    addTearDown(() => root.delete(recursive: true));

    final redFile = File('${root.path}${Platform.pathSeparator}red.png');
    final redImage = img.Image(width: 10, height: 10);
    img.fill(redImage, color: img.ColorRgb8(255, 0, 0));
    await redFile.writeAsBytes(img.encodePng(redImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 100,
      height: 100,
      rows: 1,
      columns: 1,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-red',
            imageId: 'image-1',
            sourceName: 'red.png',
            path: redFile.path,
            indexNo: 1,
          ),
          caption: '这段描述不会占位',
          slotIndex: 0,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;
    final lowerPixel = image.getPixel(image.width ~/ 2, image.height - 7);

    expect(lowerPixel.r, greaterThan(220));
    expect(lowerPixel.g, lessThan(40));
    expect(lowerPixel.b, lessThan(40));
  });

  test('导出长描述时会自动增加画布高度', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_long_caption_',
    );
    addTearDown(() => root.delete(recursive: true));

    final redFile = File('${root.path}${Platform.pathSeparator}red.png');
    final redImage = img.Image(width: 10, height: 10);
    img.fill(redImage, color: img.ColorRgb8(255, 0, 0));
    await redFile.writeAsBytes(img.encodePng(redImage));

    final item = StoryboardItem(
      asset: StoryboardCutAsset(
        id: 'asset-red',
        imageId: 'image-1',
        sourceName: 'red.png',
        path: redFile.path,
        indexNo: 1,
      ),
      caption: '角色从画面左侧向右穿过尘土街道，回头看向远方，随后停在马匹旁边整理衣袖，神情从紧张逐渐变得坚定。',
      slotIndex: 0,
    );
    final baseHeight = StoryboardBoard.heightForLayout(
      width: 480,
      rows: 1,
      columns: 1,
      items: [item.copyWith(caption: '')],
      storyDescriptionEnabled: false,
    );
    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 480,
      height: baseHeight,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [item],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;

    expect(image.height, greaterThan(baseHeight));
    expect(image.height, board.withAdaptiveHeight().height);
  });

  test('导出故事描述时会绘制文本框旁序号', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_caption_badge_',
    );
    addTearDown(() => root.delete(recursive: true));

    final sourceFile = File('${root.path}${Platform.pathSeparator}dark.png');
    final sourceImage = img.Image(width: 20, height: 20);
    img.fill(sourceImage, color: img.ColorRgb8(0, 0, 0));
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 220,
      height: 220,
      rows: 1,
      columns: 1,
      gap: 0,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-dark',
            imageId: 'image-1',
            sourceName: 'dark.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '短描述',
          slotIndex: 0,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;

    final disabledBytes = await const StoryboardExportService()
        .renderBoardToPng(board, captionNumberEnabled: false);
    final disabledImage = img.decodePng(disabledBytes)!;

    final enabledCyanPixels = _countCyanPixels(
      image,
      x1: 0,
      y1: image.height ~/ 2,
      x2: 80,
      y2: image.height - 1,
    );
    final disabledCyanPixels = _countCyanPixels(
      disabledImage,
      x1: 0,
      y1: disabledImage.height ~/ 2,
      x2: 80,
      y2: disabledImage.height - 1,
    );
    expect(enabledCyanPixels, greaterThan(30));
    expect(disabledCyanPixels, lessThan(enabledCyanPixels));
  });

  test('逐行描述导出不会绘制单图文本框旁序号', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_row_caption_no_badge_',
    );
    addTearDown(() => root.delete(recursive: true));

    final sourceFile = File('${root.path}${Platform.pathSeparator}dark.png');
    final sourceImage = img.Image(width: 20, height: 20);
    img.fill(sourceImage, color: img.ColorRgb8(0, 0, 0));
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 220,
      height: 220,
      rows: 1,
      columns: 1,
      gap: 0,
      rowDescriptionEnabled: true,
      rowCaptions: const ['逐行描述'],
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-dark',
            imageId: 'image-1',
            sourceName: 'dark.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '短描述',
          slotIndex: 0,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;

    expect(_countCyanPixels(image, x1: 6, y1: 216, x2: 58, y2: 266), 0);
  });

  test('导出故事板会应用图片水平和垂直翻转', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_flip_',
    );
    addTearDown(() => root.delete(recursive: true));

    final sourceFile = File('${root.path}${Platform.pathSeparator}quad.png');
    final sourceImage = img.Image(width: 10, height: 10);
    img.fillRect(
      sourceImage,
      x1: 0,
      y1: 0,
      x2: 4,
      y2: 4,
      color: img.ColorRgb8(255, 0, 0),
    );
    img.fillRect(
      sourceImage,
      x1: 5,
      y1: 0,
      x2: 9,
      y2: 4,
      color: img.ColorRgb8(0, 255, 0),
    );
    img.fillRect(
      sourceImage,
      x1: 0,
      y1: 5,
      x2: 4,
      y2: 9,
      color: img.ColorRgb8(0, 0, 255),
    );
    img.fillRect(
      sourceImage,
      x1: 5,
      y1: 5,
      x2: 9,
      y2: 9,
      color: img.ColorRgb8(255, 255, 0),
    );
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 100,
      height: 100,
      rows: 1,
      columns: 1,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-quad',
            imageId: 'image-1',
            sourceName: 'quad.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '',
          slotIndex: 0,
          flipHorizontal: true,
          flipVertical: true,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(board);
    final image = img.decodePng(bytes)!;
    final imageRect = _exportImageRect(board, 0);
    final topLeftPixel = image.getPixel(
      (imageRect.left + imageRect.width * 0.25).round(),
      (imageRect.top + imageRect.height * 0.25).round(),
    );

    expect(topLeftPixel.r, greaterThan(220));
    expect(topLeftPixel.g, greaterThan(220));
    expect(topLeftPixel.b, lessThan(40));
  });

  test('导出故事板开启图片编号后按指定位置绘制徽章', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_number_',
    );
    addTearDown(() => root.delete(recursive: true));

    final sourceFile = File('${root.path}${Platform.pathSeparator}dark.png');
    final sourceImage = img.Image(width: 20, height: 20);
    img.fill(sourceImage, color: img.ColorRgb8(0, 0, 0));
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 120,
      height: 120,
      rows: 1,
      columns: 1,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-dark',
            imageId: 'image-1',
            sourceName: 'dark.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '',
          slotIndex: 0,
        ),
      ],
    );

    final bytes = await const StoryboardExportService().renderBoardToPng(
      board,
      numberEnabled: true,
      numberPosition: CutImageNumberPosition.bottomRight,
    );
    final image = img.decodePng(bytes)!;
    final imageRect = _exportImageRect(board, 0);

    expect(
      _hasVisibleBadgePixel(
        image,
        x1: (imageRect.right - 40).round(),
        y1: (imageRect.bottom - 35).round(),
        x2: imageRect.right.round(),
        y2: imageRect.bottom.round(),
      ),
      isTrue,
    );
    expect(
      _hasVisibleBadgePixel(
        image,
        x1: (imageRect.left + 4).round(),
        y1: (imageRect.top + 4).round(),
        x2: (imageRect.left + 30).round(),
        y2: (imageRect.top + 30).round(),
      ),
      isFalse,
    );
  });

  test('导出故事板图片编号尺寸会同步放大外圈', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_number_scale_',
    );
    addTearDown(() => root.delete(recursive: true));

    final sourceFile = File('${root.path}${Platform.pathSeparator}dark.png');
    final sourceImage = img.Image(width: 40, height: 40);
    img.fill(sourceImage, color: img.ColorRgb8(0, 0, 0));
    await sourceFile.writeAsBytes(img.encodePng(sourceImage));

    final board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 220,
      height: 220,
      rows: 1,
      columns: 1,
      gap: 0,
      storyDescriptionEnabled: false,
      items: [
        StoryboardItem(
          asset: StoryboardCutAsset(
            id: 'asset-dark',
            imageId: 'image-1',
            sourceName: 'dark.png',
            path: sourceFile.path,
            indexNo: 1,
          ),
          caption: '',
          slotIndex: 0,
        ),
      ],
    );

    final smallBytes = await const StoryboardExportService().renderBoardToPng(
      board,
      numberEnabled: true,
      numberTextScale: 0.7,
    );
    final largeBytes = await const StoryboardExportService().renderBoardToPng(
      board,
      numberEnabled: true,
      numberTextScale: 1.6,
    );

    final smallImage = img.decodePng(smallBytes)!;
    final largeImage = img.decodePng(largeBytes)!;

    expect(
      _countBrightPixels(largeImage),
      greaterThan(_countBrightPixels(smallImage)),
    );
  });

  test('导出画板图片会按宫格位置重命名原图', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_board_images_',
    );
    addTearDown(() => root.delete(recursive: true));

    final firstFile = File('${root.path}${Platform.pathSeparator}first.png');
    final firstImage = img.Image(width: 10, height: 10);
    img.fill(firstImage, color: img.ColorRgb8(255, 0, 0));
    await firstFile.writeAsBytes(img.encodePng(firstImage));

    final fourthFile = File('${root.path}${Platform.pathSeparator}fourth.jpg');
    final fourthImage = img.Image(width: 10, height: 10);
    img.fill(fourthImage, color: img.ColorRgb8(0, 0, 255));
    await fourthFile.writeAsBytes(img.encodeJpg(fourthImage));

    final outputDirectory = Directory(
      '${root.path}${Platform.pathSeparator}exports',
    );
    const boardName = '画板A';
    final result = await const StoryboardExportService().exportBoardImages(
      board: StoryboardBoard(
        id: 'board-1',
        name: boardName,
        width: 100,
        height: 100,
        rows: 2,
        columns: 2,
        gap: 0,
        items: [
          StoryboardItem(
            asset: StoryboardCutAsset(
              id: 'asset-first',
              imageId: 'image-1',
              sourceName: 'first.png',
              path: firstFile.path,
              indexNo: 1,
            ),
            caption: '',
            slotIndex: 0,
          ),
          StoryboardItem(
            asset: StoryboardCutAsset(
              id: 'asset-fourth',
              imageId: 'image-2',
              sourceName: 'fourth.jpg',
              path: fourthFile.path,
              indexNo: 4,
            ),
            caption: '',
            slotIndex: 3,
          ),
        ],
      ),
      outputDirectory: outputDirectory.path,
    );

    expect(p.basename(result.directory.path), boardName);
    expect(result.files.map((file) => p.basename(file.path)), [
      '画板A1.png',
      '画板A4.jpg',
    ]);
    expect(
      File(p.join(result.directory.path, '画板A2.png')).existsSync(),
      isFalse,
    );
    expect(
      await result.files.first.readAsBytes(),
      await firstFile.readAsBytes(),
    );
  });

  test('PNG 导出会为故事板内容页生成独立图片', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_summary_',
    );
    addTearDown(() => root.delete(recursive: true));

    const board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 240,
      height: 240,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [],
      summary: StoryboardSummary(
        outline: '角色进入房间',
        content: '角色抵达新场景并观察环境。',
        scenes: '室内',
        props: '门、窗',
      ),
    );

    final files = await const StoryboardExportService().exportBoard(
      board: board,
      format: StoryboardExportFormat.png,
      outputPath: '${root.path}${Platform.pathSeparator}board.png',
      includeSummaryPage: true,
    );

    expect(files.length, 2);
    expect(files.first.existsSync(), isTrue);
    expect(files.last.path.endsWith('-内容页.png'), isTrue);
    expect(files.last.existsSync(), isTrue);
  });

  test('PDF 导出会把故事板内容页合并进同一个文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'storyboard_export_summary_pdf_',
    );
    addTearDown(() => root.delete(recursive: true));

    const board = StoryboardBoard(
      id: 'board-1',
      name: '画板 1',
      width: 240,
      height: 240,
      rows: 1,
      columns: 1,
      gap: 12,
      items: [],
      summary: StoryboardSummary(
        outline: '角色进入房间',
        content: '角色抵达新场景并观察环境。',
        scenes: '室内',
        props: '门、窗',
      ),
    );

    final files = await const StoryboardExportService().exportBoard(
      board: board,
      format: StoryboardExportFormat.pdf,
      outputPath: '${root.path}${Platform.pathSeparator}board.pdf',
      includeSummaryPage: true,
    );

    expect(files.length, 1);
    expect(files.single.existsSync(), isTrue);
    expect(files.single.lengthSync(), greaterThan(0));
  });
}

int _colorByte(double channel) => (channel * 255).round();

double _exportDividerY(StoryboardBoard board, int rowIndex) {
  final layout = _ExportTestLayout(board.withAdaptiveHeight());
  return layout.gridTop +
      (rowIndex + 1) * layout.rowBandHeight +
      (rowIndex + 0.5) * layout.gap;
}

_TestRect _exportSlotRect(StoryboardBoard board, int slotIndex) {
  return _ExportTestLayout(board.withAdaptiveHeight()).slotRect(slotIndex);
}

_TestRect _exportImageRect(StoryboardBoard board, int slotIndex) {
  final renderBoard = board.withAdaptiveHeight();
  final layout = _ExportTestLayout(renderBoard);
  final tileRect = layout.slotRect(slotIndex);
  final padding = math.min(12.0, math.max(6.0, tileRect.width * 0.035));
  final captionHeight =
      renderBoard.storyDescriptionEnabled && !renderBoard.rowDescriptionEnabled
      ? layout.itemCaptionHeight
      : 0.0;
  return _TestRect(
    left: tileRect.left + padding,
    top: tileRect.top + padding,
    width: math.max(1.0, tileRect.width - padding * 2),
    height: math.max(
      1.0,
      tileRect.height -
          padding * 2 -
          captionHeight -
          (captionHeight > 0 ? 8 : 0),
    ),
  );
}

class _ExportTestLayout {
  _ExportTestLayout(this.board) {
    final rows = math.max(1, board.rows);
    final columns = math.max(1, board.columns);
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
  late final double cellWidth;
  late final double cellHeight;
  late final double rowBandHeight;
  late final double titleHeight;
  late final double rowCaptionHeight;
  late final double itemCaptionHeight;
  late final double rowCaptionGap;

  double get gap => board.gap;

  double get gridTop => gap + titleHeight + gap;

  _TestRect slotRect(int index) {
    final columns = math.max(1, board.columns);
    final row = index ~/ columns;
    final column = index % columns;
    return _TestRect(
      left: gap + column * (cellWidth + gap),
      top: gridTop + row * (rowBandHeight + gap),
      width: cellWidth,
      height: cellHeight,
    );
  }
}

class _TestRect {
  const _TestRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;

  double get bottom => top + height;

  double get centerX => left + width / 2;

  double get centerY => top + height / 2;
}

bool _hasVisibleBadgePixel(
  img.Image image, {
  required int x1,
  required int y1,
  required int x2,
  required int y2,
}) {
  final safeX1 = x1.clamp(0, image.width - 1);
  final safeY1 = y1.clamp(0, image.height - 1);
  final safeX2 = x2.clamp(safeX1, image.width - 1);
  final safeY2 = y2.clamp(safeY1, image.height - 1);
  for (var y = safeY1; y <= safeY2; y++) {
    for (var x = safeX1; x <= safeX2; x++) {
      final pixel = image.getPixel(x, y);
      if (pixel.r > 80 && pixel.g > 80 && pixel.b > 80) {
        return true;
      }
    }
  }
  return false;
}

int _countBrightPixels(img.Image image, {int? x1, int? y1, int? x2, int? y2}) {
  final safeX1 = (x1 ?? 0).clamp(0, image.width - 1).toInt();
  final safeY1 = (y1 ?? 0).clamp(0, image.height - 1).toInt();
  final safeX2 = (x2 ?? image.width - 1).clamp(safeX1, image.width - 1).toInt();
  final safeY2 = (y2 ?? image.height - 1)
      .clamp(safeY1, image.height - 1)
      .toInt();
  var count = 0;
  for (var y = safeY1; y <= safeY2; y++) {
    for (var x = safeX1; x <= safeX2; x++) {
      final pixel = image.getPixel(x, y);
      if (pixel.r > 80 && pixel.g > 80 && pixel.b > 80) {
        count++;
      }
    }
  }
  return count;
}

int _countCyanPixels(
  img.Image image, {
  required int x1,
  required int y1,
  required int x2,
  required int y2,
}) {
  var count = 0;
  for (
    var y = y1.clamp(0, image.height - 1);
    y <= y2 && y < image.height;
    y++
  ) {
    for (
      var x = x1.clamp(0, image.width - 1);
      x <= x2 && x < image.width;
      x++
    ) {
      final pixel = image.getPixel(x, y);
      if (pixel.g > pixel.r + 20 && pixel.b > pixel.r + 25) {
        count++;
      }
    }
  }
  return count;
}
