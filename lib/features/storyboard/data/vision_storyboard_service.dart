import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../../../core/services/vision_request_rate_limiter.dart';
import '../../settings/domain/app_settings.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import 'vision_caption_coherence_service.dart';

enum VisionImageRecoveryMode {
  none,
  jsonRepair,
  imageRetry,
  simplifiedFallback,
}

class VisionImageAnalysisException implements Exception {
  const VisionImageAnalysisException({
    required this.sequenceNo,
    required this.requestCount,
    required this.recoveryErrors,
    required this.rawResponse,
  });

  final int sequenceNo;
  final int requestCount;
  final List<String> recoveryErrors;
  final String rawResponse;

  @override
  String toString() {
    return '第 $sequenceNo 张图片解析在 $requestCount 次请求后仍失败：'
        '${recoveryErrors.join('；')}';
  }
}

class VisionImageAnalysis {
  const VisionImageAnalysis({
    required this.caption,
    required this.detail,
    required this.scene,
    required this.props,
    required this.people,
    required this.expression,
    required this.bodyAction,
    required this.movementTrend,
    this.soundDesign = '',
    required this.shotSize,
    this.cameraMovement = '',
    this.cameraDesign = '',
    this.cameraPurpose = '',
    this.speedCurve = '',
    this.startComposition = '',
    this.endComposition = '',
    this.focusPath = '',
    this.transitionExecution = '',
    required this.composition,
    required this.subjectDirection,
    required this.gazeDirection,
    required this.actionStage,
    required this.spatialRelation,
    required this.chronologyCue,
    this.cameraAngle = '',
    this.visualFocus = '',
    this.lightingMood = '',
    this.colorPalette = '',
    this.narrativeFunction = '',
    this.transitionHint = '',
    this.continuesFromPrevious = false,
    this.continuesToNext = false,
    this.recoveryMode = VisionImageRecoveryMode.none,
    this.requestCount = 1,
    this.recoveryErrors = const [],
    required this.rawResponse,
  });

  final String caption;
  final String detail;
  final String scene;
  final String props;
  final String people;
  final String expression;
  final String bodyAction;
  final String movementTrend;
  final String soundDesign;
  final String cameraMovement;
  final String cameraDesign;
  final String cameraPurpose;
  final String speedCurve;
  final String startComposition;
  final String endComposition;
  final String focusPath;
  final String transitionExecution;
  final String shotSize;
  final String composition;
  final String subjectDirection;
  final String gazeDirection;
  final String actionStage;
  final String spatialRelation;
  final String chronologyCue;
  final String cameraAngle;
  final String visualFocus;
  final String lightingMood;
  final String colorPalette;
  final String narrativeFunction;
  final String transitionHint;
  final bool continuesFromPrevious;
  final bool continuesToNext;
  final VisionImageRecoveryMode recoveryMode;
  final int requestCount;
  final List<String> recoveryErrors;
  final String rawResponse;

  bool get hasStoryboardOrderingCues {
    return shotSize.trim().isNotEmpty ||
        composition.trim().isNotEmpty ||
        subjectDirection.trim().isNotEmpty ||
        gazeDirection.trim().isNotEmpty ||
        actionStage.trim().isNotEmpty ||
        spatialRelation.trim().isNotEmpty ||
        chronologyCue.trim().isNotEmpty ||
        visualFocus.trim().isNotEmpty ||
        narrativeFunction.trim().isNotEmpty ||
        transitionHint.trim().isNotEmpty;
  }

  VisionImageAnalysis withCaption(String caption) {
    return VisionImageAnalysis(
      caption: normalizeVisionModelRoleTerms(caption),
      detail: detail,
      scene: scene,
      props: props,
      people: people,
      expression: expression,
      bodyAction: bodyAction,
      movementTrend: movementTrend,
      soundDesign: soundDesign,
      cameraMovement: cameraMovement,
      cameraDesign: cameraDesign,
      cameraPurpose: cameraPurpose,
      speedCurve: speedCurve,
      startComposition: startComposition,
      endComposition: endComposition,
      focusPath: focusPath,
      transitionExecution: transitionExecution,
      shotSize: shotSize,
      composition: composition,
      subjectDirection: subjectDirection,
      gazeDirection: gazeDirection,
      actionStage: actionStage,
      spatialRelation: spatialRelation,
      chronologyCue: chronologyCue,
      cameraAngle: cameraAngle,
      visualFocus: visualFocus,
      lightingMood: lightingMood,
      colorPalette: colorPalette,
      narrativeFunction: narrativeFunction,
      transitionHint: transitionHint,
      continuesFromPrevious: continuesFromPrevious,
      continuesToNext: continuesToNext,
      recoveryMode: recoveryMode,
      requestCount: requestCount,
      recoveryErrors: recoveryErrors,
      rawResponse: rawResponse,
    );
  }
}

class VisionShotGroupAnalysis {
  const VisionShotGroupAnalysis({
    required this.frames,
    required this.motion,
    required this.rawResponse,
  });

  final List<VisionImageAnalysis> frames;
  final VisionShotMotionAnalysis motion;
  final String rawResponse;
}

class VisionStoryboardSummaryResult {
  const VisionStoryboardSummaryResult({
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
    required this.rawResponse,
  });

  final String outline;
  final String content;
  final String scenes;
  final String props;
  final String rawResponse;
}

class VisionVideoDimensionResult {
  const VisionVideoDimensionResult({
    required this.dimensions,
    required this.rawResponse,
  });

  final Map<String, String> dimensions;
  final String rawResponse;
}

class VisionShotMotionAnalysis {
  const VisionShotMotionAnalysis({
    required this.isSameShot,
    required this.cameraMovement,
    this.designedCameraMovement = '',
    this.cameraPurpose = '',
    this.speedCurve = '',
    this.startComposition = '',
    this.endComposition = '',
    this.focusPath = '',
    this.transitionExecution = '',
    required this.cameraAngle,
    required this.evidence,
    required this.rawResponse,
  });

  final bool isSameShot;
  final String cameraMovement;
  final String designedCameraMovement;
  final String cameraPurpose;
  final String speedCurve;
  final String startComposition;
  final String endComposition;
  final String focusPath;
  final String transitionExecution;
  final String cameraAngle;
  final String evidence;
  final String rawResponse;
}

class VisionStoryboardCaptionRewriteResult {
  const VisionStoryboardCaptionRewriteResult({
    required this.captions,
    required this.rawResponse,
    this.initialReturnedCount = 0,
    this.repairedSequenceNos = const [],
    this.fallbackSequenceNos = const [],
    this.diagnostics = const {},
  });

  final List<String> captions;
  final String rawResponse;
  final int initialReturnedCount;
  final List<int> repairedSequenceNos;
  final List<int> fallbackSequenceNos;
  final Map<String, Object?> diagnostics;
}

class _VisionRequestCancelledException implements Exception {
  const _VisionRequestCancelledException();

  @override
  String toString() => '视觉模型请求已取消';
}

class VisionStoryboardOrderResult {
  const VisionStoryboardOrderResult({
    required this.order,
    required this.rawResponse,
  });

  final List<int> order;
  final String rawResponse;
}

class VisionImageEditSuggestion {
  const VisionImageEditSuggestion({
    required this.advice,
    required this.prompt,
    required this.rawResponse,
  });

  final String advice;
  final String prompt;
  final String rawResponse;
}

class VisionStoryboardService {
  VisionStoryboardService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static const _maxMissingOrderRepairCount = 2;

  static const requestTimeout = Duration(seconds: 120);
  static const _oversizedImageThresholdBytes = 3 * 1024 * 1024;
  static const _compressedImageTargetBytes = 2 * 1024 * 1024;

  static const _cameraMovementGuide = '''
运镜判断必须先比较同一镜头的起始/当前/结束帧构图变化，再选择一个主导运镜；不要只看当前帧主体大小。
判定顺序：
1. 固定：背景位置和画面边缘参照物基本不变，只有人物动作或姿态变化。
2. 升降/上摇下摇：画面取景沿垂直方向改变，例如从腰部/下半身抬到上半身/脸部，或背景边缘整体向上/向下滑动；这种情况优先写“升降”，不要写“推”。
3. 摇：机位原地水平或垂直转向，背景透视基本不变但取景方向改变。
4. 移/平移：整台摄影机横向或纵向平移，前景与背景有相对位移或视差。
5. 推/拉：主体和背景整体尺度持续变大/变小，画面透视或空间纵深支持摄影机靠近/远离；仅人物从下半身变成上半身、但画面重心上移，不算推。
6. 跟/正跟随/倒跟随：主体在空间中移动，镜头随主体保持相对距离。
7. 环绕/手持/摇移：只有出现绕主体视角变化、明显手持晃动或复合摇移证据时才选择。
如果前后帧证据冲突，优先选择“画面中心/边缘参照物位移”所支持的运镜；证据不足时写“固定”或空字符串。
''';

  static const _narrativeStyleExecutionGuide = '''
叙事风格逐字段执行规则：
1. 如果上文提供“已选镜头叙事风格执行契约（强制）”，它不是背景简介，而是本次镜头设计的强制规则。图片可见事实和用户已给事实优先；在不篡改这些事实的前提下，必须按执行契约重新设计叙事、画面材质、镜头节奏、动作连续性和声音。
2. 不能只在 detail 中写一句风格名，也不能用“电影感、唯美、高级”等通用形容词代替执行。caption/detail、camera_design、shot_size、composition、camera_angle、visual_focus、lighting_mood、color_palette、body_action、movement_trend、action_stage、spatial_relation、sound_design、narrative_function 和 transition_hint 各字段必须互相一致地体现同一种镜头语法。
3. 至少把两个该风格独有、可见或可听的特征写入对应字段；例如专属材质、特定动作机制、UI/文字规则、纸艺机关、节拍切点、品牌事实链或身份/空间锚点。不得只照抄执行契约原句，必须结合当前图片和故事改写成具体镜头内容。
4. 如果执行契约包含固定阶段、时间段或故事脊柱，只输出当前镜头对应的阶段；根据“全局故事与当前镜头位置”判断阶段，不要把整套流程机械塞进一个镜头。
5. hard constraints 与负向边界同样具有约束力。不得在正向字段中重新引入被禁止的材质、运动、文字、音频、品牌事实或叙事事件。
''';

  static const _professionalCameraPlanningGuide = '''
即梦 / Seedance 2.0 成熟导演语法（运镜与动作组织基线）：
1. 按“空间层 + 时间层”组织镜头：先锁定精准主体、场景环境、空间关系、光影色调，再按发生顺序写动作细节、表情变化、摄影机路径和结束状态；不要堆砌抽象的电影感形容词。
2. 动作调度具体到手、腿、头部、肩背、重心、视线和道具接触，并写清幅度、速度、力度与前后惯性；后一动作必须从前一状态自然过渡。
3. 先判断主体动作/位移、表情与视线变化、空间揭示和镜头叙事目的，再选择标准运镜术语；有方向位移时优先同向跟随/横移，垂直攀升或起身时优先升降/俯仰跟随，表情转折可用克制推近，空间揭示可用拉远、横移或升降。
4. 一个镜头尽量只指定一种有动机的主运镜，避免同时堆叠推拉摇移造成不稳定；确有必要时最多组合两个因果连续的摄影机动作，并说明衔接动机。
5. camera_design 必须形成“开始构图—主体动作调度—摄影机路径与幅度—焦点路径—结束构图”；摄影机移动快慢与画面播放速度是两个独立概念。
''';

