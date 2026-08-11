import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/shooting_script/data/script_multimodal_analysis_service.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:test/test.dart';

void main() {
  test('视觉解析结果映射字段并设计音效时长运镜，但对白仍由用户填写', () {
    final patch = ScriptMultimodalAnalysisService.fromVisionAnalysis(
      VisionImageAnalysis(
        caption: '白衬衫人物走向镜头',
        detail: '人物在暖色室内从画面左侧向右前方走近',
        scene: '现代客厅',
        props: '桌面花瓶',
        people: '一名成年人',
        expression: '平静',
        bodyAction: '迈步走近',
        movementTrend: '向前',
        soundDesign: '每次鞋底落地都与画面中的落脚瞬间逐次同步，保留自然清脆的脚步瞬态',
        shotSize: '中景',
        cameraMovement: '推镜',
        composition: '主体位于画面左侧',
        subjectDirection: '向右',
        gazeDirection: '看向镜头',
        actionStage: '动作开始',
        spatialRelation: '人物在桌前',
        chronologyCue: '开场',
        cameraAngle: '平视',
        visualFocus: '人物面部',
        lightingMood: '暖光',
        colorPalette: '米白与金色',
        narrativeFunction: '建立场景',
        transitionHint: '可接近景',
        continuesFromPrevious: true,
        continuesToNext: true,
        rawResponse: '{}',
      ),
    );

    expect(patch.values['visual'], contains('白衬衫人物'));
    expect(patch.values['content'], contains('人物'));
    expect(patch.values['shotSize'], '中景');
    expect(patch.values['cameraMovement'], '推镜');
    expect(patch.values['composition'], '主体位于画面左侧');
    expect(patch.values['cameraAngle'], '平视');
    expect(patch.values['lightingMood'], '暖光');
    expect(patch.values['colorPalette'], '米白与金色');
    expect(patch.values['visualFocus'], '人物面部');
    expect(patch.values['transitionHint'], '可接近景');
    expect(patch.values['movementTrend'], '向前');
    expect(patch.values['actionStage'], '动作开始');
    expect(patch.values['continuesFromPrevious'], 'true');
    expect(patch.values['continuesToNext'], 'true');
    expect(patch.values['cameraNotes'], '参考原运镜：推镜');
    expect(patch.values.containsKey('dialogue'), isFalse);
    expect(patch.values['sound'], contains('音效设计'));
    expect(patch.values['sound'], contains('每次鞋底落地'));
    expect(patch.values['sound'], contains('真实时间速度'));
    expect(patch.values['sound'], contains('禁止慢放'));
    expect(patch.values['sound'], contains('非叙事性音乐：N/A'));
    expect(double.parse(patch.values['durationSeconds']!), 6);
    expect(patch.values.containsKey('productCode'), isFalse);
    expect(patch.fieldConfidence['content'], greaterThan(0.8));
    expect(patch.promptContext.subject['people'], '一名成年人');
    expect(patch.promptContext.subject['expression'], '平静');
    expect(patch.promptContext.action['bodyAction'], '迈步走近');
    expect(patch.promptContext.scene['subjectDirection'], '向右');
    expect(patch.promptContext.scene['gazeDirection'], '看向镜头');
    expect(patch.promptContext.scene['spatialRelation'], '人物在桌前');
    expect(patch.promptContext.camera['cameraMovement'], '推镜');
    expect(patch.promptContext.camera['visualFocus'], '人物面部');
    expect(patch.promptContext.visualStyle['lightingMood'], '暖光');
    expect(patch.promptContext.continuity['narrativeFunction'], '建立场景');
    expect(patch.promptContext.continuity['continuesFromPrevious'], 'true');
    expect(patch.promptContext.audio['sound'], contains('每次鞋底落地'));
  });

  test('色彩字段只保留整体调色风格并剥离服装配饰对象颜色', () {
    final cleaned = ScriptMultimodalAnalysisService.colorStyleFromPaletteText(
      '暖米灰石墙融合为底，深棕皮革、棕白条纹衣袖、肤色与银饰点缀，整体低饱和大地色系；'
      '黑白条纹与米白长裤的暖中性色调，黑色铁艺提供沉稳深色对比',
    );

    expect(cleaned, contains('低饱和大地色系'));
    expect(cleaned, contains('暖中性色调'));
    expect(cleaned, isNot(contains('皮革')));
    expect(cleaned, isNot(contains('衣袖')));
    expect(cleaned, isNot(contains('长裤')));
    expect(cleaned, isNot(contains('肤色')));
    expect(cleaned, isNot(contains('银饰')));
    expect(cleaned, isNot(contains('铁艺')));
    expect(cleaned, isNot(contains('条纹')));
  });

  test('视觉解析写入拍摄脚本时净化色彩列', () {
    final patch = ScriptMultimodalAnalysisService.fromVisionAnalysis(
      VisionImageAnalysis(
        caption: '女模特站在复古石墙前',
        detail: '女模特穿着皮夹克和长裤，站在暖灰石墙前。',
        scene: '复古石墙前',
        props: '铁艺栏杆',
        people: '女模特站立',
        expression: '平静',
        bodyAction: '站立',
        movementTrend: '静止不明显',
        shotSize: '中景',
        composition: '主体居中',
        subjectDirection: '正面',
        gazeDirection: '看向镜头',
        actionStage: '静态',
        spatialRelation: '人物位于墙前',
        chronologyCue: '静态展示',
        colorPalette: '暖灰石墙为底，搭配深棕皮革、黑白条纹与米白长裤的暖中性色调',
        rawResponse: '{}',
      ),
    );

    expect(patch.values['colorPalette'], contains('暖中性色调'));
    expect(patch.values['colorPalette'], isNot(contains('皮革')));
    expect(patch.values['colorPalette'], isNot(contains('长裤')));
    expect(patch.values['colorPalette'], isNot(contains('条纹')));
    expect(patch.values['colorPalette'], isNot(contains('石墙')));
  });

  test('兼容读取旧版复合摄影备注并拆分到独立视觉字段', () {
    final fields = ScriptShotVisualFields.fromLegacyCameraNotes(
      '构图：主体居中略偏右；机位：平视角度；光影：自然漫射光；'
      '色彩：暖橙色与绿色；视觉焦点：人物面部；衔接：适合作为中段插入',
    );

    expect(fields.composition, '主体居中略偏右');
    expect(fields.cameraAngle, '平视角度');
    expect(fields.lightingMood, '自然漫射光');
    expect(fields.colorPalette, '暖橙色与绿色');
    expect(fields.visualFocus, '人物面部');
    expect(fields.transitionHint, '适合作为中段插入');
    expect(fields.cameraNotes, isEmpty);
  });

  test('空运镜兜底优先识别垂直构图变化而不是默认推镜', () {
    final patch = ScriptMultimodalAnalysisService.fromVisionAnalysis(
      VisionImageAnalysis(
        caption: '镜头从腰部抬到上半身',
        detail: '女模特站在墙边，画面从腰部位置抬升到上半身和脸部。',
        scene: '复古砖墙前',
        props: '砖墙',
        people: '女模特站立',
        expression: '平静看向镜头',
        bodyAction: '保持站立，手部抬起',
        movementTrend: '画面重心向上抬升',
        shotSize: '中近景',
        composition: '从下半身构图过渡到上半身构图',
        subjectDirection: '正面看向镜头',
        gazeDirection: '看向镜头',
        actionStage: '进行',
        spatialRelation: '女模特站在墙边',
        chronologyCue: '动作中',
        visualFocus: '上半身与面部',
        rawResponse: '{}',
      ),
    );

    expect(patch.values['cameraMovement'], contains('垂直升降'));
    expect(patch.values['cameraMovement'], isNot(contains('推近')));
    expect(patch.fieldConfidence['cameraMovement'], 0.62);
  });

  test('空运镜且证据不足时生成有起势路径落点的导演方案而非固定兜底', () {
    final patch = ScriptMultimodalAnalysisService.fromVisionAnalysis(
      VisionImageAnalysis(
        caption: '人物安静站在室内',
        detail: '人物站在室内，画面没有明确移动证据。',
        scene: '室内',
        props: '',
        people: '人物站立',
        expression: '平静',
        bodyAction: '站立',
        movementTrend: '静止不明显',
        shotSize: '中景',
        composition: '主体居中',
        subjectDirection: '正面',
        gazeDirection: '不明显',
        actionStage: '静态',
        spatialRelation: '人物位于房间中央',
        chronologyCue: '不明显',
        rawResponse: '{}',
      ),
    );

    expect(patch.values['cameraMovement'], contains('起势'));
    expect(patch.values['cameraMovement'], contains('最终'));
    expect(patch.values['cameraMovement'], isNot(contains('固定镜头')));
  });

  test('组级解析在原时长为零时按画面动作和运镜写入合理时长', () {
    final patch = ScriptMultimodalAnalysisService.fromShotGroupAnalysis(
      shots: [_shot('shot-1', 1, 0), _shot('shot-2', 2, 0)],
      analyses: [
        VisionImageAnalysis(
          caption: '暖光室内人物抬手',
          detail: '人物在暖色室内开始抬手展示产品',
          scene: '现代客厅',
          props: '产品瓶',
          people: '一名成年人',
          expression: '平静',
          bodyAction: '0-2秒：抬手展示',
          movementTrend: '向上',
          soundDesign: '手掌接触产品瓶时出现一次短促自然的材质触碰声',
          shotSize: '中景',
          composition: '主体居中',
          subjectDirection: '正面',
          gazeDirection: '看向镜头',
          actionStage: '开始',
          spatialRelation: '人物在桌前',
          chronologyCue: '开场',
          lightingMood: '暖光柔和',
          rawResponse: '{}',
        ),
        VisionImageAnalysis(
          caption: '暖光室内人物完成展示',
          detail: '人物在暖色室内完成产品展示',
          scene: '现代客厅',
          props: '产品瓶',
          people: '一名成年人',
          expression: '平静',
          bodyAction: '完成展示',
          movementTrend: '完成',
          soundDesign: '产品瓶稳定落位时出现一次轻微接触声，随后立即停止',
          shotSize: '近景',
          composition: '产品靠近画面中心',
          subjectDirection: '正面',
          gazeDirection: '看向镜头',
          actionStage: '完成',
          spatialRelation: '人物在桌前',
          chronologyCue: '收束',
          lightingMood: '暖光柔和',
          rawResponse: '{}',
        ),
      ],
      motion: const VisionShotMotionAnalysis(
        isSameShot: true,
        cameraMovement: '升降',
        designedCameraMovement: '从手部特写起势，垂直升降到产品正面，前快后慢并锁定瓶身高光',
        cameraPurpose: '建立产品记忆点',
        speedCurve: '短促起势—匀速上升—末段缓停',
        startComposition: '手部近景位于画面下方',
        endComposition: '产品正面特写居中',
        focusPath: '从手部动作转移到产品瓶身',
        transitionExecution: '承接抬手动作，产品居中后切下个镜头',
        cameraAngle: '轻微上摇到眼平',
        evidence: '背景连续，画面从手部上移到产品中心',
        rawResponse: '{}',
      ),
    );

    expect(patch.values['durationSeconds'], '6.0');
    expect(patch.values['sound'], contains('开始：手掌接触产品瓶'));
    expect(patch.values['sound'], contains('完成：产品瓶稳定落位'));
    expect(patch.values['sound'], contains('真实时间速度'));
    expect(patch.values['sound'], contains('禁止慢放'));
    expect(patch.values['sound'], contains('非叙事性音乐：N/A'));
    expect(patch.promptContext.action['bodyAction'], contains('抬手展示'));
    expect(patch.promptContext.action['bodyAction'], isNot(contains('0-2秒')));
    expect(patch.promptContext.action['bodyAction'], contains('完成展示'));
    expect(patch.promptContext.camera['shotSize'], '中景到近景');
    expect(patch.values['cameraMovement'], contains('垂直升降到产品正面'));
    expect(patch.values['composition'], contains('起：手部近景'));
    expect(patch.values['visualFocus'], '从手部动作转移到产品瓶身');
    expect(patch.values['transitionHint'], contains('承接抬手动作'));
    expect(patch.values['cameraNotes'], contains('镜头目的：建立产品记忆点'));
    expect(patch.values['cameraNotes'], contains('速度曲线：短促起势'));
    expect(patch.values['cameraNotes'], contains('参考原运镜：升降'));
    expect(patch.promptContext.camera['cameraMovement'], contains('垂直升降到产品正面'));
    expect(patch.promptContext.camera['observedCameraMovement'], '升降');
    expect(patch.promptContext.camera['cameraAngle'], '轻微上摇到眼平');
    expect(patch.promptContext.continuity['chronologyCue'], '开场到收束');
  });

  test('首尾帧镜头组将所有图片合并到一次视觉 API 请求', () async {
    final root = await Directory.systemTemp.createTemp(
      'script_multimodal_group_request_',
    );
    addTearDown(() => root.delete(recursive: true));
    final first = File('${root.path}${Platform.pathSeparator}first.png');
    final middle = File('${root.path}${Platform.pathSeparator}middle.png');
    final last = File('${root.path}${Platform.pathSeparator}last.png');
    await first.writeAsBytes([1]);
    await middle.writeAsBytes([2]);
    await last.writeAsBytes([3]);
    final visionService = _FakeGroupVisionService();
    final service = ScriptMultimodalAnalysisService(
      visionService: visionService,
    );

    final patch = await service.analyzeShotGroup(
      settings: _testSettings,
      shots: [
        _shot('shot-1', 1, 8),
        _shot('shot-2', 2, 6),
        _shot('shot-3', 3, 4),
      ],
      imageFiles: [first, middle, last],
      creativeBrief: '品牌宣传短片',
      storyContext: '当前处理镜头 1-3',
      neighboringCameraPlan: '上一镜头向右平移',
    );

    expect(visionService.completeCalls, 1);
    expect(visionService.analyzeImageCalls, 0);
    expect(visionService.submittedImagePaths, [
      first.path,
      middle.path,
      last.path,
    ]);
    expect(visionService.lastPrompt, contains('首帧、中间帧、尾帧'));
    expect(visionService.lastPrompt, contains('sound_design'));
    expect(visionService.lastPrompt, contains('真实时间速度逐次贴合画面'));
    expect(visionService.lastPrompt, contains('品牌宣传短片'));
    expect(patch.values['content'], contains('完成产品展示'));
    expect(patch.values['cameraMovement'], contains('垂直升降'));
    expect(patch.promptContext.camera['startComposition'], contains('手部'));
    expect(patch.promptContext.camera['endComposition'], contains('产品'));
  });
}

