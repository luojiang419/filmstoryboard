import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:filmstoryboard/features/replicate/data/dwpose_model_manager.dart';
import 'package:filmstoryboard/features/replicate/data/dwpose_service.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  test('仓库内置 DWPose 官方权重规格和哈希正确', () async {
    final detector = File('assets/dwpose/models/yolox_l.onnx');
    final pose = File('assets/dwpose/models/dw-ll_ucoco_384.onnx');

    expect(detector.existsSync(), isTrue);
    expect(pose.existsSync(), isTrue);
    expect(
      await DwPoseModelManager.verifyFile(
        detector,
        DwPoseModelManager.detectorSpec,
      ),
      isTrue,
    );
    expect(
      await DwPoseModelManager.verifyFile(pose, DwPoseModelManager.poseSpec),
      isTrue,
    );
  });

  test('内置模型完整时直接返回两个权重文件', () async {
    final root = await Directory.systemTemp.createTemp('dwpose_bundled_');
    final detectorSpec = _testModelSpec(
      fileName: 'detector.onnx',
      expectedBytes: [1, 2, 3],
    );
    final poseSpec = _testModelSpec(
      fileName: 'pose.onnx',
      expectedBytes: [4, 5, 6],
    );
    final manager = DwPoseModelManager(
      bundledModelDirectory: root,
      detectorModelSpec: detectorSpec,
      poseModelSpec: poseSpec,
    );
    await manager.fileFor(detectorSpec).writeAsBytes([1, 2, 3]);
    await manager.fileFor(poseSpec).writeAsBytes([4, 5, 6]);

    try {
      expect(await manager.areModelsAvailable(), isTrue);
      final models = await manager.loadBundledModels();
      expect(models.detector.path, manager.fileFor(detectorSpec).path);
      expect(models.pose.path, manager.fileFor(poseSpec).path);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('内置模型损坏时提示重新安装且不创建下载残片', () async {
    final root = await Directory.systemTemp.createTemp('dwpose_bundled_bad_');
    final detectorSpec = _testModelSpec(
      fileName: 'detector.onnx',
      expectedBytes: [1, 2, 3],
    );
    final poseSpec = _testModelSpec(
      fileName: 'pose.onnx',
      expectedBytes: [4, 5, 6],
    );
    final manager = DwPoseModelManager(
      bundledModelDirectory: root,
      detectorModelSpec: detectorSpec,
      poseModelSpec: poseSpec,
    );
    await manager.fileFor(detectorSpec).writeAsBytes([1, 2, 3]);
    await manager.fileFor(poseSpec).writeAsBytes([4, 5, 0]);

    try {
      expect(await manager.areModelsAvailable(), isFalse);
      await expectLater(
        manager.loadBundledModels(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('重新安装'),
          ),
        ),
      );
      expect(
        await File('${manager.fileFor(poseSpec).path}.download').exists(),
        isFalse,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('YOLOX 解码只保留人物类别并执行 NMS', () {
    final output = List<double>.filled(8400 * 85, 0);
    void candidate(int row, double confidence) {
      final offset = row * 85;
      output[offset] = 0;
      output[offset + 1] = 0;
      output[offset + 2] = 2;
      output[offset + 3] = 2;
      output[offset + 4] = confidence;
      output[offset + 5] = confidence;
    }

    candidate(0, 0.9);
    candidate(1, 0.8);
    final boxes = DwPoseService.decodeDetectorOutput(output, imageScale: 1);

    expect(boxes, hasLength(1));
    expect(boxes.single.score, closeTo(0.81, 0.001));
  });

  test('SimCC 解码生成 133 点并插入颈部映射为 OpenPose 顺序', () {
    const keypoints = 133;
    const xBins = 576;
    const yBins = 768;
    final x = List<double>.filled(keypoints * xBins, -1);
    final y = List<double>.filled(keypoints * yBins, -1);
    for (var key = 0; key < keypoints; key++) {
      x[key * xBins + 100 + key] = 0.9;
      y[key * yBins + 120 + key] = 0.8;
    }

    final decoded = DwPoseService.decodePoseOutput(
      simccX: x,
      simccY: y,
      keypointCount: keypoints,
      xBins: xBins,
      yBins: yBins,
      centerX: 144,
      centerY: 192,
      scaleWidth: 288,
      scaleHeight: 384,
    );

    expect(decoded, hasLength(134));
    expect(decoded[1].score, greaterThan(0.3), reason: '颈部应由左右肩联合生成');
    expect(decoded[2].x, isNot(decoded[3].x), reason: '肩肘腕映射后不应坍缩');
  });

  test('骨架渲染输出黑底彩色身体、手部与面部关键点', () {
    final points = List.generate(
      134,
      (index) =>
          DwPosePoint(20 + (index % 20) * 4, 20 + (index ~/ 20) * 12, 0.9),
    );
    final canvas = DwPoseService.renderSkeleton(
      width: 160,
      height: 120,
      people: [points],
    );
    final bytes = img.encodePng(canvas);

    expect(bytes, isNotEmpty);
    expect(
      canvas.any((pixel) => pixel.r > 0 || pixel.g > 0 || pixel.b > 0),
      isTrue,
    );
    final corner = canvas.getPixel(159, 119);
    expect([corner.r, corner.g, corner.b], [0, 0, 0]);
  });
}

DwPoseModelSpec _testModelSpec({
  required String fileName,
  required List<int> expectedBytes,
}) {
  return DwPoseModelSpec(
    fileName: fileName,
    byteLength: expectedBytes.length,
    sha256Hash: sha256.convert(expectedBytes).toString(),
  );
}
