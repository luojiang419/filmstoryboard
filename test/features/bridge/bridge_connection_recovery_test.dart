import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_workflow_server.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_loopback_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'occupied preferred port falls back and concurrent starts use one listener',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);
      final server = BridgeWorkflowServer(
        projectId: 'source',
        port: occupied.port,
        fallbackPorts: const [0],
        onRequest: (_) async => {},
      );
      addTearDown(server.stop);
      await Future.wait([server.start(), server.start()]);
      final port = server.boundPort;
      expect(port, isNotNull);
      expect(port, isNot(occupied.port));
      await server.start();
      expect(server.boundPort, port);
      final response = await http.get(
        Uri.parse('http://127.0.0.1:$port/capabilities'),
      );
      expect(jsonDecode(response.body)['project_id'], 'source');
      await server.stop();
      expect(server.boundPort, isNull);
      final released = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port!,
      );
      await released.close();
    },
  );

  test('disposing while bind is pending leaves no listener', () async {
    final server = BridgeWorkflowServer(
      projectId: 'source',
      port: 0,
      onRequest: (_) async => {},
    );
    final starting = server.start();
    await server.stop();
    await starting;
    expect(server.boundPort, isNull);
  });

  test(
    'export validates persisted group, frames, workflow and editor URL',
    () async {
      final dir = await Directory.systemTemp.createTemp('bridge-receipt-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.png')..writeAsBytesSync([1]);
      final receipt = <String, Object?>{
        'ok': true,
        'canvas_id': 'created',
        'group_id': 'group',
        'frame_count': 1,
        'workflow_node_ids': ['prepare', 'confirm', 'video'],
        'workflow_ready': true,
      };
      final bridge = BridgeLoopbackClient(
        ports: const [3000],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/capabilities')) {
            return http.Response(
              jsonEncode({
                'app': 'shiyin-ai',
                'schema': 'shiyin-film-bridge',
                'automatic_receive': true,
                'direct_receive': true,
                'workflow_receive': true,
              }),
              200,
            );
          }
          return http.Response(jsonEncode(receipt), 200);
        }),
      );
      addTearDown(bridge.close);
      Future<BridgeLoopbackResult> send() => bridge.sendDirect(
        manifest: const {},
        uploads: [BridgeDirectUpload(file: file, uploadName: 'a.png')],
        canvasTitle: 'board',
        requireWorkflow: true,
      );
      final result = await send();
      expect(
        result.editorUri.toString(),
        'http://127.0.0.1:3000/static/canvas.html?id=created',
      );
      for (final change in <Map<String, Object?>>[
        {'canvas_id': ''},
        {'group_id': ''},
        {'frame_count': 0},
        {'frame_count': 2},
        {'workflow_node_ids': null},
        {'workflow_ready': false, 'workflow_warning': 'film offline'},
        {'workflow_ready': null},
        {
          'workflow_node_ids': ['a', 'a', 'a'],
        },
        {'editor_url': '/'},
        {'editor_url': '/static/canvas.html?id=other'},
        {'editor_url': 'https://example.com/static/canvas.html?id=created'},
      ]) {
        final saved = Map<String, Object?>.from(receipt);
        receipt.addAll(change);
        await expectLater(send(), throwsA(isA<BridgeLoopbackException>()));
        receipt
          ..clear()
          ..addAll(saved);
      }
    },
  );
}
