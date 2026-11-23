import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../remote_access/domain/remote_video_generation_models.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../data/kling_cli_models.dart';
import '../data/libtv_cli_models.dart';
import '../domain/video_generation_models.dart';
import 'video_generation_controller.dart';

class VideoGenerationRemoteSource extends ChangeNotifier
    implements RemoteVideoGenerationSource {
  VideoGenerationRemoteSource(this._controller) {
    _controller.addListener(_handleControllerChanged);
  }

  final VideoGenerationController _controller;
  final Map<String, _RemoteGenerationOperation> _operations = {};
  final Set<String> _cancelledOperationIds = {};
  final Set<String> _cancellingTaskIds = {};
  bool _disposed = false;

  @override
  RemoteVideoGenerationOptionsRecord get options {
    final state = _controller.value;
    final config = _controller.activeVideoGenerationApiConfig;
    final backendKind = config?.kind.name ?? 'klingCli';
    final backendReady = config?.isHttpApi == true
        ? config!.baseUrl.trim().isNotEmpty
        : config?.isLibTvCli == true
        ? state.libTvEnvironment?.isReady == true &&
              state.libTvAccount != null &&
              state.libTvModel != null
        : state.environment?.isReady == true && state.identity != null;
    return RemoteVideoGenerationOptionsRecord(
      scripts: [
        for (final script in state.scripts)
          RemoteVideoGenerationScriptRecord(
            id: script.id,
            name: script.name,
            status: script.status.name,
            version: script.version,
            isSelected: script.id == state.selectedScriptId,
          ),
      ],
      selectedScriptId: state.selectedScriptId,
      backendKind: backendKind,
      backendName: _controller.activeVideoBackendName,
      backendReady: backendReady,
      backendMessage: state.errorMessage.isNotEmpty
          ? state.errorMessage
          : backendReady
          ? '本机视频生成服务已就绪'
          : '请先在桌面端完成视频模型配置或登录',
      projectAspectRatio: _controller.projectAspectRatioLabel,
      models: _models,
      selectedModelId: _selectedModelId,
      parameters: _parameters,
    );
  }

  @override
  List<RemoteVideoGenerationGroupRecord> get groups {
    final state = _controller.value;
    final records = <RemoteVideoGenerationGroupRecord>[];
    final seen = <String>{};
    for (final shot in state.shots) {
      final sequence = _controller.actionSequenceFor(shot);
      final owner = sequence.head;
      if (!seen.add(owner.id)) continue;
      final draft = state.drafts[owner.id];
      final image = _controller.generationReferenceImageFileFor(owner);
      records.add(
        RemoteVideoGenerationGroupRecord(
          id: owner.id,
          scriptId: owner.scriptId,
          shotIds: [for (final item in sequence.shots) item.id],
          shotNumbers: [for (final item in sequence.shots) item.shotNumber],
          title: sequence.shots.length == 1
              ? '镜头 ${owner.shotNumber}'
              : '镜头 ${sequence.head.shotNumber}-${sequence.tail.shotNumber}',
          durationSeconds: _controller.desiredDurationFor(owner),
          prompt: draft?.selectedPrompt ?? '',
          promptMode: draft?.promptMode.name ?? '',
          canGenerate: _controller.canGenerateShot(owner),
          isActive: _controller.isGenerationActiveFor(owner),
          referenceImagePath: image?.path ?? '',
        ),
      );
    }
    return List.unmodifiable(records);
  }

  @override
  List<RemoteVideoGenerationTaskRecord> get tasks =>
      _controller.projectTasks.map(_taskRecord).toList(growable: false);

  @override
  List<RemoteVideoGenerationTaskRecord> get works => _controller.projectTasks
      .where(
        (task) =>
            (task.status == VideoGenerationTaskStatus.completed ||
                task.status == VideoGenerationTaskStatus.partialCompleted) &&
            _controller.generatedVideoFileFor(task).existsSync(),
      )
      .map(_taskRecord)
      .toList(growable: false);

  @override
  void selectScript(String scriptId) {
    final normalized = scriptId.trim();
    if (!_controller.value.scripts.any((script) => script.id == normalized)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_script_not_found',
        '拍摄脚本不存在',
      );
    }
    _controller.selectScript(normalized);
  }

  @override
  RemoteVideoGenerationTaskRecord? taskById(String taskId) {
    for (final task in _controller.projectTasks) {
      if (task.id == taskId) return _taskRecord(task);
    }
    return null;
  }

  @override
  Future<RemoteVideoGenerationOperationResult> startGeneration(
    RemoteVideoGenerationCommand command, {
    required String operationId,
  }) async {
    final normalizedOperationId = operationId.trim();
    if (normalizedOperationId.isEmpty) {
      throw const RemoteVideoGenerationSourceException(
        'invalid_generation_request',
        '生成操作标识不能为空',
      );
    }
    if (_cancelledOperationIds.contains(normalizedOperationId)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_cancelled',
        '视频生成任务已取消',
      );
    }
    if (command.scriptId?.trim().isNotEmpty == true) {
      selectScript(command.scriptId!);
    }
    if (_controller.value.selectedScript == null) {
      throw const RemoteVideoGenerationSourceException(
        'generation_script_required',
        '请先选择拍摄脚本',
      );
    }
    final currentOptions = options;
    if (!currentOptions.backendReady) {
      throw RemoteVideoGenerationSourceException(
        'generation_backend_unavailable',
        currentOptions.backendMessage,
      );
    }
    await _applyModel(command.model);
    _applyParameters(command.parameters);
    _applyShotOverrides(command.shotOverrides);
    final targets = _resolveTargets(command.shotIds);
    if (targets.isEmpty) {
      throw RemoteVideoGenerationSourceException(
        'generation_target_unavailable',
        _controller.value.errorMessage.isEmpty
            ? '没有具备首帧图和提示词的可生成镜头'
            : _controller.value.errorMessage,
      );
    }
    final baselineTaskIds = _controller.projectTasks
        .map((task) => task.id)
        .toSet();
    final operation = _RemoteGenerationOperation(
      targetShotIds: targets.map((shot) => shot.id).toSet(),
      baselineTaskIds: baselineTaskIds,
    );
    _operations[normalizedOperationId] = operation;
    try {
      if (_cancelledOperationIds.contains(normalizedOperationId)) {
        throw const RemoteVideoGenerationSourceException(
          'generation_cancelled',
          '视频生成任务已取消',
        );
      }
      await _controller.generateSelection(targets);
      final created = _createdTasks(operation).map(_taskRecord).toList();
      if (created.isEmpty) {
        throw RemoteVideoGenerationSourceException(
          'generation_not_started',
          _controller.value.errorMessage.isEmpty
              ? '本机没有创建视频生成任务'
              : _controller.value.errorMessage,
        );
      }
      return RemoteVideoGenerationOperationResult(
        tasks: List.unmodifiable(created),
      );
    } finally {
      _operations.remove(normalizedOperationId);
      _cancelledOperationIds.remove(normalizedOperationId);
    }
  }

  @override
  RemoteVideoGenerationOperationProgress operationProgress(String operationId) {
    final operation = _operations[operationId];
    if (operation == null) {
      return RemoteVideoGenerationOperationProgress(
        current: 0,
        total: 0,
        message: _controller.value.message,
      );
    }
    final created = _createdTasks(operation);
    final completed = created.where((task) => task.status.isTerminal).length;
    return RemoteVideoGenerationOperationProgress(
      current: completed,
      total: created.length > operation.targetShotIds.length
          ? created.length
          : operation.targetShotIds.length,
      message: _controller.value.message.isEmpty
          ? '正在执行本机视频生成任务'
          : _controller.value.message,
    );
  }

  @override
  Future<bool> cancelOperation(String operationId) async {
    final normalized = operationId.trim();
    if (normalized.isEmpty) return false;
    _cancelledOperationIds.add(normalized);
    final operation = _operations[normalized];
    if (operation != null) await _cancelCreatedTasks(operation);
    return true;
  }

  @override
  Future<RemoteVideoGenerationTaskRecord?> cancelTask(String taskId) async {
    final task = _controller.projectTasks
        .where((item) => item.id == taskId)
        .firstOrNull;
    if (task == null) return null;
    await _controller.cancelTask(task);
    final updated = _controller.projectTasks
        .where((item) => item.id == taskId)
        .firstOrNull;
    return updated == null ? null : _taskRecord(updated);
  }

  List<RemoteVideoGenerationModelRecord> get _models {
    if (_controller.usesLibTvCli) {
      return [
        for (final model in _controller.libTvModels)
          RemoteVideoGenerationModelRecord(
            id: model.modelKey,
            name: model.modelName,
          ),
      ];
    }
    if (_isHttpBackend) {
      final model = _controller.activeVideoGenerationApiModel;
      return [RemoteVideoGenerationModelRecord(id: model, name: model)];
    }
    return [
      for (final model
          in _controller.value.identity?.imageToVideoModels ??
              const <KlingModelSpec>[])
        RemoteVideoGenerationModelRecord(id: model.model, name: model.alias),
    ];
  }

  String get _selectedModelId => _controller.usesLibTvCli
      ? _controller.selectedLibTvModelKey
      : _isHttpBackend
      ? _controller.activeVideoGenerationApiModel
      : _controller.value.profile?.model ?? '';

  List<RemoteVideoGenerationParameterRecord> get _parameters {
    if (_isHttpBackend) {
      return [
        RemoteVideoGenerationParameterRecord(
          key: 'aspectRatio',
          label: '生成比例',
          component: 'select',
          group: 'basic',
          value: _controller.selectedVideoApiAspectRatio,
          options: _plainOptions(_controller.videoApiAspectRatios),
        ),
        RemoteVideoGenerationParameterRecord(
          key: 'resolution',
          label: '分辨率',
          component: 'select',
          group: 'basic',
          value: _controller.selectedVideoApiResolution,
          options: _plainOptions(
            _controller.videoApiResolutionsForAspect(
              _controller.selectedVideoApiAspectRatio,
            ),
          ),
        ),
        RemoteVideoGenerationParameterRecord(
          key: 'steps',
          label: '生成步数',
          component: 'number',
          group: 'advanced',
          value: '${_controller.selectedVideoApiSteps}',
          options: const [],
          min: 4,
          max: 30,
          step: 1,
        ),
      ];
    }
    if (_controller.usesLibTvCli) {
      return [
        RemoteVideoGenerationParameterRecord(
          key: 'modeType',
          label: '生成模式',
          component: 'select',
          group: 'basic',
          value: _controller.selectedLibTvModeType,
          options: [
            for (final mode in _controller.libTvModeTypes)
              RemoteVideoGenerationParameterOption(
                value: mode,
                label: _controller.libTvModeTypeLabel(mode),
              ),
          ],
        ),
        RemoteVideoGenerationParameterRecord(
          key: 'count',
          label: '每镜头生成数量',
          component: 'select',
          group: 'basic',
          value: _controller.selectedLibTvCount,
          options: [
            for (final option in _controller.libTvCountOptions)
              RemoteVideoGenerationParameterOption(
                value: option.value,
                label: option.label,
              ),
          ],
        ),
        for (final parameter in _controller.libTvParameterSpecs)
          if (parameter.key != 'modeType' && parameter.key != 'count')
            RemoteVideoGenerationParameterRecord(
              key: parameter.key,
              label: parameter.displayName,
              component: parameter.component.isEmpty
                  ? parameter.options.isEmpty
                        ? 'text'
                        : 'select'
                  : parameter.component,
              group: parameter.group.name,
              value: _controller.selectedLibTvParameterValue(parameter),
              options: [
                for (final option in parameter.options)
                  RemoteVideoGenerationParameterOption(
                    value: option.value,
                    label: option.label,
                  ),
              ],
              min: parameter.min,
              max: parameter.max,
              step: parameter.step,
            ),
      ];
    }
    final profile = _controller.value.profile;
    final model = _controller.value.identity?.imageToVideoModels
        .where((item) => item.model == profile?.model)
        .firstOrNull;
    if (model == null) return const [];
    return [
      for (final argument in model.arguments)
        RemoteVideoGenerationParameterRecord(
          key: argument.name,
          label: argument.name,
          component: argument.allowedValues.isEmpty ? 'text' : 'select',
          group: 'basic',
          value: profile?.parameters[argument.name] ?? argument.defaultValue,
          options: _plainOptions(argument.allowedValues),
        ),
    ];
  }

  Future<void> _applyModel(String? modelId) async {
    final normalized = modelId?.trim() ?? '';
    if (normalized.isEmpty) return;
    if (_controller.usesLibTvCli) {
      if (!_controller.libTvModels.any(
        (model) => model.modelKey == normalized,
      )) {
        throw const RemoteVideoGenerationSourceException(
          'generation_model_not_found',
          '所选 LibTV 视频模型不存在',
        );
      }
      await _controller.selectLibTvModel(normalized);
      if (_controller.selectedLibTvModelKey != normalized) {
        throw RemoteVideoGenerationSourceException(
          'generation_model_unavailable',
          _controller.value.errorMessage.isEmpty
              ? '无法切换所选 LibTV 视频模型'
              : _controller.value.errorMessage,
        );
      }
      return;
    }
    if (_isHttpBackend) {
      if (normalized != _controller.activeVideoGenerationApiModel) {
        throw const RemoteVideoGenerationSourceException(
          'generation_model_not_found',
          'HTTP 视频模型由桌面端配置，远程请求不能切换到未知模型',
        );
      }
      return;
    }
    if (!_models.any((model) => model.id == normalized)) {
      throw const RemoteVideoGenerationSourceException(
        'generation_model_not_found',
        '所选可灵视频模型不存在',
      );
    }
    _controller.selectModel(normalized);
  }

  void _applyParameters(Map<String, String> parameters) {
    if (parameters.isEmpty) return;
    if (_isHttpBackend) {
      const allowed = {'aspectRatio', 'resolution', 'steps'};
      _rejectUnknownParameters(parameters, allowed);
      final aspectRatio = parameters['aspectRatio'];
      if (aspectRatio != null) {
        if (!_controller.videoApiAspectRatios.contains(aspectRatio)) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '视频生成比例无效',
          );
        }
        _controller.updateVideoApiAspectRatio(aspectRatio);
      }
      final resolution = parameters['resolution'];
      if (resolution != null) {
        final allowedResolutions = _controller.videoApiResolutionsForAspect(
          _controller.selectedVideoApiAspectRatio,
        );
        if (!allowedResolutions.contains(resolution)) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '视频生成分辨率与当前比例不匹配',
          );
        }
        _controller.updateVideoApiResolution(resolution);
      }
      final steps = parameters['steps'];
      if (steps != null) {
        final parsed = int.tryParse(steps);
        if (parsed == null || parsed < 4 || parsed > 30) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '视频生成步数必须在 4 到 30 之间',
          );
        }
        _controller.updateVideoApiSteps(parsed);
      }
      return;
    }
    if (_controller.usesLibTvCli) {
      final modeType = parameters['modeType'];
      if (modeType != null) {
        if (!_controller.libTvModeTypes.contains(modeType)) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            'LibTV 生成模式无效',
          );
        }
        _controller.updateLibTvModeType(modeType);
      }
      final specs = {
        for (final spec in _controller.libTvParameterSpecs) spec.key: spec,
      };
      _rejectUnknownParameters(parameters, {
        'modeType',
        'count',
        ...specs.keys,
      });
      final count = parameters['count'];
      if (count != null) {
        if (!_controller.libTvCountOptions.any(
          (option) => option.value == count,
        )) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            'LibTV 生成数量无效',
          );
        }
        _controller.updateLibTvCount(count);
      }
      for (final entry in parameters.entries) {
        final spec = specs[entry.key];
        if (spec == null) continue;
        if (!_validLibTvValue(spec, entry.value)) {
          throw RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '${spec.displayName} 参数值无效',
          );
        }
        _controller.updateLibTvParameter(spec, entry.value);
      }
      return;
    }
    final model = _controller.value.identity?.imageToVideoModels
        .where((item) => item.model == _controller.value.profile?.model)
        .firstOrNull;
    if (model == null) {
      throw const RemoteVideoGenerationSourceException(
        'generation_model_unavailable',
        '请先在桌面端登录并选择可灵视频模型',
      );
    }
    final arguments = {for (final item in model.arguments) item.name: item};
    _rejectUnknownParameters(parameters, arguments.keys.toSet());
    for (final entry in parameters.entries) {
      final argument = arguments[entry.key]!;
      if (argument.allowedValues.isNotEmpty &&
          !argument.allowedValues.contains(entry.value)) {
        throw RemoteVideoGenerationSourceException(
          'invalid_generation_parameter',
          '${argument.name} 参数值无效',
        );
      }
      _controller.updateParameter(entry.key, entry.value);
    }
  }

  void _applyShotOverrides(
    Map<String, RemoteVideoGenerationShotOverride> overrides,
  ) {
    for (final entry in overrides.entries) {
      final shot = _controller.value.shots
          .where((item) => item.id == entry.key)
          .firstOrNull;
      if (shot == null) {
        throw const RemoteVideoGenerationSourceException(
          'generation_shot_not_found',
          '镜头不存在或不属于当前拍摄脚本',
        );
      }
      final owner = _controller.generationOwnerFor(shot);
      final override = entry.value;
      final prompt = override.prompt?.trim();
      final mode = override.promptMode == null
          ? null
          : VideoPromptMode.values
                .where((item) => item.name == override.promptMode)
                .firstOrNull;
      if (override.promptMode != null && mode == null) {
        throw const RemoteVideoGenerationSourceException(
          'invalid_generation_parameter',
          '镜头提示词模式无效',
        );
      }
      if (prompt != null) {
        if (prompt.isEmpty ||
            (mode != null && mode != VideoPromptMode.edited)) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '自定义提示词不能为空，且提示词模式必须为 edited',
          );
        }
        _controller.updateEditedPrompt(owner.id, prompt);
      }
      if (mode != null) {
        final draft = _controller.value.drafts[owner.id];
        if (mode == VideoPromptMode.edited &&
            (draft?.editedPrompt.trim().isEmpty ?? true)) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            'edited 模式必须提供非空自定义提示词',
          );
        }
        _controller.updatePromptMode(owner.id, mode);
      }
      final duration = override.durationSeconds;
      if (duration != null) {
        if (!duration.isFinite || duration <= 0) {
          throw const RemoteVideoGenerationSourceException(
            'invalid_generation_parameter',
            '镜头时长必须是大于 0 的数字',
          );
        }
        _controller.updateDesiredDurationFor(owner, duration);
      }
    }
  }

  List<ScriptShot> _resolveTargets(List<String> requestedShotIds) {
    if (requestedShotIds.isEmpty) {
      return _controller.generationTargets();
    }
    final targets = <String, ScriptShot>{};
    for (final requestedId in requestedShotIds) {
      final shot = _controller.value.shots
          .where((item) => item.id == requestedId)
          .firstOrNull;
      if (shot == null) {
        throw const RemoteVideoGenerationSourceException(
          'generation_shot_not_found',
          '镜头不存在或不属于当前拍摄脚本',
        );
      }
      final owner = _controller.generationOwnerFor(shot);
      if (!_controller.canGenerateShot(owner)) {
        throw RemoteVideoGenerationSourceException(
          'generation_target_unavailable',
          '镜头 ${owner.shotNumber} 缺少可用首帧图或参考素材',
        );
      }
      if (_controller.isGenerationActiveFor(owner)) {
        throw RemoteVideoGenerationSourceException(
          'generation_already_running',
          '镜头 ${owner.shotNumber} 已有正在运行的生成任务',
        );
      }
      targets[owner.id] = owner;
    }
    return targets.values.toList(growable: false);
  }

  RemoteVideoGenerationTaskRecord _taskRecord(VideoGenerationTask task) {
    final shot = _controller.value.shots
        .where((item) => item.id == task.shotId)
        .firstOrNull;
    final file = _controller.generatedVideoFileFor(task);
    return RemoteVideoGenerationTaskRecord(
      id: task.id,
      scriptId: task.scriptId,
      shotId: task.shotId,
      shotNumber: shot?.shotNumber ?? 0,
      model: task.model,
      parameters: Map.unmodifiable(task.parameters),
      durationSeconds: task.durationSeconds,
      promptMode: task.promptMode.name,
      prompt: task.prompt,
      status: task.status.name,
      errorMessage: task.errorMessage,
      createdAt: task.createdAt,
      updatedAt: task.updatedAt,
      completedAt: task.completedAt,
      localPath: file.path,
      hasLocalResult: file.existsSync(),
    );
  }

  List<VideoGenerationTask> _createdTasks(
    _RemoteGenerationOperation operation,
  ) => _controller.projectTasks
      .where(
        (task) =>
            !operation.baselineTaskIds.contains(task.id) &&
            operation.targetShotIds.contains(task.shotId),
      )
      .toList(growable: false);

  Future<void> _cancelCreatedTasks(_RemoteGenerationOperation operation) async {
    for (final task in _createdTasks(operation)) {
      if (task.status.isTerminal || !_cancellingTaskIds.add(task.id)) continue;
      try {
        await _controller.cancelTask(task);
      } finally {
        _cancellingTaskIds.remove(task.id);
      }
    }
  }

  void _handleControllerChanged() {
    if (_disposed) return;
    for (final entry in _operations.entries) {
      if (_cancelledOperationIds.contains(entry.key)) {
        unawaited(_cancelCreatedTasks(entry.value));
      }
    }
    notifyListeners();
  }

  bool get _isHttpBackend =>
      _controller.activeVideoGenerationApiConfig?.isHttpApi == true;

  static void _rejectUnknownParameters(
    Map<String, String> parameters,
    Set<String> allowed,
  ) {
    final unknown = parameters.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty) {
      throw RemoteVideoGenerationSourceException(
        'invalid_generation_parameter',
        '不支持的视频生成参数：${unknown.join('、')}',
      );
    }
  }

  static bool _validLibTvValue(
    LibTvModelParameterSpec parameter,
    String value,
  ) {
    if (value.trim().isEmpty) return false;
    if (parameter.options.isNotEmpty) {
      return parameter.options.any((option) => option.value == value);
    }
    if (!parameter.hasNumericRange) return true;
    final number = num.tryParse(value);
    return number != null &&
        number >= parameter.min! &&
        number <= parameter.max!;
  }

  static List<RemoteVideoGenerationParameterOption> _plainOptions(
    Iterable<String> values,
  ) => [
    for (final value in values)
      RemoteVideoGenerationParameterOption(value: value, label: value),
  ];

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }
}

class _RemoteGenerationOperation {
  const _RemoteGenerationOperation({
    required this.targetShotIds,
    required this.baselineTaskIds,
  });

  final Set<String> targetShotIds;
  final Set<String> baselineTaskIds;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
