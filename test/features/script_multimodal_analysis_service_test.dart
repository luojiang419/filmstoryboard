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
}
