import 'package:filmstoryboard/features/replicate/data/h3_skill_library.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('软件资源收录 8 个叙事 Skill 与通用 H3 中文 Skill', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final officialAssets = manifest
        .listAssets()
        .where((path) => path.startsWith('assets/minimax_h3_skills/skills/'))
        .toSet();

    expect(officialAssets, hasLength(18));
    expect(
      officialAssets.where((path) => path.endsWith('/SKILL.cn.md')),
      hasLength(8),
    );
    expect(
      officialAssets.where((path) => path.endsWith('/SKILL.md')),
      hasLength(1),
    );
    expect(
      officialAssets.where((path) => path.endsWith('/meta.yaml')),
      isEmpty,
    );
    expect(
      officialAssets.where((path) => path.contains('/h3-prompt-writing/')),
      hasLength(3),
    );
    expect(
      officialAssets,
      contains(
        'assets/minimax_h3_skills/skills/3d-animation-short-generator/references/storyboard-guidelines.md',
      ),
    );
    expect(
      officialAssets,
      contains(
        'assets/minimax_h3_skills/skills/co-op-game-intro-generator/references/h3-video-prompt-template.md',
      ),
    );
  });

  test('8 种叙事风格加载完整中文 Skill 与全部引用文档', () async {
    final library = BundledH3SkillLibrary();
    const expectedFileCounts = {
      '3d-animation-short': 6,
      'brand-promo': 1,
      'co-op-game-intro': 3,
      'handdrawn-live': 1,
      'minimalist-product-ad': 1,
      'music-video-subtitle': 1,
      'paper-collage-explainer': 1,
      'papercraft-stop-motion': 1,
    };

    for (final style in H3PromptStyle.values.skip(1)) {
      final document = await library.loadForStyle(style);
      final context = document.toVisionModelContext();
      expect(document.sourceRevision, H3PromptStyle.officialSourceRevision);
      expect(document.fileCount, expectedFileCounts[style.id]);
      expect(document.characterCount, greaterThan(1900));
      expect(
        RegExp('<official_skill_file ').allMatches(context),
        hasLength(document.fileCount),
      );
      expect(
        RegExp('</official_skill_file>').allMatches(context),
        hasLength(document.fileCount),
      );
      expect(context, endsWith('【完整官方 Skill 结束】'));
    }
  });

  test('通用 H3 不会回退加载英文官方 Skill', () async {
    final library = BundledH3SkillLibrary();

    await expectLater(
      library.loadForStyle(H3PromptStyle.general),
      throwsA(isA<StateError>()),
    );
  });

  test('品牌 Skill 从首次问询到失败恢复均未截断', () async {
    final document = await BundledH3SkillLibrary().loadForStyle(
      H3PromptStyle.resolve('brand-promo'),
    );
    final context = document.toVisionModelContext();

    expect(context, contains('## 步骤 1：上传素材并确认简报'));
    expect(context, contains('## 步骤 10：交付'));
    expect(context, contains('## 失败恢复'));
    expect(context, contains('资产不可用：索要授权原件，绝不猜测。'));
  });

  test('3D 与双人游戏 Skill 会连同所有强制参考文件一起读取', () async {
    final library = BundledH3SkillLibrary();
    final animation = await library.loadForStyle(
      H3PromptStyle.resolve('3d-animation-short'),
    );
    final coOp = await library.loadForStyle(
      H3PromptStyle.resolve('co-op-game-intro'),
    );

    expect(
      animation.files.keys,
      containsAll([
        'skills/3d-animation-short-generator/references/fallback-policy.md',
        'skills/3d-animation-short-generator/references/model-selection.md',
        'skills/3d-animation-short-generator/references/qc-checklist.md',
        'skills/3d-animation-short-generator/references/shot-table-spec.md',
        'skills/3d-animation-short-generator/references/storyboard-guidelines.md',
      ]),
    );
    expect(
      coOp.files.keys,
      containsAll([
        'skills/co-op-game-intro-generator/references/h3-confirmation-image-template.md',
        'skills/co-op-game-intro-generator/references/h3-video-prompt-template.md',
      ]),
    );
  });
}
