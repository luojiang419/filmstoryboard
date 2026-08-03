import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/script_multimodal_analysis_service.dart';
import '../data/shooting_script_workflow_repository.dart';
import '../domain/shooting_script_models.dart';
import '../domain/shooting_script_workflow_models.dart';
import 'shooting_script_controller.dart';

final scriptAnalysisControllerProvider =
    Provider<ShootingScriptAnalysisController>(
      (ref) {
        final controller = ShootingScriptAnalysisController(
          shootingScriptController: ref.watch(shootingScriptControllerProvider),
          repository: ShootingScriptWorkflowRepository(
            ref.watch(appDatabaseProvider),
          ),
          settingsController: ref.watch(settingsControllerProvider),
        );
        ref.onDispose(controller.dispose);
        return controller;
      },
      dependencies: [
        appDatabaseProvider,
        settingsControllerProvider,
        shootingScriptControllerProvider,
      ],
    );

class ScriptAnalysisState {
  const ScriptAnalysisState({
    this.scriptId = '',
    this.analyses = const [],
    this.isBusy = false,
    this.completedCount = 0,
    this.failedCount = 0,
    this.totalCount = 0,
    this.message = '',
    this.errorMessage = '',
  });

  final String scriptId;
  final List<ScriptShotAnalysisRecord> analyses;
  final bool isBusy;
  final int completedCount;
  final int failedCount;
  final int totalCount;
  final String message;
  final String errorMessage;

