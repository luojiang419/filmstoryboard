import '../../shooting_script/domain/shooting_script_models.dart';

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

  VideoActionSequence sequenceFor(List<ScriptShot> shots, String shotId) =>
      resolve(shots).firstWhere(
        (sequence) => sequence.contains(shotId),
        orElse: () => VideoActionSequence([
          shots.firstWhere((shot) => shot.id == shotId),
        ]),
      );

  bool _isContinuous(ScriptShot previous, ScriptShot next) {
    return previous.continuesToNext && next.continuesFromPrevious;
  }
}
