import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_prompt_compiler.dart';
import 'package:filmstoryboard/features/replicate/domain/lightweight_replication_prompt_compiler.dart';
import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_catalog.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:test/test.dart';

void main() {
  final snapshot = LineArtColorStyleSelectionSnapshot.fromPreset(
    LineArtColorStyleCatalog.builtInPresets.first,
  );

  test('统一编译器输出稳定冻结色彩块并拒绝损坏快照', () {
    const compiler = LineArtColorStylePromptCompiler();
    final block = compiler.compileBlock(
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      snapshot: snapshot,
    );
    expect(block, contains(snapshot.fingerprint));
    expect(block, contains('人物、产品、服装和场景资产的局部本色与材质证据优先'));
    expect(
      () => compiler.compileBlock(
        sourceFrameMode: ReplicateSourceFrameMode.lineArt,
        snapshot: LineArtColorStyleSelectionSnapshot(
          schemaVersion: snapshot.schemaVersion,
          presetId: snapshot.presetId,
          presetVersion: snapshot.presetVersion,
          presetName: snapshot.presetName,
          prompt: snapshot.prompt,
          swatches: snapshot.swatches,
          thumbnail: snapshot.thumbnail,
          fingerprint: 'broken',
        ),
      ),
      throwsStateError,
    );
  });

  test('快速复刻线稿模式与统一编译器使用同一色彩块和图片1边界', () {
    final prompt = const LightweightReplicationPromptCompiler().compile(
      instruction: '保持高级服装广告构图',
      references: const [
        LightweightReplicationReference(
          imageNumber: 2,
          type: ReplicateAssetType.character,
          name: '模特',
        ),
      ],
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      colorStyleSnapshot: snapshot,
    );
    final block = const LineArtColorStylePromptCompiler().compileBlock(
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      snapshot: snapshot,
    );
    expect(
      prompt,
      contains(LineArtColorStylePromptCompiler.lineArtSourceFrameAuthority),
    );
    expect(prompt, contains(block));
    expect(prompt, isNot(contains('图片1提供原环境外观')));
  });

  test('彩色原帧不注入线稿色彩块', () {
    final prompt = const LightweightReplicationPromptCompiler().compile(
      instruction: '自然复刻',
      references: const [],
      sourceFrameMode: ReplicateSourceFrameMode.colorReference,
      colorStyleSnapshot: snapshot,
    );
    expect(prompt, isNot(contains('全片统一色彩圣经')));
    expect(prompt, isNot(contains('线稿原帧权威边界')));
  });

  test('10镜头等价链路始终复用同一冻结色彩块和指纹', () {
    const compiler = LightweightReplicationPromptCompiler();
    final prompts = [
      for (var shot = 1; shot <= 10; shot++)
        compiler.compile(
          instruction: '高端服装广告镜头$shot',
          references: const [
            LightweightReplicationReference(
              imageNumber: 2,
              type: ReplicateAssetType.character,
              name: '模特',
            ),
          ],
          sourceFrameMode: ReplicateSourceFrameMode.lineArt,
          colorStyleSnapshot: snapshot,
        ),
    ];
    final block = const LineArtColorStylePromptCompiler().compileBlock(
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      snapshot: snapshot,
    );
    expect(prompts, hasLength(10));
    expect(prompts.every((prompt) => prompt.contains(block)), isTrue);
    expect(
      prompts
          .map(
            (prompt) =>
                RegExp(r'冻结指纹 ([0-9a-f]{64})').firstMatch(prompt)?.group(1),
          )
          .toSet(),
      {snapshot.fingerprint},
    );
  });
}