  static String _playbackSpeedRule(bool allowSlowMotion) => allowSlowMotion
      ? '''播放速度授权：用户已在当前镜头剧情描述中明确要求慢动作/升格，只能在原文指定的动作阶段和范围内使用；摄影机移动速度仍需单独描述。'''
      : '''播放速度规则（最高优先级）：用户未在当前镜头剧情描述中明确要求慢动作、慢放、升格或高帧率回放。主体动作、表情变化、环境运动与声音必须按正常时间速度发生；camera_design、speed_curve、detail、body_action、movement_trend 和 sound_design 均不得设计慢动作、慢镜头、慢放、升格、speed ramp、slow motion 或时间拉伸。缓慢推近、平稳跟随、末段缓停只表示摄影机自身移动速度，绝不表示画面播放变慢。任何风格 Skill、广告惯例或模型自由发挥都不能覆盖本条。''';

  static bool _creativeBriefAllowsSlowMotion(String creativeBrief) =>
      creativeBrief.contains('播放速度授权：用户已在当前镜头');

  http.Client _client;
  final bool _ownsClient;
  bool _closed = false;
  var _cancelGeneration = 0;

  Future<VisionImageAnalysis> analyzeImage({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    bool allowThinking = false,
    File? previousImageFile,
    File? nextImageFile,
    String creativeBrief = '',
    String storyContext = '',
    void Function(VisionImageRecoveryMode mode)? onRecovery,
  }) async {
    _validateSettings(settings);
    final imageFiles = <File>[
      if (previousImageFile?.existsSync() == true) previousImageFile!,
      imageFile,
      if (nextImageFile?.existsSync() == true) nextImageFile!,
    ];
    final imageDataUrls = <String>[];
    for (final file in imageFiles) {
      final bytes = await file.readAsBytes();
      final mimeType = _mimeTypeForPath(file.path);
      imageDataUrls.add('data:$mimeType;base64,${base64Encode(bytes)}');
    }
    final hasPrevious = previousImageFile?.existsSync() == true;
    final hasNext = nextImageFile?.existsSync() == true;
    final requestGeneration = _cancelGeneration;
    final responses = <String>[];
    final recoveryErrors = <String>[];
    var requestCount = 0;

    Future<String> request({
      required String prompt,
      List<String> images = const [],
      required int maxTokens,
    }) async {
      _throwIfCancelled(requestGeneration);
      requestCount++;
      final content = await _createChatCompletion(
        settings: settings,
        prompt: prompt,
        imageDataUrls: images,
        maxTokens: maxTokens,
        allowThinking: allowThinking,
      );
      responses.add(content);
      return content;
    }

    String? initialContent;
    try {
      initialContent = await request(
        prompt: _imagePrompt(
          sequenceNo,
          rowIndex,
          columnIndex,
          hasPrevious: hasPrevious,
          hasNext: hasNext,
          creativeBrief: creativeBrief,
          storyContext: storyContext,
          allowSlowMotion: _creativeBriefAllowsSlowMotion(creativeBrief),
        ),
        images: imageDataUrls,
        maxTokens: 2200,
      );
      return _analysisFromContent(
        initialContent,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('initial: $error');
    }

    if (initialContent != null) {
      try {
        onRecovery?.call(VisionImageRecoveryMode.jsonRepair);
        final repairedContent = await request(
          prompt: _imageJsonRepairPrompt(
            sequenceNo: sequenceNo,
            rawResponse: initialContent,
            parseError: recoveryErrors.last,
          ),
          maxTokens: 2200,
        );
        return _analysisFromContent(
          repairedContent,
          recoveryMode: VisionImageRecoveryMode.jsonRepair,
          rawResponse: _joinedRecoveryResponses(responses),
          requestCount: requestCount,
          recoveryErrors: recoveryErrors,
        );
      } catch (error) {
        _throwIfCancelled(requestGeneration);
        recoveryErrors.add('json_repair: $error');
      }
    }

    try {
      onRecovery?.call(VisionImageRecoveryMode.imageRetry);
      final retryContent = await request(
        prompt: _imageRetryPrompt(
          sequenceNo,
          rowIndex,
          columnIndex,
          hasPrevious: hasPrevious,
          hasNext: hasNext,
          creativeBrief: creativeBrief,
          storyContext: storyContext,
          allowSlowMotion: _creativeBriefAllowsSlowMotion(creativeBrief),
        ),
        images: imageDataUrls,
        maxTokens: 2200,
      );
      return _analysisFromContent(
        retryContent,
        recoveryMode: VisionImageRecoveryMode.imageRetry,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('image_retry: $error');
    }

    try {
      onRecovery?.call(VisionImageRecoveryMode.simplifiedFallback);
      final fallbackContent = await request(
        prompt: _simplifiedImagePrompt(sequenceNo, rowIndex, columnIndex),
        images: imageDataUrls,
        maxTokens: 800,
      );
      return _analysisFromContent(
        fallbackContent,
        recoveryMode: VisionImageRecoveryMode.simplifiedFallback,
        rawResponse: _joinedRecoveryResponses(responses),
        requestCount: requestCount,
        recoveryErrors: recoveryErrors,
      );
    } catch (error) {
      _throwIfCancelled(requestGeneration);
      recoveryErrors.add('simplified_fallback: $error');
      throw VisionImageAnalysisException(
        sequenceNo: sequenceNo,
        requestCount: requestCount,
        recoveryErrors: List.unmodifiable(recoveryErrors.map(_compactForError)),
        rawResponse: _joinedRecoveryResponses(responses),
      );
    }
  }

  VisionImageAnalysis _analysisFromContent(
    String content, {
    VisionImageRecoveryMode recoveryMode = VisionImageRecoveryMode.none,
    required String rawResponse,
    required int requestCount,
    required List<String> recoveryErrors,
  }) {
    final json = _extractJsonObject(content);
    return _analysisFromJson(
      json,
      recoveryMode: recoveryMode,
      rawResponse: rawResponse,
      requestCount: requestCount,
      recoveryErrors: recoveryErrors,
    );
  }

  VisionImageAnalysis _analysisFromJson(
    Map<String, dynamic> json, {
    VisionImageRecoveryMode recoveryMode = VisionImageRecoveryMode.none,
    required String rawResponse,
    required int requestCount,
    required List<String> recoveryErrors,
  }) {
    final caption = _stringValue(json, 'caption');
    final detail = _stringValue(json, 'detail');
    if (caption.isEmpty || detail.isEmpty) {
      final missing = [
        if (caption.isEmpty) 'caption',
        if (detail.isEmpty) 'detail',
      ];
      throw FormatException('视觉模型缺少关键字段：${missing.join(', ')}');
    }
    return VisionImageAnalysis(
      caption: caption,
      detail: detail,
      scene: _stringValue(json, 'scene'),
      props: _stringValue(json, 'props'),
      people: _stringValue(json, 'people'),
      expression: _stringValue(json, 'expression'),
      bodyAction: _firstStringValue(json, const ['body_action', 'bodyAction']),
      movementTrend: _firstStringValue(json, const [
        'movement_trend',
        'movementTrend',
      ]),
      soundDesign: _firstStringValue(json, const [
        'sound_design',
        'soundDesign',
      ]),
      cameraMovement: _firstStringValue(json, const [
        'observed_camera_movement',
        'observedCameraMovement',
        'camera_movement',
        'cameraMovement',
      ]),
      cameraDesign: _firstStringValue(json, const [
        'camera_design',
        'cameraDesign',
      ]),
      cameraPurpose: _firstStringValue(json, const [
        'camera_purpose',
        'cameraPurpose',
      ]),
      speedCurve: _firstStringValue(json, const ['speed_curve', 'speedCurve']),
      startComposition: _firstStringValue(json, const [
        'start_composition',
        'startComposition',
      ]),
      endComposition: _firstStringValue(json, const [
        'end_composition',
        'endComposition',
      ]),
      focusPath: _firstStringValue(json, const ['focus_path', 'focusPath']),
      transitionExecution: _firstStringValue(json, const [
        'transition_execution',
        'transitionExecution',
      ]),
      shotSize: _firstStringValue(json, const ['shot_size', 'shotSize']),
      composition: _stringValue(json, 'composition'),
      subjectDirection: _firstStringValue(json, const [
        'subject_direction',
        'subjectDirection',
      ]),
      gazeDirection: _firstStringValue(json, const [
        'gaze_direction',
        'gazeDirection',
      ]),
      actionStage: _firstStringValue(json, const [
        'action_stage',
        'actionStage',
      ]),
      spatialRelation: _firstStringValue(json, const [
        'spatial_relation',
        'spatialRelation',
      ]),
      chronologyCue: _firstStringValue(json, const [
        'chronology_cue',
        'chronologyCue',
      ]),
      cameraAngle: _firstStringValue(json, const [
        'camera_angle',
        'cameraAngle',
      ]),
      visualFocus: _firstStringValue(json, const [
        'visual_focus',
        'visualFocus',
      ]),
      lightingMood: _firstStringValue(json, const [
        'lighting_mood',
        'lightingMood',
      ]),
      colorPalette: _firstStringValue(json, const [
        'color_palette',
        'colorPalette',
      ]),
      narrativeFunction: _firstStringValue(json, const [
        'narrative_function',
        'narrativeFunction',
      ]),
      transitionHint: _firstStringValue(json, const [
        'transition_hint',
        'transitionHint',
      ]),
      continuesFromPrevious: _boolValue(json, const [
        'continues_from_previous',
        'continuesFromPrevious',
      ]),
      continuesToNext: _boolValue(json, const [
        'continues_to_next',
        'continuesToNext',
      ]),
      recoveryMode: recoveryMode,
      requestCount: requestCount,
      recoveryErrors: List.unmodifiable(recoveryErrors),
      rawResponse: rawResponse,
    );
  }

  /// Analyzes every frame in a start/end-frame shot group and its motion in one
  /// multimodal API request. Image order is preserved as the time order.
  Future<VisionShotGroupAnalysis> analyzeShotGroupImages({
    required AppSettings settings,
    required List<File> imageFiles,
    required int shotNumber,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
    bool allowThinking = false,
  }) async {
    if (imageFiles.length < 2) {
      throw const FormatException('组级视觉解析至少需要两帧');
    }
    final content = await complete(
      settings: settings,
      prompt: _shotGroupAnalysisPrompt(
        shotNumber: shotNumber,
        frameCount: imageFiles.length,
        creativeBrief: creativeBrief,
        storyContext: storyContext,
        neighboringCameraPlan: neighboringCameraPlan,
        allowSlowMotion: _creativeBriefAllowsSlowMotion(creativeBrief),
      ),
      imageFiles: imageFiles,
      maxTokens: 4200,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    final rawFrames = json['frames'];
    if (rawFrames is! List) {
      throw const FormatException('镜头组视觉模型未返回 frames 数组');
    }
    final frameMaps = rawFrames
        .whereType<Map>()
        .map(
          (item) => <String, dynamic>{
            for (final entry in item.entries) '${entry.key}': entry.value,
          },
        )
        .toList(growable: false);
    if (frameMaps.length != imageFiles.length) {
      throw FormatException(
        '镜头组视觉模型返回 ${frameMaps.length} 帧，期望 ${imageFiles.length} 帧',
      );
    }
    final rawMotion = json['motion'];
    if (rawMotion is! Map) {
      throw const FormatException('镜头组视觉模型未返回 motion 对象');
    }
    final motionJson = <String, dynamic>{
      for (final entry in rawMotion.entries) '${entry.key}': entry.value,
    };
    return VisionShotGroupAnalysis(
      frames: List.unmodifiable(
        frameMaps.map(
          (frame) => _analysisFromJson(
            frame,
            rawResponse: '',
            requestCount: 1,
            recoveryErrors: const [],
          ),
        ),
      ),
      motion: _shotMotionFromJson(motionJson, rawResponse: content),
      rawResponse: content,
    );
  }

  Future<VisionStoryboardSummaryResult> summarizeStoryboard({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
  }) async {
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _summaryPrompt(analyses),
      maxTokens: 1200,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    return VisionStoryboardSummaryResult(
      outline: _summaryValue(
        json,
        'outline',
        fallback: _fallbackOutline(analyses),
        placeholders: const {'故事板大纲', '大纲'},
      ),
      content: _summaryValue(
        json,
        'content',
        fallback: _fallbackContent(analyses),
        placeholders: const {'故事板内容概述', '内容概述', '故事板内容'},
      ),
      scenes: _summaryValue(
        json,
        'scenes',
        fallback: _fallbackJoinedValues(
          analyses.map((analysis) => analysis.scene),
        ),
        placeholders: const {'出现的主要场景', '主要场景', '场景'},
      ),
      props: _summaryValue(
        json,
        'props',
        fallback: _fallbackJoinedValues(
          analyses.map((analysis) => analysis.props),
        ),
        placeholders: const {'关键道具和视觉元素', '关键道具', '视觉元素', '道具'},
      ),
      rawResponse: content,
    );
  }

  Future<VisionVideoDimensionResult> analyzeVideoDimensions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    required Map<String, String> summary,
    bool allowThinking = false,
  }) async {
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _videoDimensionPrompt(analyses, summary),
      maxTokens: 4200,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    return VisionVideoDimensionResult(
      dimensions: {
        for (final field in videoAnalysisDimensionFields)
          field: _stringValue(json, field),
      },
      rawResponse: content,
    );
  }

  Future<VisionVideoDimensionResult> analyzeVideoDimensionsFromImages({
    required AppSettings settings,
    required List<File> imageFiles,
    bool allowThinking = false,
  }) async {
    if (imageFiles.isEmpty) {
      throw const FormatException('多维度分析至少需要一张视频帧');
    }
    final content = await complete(
      settings: settings,
      prompt:
          '${_videoDimensionPrompt(const [], const {})}\n'
          '本次按视频时间顺序附带 ${imageFiles.length} 张候选帧。请直接根据这些图片完成分析；图片之间是时间连续采样，不要把相邻帧误判为不同视频。',
      imageFiles: imageFiles,
      maxTokens: 4200,
      allowThinking: allowThinking,
      compressOversizedImages: true,
    );
    final json = _extractJsonObject(content);
    return VisionVideoDimensionResult(
      dimensions: {
        for (final field in videoAnalysisDimensionFields)
          field: _stringValue(json, field),
      },
      rawResponse: content,
    );
  }

  Future<VisionShotMotionAnalysis> analyzeShotMotion({
    required AppSettings settings,
    required List<File> imageFiles,
    required List<VisionImageAnalysis> analyses,
    required int shotNumber,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
    bool allowThinking = false,
  }) async {
    if (imageFiles.length < 2 || analyses.length < 2) {
      throw const FormatException('组级运镜复核至少需要两帧');
    }
    _validateSettings(settings);
    final selectedImages = _selectShotMotionFiles(imageFiles);
    final selectedAnalyses = _selectShotMotionAnalyses(analyses);
    final content = await complete(
      settings: settings,
      prompt: _shotMotionPrompt(
        shotNumber: shotNumber,
        analyses: selectedAnalyses,
        creativeBrief: creativeBrief,
        storyContext: storyContext,
        neighboringCameraPlan: neighboringCameraPlan,
        allowSlowMotion: _creativeBriefAllowsSlowMotion(creativeBrief),
      ),
      imageFiles: selectedImages,
      maxTokens: 1800,
      allowThinking: allowThinking,
    );
    final json = _extractJsonObject(content);
    return _shotMotionFromJson(json, rawResponse: content);
  }

  VisionShotMotionAnalysis _shotMotionFromJson(
    Map<String, dynamic> json, {
    required String rawResponse,
  }) => VisionShotMotionAnalysis(
    isSameShot: _boolValue(json, const ['is_same_shot', 'isSameShot']),
    cameraMovement: _firstStringValue(json, const [
      'observed_camera_movement',
      'observedCameraMovement',
      'camera_movement',
      'cameraMovement',
    ]),
    designedCameraMovement: _firstStringValue(json, const [
      'designed_camera_movement',
      'designedCameraMovement',
    ]),
    cameraPurpose: _firstStringValue(json, const [
      'camera_purpose',
      'cameraPurpose',
    ]),
    speedCurve: _firstStringValue(json, const ['speed_curve', 'speedCurve']),
    startComposition: _firstStringValue(json, const [
      'start_composition',
      'startComposition',
    ]),
    endComposition: _firstStringValue(json, const [
      'end_composition',
      'endComposition',
    ]),
    focusPath: _firstStringValue(json, const ['focus_path', 'focusPath']),
    transitionExecution: _firstStringValue(json, const [
      'transition_execution',
      'transitionExecution',
    ]),
    cameraAngle: _firstStringValue(json, const ['camera_angle', 'cameraAngle']),
    evidence: _stringValue(json, 'evidence'),
    rawResponse: rawResponse,
  );

  Future<VisionStoryboardCaptionRewriteResult> rewriteStoryboardCaptions({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
    bool allowThinking = false,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (analyses.isEmpty) {
      return const VisionStoryboardCaptionRewriteResult(
        captions: [],
        rawResponse: '',
      );
    }
    _validateSettings(settings);
    final requestGeneration = _cancelGeneration;
    final coherenceService = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        _throwIfCancelled(requestGeneration);
        final completion = await _createChatCompletionDetailed(
          settings: settings,
          prompt: prompt,
          maxTokens: maxTokens,
          allowThinking: allowThinking,
        );
        _throwIfCancelled(requestGeneration);
        return completion;
      },
      shouldRethrow: (error) => error is _VisionRequestCancelledException,
    );
    final coherence = await coherenceService.rewrite(
      sources: [
        for (var index = 0; index < analyses.length; index++)
          VisionCaptionSource(
            sequenceNo: index + 1,
            caption: normalizeVisionModelRoleTerms(analyses[index].caption),
            scene: normalizeVisionModelRoleTerms(analyses[index].scene),
            bodyAction: normalizeVisionModelRoleTerms(
              analyses[index].bodyAction,
            ),
            actionStage: normalizeVisionModelRoleTerms(
              analyses[index].actionStage,
            ),
            visualFocus: normalizeVisionModelRoleTerms(
              analyses[index].visualFocus,
            ),
            lightingMood: normalizeVisionModelRoleTerms(
              analyses[index].lightingMood,
            ),
            narrativeFunction: normalizeVisionModelRoleTerms(
              analyses[index].narrativeFunction,
            ),
            transitionHint: normalizeVisionModelRoleTerms(
              analyses[index].transitionHint,
            ),
          ),
      ],
      onProgress: onProgress,
    );
    return VisionStoryboardCaptionRewriteResult(
      captions: coherence.captions
          .map(normalizeVisionModelRoleTerms)
          .toList(growable: false),
      rawResponse: coherence.rawResponse,
      initialReturnedCount: coherence.initialReturnedCount,
      repairedSequenceNos: coherence.repairedSequenceNos,
      fallbackSequenceNos: coherence.localFallbackSequenceNos,
      diagnostics: coherence.diagnostics,
    );
  }

