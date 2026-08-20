import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../domain/bridge_manifest.dart';

class BridgeFrameSource {
  const BridgeFrameSource({
    required this.path,
    required this.sourceName,
    required this.slotIndex,
    required this.shotNumber,
    required this.frameIndex,
    required this.timestampMs,
    required this.width,
    required this.height,
    this.caption = '',
    this.variant = BridgeVariant.original,
    this.metadata = const <String, Object?>{},
  });

  final File path;
  final String sourceName;
  final int slotIndex;
  final int shotNumber;
  final int frameIndex;
  final int timestampMs;
  final int width;
  final int height;
  final String caption;
  final BridgeVariant variant;
  final Map<String, Object?> metadata;
}

class BridgeImportedFrame {
  const BridgeImportedFrame({
    required this.record,
    required this.file,
    required this.width,
    required this.height,
  });

  final BridgeFrameRecord record;
  final File file;
  final int width;
  final int height;
}

class BridgeImportResult {
  const BridgeImportResult({required this.manifest, required this.frames});

  final BridgeManifest manifest;
  final List<BridgeImportedFrame> frames;
}

class BridgePackageService {
  const BridgePackageService();

  Future<File> exportFilmToShiyin({
    required File outputFile,
    required String projectId,
    required String projectName,
    required String boardId,
    required String boardName,
    required List<BridgeFrameSource> frames,
    List<BridgeShotRecord> shots = const [],
    String? scriptId,
    String? scriptName,
    BridgeVariant selectedVariant = BridgeVariant.original,
  }) async {
    if (frames.isEmpty) throw const FormatException('没有可导出的故事板图片');
    final bridgeId = BridgeManifest.stableBridgeId(projectId, boardId);
    final archive = Archive();
    final checksums = <String, String>{};
    final manifestFrames = <BridgeFrameRecord>[];
    final variants = <BridgeVariant>{};
    for (final frame in frames) {
      if (!frame.path.existsSync()) {
        throw FormatException('故事板图片不存在：${frame.path.path}');
      }
      if (frame.width <= 0 || frame.height <= 0) {
        throw const FormatException('故事板图片缺少有效尺寸');
      }
      final variant = frame.variant;
      variants.add(variant);
      final fileName =
          '${(frame.frameIndex + 1).toString().padLeft(4, '0')}${p.extension(frame.path.path).toLowerCase()}';
      final relativePath = 'images/${variant.wireName}/$fileName';
      final bytes = await frame.path.readAsBytes();
      final checksum = sha256.convert(bytes).toString();
      checksums[relativePath] = checksum;
      archive.addFile(ArchiveFile.bytes(relativePath, bytes));
      manifestFrames.add(
        BridgeFrameRecord(
          stableId: BridgeManifest.stableFrameId(
            boardId,
            frame.frameIndex,
            variant,
          ),
          shotStableId: BridgeManifest.stableShotId(boardId, frame.shotNumber),
          slotIndex: frame.slotIndex,
          shotNumber: frame.shotNumber,
          frameIndex: frame.frameIndex,
          timestampMs: frame.timestampMs,
          sourceName: frame.sourceName,
          relativePath: relativePath,
          width: frame.width,
          height: frame.height,
          variant: variant,
          caption: frame.caption,
          sha256: checksum,
          metadata: frame.metadata,
        ),
      );
    }
    final manifest = BridgeManifest(
      bridgeId: bridgeId,
      direction: BridgeDirection.filmToShiyin,
      exportedAt: DateTime.now().toUtc(),
      source: {
        'app': 'filmstoryboard',
        'project_id': projectId,
        'project_name': projectName,
        'board_id': boardId,
        'script_id': scriptId ?? '',
        'script_name': scriptName ?? '',
      },
      canvas: {'create_prompt_nodes': true},
      boardName: boardName,
      selectedVariant: selectedVariant,
      variants: variants.toList(growable: false),
      frames: manifestFrames,
      shots: shots,
      checksums: checksums,
    );
    archive.addFile(
      ArchiveFile.bytes('manifest.json', utf8.encode('${manifest.encode()}\n')),
    );
    archive.addFile(
      ArchiveFile.bytes(
        'checksums.json',
        utf8.encode(
          '${const JsonEncoder.withIndent('  ').convert(checksums)}\n',
        ),
      ),
    );
    final encoded = ZipEncoder().encodeBytes(archive);
    final partial = File('${outputFile.path}.partial');
    await outputFile.parent.create(recursive: true);
    await partial.writeAsBytes(encoded, flush: true);
    if (outputFile.existsSync()) await outputFile.delete();
    await partial.rename(outputFile.path);
    return outputFile;
  }

