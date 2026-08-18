import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/dwpose_editable_pose_mapper.dart';
import 'package:filmstoryboard/features/replicate/data/dwpose_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_asset_preparation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('结构化结果按人物框从左到右绑定模特 A/B/C 并保留 133 点', () {
    final result = DwPoseExtractionResult(
      skeletonFile: File('unused.png'),
      sourceWidth: 1920,
      sourceHeight: 1080,
      people: [
        _person(left: 1200, score: 0.95),
        _person(left: 100, score: 0.8),
        _person(left: 650, score: 0.99),
      ],
    );

    final pose = DwPoseEditablePoseMapper.fromExtraction(result);

    expect(pose.sourceWidth, 1920);
    expect(pose.sourceHeight, 1080);
    expect(pose.people, hasLength(3));
    expect(pose.people.map((person) => person.bounds.x), [100, 650, 1200]);
    expect(pose.people.map((person) => person.leftToRightOrder), [0, 1, 2]);
    expect(pose.people.map((person) => person.modelSlotIndex), [0, 1, 2]);
    expect(pose.people.map((person) => person.id), [
      'pose-person-0',
      'pose-person-1',
      'pose-person-2',
    ]);
    expect(
      pose.people.every((person) => person.keypoints.length == 133),
      isTrue,
    );
  });

  test('同画布重新提取按模特槽保留人工调整且不同画布不错误继承', () {
    final fresh = DwPoseEditablePoseMapper.fromExtraction(
      DwPoseExtractionResult(
        skeletonFile: File('unused.png'),
        sourceWidth: 640,
        sourceHeight: 360,
        people: [_person(left: 100, score: 0.9)],
      ),
    );
    final manualPoint = fresh.people.single.keypoints[10].copyWith(
      x: 321,
      y: 123,
      manuallyAdjusted: true,
    );
    final previous = ReplicateEditablePoseData(
      sourceWidth: 640,
      sourceHeight: 360,
      people: [
        fresh.people.single.copyWith(
          keypoints: [
            for (final point in fresh.people.single.keypoints)
              point.index == 10 ? manualPoint : point,
          ],
        ),
      ],
    );

    final merged = DwPoseEditablePoseMapper.fromExtraction(
      DwPoseExtractionResult(
        skeletonFile: File('unused.png'),
        sourceWidth: 640,
        sourceHeight: 360,
        people: [_person(left: 120, score: 0.95)],
      ),
      previous: previous,
    );
    final changedCanvas = DwPoseEditablePoseMapper.mergeManualAdjustments(
      previous: previous,
      fresh: ReplicateEditablePoseData(
        sourceWidth: 1280,
        sourceHeight: 720,
        people: fresh.people,
      ),
    );

    expect(merged.people.single.keypoints[10].x, 321);
    expect(merged.people.single.keypoints[10].y, 123);
    expect(merged.people.single.keypoints[10].confidence, 1);
    expect(merged.people.single.keypoints[10].manuallyAdjusted, isTrue);
    expect(changedCanvas.people.single.keypoints[10].manuallyAdjusted, isFalse);
  });
}

DwPosePerson _person({required double left, required double score}) =>
    DwPosePerson(
      box: DwPoseBox(left, 20, left + 200, 340, score),
      keypoints: [
        for (var index = 0; index < 133; index++)
          DwPosePoint(left + index % 10, (30 + index ~/ 10).toDouble(), 0.9),
      ],
    );