const _testSettings = AppSettings(
  exportDirectory: '',
  themePreference: AppThemePreference.system,
  cutImageNumberEnabled: true,
  cutImageNumberPosition: CutImageNumberPosition.topLeft,
  cutImageNumberBackgroundOpacity: 0.5,
  cutImageNumberTextScale: 1,
  storyboardSummaryPageEnabled: true,
  visionApiBaseUrl: 'https://vision.example',
  visionApiKey: 'test-key',
  visionModel: 'test-model',
  imageGenerationApiBaseUrl: '',
  imageGenerationApiKey: '',
  imageGenerationGeminiApiKey: '',
  imageGenerationModel: '',
  updateReleaseApiUrl: '',
  autoInstallUpdates: false,
  updateDownloadMode: UpdateDownloadMode.direct,
  updateManualProxyUrl: '',
);

class _FakeGroupVisionService extends VisionStoryboardService {
  int completeCalls = 0;
  int analyzeImageCalls = 0;
  List<String> submittedImagePaths = const [];
  String lastPrompt = '';

  @override
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
    Duration responseTimeout = VisionStoryboardService.requestTimeout,
    bool compressOversizedImages = false,
  }) async {
    completeCalls++;
    submittedImagePaths = imageFiles.map((file) => file.path).toList();
    lastPrompt = prompt;
    return jsonEncode({
      'frames': [
        _frameJson('人物开始抬手', '手部近景', '开始'),
        _frameJson('人物举起产品', '产品进入中心', '进行'),
        _frameJson('人物完成产品展示', '产品正面居中', '完成'),
      ],
      'motion': {
        'is_same_shot': true,
        'observed_camera_movement': '升降',
        'designed_camera_movement': '从手部近景起势，垂直升降到产品正面并缓停',
        'camera_purpose': '建立产品记忆点',
        'speed_curve': '短促起势—匀速上升—末段缓停',
        'start_composition': '手部近景位于画面下方',
        'end_composition': '产品正面特写居中',
        'focus_path': '从手部转移到产品',
        'transition_execution': '产品居中后切下一镜头',
        'camera_angle': '轻微上摇到眼平',
        'evidence': '背景连续，画面重心从手部上移到产品',
      },
    });
  }

  @override
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
  }) {
    analyzeImageCalls++;
    throw StateError('镜头组不应逐图调用 analyzeImage');
  }

  static Map<String, Object> _frameJson(
    String caption,
    String composition,
    String actionStage,
  ) => {
    'caption': caption,
    'detail': caption,
    'scene': '现代客厅',
    'props': '产品瓶',
    'people': '一名成年人',
    'expression': '平静',
    'body_action': caption,
    'movement_trend': '向上',
    'sound_design': '$caption发生时生成一次对应的自然物理声并与动作同步',
    'shot_size': '近景',
    'composition': composition,
    'subject_direction': '正面',
    'gaze_direction': '看向产品',
    'action_stage': actionStage,
    'spatial_relation': '人物位于桌前',
    'chronology_cue': actionStage,
    'camera_angle': '眼平',
    'visual_focus': '产品',
    'lighting_mood': '暖光柔和',
    'color_palette': '暖中性色调',
    'narrative_function': '展示产品',
    'transition_hint': '动作连续',
  };
}

ScriptShot _shot(String id, int number, double durationSeconds) => ScriptShot(
  id: id,
  scriptId: 'script-1',
  shotNumber: number,
  durationSeconds: durationSeconds,
  framePath: '',
  visual: '',
  content: '',
  shotSize: '',
  cameraMovement: '',
  cameraNotes: '',
  scene: '',
  productCode: '',
  productStyling: '',
  dialogue: '',
  sound: '',
  prompt: '',
  status: ProcessingStatus.completed,
  updatedAt: DateTime.utc(2026, 8, 7),
);
