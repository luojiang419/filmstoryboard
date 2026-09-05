import 'dart:io';

import 'package:filmstoryboard/features/replicate/domain/deterministic_replacement_prompt_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('模特产品场景八种组合完整且可确定性解析', () {
    final scenarios = DeterministicReplacementPromptCatalog.scenarios;

    expect(scenarios, hasLength(8));
    expect(scenarios.map((scenario) => scenario.id).toSet(), hasLength(8));
    for (final scenario in scenarios) {
      expect(
        DeterministicReplacementPromptCatalog.resolve(
          hasModel: scenario.hasModel,
          hasProduct: scenario.hasProduct,
          hasScene: scenario.hasScene,
        ),
        same(scenario),
      );
      final prompt = scenario.compileReviewTemplate();
      expect(prompt, contains('【确定性一键替换协议】'));
      expect(prompt, contains('【组合路由】${scenario.id}'));
      expect(prompt, contains('【默认保留】'));
      expect(prompt, contains('模特A只对应人物A，产品A只对应产品A'));
      expect(prompt, contains('图片2是原帧配准深度图'));
    }
  });

  test('仅模特组合保留原帧服装且不把模特图穿搭带入结果', () {
    final scenario = DeterministicReplacementPromptCatalog.resolve(
      hasModel: true,
      hasProduct: false,
      hasScene: false,
    );
    final prompt = scenario.compileReviewTemplate();

    expect(prompt, contains('原服装、产品、动作与场景保持图片1不变'));
    expect(prompt, contains('不得带入素材图的服装、姿势、背景'));
    expect(prompt, isNot(contains('产品资产只提供')));
  });

  test('查阅文档逐段包含运行时导出的八种完整模板', () {
    final document = File('docs/准备资产一键替换八组合提示词.md');
    expect(document.existsSync(), isTrue);
    final content = document.readAsStringSync();

    for (final scenario in DeterministicReplacementPromptCatalog.scenarios) {
      expect(content, contains(scenario.compileReviewTemplate()));
    }
  });
}
