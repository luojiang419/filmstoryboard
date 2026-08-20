import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:filmstoryboard/features/bridge/data/bridge_loopback_client.dart';

void main() {
  test('discovers SHIYIN and sends package to automatic receiver', () async {
    final directory = await Directory.systemTemp.createTemp('bridge-loopback-');
    addTearDown(() => directory.delete(recursive: true));
    final package = File('${directory.path}/bridge.zip')
      ..writeAsBytesSync([1, 2, 3]);
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode({
            'app': 'shiyin-ai',
            'schema': 'shiyin-film-bridge',
            'automatic_receive': true,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'ok': true,
          'canvas_id': 'canvas-1',
          'group_id': 'group-1',
          'frame_count': 4,
          'editor_url': '/static/canvas.html?id=canvas-1',
        }),
        200,
      );
    });
    final bridge = BridgeLoopbackClient(client: client, ports: const [3000]);
    final result = await bridge.sendPackage(
      packageFile: package,
      canvasTitle: '测试故事板',
    );
    expect(result.canvasId, 'canvas-1');
    expect(result.frameCount, 4);
    expect(result.editorUri.toString(), contains('canvas-1'));
    expect(requests, hasLength(2));
    bridge.close();
  });

  test('reports missing SHIYIN receiver', () async {
    final bridge = BridgeLoopbackClient(
      client: MockClient((_) async => http.Response('not found', 404)),
      ports: const [3000],
    );
    expect(bridge.discover(), throwsA(isA<BridgeLoopbackException>()));
    bridge.close();
  });
}
