import 'dart:convert';
import 'dart:io';

import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../domain/replicate_models.dart';

class ReplicationFrameAnalysisResult {
  const ReplicationFrameAnalysisResult({
    required this.elements,
    this.subjects = const [],
    required this.actionDescription,
    required this.poseConstraints,
    this.personCount = 0,
    required this.rawResponse,
  });

  final List<ReplicatePreservedElement> elements;
  final List<ReplicateDetectedSubject> subjects;
  final String actionDescription;
  final String poseConstraints;
  final int personCount;
  final String rawResponse;
}

class ReplicationFrameAnalysisService {
  const ReplicationFrameAnalysisService({
    VisionStoryboardService? visionService,
  }) : _visionService = visionService;

  final VisionStoryboardService? _visionService;

  Future<ReplicationFrameAnalysisResult> analyze({
    required AppSettings settings,
    required File imageFile,
    required int shotNumber,
    List<ReplicatePreservedElement> previousElements = const [],
    List<ReplicateDetectedSubject> previousSubjects = const [],
    bool allowThinking = false,
  }) async {
    final visionService = _visionService;
    if (visionService == null) {
      throw StateError('原帧复刻指导分析服务未配置视觉模型客户端');
    }
    if (!imageFile.existsSync()) {
      throw FileSystemException('原视频帧不存在', imageFile.path);
    }
    final response = await visionService.complete(
      settings: settings,
      prompt: buildPrompt(shotNumber: shotNumber),
      imageFiles: [imageFile],
      maxTokens: 2400,
      allowThinking: allowThinking,
      compressOversizedImages: true,
    );
    return parseResponse(
      response,
      previousElements: previousElements,
      previousSubjects: previousSubjects,
    );
  }