  ScriptAnalysisState copyWith({
    String? scriptId,
    List<ScriptShotAnalysisRecord>? analyses,
    bool? isBusy,
    int? completedCount,
    int? failedCount,
    int? totalCount,
    String? message,
    String? errorMessage,
  }) => ScriptAnalysisState(
    scriptId: scriptId ?? this.scriptId,
    analyses: analyses ?? this.analyses,
    isBusy: isBusy ?? this.isBusy,
    completedCount: completedCount ?? this.completedCount,
    failedCount: failedCount ?? this.failedCount,
    totalCount: totalCount ?? this.totalCount,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  ScriptShotAnalysisRecord? forShot(String shotId) {
    for (final item in analyses) {
      if (item.shotId == shotId) return item;
    }
    return null;
  }
}

class ShootingScriptAnalysisController
    extends ValueNotifier<ScriptAnalysisState> {
  ShootingScriptAnalysisController({
    required ShootingScriptController shootingScriptController,
    required ShootingScriptWorkflowRepository repository,
    required SettingsController settingsController,
    ScriptMultimodalAnalysisService? analysisService,
    Uuid uuid = const Uuid(),
  }) : _shootingScriptController = shootingScriptController,
       _repository = repository,
       _settingsController = settingsController,
       _analysisService = analysisService ?? ScriptMultimodalAnalysisService(),
       _ownsAnalysisService = analysisService == null,
       _uuid = uuid,
       super(const ScriptAnalysisState()) {
    _shootingScriptController.addListener(_handleScriptChanged);
    refresh();
  }

  final ShootingScriptController _shootingScriptController;
  final ShootingScriptWorkflowRepository _repository;
  final SettingsController _settingsController;
  final ScriptMultimodalAnalysisService _analysisService;
  final bool _ownsAnalysisService;
  final Uuid _uuid;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleScriptChanged);
    if (_ownsAnalysisService) {
      _analysisService.close();
    }
    super.dispose();
  }

  void refresh({bool preserveBusy = false}) {
    final script = _shootingScriptController.value.selectedScript;
    if (script == null) {
      value = const ScriptAnalysisState();
      return;
    }
    final analyses = _repository.listAnalyses(script.id);
    final wasBusy = value.isBusy;
    value = value.copyWith(
      scriptId: script.id,
      analyses: analyses,
      totalCount: _shootingScriptController.value.shots.length,
      completedCount: analyses
          .where((item) => item.status == ProcessingStatus.completed)
          .length,
      failedCount: analyses
          .where((item) => item.status == ProcessingStatus.failed)
          .length,
      isBusy: preserveBusy ? wasBusy : false,
    );
  }

  Future<void> analyzeAll({bool overwriteExisting = false}) async {
    final script = _shootingScriptController.value.selectedScript;
    final shots = _shootingScriptController.value.shots;
    if (script == null || shots.isEmpty) {
      value = value.copyWith(message: '', errorMessage: '当前脚本没有可解析的镜头');
      return;
    }
    value = value.copyWith(
      scriptId: script.id,
      analyses: const [],
      isBusy: true,
      completedCount: 0,
      failedCount: 0,
      totalCount: shots.length,
      message: '正在解析 0/${shots.length} 个镜头…',
      errorMessage: '',
    );
    for (var index = 0; index < shots.length; index++) {
      if (_disposed) return;
      await _analyzeOne(
        scriptId: script.id,
        shot: shots[index],
        overwriteExisting: overwriteExisting,
      );
      if (!_disposed) {
        value = value.copyWith(
          message: '正在解析 ${index + 1}/${shots.length} 个镜头…',
        );
      }
    }
    final failed = value.failedCount;
    if (!_disposed) {
      value = value.copyWith(
        isBusy: false,
        message: failed == 0 ? '脚本自动解析完成' : '解析完成，但有 $failed 个镜头失败',
        errorMessage: failed == 0 ? '' : '$failed 个镜头解析失败',
      );
    }
  }

  Future<void> analyzeShot(
    String shotId, {
    bool overwriteExisting = false,
  }) async {
    final script = _shootingScriptController.value.selectedScript;
    final shot = _shootingScriptController.value.shots
        .where((item) => item.id == shotId)
        .firstOrNull;
    if (script == null || shot == null) return;
    value = value.copyWith(
      isBusy: true,
      message: '正在解析镜头 ${shot.shotNumber}…',
      errorMessage: '',
    );
    await _analyzeOne(
      scriptId: script.id,
      shot: shot,
      overwriteExisting: overwriteExisting,
    );
    if (!_disposed) {
      value = value.copyWith(
        isBusy: false,
        message: '镜头 ${shot.shotNumber} 解析完成',
      );
    }
  }

  void cancel() {
    _analysisService.cancelActiveRequests();
    value = value.copyWith(isBusy: false, message: '已取消自动解析');
  }

  Future<void> _analyzeOne({
    required String scriptId,
    required ScriptShot shot,
    required bool overwriteExisting,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = _repository.getAnalysis(shot.id);
    final imagePath = shot.framePath.trim();
    if (imagePath.isEmpty || !File(imagePath).existsSync()) {
      _saveFailure(
        shot: shot,
        existing: existing,
        message: '缺少镜头画面，无法执行多模态解析',
        now: now,
      );
      return;
    }
    try {
      final patch = await _analysisService.analyzeShot(
        settings: _settingsController.value,
        shot: shot,
        imageFile: File(imagePath),
      );
      final updatedShot = _applyPatch(
        shot,
        patch.values,
        overwriteExisting: overwriteExisting,
      );
      _shootingScriptController.updateShot(updatedShot);
      final sources = <String, String>{
        for (final field in _analysisFields)
          field: _sourceForField(
            field: field,
            original: shot,
            updated: updatedShot,
            patch: patch,
            overwriteExisting: overwriteExisting,
          ),
      };
      _repository.upsertAnalysis(
        ScriptShotAnalysisRecord(
          id: existing?.id ?? _uuid.v4(),
          shotId: shot.id,
          model: _settingsController.value.visionModel,
          status: ProcessingStatus.completed,
          fieldSources: sources,
          fieldConfidence: patch.fieldConfidence,
          rawResponse: patch.rawResponse,
          errorMessage: '',
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      _refreshProgress(scriptId);
    } catch (error) {
      _saveFailure(shot: shot, existing: existing, message: '$error', now: now);
    }
  }

  void _saveFailure({
    required ScriptShot shot,
    required ScriptShotAnalysisRecord? existing,
    required String message,
    required DateTime now,
  }) {
    _repository.upsertAnalysis(
      ScriptShotAnalysisRecord(
        id: existing?.id ?? _uuid.v4(),
        shotId: shot.id,
        model: _settingsController.value.visionModel,
        status: ProcessingStatus.failed,
        fieldSources: const {},
        fieldConfidence: const {},
        rawResponse: '',
        errorMessage: message,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    _refreshProgress(shot.scriptId);
  }

  void _refreshProgress(String scriptId) {
    final analyses = _repository.listAnalyses(scriptId);
    final completed = analyses
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    final failed = analyses
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    if (!_disposed) {
      value = value.copyWith(
        scriptId: scriptId,
        analyses: analyses,
        completedCount: completed,
        failedCount: failed,
      );
    }
  }

  void _handleScriptChanged() {
    if (!_disposed) refresh(preserveBusy: true);
  }

  static const _analysisFields = [
    'visual',
    'content',
    'shotSize',
    'cameraMovement',
    'composition',
    'cameraAngle',
    'lightingMood',
    'colorPalette',
    'visualFocus',
    'transitionHint',
    'cameraNotes',
    'scene',
    'productCode',
    'productStyling',
    'dialogue',
    'sound',
  ];

  static String _sourceForField({
    required String field,
    required ScriptShot original,
    required ScriptShot updated,
    required ScriptShotAnalysisPatch patch,
    required bool overwriteExisting,
  }) {
    final originalValue = _fieldValue(original, field).trim();
    final updatedValue = _fieldValue(updated, field).trim();
    final modelValueApplied =
        patch.values.containsKey(field) &&
        (overwriteExisting || originalValue.isEmpty);
    if (modelValueApplied) return 'model';
    if (originalValue.isNotEmpty && updatedValue.isNotEmpty) return 'preserved';
    return 'unavailable';
  }

  static ScriptShot _applyPatch(
    ScriptShot shot,
    Map<String, String> values, {
    required bool overwriteExisting,
  }) {
    var updated = shot;
    for (final entry in values.entries) {
      final current = _fieldValue(updated, entry.key);
      if (!overwriteExisting && current.trim().isNotEmpty) continue;
      updated = _copyField(updated, entry.key, entry.value);
    }
    return updated;
  }

  static String _fieldValue(ScriptShot shot, String field) => switch (field) {
    'visual' => shot.visual,
    'content' => shot.content,
    'shotSize' => shot.shotSize,
    'cameraMovement' => shot.cameraMovement,
    'composition' => shot.composition,
    'cameraAngle' => shot.cameraAngle,
    'lightingMood' => shot.lightingMood,
    'colorPalette' => shot.colorPalette,
    'visualFocus' => shot.visualFocus,
    'transitionHint' => shot.transitionHint,
    'cameraNotes' => shot.cameraNotes,
    'scene' => shot.scene,
    'productCode' => shot.productCode,
    'productStyling' => shot.productStyling,
    'dialogue' => shot.dialogue,
    'sound' => shot.sound,
    _ => '',
  };

  static ScriptShot _copyField(ScriptShot shot, String field, String value) =>
      switch (field) {
        'visual' => shot.copyWith(visual: value),
        'content' => shot.copyWith(content: value),
        'shotSize' => shot.copyWith(shotSize: value),
        'cameraMovement' => shot.copyWith(cameraMovement: value),
        'composition' => shot.copyWith(composition: value),
        'cameraAngle' => shot.copyWith(cameraAngle: value),
        'lightingMood' => shot.copyWith(lightingMood: value),
        'colorPalette' => shot.copyWith(colorPalette: value),
        'visualFocus' => shot.copyWith(visualFocus: value),
        'transitionHint' => shot.copyWith(transitionHint: value),
        'cameraNotes' => shot.copyWith(cameraNotes: value),
        'scene' => shot.copyWith(scene: value),
        'productCode' => shot.copyWith(productCode: value),
        'productStyling' => shot.copyWith(productStyling: value),
        'dialogue' => shot.copyWith(dialogue: value),
        'sound' => shot.copyWith(sound: value),
        _ => shot,
      };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
