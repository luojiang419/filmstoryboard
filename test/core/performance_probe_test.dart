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