  Future<VisionStoryboardOrderResult> suggestStoryboardOrder({
    required AppSettings settings,
    required List<VisionImageAnalysis> analyses,
  }) async {
    if (analyses.isEmpty) {
      return const VisionStoryboardOrderResult(order: [], rawResponse: '');
    }
    _validateSettings(settings);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _orderPrompt(analyses),
      maxTokens: (500 + analyses.length * 60).clamp(700, 1800).toInt(),
    );
    try {
      final json = _extractJsonObject(content);
      return VisionStoryboardOrderResult(
        order: _orderListValue(json, analyses.length),
        rawResponse: content,
      );
    } on FormatException catch (error) {
      throw FormatException(
        '${error.message}；原始响应：${_compactForError(content)}',
      );
    }
  }

  Future<VisionImageEditSuggestion> suggestImageEditPrompt({
    required AppSettings settings,
    required File imageFile,
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String currentCaption,
    required String previousCaption,
    required String nextCaption,
    required String rowCaption,
    required String storyboardSummary,
    required VisionImageAnalysis currentAnalysis,
    required VisionImageAnalysis? previousAnalysis,
    required VisionImageAnalysis? nextAnalysis,
    required List<VisionImageAnalysis> storyboardAnalyses,
  }) async {
    _validateSettings(settings);
    final bytes = await imageFile.readAsBytes();
    final mimeType = _mimeTypeForPath(imageFile.path);
    final content = await _createChatCompletion(
      settings: settings,
      prompt: _imageEditSuggestionPrompt(
        sequenceNo: sequenceNo,
        rowIndex: rowIndex,
        columnIndex: columnIndex,
        currentCaption: currentCaption,
        previousCaption: previousCaption,
        nextCaption: nextCaption,
        rowCaption: rowCaption,
        storyboardSummary: storyboardSummary,
        currentAnalysis: currentAnalysis,
        previousAnalysis: previousAnalysis,
        nextAnalysis: nextAnalysis,
        storyboardAnalyses: storyboardAnalyses,
      ),
      imageDataUrl: 'data:$mimeType;base64,${base64Encode(bytes)}',
      maxTokens: 1400,
    );
    final json = _extractJsonObject(content);
    final prompt = _stringValue(json, 'prompt');
    if (prompt.trim().isEmpty) {
      throw const FormatException('视觉模型未返回可用的修改提示词');
    }
    return VisionImageEditSuggestion(
      advice: _stringValue(json, 'advice'),
      prompt: prompt,
      rawResponse: content,
    );
  }

  void cancelActiveRequests() {
    _cancelGeneration++;
    if (!_ownsClient || _closed) {
      return;
    }
    _client.close();
    _client = http.Client();
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _client.close();
  }

  void _throwIfCancelled(int requestGeneration) {
    if (_closed || requestGeneration != _cancelGeneration) {
      throw const _VisionRequestCancelledException();
    }
  }

  Future<String> _createChatCompletion({
    required AppSettings settings,
    required String prompt,
    String? imageDataUrl,
    List<String> imageDataUrls = const [],
    required int maxTokens,
    bool allowThinking = false,
    Duration responseTimeout = requestTimeout,
  }) async {
    final completion = await _createChatCompletionDetailed(
      settings: settings,
      prompt: prompt,
      imageDataUrl: imageDataUrl,
      imageDataUrls: imageDataUrls,
      maxTokens: maxTokens,
      allowThinking: allowThinking,
      responseTimeout: responseTimeout,
    );
    return completion.content;
  }

  /// Runs a JSON-oriented chat completion for workflow features that need to
  /// compare several local images in one request.
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
    Duration responseTimeout = requestTimeout,
    bool compressOversizedImages = false,
  }) async {
    _validateSettings(settings);
    final imageDataUrls = <String>[];
    for (final imageFile in imageFiles) {
      if (!imageFile.existsSync()) continue;
      final bytes = await imageFile.readAsBytes();
      if (compressOversizedImages) {
        final transferable = TransferableTypedData.fromList([bytes]);
        final mimeType = _mimeTypeForPath(imageFile.path);
        imageDataUrls.add(
          await Isolate.run(
            () => _compressVisionImageInWorker(
              transferable,
              imageFile.path,
              mimeType,
            ),
          ),
        );
      } else {
        imageDataUrls.add(
          'data:${_mimeTypeForPath(imageFile.path)};base64,'
          '${base64Encode(bytes)}',
        );
      }
    }
    return _createChatCompletion(
      settings: settings,
      prompt: prompt,
      imageDataUrls: imageDataUrls,
      maxTokens: maxTokens,
      allowThinking: allowThinking,
      responseTimeout: responseTimeout,
    );
  }

  Future<VisionChatCompletion> _createChatCompletionDetailed({
    required AppSettings settings,
    required String prompt,
    String? imageDataUrl,
    List<String> imageDataUrls = const [],
    required int maxTokens,
    bool allowThinking = false,
    Duration responseTimeout = requestTimeout,
  }) async {
    await VisionRequestRateLimiter.waitForRequestSlot(settings);
    final endpoint = normalizeChatCompletionsEndpoint(
      settings.visionApiBaseUrl,
    );
    final disableThinking = _shouldDisableThinking(
      settings,
      allowThinking: allowThinking,
    );
    final enableThinking = _shouldEnableThinking(settings, allowThinking);
    final content = <Map<String, Object?>>[
      {
        'type': 'text',
        'text': disableThinking
            ? '/no_think\n$prompt'
            : enableThinking
            ? '/think\n$prompt'
            : prompt,
      },
      for (final image in [
        ...?imageDataUrl == null ? null : [imageDataUrl],
        ...imageDataUrls,
      ])
        {
          'type': 'image_url',
          'image_url': {'url': image},
        },
    ];
    final response = await _client
        .post(
          endpoint,
          headers: {
            'Content-Type': 'application/json',
            if (settings.visionApiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${settings.visionApiKey.trim()}',
          },
          body: jsonEncode({
            'model': settings.visionModel.trim(),
            'messages': [
              {'role': 'user', 'content': content},
            ],
            'temperature': 0,
            if (disableThinking) ...{
              'chat_template_kwargs': {'enable_thinking': false},
              'enable_thinking': false,
            },
            if (enableThinking) ...{
              'chat_template_kwargs': {'enable_thinking': true},
              'enable_thinking': true,
            },
          }),
        )
        .timeout(
          responseTimeout,
          onTimeout: () {
            throw TimeoutException(
              '视觉模型请求超时：超过 ${responseTimeout.inSeconds} 秒未响应',
            );
          },
        );
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('视觉模型请求失败：${response.statusCode} $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('视觉模型响应不是 JSON 对象');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('视觉模型响应缺少 choices');
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      throw const FormatException('视觉模型 choices 格式异常');
    }
    final message = firstChoice['message'];
    if (message is! Map<String, dynamic>) {
      throw const FormatException('视觉模型响应缺少 message');
    }
    final messageContent = message['content'];
    final String text;
    if (messageContent is String) {
      text = messageContent;
    } else if (messageContent is List) {
      text = messageContent
          .map((item) {
            if (item is Map && item['text'] != null) {
              return item['text'].toString();
            }
            return item.toString();
          })
          .join('\n');
    } else {
      throw const FormatException('视觉模型响应缺少文本内容');
    }
    final usage = decoded['usage'];
    return VisionChatCompletion(
      content: text,
      finishReason: firstChoice['finish_reason']?.toString() ?? '',
      promptTokens: usage is Map ? _nullableInt(usage['prompt_tokens']) : null,
      completionTokens: usage is Map
          ? _nullableInt(usage['completion_tokens'])
          : null,
      totalTokens: usage is Map ? _nullableInt(usage['total_tokens']) : null,
    );
  }

  int? _nullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  bool _shouldDisableThinking(
    AppSettings settings, {
    required bool allowThinking,
  }) {
    return !allowThinking && _supportsThinkingToggle(settings);
  }

  bool _shouldEnableThinking(AppSettings settings, bool allowThinking) {
    return allowThinking && _supportsThinkingToggle(settings);
  }

  bool _supportsThinkingToggle(AppSettings settings) {
    final model = settings.visionModel.trim().toLowerCase();
    return model.contains('qwen3') || model.contains('qwen-3');
  }

  void _validateSettings(AppSettings settings) {
    if (settings.visionApiBaseUrl.trim().isEmpty) {
      throw const FormatException('请先填写视觉模型 API 地址');
    }
    if (settings.visionModel.trim().isEmpty) {
      throw const FormatException('请先填写视觉模型名称');
    }
  }

  String _imagePrompt(
    int sequenceNo,
    int rowIndex,
    int columnIndex, {
    bool hasPrevious = false,
    bool hasNext = false,
    String creativeBrief = '',
    String storyContext = '',
    bool allowSlowMotion = false,
  }) {
    final sequenceGuide = switch ((hasPrevious, hasNext)) {
      (true, true) =>
        '本次按时间顺序提供三张图：上一帧、当前帧、下一帧。所有主体、动作和运动字段必须以当前帧为中心，结合前后帧的可见变化判断。',
      (true, false) => '本次按时间顺序提供两张图：上一帧、当前帧。所有主体、动作和运动字段必须以第二张当前帧为中心，结合上一帧判断。',
      (false, true) => '本次按时间顺序提供两张图：当前帧、下一帧。所有主体、动作和运动字段必须以第一张当前帧为中心，结合下一帧判断。',
      (false, false) => '本次只提供当前帧；无法可靠判断运动方向时必须明确写不明显。',
    };
    final directorContext = _directorContext(
      creativeBrief: creativeBrief,
      storyContext: storyContext,
    );
    return '''
你正在为故事板构建可直接执行的导演脚本。先忠实识别画面事实，再根据故事作用设计镜头语言；“观测到什么”和“建议怎么拍”必须分开回答。
请分析第 $sequenceNo 张图片，它位于第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列。
$sequenceGuide
禁止根据单帧姿态猜测运动：只有前后帧出现可见位移、姿态推进或动作结果时，才能判断运动趋势和动作阶段。
$_cameraMovementGuide
$_professionalCameraPlanningGuide
${_playbackSpeedRule(allowSlowMotion)}
$directorContext
$_narrativeStyleExecutionGuide
当前是单张目标画面的单镜头导演设计。相邻图片若存在，只用于判断动作承接与剪辑关系，不得把相邻图片机械拆成当前镜头内的新 Shot。请根据当前画面可见的身体动势、动作趋势、表情变化潜力、视线方向和空间关系，设计专业但可执行的画内动作调度与一条主运镜；不得编造与当前姿态相冲突的动作起点。
导演式运镜设计规则：
1. camera_movement 只记录参考画面可证实的原始运镜；camera_design 才是根据叙事功能、内容类型和镜头位置设计的最终执行方案。
2. camera_design 必须写清起始机位/构图、运动路径与幅度、速度变化、焦点落点，形成“起势—过程—落点”，不能只写“推、拉、摇、移、固定”。
3. 运镜服务叙事：建立交代空间，推进跟随动作，揭示通过遮挡/角度/焦点变化制造信息出现，产品记忆点强调材质与轮廓，反应镜头强调情绪，收束镜头给出明确视觉句号。
4. 内容类型不同，镜头语法必须不同：品牌宣传强调自信、精确、英雄化与商业节拍；极简产品展示强调微距、轮廓光、受控弧线/滑轨与材质焦点；剧情强调视线、关系、悬念与因果；MV 强调节拍、身体动势和转场动机；手作/纸艺强调触感、层次和定格节奏。
5. 不得为“丰富”而无目的堆叠运镜。一个镜头只保留一条可执行主路径，最多组合两个连续动作，并说明组合原因。
6. “固定/锁定机位”只能是主动设计：必须说明为何静止、画内动作如何调度、最终视觉落点是什么。证据不足不能自动批量写固定。
7. 结合前后镜头避免连续重复相同运镜；若沿用同类运动，必须改变幅度、方向、速度曲线或叙事目的。
音效设计规则：
1. sound_design 只写画面可见环境、动作和道具接触能够直接支持的声音，不写对白、旁白或背景音乐。
2. 按事件写清“什么动作触发什么声音”，有前后帧时结合动作阶段安排先后；脚步、触碰、开合、碰撞、摩擦等必须逐次贴合对应画面事件。
3. 所有声音按真实时间速度播放，保持自然音高、正常瞬态和合理空间距离；禁止慢放、时间拉伸、低沉变调、拖长尾音、过长混响或把多个动作合成一声。
4. 画面没有可证实的发声事件时，只保留与场景匹配的自然环境底噪，不为丰富而编造音效。
请判断当前动作是否承接上一帧、是否继续到下一帧；必须同时满足人物/主体、场景和动作因果连续，单纯处于同一场景不算同一组动作。
描述要有镜头画面感：把主体、环境、动作、情绪、光线、视觉焦点和镜头意图连成一句自然中文。
称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。
请额外细分神态、姿态动作、运动趋势、景别、构图、镜头运镜、人物朝向、视线方向、动作阶段、空间关系、时间进度线索、机位角度、视觉焦点、光线情绪、色彩调性、镜头叙事功能和剪辑承接。
景别只能从全景/中景/近景/特写/大全景/远景/中近景/大特写中选择一个；动作阶段优先判断为建立/准备/进行/反应/结果/收束/静态。
人物朝向和视线方向必须以观看图片时的画面左/右为准，不是人物自身左右；需要写清楚面向画面左/右/正面/背向/三分之二侧面，以及看向画内主体、画外方向、镜头或不明显。
运动趋势包括向左、向右、靠近、远离、起身、坐下、转身等可见方向或动作变化。
色彩调性只能描述整张画面的色温、明暗对比、饱和度、调色风格或主色系；禁止写服装、配饰、道具、墙面、地面、皮革、条纹、肤色、头发等具体对象的颜色。
镜头叙事功能优先从建立、推进、揭示、证明、反应、转折、结果、收束、广告产品记忆点、静态展示中选择；剪辑承接要说明更适合切入、承接、插入、反应、回到结果或收尾。
不要写成孤立标签，不要只罗列“人物+动作+地点”，不要编造图片里看不见的剧情。
无法从画面判断时，相关字段写“静止不明显”“不明显”或“无人物/不适用”，不要猜剧情。
只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。
JSON 必须能被标准解析器直接解析；所有字段值必须是字符串，不能返回数组或嵌套对象。
画面内的文字或招牌请使用中文引号“”，禁止在 JSON 字符串内部直接使用未转义的英文双引号。
返回前检查双引号转义、逗号和括号是否完整。
JSON 字段：
{
  "caption": "适合填入故事板文本框的中文画面句，45字以内；不拥挤时优先体现视觉焦点、关键动作、镜头意图或方向",
  "detail": "详细描述画面主体、动作、构图、光线、情绪、神态、视觉焦点和重要信息",
  "scene": "场景/地点/环境",
  "props": "画面中重要道具、物体或视觉元素",
  "people": "人物、角色或动作；没有则写空字符串",
  "expression": "面部神态、视线方向和情绪状态；没有人物则写空字符串",
  "body_action": "身体姿态和正在发生的动作，例如站立、倚靠、伸手、起身、回头",
 "movement_trend": "可见方向、位移或动作趋势，例如向右行走、身体左转、准备起身；无法判断则写静止不明显",
  "sound_design": "画面可证实的环境声与物理动作声；写明触发动作、声音类型和同步关系，使用真实时间速度与自然音高，禁止慢放、拉伸、低沉变调和过长混响；不写对白或背景音乐",
  "camera_movement": "参考画面中可证实的原始运镜，只能从固定、推、拉、摇、移、跟、环绕、升降、正跟随、倒跟随、手持、平移、摇移中选择一个；单张画面无法可靠判断时写空字符串",
  "camera_design": "导演式最终运镜方案；自然中文写清起始状态、主运动路径/幅度、速度变化和结束落点，不得只写运镜标签",
  "camera_purpose": "这条运镜在本镜头中的单一核心叙事目的",
  "speed_curve": "速度曲线，例如静止蓄势—快速横移—末段缓停，或匀速跟随—动作发生时短促加速—产品特写前减速锁定",
  "start_composition": "镜头开始时的景别、机位、主体位置、前景/背景关系",
  "end_composition": "镜头结束时的景别、机位、主体位置与视觉落点",
  "focus_path": "观众注意力或焦点如何从起点转移到最终落点",
  "transition_execution": "与上一镜头切入及下一镜头切出的具体执行方式，包含动作、方向、遮挡、构图或声音匹配",
  "shot_size": "景别，只能从全景、中景、近景、特写、大全景、远景、中近景、大特写中选择一个；无法判断时写空字符串",
  "composition": "构图和主体位置，例如主体居中、左侧留白、右侧前景遮挡、俯视/仰视",
  "subject_direction": "人物或主体朝向，例如面向画面右侧、背对镜头、正面看向镜头、无人物/不适用",
  "gaze_direction": "视线方向和看向目标，例如看向画面左侧、看向门口、看向画外、不明显",
  "action_stage": "动作进度阶段，例如建立、准备、进行、反应、结果、收束、静态",
  "spatial_relation": "主体与场景/道具/他人的空间关系，例如从门外进入室内、靠近桌面、站在马匹左侧",
  "chronology_cue": "时间或叙事进度线索，例如开场建立、动作前、动作中、动作后、反应镜头、结尾收束、不明显",
  "camera_angle": "机位、角度或镜头感，例如眼平中景、低角度仰拍、俯视、侧面观察、过肩、产品三分之二角度",
  "visual_focus": "观众第一眼会注意到的主体、表情、动作、道具、Logo、材质或信息点",
  "lighting_mood": "光线来源、明暗关系和情绪，例如柔和窗光、硬侧光、高调商业光、低调悬疑光、暖色余晖",
  "color_palette": "只写整体色彩风格，例如冷蓝灰调、暖金色调、黑白高反差、清爽白绿、低饱和大地色系；不要写任何具体对象、服装、配饰、道具或材质的颜色",
  "narrative_function": "镜头叙事功能，例如建立、推进、揭示、证明、反应、转折、结果、收束、广告产品记忆点、静态展示",
  "transition_hint": "剪辑承接建议，例如适合开场、承接上一动作、作为中段插入细节、接反应镜头、回到结果、适合收尾"
  ,"continues_from_previous": "布尔字符串 true 或 false；当前动作是否明确承接上一帧，没有上一帧时必须为 false"
  ,"continues_to_next": "布尔字符串 true 或 false；当前动作是否明确继续到下一帧，没有下一帧时必须为 false"
}

''';
  }

  String _imageRetryPrompt(
    int sequenceNo,
    int rowIndex,
    int columnIndex, {
    bool hasPrevious = false,
    bool hasNext = false,
    String creativeBrief = '',
    String storyContext = '',
    bool allowSlowMotion = false,
  }) {
    return '''
上一次解析第 $sequenceNo 张图片时，模型响应无法通过标准 JSON 校验。
请重新观察图片并完整分析，不要复用上一次的错误格式。
特别注意：JSON 字符串内部禁止出现未转义英文双引号；画面文字统一使用中文引号“”。

${_imagePrompt(sequenceNo, rowIndex, columnIndex, hasPrevious: hasPrevious, hasNext: hasNext, creativeBrief: creativeBrief, storyContext: storyContext, allowSlowMotion: allowSlowMotion)}
''';
  }

  String _imageJsonRepairPrompt({
    required int sequenceNo,
    required String rawResponse,
    required String parseError,
  }) {
    return '''
请修复第 $sequenceNo 张图片视觉解析结果的 JSON 结构。
只修复语法、引号转义和字段类型，不改变原有视觉事实，不添加新剧情。
只返回一个可被标准 JSON 解析器直接解析的对象，不要使用 Markdown，不要解释。
所有字段值必须是字符串；数组请用中文顿号连接为字符串；画面文字使用中文引号“”。
必须保留 caption 和 detail 两个关键字段。

解析错误：
$parseError

待修复原始响应：
$rawResponse
''';
  }

  String _simplifiedImagePrompt(int sequenceNo, int rowIndex, int columnIndex) {
    return '''
请对第 $sequenceNo 张故事板图片执行稳定的精简视觉解析，它位于第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列。
只根据画面可见内容描述，不编造剧情。成年女性称为“女模特”，成年男性称为“男模特”。
$_cameraMovementGuide
只返回一个可被标准 JSON 解析器直接解析的对象，不要使用 Markdown，不要解释。
所有字段值必须是字符串，画面文字使用中文引号“”，禁止使用未转义英文双引号。
JSON 字段：
{
  "caption": "45字以内的专业故事板画面句",
  "detail": "主体、动作、环境、构图、光线和情绪的具体描述",
  "scene": "场景与环境",
  "props": "关键道具与视觉元素",
  "people": "人物与可见动作",
  "body_action": "身体姿态和动作",
  "movement_trend": "可见运动方向或静止不明显",
  "sound_design": "画面可证实且与动作逐次同步的自然环境声和物理声；真实速度、自然音高，不写对白或背景音乐",
  "camera_movement": "镜头运镜；从固定、推、拉、摇、移、跟、环绕、升降、正跟随、倒跟随、手持、平移、摇移中选择一个；无法可靠判断时写空字符串",
  "shot_size": "景别",
  "composition": "构图与主体位置",
  "visual_focus": "第一视觉焦点",
  "narrative_function": "建立、推进、揭示、反应、结果、收束或静态展示",
  "transition_hint": "与前后镜头的剪辑承接建议"
}
''';
  }

  String _joinedRecoveryResponses(List<String> responses) {
    return [
      for (var i = 0; i < responses.length; i++)
        '[响应 ${i + 1}]\n${responses[i]}',
    ].join('\n\n');
  }

  String _summaryPrompt(List<VisionImageAnalysis> analyses) {
    final buffer = StringBuffer()
      ..writeln('请根据以下逐图视觉解析结果，归纳整个故事板。')
      ..writeln('只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。')
      ..writeln('字段值必须写具体内容，不要照抄字段说明或输出“故事板大纲”“故事板内容概述”等占位词。')
      ..writeln('称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。')
      ..writeln(
        '请按镜头顺序归纳主角、视觉焦点、镜头功能、景别推进、人物朝向、视线方向、动作阶段、运动趋势、场景变化、光色氛围、视觉风格和关键道具。',
      )
      ..writeln('整体描述必须像一个连续画面段落，不要逐条罗列，不要把逐图短句用分号直接拼接。')
      ..writeln('JSON 字段：')
      ..writeln('{')
      ..writeln('  "outline": "一句具体故事线，60字以内，体现主角和视觉推进",')
      ..writeln('  "content": "一段完整中文概述，说明故事板讲了什么，包含连续的场景、神态、动作、运动趋势和情绪",')
      ..writeln('  "scenes": "用顿号分隔的具体场景/地点",')
      ..writeln('  "props": "用顿号分隔的关键道具和视觉元素"')
      ..writeln('}')
      ..writeln()
      ..writeln('逐图内容：');
    for (var i = 0; i < analyses.length; i++) {
      final item = analyses[i];
      buffer
        ..writeln('${i + 1}. ${item.caption}')
        ..writeln('详细：${item.detail}')
        ..writeln('场景：${item.scene}')
        ..writeln('道具：${item.props}')
        ..writeln('人物动作：${item.people}')
        ..writeln('神态情绪：${item.expression}')
        ..writeln('姿态动作：${item.bodyAction}')
        ..writeln('运动趋势：${item.movementTrend}')
        ..writeln('景别：${item.shotSize}')
        ..writeln('构图：${item.composition}')
        ..writeln('主体朝向：${item.subjectDirection}')
        ..writeln('视线方向：${item.gazeDirection}')
        ..writeln('动作阶段：${item.actionStage}')
        ..writeln('空间关系：${item.spatialRelation}')
        ..writeln('进度线索：${item.chronologyCue}')
        ..writeln('机位角度：${item.cameraAngle}')
        ..writeln('视觉焦点：${item.visualFocus}')
        ..writeln('光线情绪：${item.lightingMood}')
        ..writeln('色彩调性：${item.colorPalette}')
        ..writeln('叙事功能：${item.narrativeFunction}')
        ..writeln('剪辑承接：${item.transitionHint}')
        ..writeln();
    }
    return buffer.toString();
  }

  String _videoDimensionPrompt(
    List<VisionImageAnalysis> analyses,
    Map<String, String> summary,
  ) {
    final buffer = StringBuffer()
      ..writeln('你是一名资深短视频广告策略师、剪辑导演和转化分析师。')
      ..writeln('请基于下面可见的逐镜头事实，完成整条参考视频的多维度专业拆解。')
      ..writeln('只返回一个扁平 JSON 对象，不要 Markdown，不要解释，不要新增字段。')
      ..writeln('不得编造画面中不存在的产品、品牌、价格、福利、证明、评论或 CTA；无法确认时明确写“未在可见画面中确认”。')
      ..writeln(
        '每个字段必须按三行返回："证据：…\\n商业作用：…\\n优化建议：…"。即使某项未确认，也要保留三行并说明原因；不要只写“吸引用户、节奏较快、画面高级”等空泛结论。',
      )
      ..writeln('如果某项只依赖音频、字幕、落地页或视频比例而当前输入没有事实，必须明确标记未确认，不要用行业常识代替证据。')
      ..writeln('JSON 必须包含以下全部字段，键名必须完全一致：')
      ..writeln(videoAnalysisDimensionFields.join('、'))
      ..writeln('JSON 示例结构（每个值都要换成真实分析）：');
    buffer.writeln('{');
    for (var index = 0; index < videoAnalysisDimensionFields.length; index++) {
      final field = videoAnalysisDimensionFields[index];
      final comma = index == videoAnalysisDimensionFields.length - 1 ? '' : ',';
      buffer.writeln(
        '  "$field": "证据：可见画面事实\\n商业作用：该事实对留存、理解或转化的作用\\n优化建议：可执行的优化方向"$comma',
      );
    }
    buffer
      ..writeln('}')
      ..writeln('视频级已有摘要：')
      ..writeln('大纲：${summary['outline'] ?? ''}')
      ..writeln('内容：${summary['content'] ?? ''}')
      ..writeln('逐镜头事实：');
    for (var index = 0; index < analyses.length; index++) {
      final item = analyses[index];
      buffer
        ..writeln('镜头 ${index + 1}：${item.caption}')
        ..writeln('场景/人物/动作：${item.scene}；${item.people}；${item.bodyAction}')
        ..writeln('道具/产品：${item.props}')
        ..writeln(
          '景别/运镜/构图：${item.shotSize}；${item.cameraMovement}；${item.composition}',
        )
        ..writeln(
          '焦点/光色/功能：${item.visualFocus}；${item.lightingMood}；${item.colorPalette}；${item.narrativeFunction}',
        );
    }
    return buffer.toString();
  }

  List<File> _selectShotMotionFiles(List<File> imageFiles) {
    if (imageFiles.length <= 3) {
      return imageFiles;
    }
    return [
      imageFiles.first,
      imageFiles[imageFiles.length ~/ 2],
      imageFiles.last,
    ];
  }

  List<VisionImageAnalysis> _selectShotMotionAnalyses(
    List<VisionImageAnalysis> analyses,
  ) {
    if (analyses.length <= 3) {
      return analyses;
    }
    return [analyses.first, analyses[analyses.length ~/ 2], analyses.last];
  }

  String _shotGroupAnalysisPrompt({
    required int shotNumber,
    required int frameCount,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
    bool allowSlowMotion = false,
  }) {
    final directorContext = _directorContext(
      creativeBrief: creativeBrief,
      storyContext: storyContext,
      neighboringCameraPlan: neighboringCameraPlan,
    );
    return '''
你正在为第 $shotNumber 个连续镜头组完成一次性多帧视觉解析和导演式运镜设计。
本次请求按时间顺序提供 $frameCount 张图片；两张时为首帧、尾帧，三张或更多时为首帧、中间帧、尾帧的完整时间序列。
必须同时对比全部图片后再判断主体动作、空间连续性、构图变化和运镜，不要把它们当成互不相关的独立分镜。
$_cameraMovementGuide
$_professionalCameraPlanningGuide
${_playbackSpeedRule(allowSlowMotion)}
$directorContext
$_narrativeStyleExecutionGuide

多帧连续动作契约（最高优先级）：
1. 全部图片默认是同一物理镜头内按时间排序的阶段抽帧，不是各自独立的分镜或新镜头首帧；除非剧情描述明确要求不同景别切换/切镜，才能判定为多镜头。
2. 逐帧建立同一条动作状态链：前一帧结束姿态就是后一帧动作起点；保持运动方向、重心转移、肢体相位、视线、表情发展、道具接触和空间位置连续。
3. 禁止每帧重新开始同一动作、倒退到早期姿态、重复抬腿/伸手/转头，或用“切换到下一张构图”掩盖不连续；caption/detail/body_action/movement_trend/action_stage 必须体现不可逆的阶段推进。
4. designed_camera_movement 必须是一条跨越全部阶段帧的连续路径，摄影机跟随主体趋势并自然抵达尾帧构图；不得按 Picture/帧编号重启运镜。
5. 若景别或主体尺度变化可由主体靠近/远离、摄影机连续推拉/升降/摇移解释，优先解释为镜内连续变化，不得擅自切镜。

返回一个 JSON 对象，不要 Markdown，不要解释。
frames 数组必须严格按输入图片顺序返回 $frameCount 项，每项必须包含：
caption, detail, scene, props, people, expression, body_action, movement_trend,
sound_design,
shot_size, composition, subject_direction, gaze_direction, action_stage,
spatial_relation, chronology_cue, camera_angle, visual_focus, lighting_mood,
color_palette, narrative_function, transition_hint, continues_from_previous,
continues_to_next。

motion 对象必须综合全部帧，包含：
is_same_shot, observed_camera_movement, designed_camera_movement,
camera_purpose, speed_curve, start_composition, end_composition, focus_path,
transition_execution, camera_angle, evidence。

designed_camera_movement 要写清起始状态、主路径与幅度、速度变化和结束落点；先用 observed_camera_movement 记录多帧可证实的原始运镜。
每个 frame 的 sound_design 必须根据该动作阶段写清可听事件与触发动作；跨帧动作按图片顺序连续安排，所有音效按真实时间速度逐次贴合画面，保持自然音高和正常瞬态，禁止慢放、时间拉伸、低沉变调、拖尾或过长混响，不写对白或背景音乐。
对同一镜头，背景、场景、主体身份和空间关系应连续；只有可见内容突然切换时才将 is_same_shot 设为 false。

JSON 结构：
下方 frames 内容只示意单项字段；实际返回时必须按图片顺序重复为 $frameCount 项，不得少项。
{
  "frames": [
    {"caption":"", "detail":"", "scene":"", "props":"", "people":"", "expression":"", "body_action":"", "movement_trend":"", "sound_design":"", "shot_size":"", "composition":"", "subject_direction":"", "gaze_direction":"", "action_stage":"", "spatial_relation":"", "chronology_cue":"", "camera_angle":"", "visual_focus":"", "lighting_mood":"", "color_palette":"", "narrative_function":"", "transition_hint":"", "continues_from_previous":false, "continues_to_next":true}
  ],
  "motion": {"is_same_shot":true, "observed_camera_movement":"", "designed_camera_movement":"", "camera_purpose":"", "speed_curve":"", "start_composition":"", "end_composition":"", "focus_path":"", "transition_execution":"", "camera_angle":"", "evidence":""}
}
''';
  }

  String _shotMotionPrompt({
    required int shotNumber,
    required List<VisionImageAnalysis> analyses,
    String creativeBrief = '',
    String storyContext = '',
    String neighboringCameraPlan = '',
    bool allowSlowMotion = false,
  }) {
    final directorContext = _directorContext(
      creativeBrief: creativeBrief,
      storyContext: storyContext,
      neighboringCameraPlan: neighboringCameraPlan,
    );
    final buffer = StringBuffer()
      ..writeln('你正在为第 $shotNumber 个连续镜头组完成“原始运镜复核 + 导演式最终运镜设计”。')
      ..writeln('本次按时间顺序提供同一候选镜头组的首帧、中间帧、尾帧；如果只有两帧，则为首帧和尾帧。')
      ..writeln(
        '核心规则：同一镜头通常背景、场景、主体身份和空间关系连续，背景不变或变化很少；这时必须把多帧作为一个连续镜头判断运镜，不要逐帧孤立猜测。',
      )
      ..writeln('如果背景/场景/主体突然切换，才判定不是同一镜头，并在 evidence 说明切换证据。')
      ..writeln(_cameraMovementGuide)
      ..writeln(_professionalCameraPlanningGuide)
      ..writeln(_playbackSpeedRule(allowSlowMotion))
      ..writeln(directorContext)
      ..writeln(_narrativeStyleExecutionGuide)
      ..writeln(
        '先用 observed_camera_movement 忠实记录多帧证据，再用 designed_camera_movement 输出最终方案。',
      )
      ..writeln('最终方案必须服务当前镜头的叙事功能和内容类型，写清起势、路径、幅度、速度曲线与落点；大胆但可执行，不得机械复制原始运镜。')
      ..writeln(
        '全部阶段帧必须形成同一条不可逆动作状态链：后一帧从前一帧结束姿态继续，保持方向、肢体相位、视线、表情、道具接触和空间位置连续；不得逐帧重启或重复动作。',
      )
      ..writeln('检查相邻镜头计划，避免连续重复固定、轻推或同方向平移。固定只能是有明确画内调度和视觉目的的主动选择。')
      ..writeln('必须特别区分：')
      ..writeln('A. 画面从腰部/下半身上移到上半身/脸部，背景基本连续，这是升降或上摇，不是推。')
      ..writeln('B. 只有主体和背景整体同步变大、透视或空间纵深支持摄影机靠近，才是推。')
      ..writeln('C. 主体在空间里移动且镜头保持距离，才是跟/正跟随/倒跟随。')
      ..writeln(
        '只返回一个 JSON 对象，不要 Markdown，不要解释。所有字段值必须是字符串，is_same_shot 返回 true 或 false。',
      )
      ..writeln('JSON 字段：')
      ..writeln('{')
      ..writeln('  "is_same_shot": "true 或 false",')
      ..writeln(
        '  "observed_camera_movement": "参考多帧可证实的原始运镜；只能从固定、推、拉、摇、移、跟、环绕、升降、正跟随、倒跟随、手持、平移、摇移中选择一个；无法判断写空字符串",',
      )
      ..writeln(
        '  "designed_camera_movement": "导演式最终运镜，写清起始状态、主路径和幅度、速度变化、结束落点",',
      )
      ..writeln('  "camera_purpose": "唯一核心叙事目的",')
      ..writeln('  "speed_curve": "可执行的速度曲线",')
      ..writeln('  "start_composition": "开始景别、机位、主体位置和空间层次",')
      ..writeln('  "end_composition": "结束景别、机位、主体位置和视觉落点",')
      ..writeln('  "focus_path": "注意力或焦点从哪里转移到哪里",')
      ..writeln('  "transition_execution": "承上启下的具体剪辑衔接执行",')
      ..writeln(
        '  "camera_angle": "组级机位角度，例如眼平、低角度仰拍、俯视、轻微上摇到眼平、过肩；无法判断时写不明显",',
      )
      ..writeln('  "evidence": "用一句中文说明首帧到尾帧的背景连续性、画面中心/边缘参照物、主体尺度和构图裁切变化"')
      ..writeln('}')
      ..writeln()
      ..writeln('候选镜头组逐帧事实：');
    for (var index = 0; index < analyses.length; index++) {
      final item = analyses[index];
      buffer
        ..writeln('帧 ${index + 1}：${_emptyAsNone(item.caption)}')
        ..writeln('详细：${_emptyAsNone(item.detail)}')
        ..writeln(
          '场景/主体/动作：${_emptyAsNone(item.scene)}；${_emptyAsNone(item.people)}；${_emptyAsNone(item.bodyAction)}',
        )
        ..writeln(
          '趋势/景别/构图：${_emptyAsNone(item.movementTrend)}；${_emptyAsNone(item.shotSize)}；${_emptyAsNone(item.composition)}',
        )
        ..writeln(
          '逐帧原运镜/机位：${_emptyAsNone(item.cameraMovement)}；${_emptyAsNone(item.cameraAngle)}',
        )
        ..writeln();
    }
    return buffer.toString();
  }

  static String _directorContext({
    required String creativeBrief,
    required String storyContext,
    String neighboringCameraPlan = '',
  }) {
    final parts = <String>[
      if (creativeBrief.trim().isNotEmpty)
        '已选镜头叙事风格执行契约（强制）：\n${creativeBrief.trim()}',
      if (storyContext.trim().isNotEmpty) '全局故事与当前镜头位置：${storyContext.trim()}',
      if (neighboringCameraPlan.trim().isNotEmpty)
        '相邻镜头已采用的运镜：${neighboringCameraPlan.trim()}',
    ];
    return parts.isEmpty ? '创作方向：通用电影化叙事，运镜必须服务镜头功能。' : parts.join('\n');
  }

  String _orderPrompt(List<VisionImageAnalysis> analyses) {
    final buffer = StringBuffer()
      ..writeln('请根据以下逐图视觉解析结果，判断故事板镜头最自然、最连贯的观看顺序。')
      ..writeln('只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。')
      ..writeln('必须返回 order 数组，数组内容是原始图片编号，使用 1 到 ${analyses.length} 的整数。')
      ..writeln('order 必须包含每一张图片且只能出现一次，不能新增、删除或重复编号。')
      ..writeln('请像专业分镜师一样校正当前顺序，优先依据可见信息，不要按文件名机械排序。')
      ..writeln('称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。')
      ..writeln(
        '导演式判断：优先使用逐图的叙事功能、视觉焦点和剪辑承接来标注每张图的镜头功能，例如建立、推进、揭示、证明、反应、转折、结果、收束或广告产品记忆点；最终只返回 order。',
      )
      ..writeln('每张图都要回答“它让画面状态改变了什么”：从初始状态，到可见动作或信息揭示，再到改变后的状态。')
      ..writeln(
        '当前 1 到 ${analyses.length} 的顺序已经是一个候选故事板；你的任务是校正明显错位，而不是从零重新编排。',
      )
      ..writeln('保守模式：默认输出原顺序 [1, 2, ...]；只有发现明确错位时，才返回不同顺序。')
      ..writeln('如果图片更像同一人物、产品或场景的写真/展示图，而不是连续动作故事板，必须保持原顺序。')
      ..writeln('重排序不是重新编故事：只有在画面里有明确动作因果、空间连续、视线承接或收束线索时才移动图片。')
      ..writeln('采用最小改动原则：证据不足时保留原相对顺序；如果当前顺序已经合理，直接返回 [1, 2, ...]。')
      ..writeln('不要为了满足景别变化、情绪起伏或抽象主题而跨段搬动图片；避免把照片组重新编成不存在的剧情。')
      ..writeln('排序规则按优先级执行：')
      ..writeln('1. 先找建立镜头：远景/全景/空镜、场景交代、主体尚未动作的画面通常靠前。')
      ..writeln(
        '2. 再按动作阶段推进：准备 -> 进行 -> 反应/转折 -> 结果 -> 收束；起身、转身、靠近、接触、离开要形成因果。',
      )
      ..writeln('3. 保持人物朝向、视线方向和运动方向的连续性：看向某物通常在目标或反应镜头前后形成关系。')
      ..writeln('4. 保持空间关系连续：同一场景、相邻位置、靠近/远离关系优先连在一起，场景切换需要有转场或结果线索。')
      ..writeln('5. 使用景别推进辅助判断，但景别不是时间线：特写/大特写可作为中段细节、材质证明、情绪反应或信息揭示，不天然等于结尾。')
      ..writeln('6. 使用情绪和道具线索补充判断：情绪从平静到紧张再到缓和，道具从出现、被注意、被使用到产生结果。')
      ..writeln('7. 使用机位、光色和视觉焦点判断节奏：同一功能的镜头不要堆在一起，插入细节后要回到人物动作、产品结果或关系变化。')
      ..writeln('8. 对同一人物、同一风格但缺少明确剧情因果的照片组，应优先维持局部连续，不要跨场景来回穿插。')
      ..writeln(
        '9. 选择最后一张前先判断完成端点：剧情结尾应落在可见结果、关系变化、离开、停顿、回望或余韵；仍在进行中的行走/动作通常不应作为最终镜头。',
      )
      ..writeln(
        '10. 如果是产品、品牌或广告画面，结尾优先选择使用结果、利益被证明、产品三分之二英雄角度、包装/Logo清晰或明确 end-card/packshot，而不是默认脸部或局部特写。',
      )
      ..writeln(
        '11. 如果最后候选是特写，但它只是细节插入、反应、动作中或信息铺垫，应把它放在对应动作/结果之前；只有承担结果、记忆点或余韵时才适合收尾。',
      )
      ..writeln('如果规则冲突，优先可见动作因果，其次空间连续，其次完成端点，其次景别推进；仍无法判断时才返回原顺序。')
      ..writeln('JSON 字段：')
      ..writeln('{')
      ..writeln('  "order": [1, 2, 3]')
      ..writeln('}')
      ..writeln()
      ..writeln('逐图内容：');
    for (var i = 0; i < analyses.length; i++) {
      final item = analyses[i];
      buffer
        ..writeln('${i + 1}. caption：${item.caption}')
        ..writeln('详细：${item.detail}')
        ..writeln('场景：${item.scene}')
        ..writeln('道具：${item.props}')
        ..writeln('人物动作：${item.people}')
        ..writeln('神态情绪：${item.expression}')
        ..writeln('姿态动作：${item.bodyAction}')
        ..writeln('运动趋势：${item.movementTrend}')
        ..writeln('景别：${item.shotSize}')
        ..writeln('构图：${item.composition}')
        ..writeln('主体朝向：${item.subjectDirection}')
        ..writeln('视线方向：${item.gazeDirection}')
        ..writeln('动作阶段：${item.actionStage}')
        ..writeln('空间关系：${item.spatialRelation}')
        ..writeln('进度线索：${item.chronologyCue}')
        ..writeln('机位角度：${item.cameraAngle}')
        ..writeln('视觉焦点：${item.visualFocus}')
        ..writeln('光线情绪：${item.lightingMood}')
        ..writeln('色彩调性：${item.colorPalette}')
        ..writeln('叙事功能：${item.narrativeFunction}')
        ..writeln('剪辑承接：${item.transitionHint}')
        ..writeln();
    }
    return buffer.toString();
  }

  String _imageEditSuggestionPrompt({
    required int sequenceNo,
    required int rowIndex,
    required int columnIndex,
    required String currentCaption,
    required String previousCaption,
    required String nextCaption,
    required String rowCaption,
    required String storyboardSummary,
    required VisionImageAnalysis currentAnalysis,
    required VisionImageAnalysis? previousAnalysis,
    required VisionImageAnalysis? nextAnalysis,
    required List<VisionImageAnalysis> storyboardAnalyses,
  }) {
    return '''
你是一名专业分镜导演和 AI 图片修改提示词设计师。
请结合当前图片、前后镜头、全局故事板摘要和逐图多维度视觉解析，判断这张分镜最值得优化的地方，并给出可直接用于图生图/图片修改模型的中文提示词。

上下文：
- 当前图片序号：第 $sequenceNo 张
- 当前宫格位置：第 ${rowIndex + 1} 行、第 ${columnIndex + 1} 列
- 当前格文字：${_emptyAsNone(currentCaption)}
- 前一格文字：${_emptyAsNone(previousCaption)}
- 后一格文字：${_emptyAsNone(nextCaption)}
- 当前行描述：${_emptyAsNone(rowCaption)}
- 故事板概述：${_emptyAsNone(storyboardSummary)}

当前分镜多维解析：
${_imageEditAnalysisBlock(currentAnalysis)}

前一分镜多维解析：
${_nullableImageEditAnalysisBlock(previousAnalysis)}

后一分镜多维解析：
${_nullableImageEditAnalysisBlock(nextAnalysis)}

全局逐图解析：
${_storyboardAnalysisList(storyboardAnalyses)}

综合设计要求：
1. 先从全局故事顺序判断当前分镜承担的叙事功能：建立、推进、反应、转折、结果或收束。
2. 再结合当前图片可见内容，选择一个最值得优化的方向，不要同时提出互相冲突的改动。
3. 镜头角度、景别、构图、人物朝向、视线方向、神态、姿态、动作阶段、运动趋势、空间关系、道具、服装、场景和光线必须与前后镜头连续。
4. 提示词必须明确保留原图主体、身份、核心场景、构图关系和故事连续性，只强化必要的画面信息。
5. 不要编造图片里没有依据的新角色、新剧情或大幅改变场景；不要输出无关参数。
6. 称呼规范：成年女性统一称为“女模特”，成年男性统一称为“男模特”，不要使用“女子”“男子”。

只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。
JSON 字段：
{
  "advice": "给用户看的中文修改建议，说明应该优化哪些点，100字以内",
  "prompt": "给图片生成 API 的中文修改提示词，120到260字；必须明确保留原图主体、角色身份、场景和整体连续性，并说明具体要修改或强化的镜头角度、人物状态、道具、服装、光线、构图或动作承接；不要写无关参数"
}
''';
  }

  String _nullableImageEditAnalysisBlock(VisionImageAnalysis? analysis) {
    if (analysis == null) {
      return '无';
    }
    return _imageEditAnalysisBlock(analysis);
  }

  String _imageEditAnalysisBlock(VisionImageAnalysis analysis) {
    return [
      '画面短句：${_emptyAsNone(analysis.caption)}',
      '详细描述：${_emptyAsNone(analysis.detail)}',
      '场景：${_emptyAsNone(analysis.scene)}',
      '道具：${_emptyAsNone(analysis.props)}',
      '人物动作：${_emptyAsNone(analysis.people)}',
      '神态情绪：${_emptyAsNone(analysis.expression)}',
      '姿态动作：${_emptyAsNone(analysis.bodyAction)}',
      '运动趋势：${_emptyAsNone(analysis.movementTrend)}',
      '景别：${_emptyAsNone(analysis.shotSize)}',
      '构图：${_emptyAsNone(analysis.composition)}',
      '主体朝向：${_emptyAsNone(analysis.subjectDirection)}',
      '视线方向：${_emptyAsNone(analysis.gazeDirection)}',
      '动作阶段：${_emptyAsNone(analysis.actionStage)}',
      '空间关系：${_emptyAsNone(analysis.spatialRelation)}',
      '进度线索：${_emptyAsNone(analysis.chronologyCue)}',
      '机位角度：${_emptyAsNone(analysis.cameraAngle)}',
      '视觉焦点：${_emptyAsNone(analysis.visualFocus)}',
      '光线情绪：${_emptyAsNone(analysis.lightingMood)}',
      '色彩调性：${_emptyAsNone(analysis.colorPalette)}',
      '叙事功能：${_emptyAsNone(analysis.narrativeFunction)}',
      '剪辑承接：${_emptyAsNone(analysis.transitionHint)}',
    ].join('\n');
  }

  String _storyboardAnalysisList(List<VisionImageAnalysis> analyses) {
    if (analyses.isEmpty) {
      return '无';
    }
    final buffer = StringBuffer();
    for (var i = 0; i < analyses.length; i++) {
      buffer
        ..writeln('${i + 1}. ${_emptyAsNone(analyses[i].caption)}')
        ..writeln('   详细：${_emptyAsNone(analyses[i].detail)}')
        ..writeln(
          '   场景/道具：${_emptyAsNone(analyses[i].scene)}；${_emptyAsNone(analyses[i].props)}',
        )
        ..writeln(
          '   人物/神态/动作：${_emptyAsNone(analyses[i].people)}；${_emptyAsNone(analyses[i].expression)}；${_emptyAsNone(analyses[i].bodyAction)}',
        )
        ..writeln(
          '   镜头/构图/方向：${_emptyAsNone(analyses[i].shotSize)}；${_emptyAsNone(analyses[i].composition)}；${_emptyAsNone(analyses[i].subjectDirection)}；${_emptyAsNone(analyses[i].gazeDirection)}',
        )
        ..writeln(
          '   连续性：${_emptyAsNone(analyses[i].movementTrend)}；${_emptyAsNone(analyses[i].actionStage)}；${_emptyAsNone(analyses[i].spatialRelation)}；${_emptyAsNone(analyses[i].chronologyCue)}',
        )
        ..writeln(
          '   导演/光色/剪辑：${_emptyAsNone(analyses[i].cameraAngle)}；${_emptyAsNone(analyses[i].visualFocus)}；${_emptyAsNone(analyses[i].lightingMood)}；${_emptyAsNone(analyses[i].colorPalette)}；${_emptyAsNone(analyses[i].narrativeFunction)}；${_emptyAsNone(analyses[i].transitionHint)}',
        );
    }
    return buffer.toString().trimRight();
  }

  String _emptyAsNone(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? '无' : normalizeVisionModelRoleTerms(trimmed);
  }

  Map<String, dynamic> _extractJsonObject(String text) {
    final trimmed = text.trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // 继续尝试从模型解释文本中提取 JSON 对象。
    }
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('视觉模型未返回可解析的 JSON');
    }
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const FormatException('视觉模型 JSON 格式异常');
  }

  String _stringValue(Map<String, dynamic> json, String key) {
    return _coerceTextValue(json[key]);
  }

  String _coerceTextValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is List) {
      return value
          .map(_coerceTextValue)
          .where((item) => item.isNotEmpty)
          .join('、')
          .trim();
    }
    if (value is Map) {
      for (final key in const ['text', 'caption', 'name', 'value']) {
        final preferred = _coerceTextValue(value[key]);
        if (preferred.isNotEmpty) {
          return preferred;
        }
      }
      return value.values
          .map(_coerceTextValue)
          .where((item) => item.isNotEmpty)
          .join('、')
          .trim();
    }
    return normalizeVisionModelRoleTerms(value.toString().trim());
  }

  String _firstStringValue(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = _stringValue(json, key);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  bool _boolValue(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is bool) return value;
      final normalized = '$value'.trim().toLowerCase();
      if (const {'true', '1', 'yes', '是', '连续', '承接'}.contains(normalized)) {
        return true;
      }
      if (const {'false', '0', 'no', '否', '不连续', '不承接'}.contains(normalized)) {
        return false;
      }
    }
    return false;
  }

  List<int> _orderListValue(Map<String, dynamic> json, int expectedCount) {
    final value = _findOrderValue(json);
    final items = switch (value) {
      List list => list,
      String text => _numbersFromText(text),
      _ => null,
    };
    if (items == null) {
      throw const FormatException('视觉模型未返回 order 数组');
    }
    final order = <int>[];
    for (final item in items) {
      final number = _orderNumberFromItem(item);
      if (number == null) {
        throw const FormatException('视觉模型 order 包含非数字编号');
      }
      order.add(number);
    }
    final normalizedOrder = _normalizeOrderNumbers(order, expectedCount);
    final repairedOrder = _repairMissingOrderNumbers(
      normalizedOrder,
      expectedCount,
    );
    final unique = repairedOrder.toSet();
    final validRange = normalizedOrder.every(
      (number) => number >= 1 && number <= expectedCount,
    );
    if (repairedOrder.length != expectedCount ||
        unique.length != expectedCount ||
        !validRange) {
      final invalidNumbers = normalizedOrder
          .where((number) => number < 1 || number > expectedCount)
          .toList();
      throw FormatException(
        '视觉模型 order 数量异常：期望 $expectedCount，实际 ${normalizedOrder.length}'
        '，唯一 ${unique.length}'
        '${invalidNumbers.isEmpty ? '' : '，无效编号 ${invalidNumbers.join(', ')}'}'
        '，解析值 ${normalizedOrder.join(', ')}',
      );
    }
    return repairedOrder;
  }

  Object? _findOrderValue(Object? value) {
    if (value is List) {
      return value;
    }
    if (value is! Map) {
      return null;
    }
    const keys = [
      'order',
      'orders',
      'sorted_order',
      'sortedOrder',
      'sequence',
      'indices',
      '排序',
    ];
    for (final key in keys) {
      if (value.containsKey(key)) {
        return value[key];
      }
    }
    const nestedKeys = ['result', 'data', 'output', 'answer', 'content'];
    for (final key in nestedKeys) {
      final nested = _findOrderValue(value[key]);
      if (nested != null) {
        return nested;
      }
    }
    if (value.length == 1) {
      return _findOrderValue(value.values.single);
    }
    return null;
  }

  int? _orderNumberFromItem(Object? item) {
    if (item is num) {
      return item.toInt();
    }
    if (item is String) {
      return _numberFromText(item);
    }
    if (item is Map) {
      const keys = [
        'index',
        'id',
        'order',
        'number',
        'no',
        'image',
        'image_no',
        'imageNo',
        'original',
        'original_index',
        'originalIndex',
      ];
      for (final key in keys) {
        final number = _orderNumberFromItem(item[key]);
        if (number != null) {
          return number;
        }
      }
      if (item.length == 1) {
        return _orderNumberFromItem(item.values.single);
      }
    }
    return null;
  }

  List<int> _normalizeOrderNumbers(List<int> order, int expectedCount) {
    final unique = order.toSet();
    final zeroBased =
        order.length == expectedCount &&
        unique.length == expectedCount &&
        order.every((number) => number >= 0 && number < expectedCount);
    if (zeroBased) {
      return [for (final number in order) number + 1];
    }
    final incompleteZeroBased =
        order.isNotEmpty &&
        order.length < expectedCount &&
        unique.length == order.length &&
        order.contains(0) &&
        !order.contains(expectedCount) &&
        order.every((number) => number >= 0 && number < expectedCount);
    if (incompleteZeroBased) {
      return [for (final number in order) number + 1];
    }
    return order;
  }

  List<int> _repairMissingOrderNumbers(List<int> order, int expectedCount) {
    final unique = order.toSet();
    final validRange = order.every(
      (number) => number >= 1 && number <= expectedCount,
    );
    if (order.length == expectedCount ||
        unique.length != order.length ||
        !validRange) {
      return order;
    }

    final missing = [
      for (var number = 1; number <= expectedCount; number++)
        if (!unique.contains(number)) number,
    ];
    if (missing.length > _maxMissingOrderRepairCount) {
      return order;
    }

    final repaired = [...order];
    for (final number in missing) {
      var inserted = false;
      for (var before = number - 1; before >= 1; before--) {
        final index = repaired.indexOf(before);
        if (index != -1) {
          repaired.insert(index + 1, number);
          inserted = true;
          break;
        }
      }
      if (inserted) {
        continue;
      }
      for (var after = number + 1; after <= expectedCount; after++) {
        final index = repaired.indexOf(after);
        if (index != -1) {
          repaired.insert(index, number);
          inserted = true;
          break;
        }
      }
      if (!inserted) {
        repaired.add(number);
      }
    }
    return repaired;
  }

  List<int> _numbersFromText(String text) {
    return [
      for (final match in RegExp(r'-?\d+').allMatches(text))
        int.parse(match.group(0)!),
    ];
  }

  int? _numberFromText(String text) {
    final trimmed = text.trim();
    final parsed = int.tryParse(trimmed);
    if (parsed != null) {
      return parsed;
    }
    final match = RegExp(r'-?\d+').firstMatch(trimmed);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(0)!);
  }

  String _compactForError(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 600) {
      return compact;
    }
    return '${compact.substring(0, 600)}...';
  }

  String _summaryValue(
    Map<String, dynamic> json,
    String key, {
    required String fallback,
    required Set<String> placeholders,
  }) {
    final value = _stringValue(json, key);
    if (value.isEmpty || _isPlaceholder(value, placeholders)) {
      return fallback;
    }
    return value;
  }

  bool _isPlaceholder(String value, Set<String> placeholders) {
    final normalized = _normalizeSummaryText(value);
    return placeholders
        .map(_normalizeSummaryText)
        .any((placeholder) => normalized == placeholder);
  }

  String _normalizeSummaryText(String value) {
    return value.replaceAll(RegExp(r'[\s:：,，.。;；、]'), '').trim();
  }

  String _fallbackOutline(List<VisionImageAnalysis> analyses) {
    return composeVisionAnalysesOutline(analyses);
  }

  String _fallbackContent(List<VisionImageAnalysis> analyses) {
    return composeVisionAnalysesDescription(analyses);
  }

  String _fallbackJoinedValues(Iterable<String> values) {
    return _uniqueNonEmptyTexts(values).join('、');
  }

  String _mimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/png';
  }
}

