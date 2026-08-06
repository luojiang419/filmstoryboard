import 'package:filmstoryboard/features/shooting_script/data/script_multimodal_analysis_service.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
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
    expect(patch.values.containsKey('cameraNotes'), isFalse);
    expect(patch.values.containsKey('dialogue'), isFalse);
    expect(patch.values['sound'], contains('音效设计'));
    expect(patch.values['sound'], contains('现代客厅'));
    expect(double.parse(patch.values['durationSeconds']!), 5);
    expect(patch.values.containsKey('productCode'), isFalse);
    expect(patch.fieldConfidence['content'], greaterThan(0.8));
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

  test('空运镜且证据不足时不再默认生成推近', () {
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

    expect(patch.values['cameraMovement'], contains('固定镜头'));
    expect(patch.values['cameraMovement'], isNot(contains('推近')));
  });
}
