import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/core/performance/performance_probe.dart';
import 'package:filmstoryboard/core/performance/rebuild_counter.dart';

void main() {
  test('disabled probe is a no-op', () {
    final probe = PerformanceProbe(enabled: false);

    probe.increment('build:test');
    probe.record('test', const Duration(milliseconds: 1));

    expect(probe.events, isEmpty);
    expect(probe.counters['build:test'], 0);
  });

  test('enabled probe records bounded events and counters', () async {
    final probe = PerformanceProbe(enabled: true, maxEvents: 2);
    final names = <String>[];
    probe.addListener((event) => names.add(event.name));

    probe.increment('build:test', 2);
    probe.record('first', const Duration(microseconds: 1));
    await probe.measureAsync('second', () async {});
    probe.record('third', const Duration(microseconds: 1));

    expect(probe.counters['build:test'], 2);
    expect(probe.events, hasLength(2));
    expect(probe.events.map((event) => event.name), ['second', 'third']);
    expect(names, ['first', 'second', 'third']);
  });

  test('report freezes events and exports reviewable statistics', () {
    final probe = PerformanceProbe(enabled: true);
    final capturedAt = DateTime.utc(2026, 8, 24, 5, 30);
    for (final milliseconds in <int>[1, 2, 3, 4, 100]) {
      probe.record(
        'database.listShots',
        Duration(milliseconds: milliseconds),
        metadata: {'rows': 10, 'opaque': capturedAt},
      );
    }
    probe.increment('build:shooting_script.page', 3);

    final report = probe.createReport(capturedAt: capturedAt);
    final summary = report.operations['database.listShots']!;

    expect(summary.count, 5);
    expect(summary.totalMicroseconds, 110000);
    expect(summary.meanMicroseconds, 22000);
    expect(summary.p50Microseconds, 3000);
    expect(summary.p95Microseconds, 100000);
    expect(summary.p99Microseconds, 100000);
    expect(summary.maxMicroseconds, 100000);
    expect(report.toJson()['schemaVersion'], 1);
    expect(report.toJson()['eventCount'], 5);
    expect(
      report.toMarkdown(),
      allOf(
        contains('database.listShots'),
        contains('22.000'),
        contains('build:shooting_script.page'),
      ),
    );

    probe.clear();
    expect(report.events, hasLength(5));
    expect(report.counters['build:shooting_script.page'], 3);
  });

  testWidgets('RebuildCounter preserves child behavior and counts builds', (
    tester,
  ) async {
    final previous = PerformanceProbe.shared.enabled;
    PerformanceProbe.shared.enabled = true;
    addTearDown(() {
      PerformanceProbe.shared.enabled = previous;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: RebuildCounter(name: 'test.counter', child: const Text('内容')),
      ),
    );

    expect(find.text('内容'), findsOneWidget);
    expect(PerformanceProbe.shared.counters['build:test.counter'], 1);
  });
}
