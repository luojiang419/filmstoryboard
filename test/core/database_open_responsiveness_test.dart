import 'dart:async';
import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:test/test.dart';

void main() {
  test('hot script and vision queries use scoped indexes', () async {
    final root = await Directory.systemTemp.createTemp('database_indexes_');
    addTearDown(() => root.delete(recursive: true));
    final database = await AppDatabase.open(
      File('${root.path}/project.sqlite'),
    );
    addTearDown(database.dispose);
    for (final (sql, indexName) in [
      (
        'SELECT * FROM script_shots WHERE script_id = ? ORDER BY shot_number',
        'idx_script_shots_script_order',
      ),
      (
        'SELECT * FROM video_generation_drafts WHERE script_id = ?',
        'idx_video_drafts_script',
      ),
      (
        'SELECT * FROM vision_analysis_items WHERE run_id = ? ORDER BY slot_index',
        'idx_vision_items_run_slot',
      ),
    ]) {
      final plan = database.selectRows('EXPLAIN QUERY PLAN $sql', ['fixture']);
      expect(plan.map((row) => row['detail']).join(' '), contains(indexName));
    }
  });

  test(
    'failed worker open closes its connection and reports corruption',
    () async {
      final root = await Directory.systemTemp.createTemp('database_corrupt_');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/broken.sqlite');
      await file.writeAsString('invalid database' * 100);
      await expectLater(
        AppDatabase.open(file, verifyIntegrity: true),
        throwsA(anything),
      );
      await file.delete();
      expect(await file.exists(), isFalse);
    },
  );

  test('large database verification yields to the UI event loop', () async {
    final root = await Directory.systemTemp.createTemp('database_response_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/large.sqlite');
    final seed = await AppDatabase.open(file);
    seed.executeStatement('BEGIN;');
    final payload = 'x' * 8192;
    for (var index = 0; index < 2000; index++) {
      seed.setSetting('fixture-$index', payload);
    }
    seed.executeStatement('COMMIT;');
    seed.dispose();

    var heartbeats = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
      heartbeats++;
    });
    final watch = Stopwatch()..start();
    final opened = await AppDatabase.open(file, verifyIntegrity: true);
    watch.stop();
    heartbeat.cancel();
    opened.dispose();
    // ignore: avoid_print
    print(
      'DATABASE_OPEN elapsed_ms=${watch.elapsedMilliseconds} '
      'event_loop_heartbeats=$heartbeats rows=2000 payload_bytes=8192',
    );
    expect(
      heartbeats,
      greaterThan(0),
      reason: 'Database verification must not monopolize the UI isolate.',
    );
  });
}
