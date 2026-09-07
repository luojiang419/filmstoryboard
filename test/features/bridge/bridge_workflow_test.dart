import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/core/database/app_database.dart';
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_workflow_server.dart';
import 'package:filmstoryboard/features/bridge/application/bridge_workflow_controller.dart';
import 'package:filmstoryboard/features/replicate/application/replicate_controller.dart';
import 'package:filmstoryboard/features/replicate/data/replicate_repository.dart';
import 'package:filmstoryboard/features/settings/application/settings_controller.dart';
import 'package:filmstoryboard/features/settings/data/settings_repository.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_script_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_analysis_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/script_asset_binding_controller.dart';
import 'package:filmstoryboard/features/shooting_script/application/shooting_asset_library_controller.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_script_workflow_repository.dart';
import 'package:filmstoryboard/features/shooting_script/data/shooting_asset_library_repository.dart';
import 'package:filmstoryboard/features/storyboard/application/storyboard_controller.dart';
import 'package:filmstoryboard/features/video_generation/application/video_generation_controller.dart';
import 'package:filmstoryboard/features/video_generation/data/video_generation_repository.dart';
import 'package:filmstoryboard/features/video_analysis/data/video_analysis_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'loopback workflow requires token, rejects browser origin and wrong project',
    () async {
      final server = BridgeWorkflowServer(
        port: 0,
        projectId: 'project',
        onRequest: (body) async => {'action': body['action']},
      );
      await server.start();
      addTearDown(server.stop);
      final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
      final caps =
          jsonDecode((await http.get(base.resolve('/capabilities'))).body)
              as Map;
      expect(caps['workflow_version'], 1);
      expect(
        (await http.get(
          base.resolve('/capabilities'),
          headers: {'Origin': 'https://example.com'},
        )).statusCode,
        403,
      );
      expect(
        (await http.post(base.resolve('/workflow'), body: '{}')).statusCode,
        403,
      );
      final headers = {
        'X-Workflow-Token': '${caps['token']}',
        'Content-Type': 'application/json',
      };
      expect(
        (await http.post(
          base.resolve('/workflow'),
          headers: headers,
          body: jsonEncode({'project_id': 'wrong'}),
        )).statusCode,
        400,
      );
      final response = await http.post(
        base.resolve('/workflow'),
        headers: headers,
        body: jsonEncode({'project_id': 'project', 'action': 'snapshot'}),
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body)['action'], 'snapshot');
    },
  );

  test(
    'real controllers persist group scripts, preserve edits and bind assets without generation',
    () async {
      final root = await Directory.systemTemp.createTemp('film-workflow-test-');
      final dirs = await AppDirectories.create(executableDirectory: root);
      final database = await AppDatabase.open(dirs.databaseFile);
      final settingsRepo = SettingsRepository(database, dirs);
      final settings = SettingsController(
        repository: settingsRepo,
        initialSettings: settingsRepo.load(),
      );
      final scripts = ShootingScriptController(
        repository: ShootingScriptRepository(database),
        directories: dirs,
      );
      final boards = StoryboardController(
        database: database,
        directories: dirs,
        settingsController: settings,
      );
      final workflowRepo = ShootingScriptWorkflowRepository(database);
      final library = ShootingAssetLibraryController(
        repository: ShootingAssetLibraryRepository(
          database: database,
          directories: dirs,
        ),
        directories: dirs,
      );
      final binding = ShootingScriptAssetBindingController(
        shootingScriptController: scripts,
        libraryController: library,
        repository: workflowRepo,
        settingsController: settings,
      );
      final analysis = ShootingScriptAnalysisController(
        shootingScriptController: scripts,
        repository: workflowRepo,
        settingsController: settings,
      );
      final replicate = ReplicateController(
        repository: ReplicateRepository(database),
        shootingScriptController: scripts,
        directories: dirs,
        settingsController: settings,
        workflowRepository: workflowRepo,
        assetBindingController: binding,
      );
      final video = VideoGenerationController(
        repository: VideoGenerationRepository(database),
        videoRepository: VideoAnalysisRepository(database),
        shootingScriptController: scripts,
        replicateController: replicate,
        directories: dirs,
        settingsController: settings,
        workflowRepository: workflowRepo,
      );
      late final BridgeWorkflowController controller;
      final server = BridgeWorkflowServer(
        port: 0,
        projectId: 'project',
        onRequest: (body) => controller.handle(body),
      );
      controller = BridgeWorkflowController(
        scripts: scripts,
        storyboards: boards,
        replicate: replicate,
        analysis: analysis,
        binding: binding,
        library: library,
        video: video,
        directories: dirs,
        server: server,
      );
      addTearDown(() async {
        await server.stop();
        video.dispose();
        analysis.dispose();
        replicate.dispose();
        binding.dispose();
        library.dispose();
        boards.dispose();
        scripts.dispose();
        settings.dispose();
        database.dispose();
        await root.delete(recursive: true);
      });
      final data = base64Encode(img.encodePng(img.Image(width: 16, height: 9)));
      final command = <String, Object?>{
        'action': 'sync',
        'group_key': 'canvas:prepare:group',
        'name': '测试画板',
        'frames': [
          {'id': 'frame-a', 'name': 'A', 'data': data},
          {'id': 'frame-b', 'name': 'B', 'data': data},
        ],
      };
      final first = (await controller.handle(command))['snapshot'] as Map;
      final id = first['scriptId'] as String;
      expect(first['shots'], hasLength(2));
      final shotId = scripts.value.shots.first.id;
      await controller.handle({
        'action': 'edit-shot',
        'script_id': id,
        'shot_id': shotId,
        'parameters': {'content': '用户编辑的描述', 'prompt': '用户提示词'},
      });
      await controller.handle({
        'action': 'confirm',
        'script_id': id,
        'shot_id': shotId,
      });
      await controller.handle({
        'action': 'parameters',
        'script_id': id,
        'parameters': {'replicationInstructions': '保留衣服细节'},
      });
      final again = (await controller.handle(command))['snapshot'] as Map;
      expect(again['scriptId'], id);
      expect(scripts.value.scripts.where((s) => s.id == id), hasLength(1));
      expect(scripts.value.shots.first.id, shotId);
      expect(scripts.value.shots.first.content, '用户编辑的描述');
      expect((again['parameters'] as Map)['replicationInstructions'], '保留衣服细节');
      expect(replicate.value.run!.confirmedShotIds, contains(shotId));
      final job =
          (await controller.handle({
                'action': 'import-asset',
                'script_id': id,
                'shot_id': shotId,
                'asset_type': 'character',
                'name': '演员',
                'asset': {'data': data},
                'request_id': 'import-1',
              }))['job']
              as Map;
      while (job['status'] == 'running') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(job['status'], 'completed', reason: '${job['error']}');
      expect(binding.value.linksForShot(shotId), hasLength(1));
      expect(video.value.tasks, isEmpty);
      expect(
        await controller.handle({
          'action': 'import-asset',
          'script_id': id,
          'request_id': 'import-1',
        }),
        contains('job'),
      );
      expect(library.value.items, hasLength(1));
      await expectLater(
        controller.handle({
          'action': 'edit-shot',
          'script_id': id,
          'shot_id': 'unrelated',
          'parameters': {'prompt': 'invalid'},
        }),
        throwsFormatException,
      );
      // 新图片组使用独立稳定来源，不覆盖原脚本。
      final second =
          (await controller.handle({
                ...command,
                'group_key': 'canvas:prepare:other',
              }))['snapshot']
              as Map;
      expect(second['scriptId'], isNot(id));
    },
  );
}
