import 'package:filmstoryboard/features/replicate/data/seedance_prompt_generation_service.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/structured_prompt_shot_adapter.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/domain/h3_video_prompt_adapter.dart';
import 'package:filmstoryboard/features/video_generation/domain/kling_video_prompt_adapter.dart';
import 'package:test/test.dart';

void main() {
  const adapter = StructuredPromptShotAdapter();
  const context = ScriptShotPromptContext(
    subject: {'people': '女模特', 'expression': '专注看向手中的产品', 'props': '玻璃精华瓶'},
    action: {
      'bodyAction': '抬手将产品转向镜头',
      'movementTrend': '产品逐渐靠近画面中心',
      'actionStage': '展示进行阶段',
    },
    scene: {
      'location': '极简摄影棚',
      'subjectDirection': '身体面向画面右侧',
      'gazeDirection': '看向手中的产品',
      'spatialRelation': '人物位于展台左侧，产品位于胸前',
    },
    camera: {
      'shotSize': '中近景',
      'cameraMovement': '短促推进后减速锁定',
      'composition': '主体居左，产品位于中心',
      'cameraAngle': '眼平三分之二侧面',
      'visualFocus': '从人物面部转移到产品瓶身',
    },
    visualStyle: {'lightingMood': '柔和侧光', 'colorPalette': '暖金低饱和调'},
    continuity: {
      'caption': '女模特抬手展示产品',
      'chronologyCue': '动作中',
      'narrativeFunction': '广告产品记忆点',
      'transitionHint': '承接上一镜头的抬手动作',
    },
    audio: {'sound': '轻快节奏铺底，产品转动轻响'},
  );

  test('人工脚本字段优先并用结构化上下文补齐提示词事实', () {
    final enriched = adapter.apply(
      _shot().copyWith(
        content: '人工确认：模特稳定展示产品',
        scene: '人工确认摄影棚',
        cameraMovement: '人工确认横移',
      ),
      context,
    );

    expect(enriched.content, startsWith('人工确认：模特稳定展示产品'));
    expect(enriched.content, contains('抬手将产品转向镜头'));
    expect(enriched.content, contains('身体面向画面右侧'));
    expect(enriched.scene, '人工确认摄影棚');
    expect(enriched.cameraMovement, '人工确认横移');
    expect(enriched.composition, '主体居左，产品位于中心');
    expect(enriched.cameraAngle, '眼平三分之二侧面');
    expect(enriched.cameraNotes, contains('空间关系：人物位于展台左侧'));
    expect(enriched.cameraNotes, contains('叙事功能：广告产品记忆点'));
    expect(enriched.sound, '轻快节奏铺底，产品转动轻响');
  });

  test('同一结构化上下文可确定性编译SD2、Kling和H3提示词', () {
    final enriched = adapter.apply(_shot(), context);
    final sd2 = const SeedancePromptGenerationService()
        .generate(
          shot: enriched,
          assets: const [],
          globalStyle: '电影级商业质感',
          constraints: '无字幕、无Logo、无水印',
        )
        .prompt;
    final kling = const KlingVideoPromptAdapter().adapt(
      enriched,
      availableImageReferences: 1,
      globalStyle: '电影级商业质感',
      constraints: '无字幕、无Logo、无水印',
    );
    final h3 = const H3VideoPromptAdapter().adapt(
      enriched,
      availableImageReferences: 1,
      globalStyle: '电影级商业质感',
      constraints: '无字幕、无Logo、无水印',
    );

    for (final prompt in [sd2, kling]) {
      expect(prompt, contains('抬手将产品转向镜头'));
      expect(prompt, contains('身体面向画面右侧'));
    }
    expect(sd2, contains('人物位于展台左侧'));
    expect(sd2, contains('广告产品记忆点'));
    expect(kling, contains('主体居左，产品位于中心'));
    expect(kling, isNot(contains('广告产品记忆点')));
    expect(h3, contains('抬手将产品转向镜头'));
    expect(h3, contains('身体面向画面右侧'));
    expect(h3, contains('人物位于展台左侧'));
    expect(h3, isNot(contains('广告产品记忆点')));
    expect(h3, isNot(contains('玻璃精华瓶')));
    expect(
      adapter.apply(_shot(), context).content,
      adapter.apply(_shot(), context).content,
    );
  });
}

ScriptShot _shot() => ScriptShot(
  id: 'shot-1',
  scriptId: 'script-1',
  shotNumber: 1,
  durationSeconds: 5,
  framePath: 'replica.png',
  visual: '',
  content: '',
  shotSize: '',
  cameraMovement: '',
  cameraNotes: '',
  scene: '',
  productCode: '',
  productStyling: '',
  dialogue: '',
  sound: '',
  prompt: '',
  status: ProcessingStatus.completed,
  updatedAt: DateTime.utc(2026, 8, 7),
);
