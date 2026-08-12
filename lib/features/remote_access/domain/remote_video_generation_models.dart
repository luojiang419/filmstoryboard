import 'package:flutter/foundation.dart';

class RemoteVideoGenerationScriptRecord {
  const RemoteVideoGenerationScriptRecord({
    required this.id,
    required this.name,
    required this.status,
    required this.version,
    required this.isSelected,
  });

  final String id;
  final String name;
  final String status;
  final int version;
  final bool isSelected;
}

class RemoteVideoGenerationModelRecord {
  const RemoteVideoGenerationModelRecord({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

class RemoteVideoGenerationParameterOption {
  const RemoteVideoGenerationParameterOption({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;
}

class RemoteVideoGenerationParameterRecord {
  const RemoteVideoGenerationParameterRecord({
    required this.key,
    required this.label,
    required this.component,
    required this.group,
    required this.value,
    required this.options,
    this.min,
    this.max,
    this.step,
  });

  final String key;
  final String label;
  final String component;
  final String group;
  final String value;
  final List<RemoteVideoGenerationParameterOption> options;
  final num? min;
  final num? max;
  final num? step;
}

class RemoteVideoGenerationOptionsRecord {
  const RemoteVideoGenerationOptionsRecord({
    required this.scripts,
    required this.selectedScriptId,
    required this.backendKind,
    required this.backendName,
    required this.backendReady,
    required this.backendMessage,
    required this.projectAspectRatio,
    required this.models,
    required this.selectedModelId,
    required this.parameters,
  });

  final List<RemoteVideoGenerationScriptRecord> scripts;
  final String selectedScriptId;
  final String backendKind;
  final String backendName;
  final bool backendReady;
  final String backendMessage;
  final String projectAspectRatio;
  final List<RemoteVideoGenerationModelRecord> models;
  final String selectedModelId;
  final List<RemoteVideoGenerationParameterRecord> parameters;
}

class RemoteVideoGenerationGroupRecord {
  const RemoteVideoGenerationGroupRecord({
    required this.id,
    required this.scriptId,
    required this.shotIds,
    required this.shotNumbers,
    required this.title,
    required this.durationSeconds,
    required this.prompt,
    required this.promptMode,
    required this.canGenerate,
    required this.isActive,
    required this.referenceImagePath,
  });

  final String id;
  final String scriptId;
  final List<String> shotIds;
  final List<int> shotNumbers;
  final String title;
  final double durationSeconds;
  final String prompt;
  final String promptMode;
  final bool canGenerate;
  final bool isActive;

  /// 仅用于注册当前工程媒体白名单，禁止直接序列化到远程响应。
  final String referenceImagePath;
}

class RemoteVideoGenerationTaskRecord {
  const RemoteVideoGenerationTaskRecord({
    required this.id,
    required this.scriptId,
    required this.shotId,
    required this.shotNumber,
    required this.model,
    required this.parameters,
    required this.durationSeconds,
    required this.promptMode,
    required this.prompt,
    required this.status,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.completedAt,
    required this.localPath,
    required this.hasLocalResult,
  });

  final String id;
  final String scriptId;
  final String shotId;
  final int shotNumber;
  final String model;
  final Map<String, String> parameters;
  final int durationSeconds;
  final String promptMode;
  final String prompt;
  final String status;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  /// 仅用于注册当前工程媒体白名单，禁止直接序列化到远程响应。
  final String localPath;
  final bool hasLocalResult;
}

class RemoteVideoGenerationShotOverride {
  const RemoteVideoGenerationShotOverride({
    this.prompt,
    this.promptMode,
    this.durationSeconds,
  });

  final String? prompt;
  final String? promptMode;
  final double? durationSeconds;
}

class RemoteVideoGenerationCommand {
  const RemoteVideoGenerationCommand({
    this.scriptId,
    this.shotIds = const [],
    this.model,
    this.parameters = const {},
    this.shotOverrides = const {},
  });

  final String? scriptId;
  final List<String> shotIds;
  final String? model;
  final Map<String, String> parameters;
  final Map<String, RemoteVideoGenerationShotOverride> shotOverrides;
}

class RemoteVideoGenerationOperationProgress {
  const RemoteVideoGenerationOperationProgress({
    required this.current,
    required this.total,
    required this.message,
  });

  final int current;
  final int total;
  final String message;
}

class RemoteVideoGenerationOperationResult {
  const RemoteVideoGenerationOperationResult({required this.tasks});

  final List<RemoteVideoGenerationTaskRecord> tasks;
}

class RemoteVideoGenerationSourceException implements Exception {
  const RemoteVideoGenerationSourceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

abstract interface class RemoteVideoGenerationSource implements Listenable {
  RemoteVideoGenerationOptionsRecord get options;

  List<RemoteVideoGenerationGroupRecord> get groups;

  List<RemoteVideoGenerationTaskRecord> get tasks;

  List<RemoteVideoGenerationTaskRecord> get works;

  void selectScript(String scriptId);

  RemoteVideoGenerationTaskRecord? taskById(String taskId);

  Future<RemoteVideoGenerationOperationResult> startGeneration(
    RemoteVideoGenerationCommand command, {
    required String operationId,
  });

  RemoteVideoGenerationOperationProgress operationProgress(String operationId);

  Future<bool> cancelOperation(String operationId);

  Future<RemoteVideoGenerationTaskRecord?> cancelTask(String taskId);
}