String composeVisionAnalysesOutline(List<VisionImageAnalysis> analyses) {
  final captions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.caption),
  ).map(_trimSentenceEnd).take(3).toList();
  if (captions.isEmpty) {
    return '';
  }
  if (captions.length == 1) {
    return _ensureChineseSentence(captions.single);
  }
  return '镜头围绕${_joinSequence(captions)}展开，形成一段连续故事。';
}

String composeVisionAnalysesDescription(List<VisionImageAnalysis> analyses) {
  final captions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.caption),
  ).map(_trimSentenceEnd).toList();
  if (captions.isEmpty) {
    return '';
  }
  final cueText = _analysisCueText(analyses);
  if (captions.length == 1) {
    return _ensureChineseSentence('${captions.single}$cueText');
  }

  final scenes = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.scene),
  ).map(_trimSentenceEnd).take(3).toList();
  final scenePrefix = scenes.isEmpty
      ? ''
      : scenes.length == 1
      ? '在${scenes.single}中，'
      : '在${_joinNames(scenes)}之间，';
  return '$scenePrefix镜头依次呈现${_joinSequence(captions)}$cueText，人物动作、视线、神态与运动趋势被连成一段完整画面。';
}

String _analysisCueText(List<VisionImageAnalysis> analyses) {
  final expressions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.expression),
  ).map(_trimSentenceEnd).take(3).toList();
  final actions = _uniqueNonEmptyTexts(
    analyses.map(
      (analysis) => analysis.bodyAction.trim().isNotEmpty
          ? analysis.bodyAction
          : analysis.people,
    ),
  ).map(_trimSentenceEnd).take(3).toList();
  final movements = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.movementTrend),
  ).map(_trimSentenceEnd).take(3).toList();
  final focuses = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.visualFocus),
  ).map(_trimSentenceEnd).take(3).toList();
  final moods = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.lightingMood),
  ).map(_trimSentenceEnd).take(2).toList();
  final functions = _uniqueNonEmptyTexts(
    analyses.map((analysis) => analysis.narrativeFunction),
  ).map(_trimSentenceEnd).take(3).toList();

  final cues = <String>[
    if (expressions.isNotEmpty) '神态聚焦${_joinNames(expressions)}',
    if (actions.isNotEmpty) '姿态动作包括${_joinSequence(actions)}',
    if (movements.isNotEmpty) '运动趋势表现为${_joinNames(movements)}',
    if (focuses.isNotEmpty) '视觉焦点落在${_joinNames(focuses)}',
    if (moods.isNotEmpty) '光线情绪呈现${_joinNames(moods)}',
    if (functions.isNotEmpty) '镜头功能形成${_joinSequence(functions)}',
  ];
  if (cues.isEmpty) {
    return '';
  }
  return '，${cues.join('，')}';
}

