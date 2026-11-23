import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/script_shot_group.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_shooting_script_sync_controller.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('从视频焦点帧生成脚本并支持编辑、复制、排序、归档和恢复', () async {
    final fixture = await _createFixture();
    final now = DateTime.utc(2026, 8, 2);
    final firstFrame = await _writeImage(
      fixture.directories.frames,
      'frame-1.png',
      img.ColorRgb8(200, 40, 30),
    );
    final secondFrame = await _writeImage(
      fixture.directories.frames,
      'frame-2.png',
      img.ColorRgb8(30, 80, 210),
    );
    final video = _video(now);
    final frames = [
      _frame('frame-1', video.id, 0, firstFrame.path, now),
      _frame('frame-2', video.id, 1, secondFrame.path, now),
    ];
    final videoRepository = VideoAnalysisRepository(fixture.database);
    videoRepository.upsertSourceVideo(video);
    for (final frame in frames) {
      videoRepository.upsertVideoFrame(frame);
    }
    final analyses = [
      _analysis(
        'analysis-1',
        video.id,
        'frame-1',
        1,
        now,
        caption: '产品进入画面',
        shotSize: '中景',
        movement: '推',
        scene: '摄影棚',
        movementTrend: '向前移动',
        actionStage: '准备',
        colorPalette: '暖灰石墙为底，搭配深棕皮革、黑白条纹与米白长裤的暖中性色调',
        continuesToNext: true,
      ),
      _analysis(
        'analysis-2',
        video.id,
        'frame-2',
        2,
        now,
        caption: '纹理细节特写',
        shotSize: '特写',
        movement: '固定',
        scene: '摄影棚',
        movementTrend: '完成向前移动',
        actionStage: '结果',
      ),
    ];
    final sourceShots = [
      _videoShot('video-shot-1', video.id, 'frame-1', 1, 0, 1200, now),
      _videoShot('video-shot-2', video.id, 'frame-2', 2, 1200, 2800, now),
    ];

    final script = fixture.controller.createFromVideo(
      video: video,
      frames: frames,
      videoShots: sourceShots,
      analyses: analyses,
    );

    expect(script, isNotNull);
    expect(fixture.controller.value.shots, hasLength(2));
    expect(fixture.controller.value.shots.first.content, '产品进入画面');
    expect(fixture.controller.value.shots.first.shotSize, '中景');
    expect(
      fixture.controller.value.shots.first.colorPalette,
      contains('暖中性色调'),
    );
    expect(
      fixture.controller.value.shots.first.colorPalette,
      isNot(contains('皮革')),
    );
    expect(
      fixture.controller.value.shots.first.colorPalette,
      isNot(contains('长裤')),
    );
    expect(fixture.controller.value.shots.first.durationSeconds, 1.2);
    expect(fixture.controller.value.shots.first.continuesToNext, isFalse);
    expect(fixture.controller.value.shots[1].continuesFromPrevious, isFalse);
    expect(ScriptShotGroup.group(fixture.controller.value.shots), hasLength(2));

    final first = fixture.controller.value.shots.first;
    fixture.controller.updateShot(
      first.copyWith(
        content: '人工修订内容',
        cameraNotes: '使用柔光箱',
        productCode: 'SKU-001',
      ),
    );
    fixture.controller.batchUpdateShots(
      field: ShootingScriptBatchField.productStyling,
      fieldValue: '统一白色造型',
    );
    expect(
      fixture.controller.value.shots.map((shot) => shot.productStyling),
      everyElement('统一白色造型'),
    );
    final duplicate = fixture.controller.duplicateShot(first.id)!;
    expect(fixture.controller.value.shots, hasLength(3));
    expect(duplicate.content, '人工修订内容');

    fixture.controller.reorderShots(1, 0);
    expect(fixture.controller.value.shots.first.id, duplicate.id);
    expect(fixture.controller.value.shots.map((shot) => shot.shotNumber), [
      1,
      2,
      3,
    ]);
    fixture.controller.deleteShot(duplicate.id);
    expect(fixture.controller.value.shots, hasLength(2));

    final copiedScript = fixture.controller.duplicateSelectedScript();
    expect(copiedScript, isNotNull);
    expect(fixture.controller.value.shots, hasLength(2));
    expect(fixture.controller.value.shots.first.scriptId, copiedScript!.id);
    expect(fixture.controller.value.shots.first.id, isNot(first.id));

    final scriptOrderBeforeReorder = fixture.controller.value.scripts
        .map((item) => item.id)
        .toList();
    fixture.controller.reorderScripts(0, scriptOrderBeforeReorder.length);
    expect(
      fixture.controller.value.scripts.last.id,
      scriptOrderBeforeReorder.first,
    );

    expect(fixture.controller.renameSelectedScript('正式拍摄脚本'), isTrue);
    fixture.controller.toggleArchiveSelectedScript();
    expect(
      fixture.controller.value.selectedScript!.status,
      ShootingScriptStatus.archived,
    );
    fixture.controller.toggleArchiveSelectedScript();
    expect(
      fixture.controller.value.selectedScript!.status,
      ShootingScriptStatus.draft,
    );

    final restored = ShootingScriptController(
      repository: ShootingScriptRepository(fixture.database),
      directories: fixture.directories,
    );
    addTearDown(restored.dispose);
    expect(restored.value.scripts, hasLength(2));
    expect(restored.value.scripts.any((item) => item.name == '正式拍摄脚本'), isTrue);
  });

  test('待解析候选帧可先建脚本且解析回填保留用户已填写内容', () async {
    final fixture = await _createFixture();
    final now = DateTime.utc(2026, 8, 11);
    final frameFile = await _writeImage(
      fixture.directories.frames,
      'pending-frame.png',
      img.ColorRgb8(80, 120, 200),
    );
    final video = _video(now);
    final frame = _frame(
      'pending-frame',
      video.id,
      0,
      frameFile.path,
      now,
    ).copyWith(status: ProcessingStatus.pending);
    VideoAnalysisRepository(fixture.database)
      ..upsertSourceVideo(video)
      ..upsertVideoFrame(frame);

    final initialScript = fixture.controller.createFromVideo(
      video: video,
      frames: [frame],
      videoShots: const [],
      analyses: const [],
    )!;
    final initialShot = fixture.controller.value.shots.single;
    expect(initialShot.content, isEmpty);
    fixture.controller.updateShot(initialShot.copyWith(content: '用户提前填写的镜头内容'));

    final updatedScript = fixture.controller.createFromVideo(
      video: video,
      frames: [frame.copyWith(status: ProcessingStatus.completed)],
      videoShots: const [],
      analyses: [
        _analysis(
          'pending-analysis',
          video.id,
          frame.id,
          1,
          now,
          caption: '模型解析镜头内容',
          shotSize: '近景',
          movement: '固定',
          scene: '室内',
        ),
      ],
    )!;
    final updatedShot = fixture.controller.value.shots.single;

    expect(updatedScript.id, initialScript.id);
    expect(updatedShot.id, initialShot.id);
    expect(updatedShot.content, '用户提前填写的镜头内容');
    expect(updatedShot.shotSize, '近景');
    expect(updatedShot.scene, '室内');
  });

  test('单镜头编辑只更新当前行并仅通知一次', () async {
    final fixture = await _createFixture();
    final script = fixture.controller.createEmpty(name: '单行更新脚本');
    final first = fixture.controller.addShot()!;
    final second = fixture.controller.addShot()!;
    final versionBefore = fixture.controller.value.selectedScript!.version;
    final secondUpdatedAtBefore = fixture.controller.value.shots
        .firstWhere((shot) => shot.id == second.id)
        .updatedAt;
    var notifications = 0;
    void listener() => notifications++;
    fixture.controller.addListener(listener);
    addTearDown(() => fixture.controller.removeListener(listener));

    fixture.controller.updateShot(first.copyWith(content: '只修改第一个镜头'));

    expect(notifications, 1);
    expect(fixture.controller.value.selectedScript!.version, versionBefore + 1);
    expect(fixture.controller.value.selectedShotId, first.id);
    expect(fixture.controller.value.shots.first.content, '只修改第一个镜头');
    expect(fixture.controller.value.shots[1].updatedAt, secondUpdatedAtBefore);
    final repository = ShootingScriptRepository(fixture.database);
    expect(repository.getScript(script.id)!.version, versionBefore + 1);
    expect(repository.getShot(script.id, first.id)!.content, '只修改第一个镜头');
    expect(
      repository.getShot(script.id, second.id)!.updatedAt,
      secondUpdatedAtBefore,
    );
  });

  test('加载旧工程脚本时将相对帧图路径转换为可显示路径', () async {
    final fixture = await _createFixture();
    final source = await _writeImage(
      fixture.directories.frames,
      'legacy-frame.png',
      img.ColorRgb8(120, 90, 220),
    );
    final script = fixture.controller.createEmpty(name: '旧工程脚本');
    final relativePath = p
        .relative(source.path, from: fixture.directories.workspaceRoot.path)
        .replaceAll('\\', '/');
    final now = DateTime.now().toUtc();
    ShootingScriptRepository(fixture.database).replaceShots(script.id, [
      ScriptShot(
        id: 'legacy-shot-1',
        scriptId: script.id,
        shotNumber: 1,
        durationSeconds: 1,
        framePath: relativePath,
        visual: '',
        content: '旧工程相对路径镜头',
        shotSize: '',
        cameraMovement: '',
        cameraNotes: '',
        composition: '',
        cameraAngle: '',
        lightingMood: '',
        colorPalette: '',
        visualFocus: '',
        transitionHint: '',
        movementTrend: '',
        actionStage: '',
        continuesFromPrevious: false,
        continuesToNext: false,
        scene: '',
        productCode: '',
        productStyling: '',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.completed,
        updatedAt: now,
      ),
    ]);

    final restored = ShootingScriptController(
      repository: ShootingScriptRepository(fixture.database),
      directories: fixture.directories,
    );
    addTearDown(restored.dispose);

    expect(
      p.normalize(restored.value.shots.single.framePath),
      p.normalize(source.path),
    );
    expect(File(restored.value.shots.single.framePath).existsSync(), isTrue);
  });

  test('加载现有视频脚本时按帧修复误写为叙事功能的内容列', () async {
    final fixture = await _createFixture();
    final now = DateTime.utc(2026, 8, 5);
    final firstFrame = await _writeImage(
      fixture.directories.frames,
      'legacy-video-frame-1.png',
      img.ColorRgb8(200, 70, 50),
    );
    final secondFrame = await _writeImage(
      fixture.directories.frames,
      'legacy-video-frame-2.png',
      img.ColorRgb8(50, 120, 210),
    );
    final video = _video(now);
    final frames = [
      _frame('legacy-frame-1', video.id, 0, firstFrame.path, now),
      _frame('legacy-frame-2', video.id, 1, secondFrame.path, now),
    ];
    final analyses = [
      _analysis(
        'legacy-analysis-1',
        video.id,
        'legacy-frame-1',
        1,
        now,
        caption: '模特站在门口展示黑色外套',
        shotSize: '中景',
        movement: '固定',
        scene: '街边门口',
      ),
      _analysis(
        'legacy-analysis-2',
        video.id,
        'legacy-frame-2',
        2,
        now,
        caption: '模特向右侧抬手示意',
        shotSize: '中景',
        movement: '固定',
        scene: '街边门口',
      ),
    ];
    final videoRepository = VideoAnalysisRepository(fixture.database)
      ..upsertSourceVideo(video);
    for (final frame in frames) {
      videoRepository.upsertVideoFrame(frame);
    }
    for (final analysis in analyses) {
      videoRepository.upsertVideoFrameAnalysis(analysis);
    }
    final sourceShots = [
      _videoShot('legacy-shot-1', video.id, 'legacy-frame-1', 1, 0, 1200, now),
      _videoShot(
        'legacy-shot-2',
        video.id,
        'legacy-frame-2',
        2,
        1200,
        2400,
        now,
      ),
    ];
    for (final sourceShot in sourceShots) {
      videoRepository.upsertVideoShot(sourceShot);
    }

    final script = fixture.controller.createFromVideo(
      video: video,
      frames: frames,
      videoShots: sourceShots,
      analyses: analyses,
    )!;
    final repository = ShootingScriptRepository(fixture.database);
    repository.upsertScript(
      ShootingScript(
        id: script.id,
        name: script.name,
        sourceStoryboardId: script.sourceStoryboardId,
        sourceVideoId: null,
        status: script.status,
        version: script.version + 1,
        createdAt: script.createdAt,
        updatedAt: now,
      ),
    );
    final oldShots = repository.listShots(script.id);
    repository.replaceShots(script.id, [
      oldShots[0].copyWith(content: '广告产品记忆点'),
      oldShots[1].copyWith(content: '人工保留的画面内容'),
    ]);

    final restored = ShootingScriptController(
      repository: repository,
      videoRepository: videoRepository,
      directories: fixture.directories,
    );
    addTearDown(restored.dispose);

    expect(restored.value.shots[0].content, '模特站在门口展示黑色外套');
    expect(restored.value.shots[1].content, '人工保留的画面内容');
    expect(repository.listShots(script.id).map((shot) => shot.content), [
      '模特站在门口展示黑色外套',
      '人工保留的画面内容',
    ]);
  });

  test('手动新建空故事板时创建关联的空拍摄脚本', () async {
    final fixture = await _createFixture();
    const board = StoryboardBoard(
      id: 'manual-board-1',
      name: '新画板 1',
      width: 1920,
      height: 1080,
      rows: 3,
      columns: 3,
      gap: 12,
      items: [],
    );

    final script = fixture.controller.createForStoryboard(board);

    expect(script.sourceStoryboardId, board.id);
    expect(script.sourceVideoId, isNull);
    expect(script.name, '新画板 1 · 拍摄脚本');
    expect(fixture.controller.value.selectedScript?.id, script.id);
    expect(fixture.controller.value.shots, isEmpty);
  });

  test('故事板同步器发现手动新画板时自动创建主拍摄脚本', () async {
    final fixture = await _createFixture();
    final storyboardController = StoryboardController(
      database: fixture.database,
    );
    addTearDown(storyboardController.dispose);
    final syncController = StoryboardShootingScriptSyncController(
      storyboardController: storyboardController,
      shootingScriptController: fixture.controller,
    );
    addTearDown(syncController.dispose);

    final board = storyboardController.addBoard();

    final script = fixture.controller.value.scripts.singleWhere(
      (item) => item.sourceStoryboardId == board.id,
    );
    expect(script.sourceVideoId, isNull);
    expect(script.name, '${board.name} · 拍摄脚本');
  });

  test('从视频创建的故事板脚本同时保留故事板和源视频关联', () async {
    final fixture = await _createFixture();
    final board = StoryboardBoard(
      id: 'video-board',
      name: '视频故事板',
      width: 1920,
      height: 1080,
      rows: 1,
      columns: 1,
      gap: 12,
      items: const [],
    );

    final script = fixture.controller.createForStoryboard(
      board,
      sourceVideoId: 'source-video-1',
    );

    expect(script.sourceStoryboardId, board.id);
    expect(script.sourceVideoId, 'source-video-1');
  });

  test('故事板和主拍摄脚本实时同步共享字段', () async {
    final fixture = await _createFixture();
    final storyboardController = StoryboardController(
      database: fixture.database,
    );
    addTearDown(storyboardController.dispose);
    final syncController = StoryboardShootingScriptSyncController(
      storyboardController: storyboardController,
      shootingScriptController: fixture.controller,
    );
    addTearDown(syncController.dispose);
    final board = storyboardController.value.selectedBoard!;
    fixture.controller.createForStoryboard(board);
    const asset = StoryboardCutAsset(
      id: 'manual-asset-1',
      imageId: 'manual-image-1',
      sourceName: '手动素材',
      path: 'C:/fixtures/manual-asset-1.png',
      indexNo: 1,
    );

    storyboardController.placeAssetAtSlot(asset, 0);

    final shot = fixture.controller.value.shots.single;
    expect(shot.sourceStoryboardAssetId, asset.id);
    expect(shot.framePath, asset.path);
    fixture.controller.updateShot(shot.copyWith(content: '脚本回写的镜头内容'));
    expect(
      storyboardController.value.selectedBoard!.items.single.caption,
      '脚本回写的镜头内容',
    );

    fixture.controller.deleteShot(shot.id);
    expect(storyboardController.value.selectedBoard!.items, isEmpty);

    final duplicate = storyboardController.duplicateSelectedBoard()!;
    final duplicateScript = fixture.controller.createForStoryboard(duplicate);
    expect(duplicate.id, isNot(board.id));
    expect(duplicateScript.sourceStoryboardId, duplicate.id);
  });

  test('故事板图片替换后拍摄脚本自动切换到新帧路径', () async {
    final fixture = await _createFixture();
    final storyboardController = StoryboardController(
      database: fixture.database,
      directories: fixture.directories,
    );
    addTearDown(storyboardController.dispose);
    final syncController = StoryboardShootingScriptSyncController(
      storyboardController: storyboardController,
      shootingScriptController: fixture.controller,
    );
    addTearDown(syncController.dispose);
    final source = await _writeImage(
      fixture.directories.frames,
      'source-frame.png',
      img.ColorRgb8(40, 90, 180),
    );
    final generated = await _writeImage(
      fixture.directories.frames,
      'expanded-frame.png',
      img.ColorRgb8(180, 90, 40),
    );
    const asset = StoryboardCutAsset(
      id: 'source-frame-asset',
      imageId: 'source-frame-image',
      sourceName: '源帧',
      path: 'source-frame.png',
      indexNo: 1,
    );
    final board = storyboardController.value.selectedBoard!;
    fixture.controller.createForStoryboard(board);
    storyboardController.placeAssetAtSlot(asset, 0);
    final oldItem = storyboardController.value.selectedBoard!.itemAtSlot(0)!;
    final applied = await storyboardController.replaceItemImage(
      item: oldItem,
      imagePath: generated.path,
    );

    expect(applied, isTrue);
    final updatedItem = storyboardController.value.selectedBoard!.itemAtSlot(
      0,
    )!;
    expect(updatedItem.asset.path, isNot(oldItem.asset.path));
    expect(File(updatedItem.asset.path).existsSync(), isTrue);
    expect(updatedItem.asset.path, contains('手动替换'));
    final shot = fixture.controller.value.shots.single;
    expect(shot.sourceStoryboardAssetId, updatedItem.asset.id);
    expect(shot.framePath, updatedItem.asset.path);
    expect(shot.framePath, isNot(source.path));
  });

  test('只有手动设置首帧到结束帧才会形成镜头组', () async {
    final fixture = await _createFixture();
    fixture.controller.createEmpty(name: '手动镜头组');
    final first = fixture.controller.addShot()!;
    final second = fixture.controller.addShot()!;
    final third = fixture.controller.addShot()!;
    fixture.controller.updateShot(first.copyWith(scene: '室内', content: '动作开始'));
    fixture.controller.updateShot(
      second.copyWith(scene: '街道', content: '动作进行'),
    );
    fixture.controller.updateShot(third.copyWith(scene: '棚拍', content: '动作结束'));

    final applied = fixture.controller.setContinuousShotRange(
      startShotId: first.id,
      endShotId: third.id,
    );

    expect(applied, isTrue);
    final shots = fixture.controller.value.shots;
    expect(shots[0].continuesToNext, isTrue);
    expect(shots[1].continuesFromPrevious, isTrue);
    expect(shots[1].continuesToNext, isTrue);
    expect(shots[2].continuesFromPrevious, isTrue);
    expect(ScriptShotGroup.group(shots).single.shots, hasLength(3));

    expect(fixture.controller.clearContinuousShotGroup(second.id), isTrue);
    final cleared = fixture.controller.value.shots;
    expect(cleared.any((shot) => shot.continuesFromPrevious), isFalse);
    expect(cleared.any((shot) => shot.continuesToNext), isFalse);
    expect(ScriptShotGroup.group(cleared), hasLength(3));
  });

  test('脚本导出填充字段、保留图片槽位为空，并按原始字节复制镜头图片', () async {
    final fixture = await _createFixture();
    final source = await _writeImage(
      fixture.directories.frames,
      'original.jpg',
      img.ColorRgb8(90, 160, 70),
    );
    final script = fixture.controller.createEmpty(name: '商品 A 脚本');
    final shot = fixture.controller.addShot()!;
    fixture.controller.updateShot(
      shot.copyWith(
        durationSeconds: 2.5,
        framePath: source.path,
        content: '模特拿起商品并转向镜头',
        shotSize: '近景',
        cameraMovement: '推',
        cameraNotes: '主光从左前方进入',
        scene: '白色摄影棚',
        productCode: 'A-1024',
        visual: '商品正面图',
        productStyling: '白衬衫 + 银色配饰',
        dialogue: '现在就来试试',
        sound: '轻快音乐进入',
        prompt: '图片1中的商品保持一致，模特缓慢抬手。',
        status: ProcessingStatus.completed,
      ),
    );

    final xlsx = await fixture.controller.exportXlsx();
    final originals = await fixture.controller.exportOriginalImages();

    expect(xlsx, isNotNull);
    expect(originals, isNotNull);
    expect(originals!.copiedCount, 1);
    expect(originals.missingCount, 0);
    expect(
      p.isWithin(fixture.directories.scripts.path, originals.directory.path),
      isTrue,
    );
    expect(p.basename(originals.directory.path), '商品 A 脚本-原分镜图');
    final copied = originals.directory.listSync().whereType<File>().single;
    expect(await copied.readAsBytes(), await source.readAsBytes());

    final files = _archiveFiles(await xlsx!.readAsBytes());
    final workbook = utf8.decode(files['xl/workbook.xml']!);
    final primary = utf8.decode(files['xl/worksheets/sheet1.xml']!);
    final extra = utf8.decode(files['xl/worksheets/sheet2.xml']!);
    expect(workbook, contains('name="LV1"'));
    expect(workbook, contains('name="附加信息"'));
    expect(primary, contains('内容：${script.name}'));
    expect(primary, contains('模特拿起商品并转向镜头'));
    expect(primary, contains('近景'));
    expect(primary, contains('推'));
    expect(primary, contains('主光从左前方进入'));
    expect(primary, contains('白色摄影棚'));
    expect(primary, contains('A-1024'));
    expect(primary, isNot(contains('商品正面图')));
    expect(RegExp(r'<c r="I3"[^>]*\/>').hasMatch(primary), isTrue);
    expect(primary, contains('白衬衫 + 银色配饰'));
    expect(extra, contains('时长（秒）'));
    expect(extra, contains('现在就来试试'));
    expect(extra, contains('轻快音乐进入'));
    expect(extra, contains('图片1中的商品保持一致'));
    expect(
      files.keys.where((name) => name.startsWith('xl/media/')),
      hasLength(1),
    );
  });
}