  ReplicationFrameAnalysisResult parseResponse(
    String response, {
    List<ReplicatePreservedElement> previousElements = const [],
    List<ReplicateDetectedSubject> previousSubjects = const [],
  }) {
    final json = _extractJsonObject(response);
    final previousSelectedKeys = {
      for (final element in previousElements)
        if (element.selected) _elementKey(element.category, element.label),
    };
    final previousSelectedLabels = {
      for (final element in previousElements)
        if (element.selected) _normalized(element.label),
    };
    final rawElements =
        json['preservable_elements'] ??
        json['preservableElements'] ??
        json['elements'];
    final elements = <ReplicatePreservedElement>[];
    final usedKeys = <String>{};
    if (rawElements is List) {
      for (final raw in rawElements) {
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry('$key', value));
        final category = _text(item, const ['category', 'type']);
        final label = _text(item, const ['label', 'name']);
        if (label.isEmpty) continue;
        final key = _elementKey(category, label);
        if (!usedKeys.add(key)) continue;
        final confidence = _number(item['confidence']).clamp(0.0, 1.0);
        elements.add(
          ReplicatePreservedElement(
            id: '${category.isEmpty ? '其他' : category}:$label',
            category: category.isEmpty ? '其他' : category,
            label: label,
            description: _text(item, const [
              'description',
              'appearance',
              'visual_features',
            ]),
            location: _text(item, const ['location', 'screen_position']),
            relationship: _text(item, const [
              'relationship',
              'wearing_or_contact_relation',
              'interaction',
            ]),
            confidence: confidence,
            selected:
                previousSelectedKeys.contains(key) ||
                previousSelectedLabels.contains(_normalized(label)),
          ),
        );
      }
    }
    for (final previous in previousElements) {
      if (!previous.isManual) continue;
      final key = _elementKey(previous.category, previous.label);
      if (usedKeys.add(key)) elements.add(previous);
    }
    final previousDecisions = {
      for (final subject in previousSubjects)
        _subjectKey(subject.type, subject.slotIndex): subject.decision,
    };
    final people = List<ReplicateDetectedSubject>.of(
      _subjects(
        json['people'] ?? json['persons'] ?? json['characters'],
        type: ReplicateSubjectType.person,
        previousDecisions: previousDecisions,
      ),
    );
    final declaredPersonCount = _number(
      json['person_count'] ?? json['personCount'],
    ).round().clamp(0, 100).toInt();
    final detectedPersonSlots = people
        .map((subject) => subject.slotIndex)
        .toSet();
    for (var slotIndex = 0; slotIndex < declaredPersonCount; slotIndex++) {
      if (!detectedPersonSlots.add(slotIndex)) continue;
      people.add(
        ReplicateDetectedSubject(
          id: '${ReplicateSubjectType.person.name}:$slotIndex',
          type: ReplicateSubjectType.person,
          label: '画面人物${slotIndex + 1}',
          slotIndex: slotIndex,
          decision:
              previousDecisions[_subjectKey(
                ReplicateSubjectType.person,
                slotIndex,
              )] ??
              ReplicateSubjectDecision.undecided,
        ),
      );
    }
    people.sort((left, right) => left.slotIndex.compareTo(right.slotIndex));
    final subjects = <ReplicateDetectedSubject>[
      ...people,
      ..._subjects(
        json['products'] ?? json['commercial_products'] ?? json['items'],
        type: ReplicateSubjectType.product,
        previousDecisions: previousDecisions,
      ),
    ];
    return ReplicationFrameAnalysisResult(
      elements: List.unmodifiable(elements),
      subjects: List.unmodifiable(subjects),
      actionDescription: _text(json, const [
        'action_description',
        'actionDescription',
        'action',
      ]),
      poseConstraints: _text(json, const [
        'pose_constraints',
        'poseConstraints',
        'pose',
      ]),
      personCount: subjects
          .where((subject) => subject.type == ReplicateSubjectType.person)
          .length,
      rawResponse: response,
    );
  }

  static String buildPrompt({required int shotNumber}) =>
      '''
你正在分析镜头 $shotNumber 的原视频帧，为“更换人物或产品后重新生成分镜图”建立严格的原帧保留清单和动作约束。

任务零：识别需要显式处理的可见主体。
- 统计画面中可见人物总数，并严格按人物中心点横坐标从小到大（画面从左到右）列出每个人。即使人物身份、服装相似，也必须分别计数；不要把海报、屏幕、照片或镜中重复影像误算为独立人物。
- 识别所有必须由用户选择“保留”“替换”或“移除”的商业产品，包括独立商品、包装、手持商品，以及人物正在穿着的有明确款式结构的服装、鞋、帽、包和配饰。选择“保留”时会直接沿用原视频帧中的对应主体外观。不要把普通家具、建筑构件、自然物或无法辨认的背景杂物列为产品。
- 每个人和产品都分配从 1 开始的稳定 `slot_index`。人物按从左到右编号；产品优先使用与其穿着、持拿或交互人物相同的编号，无关联产品再按从左到右使用未占用编号。

任务一：只识别用户可能希望从原人物继续保留的独立配饰与关键交互道具，包括眼镜、帽子、包、鞋子、耳环、项链、手链、戒指、手表、发饰、围巾、腰带，以及人物正在拿取、穿戴、踩踏或直接交互的关键道具。
- 不要把人物身份、脸部、肤色、发型、体型或整套服装列为候选。
- 普通上衣、裤子、裙子、外套不作为候选，除非它是具有独立功能的可拆卸配饰。
- 不要识别字幕、Logo、品牌文字或水印。
- 每项写清可见外观、画面位置，以及佩戴、持握、接触或遮挡关系。

任务二：忠实分析图片中人物当下的精确动作，不要推测动作前后剧情。动作描述必须覆盖：
- 头部朝向、俯仰和与肩线的夹角；
- 双肩高低、躯干朝向与倾斜、髋部朝向、身体重心；
- 左右上臂、肘、前臂、腕和可见手指的位置与弯曲关系；
- 左右大腿、膝、小腿、踝、脚尖方向和支撑脚；
- 人物在画面中的左右位置、轮廓、遮挡和视线；
- 手部与产品或道具的接触点、持握方式和受力关系。
所有左/右都以观看图片时的画面左/右为坐标系，不是人物自身左右。

只返回一个可被标准解析器读取的 JSON 对象，不要 Markdown、解释或额外文本：
{
  "person_count": 2,
  "people": [
    {
      "slot_index": 1,
      "screen_order": 1,
      "screen_position": "画面最左侧/从左到右第N位",
      "brief_description": "仅用于区分画面中不同人物的简短可见描述"
    }
  ],
  "products": [
    {
      "slot_index": 1,
      "label": "可供用户识别的简短名称",
      "description": "整体轮廓、结构、材质与可见细节，不抄录文字或Logo",
      "screen_position": "画面位置",
      "relationship": "与第几位人物的穿着、持拿、接触或独立摆放关系",
      "confidence": 0.0
    }
  ],
  "preservable_elements": [
    {
      "category": "眼镜/帽子/包/鞋子/首饰/手表/发饰/围巾/腰带/关键道具/其他",
      "label": "简短且可供用户勾选的名称",
      "description": "外观、结构、材质和可见细节，不抄录文字或Logo",
      "location": "以画面坐标描述的位置",
      "relationship": "与人物身体或道具的佩戴、持握、接触和遮挡关系",
      "confidence": 0.0
    }
  ],
  "action_description": "忠实、具体、无推测的当前动作描述",
  "pose_constraints": "用于图像生成的逐关节姿态、重心、视线、遮挡和手物接触硬约束"
}
''';

  static Map<String, dynamic> _extractJsonObject(String response) {
    final trimmed = response
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 继续从模型解释文本中提取最外层 JSON。
    }
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('原帧复刻指导分析未返回可解析的 JSON');
    }
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('原帧复刻指导分析 JSON 格式异常');
  }

  static String _text(Map<dynamic, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final text = value is List ? value.join('；').trim() : '$value'.trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }

  static List<ReplicateDetectedSubject> _subjects(
    Object? rawSubjects, {
    required ReplicateSubjectType type,
    required Map<String, ReplicateSubjectDecision> previousDecisions,
  }) {
    if (rawSubjects is! List) return const [];
    final result = <ReplicateDetectedSubject>[];
    final usedSlots = <int>{};
    for (var sourceIndex = 0; sourceIndex < rawSubjects.length; sourceIndex++) {
      final raw = rawSubjects[sourceIndex];
      if (raw is! Map) continue;
      final item = raw.map((key, value) => MapEntry('$key', value));
      final oneBasedSlot = _number(
        item['slot_index'] ??
            item['slotIndex'] ??
            item['screen_order'] ??
            item['screenOrder'],
      ).round();
      var slotIndex = oneBasedSlot > 0 ? oneBasedSlot - 1 : sourceIndex;
      while (!usedSlots.add(slotIndex)) {
        slotIndex++;
      }
      final label = type == ReplicateSubjectType.person
          ? _text(item, const [
              'label',
              'brief_description',
              'briefDescription',
              'name',
            ])
          : _text(item, const ['label', 'name', 'product_name']);
      final fallbackLabel = type == ReplicateSubjectType.person
          ? '画面人物${slotIndex + 1}'
          : '画面产品${slotIndex + 1}';
      result.add(
        ReplicateDetectedSubject(
          id: '${type.name}:$slotIndex',
          type: type,
          label: label.isEmpty ? fallbackLabel : label,
          slotIndex: slotIndex,
          description: _text(item, const [
            'description',
            'brief_description',
            'briefDescription',
            'appearance',
          ]),
          location: _text(item, const [
            'screen_position',
            'screenPosition',
            'location',
          ]),
          relationship: _text(item, const [
            'relationship',
            'interaction',
            'wearing_or_contact_relation',
          ]),
          confidence: _number(item['confidence']).clamp(0.0, 1.0),
          decision:
              previousDecisions[_subjectKey(type, slotIndex)] ??
              ReplicateSubjectDecision.undecided,
        ),
      );
    }
    return result;
  }

  static String _subjectKey(ReplicateSubjectType type, int slotIndex) =>
      '${type.name}:$slotIndex';

  static String _elementKey(String category, String label) =>
      '${_normalized(category)}:${_normalized(label)}';

  static String _normalized(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}
