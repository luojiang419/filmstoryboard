import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../domain/shooting_script_models.dart';

class ScriptShotAnalysisPatch {
  const ScriptShotAnalysisPatch({
    required this.values,
    required this.fieldConfidence,
    required this.rawResponse,
  });

  final Map<String, String> values;
  final Map<String, double> fieldConfidence;
  final String rawResponse;
}

/// Converts the existing vision-model response into shooting-script fields and
/// derives production suggestions that cannot be read literally from a still.
/// Dialogue, product codes and product styling remain user-authored fields.
class ScriptMultimodalAnalysisService {
  ScriptMultimodalAnalysisService({VisionStoryboardService? visionService})
    : _visionService = visionService ?? VisionStoryboardService(),
      _ownsVisionService = visionService == null;

  final VisionStoryboardService _visionService;
  final bool _ownsVisionService;

  Future<ScriptShotAnalysisPatch> analyzeShot({
    required AppSettings settings,
    required ScriptShot shot,
    required File imageFile,
    File? previousImageFile,
    File? nextImageFile,
  }) async {
    final analysis = await _visionService.analyzeImage(
      settings: settings,
      imageFile: imageFile,
      sequenceNo: shot.shotNumber,
      rowIndex: shot.shotNumber - 1,
      columnIndex: 0,
      allowThinking: settings.videoAnalysisThinkingEnabled,
      previousImageFile: previousImageFile,
      nextImageFile: nextImageFile,
    );
    return fromVisionAnalysis(analysis, shot: shot);
  }

  void cancelActiveRequests() => _visionService.cancelActiveRequests();

  void close() {
    if (_ownsVisionService) {
      _visionService.close();
    }
  }

  static ScriptShotAnalysisPatch fromVisionAnalysis(
    VisionImageAnalysis analysis, {
    ScriptShot? shot,
  }) {
    final values = <String, String>{};
    final confidence = <String, double>{};
    void add(String field, String value, double score) {
      final normalized = value.trim();
      if (normalized.isEmpty) return;
      values[field] = normalized;
      confidence[field] = score;
    }

    add('visual', analysis.caption, 0.86);
    add('content', analysis.detail, 0.84);
    add('shotSize', analysis.shotSize, 0.82);
    add(
      'cameraMovement',
      analysis.cameraMovement.trim().isEmpty
          ? _designCameraMovement(analysis)
          : analysis.cameraMovement,
      analysis.cameraMovement.trim().isEmpty ? 0.62 : 0.74,
    );
    add('scene', analysis.scene, 0.82);
    add('composition', analysis.composition, 0.80);
    add('cameraAngle', analysis.cameraAngle, 0.78);
    add('lightingMood', analysis.lightingMood, 0.80);
    add('colorPalette', analysis.colorPalette, 0.78);
    add('visualFocus', analysis.visualFocus, 0.80);
    add('transitionHint', analysis.transitionHint, 0.70);
    add('movementTrend', analysis.movementTrend, 0.86);
    add('actionStage', analysis.actionStage, 0.84);
    add(
      'continuesFromPrevious',
      analysis.continuesFromPrevious.toString(),
      0.88,
    );
    add('continuesToNext', analysis.continuesToNext.toString(), 0.88);
    add('sound', _designSound(analysis), 0.60);
    add(
      'durationSeconds',
      _designDurationSeconds(analysis, shot: shot).toStringAsFixed(1),
      0.58,
    );

    return ScriptShotAnalysisPatch(
      values: Map.unmodifiable(values),
      fieldConfidence: Map.unmodifiable(confidence),
      rawResponse: analysis.rawResponse,
    );
  }

  static String _designCameraMovement(VisionImageAnalysis analysis) {
    final text = [
      analysis.bodyAction,
      analysis.movementTrend,
      analysis.shotSize,
      analysis.visualFocus,
      analysis.narrativeFunction,
    ].join(' ');
    if (_containsAny(text, const ['走', '跑', '移动', '驶', '飞', '跟随'])) {
      return '平稳跟拍主体，速度与主体动作保持一致';
    }
    if (_containsAny(text, const [
      '向上',
      '上移',
      '抬升',
      '上升',
      '下半身',
      '腰部',
      '上半身',
    ])) {
      return '镜头随主体垂直升降或轻微上摇，保持构图变化准确';
    }
    if (_containsAny(text, const ['特写', '细节', '表情', '产品', '聚焦'])) {
      return '缓慢推近主体，聚焦关键动作与视觉细节';
    }
    if (_containsAny(text, const ['全景', '远景', '环境', '建立场景'])) {
      return '缓慢拉远，逐步交代环境与主体空间关系';
    }
    return '固定镜头，保持画面稳定，仅在人工确认后添加推拉摇移';
  }

  static String _designSound(VisionImageAnalysis analysis) {
    final parts = <String>[];
    if (analysis.scene.trim().isNotEmpty) {
      parts.add('${analysis.scene.trim()}的自然环境底噪');
    }
    if (analysis.bodyAction.trim().isNotEmpty) {
      parts.add('${analysis.bodyAction.trim()}对应的动作细节声');
    }
    if (analysis.props.trim().isNotEmpty) {
      parts.add('${analysis.props.trim()}产生的轻微接触声');
    }
    if (parts.isEmpty) {
      parts.add('与画面空间匹配的低强度环境声和主体动作声');
    }
    return '音效设计：${parts.join('；')}，不添加对白';
  }

  static double _designDurationSeconds(
    VisionImageAnalysis analysis, {
    ScriptShot? shot,
  }) {
    final text = [
      analysis.bodyAction,
      analysis.movementTrend,
      analysis.shotSize,
      analysis.narrativeFunction,
      analysis.transitionHint,
    ].join(' ');
    if (_containsAny(text, const ['快速', '瞬间', '切换', '特写', '细节'])) {
      return 4;
    }
    if (_containsAny(text, const ['建立', '全景', '远景', '走', '跑', '移动'])) {
      return 5;
    }
    final existing = shot?.durationSeconds ?? 0;
    return existing > 0 ? existing.clamp(3, 15).toDouble() : 5;
  }

  static bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);
}
