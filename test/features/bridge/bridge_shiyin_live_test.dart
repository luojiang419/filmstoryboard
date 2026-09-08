// 使用隔离 SHIYIN 后端，不要指向日常使用的数据目录。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/features/bridge/data/bridge_board_export_service.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_loopback_client.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_workflow_server.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final port = int.tryParse(
    Platform.environment['FILM_SHIYIN_TEST_PORT'] ?? '',
  );
  test(
    'real Dart sender creates grouped canvases and Python calls real Dart workflow',
    () async {
      final base = Uri.parse('http://127.0.0.1:$port');
      final root = await Directory.systemTemp.createTemp('film-live-bridge-');
      addTearDown(() => root.delete(recursive: true));
      final image = File('${root.path}/frame.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 16, height: 9)));
      StoryboardBoard board(String id) => StoryboardBoard(
        id: id,
        name: '联调画板 $id',
        width: 1920,
        height: 1080,
        rows: 1,
        columns: 1,
        gap: 0,
        items: [
          StoryboardItem(
            slotIndex: 0,
            caption: '真实直传镜头',
            asset: StoryboardCutAsset(
              id: 'asset-$id',
              imageId: 'image-$id',
              sourceName: 'frame.png',
              path: image.path,
              indexNo: 1,
            ),
          ),
        ],
      );
      final client = BridgeLoopbackClient(ports: [port!]);
      addTearDown(client.close);
      final calls = <Map<String, Object?>>[];
      final server = BridgeWorkflowServer(
        projectId: 'live-project',
        onRequest: (body) async {
          calls.add(body);
          return {
            'snapshot': {'scriptId': 'live-script', 'shots': []},
          };
        },
      );
      await server.start();
      addTearDown(server.stop);
      Future<BridgeLoopbackResult> send(String id, bool workflow) =>
          const BridgeBoardExportService().send(
            board: board(id),
            projectId: 'live-project',
            projectName: '隔离联调',
            workflow: workflow,
            client: client,
          );
      final first = await send('export', true);
      final second = await send('storyboard', false);
      expect(second.canvasId, isNot(first.canvasId));
      final repeat = await send('export', true);
      expect(repeat.canvasId, first.canvasId);
      expect(repeat.groupId, first.groupId);
      final login = await http.post(
        base.resolve('/api/account/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'account': 'jiang', 'password': 'jiang'}),
      );
      expect(login.statusCode, 200);
      final headers = {
        'Cookie': login.headers['set-cookie']!.split(';').first,
        'Content-Type': 'application/json',
      };
      Future<Map> graph(String id) async =>
          (jsonDecode(
                    (await http.get(
                      base.resolve('/api/canvases/$id'),
                      headers: headers,
                    )).body,
                  )
                  as Map)['canvas']
              as Map;
      final firstGraph = await graph(first.canvasId);
      final secondGraph = await graph(second.canvasId);
      final nodes = (firstGraph['nodes'] as List).cast<Map>();
      expect(nodes.where((n) => n['type'] == 'group'), hasLength(4));
      expect(firstGraph['connections'], hasLength(3));
      expect(calls, hasLength(2), reason: '导出后端直接建立脚本，无需打开网页');
      for (final node in nodes.where((n) => n['workflowKey'] != null)) {
        expect(node['workflowScriptId'], 'live-script');
        expect(node['workflowSnapshot']['scriptId'], 'live-script');
      }
      final secondNodes = (secondGraph['nodes'] as List).cast<Map>();
      final group = secondNodes.singleWhere((n) => n['type'] == 'group');
      expect(group['bridgeProjectId'], 'live-project');
      expect(group['items'], [
        secondNodes.singleWhere((n) => n['type'] == 'image')['id'],
      ]);
      final received = await http.get(
        base.resolve(
          nodes.singleWhere((n) => n['type'] == 'image')['url'] as String,
        ),
        headers: headers,
      );
      expect(received.bodyBytes, image.readAsBytesSync());
      final response = await http.post(
        base.resolve('/api/canvas-film-workflow'),
        headers: headers,
        body: jsonEncode({
          'canvas_id': first.canvasId,
          'node_id': nodes.singleWhere(
            (n) => n['type'] == 'film-prepare-assets',
          )['id'],
          'action': 'sync',
          'graph': firstGraph,
        }),
      );
      expect(response.statusCode, 200, reason: response.body);
      expect(jsonDecode(response.body)['snapshot']['scriptId'], 'live-script');
      expect(calls.last['source_board_id'], 'export');
      expect(
        base64Decode(
          ((calls.last['frames'] as List).single as Map)['data'] as String,
        ),
        image.readAsBytesSync(),
      );
    },
    skip: port == null ? '设置 FILM_SHIYIN_TEST_PORT 指向隔离 SHIYIN 后端' : false,
  );
}
