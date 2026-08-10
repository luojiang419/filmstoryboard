import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('注册表包含通用默认项和 8 个固定风格且 ID 唯一', () {
    expect(H3PromptStyle.values, hasLength(9));
    expect(H3PromptStyle.values.first, same(H3PromptStyle.general));
    expect(
      H3PromptStyle.values.map((style) => style.id).toSet(),
      hasLength(H3PromptStyle.values.length),
    );
    expect(
      H3PromptStyle.values.map((style) => style.id),
      containsAll(const [
        'general',
        '3d-animation-short',
        'brand-promo',
        'co-op-game-intro',
        'handdrawn-live',
        'minimalist-product-ad',
        'music-video-subtitle',
        'paper-collage-explainer',
        'papercraft-stop-motion',
      ]),
    );
  });

  test('空值和未知 ID 回退通用 H3 以兼容旧项目', () {
    expect(H3PromptStyle.resolve(null), same(H3PromptStyle.general));
    expect(H3PromptStyle.resolve(''), same(H3PromptStyle.general));
    expect(H3PromptStyle.resolve('unknown'), same(H3PromptStyle.general));
    expect(H3PromptStyle.resolve(' general '), same(H3PromptStyle.general));
  });

  test('8 个风格化选项均绑定官方技能并提供分析与成片两级执行契约', () {
    expect(H3PromptStyle.general.visualPromptInstruction, isEmpty);
    expect(H3PromptStyle.general.videoPromptInstruction, isEmpty);
    for (final style in H3PromptStyle.values.skip(1)) {
      expect(style.label, isNotEmpty, reason: style.id);
      expect(style.description, isNotEmpty, reason: style.id);
      expect(style.officialSkillPath, startsWith('skills/'), reason: style.id);
      expect(
        style.visualPromptInstruction.trim(),
        isNotEmpty,
        reason: style.id,
      );
      expect(style.videoPromptInstruction.trim(), isNotEmpty, reason: style.id);
      expect(
        style.visualPromptInstruction,
        allOf(
          contains('叙事结构：'),
          contains('画面材质：'),
          contains('镜头与节奏：'),
          contains('动作与连续性：'),
          contains('声音策略：'),
          contains('硬性禁区：'),
          contains('逐字段落实：'),
        ),
        reason: style.id,
      );
    }
  });

  test('结构化执行契约保留各官方风格的关键画面与叙事语法', () {
    expect(
      H3PromptStyle.resolve('3d-animation-short').visualPromptInstruction,
      allOf(
        contains('C4D + Octane'),
        contains('2.5–3 头身'),
        contains('squash-and-stretch'),
        contains('空间锚点'),
      ),
    );
    expect(
      H3PromptStyle.resolve('handdrawn-live').visualPromptInstruction,
      allOf(
        contains('0–3 秒'),
        contains('同一个实体'),
        contains('慢半拍'),
        contains('13–15 秒'),
      ),
    );
    expect(
      H3PromptStyle.resolve('brand-promo').visualPromptInstruction,
      allOf(
        contains('事实表'),
        contains('产品证据'),
        contains('行动号召'),
        contains('不得虚构'),
      ),
    );
    expect(
      H3PromptStyle.resolve('co-op-game-intro').visualPromptInstruction,
      allOf(
        contains('PLAYER 1 始终在左'),
        contains('CONTINUE'),
        contains('五种主色'),
        contains('加载'),
      ),
    );
    expect(
      H3PromptStyle.resolve('minimalist-product-ad').visualPromptInstruction,
      allOf(
        contains('产品本体颜色'),
        contains('3–5 个英文词'),
        contains('同一行'),
        contains('产品真实动作'),
      ),
    );
    expect(
      H3PromptStyle.resolve('music-video-subtitle').visualPromptInstruction,
      allOf(
        contains('唯一主音乐轨'),
        contains('Beat Grid'),
        contains('空间图形层'),
        contains('逐字匹配'),
      ),
    );
    expect(
      H3PromptStyle.resolve('paper-collage-explainer').visualPromptInstruction,
      allOf(
        contains('3–6 个'),
        contains('出现→回弹→压平→暂停→锁定'),
        contains('默认不添加 BGM'),
      ),
    );
    expect(
      H3PromptStyle.resolve('papercraft-stop-motion').visualPromptInstruction,
      allOf(
        contains('4–7 层'),
        contains('前景、中景、背景和远景'),
        contains('纸艺物理逻辑'),
        contains('避免丝滑 CG'),
      ),
    );
  });
}
