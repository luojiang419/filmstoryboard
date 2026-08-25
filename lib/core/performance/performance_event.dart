import 'dart:collection';

/// A single diagnostic measurement emitted by [PerformanceProbe].
///
/// These events are intentionally data-only so they can be asserted in tests
/// and exported to a future profile report without coupling business code to a
/// logging backend.
class PerformanceEvent {
  const PerformanceEvent({
    required this.name,
    required this.timestamp,
    required this.duration,
    this.metadata = const <String, Object?>{},
  });

  final String name;
  final DateTime timestamp;
  final Duration duration;
  final Map<String, Object?> metadata;

  UnmodifiableMapView<String, Object?> get immutableMetadata =>
      UnmodifiableMapView(metadata);
}

/// A stable snapshot of aggregated diagnostic counters.
class PerformanceCounterSnapshot {
  const PerformanceCounterSnapshot(this.values);

  final Map<String, int> values;

  int operator [](String name) => values[name] ?? 0;
}
