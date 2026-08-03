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

/// Converts the existing vision-model response into shooting-script fields.
/// It deliberately does not fabricate dialogue, sound, product codes or
/// product styling when the evidence is only a still image.
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
  }) async {
    final analysis = await _visionService.analyzeImage(
      settings: settings,
      imageFile: imageFile,
      sequenceNo: shot.shotNumber,
      rowIndex: shot.shotNumber - 1,
      columnIndex: 0,
      allowThinking: settings.videoAnalysisThinkingEnabled,
    );
    return fromVisionAnalysis(analysis);
  }

  void cancelActiveRequests() => _visionService.cancelActiveRequests();

  void close() {
    if (_ownsVisionService) {
      _visionService.close();
    }
  }

  static ScriptShotAnalysisPatch fromVisionAnalysis(
    VisionImageAnalysis analysis,
  ) {
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
    add('cameraMovement', analysis.cameraMovement, 0.74);
    add('scene', analysis.scene, 0.82);
    add('composition', analysis.composition, 0.80);
    add('cameraAngle', analysis.cameraAngle, 0.78);
    add('lightingMood', analysis.lightingMood, 0.80);
    add('colorPalette', analysis.colorPalette, 0.78);
    add('visualFocus', analysis.visualFocus, 0.80);
    add('transitionHint', analysis.transitionHint, 0.70);

    return ScriptShotAnalysisPatch(
      values: Map.unmodifiable(values),
      fieldConfidence: Map.unmodifiable(confidence),
      rawResponse: analysis.rawResponse,
    );
  }
}
