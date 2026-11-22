import '../data/kling_cli_models.dart';

class KlingDurationMatcher {
  const KlingDurationMatcher();

  int closest({
    required double desiredSeconds,
    required Iterable<int> allowed,
  }) {
    final durations = allowed.where((value) => value > 0).toSet().toList()
      ..sort();
    if (durations.isEmpty) {
      throw const FormatException('当前模型没有声明可用的视频时长。');
    }
    var best = durations.first;
    var bestDifference = (best - desiredSeconds).abs();
    for (final duration in durations.skip(1)) {
      final difference = (duration - desiredSeconds).abs();
      if (difference < bestDifference ||
          (difference == bestDifference && duration < best)) {
        best = duration;
        bestDifference = difference;
      }
    }
    return best;
  }

  int forModel({
    required double desiredSeconds,
    required KlingModelSpec model,
  }) {
    final duration = model.argument('duration');
    return closest(
      desiredSeconds: desiredSeconds,
      allowed:
          duration?.allowedValues.map(int.tryParse).whereType<int>() ??
          const <int>[],
    );
  }
}
