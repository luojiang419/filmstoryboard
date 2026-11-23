class GeneratedVideoTrimRange {
  const GeneratedVideoTrimRange({
    required this.sourceDuration,
    required this.inPoint,
    required this.outPoint,
  });

  factory GeneratedVideoTrimRange.fromMilliseconds({
    required int sourceDurationMs,
    required int trimInMs,
    required int trimOutMs,
    required int fallbackDurationMs,
  }) {
    final resolvedDurationMs = sourceDurationMs > 0
        ? sourceDurationMs
        : fallbackDurationMs;
    final durationMs = resolvedDurationMs.clamp(1, 86400000).toInt();
    final inPointMs = trimInMs.clamp(0, durationMs - 1).toInt();
    final requestedOutPointMs = trimOutMs > 0 ? trimOutMs : durationMs;
    final outPointMs = requestedOutPointMs
        .clamp(inPointMs + 1, durationMs)
        .toInt();
    return GeneratedVideoTrimRange(
      sourceDuration: Duration(milliseconds: durationMs),
      inPoint: Duration(milliseconds: inPointMs),
      outPoint: Duration(milliseconds: outPointMs),
    );
  }

  final Duration sourceDuration;
  final Duration inPoint;
  final Duration outPoint;

  Duration get duration => outPoint - inPoint;

  bool get isFullRange =>
      inPoint == Duration.zero && outPoint == sourceDuration;
}
