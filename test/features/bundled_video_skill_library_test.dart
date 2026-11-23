import 'package:filmstoryboard/features/replicate/data/bundled_video_skill_library.dart';
import 'package:filmstoryboard/features/settings/domain/video_generation_api_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('发布资源完整收录 LibTV、可灵和通用 H3 Skill', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();

    expect(
      assets.where(
        (path) => path.startsWith('assets/video_cli_skills/libtv-cli/'),
      ),
      hasLength(46),
    );
    expect(
      assets.where(
        (path) => path.startsWith('assets/video_cli_skills/kling-cli/'),
      ),
      hasLength(4),
    );
    expect(
      assets.where(
        (path) => path.startsWith(
          'assets/minimax_h3_skills/skills/h3-prompt-writing/',
        ),
      ),
      hasLength(3),
    );
  });

  test('视觉模型只按当前视频后端读取对应完整 Skill 上下文', () async {
    final library = BundledVideoSkillLibrary();
    const kling = VideoGenerationApiConfig(
      id: 'kling',
      name: '可灵 CLI',
      kind: VideoGenerationApiConfigKind.klingCli,
      baseUrl: '',
      apiKey: '',
      model: 'kling-video-o3-std',
    );
    const libTv = VideoGenerationApiConfig(
      id: 'libtv',
      name: 'LibTV CLI · 即梦 2.0',
      kind: VideoGenerationApiConfigKind.libTvCli,
      baseUrl: '',
      apiKey: '',
      model: 'Seedance 2.0',
    );
    const h3 = VideoGenerationApiConfig(
      id: 'h3',
      name: 'MiniMax H3',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'http://127.0.0.1:7860',
      apiKey: '',
      model: 'MiniMax-H3',
    );

    final klingDocument = (await library.loadForConfig(kling))!;
    final libTvDocument = (await library.loadForConfig(libTv))!;
    final h3Document = (await library.loadForConfig(h3))!;

    expect(klingDocument.fileCount, 1);
    expect(
      klingDocument.files['kling-cli/prompt-guide.md'],
      contains('参考图是主体外观'),
    );
    expect(libTvDocument.fileCount, 1);
    expect(
      libTvDocument
          .files['libtv-cli/prompt-guides/image-to-video-prompt-guide.md'],
      contains('参考图已经表达'),
    );
    expect(h3Document.fileCount, 3);
    expect(
      h3Document.files['skills/h3-prompt-writing/SKILL.md'],
      contains('integrated_multimodal_description'),
    );

    for (final document in [klingDocument, libTvDocument, h3Document]) {
      final context = document.toVisionModelContext();
      expect(context, contains('软件内置视频提示词 Skill（仅供当前后端）'));
      expect(
        RegExp('<bundled_video_skill_file ').allMatches(context),
        hasLength(document.fileCount),
      );
      expect(context, isNot(contains('登录、上传、画布、提交、轮询和下载')));
    }
  });

  test('未知 HTTP 模型不会误加载 MiniMax H3 Skill', () async {
    final library = BundledVideoSkillLibrary();
    const unknown = VideoGenerationApiConfig(
      id: 'custom-video-api',
      name: '自定义视频模型',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'https://example.com',
      apiKey: '',
      model: 'custom-video-v1',
    );

    expect(await library.loadForConfig(unknown), isNull);
  });

  test('远程 H3 HTTP 模型不会加载只供本地模型使用的 H3 Skill', () async {
    final library = BundledVideoSkillLibrary();
    const remoteH3 = VideoGenerationApiConfig(
      id: 'remote-h3',
      name: 'MiniMax H3 远程',
      kind: VideoGenerationApiConfigKind.httpApi,
      baseUrl: 'https://example.com',
      apiKey: '',
      model: 'MiniMax-H3',
    );

    expect(remoteH3.supportsLocalH3SkillRouting, isFalse);
    expect(await library.loadForConfig(remoteH3), isNull);
  });
}
