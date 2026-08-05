import '../../shooting_script/domain/shooting_script_models.dart';

class StartEndFramePair {
  const StartEndFramePair({
    required this.startShotId,
    required this.tailShotId,
  });

  final String startShotId;
  final String tailShotId;
}

class VideoActionSequence {
  const VideoActionSequence(this.shots);

  final List<ScriptShot> shots;

  ScriptShot get head => shots.first;
  ScriptShot get tail => shots.last;
  bool get hasDistinctTail => shots.length > 1;

  bool contains(String shotId) => shots.any((shot) => shot.id == shotId);
}

class VideoActionSequenceResolver {
  const VideoActionSequenceResolver();

  List<VideoActionSequence> resolve(List<ScriptShot> shots) {
    if (shots.isEmpty) return const [];
    final ordered = [...shots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final result = <VideoActionSequence>[];
    var current = <ScriptShot>[ordered.first];
    for (var index = 1; index < ordered.length; index++) {
      final previous = ordered[index - 1];
      final next = ordered[index];
      if (_isContinuous(previous, next)) {
        current.add(next);
      } else {
        result.add(VideoActionSequence(List.unmodifiable(current)));
        current = <ScriptShot>[next];
      }
    }
    result.add(VideoActionSequence(List.unmodifiable(current)));
    return List.unmodifiable(result);
  }

  List<VideoActionSequence> resolveManual(
    List<ScriptShot> shots,
    List<StartEndFramePair> pairs,
  ) {
    if (shots.isEmpty) return const [];
    final ordered = [...shots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final indexById = <String, int>{
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index,
    };
    final pairByStartIndex = <int, int>{};
    final occupied = <int>{};
    for (final pair in pairs) {
      final startIndex = indexById[pair.startShotId];
      final tailIndex = indexById[pair.tailShotId];
      if (startIndex == null || tailIndex == null || tailIndex <= startIndex) {
        continue;
      }
      var overlaps = false;
      for (var index = startIndex; index <= tailIndex; index++) {
        if (occupied.contains(index)) {
          overlaps = true;
          break;
        }
      }
      if (overlaps) continue;
      pairByStartIndex[startIndex] = tailIndex;
      for (var index = startIndex; index <= tailIndex; index++) {
        occupied.add(index);
      }
    }

    final result = <VideoActionSequence>[];
    var index = 0;
    while (index < ordered.length) {
      final tailIndex = pairByStartIndex[index];
      if (tailIndex != null) {
        result.add(
          VideoActionSequence(
            List.unmodifiable(ordered.sublist(index, tailIndex + 1)),
          ),
        );
        index = tailIndex + 1;
      } else if (occupied.contains(index)) {
        index++;
      } else {
        result.add(VideoActionSequence([ordered[index]]));
        index++;
      }
    }
    return List.unmodifiable(result);
  }

  VideoActionSequence sequenceFor(List<ScriptShot> shots, String shotId) =>
      resolve(shots).firstWhere(
        (sequence) => sequence.contains(shotId),
        orElse: () => VideoActionSequence([
          shots.firstWhere((shot) => shot.id == shotId),
        ]),
      );

  VideoActionSequence manualSequenceFor(
    List<ScriptShot> shots,
    List<StartEndFramePair> pairs,
    String shotId,
  ) => resolveManual(shots, pairs).firstWhere(
    (sequence) => sequence.contains(shotId),
    orElse: () =>
        VideoActionSequence([shots.firstWhere((shot) => shot.id == shotId)]),
  );

  bool _isContinuous(ScriptShot previous, ScriptShot next) {
    if (!previous.continuesToNext || !next.continuesFromPrevious) {
      return false;
    }
    final previousScene = _normalizedScene(previous.scene);
    final nextScene = _normalizedScene(next.scene);
    return previousScene.isEmpty ||
        nextScene.isEmpty ||
        previousScene == nextScene;
  }

  String _normalizedScene(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s，,。；;、]+'), '');
}
