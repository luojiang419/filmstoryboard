class LibTvCliEnvironment {
  const LibTvCliEnvironment({
    required this.executablePath,
    required this.version,
    required this.errorMessage,
  });

  final String executablePath;
  final String version;
  final String errorMessage;

  bool get isReady => errorMessage.isEmpty;
}

class LibTvAccountInfo {
  const LibTvAccountInfo({
    required this.userId,
    required this.nickname,
    required this.accountName,
    required this.teamId,
  });

  final String userId;
  final String nickname;
  final String accountName;
  final int teamId;
}

class LibTvModelSpec {
  const LibTvModelSpec({
    required this.modelName,
    required this.modelKey,
    required this.modality,
    required this.schema,
  });

  final String modelName;
  final String modelKey;
  final String modality;
  final Map<String, Object?> schema;
}

class LibTvGenerationResult {
  const LibTvGenerationResult({
    required this.projectUuid,
    required this.nodeKey,
    required this.taskId,
    required this.videoUrl,
    required this.rawJson,
  });

  final String projectUuid;
  final String nodeKey;
  final String taskId;
  final String videoUrl;
  final Map<String, Object?> rawJson;
}

class LibTvCliException implements Exception {
  const LibTvCliException(this.message, {this.exitCode, this.rawOutput = ''});

  final String message;
  final int? exitCode;
  final String rawOutput;

  @override
  String toString() => message;
}

class LibTvGenerationCanceledException extends LibTvCliException {
  const LibTvGenerationCanceledException() : super('已取消 LibTV 视频生成。');
}
