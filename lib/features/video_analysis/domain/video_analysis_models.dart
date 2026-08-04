enum ProcessingStatus {
  pending,
  running,
  completed,
  partial,
  failed,
  retrying;

  static ProcessingStatus fromStorage(Object? value) {
    return ProcessingStatus.values.firstWhere(
      (item) => item.name == value,
      orElse: () => ProcessingStatus.failed,
    );
  }
}

const videoAnalysisDimensionGroups = <String, List<String>>{
  '开头与注意力': ['开场类型', '黄金3秒内容', '留存钩子', '首帧冲击点', '中途留存机制', '视觉刺激手段'],
  '内容结构与节奏': ['视频结构', '镜头节奏', '信息密度', '冲突/问题', '叙事推进', '结果兑现', '结尾记忆点'],
  '品牌与产品表达': [
    '品牌露出',
    '出现时间',
    '产品展示方式',
    '卖点表达',
    '卖点证据',
    '差异化记忆点',
    '使用场景',
    '包装/Logo/品牌资产',
  ],
  '视觉与听觉执行': [
    '场景',
    '画面风格',
    '构图与主体',
    '景别与机位',
    '运镜与转场',
    '色彩',
    '光线质感',
    '字幕/屏显信息',
    '声音与音乐',
    '竖屏安全区',
  ],
  '用户洞察与信任': ['目标受众', '用户痛点', '情绪触发', '购买理由', '信任证据', '异议/风险消除', '人物/创作者角色'],
  '转化设计': ['CTA', '福利', '价格/优惠', '紧迫感', '评论引导', '互动机制', '转化路径'],
  '传播、增长与风险': [
    '可分享话题',
    '可模仿/UGC机制',
    '社交货币',
    '品牌记忆资产',
    '多版本测试建议',
    '平台适配建议',
    '宣称/证明风险',
    '信息缺口',
  ],
};

final videoAnalysisDimensionFields = <String>[
  for (final group in videoAnalysisDimensionGroups.values) ...group,
];

class SourceVideo {
  const SourceVideo({
    required this.id,
    required this.originalPath,
    required this.fileName,
    required this.storedPath,
    required this.durationMs,
    required this.frameRate,
    required this.width,
    required this.height,
    required this.hasAudio,
    required this.frameCount,
    required this.successfulFrames,
    required this.failedFrames,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String originalPath;
  final String fileName;
  final String storedPath;
  final int durationMs;
  final double frameRate;
  final int width;
  final int height;
  final bool hasAudio;
  final int frameCount;
  final int successfulFrames;
  final int failedFrames;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  SourceVideo copyWith({
    String? storedPath,
    int? durationMs,
    double? frameRate,
    int? width,
    int? height,
    bool? hasAudio,
    int? frameCount,
    int? successfulFrames,
    int? failedFrames,
    ProcessingStatus? status,
    String? errorMessage,
    DateTime? updatedAt,
  }) => SourceVideo(
    id: id,
    originalPath: originalPath,
    fileName: fileName,
    storedPath: storedPath ?? this.storedPath,
    durationMs: durationMs ?? this.durationMs,
    frameRate: frameRate ?? this.frameRate,
    width: width ?? this.width,
    height: height ?? this.height,
    hasAudio: hasAudio ?? this.hasAudio,
    frameCount: frameCount ?? this.frameCount,
    successfulFrames: successfulFrames ?? this.successfulFrames,
    failedFrames: failedFrames ?? this.failedFrames,
    status: status ?? this.status,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class VideoFrame {
  const VideoFrame({
    required this.id,
    required this.videoId,
    required this.index,
    required this.timestampMs,
    required this.path,
    required this.width,
    required this.height,
    required this.sharpness,
    required this.brightness,
    required this.motionScore,
    required this.perceptualHash,
    required this.isFocus,
    required this.isSelected,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
  });

  final String id;
  final String videoId;
  final int index;
  final int timestampMs;
  final String path;
  final int width;
  final int height;
  final double sharpness;
  final double brightness;
  final double motionScore;
  final String perceptualHash;
  final bool isFocus;
  final bool isSelected;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;

  VideoFrame copyWith({
    double? sharpness,
    double? brightness,
    double? motionScore,
    String? perceptualHash,
    bool? isFocus,
    bool? isSelected,
    ProcessingStatus? status,
    String? errorMessage,
  }) => VideoFrame(
    id: id,
    videoId: videoId,
    index: index,
    timestampMs: timestampMs,
    path: path,
    width: width,
    height: height,
    sharpness: sharpness ?? this.sharpness,
    brightness: brightness ?? this.brightness,
    motionScore: motionScore ?? this.motionScore,
    perceptualHash: perceptualHash ?? this.perceptualHash,
    isFocus: isFocus ?? this.isFocus,
    isSelected: isSelected ?? this.isSelected,
    status: status ?? this.status,
    errorMessage: errorMessage ?? this.errorMessage,
    createdAt: createdAt,
  );
}

class VideoShot {
  const VideoShot({
    required this.id,
    required this.videoId,
    required this.shotNumber,
    required this.startMs,
    required this.endMs,
    required this.primaryFrameId,
    required this.frameIds,
    required this.description,
    required this.storyFlow,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String videoId;
  final int shotNumber;
  final int startMs;
  final int endMs;
  final String? primaryFrameId;
  final List<String> frameIds;
  final String description;
  final String storyFlow;
  final ProcessingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class MarketingAnalysis {
  const MarketingAnalysis({
    required this.id,
    required this.videoId,
    required this.scope,
    required this.dimensions,
    required this.rawResponse,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String videoId;
  final String scope;
  final Map<String, String> dimensions;
  final String rawResponse;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class VideoFrameAnalysis {
  const VideoFrameAnalysis({
    required this.id,
    required this.videoId,
    required this.frameId,
    required this.sequenceNo,
    required this.dimensions,
    required this.rawResponse,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String videoId;
  final String frameId;
  final int sequenceNo;
  final Map<String, String> dimensions;
  final String rawResponse;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class VideoSummary {
  const VideoSummary({
    required this.id,
    required this.videoId,
    required this.fields,
    required this.rawResponse,
    required this.status,
    required this.errorMessage,
    required this.updatedAt,
  });

  final String id;
  final String videoId;
  final Map<String, String> fields;
  final String rawResponse;
  final ProcessingStatus status;
  final String errorMessage;
  final DateTime updatedAt;
}
