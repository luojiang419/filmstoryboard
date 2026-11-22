import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/line_art_color_style_repository.dart';
import 'package:filmstoryboard/features/replicate/data/line_art_color_style_thumbnail_service.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_catalog.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('控制器加载内置目录并在线稿模式保存预设冻结快照', () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.dispose);

    expect(fixture.controller.value.colorStylePresets, hasLength(10));
    fixture.controller.updateGenerationDefaults(
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      colorStylePresetId: 'desaturated_prestige',
    );

    final run = fixture.controller.value.run!;
    expect(run.sourceFrameMode, ReplicateSourceFrameMode.lineArt);
    expect(run.colorStylePresetId, 'desaturated_prestige');
    expect(run.colorStyleSnapshot, isNotNull);
    expect(run.colorStyleSnapshot!.hasValidFingerprint, isTrue);
    expect(fixture.controller.isSelectedColorStyleChanged, isFalse);

    final restored = fixture.replicateRepository.getRun(run.id)!;
    expect(
      restored.colorStyleSnapshot!.fingerprint,
      run.colorStyleSnapshot!.fingerprint,
    );
    expect(
      () => fixture.controller.updateGenerationDefaults(
        sourceFrameMode: ReplicateSourceFrameMode.autoDetect,
      ),
      throwsArgumentError,
    );

    fixture.controller.updateGenerationDefaults(
      sourceFrameMode: ReplicateSourceFrameMode.colorReference,
    );
    expect(fixture.controller.value.run!.colorStylePresetId, isEmpty);
    expect(fixture.controller.value.run!.colorStyleSnapshot, isNull);
  });

  test('自定义预设创建编辑复制删除并保留运行中的冻结快照', () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.dispose);

    final id = fixture.controller.saveCustomColorStylePreset(
      name: '客户红毯',
      description: '暖红丝绒和自然肤色',
      prompt:
          'Preserve authorized colors and apply a restrained velvet-red grade.',
      swatches: const ['#5A1425', '#B06F6A', '#D7BFA7'],
    );
    expect(fixture.controller.value.colorStylePresets, hasLength(11));
    expect(fixture.styles.getCustomPreset(id)!.version, 1);

    fixture.controller.saveCustomColorStylePreset(
      id: id,
      name: '客户红毯 2026',
      description: '暖红丝绒和自然肤色',
      prompt:
          'Preserve authorized colors and apply a restrained velvet-red grade.',
      swatches: const ['#5A1425', '#B06F6A', '#D7BFA7'],
    );
    expect(fixture.styles.getCustomPreset(id)!.version, 2);

    final duplicateId = fixture.controller.duplicateColorStylePreset(id);
    expect(duplicateId, isNot(id));
    expect(fixture.styles.getCustomPreset(duplicateId), isNotNull);

    fixture.controller.updateGenerationDefaults(
      sourceFrameMode: ReplicateSourceFrameMode.lineArt,
      colorStylePresetId: id,
    );
    final frozenFingerprint =
        fixture.controller.value.run!.colorStyleSnapshot!.fingerprint;
    await expectLater(
      fixture.controller.deleteCustomColorStylePreset(id),
      throwsStateError,
    );
    await fixture.controller.deleteCustomColorStylePreset(id, force: true);
    expect(fixture.styles.getCustomPreset(id), isNull);
    expect(
      fixture.controller.value.run!.colorStyleSnapshot!.fingerprint,
      frozenFingerprint,
    );
    expect(fixture.controller.isSelectedColorStyleChanged, isTrue);
  });

  test('内置和自定义预设都可导入替换并移除项目缩略图', () async {
    final fixture = await _ControllerFixture.create();
    addTearDown(fixture.dispose);
    final source = File(p.join(fixture.root.path, 'thumbnail.png'));
    final image = img.Image(width: 120, height: 120);
    img.fill(image, color: img.ColorRgb8(120, 40, 80));
    await source.writeAsBytes(img.encodePng(image));

    const builtInId = LineArtColorStyleCatalog.defaultPresetId;
    await fixture.controller.importColorStyleThumbnail(
      presetId: builtInId,
      source: source,
    );
    final builtInOverride = fixture.styles.getThumbnailOverride(builtInId)!;
    final builtInFile = fixture.thumbnails.resolveProjectFile(builtInOverride);
    expect(await builtInFile.exists(), isTrue);
    expect(
      fixture.controller.colorStylePresetById(builtInId)!.thumbnail!.type,
      ColorStyleThumbnailType.projectFile,
    );
    await fixture.controller.removeColorStyleThumbnail(builtInId);
    expect(fixture.styles.getThumbnailOverride(builtInId), isNull);
    expect(await builtInFile.exists(), isFalse);

    final customId = fixture.controller.saveCustomColorStylePreset(
      name: '自定义冷银',
      description: '',
      prompt: 'Preserve authorized colors and apply a cool silver grade.',
      swatches: const ['#DDE4E8', '#60717B'],
    );
    await fixture.controller.importColorStyleThumbnail(
      presetId: customId,
      source: source,
    );
    final customReference = fixture.styles
        .getCustomPreset(customId)!
        .thumbnail!;
    final customFile = fixture.thumbnails.resolveProjectFile(customReference);
    expect(await customFile.exists(), isTrue);
    await fixture.controller.removeColorStyleThumbnail(customId);
    expect(fixture.styles.getCustomPreset(customId)!.thumbnail, isNull);
    expect(await customFile.exists(), isFalse);
  });
}

class _ControllerFixture {
  const _ControllerFixture({
    required this.root,
    required this.database,
    required this.settingsController,
    required this.shootingController,
    required this.replicateRepository,
    required this.styles,
    required this.thumbnails,
    required this.controller,
  });

  final Directory root;
  final AppDatabase database;
  final SettingsController settingsController;
  final ShootingScriptController shootingController;
  final ReplicateRepository replicateRepository;
  final LineArtColorStyleRepository styles;
  final LineArtColorStyleThumbnailService thumbnails;
  final ReplicateController controller;

  static Future<_ControllerFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'color_style_controller_',
    );
    final directories = await AppDirectories.create(executableDirectory: root);
    final database = await AppDatabase.open(directories.databaseFile);
    final settingsRepository = SettingsRepository(database, directories);
    final settingsController = SettingsController(
      repository: settingsRepository,
      initialSettings: settingsRepository.load(),
    );
    final shootingController = ShootingScriptController(
      repository: ShootingScriptRepository(database),
      directories: directories,
    )..createEmpty(name: '色彩控制器测试');
    final replicateRepository = ReplicateRepository(database);
    final styles = LineArtColorStyleRepository(database);
    final thumbnails = LineArtColorStyleThumbnailService(
      projectRoot: directories.workspaceRoot,
      projectAssetsRoot: directories.assets,
    );
    final controller = ReplicateController(
      repository: replicateRepository,
      colorStyleRepository: styles,
      colorStyleThumbnailService: thumbnails,
      shootingScriptController: shootingController,
      directories: directories,
      settingsController: settingsController,
    );
    return _ControllerFixture(
      root: root,
      database: database,
      settingsController: settingsController,
      shootingController: shootingController,
      replicateRepository: replicateRepository,
      styles: styles,
      thumbnails: thumbnails,
      controller: controller,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    shootingController.dispose();
    settingsController.dispose();
    database.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
