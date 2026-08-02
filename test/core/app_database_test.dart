import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:test/test.dart';

void main() {
  test('初始化数据库表并持久化设置', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    expect(database.countRows('settings'), 0);

    final repository = SettingsRepository(
      database,
      directories,
      visionDefaultsText:
          'url:http://127.0.0.1:12345\nkey:test-key\n模型:test-vlm',
      imageGenerationDefaultsText:
          '4. `builtin-grsai-image`\nkey: test-image-key\n模型：nano-banana-fast',
    );
    final defaults = repository.load();
    expect(defaults.exportDirectory, directories.exports.path);
    expect(defaults.cutImageNumberEnabled, isFalse);
    expect(defaults.cutImageNumberPosition, CutImageNumberPosition.topLeft);
    expect(defaults.cutImageNumberBackgroundOpacity, 0.5);
    expect(defaults.cutImageNumberTextScale, 1.0);
    expect(defaults.storyboardCaptionNumberEnabled, isTrue);
    expect(defaults.storyboardSummaryPageEnabled, isTrue);
    expect(defaults.visionApiBaseUrl, 'http://127.0.0.1:12345');
    expect(defaults.visionModel, 'test-vlm');
    expect(defaults.imageGenerationApiBaseUrl, 'https://grsai.dakka.com.cn');
    expect(defaults.imageGenerationApiKey, 'test-image-key');
    expect(
      defaults.imageGenerationGeminiApiBaseUrl,
      'https://www.shiying-api.com',
    );
    expect(defaults.imageGenerationGeminiApiKey, '');
    expect(defaults.imageGenerationApiMartApiBaseUrl, 'https://api.apimart.ai');
    expect(defaults.imageGenerationApiMartApiKey, '');
    expect(defaults.imageGenerationModel, 'nano-banana-fast');
    expect(
      defaults.updateReleaseApiUrl,
      'https://github.com/luojiang419/storyboard-grid-app-releases',
    );
    expect(defaults.autoInstallUpdates, isFalse);
    expect(defaults.updateDownloadMode, UpdateDownloadMode.automatic);
    expect(defaults.updateManualProxyUrl, 'http://127.0.0.1:7890');

    final customExportPath = p.join(root.path, 'custom_exports');
    repository.save(
      AppSettings(
        exportDirectory: customExportPath,
        themePreference: AppThemePreference.dark,
        cutImageNumberEnabled: true,
        cutImageNumberPosition: CutImageNumberPosition.bottomRight,
        cutImageNumberBackgroundOpacity: 0.35,
        cutImageNumberTextScale: 1.4,
        storyboardCaptionNumberEnabled: false,
        storyboardSummaryPageEnabled: false,
        visionApiBaseUrl: 'http://localhost:9000',
        visionApiKey: 'custom-key',
        visionModel: 'custom-vlm',
        imageGenerationApiBaseUrl: 'https://grsaiapi.com',
        imageGenerationApiKey: 'custom-image-key',
        imageGenerationGeminiApiBaseUrl: 'https://gemini.example',
        imageGenerationGeminiApiKey: 'custom-gemini-key',
        imageGenerationApiMartApiBaseUrl: 'https://apimart.example',
        imageGenerationApiMartApiKey: 'custom-apimart-key',
        imageGenerationModel: 'gpt-image-2',
        updateReleaseApiUrl:
            'https://api.github.com/repos/example/storyboard/releases/latest',
        autoInstallUpdates: true,
        updateDownloadMode: UpdateDownloadMode.manual,
        updateManualProxyUrl: 'http://127.0.0.1:7890',
      ),
    );

    final loaded = repository.load();
    expect(loaded.exportDirectory, customExportPath);
    expect(loaded.themePreference, AppThemePreference.dark);
    expect(loaded.cutImageNumberEnabled, isTrue);
    expect(loaded.cutImageNumberPosition, CutImageNumberPosition.bottomRight);
    expect(loaded.cutImageNumberBackgroundOpacity, 0.35);
    expect(loaded.cutImageNumberTextScale, 1.4);
    expect(loaded.storyboardCaptionNumberEnabled, isFalse);
    expect(loaded.storyboardSummaryPageEnabled, isFalse);
    expect(loaded.visionApiBaseUrl, 'http://localhost:9000');
    expect(loaded.visionModel, 'custom-vlm');
    expect(loaded.imageGenerationApiBaseUrl, 'https://grsaiapi.com');
    expect(loaded.imageGenerationApiKey, 'custom-image-key');
    expect(loaded.imageGenerationGeminiApiBaseUrl, 'https://gemini.example');
    expect(loaded.imageGenerationGeminiApiKey, 'custom-gemini-key');
    expect(loaded.imageGenerationApiMartApiBaseUrl, 'https://apimart.example');
    expect(loaded.imageGenerationApiMartApiKey, 'custom-apimart-key');
    expect(loaded.imageGenerationModel, 'gpt-image-2');
    expect(
      loaded.updateReleaseApiUrl,
      'https://api.github.com/repos/example/storyboard/releases/latest',
    );
    expect(loaded.autoInstallUpdates, isTrue);
    expect(loaded.updateDownloadMode, UpdateDownloadMode.manual);
    expect(loaded.updateManualProxyUrl, 'http://127.0.0.1:7890');
    expect(database.countRows('settings'), 32);
  });

  test('记录图片生成任务结果', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    database.insertImageGenerationRecord(
      id: 'gen-1',
      boardId: 'board-1',
      slotIndex: 2,
      sourceAssetId: 'asset-source',
      sourcePath: p.join(root.path, 'source.png'),
      model: 'nano-banana-fast',
      prompt: '让人物回头看向门口',
      aspectRatio: '16:9',
      imageSize: '2K',
      quality: 'auto',
      referencePathsJson: '["source.png"]',
      status: 'running',
    );
    database.updateImageGenerationRecord(
      id: 'gen-1',
      status: 'succeeded',
      resultAssetId: 'asset-result',
      resultPath: p.join(root.path, 'result.png'),
      rawResponse: '{"status":"succeeded"}',
    );

    final record = database.getImageGenerationRecord('gen-1');
    expect(record?.boardId, 'board-1');
    expect(record?.slotIndex, 2);
    expect(record?.sourceAssetId, 'asset-source');
    expect(record?.resultAssetId, 'asset-result');
    expect(record?.model, 'nano-banana-fast');
    expect(record?.status, 'succeeded');
    expect(record?.errorMessage, '');
  });

  test('记录视觉解析批次、逐图结果和故事板摘要', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    final now = DateTime.now().toIso8601String();
    database
      ..upsertImportedImage(
        id: 'image-vision',
        originalPath: 'D:\\demo\\vision.png',
        originalName: 'vision.png',
        storedPath: p.join(root.path, 'vision.png'),
        width: 400,
        height: 400,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-vision',
        imageId: 'image-vision',
        status: 'exported',
        rows: 1,
        columns: 1,
        confidence: 0.9,
      )
      ..insertCutResult(
        id: 'cut-vision',
        taskId: 'task-vision',
        imageId: 'image-vision',
        indexNo: 1,
        path: p.join(root.path, 'vision-cut.png'),
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      )
      ..insertVisionAnalysisRun(
        id: 'run-1',
        boardId: 'board-1',
        model: 'test-vlm',
        status: 'running',
        totalImages: 1,
      )
      ..insertVisionAnalysisItem(
        id: 'item-1',
        runId: 'run-1',
        boardId: 'board-1',
        cutResultId: 'cut-vision',
        slotIndex: 0,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 0,
        status: 'success',
        caption: '角色进入房间',
        detail: '画面中角色推门进入室内。',
        scene: '室内',
        props: '门',
        people: '角色',
        expression: '神情警觉，视线看向门内',
        bodyAction: '推门进入',
        movementTrend: '向室内前进',
        cameraMovement: '推',
        shotSize: '全景',
        composition: '门位于画面右侧，角色从左侧进入',
        subjectDirection: '面向右侧室内',
        gazeDirection: '看向门内',
        actionStage: '进行',
        spatialRelation: '角色从门外进入室内',
        chronologyCue: '动作中',
        cameraAngle: '眼平全景',
        visualFocus: '角色推门进入的动作',
        lightingMood: '室内暗光与门外亮光对比',
        colorPalette: '暖黄与深棕',
        narrativeFunction: '推进',
        transitionHint: '适合接在开场建立镜头之后',
        rawResponse: '{"caption":"角色进入房间"}',
      )
      ..updateVisionAnalysisRun(
        id: 'run-1',
        status: 'completed',
        successCount: 1,
      )
      ..upsertStoryboardSummary(
        boardId: 'board-1',
        runId: 'run-1',
        outline: '角色进入房间',
        content: '角色抵达新场景。',
        scenes: '室内',
        props: '门',
        rawResponse: '{"outline":"角色进入房间"}',
      );

    final run = database.getVisionAnalysisRun('run-1');
    expect(run?.status, 'completed');
    expect(run?.successCount, 1);

    final items = database.listVisionAnalysisItems('run-1');
    expect(items.single.caption, '角色进入房间');
    expect(items.single.sequenceNo, 1);
    expect(items.single.expression, '神情警觉，视线看向门内');
    expect(items.single.bodyAction, '推门进入');
    expect(items.single.movementTrend, '向室内前进');
    expect(items.single.cameraMovement, '推');
    expect(items.single.shotSize, '全景');
    expect(items.single.composition, '门位于画面右侧，角色从左侧进入');
    expect(items.single.subjectDirection, '面向右侧室内');
    expect(items.single.gazeDirection, '看向门内');
    expect(items.single.actionStage, '进行');
    expect(items.single.spatialRelation, '角色从门外进入室内');
    expect(items.single.chronologyCue, '动作中');
    expect(items.single.cameraAngle, '眼平全景');
    expect(items.single.visualFocus, '角色推门进入的动作');
    expect(items.single.lightingMood, '室内暗光与门外亮光对比');
    expect(items.single.colorPalette, '暖黄与深棕');
    expect(items.single.narrativeFunction, '推进');
    expect(items.single.transitionHint, '适合接在开场建立镜头之后');

    final summary = database.getStoryboardSummary('board-1');
    expect(summary?.outline, '角色进入房间');
    expect(summary?.props, '门');

    final firstBatch = database.getLatestVisionAnalysisBatchForBoard('board-1');
    expect(firstBatch?.run.id, 'run-1');
    expect(firstBatch?.items.single.cutResultId, 'cut-vision');

    await Future<void>.delayed(const Duration(milliseconds: 2));
    database
      ..insertCutResult(
        id: 'cut-vision-2',
        taskId: 'task-vision',
        imageId: 'image-vision',
        indexNo: 2,
        path: p.join(root.path, 'vision-cut-2.png'),
        x: 100,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      )
      ..insertVisionAnalysisRun(
        id: 'run-2',
        boardId: 'board-1',
        model: 'test-vlm',
        status: 'running',
        totalImages: 1,
      )
      ..insertVisionAnalysisItem(
        id: 'item-2',
        runId: 'run-2',
        boardId: 'board-1',
        cutResultId: 'cut-vision-2',
        slotIndex: 1,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 1,
        status: 'success',
        caption: '角色走向窗边',
        detail: '角色走向窗边观察外面。',
        scene: '窗边',
        props: '窗户',
        people: '角色',
        expression: '神情专注',
        bodyAction: '走向窗边',
        movementTrend: '向右移动',
        shotSize: '中景',
        composition: '窗户在画面右侧',
        subjectDirection: '面向右侧',
        gazeDirection: '看向窗户',
        actionStage: '进行',
        spatialRelation: '角色靠近窗边',
        chronologyCue: '动作中',
        rawResponse: '{"caption":"角色走向窗边"}',
      )
      ..updateVisionAnalysisRun(
        id: 'run-2',
        status: 'completed',
        successCount: 1,
      );

    final latestBatch = database.getLatestVisionAnalysisBatchForBoard(
      'board-1',
    );
    expect(latestBatch?.run.id, 'run-2');
    expect(latestBatch?.items.single.caption, '角色走向窗边');
  });

  test('只清理指定画板的视觉解析记录和故事板摘要', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final database = await AppDatabase.open(
      File(p.join(root.path, 'storyboard.sqlite')),
    );
    addTearDown(database.dispose);

    final now = DateTime.now().toIso8601String();
    database
      ..upsertImportedImage(
        id: 'image-clean',
        originalPath: p.join(root.path, 'source.png'),
        originalName: 'source.png',
        storedPath: p.join(root.path, 'source.png'),
        width: 100,
        height: 100,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-clean',
        imageId: 'image-clean',
        status: 'exported',
        rows: 1,
        columns: 2,
        confidence: 0.9,
      )
      ..insertCutResult(
        id: 'cut-clean-1',
        taskId: 'task-clean',
        imageId: 'image-clean',
        indexNo: 1,
        path: p.join(root.path, 'cut-1.png'),
        x: 0,
        y: 0,
        width: 50,
        height: 100,
        selected: true,
      )
      ..insertCutResult(
        id: 'cut-clean-2',
        taskId: 'task-clean',
        imageId: 'image-clean',
        indexNo: 2,
        path: p.join(root.path, 'cut-2.png'),
        x: 50,
        y: 0,
        width: 50,
        height: 100,
        selected: true,
      )
      ..insertVisionAnalysisRun(
        id: 'run-clean-1',
        boardId: 'board-clean-1',
        model: 'test-vlm',
        status: 'completed',
        totalImages: 1,
      )
      ..insertVisionAnalysisItem(
        id: 'item-clean-1',
        runId: 'run-clean-1',
        boardId: 'board-clean-1',
        cutResultId: 'cut-clean-1',
        slotIndex: 0,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 0,
        status: 'success',
        caption: '画板一',
        detail: '画板一解析',
        scene: '',
        props: '',
        people: '',
        expression: '',
        bodyAction: '',
        movementTrend: '',
        rawResponse: '{}',
      )
      ..updateVisionAnalysisRun(
        id: 'run-clean-1',
        status: 'completed',
        successCount: 1,
      )
      ..upsertStoryboardSummary(
        boardId: 'board-clean-1',
        runId: 'run-clean-1',
        outline: '画板一概述',
        content: '',
        scenes: '',
        props: '',
        rawResponse: '{}',
      )
      ..insertVisionAnalysisRun(
        id: 'run-clean-2',
        boardId: 'board-clean-2',
        model: 'test-vlm',
        status: 'completed',
        totalImages: 1,
      )
      ..insertVisionAnalysisItem(
        id: 'item-clean-2',
        runId: 'run-clean-2',
        boardId: 'board-clean-2',
        cutResultId: 'cut-clean-2',
        slotIndex: 0,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 0,
        status: 'success',
        caption: '画板二',
        detail: '画板二解析',
        scene: '',
        props: '',
        people: '',
        expression: '',
        bodyAction: '',
        movementTrend: '',
        rawResponse: '{}',
      )
      ..updateVisionAnalysisRun(
        id: 'run-clean-2',
        status: 'completed',
        successCount: 1,
      )
      ..upsertStoryboardSummary(
        boardId: 'board-clean-2',
        runId: 'run-clean-2',
        outline: '画板二概述',
        content: '',
        scenes: '',
        props: '',
        rawResponse: '{}',
      );

    database.deleteVisionAnalysisForBoard('board-clean-1');

    expect(database.getVisionAnalysisRun('run-clean-1'), isNull);
    expect(database.listVisionAnalysisItems('run-clean-1'), isEmpty);
    expect(database.getStoryboardSummary('board-clean-1'), isNull);
    expect(database.getVisionAnalysisRun('run-clean-2'), isNotNull);
    expect(
      database.listVisionAnalysisItems('run-clean-2').single.caption,
      '画板二',
    );
    expect(database.getStoryboardSummary('board-clean-2')?.outline, '画板二概述');
  });

  test('旧视觉解析表会补齐维度并支持自定义文件夹资源', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final databaseFile = File(p.join(root.path, 'legacy.sqlite'));
    final legacy = sqlite3.open(databaseFile.path);
    legacy.execute('''
      CREATE TABLE vision_analysis_items (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES vision_analysis_runs(id) ON DELETE CASCADE,
        board_id TEXT NOT NULL,
        cut_result_id TEXT NOT NULL REFERENCES cut_results(id) ON DELETE CASCADE,
        slot_index INTEGER NOT NULL,
        sequence_no INTEGER NOT NULL,
        row_index INTEGER NOT NULL,
        column_index INTEGER NOT NULL,
        status TEXT NOT NULL,
        caption TEXT NOT NULL DEFAULT '',
        detail TEXT NOT NULL DEFAULT '',
        scene TEXT NOT NULL DEFAULT '',
        props TEXT NOT NULL DEFAULT '',
        people TEXT NOT NULL DEFAULT '',
        raw_response TEXT NOT NULL DEFAULT '',
        error_message TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    legacy.close();

    final database = await AppDatabase.open(databaseFile);
    addTearDown(database.dispose);

    final now = DateTime.now().toIso8601String();
    database
      ..upsertImportedImage(
        id: 'image-legacy',
        originalPath: 'D:\\demo\\legacy.png',
        originalName: 'legacy.png',
        storedPath: p.join(root.path, 'legacy.png'),
        width: 400,
        height: 400,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-legacy',
        imageId: 'image-legacy',
        status: 'exported',
        rows: 1,
        columns: 1,
        confidence: 0.9,
      )
      ..insertCutResult(
        id: 'cut-legacy',
        taskId: 'task-legacy',
        imageId: 'image-legacy',
        indexNo: 1,
        path: p.join(root.path, 'legacy-cut.png'),
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      )
      ..insertVisionAnalysisRun(
        id: 'run-legacy',
        boardId: 'board-legacy',
        model: 'test-vlm',
        status: 'running',
        totalImages: 1,
      )
      ..insertVisionAnalysisItem(
        id: 'item-legacy',
        runId: 'run-legacy',
        boardId: 'board-legacy',
        cutResultId: 'cut-legacy',
        slotIndex: 0,
        sequenceNo: 1,
        rowIndex: 0,
        columnIndex: 0,
        status: 'success',
        caption: '角色向右起身',
        detail: '角色从椅子上起身。',
        scene: '室内',
        props: '椅子',
        people: '角色',
        expression: '眉头微皱',
        bodyAction: '扶椅起身',
        movementTrend: '向右起身',
        shotSize: '中景',
        composition: '椅子在角色身旁',
        subjectDirection: '身体朝右',
        gazeDirection: '看向画面右侧',
        actionStage: '准备',
        spatialRelation: '角色扶着椅子起身',
        chronologyCue: '动作前',
        rawResponse: '{"caption":"角色向右起身"}',
      )
      ..insertVisionAnalysisItem(
        id: 'item-folder',
        runId: 'run-legacy',
        boardId: 'board-legacy',
        cutResultId: 'folder:临时:合集单人篇1.png',
        slotIndex: 1,
        sequenceNo: 2,
        rowIndex: 0,
        columnIndex: 1,
        status: 'success',
        caption: '自定义文件夹图片',
        detail: '不依赖裁切结果表的故事板资源。',
        scene: '室内',
        props: '',
        people: '',
        expression: '',
        bodyAction: '',
        movementTrend: '',
        rawResponse: '{"caption":"自定义文件夹图片"}',
      );

    final items = database.listVisionAnalysisItems('run-legacy');
    final item = items.firstWhere((item) => item.id == 'item-legacy');
    expect(item.expression, '眉头微皱');
    expect(item.bodyAction, '扶椅起身');
    expect(item.movementTrend, '向右起身');
    expect(item.cameraMovement, '');
    expect(item.shotSize, '中景');
    expect(item.composition, '椅子在角色身旁');
    expect(item.subjectDirection, '身体朝右');
    expect(item.gazeDirection, '看向画面右侧');
    expect(item.actionStage, '准备');
    expect(item.spatialRelation, '角色扶着椅子起身');
    expect(item.chronologyCue, '动作前');
    expect(item.cameraAngle, '');
    expect(item.visualFocus, '');
    expect(item.lightingMood, '');
    expect(item.colorPalette, '');
    expect(item.narrativeFunction, '');
    expect(item.transitionHint, '');
    expect(items.last.cutResultId, 'folder:临时:合集单人篇1.png');
  });

  test('按原图来源清理旧裁切结果避免故事板重复资源', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    const originalPath = 'D:\\demo\\grid.png';
    const originalName = 'grid.png';
    final now = DateTime.now().toIso8601String();

    database
      ..upsertImportedImage(
        id: 'image-old',
        originalPath: originalPath,
        originalName: originalName,
        storedPath: p.join(root.path, 'old.png'),
        width: 400,
        height: 400,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-old',
        imageId: 'image-old',
        status: 'exported',
        rows: 4,
        columns: 4,
        confidence: 0.9,
      )
      ..insertCutResult(
        id: 'result-old',
        taskId: 'task-old',
        imageId: 'image-old',
        indexNo: 1,
        path: p.join(root.path, 'old1.png'),
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      )
      ..upsertImportedImage(
        id: 'image-new',
        originalPath: originalPath,
        originalName: originalName,
        storedPath: p.join(root.path, 'new.png'),
        width: 400,
        height: 400,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-new',
        imageId: 'image-new',
        status: 'recognized',
        rows: 4,
        columns: 4,
        confidence: 0.9,
      );

    expect(database.listCutResults().map((result) => result.id), [
      'result-old',
    ]);

    database.deleteCutResultsForImageSource(
      originalPath: originalPath,
      originalName: originalName,
    );

    database.insertCutResult(
      id: 'result-new',
      taskId: 'task-new',
      imageId: 'image-new',
      indexNo: 1,
      path: p.join(root.path, 'new1.png'),
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      selected: true,
    );

    final results = database.listCutResults();
    expect(results.length, 1);
    expect(results.single.id, 'result-new');
  });

  test('按图片 id 删除对应裁切结果', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    final now = DateTime.now().toIso8601String();
    for (final imageId in ['image-a', 'image-b']) {
      database
        ..upsertImportedImage(
          id: imageId,
          originalPath: 'D:\\demo\\$imageId.png',
          originalName: '$imageId.png',
          storedPath: p.join(root.path, '$imageId.png'),
          width: 400,
          height: 400,
          createdAt: now,
        )
        ..upsertCutTask(
          id: 'task-$imageId',
          imageId: imageId,
          status: 'exported',
          rows: 1,
          columns: 1,
          confidence: 0.9,
        )
        ..insertCutResult(
          id: 'result-$imageId',
          taskId: 'task-$imageId',
          imageId: imageId,
          indexNo: 1,
          path: p.join(root.path, '$imageId-cut.png'),
          x: 0,
          y: 0,
          width: 100,
          height: 100,
          selected: true,
        );
    }

    database.deleteCutResultsForImage('image-a');

    final results = database.listCutResults();
    expect(results.length, 1);
    expect(results.single.imageId, 'image-b');
  });

  test('清理文件已丢失的裁切结果记录', () async {
    final root = await Directory.systemTemp.createTemp('storyboard_db_');
    addTearDown(() => root.delete(recursive: true));

    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    addTearDown(database.dispose);

    final existingFile = File(p.join(root.path, 'existing.png'));
    await existingFile.writeAsBytes([1, 2, 3]);
    final missingPath = p.join(root.path, 'missing.png');
    final now = DateTime.now().toIso8601String();

    database
      ..upsertImportedImage(
        id: 'image-cleanup',
        originalPath: 'D:\\demo\\cleanup.png',
        originalName: 'cleanup.png',
        storedPath: p.join(root.path, 'cleanup.png'),
        width: 400,
        height: 400,
        createdAt: now,
      )
      ..upsertCutTask(
        id: 'task-cleanup',
        imageId: 'image-cleanup',
        status: 'exported',
        rows: 1,
        columns: 2,
        confidence: 0.9,
      )
      ..insertCutResult(
        id: 'result-existing',
        taskId: 'task-cleanup',
        imageId: 'image-cleanup',
        indexNo: 1,
        path: existingFile.path,
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      )
      ..insertCutResult(
        id: 'result-missing',
        taskId: 'task-cleanup',
        imageId: 'image-cleanup',
        indexNo: 2,
        path: missingPath,
        x: 100,
        y: 0,
        width: 100,
        height: 100,
        selected: true,
      );

    expect(database.deleteMissingCutResults(), 1);

    final results = database.listCutResults();
    expect(results.length, 1);
    expect(results.single.id, 'result-existing');
  });
}
