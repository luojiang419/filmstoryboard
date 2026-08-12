import 'dart:io';

import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/features/projects/application/project_aspect_controller.dart';
import 'package:filmstoryboard/features/projects/data/project_aspect_repository.dart';
import 'package:filmstoryboard/features/projects/domain/project_aspect_ratio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppDatabase database;
  late ProjectAspectRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('project_aspect_');
    database = await AppDatabase.open(File('${root.path}/project.sqlite'));
    repository = ProjectAspectRepository(database);
  });

  tearDown(() async {
    database.dispose();
    await root.delete(recursive: true);
  });

  test('旧工程缺少画幅设置时保持16比9兼容', () {
    final state = repository.load();

    expect(state.mode, ProjectAspectMode.landscape);
    expect(state.effectiveRatio, ProjectAspectRatio.landscape16x9);
  });

  test('自动模式由首个竖屏视频确定并持久化9比16', () {
    repository.save(const ProjectAspectState(mode: ProjectAspectMode.auto));
    final controller = ProjectAspectController(repository: repository);
    addTearDown(controller.dispose);

    final result = controller.detectFromDimensions(width: 1080, height: 1920);

    expect(result, ProjectAspectDetectionResult.resolved);
    expect(controller.state.effectiveRatio, ProjectAspectRatio.portrait9x16);
    expect(repository.load().detectedRatio, ProjectAspectRatio.portrait9x16);
  });

  test('自动模式保留4比3和4比5等常见真实画幅', () {
    repository.save(const ProjectAspectState(mode: ProjectAspectMode.auto));
    final landscapeController = ProjectAspectController(repository: repository);
    addTearDown(landscapeController.dispose);

    expect(
      landscapeController.detectFromDimensions(width: 1440, height: 1080),
      ProjectAspectDetectionResult.resolved,
    );
    expect(
      landscapeController.state.effectiveRatio,
      ProjectAspectRatio.landscape4x3,
    );

    repository.save(const ProjectAspectState(mode: ProjectAspectMode.auto));
    final portraitController = ProjectAspectController(repository: repository);
    addTearDown(portraitController.dispose);
    expect(
      portraitController.detectFromDimensions(width: 1080, height: 1350),
      ProjectAspectDetectionResult.resolved,
    );
    expect(
      portraitController.state.effectiveRatio,
      ProjectAspectRatio.portrait4x5,
    );
  });

  test('自动模式已锁定后遇到相反朝向只报告冲突', () {
    repository.save(
      const ProjectAspectState(
        mode: ProjectAspectMode.auto,
        detectedRatio: ProjectAspectRatio.portrait9x16,
      ),
    );
    final controller = ProjectAspectController(repository: repository);
    addTearDown(controller.dispose);

    final result = controller.detectFromDimensions(width: 1920, height: 1080);

    expect(result, ProjectAspectDetectionResult.conflict);
    expect(controller.state.effectiveRatio, ProjectAspectRatio.portrait9x16);
  });

  test('手动竖屏模式不会被导入的横屏视频覆盖', () {
    repository.save(const ProjectAspectState(mode: ProjectAspectMode.portrait));
    final controller = ProjectAspectController(repository: repository);
    addTearDown(controller.dispose);

    final result = controller.detectFromDimensions(width: 1920, height: 1080);

    expect(result, ProjectAspectDetectionResult.unchanged);
    expect(controller.state.effectiveRatio, ProjectAspectRatio.portrait9x16);
  });
}
