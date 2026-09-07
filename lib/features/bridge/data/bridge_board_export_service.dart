import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../../storyboard/domain/storyboard_models.dart';
import '../domain/bridge_manifest.dart';
import 'bridge_loopback_client.dart';

/// 导出页和故事板共用的稳定画板直传协议。
class BridgeBoardExportService {
  const BridgeBoardExportService();
  Future<BridgeLoopbackResult> send({
    required StoryboardBoard board,
    required String projectId,
    required String projectName,
    bool workflow = false,
    List<Map<String, Object?>> shots = const [],
    BridgeLoopbackClient? client,
  }) async {
    final frames = <Map<String, Object?>>[];
    final uploads = <BridgeDirectUpload>[];
    final checksums = <String, String>{};
    final orderedItems = board.items.toList()
      ..sort((a, b) => a.slotIndex.compareTo(b.slotIndex));
    for (final item in orderedItems) {
      final file = File(item.asset.path);
      if (!file.existsSync()) {
        throw FormatException('故事板图片不存在：${file.path}');
      }
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) {
        throw FormatException('无法读取故事板图片：${file.path}');
      }
      final shotNumber = item.slotIndex + 1;
      final bytes = await file.readAsBytes();
      final checksum = sha256.convert(bytes).toString();
      final extension = p.extension(file.path).toLowerCase().isEmpty
          ? '.png'
          : p.extension(file.path).toLowerCase();
      final uploadName =
          'frame_${item.slotIndex.toString().padLeft(4, '0')}$extension';
      final relativePath =
          'images/original/${item.slotIndex.toString().padLeft(4, '0')}$extension';
      final stableId = BridgeManifest.stableFrameId(
        board.id,
        item.slotIndex,
        BridgeVariant.original,
      );
      frames.add({
        'stable_id': stableId,
        'shot_stable_id': BridgeManifest.stableShotId(board.id, shotNumber),
        'slot_index': item.slotIndex,
        'shot_number': shotNumber,
        'frame_index': item.slotIndex,
        'timestamp_ms': 0,
        'source_name': item.asset.sourceName,
        'relative_path': relativePath,
        'upload_name': uploadName,
        'width': decoded.width,
        'height': decoded.height,
        'variant': BridgeVariant.original.wireName,
        'caption': item.caption,
        'sha256': checksum,
        'metadata': {'source_storyboard_asset_id': item.asset.id},
      });
      checksums[relativePath] = checksum;
      uploads.add(BridgeDirectUpload(file: file, uploadName: uploadName));
    }
    if (frames.isEmpty) {
      throw const FormatException('当前故事板没有可发送的图片');
    }
    final manifest = <String, Object?>{
      'schema': bridgeSchema,
      'schema_version': bridgeSchemaVersion,
      'bridge_id': BridgeManifest.stableBridgeId(projectId, board.id),
      'direction': 'film-to-shiyin',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'source': {
        'app': 'filmstoryboard',
        'project_id': projectId,
        'project_name': projectName,
        'board_id': board.id,
      },
      'canvas': {
        'create_prompt_nodes': false,
        if (workflow) 'workflow': 'film-production-v1',
      },
      'storyboard': {
        'board_name': board.name,
        'selected_variant': BridgeVariant.original.wireName,
        'variants': [BridgeVariant.original.wireName],
        'frames': frames,
      },
      'shots': shots,
      'checksums': checksums,
    };
    final loopback = client ?? BridgeLoopbackClient();
    try {
      return await loopback.sendDirect(
        manifest: manifest,
        uploads: uploads,
        canvasTitle: board.name,
        requireWorkflow: workflow,
      );
    } finally {
      if (client == null) loopback.close();
    }
  }
}