Future<
  ({
    Directory root,
    AppDirectories directories,
    AppDatabase database,
    ShootingScriptController controller,
  })
>
_createFixture() async {
  final root = await Directory.systemTemp.createTemp('shooting_script_ctrl_');
  final directories = await AppDirectories.create(executableDirectory: root);
  final database = await AppDatabase.open(directories.databaseFile);
  final controller = ShootingScriptController(
    repository: ShootingScriptRepository(database),
    directories: directories,
  );
  addTearDown(() async {
    controller.dispose();
    database.dispose();
    await root.delete(recursive: true);
  });
  return (
    root: root,
    directories: directories,
    database: database,
    controller: controller,
  );
}

SourceVideo _video(DateTime now) => SourceVideo(
  id: 'video-1',
  originalPath: 'reference.mp4',
  fileName: 'reference.mp4',
  storedPath: 'videos/reference.mp4',
  durationMs: 2800,
  frameRate: 25,
  width: 1920,
  height: 1080,
  hasAudio: true,
  frameCount: 2,
  successfulFrames: 2,
  failedFrames: 0,
  status: ProcessingStatus.completed,
  errorMessage: '',
  createdAt: now,
  updatedAt: now,
);

VideoFrame _frame(
  String id,
  String videoId,
  int index,
  String path,
  DateTime now,
) => VideoFrame(
  id: id,
  videoId: videoId,
  index: index,
  timestampMs: index * 1200,
  path: path,
  width: 64,
  height: 36,
  sharpness: 1,
  brightness: .5,
  motionScore: .5,
  perceptualHash: '$index',
  isFocus: true,
  isSelected: true,
  status: ProcessingStatus.completed,
  errorMessage: '',
  createdAt: now,
);