  Future<BridgeImportResult> importShiyinToFilm({
    required File packageFile,
    required Directory destinationRoot,
    BridgeVariant? selectedVariant,
  }) async {
    if (!packageFile.existsSync()) {
      throw const FormatException('桥接包不存在');
    }
    const maxEntries = 10500;
    const maxFileBytes = 100 * 1024 * 1024;
    const maxTotalBytes = 2 * 1024 * 1024 * 1024;
    final archive = ZipDecoder().decodeBytes(await packageFile.readAsBytes());
    if (archive.length > maxEntries) {
      throw const FormatException('桥接包文件数量超过限制');
    }
    final entries = <String, ArchiveFile>{};
    var totalBytes = 0;
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (file.isSymbolicLink || !_isSafeRelativePath(name)) {
        throw FormatException('桥接包包含不安全路径：$name');
      }
      if (!file.isFile) continue;
      if (entries.containsKey(name)) {
        throw FormatException('桥接包路径重复：$name');
      }
      if (file.size > maxFileBytes) {
        throw FormatException('桥接包单文件超过限制：$name');
      }
      totalBytes += file.size;
      if (totalBytes > maxTotalBytes) {
        throw const FormatException('桥接包解压总大小超过限制');
      }
      entries[name] = file;
    }
    final manifestEntry = entries['manifest.json'];
    final checksumEntry = entries['checksums.json'];
    if (manifestEntry == null || checksumEntry == null) {
      throw const FormatException('桥接包缺少 manifest.json 或 checksums.json');
    }
    final manifestJson = jsonDecode(utf8.decode(manifestEntry.content));
    if (manifestJson is! Map<String, Object?>) {
      throw const FormatException('桥接 manifest 不是 JSON 对象');
    }
    final manifest = BridgeManifest.fromJson(manifestJson);
    if (manifest.direction != BridgeDirection.shiyinToFilm) {
      throw const FormatException('请选择 SHIYIN-AI 回传到 filmstoryboard 的桥接包');
    }
    final checksumJson = jsonDecode(utf8.decode(checksumEntry.content));
    if (checksumJson is! Map<String, Object?>) {
      throw const FormatException('桥接 checksums.json 格式无效');
    }
    final checksumMap = checksumJson.map(
      (key, value) => MapEntry(key, '$value'),
    );
    if (checksumMap.length != manifest.checksums.length ||
        checksumMap.entries.any(
          (entry) => manifest.checksums[entry.key] != entry.value,
        )) {
      throw const FormatException('桥接 manifest 与 checksums.json 不一致');
    }
    for (final checksum in checksumMap.entries) {
      final entry = entries[checksum.key];
      if (entry == null ||
          sha256.convert(entry.content).toString() != checksum.value) {
        throw FormatException('桥接资源摘要不匹配：${checksum.key}');
      }
    }
    final variant = selectedVariant ?? manifest.selectedVariant;
    final selectedFrames =
        manifest.frames.where((frame) => frame.variant == variant).toList()
          ..sort((first, second) {
            final slot = first.slotIndex.compareTo(second.slotIndex);
            return slot != 0
                ? slot
                : first.frameIndex.compareTo(second.frameIndex);
          });
    if (selectedFrames.isEmpty) {
      throw FormatException('桥接包没有 ${variant.wireName} 变体图片');
    }
    final bridgeSlug = sha256
        .convert(utf8.encode(manifest.bridgeId))
        .toString()
        .substring(0, 20);
    final targetDirectory = Directory(
      p.join(
        destinationRoot.path,
        'shiyin-bridge',
        bridgeSlug,
        variant.wireName,
      ),
    );
    await targetDirectory.create(recursive: true);
    final imported = <BridgeImportedFrame>[];
    for (var index = 0; index < selectedFrames.length; index++) {
      final frame = selectedFrames[index];
      final entry = entries[frame.relativePath];
      if (entry == null) {
        throw FormatException('桥接包缺少图片：${frame.relativePath}');
      }
      final decoded = img.decodeImage(entry.content);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        throw FormatException('桥接图片无法读取：${frame.relativePath}');
      }
      final extension = _safeImageExtension(frame.relativePath);
      final output = File(
        p.join(
          targetDirectory.path,
          'frame_${(index + 1).toString().padLeft(4, '0')}$extension',
        ),
      );
      final partial = File('${output.path}.partial');
      await partial.writeAsBytes(entry.content, flush: true);
      if (output.existsSync()) await output.delete();
      await partial.rename(output.path);
      imported.add(
        BridgeImportedFrame(
          record: frame,
          file: output,
          width: decoded.width,
          height: decoded.height,
        ),
      );
    }
    return BridgeImportResult(manifest: manifest, frames: imported);
  }

  bool _isSafeRelativePath(String value) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
      return false;
    }
    return value
        .split('/')
        .every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }

  String _safeImageExtension(String value) {
    final extension = p.extension(value).toLowerCase();
    return const {'.png', '.jpg', '.jpeg', '.webp'}.contains(extension)
        ? extension
        : '.png';
  }
}
