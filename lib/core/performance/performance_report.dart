import 'performance_event.dart';

/// Immutable, serializable diagnostics snapshot created from a
/// [PerformanceProbe].
///
/// The report deliberately contains no file-system or UI behavior. Callers can
/// choose where to persist or display [toJson] / [toMarkdown] without coupling
/// diagnostics to a feature workflow.
class PerformanceReport {
  PerformanceReport({
    required this.capturedAt,
    required Iterable<PerformanceEvent> events,
    required Map<String, int> counters,
  }) : events = List<PerformanceEvent>.unmodifiable(events),
       counters = Map<String, int>.unmodifiable(counters),
       operations = _summarize(events);

  final DateTime capturedAt;
  final List<PerformanceEvent> events;
  final Map<String, int> counters;
  final Map<String, PerformanceOperationSummary> operations;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'eventCount': events.length,
    'counters': Map<String, int>.fromEntries(
      counters.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    ),
    'operations': <String, Object?>{
      for (final entry in operations.entries) entry.key: entry.value.toJson(),
    },
    'events': events.map(_eventToJson).toList(growable: false),
  };

  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# PerformanceProbe 性能快照')
      ..writeln()
      ..writeln('- 采集时间（UTC）：${capturedAt.toUtc().toIso8601String()}')
      ..writeln('- 事件数量：${events.length}')
      ..writeln()
      ..writeln('## 操作耗时')
      ..writeln()
      ..writeln('| 操作 | 次数 | 平均值(ms) | P50(ms) | P95(ms) | P99(ms) | 最大值(ms) |')
      ..writeln('|---|---:|---:|---:|---:|---:|---:|');
    if (operations.isEmpty) {
      buffer.writeln('| 暂无样本 | 0 | - | - | - | - | - |');
    } else {
      for (final entry in operations.entries) {
        final summary = entry.value;
        buffer.writeln(
          '| ${_escapeCell(entry.key)} | ${summary.count} | '
          '${_milliseconds(summary.meanMicroseconds)} | '
          '${_milliseconds(summary.p50Microseconds)} | '
          '${_milliseconds(summary.p95Microseconds)} | '
          '${_milliseconds(summary.p99Microseconds)} | '
          '${_milliseconds(summary.maxMicroseconds)} |',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('## 计数器')
      ..writeln()
      ..writeln('| 名称 | 数值 |')
      ..writeln('|---|---:|');
    if (counters.isEmpty) {
      buffer.writeln('| 暂无计数 | 0 |');
    } else {
      final entries = counters.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key));
      for (final entry in entries) {
        buffer.writeln('| ${_escapeCell(entry.key)} | ${entry.value} |');
      }
    }
    return buffer.toString();
  }

  static Map<String, PerformanceOperationSummary> _summarize(
    Iterable<PerformanceEvent> source,
  ) {
    final durationsByName = <String, List<int>>{};
    for (final event in source) {
      durationsByName
          .putIfAbsent(event.name, () => <int>[])
          .add(event.duration.inMicroseconds);
    }
    final names = durationsByName.keys.toList()..sort();
    return Map<String, PerformanceOperationSummary>.unmodifiable({
      for (final name in names)
        name: PerformanceOperationSummary.fromMicroseconds(
          durationsByName[name]!,
        ),
    });
  }

  static Map<String, Object?> _eventToJson(PerformanceEvent event) =>
      <String, Object?>{
        'name': event.name,
        'timestamp': event.timestamp.toUtc().toIso8601String(),
        'durationMicroseconds': event.duration.inMicroseconds,
        'metadata': <String, Object?>{
          for (final entry in event.metadata.entries)
            entry.key: _jsonSafeValue(entry.value),
        },
      };

  static Object? _jsonSafeValue(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    return value.toString();
  }

  static String _milliseconds(num microseconds) =>
      (microseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(3);

  static String _escapeCell(String value) => value.replaceAll('|', r'\|');
}

class PerformanceOperationSummary {
  const PerformanceOperationSummary({
    required this.count,
    required this.totalMicroseconds,
    required this.meanMicroseconds,
    required this.p50Microseconds,
    required this.p95Microseconds,
    required this.p99Microseconds,
    required this.maxMicroseconds,
  });

  factory PerformanceOperationSummary.fromMicroseconds(List<int> samples) {
    assert(samples.isNotEmpty);
    final sorted = List<int>.of(samples)..sort();
    final total = sorted.fold<int>(0, (sum, value) => sum + value);
    return PerformanceOperationSummary(
      count: sorted.length,
      totalMicroseconds: total,
      meanMicroseconds: total / sorted.length,
      p50Microseconds: _nearestRank(sorted, 0.50),
      p95Microseconds: _nearestRank(sorted, 0.95),
      p99Microseconds: _nearestRank(sorted, 0.99),
      maxMicroseconds: sorted.last,
    );
  }

  final int count;
  final int totalMicroseconds;
  final double meanMicroseconds;
  final int p50Microseconds;
  final int p95Microseconds;
  final int p99Microseconds;
  final int maxMicroseconds;

  Map<String, Object> toJson() => <String, Object>{
    'count': count,
    'totalMicroseconds': totalMicroseconds,
    'meanMicroseconds': meanMicroseconds,
    'p50Microseconds': p50Microseconds,
    'p95Microseconds': p95Microseconds,
    'p99Microseconds': p99Microseconds,
    'maxMicroseconds': maxMicroseconds,
  };

  static int _nearestRank(List<int> sorted, double percentile) {
    final rank = (percentile * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}