Iterable<String> _uniqueNonEmptyTexts(Iterable<String> values) sync* {
  final seen = <String>{};
  for (final value in values) {
    final trimmed = normalizeVisionModelRoleTerms(value.trim());
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    yield trimmed;
  }
}

String _trimSentenceEnd(String value) {
  return value.replaceAll(RegExp(r'[\s。！？!?；;，,、]+$'), '').trim();
}

String normalizeVisionModelRoleTerms(String value) {
  return value.replaceAll('女子', '女模特').replaceAll('男子', '男模特');
}

String _ensureChineseSentence(String value) {
  final trimmed = _trimSentenceEnd(value);
  return trimmed.isEmpty ? '' : '$trimmed。';
}

String _joinSequence(List<String> values) {
  if (values.length == 1) {
    return values.single;
  }
  if (values.length == 2) {
    return '${values.first}，并过渡到${values.last}';
  }
  return '${values.take(values.length - 1).join('、')}，并过渡到${values.last}';
}

String _joinNames(List<String> values) {
  if (values.length == 1) {
    return values.single;
  }
  if (values.length == 2) {
    return '${values.first}与${values.last}';
  }
  return '${values.take(values.length - 1).join('、')}与${values.last}';
}

Uri normalizeChatCompletionsEndpoint(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('API 地址不能为空');
  }
  final withScheme = _hasScheme(trimmed)
      ? trimmed
      : '${_defaultSchemeFor(trimmed)}://$trimmed';
  final uri = Uri.parse(withScheme);
  final path = _normalizedChatPath(uri.path);
  return uri.replace(path: path, query: null, fragment: null);
}

