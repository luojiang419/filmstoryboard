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
    add(
      'productStyling',
      wardrobeSlotsFromText(_analysisWardrobeText(analysis)),
      0.76,
    );
    add('composition', analysis.composition, 0.80);
    add('cameraAngle', analysis.cameraAngle, 0.78);
    add('lightingMood', analysis.lightingMood, 0.80);
    add('colorPalette', colorStyleFromPaletteText(analysis.colorPalette), 0.78);
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
