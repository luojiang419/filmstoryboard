import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
}
