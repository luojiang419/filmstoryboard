import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:filmstoryboard/app/app_shell.dart';
import 'package:filmstoryboard/app/app_theme.dart';
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/performance/performance_probe.dart';
import 'package:filmstoryboard/core/providers/app_providers.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/onboarding/data/onboarding_repository.dart';
import 'package:filmstoryboard/features/projects/application/project_service.dart';
import 'package:filmstoryboard/features/projects/data/project_catalog_repository.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_models.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_generation_models.dart';
import 'package:filmstoryboard/features/updater/application/updater_controller.dart';
import 'package:filmstoryboard/features/updater/data/updater_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets(
    '500 shots: real Windows page switching and bounded generation rows',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('film_profile_');
      final directories = await AppDirectories.create(
        executableDirectory: root,
      );
      final global = await AppDatabase.open(directories.databaseFile);
      global.setSetting(
        OnboardingRepository.completedVersionKey,
        '${OnboardingRepository.currentVersion}',
      );
      final service = ProjectService(catalog: ProjectCatalogRepository(global));
      var session = await service.createProject(
        name: '性能验收工程',
        parentDirectory: directories.projects,
      );
      final indexFile = session.directories.indexFile;
      final scriptRepository = ShootingScriptRepository(session.database);
      final now = DateTime.now().toUtc();
      scriptRepository.upsertScript(
        ShootingScript(
          id: 'profile-script',
          name: '500 镜头',
          sourceStoryboardId: null,
          sourceVideoId: null,
          status: ShootingScriptStatus.draft,
          version: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
      scriptRepository.replaceShots(
        'profile-script',
        List.generate(
          500,
          (index) => ScriptShot(
            id: 'shot-$index',
            scriptId: 'profile-script',
            shotNumber: index + 1,
            durationSeconds: 5,
            framePath: '',
            visual: '',
            content: '镜头内容 $index',
            shotSize: '中景',
            cameraMovement: '',
            cameraNotes: '',
            scene: '',
            productCode: '',
            productStyling: '',
            dialogue: '',
            sound: '',
            prompt: '人物转身看向窗外，光线柔和。',
            status: ProcessingStatus.completed,
            updatedAt: now,
          ),
        ),
      );
      final tasks = VideoGenerationRepository(session.database);
      session.database.executeStatement('BEGIN;');
      for (var index = 0; index < 500; index++) {
        tasks.upsertTask(
          VideoGenerationTask(
            id: 'task-$index',
            scriptId: 'profile-script',
            shotId: 'shot-$index',
            generationId: 'fixture-$index',
            model: 'fixture',
            durationSeconds: 5,
            promptMode: VideoPromptMode.original,
            prompt: 'fixture',
            status: VideoGenerationTaskStatus.completed,
            localPath: File('.tmp/perf_fixture.mp4').absolute.path,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
          ),
        );
      }
      session.database.executeStatement('COMMIT;');
      await session.close();
      final frames = <FrameTiming>[];
      void collect(List<FrameTiming> timings) => frames.addAll(timings);
      binding.addTimingsCallback(collect);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      );
      final opening = Stopwatch()..start();
      session = await service.openProject(indexFile);
      opening.stop();
      final settingsRepository = SettingsRepository(global, directories);
      final settings = SettingsController(
        repository: settingsRepository,
        initialSettings: settingsRepository.load(),
      );
      final updater = _OfflineUpdater(
        settingsController: settings,
        settingsRepository: settingsRepository,
        service: UpdaterService(directories: directories),
      );
      final container = ProviderContainer(
        overrides: [
          appDirectoriesProvider.overrideWithValue(directories),
          globalDatabaseProvider.overrideWithValue(global),
          appDatabaseProvider.overrideWithValue(session.database),
          projectDirectoriesProvider.overrideWithValue(session.directories),
          settingsRepositoryProvider.overrideWithValue(settingsRepository),
          settingsControllerProvider.overrideWithValue(settings),
          updaterControllerProvider.overrideWithValue(updater),
          videoGenerationControllerProvider.overrideWith((ref) {
            final controller = _OfflineGeneration(
              repository: VideoGenerationRepository(session.database),
              videoRepository: VideoAnalysisRepository(session.database),
              shootingScriptController: ref.watch(
                shootingScriptControllerProvider,
              ),
              replicateController: ref.watch(replicateControllerProvider),
              directories: session.directories,
              settingsController: settings,
            );
            ref.onDispose(controller.dispose);
            return controller;
          }),
        ],
      );
      final shell = Stopwatch()..start();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const AppShell(enableWindowControls: false),
          ),
        ),
      );
      shell.stop();
      await tester.pump(const Duration(milliseconds: 200));
      final timings = <Map<String, Object?>>[];
      const labels = ['视频解析', '故事板', '影视制作', '视频生成', '导出', '设置', '设计分镜图'];
      final probe = PerformanceProbe.shared;
      probe.clear();
      for (var round = 0; round < 4; round++) {
        for (final label in labels) {
          final watch = Stopwatch()..start();
          await tester.tap(find.text(label).last);
          await tester.pump();
          watch.stop();
          timings.add({
            'round': round,
            'page': label,
            'input_to_pump_ms': watch.elapsedMicroseconds / 1000,
          });
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
          if (label == '影视制作') {
            final rows = find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'replicate-asset-row-',
                  ),
            );
            expect(rows.evaluate().length, lessThan(20));
          }
          if (label == '视频生成') {
            final rows = find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'generation-row-',
                  ),
            );
            expect(rows.evaluate().length, lessThan(20));
          }
        }
      }
      await tester.pump(const Duration(seconds: 1));
      final builds =
          frames
              .map((frame) => frame.buildDuration.inMicroseconds / 1000)
              .toList()
            ..sort();
      final rasters =
          frames
              .map((frame) => frame.rasterDuration.inMicroseconds / 1000)
              .toList()
            ..sort();
      double percentile(List<double> values, double p) =>
          values.isEmpty ? 0 : values[((values.length - 1) * p).round()];
      final report = <String, Object?>{
        'mode': 'Windows profile',
        'shots': 500,
        'tasks': 500,
        'database_open_ms': opening.elapsedMilliseconds,
        'shell_first_pump_ms': shell.elapsedMilliseconds,
        'navigation': timings,
        'frame_count': builds.length,
        'ui_p95_ms': percentile(builds, .95),
        'ui_max_ms': percentile(builds, 1),
        'raster_p95_ms': percentile(rasters, .95),
        'raster_max_ms': percentile(rasters, 1),
        'counters': probe.counters.values,
      };
      final warmNavigation =
          timings
              .where((item) => item['round'] != 0)
              .map((item) => item['input_to_pump_ms']! as double)
              .toList()
            ..sort();
      report['warm_navigation_p95_ms'] = percentile(warmNavigation, .95);
      binding.reportData = report;
      final output = File('.tmp/workspace-performance-profile.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      expect(
        probe.counters['media.inline_created'],
        0,
        reason: 'Browsing must not open native players.',
      );
      expect(
        percentile(warmNavigation, .95),
        lessThan(100),
        reason: 'Warm navigation responsiveness budget',
      );
      expect(
        percentile(builds, .95),
        lessThan(30),
        reason: 'UI frame P95 regression budget',
      );
      binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      updater.dispose();
      settings.dispose();
      await session.close();
      global.dispose();
      await root.delete(recursive: true);
    },
  );
}

class _OfflineGeneration extends VideoGenerationController {
  _OfflineGeneration({
    required super.repository,
    required super.videoRepository,
    required super.shootingScriptController,
    required super.replicateController,
    required super.directories,
    required super.settingsController,
  });
  @override
  bool get shouldRequestActiveCliInstall => false;
  @override
  bool get shouldRequestActiveCliLogin => false;
}

class _OfflineUpdater extends UpdaterController {
  _OfflineUpdater({
    required super.settingsController,
    required super.settingsRepository,
    required super.service,
  });
  @override
  Future<void> beginStartupFlow() async {}
}
