import 'package:filmstoryboard/features/replicate/data/replication_frame_analysis_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:test/test.dart';

void main() {
  test('原帧复刻指导解析配饰候选、动作与姿态硬约束', () {
    const service = ReplicationFrameAnalysisService();
    final result = service.parseResponse(
      '''
      ```json
      {
        "people": [
          {"screen_order": 1, "screen_position": "画面左侧"},
          {"screen_order": 2, "screen_position": "画面右侧"}
        ],
        "person_count": 2,
        "products": [
          {
            "slot_index": 1,
            "label": "蓝色牛仔裤",
            "description": "扇贝形裤脚",
            "screen_position": "画面左侧人物下半身",
            "relationship": "由第1位人物穿着",
            "confidence": 0.93
          }
        ],
        "preservable_elements": [
          {
            "category": "眼镜",
            "label": "细金属框眼镜",
            "description": "银色细框和透明镜片",
            "location": "人物面部",
            "relationship": "稳定佩戴在双眼前方",
            "confidence": 0.96
          },
          {
            "category": "包",
            "label": "短提手手提包",
            "description": "硬挺皮质包",
            "location": "画面右下方",
            "relationship": "人物右手握住提手",
            "confidence": "0.87"
          }
        ],
        "action_description": "人物三分之二侧身面向画面右侧，右手下垂提包。",
        "pose_constraints": "保持头肩夹角、右肘角度、右腕位置和身体重心。"
      }
      ```
      ''',
      previousElements: const [
        ReplicatePreservedElement(
          id: '旧编号',
          category: '眼镜',
          label: '细金属框眼镜',
          selected: true,
        ),
      ],
    );

    expect(result.elements, hasLength(2));
    expect(result.elements.first.id, '眼镜:细金属框眼镜');
    expect(result.elements.first.selected, isTrue, reason: '重新解析应保留仍存在的勾选项');
    expect(result.elements.last.selected, isFalse);
    expect(result.elements.last.confidence, closeTo(0.87, 0.001));
    expect(result.actionDescription, contains('右手下垂提包'));
    expect(result.poseConstraints, contains('右腕位置'));
    expect(result.personCount, 2);
    expect(result.subjects, hasLength(3));
    expect(result.subjects.first.type, ReplicateSubjectType.person);
    expect(result.subjects.last.type, ReplicateSubjectType.product);
    expect(result.subjects.last.label, '蓝色牛仔裤');
    expect(result.subjects.last.decision, ReplicateSubjectDecision.undecided);
  });

  test('重新解析按主体类型和槽位保留用户处理决策', () {
    const service = ReplicationFrameAnalysisService();
    final result = service.parseResponse(
      '''
      {
        "people": [
          {"slot_index":1,"brief_description":"左侧人物"}
        ],
        "products": [
          {"slot_index":1,"label":"手提包"}
        ]
      }
      ''',
      previousSubjects: const [
        ReplicateDetectedSubject(
          id: 'person:0',
          type: ReplicateSubjectType.person,
          label: '旧人物描述',
          slotIndex: 0,
          decision: ReplicateSubjectDecision.replace,
        ),
        ReplicateDetectedSubject(
          id: 'product:0',
          type: ReplicateSubjectType.product,
          label: '旧产品描述',
          slotIndex: 0,
          decision: ReplicateSubjectDecision.keep,
        ),
      ],
    );

    expect(result.subjects.first.decision, ReplicateSubjectDecision.replace);
    expect(result.subjects.last.decision, ReplicateSubjectDecision.keep);
  });

  test('人数声明大于人物明细时补齐待决策槽位', () {
    const service = ReplicationFrameAnalysisService();
    final result = service.parseResponse('''
      {
        "person_count": 2,
        "people": [
          {"slot_index":1,"brief_description":"左侧人物"}
        ]
      }
      ''');

    expect(result.personCount, 2);
    expect(result.subjects, hasLength(2));
    expect(result.subjects.last.slotIndex, 1);
    expect(result.subjects.last.label, '画面人物2');
    expect(result.subjects.last.decision, ReplicateSubjectDecision.undecided);
  });

  test('重新解析保留手动项并过滤空名称与重复候选', () {
    const service = ReplicationFrameAnalysisService();
    final result = service.parseResponse(
      '''
      {
        "preservable_elements": [
          {"category":"鞋子","label":"白色运动鞋","confidence":2},
          {"category":"鞋子","label":"白色运动鞋","confidence":0.5},
          {"category":"首饰","label":""}
        ],
        "action_description":"人物站立",
        "pose_constraints":"双脚位置不变"
      }
      ''',
      previousElements: const [
        ReplicatePreservedElement(
          id: 'manual:胸针',
          category: '其他',
          label: '胸针',
          selected: true,
          isManual: true,
        ),
      ],
    );

    expect(result.elements.map((item) => item.label), ['白色运动鞋', '胸针']);
    expect(result.elements.first.confidence, 1);
    expect(result.elements.last.isManual, isTrue);
    expect(result.elements.last.selected, isTrue);
  });

  test('分析提示词明确候选边界和动作逐关节要求', () {
    final prompt = ReplicationFrameAnalysisService.buildPrompt(shotNumber: 7);
    expect(prompt, contains('眼镜、帽子、包、鞋子'));
    expect(prompt, contains('手部与产品或道具的接触点'));
    expect(prompt, contains('不要把人物身份、脸部'));
    expect(prompt, contains('整套服装列为候选'));
    expect(prompt, contains('镜头 7'));
    expect(prompt, contains('严格按人物中心点横坐标从小到大'));
    expect(prompt, contains('"person_count"'));
    expect(prompt, contains('"people"'));
    expect(prompt, contains('"products"'));
    expect(prompt, contains('选择“保留”“替换”或“移除”'));
    expect(prompt, contains('直接沿用原视频帧中的对应主体外观'));
  });
}
