import 'package:filmstoryboard/features/replicate/data/bundled_video_skill_library.dart';
import 'package:filmstoryboard/features/replicate/data/video_skill_router.dart';
import 'package:filmstoryboard/features/replicate/domain/h3_prompt_style.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const router = VideoSkillRouter();
  const h3 = VideoGenerationApiConfig(
    id: 'default-minimax-h3-local',
    name: 'MiniMax H3 本地',
    kind: VideoGenerationApiConfigKind.httpApi,
    baseUrl: 'http://127.0.0.1:7860',
    apiKey: '',
    model: 'minimax-h3-local',
  );
  const kling = VideoGenerationApiConfig(
    id: 'default-kling-cli',
    name: '可灵 CLI',
    kind: VideoGenerationApiConfigKind.klingCli,
    baseUrl: '',
    apiKey: '',
    model: 'kling-cli',
  );
  const libTv = VideoGenerationApiConfig(
    id: 'default-libtv-cli',
    name: 'LibTV CLI · 即梦 2.0',
    kind: VideoGenerationApiConfigKind.libTvCli,
    baseUrl: '',
    apiKey: '',
    model: 'Seedance 2.0',
  );
  const remoteH3 = VideoGenerationApiConfig(
    id: 'remote-minimax-h3',
    name: 'MiniMax H3 远程',
    kind: VideoGenerationApiConfigKind.httpApi,
    baseUrl: 'https://example.com',
    apiKey: '',
    model: 'MiniMax-H3',
  );

  test('H3 根据当前剧情自动选择至多一个专项 Skill', () {
    final music = router.resolve(
      config: h3,
      narrativeText: '制作音乐 MV，歌词贴字跟随鼓点进入画面。',
    );
    final paper = router.resolve(
      config: h3,
      narrativeText: '用纸艺定格科普解释行星运动，搭建分层纸雕舞台。',
    );

    expect(music.backendKind, BundledVideoSkillKind.minimaxH3);
    expect(music.promptStyle.id, 'music-video-subtitle');
    expect(music.automaticallySelected, isTrue);
    expect(paper.promptStyle.id, 'papercraft-stop-motion');
  });

  test('普通 H3 剧情不强行匹配专项 Skill', () {
    final route = router.resolve(
      config: h3,
      narrativeText: '清晨，一个人走过安静的街道并抬头看天。',
    );

    expect(route.promptStyle, H3PromptStyle.general);
    expect(route.automaticallySelected, isFalse);
  });

  test('手动专项风格覆盖自动判断', () {
    final route = router.resolve(
      config: h3,
      narrativeText: '音乐 MV 与歌词贴字',
      preferredStyle: H3PromptStyle.resolve('3d-animation-short'),
    );

    expect(route.promptStyle.id, '3d-animation-short');
    expect(route.automaticallySelected, isFalse);
  });

  test('可灵和 LibTV 永不叠加 H3 专项 Skill', () {
    final preferred = H3PromptStyle.resolve('music-video-subtitle');
    final klingRoute = router.resolve(
      config: kling,
      narrativeText: '歌词贴字音乐 MV',
      preferredStyle: preferred,
    );
    final libTvRoute = router.resolve(
      config: libTv,
      narrativeText: '歌词贴字音乐 MV',
      preferredStyle: preferred,
    );

    expect(klingRoute.backendKind, BundledVideoSkillKind.klingCli);
    expect(klingRoute.promptStyle, H3PromptStyle.general);
    expect(libTvRoute.backendKind, BundledVideoSkillKind.libTvCli);
    expect(libTvRoute.promptStyle, H3PromptStyle.general);
  });

  test('远程 H3 不显示也不执行只供本地模型使用的 H3 Skill 路由', () {
    final route = router.resolve(
      config: remoteH3,
      narrativeText: '音乐 MV 与歌词贴字',
      preferredStyle: H3PromptStyle.resolve('music-video-subtitle'),
    );

    expect(route.backendKind, isNull);
    expect(route.supportsH3NarrativeSkill, isFalse);
    expect(route.promptStyle, H3PromptStyle.general);
    expect(route.automaticallySelected, isFalse);
  });
}