bool _hasScheme(String value) {
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
}

String _defaultSchemeFor(String value) {
  final host = value.split('/').first.split(':').first.toLowerCase();
  final isIpv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
  if (host == 'localhost' || host == '127.0.0.1' || isIpv4) {
    return 'http';
  }
  return 'https';
}

String _normalizedChatPath(String path) {
  final normalized = path.isEmpty ? '/' : path.replaceAll(RegExp(r'/+$'), '');
  if (normalized.endsWith('/v1/chat/completions') ||
      normalized.endsWith('/chat/completions')) {
    return normalized;
  }
  if (normalized == '/' || normalized.isEmpty) {
    return '/v1/chat/completions';
  }
  if (normalized.endsWith('/v1')) {
    return '$normalized/chat/completions';
  }
  return '$normalized/v1/chat/completions';
}

String _compressVisionImageInWorker(
  TransferableTypedData transferable,
  String sourcePath,
  String sourceMimeType,
) {
  final bytes = transferable.materialize().asUint8List();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    if (bytes.length <= VisionStoryboardService._oversizedImageThresholdBytes) {
      return 'data:$sourceMimeType;base64,${base64Encode(bytes)}';
    }
    throw FormatException('超限视觉图片无法解码压缩：$sourcePath');
  }

  if (bytes.length <= VisionStoryboardService._oversizedImageThresholdBytes &&
      decoded.width <= 1280 &&
      decoded.height <= 1280) {
    return 'data:$sourceMimeType;base64,${base64Encode(bytes)}';
  }

  var current = decoded;
  if (current.width > 1280 || current.height > 1280) {
    current = current.width >= current.height
        ? img.copyResize(current, width: 1280)
        : img.copyResize(current, height: 1280);
  }

  var quality = 84;
  var encoded = img.encodeJpg(current, quality: quality);
  while (encoded.length > VisionStoryboardService._compressedImageTargetBytes &&
      quality > 52) {
    quality -= 8;
    encoded = img.encodeJpg(current, quality: quality);
  }
  if (encoded.length > VisionStoryboardService._compressedImageTargetBytes &&
      (current.width > 960 || current.height > 960)) {
    current = current.width >= current.height
        ? img.copyResize(current, width: 960)
        : img.copyResize(current, height: 960);
    quality = 76;
    encoded = img.encodeJpg(current, quality: quality);
    while (encoded.length >
            VisionStoryboardService._compressedImageTargetBytes &&
        quality > 40) {
      quality -= 8;
      encoded = img.encodeJpg(current, quality: quality);
    }
  }

  return 'data:image/jpeg;base64,${base64Encode(encoded)}';
}