VideoFrameAnalysis _analysis(
  String id,
  String videoId,
  String frameId,
  int sequence,
  DateTime now, {
  required String caption,
  required String shotSize,
  required String movement,
  required String scene,
  String movementTrend = '',
  String actionStage = '',
  String colorPalette = '',
  bool continuesFromPrevious = false,
  bool continuesToNext = false,
}) => VideoFrameAnalysis(
  id: id,
  videoId: videoId,
  frameId: frameId,
  sequenceNo: sequence,
  dimensions: {
    'caption': caption,
    'detail': '$caption 的摄影细节',
    'shotSize': shotSize,
    'cameraMovement': movement,
    'narrativeFunction': '叙事功能 $sequence',
    'scene': scene,
    'movementTrend': movementTrend,
    'actionStage': actionStage,
    'colorPalette': colorPalette,
    'continuesFromPrevious': continuesFromPrevious.toString(),
    'continuesToNext': continuesToNext.toString(),
  },
  rawResponse: '{}',
  status: ProcessingStatus.completed,
  errorMessage: '',
  createdAt: now,
  updatedAt: now,
);

VideoShot _videoShot(
  String id,
  String videoId,
  String frameId,
  int number,
  int startMs,
  int endMs,
  DateTime now,
) => VideoShot(
  id: id,
  videoId: videoId,
  shotNumber: number,
  startMs: startMs,
  endMs: endMs,
  primaryFrameId: frameId,
  frameIds: [frameId],
  description: '画面描述 $number',
  storyFlow: '镜头叙事 $number',
  status: ProcessingStatus.completed,
  createdAt: now,
  updatedAt: now,
);

Future<File> _writeImage(
  Directory directory,
  String name,
  img.Color color,
) async {
  final image = img.Image(width: 64, height: 36);
  img.fill(image, color: color);
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(
    p.extension(name).toLowerCase() == '.jpg'
        ? img.encodeJpg(image, quality: 92)
        : img.encodePng(image),
  );
  return file;
}

Map<String, List<int>> _archiveFiles(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return {
    for (final file in archive)
      if (file.isFile) file.name: file.readBytes()!.toList(),
  };
}
