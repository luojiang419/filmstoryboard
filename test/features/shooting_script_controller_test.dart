import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
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
        scene: '桌面',
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
    expect(fixture.controller.value.shots.first.content, '镜头叙事 1');
    expect(fixture.controller.value.shots.first.shotSize, '中景');
    expect(fixture.controller.value.shots.first.durationSeconds, 1.2);

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

  test('脚本导出严格填充十列、附加页，并按原始字节复制镜头图片', () async {
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
    expect(primary, contains('商品正面图'));
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
    'scene': scene,
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
