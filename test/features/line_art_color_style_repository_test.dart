import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/replicate/data/line_art_color_style_repository.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_catalog.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 28升级到29时补齐色彩表与兼容默认值', () async {
    final root = await Directory.systemTemp.createTemp('color_schema_29_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final file = File(p.join(root.path, 'project.sqlite'));
    final legacy = sqlite.sqlite3.open(file.path)
      ..execute('''
        CREATE TABLE replicate_runs (
          id TEXT PRIMARY KEY
        );
      ''')
      ..execute('''
        CREATE TABLE replicated_shot_images (
          id TEXT PRIMARY KEY
        );
      ''')
      ..execute("INSERT INTO replicate_runs(id) VALUES('run-legacy');")
      ..execute(
        "INSERT INTO replicated_shot_images(id) VALUES('image-legacy');",
      )
      ..execute('PRAGMA user_version = 28;');
    legacy.close();

    final database = await AppDatabase.open(file);
    addTearDown(database.dispose);

    expect(
      database.selectRows('PRAGMA user_version;').single['user_version'],
      AppDatabase.currentSchemaVersion,
    );
    final run = database.selectRows(
      'SELECT * FROM replicate_runs WHERE id = ?;',
      ['run-legacy'],
    ).single;
    expect(run['source_frame_mode'], 'colorReference');
    expect(run['color_style_preset_id'], '');
    expect(run['color_style_snapshot_json'], '{}');
    expect(
      database
          .selectRows(
            'SELECT color_style_fingerprint FROM replicated_shot_images;',
          )
          .single['color_style_fingerprint'],
      '',
    );
    expect(
      database.selectRows(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='replicate_color_style_presets';",
      ),
      isNotEmpty,
    );
    expect(
      database.selectRows(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='replicate_color_style_thumbnail_overrides';",
      ),
      isNotEmpty,
    );
  });

  test('自定义预设CRUD和内置预设项目缩略图覆盖可持久化', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.utc(2026, 8, 21, 9);
    const customThumbnail = ColorStyleThumbnailReference.projectFile(
      r'assets\color_style_thumbnails\custom-fashion.jpg',
    );
    final custom = LineArtColorStylePreset(
      id: 'custom-fashion',
      name: '红毯丝绒',
      description: '自定义奢华暖红',
      prompt:
          'Preserve authorized colors and apply a refined velvet-red grade.',
      swatches: const ['#571D2B', '#B27A72', '#D8C3A8'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: false,
      version: 1,
      thumbnail: customThumbnail,
      createdAt: now,
      updatedAt: now,
    );

    fixture.styles.upsertCustomPreset(custom);
    final restored = fixture.styles.getCustomPreset(custom.id)!;
    expect(restored.name, custom.name);
    expect(restored.thumbnail!.path, customThumbnail.path);
    expect(restored.swatches, custom.swatches);

    const override = ColorStyleThumbnailReference.projectFile(
      r'assets\color_style_thumbnails\natural-override.jpg',
    );
    fixture.styles.setThumbnailOverride(
      presetId: LineArtColorStyleCatalog.defaultPresetId,
      thumbnail: override,
      updatedAt: now,
    );
    expect(
      fixture.styles
          .resolvePreset(LineArtColorStyleCatalog.defaultPresetId)!
          .thumbnail!
          .path,
      override.path,
    );
    expect(fixture.styles.listEffectivePresets(), hasLength(11));

    fixture.styles.removeThumbnailOverride(
      LineArtColorStyleCatalog.defaultPresetId,
    );
    expect(
      fixture.styles
          .resolvePreset(LineArtColorStyleCatalog.defaultPresetId)!
          .thumbnail!
          .type,
      ColorStyleThumbnailType.bundledAsset,
    );

    fixture.styles.deleteCustomPreset(custom.id);
    expect(fixture.styles.getCustomPreset(custom.id), isNull);
  });

  test('任务冻结快照与单镜头色彩指纹可保存并恢复', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final now = DateTime.utc(2026, 8, 21, 10);
    final preset = LineArtColorStyleCatalog.byId('blue_gold_twilight');
    final snapshot = LineArtColorStyleSelectionSnapshot.fromPreset(preset);
    final run = ReplicateRun(
      id: 'run-color',
      videoId: null,
      scriptId: 'script-color',
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      colorStylePresetId: preset.id,
      colorStyleSnapshot: snapshot,
      currentStep: ReplicateStep.prepareAssets,
      status: ProcessingStatus.pending,
      confirmShotsStatus: ProcessingStatus.completed,
      prepareAssetsStatus: ProcessingStatus.pending,
      composePromptsStatus: ProcessingStatus.pending,
      completedCount: 0,
      totalCount: 1,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    fixture.analysis.upsertReplicateRun(run);
    final restored = fixture.analysis.getReplicateRun(run.id)!;
    expect(restored.sourceFrameMode, ReplicateSourceFrameMode.lineArt);
    expect(restored.colorStylePresetId, preset.id);
    expect(restored.colorStyleSnapshot!.fingerprint, snapshot.fingerprint);
    expect(restored.colorStyleSnapshot!.hasValidFingerprint, isTrue);

    fixture.database.executeStatement(
      '''
      INSERT INTO shooting_scripts(id, name, status, version, created_at, updated_at)
      VALUES(?, ?, ?, ?, ?, ?);
      ''',
      [
        'script-color',
        '测试脚本',
        'draft',
        1,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    fixture.database.executeStatement(
      'INSERT INTO script_shots(id, script_id, shot_number, updated_at) '
      'VALUES(?, ?, ?, ?);',
      ['shot-color', 'script-color', 1, now.toIso8601String()],
    );
    final image = ReplicatedShotImage(
      id: 'image-color',
      runId: run.id,
      scriptShotId: 'shot-color',
      shotNumber: 1,
      originalFramePath: '',
      generatedFramePath: '',
      assetIds: const [],
      prompt: 'prompt',
      model: 'model',
      rawResponse: '',
      colorStyleFingerprint: snapshot.fingerprint,
      status: ProcessingStatus.completed,
      errorMessage: '',
      createdAt: now,
      updatedAt: now,
    );
    fixture.replicate.upsertReplicatedShotImage(image);
    expect(
      fixture.replicate
          .listReplicatedShotImages(run.id)
          .single
          .colorStyleFingerprint,
      snapshot.fingerprint,
    );
  });

  test('拒绝把内置预设或内置资源路径写入自定义表和覆盖表', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    expect(
      () => fixture.styles.upsertCustomPreset(
        LineArtColorStyleCatalog.builtInPresets.first,
      ),
      throwsArgumentError,
    );
    expect(
      () => fixture.styles.setThumbnailOverride(
        presetId: 'natural_cinema',
        thumbnail: LineArtColorStyleCatalog.builtInPresets.first.thumbnail!,
      ),
      throwsArgumentError,
    );
  });
}

class _Fixture {
  const _Fixture({
    required this.root,
    required this.database,
    required this.styles,
    required this.analysis,
    required this.replicate,
  });

  final Directory root;
  final AppDatabase database;
  final LineArtColorStyleRepository styles;
  final VideoAnalysisRepository analysis;
  final ReplicateRepository replicate;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('color_style_repo_');
    final database = await AppDatabase.open(
      File(p.join(root.path, 'project.sqlite')),
    );
    return _Fixture(
      root: root,
      database: database,
      styles: LineArtColorStyleRepository(database),
      analysis: VideoAnalysisRepository(database),
      replicate: ReplicateRepository(database),
    );
  }

  Future<void> dispose() async {
    database.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
