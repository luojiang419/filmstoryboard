import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class DwPoseModelSpec {
  const DwPoseModelSpec({
    required this.fileName,
    required this.byteLength,
    required this.sha256Hash,
  });

  final String fileName;
  final int byteLength;
  final String sha256Hash;
}

class DwPoseModelFiles {
  const DwPoseModelFiles({required this.detector, required this.pose});

  final File detector;
  final File pose;
}

class DwPoseModelManager {
  DwPoseModelManager({
    Directory? bundledModelDirectory,
    DwPoseModelSpec? detectorModelSpec,
    DwPoseModelSpec? poseModelSpec,
  }) : modelDirectory = bundledModelDirectory ?? defaultBundledModelDirectory(),
       _detectorModelSpec = detectorModelSpec ?? detectorSpec,
       _poseModelSpec = poseModelSpec ?? poseSpec;

  static final detectorSpec = DwPoseModelSpec(
    fileName: 'yolox_l.onnx',
    byteLength: 216746733,
    sha256Hash:
        '7860ae79de6c89a3c1eb72ae9a2756c0ccfbe04b7791bb5880afabd97855a411',
  );
  static final poseSpec = DwPoseModelSpec(
    fileName: 'dw-ll_ucoco_384.onnx',
    byteLength: 134399116,
    sha256Hash:
        '724f4ff2439ed61afb86fb8a1951ec39c6220682803b4a8bd4f598cd913b1843',
  );

  final Directory modelDirectory;
  final DwPoseModelSpec _detectorModelSpec;
  final DwPoseModelSpec _poseModelSpec;
  DwPoseModelFiles? _verifiedFiles;

  static Directory defaultBundledModelDirectory() => Directory(
    p.join(
      File(Platform.resolvedExecutable).parent.path,
      'data',
      'dwpose',
      'models',
    ),
  );

  File fileFor(DwPoseModelSpec spec) =>
      File(p.join(modelDirectory.path, spec.fileName));

  Future<bool> areModelsAvailable() async {
    if (_verifiedFiles != null) return true;
    for (final spec in [_detectorModelSpec, _poseModelSpec]) {
      if (!await verifyFile(fileFor(spec), spec)) return false;
    }
    _verifiedFiles = DwPoseModelFiles(
      detector: fileFor(_detectorModelSpec),
      pose: fileFor(_poseModelSpec),
    );
    return true;
  }

  Future<DwPoseModelFiles> loadBundledModels() async {
    final cached = _verifiedFiles;
    if (cached != null &&
        await cached.detector.exists() &&
        await cached.pose.exists()) {
      return cached;
    }
    for (final spec in [_detectorModelSpec, _poseModelSpec]) {
      final file = fileFor(spec);
      if (!await verifyFile(file, spec)) {
        throw StateError('DWPose 内置模型缺失或损坏：${file.path}。请重新安装 FilmStoryboard。');
      }
    }
    return _verifiedFiles = DwPoseModelFiles(
      detector: fileFor(_detectorModelSpec),
      pose: fileFor(_poseModelSpec),
    );
  }

  static Future<bool> verifyFile(File file, DwPoseModelSpec spec) async {
    if (!await file.exists()) return false;
    if (await file.length() != spec.byteLength) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == spec.sha256Hash.toLowerCase();
  }
}
