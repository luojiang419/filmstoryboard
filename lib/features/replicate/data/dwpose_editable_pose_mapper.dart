import '../domain/replicate_asset_preparation_models.dart';
import 'dwpose_service.dart';

class DwPoseEditablePoseMapper {
  const DwPoseEditablePoseMapper._();

  static ReplicateEditablePoseData fromExtraction(
    DwPoseExtractionResult result, {
    ReplicateEditablePoseData previous = ReplicateEditablePoseData.empty,
  }) {
    final orderedPeople = [...result.people]
      ..sort((a, b) {
        final horizontal = a.box.centerX.compareTo(b.box.centerX);
        if (horizontal != 0) return horizontal;
        final vertical = a.box.centerY.compareTo(b.box.centerY);
        if (vertical != 0) return vertical;
        return b.box.score.compareTo(a.box.score);
      });
    final fresh = ReplicateEditablePoseData(
      sourceWidth: result.sourceWidth,
      sourceHeight: result.sourceHeight,
      people: [
        for (var order = 0; order < orderedPeople.length; order++)
          _mapPerson(orderedPeople[order], order),
      ],
    );
    return mergeManualAdjustments(previous: previous, fresh: fresh);
  }

  static ReplicateEditablePoseData mergeManualAdjustments({
    required ReplicateEditablePoseData previous,
    required ReplicateEditablePoseData fresh,
  }) {
    if (previous.sourceWidth != fresh.sourceWidth ||
        previous.sourceHeight != fresh.sourceHeight ||
        previous.people.isEmpty ||
        fresh.people.isEmpty) {
      return fresh;
    }
    final previousBySlot = {
      for (final person in previous.people) person.modelSlotIndex: person,
    };
    return ReplicateEditablePoseData(
      sourceWidth: fresh.sourceWidth,
      sourceHeight: fresh.sourceHeight,
      people: [
        for (final person in fresh.people)
          _mergePerson(
            person,
            previousBySlot[person.modelSlotIndex],
            width: fresh.sourceWidth,
            height: fresh.sourceHeight,
          ),
      ],
    );
  }

  static ReplicatePosePerson _mapPerson(DwPosePerson person, int order) =>
      ReplicatePosePerson(
        id: 'pose-person-$order',
        leftToRightOrder: order,
        modelSlotIndex: order,
        bounds: ReplicatePoseBounds(
          x: person.box.left,
          y: person.box.top,
          width: person.box.right - person.box.left,
          height: person.box.bottom - person.box.top,
        ),
        keypoints: [
          for (var index = 0; index < person.keypoints.length; index++)
            ReplicatePoseKeypoint(
              index: index,
              x: person.keypoints[index].x,
              y: person.keypoints[index].y,
              confidence: person.keypoints[index].score,
            ),
        ],
        confidence: person.box.score,
      );

  static ReplicatePosePerson _mergePerson(
    ReplicatePosePerson fresh,
    ReplicatePosePerson? previous, {
    required int width,
    required int height,
  }) {
    if (previous == null) return fresh;
    final manualByIndex = {
      for (final point in previous.keypoints)
        if (point.manuallyAdjusted &&
            point.x.isFinite &&
            point.y.isFinite &&
            point.x >= 0 &&
            point.y >= 0 &&
            point.x < width &&
            point.y < height)
          point.index: point,
    };
    if (manualByIndex.isEmpty) return fresh;
    return fresh.copyWith(
      keypoints: [
        for (final point in fresh.keypoints)
          manualByIndex[point.index]?.copyWith(
                confidence: 1,
                manuallyAdjusted: true,
              ) ??
              point,
      ],
    );
  }
}
