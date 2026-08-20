import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:filmstoryboard/features/bridge/data/bridge_loopback_receiver.dart';

void main() {
  test(
    'exposes loopback capabilities and receives a raw bridge package',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-receiver-');
      addTearDown(() => root.delete(recursive: true));
      File? received;
      final receiver = BridgeLoopbackReceiver(
        directory: root,
        onPackage: (file) async {
          received = file;
          expect(await file.readAsBytes(), [1, 2, 3, 4]);
          return {'frame_count': 2};
        },
      );
      await receiver.start();
      addTearDown(receiver.stop);

      final client = http.Client();
      addTearDown(client.close);
      final base = Uri.parse('http://127.0.0.1:${receiver.boundPort}');
      final capabilities = await client.get(
        base.resolve('/api/canvas-bridges/shiyin/capabilities'),
      );
      expect(capabilities.statusCode, HttpStatus.ok);
      expect(capabilities.body, contains('filmstoryboard'));

      final response = await client.post(
        base.resolve('/api/canvas-bridges/shiyin/receive'),
        headers: {'Content-Type': 'application/zip'},
        body: [1, 2, 3, 4],
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('"frame_count":2'));
      expect(received, isNotNull);
      expect(received!.existsSync(), isFalse);
    },
  );
}
