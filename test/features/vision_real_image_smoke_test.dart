import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:test/test.dart';

const _defaultCutDirectory =
    r'D:\Program Files\故事板\data\cuts\ChatGPT Image 2026年7月6日 17_31_27 (1)';

void main() {
  final runRealVision = Platform.environment['RUN_REAL_VISION'] == '1';

  test(
    '真实视觉模型可解析指定裁切图并完成自动重排序',
    () async {
      final cutDirectory = Directory(
        Platform.environment['REAL_VISION_CUT_DIR'] ?? _defaultCutDirectory,
      );
      expect(
        cutDirectory.existsSync(),
        isTrue,
        reason: '裁切素材目录不存在：${cutDirectory.path}',
      );

      final imageFiles = _listImageFiles(cutDirectory);
      expect(imageFiles, hasLength(9));

      final docsFile = File(
        p.join(Directory.current.path, 'docs', '视觉模型api.md'),
      );
      expect(docsFile.existsSync(), isTrue, reason: '缺少视觉模型 API 配置文档');

      final root = await Directory.systemTemp.createTemp(
        'storyboard_real_vision_',
      );
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      final database = await AppDatabase.open(directories.databaseFile);
      final repository = SettingsRepository(
        database,
        directories,
        visionDefaultsText: docsFile.readAsStringSync(),
      );
      final settingsController = SettingsController(
        repository: repository,
        initialSettings: repository.load(),
      );
      final controller = StoryboardController(
        database: database,
        settingsController: settingsController,
      );

      addTearDown(() async {
        controller.dispose();
        settingsController.dispose();
        database.dispose();
        await root.delete(recursive: true);
      });

      final assets = _registerCutAssets(database, cutDirectory, imageFiles);
      controller.setAssetsUsed(assets, true);

      await controller.analyzeSelectedBoardWithVision();

      final board = controller.value.selectedBoard!;
      expect(controller.value.isAnalyzing, isFalse);
      expect(controller.value.message, contains('故事板自动解析完成'));
      expect(database.countRows('vision_analysis_items'), imageFiles.length);
      expect(database.countRows('storyboard_summaries'), 1);
      expect(board.summary, isNotNull);
      expect(board.summary!.isEmpty, isFalse);
      expect(board.summary!.outline.trim(), isNot('故事板大纲'));
      expect(board.summary!.content.trim(), isNot('故事板内容概述'));

      final batch = database.getLatestVisionAnalysisBatchForBoard(board.id);
      expect(batch, isNotNull, reason: '解析完成后应保存视觉解析批次');
      expect(batch!.items, hasLength(imageFiles.length));
      _expectProfessionalOrderingCues(batch.items);

      final captions = <String>[];
      for (var slotIndex = 0; slotIndex < imageFiles.length; slotIndex++) {
        final item = board.itemAtSlot(slotIndex);
        expect(item, isNotNull, reason: '第 ${slotIndex + 1} 个槽位没有图片');
        expect(
          item!.caption.trim(),
          isNotEmpty,
          reason: '第 ${slotIndex + 1} 个槽位没有回填描述',
        );
        captions.add(item.caption.trim());
      }

      final originalOrder = _slotIndexOrder(board);
      await controller.reorderSelectedBoardByVisionAnalysis();

      final reorderedBoard = controller.value.selectedBoard!;
      final reorderedOrder = _slotIndexOrder(reorderedBoard);
      expect(controller.value.isAnalyzing, isFalse);
      expect(
        controller.value.message,
        anyOf(contains('自动重排序完成'), startsWith('分镜组合已是最优')),
      );
      expect(database.countRows('vision_analysis_items'), imageFiles.length);
      expect(reorderedOrder, hasLength(imageFiles.length));
      expect(reorderedOrder, unorderedEquals(originalOrder));
      expect(reorderedBoard.summary, isNotNull);
      expect(reorderedBoard.summary!.isEmpty, isFalse);
      for (var slotIndex = 0; slotIndex < imageFiles.length; slotIndex++) {
        final item = reorderedBoard.itemAtSlot(slotIndex);
        expect(item, isNotNull, reason: '重排序后第 ${slotIndex + 1} 个槽位没有图片');
        expect(
          item!.caption.trim(),
          isNotEmpty,
          reason: '重排序后第 ${slotIndex + 1} 个槽位没有文本',
        );
      }

      for (var i = 0; i < captions.length; i++) {
        // ignore: avoid_print
        print('slot ${i + 1}: ${captions[i]}');
      }
      for (final item in batch.items) {
        // ignore: avoid_print
        print(
          'analysis ${item.sequenceNo}: '
          'shot=${item.shotSize}; '
          'composition=${item.composition}; '
          'direction=${item.subjectDirection}; '
          'gaze=${item.gazeDirection}; '
          'stage=${item.actionStage}; '
          'space=${item.spatialRelation}; '
          'time=${item.chronologyCue}',
        );
      }
      // ignore: avoid_print
      print('original order: ${originalOrder.join(', ')}');
      // ignore: avoid_print
      print('reordered order: ${reorderedOrder.join(', ')}');
      // ignore: avoid_print
      print('reorder message: ${controller.value.message}');
      // ignore: avoid_print
      print('summary outline: ${board.summary!.outline}');
      // ignore: avoid_print
      print('summary content: ${board.summary!.content}');
    },
    skip: runRealVision ? false : '设置 RUN_REAL_VISION=1 后才调用真实视觉模型',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _expectProfessionalOrderingCues(List<VisionAnalysisItemRecord> items) {
  for (final item in items) {
    final fields = <String, String>{
      'shot_size': item.shotSize,
      'composition': item.composition,
      'subject_direction': item.subjectDirection,
      'gaze_direction': item.gazeDirection,
      'action_stage': item.actionStage,
      'spatial_relation': item.spatialRelation,
      'chronology_cue': item.chronologyCue,
    };
    for (final entry in fields.entries) {
      expect(
        entry.value.trim(),
        isNotEmpty,
        reason: '第 ${item.sequenceNo} 张缺少 ${entry.key}',
      );
    }
  }
}

List<int> _slotIndexOrder(StoryboardBoard board) {
  return [for (final item in _orderedItems(board)) item.asset.indexNo];
}

List<StoryboardItem> _orderedItems(StoryboardBoard board) {
  return [
    for (final item in board.items)
      if (item.slotIndex >= 0 && item.slotIndex < board.slotCount) item,
  ]..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
}

List<File> _listImageFiles(Directory directory) {
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => _isSupportedImage(file.path))
          .toList()
        ..sort((a, b) => _imageIndex(a).compareTo(_imageIndex(b)));
  return files;
}

bool _isSupportedImage(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp');
}

int _imageIndex(File file) {
  final name = p.basenameWithoutExtension(file.path);
  final match = RegExp(r'(\d+)$').firstMatch(name);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

List<StoryboardCutAsset> _registerCutAssets(
  AppDatabase database,
  Directory cutDirectory,
  List<File> imageFiles,
) {
  const imageId = 'real-vision-image';
  const taskId = 'real-vision-task';
  final now = DateTime.now().toIso8601String();
  final sourceName = p.basename(cutDirectory.path);
  database
    ..upsertImportedImage(
      id: imageId,
      originalPath: cutDirectory.path,
      originalName: sourceName,
      storedPath: cutDirectory.path,
      width: 0,
      height: 0,
      createdAt: now,
    )
    ..upsertCutTask(
      id: taskId,
      imageId: imageId,
      status: 'exported',
      rows: 3,
      columns: 3,
      confidence: 1,
    );

  return [
    for (var i = 0; i < imageFiles.length; i++)
      _insertCutAsset(
        database: database,
        taskId: taskId,
        imageId: imageId,
        sourceName: sourceName,
        file: imageFiles[i],
        indexNo: i + 1,
      ),
  ];
}

StoryboardCutAsset _insertCutAsset({
  required AppDatabase database,
  required String taskId,
  required String imageId,
  required String sourceName,
  required File file,
  required int indexNo,
}) {
  final id = 'real-vision-cut-$indexNo';
  database.insertCutResult(
    id: id,
    taskId: taskId,
    imageId: imageId,
    indexNo: indexNo,
    path: file.path,
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    selected: true,
  );
  return StoryboardCutAsset(
    id: id,
    imageId: imageId,
    sourceName: sourceName,
    path: file.path,
    indexNo: indexNo,
  );
}
