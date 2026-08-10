import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../domain/shooting_script_models.dart';
import '../domain/shooting_script_workflow_models.dart';

class ScriptShotAnalysisPatch {
  const ScriptShotAnalysisPatch({
    required this.values,
    required this.fieldConfidence,
    this.promptContext = const ScriptShotPromptContext(),
    required this.rawResponse,
  });

  final Map<String, String> values;
  final Map<String, double> fieldConfidence;
  final ScriptShotPromptContext promptContext;
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
    String creativeBrief = '',
    String storyContext = '',
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
      creativeBrief: creativeBrief,
      storyContext: storyContext,
    );
    return fromVisionAnalysis(
      analysis,
      shot: shot,
      creativeBrief: creativeBrief,
    );
  }

  Future<ScriptShotAnalysisPatch> analyzeShotGroup({
    required AppSettings settings,
    required List<ScriptShot> shots,
    required List<File> imageFiles,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
  }) async {
    if (shots.isEmpty || imageFiles.isEmpty) {
      throw const FormatException('镜头组缺少可解析帧');
    }
    if (shots.length == 1 || imageFiles.length == 1) {
      return analyzeShot(
        settings: settings,
        shot: shots.first,
        imageFile: imageFiles.first,
        creativeBrief: creativeBrief,
        storyContext: storyContext,
      );
    }
    final groupAnalysis = await _visionService.analyzeShotGroupImages(
      settings: settings,
      imageFiles: imageFiles,
      shotNumber: shots.first.shotNumber,
      allowThinking: settings.videoAnalysisThinkingEnabled,
      creativeBrief: creativeBrief,
      storyContext: storyContext,
      neighboringCameraPlan: neighboringCameraPlan,
    );
    return fromShotGroupAnalysis(
      shots: shots,
      analyses: groupAnalysis.frames,
      motion: groupAnalysis.motion,
      creativeBrief: creativeBrief,
    );
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
    String creativeBrief = '',
  }) {
    final values = <String, String>{};
    final confidence = <String, double>{};
    void add(String field, String value, double score) {
      final normalized = _normalizeGeneratedField(field, value);
      if (normalized.isEmpty) return;
      values[field] = normalized;
      confidence[field] = score;
    }

    add('visual', analysis.caption, 0.86);
    add('content', analysis.detail, 0.84);
    add('shotSize', analysis.shotSize, 0.82);
    final cameraMovement = analysis.cameraDesign.trim().isNotEmpty
        ? analysis.cameraDesign
        : analysis.cameraMovement.trim().isNotEmpty
        ? analysis.cameraMovement
        : _designCameraMovement(analysis, creativeBrief: creativeBrief);
    final composition = _cameraComposition(
      start: analysis.startComposition,
      end: analysis.endComposition,
      fallback: analysis.composition,
    );
    final visualFocus = analysis.focusPath.trim().isNotEmpty
        ? analysis.focusPath
        : analysis.visualFocus;
    final transitionHint = analysis.transitionExecution.trim().isNotEmpty
        ? analysis.transitionExecution
        : analysis.transitionHint;
    final cameraNotes = _cameraNotes(
      observedMovement: analysis.cameraMovement,
      purpose: analysis.cameraPurpose,
      speedCurve: analysis.speedCurve,
    );
    final sound = _designSound(analysis);
    add(
      'cameraMovement',
      cameraMovement,
      analysis.cameraDesign.trim().isNotEmpty
          ? 0.88
          : analysis.cameraMovement.trim().isNotEmpty
          ? 0.74
          : 0.62,
    );
    add('scene', analysis.scene, 0.82);
    add(
      'productStyling',
      wardrobeSlotsFromText(_analysisWardrobeText(analysis)),
      0.76,
    );
    add('composition', composition, 0.84);
    add('cameraAngle', analysis.cameraAngle, 0.78);
    add('lightingMood', analysis.lightingMood, 0.80);
    add('colorPalette', colorStyleFromPaletteText(analysis.colorPalette), 0.78);
    add('visualFocus', visualFocus, 0.84);
    add('transitionHint', transitionHint, 0.78);
    add('cameraNotes', cameraNotes, 0.82);
    add('movementTrend', analysis.movementTrend, 0.86);
    add('actionStage', analysis.actionStage, 0.84);
    add(
      'continuesFromPrevious',
      analysis.continuesFromPrevious.toString(),
      0.88,
    );
    add('continuesToNext', analysis.continuesToNext.toString(), 0.88);
    add('sound', sound, 0.60);
    add(
      'durationSeconds',
      _designDurationSeconds(analysis, shot: shot).toStringAsFixed(1),
      0.58,
    );

    return ScriptShotAnalysisPatch(
      values: Map.unmodifiable(values),
      fieldConfidence: Map.unmodifiable(confidence),
      promptContext: _promptContextFromVision(
        analysis,
        cameraMovement: cameraMovement,
        composition: composition,
        visualFocus: visualFocus,
        transitionHint: transitionHint,
        observedCameraMovement: analysis.cameraMovement,
        cameraPurpose: analysis.cameraPurpose,
        speedCurve: analysis.speedCurve,
        startComposition: analysis.startComposition,
        endComposition: analysis.endComposition,
        focusPath: analysis.focusPath,
        sound: sound,
      ),
      rawResponse: analysis.rawResponse,
    );
  }

  static ScriptShotAnalysisPatch fromShotGroupAnalysis({
    required List<ScriptShot> shots,
    required List<VisionImageAnalysis> analyses,
    required VisionShotMotionAnalysis motion,
    String creativeBrief = '',
  }) {
    if (analyses.isEmpty) {
      throw const FormatException('镜头组缺少视觉分析结果');
    }
    final last = analyses.last;
    final cameraMovement = motion.designedCameraMovement.trim().isNotEmpty
        ? motion.designedCameraMovement
        : motion.cameraMovement.trim().isNotEmpty
        ? motion.cameraMovement
        : _designCameraMovement(last, creativeBrief: creativeBrief);
    final shotSize = _groupShotSize(analyses);
    final composition = _cameraComposition(
      start: motion.startComposition,
      end: motion.endComposition,
      fallback: _groupComposition(analyses),
    );
    final visualFocus = motion.focusPath.trim().isNotEmpty
        ? motion.focusPath
        : _mergeOrdered(analyses.map((item) => item.visualFocus));
    final transitionHint = motion.transitionExecution.trim().isNotEmpty
        ? motion.transitionExecution
        : last.transitionHint;
    final cameraNotes = _cameraNotes(
      observedMovement: motion.cameraMovement,
      purpose: motion.cameraPurpose,
      speedCurve: motion.speedCurve,
      evidence: motion.evidence,
    );
    final sound = _designGroupSound(analyses);
    final values = <String, String>{};
    final confidence = <String, double>{};
    void add(String field, String value, double score) {
      final normalized = _normalizeGeneratedField(field, value);
      if (normalized.isEmpty) return;
      values[field] = normalized;
      confidence[field] = score;
    }

    add('visual', _mergeOrdered(analyses.map((item) => item.caption)), 0.88);
    add('content', _mergeOrdered(analyses.map((item) => item.detail)), 0.86);
    add('scene', _firstNonEmpty(analyses.map((item) => item.scene)), 0.82);
    add('shotSize', shotSize, 0.80);
    add('cameraMovement', cameraMovement, 0.90);
    add('cameraAngle', motion.cameraAngle, 0.86);
    add('composition', composition, 0.84);
    add(
      'lightingMood',
      _mergeOrdered(analyses.map((item) => item.lightingMood), maxItems: 2),
      0.80,
    );
    add(
      'colorPalette',
      colorStyleFromPaletteText(
        _mergeOrdered(analyses.map((item) => item.colorPalette), maxItems: 2),
      ),
      0.78,
    );
    add('visualFocus', visualFocus, 0.82);
    add('transitionHint', transitionHint, 0.84);
    add(
      'movementTrend',
      _mergeOrdered(analyses.map((item) => item.movementTrend), maxItems: 3),
      0.88,
    );
    add('actionStage', last.actionStage, 0.82);
    add(
      'productStyling',
      wardrobeSlotsFromText(analyses.map(_analysisWardrobeText).join(' ')),
      0.76,
    );
    add('sound', sound, 0.60);
    add(
      'durationSeconds',
      _designGroupDurationSeconds(
        analyses,
        motion: motion,
        shots: shots,
      ).toStringAsFixed(1),
      0.68,
    );
    add('cameraNotes', cameraNotes, 0.88);

    return ScriptShotAnalysisPatch(
      values: Map.unmodifiable(values),
      fieldConfidence: Map.unmodifiable(confidence),
      promptContext: _promptContextFromGroup(
        analyses,
        cameraMovement: cameraMovement,
        shotSize: shotSize,
        composition: composition,
        cameraAngle: motion.cameraAngle,
        visualFocus: visualFocus,
        transitionHint: transitionHint,
        observedCameraMovement: motion.cameraMovement,
        cameraPurpose: motion.cameraPurpose,
        speedCurve: motion.speedCurve,
        startComposition: motion.startComposition,
        endComposition: motion.endComposition,
        focusPath: motion.focusPath,
        sound: sound,
      ),
      rawResponse: [
        for (final analysis in analyses) analysis.rawResponse,
        motion.rawResponse,
      ].where((item) => item.trim().isNotEmpty).join('\n'),
    );
  }

  static String _groupShotSize(List<VisionImageAnalysis> analyses) {
    final first = _firstNonEmpty(analyses.map((item) => item.shotSize));
    final last = _lastNonEmpty(analyses.map((item) => item.shotSize));
    if (first.isEmpty) return last;
    if (last.isEmpty || first == last) return first;
    return '$first到$last';
  }

  static String _groupComposition(List<VisionImageAnalysis> analyses) {
    final first = _firstNonEmpty(analyses.map((item) => item.composition));
    final last = _lastNonEmpty(analyses.map((item) => item.composition));
    if (first.isEmpty) return last;
    if (last.isEmpty || first == last) return first;
    return '首帧：$first；结束帧：$last';
  }

  static String _firstNonEmpty(Iterable<String> values) {
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isNotEmpty) return normalized;
    }
    return '';
  }

  static String _lastNonEmpty(Iterable<String> values) {
    var result = '';
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isNotEmpty) result = normalized;
    }
    return result;
  }

  static String _mergeOrdered(Iterable<String> values, {int maxItems = 3}) {
    final result = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty || result.contains(normalized)) continue;
      result.add(normalized);
      if (result.length >= maxItems) break;
    }
    return result.join('；');
  }

  static ScriptShotPromptContext _promptContextFromVision(
    VisionImageAnalysis analysis, {
    required String cameraMovement,
    required String composition,
    required String visualFocus,
    required String transitionHint,
    required String observedCameraMovement,
    required String cameraPurpose,
    required String speedCurve,
    required String startComposition,
    required String endComposition,
    required String focusPath,
    required String sound,
  }) => ScriptShotPromptContext(
    subject: _nonEmptyMap({
      'people': analysis.people,
      'expression': analysis.expression,
      'props': analysis.props,
    }),
    action: _nonEmptyMap({
      'bodyAction': analysis.bodyAction,
      'movementTrend': analysis.movementTrend,
      'actionStage': analysis.actionStage,
    }),
    scene: _nonEmptyMap({
      'location': analysis.scene,
      'subjectDirection': analysis.subjectDirection,
      'gazeDirection': analysis.gazeDirection,
      'spatialRelation': analysis.spatialRelation,
    }),
    camera: _nonEmptyMap({
      'shotSize': analysis.shotSize,
      'cameraMovement': cameraMovement,
      'observedCameraMovement': observedCameraMovement,
      'cameraPurpose': cameraPurpose,
      'speedCurve': speedCurve,
      'startComposition': startComposition,
      'endComposition': endComposition,
      'focusPath': focusPath,
      'composition': composition,
      'cameraAngle': analysis.cameraAngle,
      'visualFocus': visualFocus,
    }),
    visualStyle: _nonEmptyMap({
      'lightingMood': analysis.lightingMood,
      'colorPalette': colorStyleFromPaletteText(analysis.colorPalette),
    }),
    continuity: _nonEmptyMap({
      'caption': analysis.caption,
      'detail': analysis.detail,
      'chronologyCue': analysis.chronologyCue,
      'narrativeFunction': analysis.narrativeFunction,
      'transitionHint': transitionHint,
      'continuesFromPrevious': analysis.continuesFromPrevious.toString(),
      'continuesToNext': analysis.continuesToNext.toString(),
    }),
    audio: _nonEmptyMap({'sound': sound}),
  );

  static ScriptShotPromptContext _promptContextFromGroup(
    List<VisionImageAnalysis> analyses, {
    required String cameraMovement,
    required String shotSize,
    required String composition,
    required String cameraAngle,
    required String visualFocus,
    required String transitionHint,
    required String observedCameraMovement,
    required String cameraPurpose,
    required String speedCurve,
    required String startComposition,
    required String endComposition,
    required String focusPath,
    required String sound,
  }) {
    final first = analyses.first;
    final last = analyses.last;
    return ScriptShotPromptContext(
      subject: _nonEmptyMap({
        'people': _firstNonEmpty(analyses.map((item) => item.people)),
        'expression': _mergeOrdered(analyses.map((item) => item.expression)),
        'props': _mergeOrdered(analyses.map((item) => item.props)),
      }),
      action: _nonEmptyMap({
        'bodyAction': _mergeOrdered(analyses.map((item) => item.bodyAction)),
        'movementTrend': _mergeOrdered(
          analyses.map((item) => item.movementTrend),
        ),
        'actionStage': _firstToLast(analyses.map((item) => item.actionStage)),
      }),
      scene: _nonEmptyMap({
        'location': _firstNonEmpty(analyses.map((item) => item.scene)),
        'subjectDirection': _firstToLast(
          analyses.map((item) => item.subjectDirection),
        ),
        'gazeDirection': _firstToLast(
          analyses.map((item) => item.gazeDirection),
        ),
        'spatialRelation': _mergeOrdered(
          analyses.map((item) => item.spatialRelation),
        ),
      }),
      camera: _nonEmptyMap({
        'shotSize': shotSize,
        'cameraMovement': cameraMovement,
        'observedCameraMovement': observedCameraMovement,
        'cameraPurpose': cameraPurpose,
        'speedCurve': speedCurve,
        'startComposition': startComposition,
        'endComposition': endComposition,
        'focusPath': focusPath,
        'composition': composition,
        'cameraAngle': cameraAngle,
        'visualFocus': visualFocus,
      }),
      visualStyle: _nonEmptyMap({
        'lightingMood': _mergeOrdered(
          analyses.map((item) => item.lightingMood),
          maxItems: 2,
        ),
        'colorPalette': colorStyleFromPaletteText(
          _mergeOrdered(analyses.map((item) => item.colorPalette), maxItems: 2),
        ),
      }),
      continuity: _nonEmptyMap({
        'caption': _mergeOrdered(analyses.map((item) => item.caption)),
        'detail': _mergeOrdered(analyses.map((item) => item.detail)),
        'chronologyCue': _firstToLast(
          analyses.map((item) => item.chronologyCue),
        ),
        'narrativeFunction': _mergeOrdered(
          analyses.map((item) => item.narrativeFunction),
        ),
        'transitionHint': transitionHint,
        'continuesFromPrevious': first.continuesFromPrevious.toString(),
        'continuesToNext': last.continuesToNext.toString(),
      }),
      audio: _nonEmptyMap({'sound': sound}),
    );
  }

  static String _firstToLast(Iterable<String> values) {
    final first = _firstNonEmpty(values);
    final last = _lastNonEmpty(values);
    if (first.isEmpty) return last;
    if (last.isEmpty || first == last) return first;
    return '$first到$last';
  }

  static Map<String, String> _nonEmptyMap(Map<String, String> values) =>
      Map.unmodifiable({
        for (final entry in values.entries)
          if (_normalizeGeneratedField('promptContext', entry.value).isNotEmpty)
            entry.key: _normalizeGeneratedField('promptContext', entry.value),
      });

  static String _designCameraMovement(
    VisionImageAnalysis analysis, {
    String creativeBrief = '',
  }) {
    final text = [
      analysis.bodyAction,
      analysis.movementTrend,
      analysis.shotSize,
      analysis.visualFocus,
      analysis.narrativeFunction,
      creativeBrief,
    ].join(' ');
    if (_containsAny(text, const ['极简产品', '产品广告', '产品展示'])) {
      return '从产品轮廓的低位近景起势，沿前侧做受控短弧滑移并同步微幅推近，前段克制匀速、材质高光出现时减速，最终锁定品牌识别面与关键结构';
    }
    if (_containsAny(text, const ['品牌宣传', '大牌', '商业广告', '品牌'])) {
      if (_containsAny(text, const ['建立', '开场', '环境'])) {
        return '从前景遮挡后的低机位起势，沿空间纵深快速滑出并轻抬机位建立主体，运动中段保持自信匀速，最终在英雄式构图上精准缓停';
      }
      if (_containsAny(text, const ['产品', '记忆点', '揭示', '证明'])) {
        return '以人物或场景动作作为运动动机短促横移，随后转入小幅弧线靠近产品，速度由快到慢，最终把品牌识别面和材质高光压在画面视觉中心';
      }
    }
    if (_containsAny(text, const ['走', '跑', '移动', '驶', '飞', '跟随'])) {
      return '从主体运动方向前侧留出空间并平稳跟随，动作起势时同步加速、途中保持相对距离，关键动作发生前减速形成清晰落点';
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
      return '从动作下方或环境层次起势，镜头随主体做连续垂直升降并轻微修正俯仰，前段匀速、接近面部或关键物时减速，最终稳定在信息落点';
    }
    if (_containsAny(text, const ['特写', '细节', '表情', '产品', '聚焦'])) {
      return '从保留环境关系的构图起势，沿主体视线或道具轴线受控推进，关键细节出现时减速并微调焦点，最终停在表情、产品或动作结果上';
    }
    if (_containsAny(text, const ['全景', '远景', '环境', '建立场景'])) {
      return '从主体动作或局部信息起势，沿空间纵深平稳后撤并逐步揭示前后景关系，中段保持匀速，最终以完整环境构图建立叙事位置';
    }
    if (_containsAny(text, const ['反应', '情绪', '回望'])) {
      return '从人物三分之二侧面中近景起势，做小幅弧线侧移以改变背景层次，情绪变化出现时明显减速，最终停在视线与表情的反应落点';
    }
    if (_containsAny(text, const ['收束', '结果', '结尾'])) {
      return '从结果信息的清晰构图起势，沿空间轴线缓慢后撤并保留余韵，速度持续衰减，最终在主体与环境关系完整的画面上稳定停住';
    }
    return '从带前景层次的中景起势，沿主体动作方向做短距离侧向滑移并轻微改变视角，中段克制匀速、信息出现时减速，最终稳定落在本镜头的第一视觉焦点';
  }

  static String _cameraComposition({
    required String start,
    required String end,
    required String fallback,
  }) {
    final startValue = start.trim();
    final endValue = end.trim();
    if (startValue.isNotEmpty && endValue.isNotEmpty) {
      if (startValue == endValue) return startValue;
      return '起：$startValue → 落：$endValue';
    }
    return startValue.isNotEmpty
        ? startValue
        : endValue.isNotEmpty
        ? endValue
        : fallback.trim();
  }

  static String _cameraNotes({
    required String observedMovement,
    required String purpose,
    required String speedCurve,
    String evidence = '',
  }) {
    return [
      if (purpose.trim().isNotEmpty) '镜头目的：${purpose.trim()}',
      if (speedCurve.trim().isNotEmpty) '速度曲线：${speedCurve.trim()}',
      if (observedMovement.trim().isNotEmpty)
        '参考原运镜：${observedMovement.trim()}',
      if (evidence.trim().isNotEmpty) '多帧证据：${evidence.trim()}',
    ].join('；');
  }

  static String _designSound(VisionImageAnalysis analysis) {
    return '音效设计：${_designSoundAtmosphere(analysis)}；$_naturalSoundSyncRule；'
        '非叙事性音乐：N/A（除非脚本明确指定）';
  }

  static String _designGroupSound(List<VisionImageAnalysis> analyses) {
    final stages = <String>[];
    for (var index = 0; index < analyses.length; index++) {
      final analysis = analyses[index];
      final stage = analysis.actionStage.trim().isEmpty
          ? '阶段${index + 1}'
          : analysis.actionStage.trim();
      final sound = _designSoundAtmosphere(analysis);
      final entry = '$stage：$sound';
      if (!stages.contains(entry)) stages.add(entry);
    }
    return '音效设计：${stages.join('；')}；$_naturalSoundSyncRule；'
        '非叙事性音乐：N/A（除非脚本明确指定）';
  }

  static String _designSoundAtmosphere(VisionImageAnalysis analysis) {
    final modelDesigned = analysis.soundDesign.trim();
    if (modelDesigned.isNotEmpty) return modelDesigned;
    final parts = <String>[];
    if (analysis.scene.trim().isNotEmpty) {
      parts.add('${analysis.scene.trim()}的自然环境底噪保持稳定');
    }
    if (analysis.bodyAction.trim().isNotEmpty &&
        !_containsAny(analysis.bodyAction, const ['静止', '站立', '坐着', '不明显'])) {
      parts.add('${analysis.bodyAction.trim()}发生时匹配真实物理声并逐次同步');
    }
    if (analysis.props.trim().isNotEmpty) {
      parts.add('${analysis.props.trim()}仅在画面发生实际接触、开合、摩擦或碰撞时发出对应声音');
    }
    if (parts.isEmpty) {
      parts.add('只保留画面可证实的自然环境声，不额外编造动作音效');
    }
    return '${parts.take(3).join('，')}，不添加对白或旁白';
  }

  static const _naturalSoundSyncRule =
      '同步要求：所有声音按画面事件发生时刻逐一对齐，以真实时间速度播放，保持自然音高、正常瞬态和合理空间距离；禁止慢放、时间拉伸、低沉变调、拖长尾音、过长混响或把多个动作合成一声';

  static double _designDurationSeconds(
    VisionImageAnalysis analysis, {
    ScriptShot? shot,
  }) {
    final existing = shot?.durationSeconds ?? 0;
    if (existing > 0) return existing.clamp(3, 15).toDouble();
    final text = [
      analysis.bodyAction,
      analysis.movementTrend,
      analysis.shotSize,
      analysis.narrativeFunction,
      analysis.transitionHint,
    ].join(' ');
    if (_containsAny(text, const ['快速', '瞬间', '闪现', '切换'])) {
      return 3;
    }
    if (_containsAny(text, const ['建立', '全景', '远景', '走', '跑', '移动', '环绕'])) {
      return 6;
    }
    if (_containsAny(text, const ['静止', '定格', '特写', '细节', '局部'])) {
      return 4;
    }
    return 5;
  }

  static double _designGroupDurationSeconds(
    List<VisionImageAnalysis> analyses, {
    required VisionShotMotionAnalysis motion,
    required List<ScriptShot> shots,
  }) {
    final existing = shots.last.durationSeconds;
    if (existing > 0) return existing.clamp(3, 15).toDouble();

    final text = [
      for (final analysis in analyses) ...[
        analysis.bodyAction,
        analysis.movementTrend,
        analysis.actionStage,
        analysis.narrativeFunction,
        analysis.transitionHint,
      ],
      motion.designedCameraMovement,
      motion.speedCurve,
      motion.transitionExecution,
    ].join(' ');
    var duration = 4 + (analyses.length - 1).clamp(0, 4);
    if (_containsAny(text, const [
      '拿起',
      '放下',
      '打开',
      '关闭',
      '转身',
      '起身',
      '坐下',
      '走向',
      '跑向',
      '展示',
      '变形',
      '切换',
    ])) {
      duration += 1;
    }
    if (_containsAny(text, const ['建立', '全景', '远景', '环绕', '跟随', '升降'])) {
      duration += 1;
    }
    if (_containsAny(text, const ['快速', '瞬间', '闪现', '短促'])) {
      duration -= 1;
    }
    if (_containsAny(text, const ['静止', '定格', '不明显']) && analyses.length <= 2) {
      duration -= 1;
    }
    return duration.clamp(3, 12).toDouble();
  }

  static String _normalizeGeneratedField(String field, String value) {
    final normalized = value.trim();
    if (field == 'durationSeconds' || normalized.isEmpty) return normalized;
    return normalized
        .replaceAllMapped(
          RegExp(
            r'(^|[；;。\n])\s*(?:第\s*)?\d+(?:\.\d+)?\s*'
            r'(?:[-—~～至到]\s*\d+(?:\.\d+)?)?\s*(?:秒|s)'
            r'(?:内|时)?\s*[：:，,]\s*',
            caseSensitive: false,
          ),
          (match) => match.group(1) ?? '',
        )
        .replaceAll(
          RegExp(
            r'\d+(?:\.\d+)?\s*[-—~～至到]\s*\d+(?:\.\d+)?\s*(?:秒|s)',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'第\s*\d+(?:\.\d+)?\s*秒(?:内|时)?'), '随后')
        .replaceAll(RegExp(r'[；;，,]\s*[；;，,]+'), '；')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);

  static String colorStyleFromPaletteText(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), '').trim();
    if (normalized.isEmpty) return '';
    final sourceSegments = normalized
        .replaceAll(RegExp(r'(?:搭配|配以|配合|伴随|加入|加上|点缀|衬托|以及)'), '，')
        .split(RegExp(r'[，,；;。.\n]+'));
    final cleanedSegments = <String>[];
    for (final segment in sourceSegments) {
      final cleaned = _colorStyleSegment(segment);
      if (cleaned.isEmpty || cleanedSegments.contains(cleaned)) {
        continue;
      }
      cleanedSegments.add(cleaned);
    }
    return cleanedSegments.take(3).join('，');
  }

  static String _colorStyleSegment(String value) {
    final segment = value.trim();
    if (segment.isEmpty) return '';
    final hasWardrobeLeak = _containsAny(segment, _wardrobeColorLeakTerms);
    final hasObjectLeak = _containsAny(segment, _objectColorLeakTerms);
    final hasStyleSignal = _containsAny(segment, _colorStyleSignalTerms);
    final stylePhrase = _extractStylePhrase(segment);
    if (stylePhrase.isNotEmpty) {
      return stylePhrase;
    }
    if (hasWardrobeLeak) {
      return '';
    }
    if (hasObjectLeak) {
      final colorToken = _extractBroadColorToken(segment);
      return colorToken.isEmpty ? '' : _ensureColorStyleSuffix(colorToken);
    }
    if (!hasStyleSignal && !_containsAny(segment, _broadColorTerms)) {
      return '';
    }
    return _stripColorLeakTerms(segment);
  }

  static String _extractStylePhrase(String value) {
    final matches = [
      ...RegExp(
        r'(?:低饱和|高饱和)?(?:冷|暖)?(?:大地|中性|高级灰|黑白|[冷暖深浅暗亮淡米灰蓝绿白黑棕褐金银红橙黄粉紫]{2,})(?:色调|调性|色系)',
      ).allMatches(value),
      ...RegExp(
        r'(?:黑白|高|低|明暗|冷暖|深色|浅色|沉稳深色|柔和)?(?:高反差|低反差|对比|反差)',
      ).allMatches(value),
      ...RegExp(
        r'(?:复古|胶片|商业|电影|柔和|浓郁|清爽|通透|沉稳|明快|冷调|暖调|高级灰)(?:风格|质感|氛围|调性|感)?',
      ).allMatches(value),
    ];
    var best = '';
    for (final match in matches) {
      final candidate = _stripColorLeakTerms(match.group(0) ?? '');
      if (candidate.length > best.length) {
        best = candidate;
      }
    }
    return best;
  }

  static String _extractBroadColorToken(String value) {
    final matches = RegExp(
      r'(?:冷|暖|深|浅|暗|亮|淡|米|灰|蓝|绿|白|黑|棕|褐|金|银|红|橙|黄|粉|紫){2,}(?:色|调|系)?',
    ).allMatches(value);
    var best = '';
    for (final match in matches) {
      final candidate = match.group(0) ?? '';
      if (candidate.length > best.length) {
        best = candidate;
      }
    }
    return best;
  }

  static String _ensureColorStyleSuffix(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.endsWith('调') ||
        trimmed.endsWith('色调') ||
        trimmed.endsWith('调性') ||
        trimmed.endsWith('色系') ||
        trimmed.endsWith('风格')) {
      return trimmed;
    }
    return '$trimmed调';
  }

  static String _stripColorLeakTerms(String value) {
    var result = value.trim();
    final terms = [..._wardrobeColorLeakTerms, ..._objectColorLeakTerms]
      ..sort((first, second) => second.length.compareTo(first.length));
    for (final term in terms) {
      result = result.replaceAll(term, '');
    }
    return result
        .replaceAll(RegExp(r'(?:为底|作为底色|融合为底|提供|形成|呈现|营造|构成|带来)'), '')
        .replaceAll(RegExp(r'[的之]+$'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  static const _wardrobeColorLeakTerms = [
    '服装',
    '穿搭',
    '造型',
    '上装',
    '下装',
    '外套',
    '夹克',
    '西装',
    '衬衫',
    'T恤',
    't恤',
    '卫衣',
    '毛衣',
    '针织',
    '背心',
    '上衣',
    '大衣',
    '风衣',
    '马甲',
    '裤',
    '长裤',
    '短裤',
    '牛仔裤',
    '半裙',
    '短裙',
    '长裙',
    '裙装',
    '裙子',
    '衣袖',
    '袖口',
    '袖',
    '鞋',
    '靴',
    '包',
    '帽',
    '眼镜',
    '墨镜',
    '项链',
    '耳环',
    '耳饰',
    '银饰',
    '手链',
    '手表',
    '戒指',
    '腰带',
    '围巾',
    '领带',
    '发饰',
    '配饰',
    '首饰',
    '皮革',
    '皮质',
    '皮夹克',
    '条纹',
    '肤色',
    '皮肤',
    '头发',
    '发色',
    '唇色',
    '指甲',
  ];

  static const _objectColorLeakTerms = [
    '石墙',
    '砖墙',
    '墙面',
    '墙',
    '地面',
    '大理石',
    '铁艺',
    '木架',
    '桌面',
    '桌',
    '椅',
    '门',
    '窗',
    '背景',
    '天花',
    '灯具',
    '灯',
    '车辆',
    '车',
    '建筑',
    '植物',
    '花瓶',
    '道具',
    '产品',
    'Logo',
    'logo',
  ];

  static const _colorStyleSignalTerms = [
    '整体',
    '色彩',
    '色调',
    '调性',
    '色系',
    '风格',
    '质感',
    '氛围',
    '冷调',
    '暖调',
    '冷暖',
    '高调',
    '低调',
    '高反差',
    '低反差',
    '对比',
    '饱和',
    '低饱和',
    '高饱和',
    '复古',
    '商业',
    '胶片',
    '电影',
    '高级灰',
    '大地',
    '中性',
    '柔和',
    '浓郁',
    '清爽',
    '通透',
    '沉稳',
    '明快',
  ];

  static const _broadColorTerms = [
    '冷',
    '暖',
    '黑',
    '白',
    '灰',
    '蓝',
    '绿',
    '红',
    '橙',
    '黄',
    '金',
    '银',
    '棕',
    '褐',
    '米',
    '粉',
    '紫',
  ];

  static String wardrobeSlotsFromText(String value) {
    final text = value.trim();
    if (text.isEmpty) return '';
    final slots = <String>[];
    void addSlot(String slot, List<String> terms) {
      if (terms.any(text.contains)) {
        slots.add(slot);
      }
    }

    addSlot('上装', const [
      '上装',
      '外套',
      '夹克',
      '西装',
      '衬衫',
      'T恤',
      't恤',
      '卫衣',
      '毛衣',
      '针织',
      '背心',
      '上衣',
      '大衣',
      '风衣',
      '马甲',
    ]);
    addSlot('下装', const [
      '下装',
      '裤',
      '短裤',
      '长裤',
      '牛仔裤',
      '半裙',
      '短裙',
      '长裙',
      '裙装',
      '裙子',
    ]);
    addSlot('鞋子', const [
      '鞋',
      '靴',
      '运动鞋',
      '高跟鞋',
      '皮鞋',
      '凉鞋',
      '拖鞋',
      '帆布鞋',
      '乐福鞋',
    ]);
    addSlot('配饰', const [
      '配饰',
      '帽',
      '包',
      '眼镜',
      '墨镜',
      '项链',
      '耳环',
      '耳饰',
      '手链',
      '手表',
      '戒指',
      '腰带',
      '围巾',
      '领带',
      '发饰',
    ]);
    return slots.isEmpty ? '' : '${slots.join('/')}/';
  }

  static String _analysisWardrobeText(VisionImageAnalysis analysis) => [
    analysis.caption,
    analysis.detail,
    analysis.people,
    analysis.props,
    analysis.bodyAction,
    analysis.visualFocus,
  ].join(' ');
}
