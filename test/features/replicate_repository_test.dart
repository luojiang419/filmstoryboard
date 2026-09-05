import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:test/test.dart';

void main() {
  test('复刻生成模式默认精确并持久化最后一次手动选择', () async {
    final root = await Directory.systemTemp.createTemp(
      'replicate_mode_preferences_',
    );
    addTearDown(() => root.delete(recursive: true));
    final database = await AppDatabase.open(File('${root.path}/app.db'));
    addTearDown(database.dispose);

    var repository = ReplicateRepository(database);
    expect(repository.loadGenerationMode(), ReplicationGenerationMode.precise);

    repository.saveGenerationMode(ReplicationGenerationMode.quick);
    repository = ReplicateRepository(database);
    expect(repository.loadGenerationMode(), ReplicationGenerationMode.quick);

    repository.saveGenerationMode(ReplicationGenerationMode.precise);
    repository = ReplicateRepository(database);
    expect(repository.loadGenerationMode(), ReplicationGenerationMode.precise);
  });
}
