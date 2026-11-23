import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'performance_event.dart';
import 'performance_report.dart';

typedef PerformanceEventListener = void Function(PerformanceEvent event);

/// Lightweight diagnostics for build, I/O and task timing.
///
/// The probe is enabled by default only in debug/profile mode. In release
/// builds, calls remain safe no-ops so instrumentation can stay in production
/// code while adding no timeline or event-buffer work.
class PerformanceProbe {
  PerformanceProbe({bool? enabled, int maxEvents = 2000})
    : _enabled = enabled ?? (kDebugMode || kProfileMode),
      _maxEvents = maxEvents.clamp(1, 10000).toInt();

  static final shared = PerformanceProbe();

  final int _maxEvents;
  final _events = <PerformanceEvent>[];
  final _counters = <String, int>{};
  final _listeners = <PerformanceEventListener>{};
  bool _enabled;

  bool get enabled => _enabled;

  List<PerformanceEvent> get events => List.unmodifiable(_events);

  PerformanceCounterSnapshot get counters =>
      PerformanceCounterSnapshot(Map.unmodifiable(_counters));

  /// Freezes the current event buffer and counters into a reviewable report.
  /// Later probe writes cannot mutate the returned snapshot.
  PerformanceReport createReport({DateTime? capturedAt}) => PerformanceReport(
    capturedAt: capturedAt ?? DateTime.now(),
    events: List<PerformanceEvent>.of(_events),
    counters: Map<String, int>.of(_counters),
  );

  set enabled(bool value) {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    if (!value) {
      clear();
    }
  }

  void addListener(PerformanceEventListener listener) {
    _listeners.add(listener);
  }

  void removeListener(PerformanceEventListener listener) {
    _listeners.remove(listener);
  }

  /// Records one completed operation.
  void record(
    String name,
    Duration duration, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!_enabled) {
      return;
    }
    final event = PerformanceEvent(
      name: name,
      timestamp: DateTime.now(),
      duration: duration,
      metadata: Map.unmodifiable(metadata),
    );
    if (_events.length >= _maxEvents) {
      _events.removeAt(0);
    }
    _events.add(event);
    for (final listener in List<PerformanceEventListener>.of(_listeners)) {
      try {
        listener(event);
      } catch (_) {
        // Diagnostics must never affect the feature being measured.
      }
    }
  }

  /// Increments an aggregate counter, such as a page or section build count.
  void increment(String name, [int amount = 1]) {
    if (!_enabled || amount == 0) {
      return;
    }
    _counters.update(name, (value) => value + amount, ifAbsent: () => amount);
  }

  void countBuild(String name) => increment('build:$name');

  PerformanceSpan start(
    String name, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    if (!_enabled) {
      return PerformanceSpan.disabled();
    }
    final timelineTask = developer.TimelineTask(filterKey: 'filmstoryboard');
    timelineTask.start(name, arguments: _timelineArguments(metadata));
    return PerformanceSpan._(this, name, metadata, timelineTask);
  }

  T measureSync<T>(
    String name,
    T Function() action, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final span = start(name, metadata: metadata);
    try {
      return action();
    } finally {
      span.stop();
    }
  }

  Future<T> measureAsync<T>(
    String name,
    Future<T> Function() action, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final span = start(name, metadata: metadata);
    try {
      return await action();
    } finally {
      span.stop();
    }
  }

  void clear() {
    _events.clear();
    _counters.clear();
  }

  static Map<String, dynamic> _timelineArguments(
    Map<String, Object?> metadata,
  ) => {for (final entry in metadata.entries) entry.key: '${entry.value}'};
}

class PerformanceSpan {
  PerformanceSpan.disabled()
    : _probe = null,
      _name = '',
      _metadata = const <String, Object?>{},
      _timelineTask = null,
      _startedAt = null;

  final PerformanceProbe? _probe;
  final String _name;
  final Map<String, Object?> _metadata;
  final developer.TimelineTask? _timelineTask;
  final Stopwatch? _startedAt;
  bool _stopped = false;
  PerformanceSpan._(this._probe, this._name, this._metadata, this._timelineTask)
    : _startedAt = Stopwatch()..start();

  void stop({Map<String, Object?> metadata = const <String, Object?>{}}) {
    if (_stopped) {
      return;
    }
    _stopped = true;
    final stopwatch = _startedAt;
    final probe = _probe;
    final timelineTask = _timelineTask;
    if (stopwatch == null || probe == null || timelineTask == null) {
      return;
    }
    stopwatch.stop();
    timelineTask.finish(
      arguments: PerformanceProbe._timelineArguments(metadata),
    );
    probe.record(
      _name,
      stopwatch.elapsed,
      metadata: {..._metadata, ...metadata},
    );
  }
}
