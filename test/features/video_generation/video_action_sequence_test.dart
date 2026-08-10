import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/shooting_script/domain/script_shot_group.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_action_sequence.dart';
import 'package:test/test.dart';

void main() {
  const resolver = VideoActionSequenceResolver();

  test('只有相邻镜头双向确认连续时才组成同一首尾帧动作组', () {
    final sequences = resolver.resolve([
      _shot(1, continuesToNext: true),
      _shot(2, continuesFromPrevious: true, continuesToNext: true),
      _shot(3, continuesFromPrevious: true),
      _shot(4),
    ]);

    expect(sequences, hasLength(2));
    expect(sequences.first.shots.map((shot) => shot.shotNumber), [1, 2, 3]);
    expect(sequences.first.head.shotNumber, 1);
    expect(sequences.first.tail.shotNumber, 3);
    expect(sequences.last.hasDistinctTail, isFalse);
  });

  test('仅同场景或单向连续不会误合并，不同场景强制断组', () {
    final sequences = resolver.resolve([
      _shot(1, continuesToNext: true),
      _shot(2, scene: '室内', continuesFromPrevious: false),
      _shot(3, scene: '室内', continuesToNext: true),
      _shot(4, scene: '室外', continuesFromPrevious: true),
    ]);

    expect(sequences, hasLength(4));
  });

  test('动作文字相似但没有手动双向标记时保持独立', () {
    final shots = [
      _shot(
        4,
        content: '女模特开始举手向前走',
        movementTrend: '向前走',
        actionStage: '准备',
        continuesToNext: true,
      ),
      _shot(
        5,
        content: '女模特举手继续向前走',
        movementTrend: '向前走并举手',
        actionStage: '进行',
      ),
      _shot(
        6,
        content: '女模特完成举手动作',
        movementTrend: '动作完成',
        actionStage: '结果',
        continuesFromPrevious: true,
      ),
    ];
    final sequences = resolver.resolve(shots);

    expect(sequences, hasLength(3));
    expect(ScriptShotGroup.group(shots), hasLength(3));
  });
}

ScriptShot _shot(
  int number, {
  String scene = '室内',
  String content = '',
  String movementTrend = '',
  String actionStage = '',
  bool continuesFromPrevious = false,
  bool continuesToNext = false,
}) => ScriptShot(
  id: 'shot-$number',
  scriptId: 'script-1',
  shotNumber: number,
  durationSeconds: 5,
  framePath: 'frame-$number.png',
  visual: '',
  content: content,
  shotSize: '',
  cameraMovement: '',
  cameraNotes: '',
  scene: scene,
  productCode: '',
  productStyling: '',
  dialogue: '',
  sound: '',
  prompt: '',
  movementTrend: movementTrend,
  actionStage: actionStage,
  continuesFromPrevious: continuesFromPrevious,
  continuesToNext: continuesToNext,
  status: ProcessingStatus.completed,
  updatedAt: DateTime.utc(2026, 8, 4),
);
