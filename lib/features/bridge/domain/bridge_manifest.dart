import 'dart:convert';

const bridgeSchema = 'shiyin-film-bridge';
const bridgeSchemaVersion = 2;

enum BridgeDirection { filmToShiyin, shiyinToFilm }

enum BridgeVariant {
  original,
  expanded16x9,
  lineArt,
  replicated;

  String get wireName => switch (this) {
    BridgeVariant.original => 'original',
    BridgeVariant.expanded16x9 => 'expanded-16x9',
    BridgeVariant.lineArt => 'line-art',
    BridgeVariant.replicated => 'replicated',
  };

  static BridgeVariant parse(String value) {
    return BridgeVariant.values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => throw FormatException('不支持的桥接变体：$value'),
    );
  }
}

class BridgeFrameRecord {
  const BridgeFrameRecord({
    required this.stableId,
    required this.shotStableId,
    required this.slotIndex,
    required this.shotNumber,
    required this.frameIndex,
    required this.timestampMs,
    required this.sourceName,
    required this.relativePath,
    required this.width,
    required this.height,
    required this.variant,
    this.caption = '',
    this.sha256 = '',
    this.metadata = const <String, Object?>{},
  });

  final String stableId;
  final String shotStableId;
  final int slotIndex;
  final int shotNumber;
  final int frameIndex;
  final int timestampMs;
  final String sourceName;
  final String relativePath;
  final int width;
  final int height;
  final BridgeVariant variant;
  final String caption;
  final String sha256;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
    'stable_id': stableId,
    'shot_stable_id': shotStableId,
    'slot_index': slotIndex,
    'shot_number': shotNumber,
    'frame_index': frameIndex,
    'timestamp_ms': timestampMs,
    'source_name': sourceName,
    'relative_path': relativePath,
    'width': width,
    'height': height,
    'variant': variant.wireName,
    'caption': caption,
    'sha256': sha256,
    'metadata': metadata,
  };

  factory BridgeFrameRecord.fromJson(Map<String, Object?> json) {
    int integer(String key) => (json[key] as num?)?.toInt() ?? 0;
    return BridgeFrameRecord(
      stableId: '${json['stable_id'] ?? ''}',
      shotStableId: '${json['shot_stable_id'] ?? ''}',
      slotIndex: integer('slot_index'),
      shotNumber: integer('shot_number'),
      frameIndex: integer('frame_index'),
      timestampMs: integer('timestamp_ms'),
      sourceName: '${json['source_name'] ?? ''}',
      relativePath: '${json['relative_path'] ?? ''}',
      width: integer('width'),
      height: integer('height'),
      variant: BridgeVariant.parse('${json['variant'] ?? 'original'}'),
      caption: '${json['caption'] ?? ''}',
      sha256: '${json['sha256'] ?? ''}',
      metadata: (json['metadata'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }
}

class BridgeShotRecord {
  const BridgeShotRecord({
    required this.stableId,
    required this.shotNumber,
    required this.frameStableId,
    this.durationSeconds = 0,
    this.fields = const <String, String>{},
  });

  final String stableId;
  final int shotNumber;
  final String frameStableId;
  final double durationSeconds;
  final Map<String, String> fields;

  Map<String, Object?> toJson() => {
    'stable_id': stableId,
    'shot_number': shotNumber,
    'frame_stable_id': frameStableId,
    'duration_seconds': durationSeconds,
    ...fields,
  };
}

class BridgeManifest {
  const BridgeManifest({
    required this.bridgeId,
    required this.direction,
    required this.exportedAt,
    required this.source,
    required this.boardName,
    required this.selectedVariant,
    required this.frames,
    required this.shots,
    this.canvas = const <String, Object?>{},
    this.variants = const <BridgeVariant>[],
    this.checksums = const <String, String>{},
  });

  final String bridgeId;
  final BridgeDirection direction;
  final DateTime exportedAt;
  final Map<String, Object?> source;
  final Map<String, Object?> canvas;
  final String boardName;
  final BridgeVariant selectedVariant;
  final List<BridgeVariant> variants;
  final List<BridgeFrameRecord> frames;
  final List<BridgeShotRecord> shots;
  final Map<String, String> checksums;

  String get schema => bridgeSchema;

  Map<String, Object?> toJson() => {
    'schema': bridgeSchema,
    'schema_version': bridgeSchemaVersion,
    'bridge_id': bridgeId,
    'direction': direction == BridgeDirection.filmToShiyin
        ? 'film-to-shiyin'
        : 'shiyin-to-film',
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'source': source,
    'canvas': canvas,
    'storyboard': {
      'board_name': boardName,
      'selected_variant': selectedVariant.wireName,
      'variants': variants.map((item) => item.wireName).toList(growable: false),
      'frames': frames.map((item) => item.toJson()).toList(growable: false),
    },
    'shots': shots.map((item) => item.toJson()).toList(growable: false),
    'variants': variants
        .map((item) => {'name': item.wireName})
        .toList(growable: false),
    'checksums': checksums,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory BridgeManifest.fromJson(Map<String, Object?> json) {
    if (json['schema'] != bridgeSchema ||
        json['schema_version'] != bridgeSchemaVersion) {
      throw const FormatException('桥接 manifest 格式或版本不受支持');
    }
    final storyboard = (json['storyboard'] as Map?)?.cast<String, Object?>();
    if (storyboard == null) throw const FormatException('桥接 manifest 缺少故事板字段');
    final frames = ((storyboard['frames'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => BridgeFrameRecord.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
    final variants = ((storyboard['variants'] as List?) ?? const [])
        .map((item) => BridgeVariant.parse('$item'))
        .toList(growable: false);
    return BridgeManifest(
      bridgeId: '${json['bridge_id'] ?? ''}',
      direction: '${json['direction'] ?? ''}' == 'film-to-shiyin'
          ? BridgeDirection.filmToShiyin
          : BridgeDirection.shiyinToFilm,
      exportedAt:
          DateTime.tryParse('${json['exported_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      source: (json['source'] as Map?)?.cast<String, Object?>() ?? const {},
      canvas: (json['canvas'] as Map?)?.cast<String, Object?>() ?? const {},
      boardName: '${storyboard['board_name'] ?? ''}',
      selectedVariant: BridgeVariant.parse(
        '${storyboard['selected_variant'] ?? 'original'}',
      ),
      variants: variants,
      frames: frames,
      shots: const [],
      checksums:
          (json['checksums'] as Map?)?.map(
            (key, value) => MapEntry('$key', '$value'),
          ) ??
          const {},
    );
  }

  static String stableBridgeId(String projectId, String boardId) {
    final project = projectId.trim();
    final board = boardId.trim();
    if (project.isEmpty || board.isEmpty)
      throw ArgumentError('projectId 和 boardId 不能为空');
    return 'film:$project:$board';
  }

  static String stableFrameId(
    String boardId,
    int index,
    BridgeVariant variant,
  ) => 'frame:$boardId:${index.toString().padLeft(4, '0')}:${variant.wireName}';

  static String stableShotId(String boardId, int shotNumber) =>
      'shot:$boardId:$shotNumber';
}
