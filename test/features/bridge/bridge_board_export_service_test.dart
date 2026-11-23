import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:filmstoryboard/features/bridge/data/bridge_board_export_service.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_loopback_client.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

void main() {
  test(
    'export uses selected board identity and advertises workflow without an active canvas target',
    () async {
      final root = await Directory.systemTemp.createTemp('workflow-export-');
      addTearDown(() => root.delete(recursive: true));
      final image = File('${root.path}/frame.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 16, height: 9)));
      final board = StoryboardBoard(
        id: 'board-selected',
        name: '所选画板',
        width: 1920,
        height: 1080,
        rows: 1,
        columns: 1,
        gap: 0,
        items: [
          StoryboardItem(
            asset: StoryboardCutAsset(
              id: 'asset-1',
              imageId: 'image-1',
              sourceName: 'frame.png',
              path: image.path,
              indexNo: 1,
            ),
            caption: '镜头内容',
            slotIndex: 0,
          ),
        ],
      );
      var supportsWorkflow = true;
      var submissions = 0;
      final client = BridgeLoopbackClient(
        ports: const [3000],
        client: MockClient((request) async {
          if (request.url.path.endsWith('/capabilities')) {
            return http.Response(
              jsonEncode({
                'app': 'shiyin-ai',
                'schema': 'shiyin-film-bridge',
                'automatic_receive': true,
                'direct_receive': true,
                'dedicated_board_projects': true,
                'workflow_receive': supportsWorkflow,
                'active_canvas_id': 'unrelated',
              }),
              200,
            );
          }
          submissions++;
          final body = latin1.decode(request.bodyBytes);
          expect(body, contains('film-production-v1'));
          expect(body, contains('board-selected'));
          expect(body, contains('source_storyboard_asset_id'));
          expect(body, isNot(contains('name="canvas_id"')));
          return http.Response(
            jsonEncode({
              'ok': true,
              'canvas_id': 'new-canvas',
              'group_id': 'board-group',
              'frame_count': 1,
              'workflow_node_ids': ['prepare', 'confirm', 'video'],
              'workflow_ready': true,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await const BridgeBoardExportService().send(
        board: board,
        projectId: 'project',
        projectName: '项目',
        workflow: true,
        client: client,
      );
      expect(result.canvasId, 'new-canvas');
      expect(submissions, 1);
      supportsWorkflow = false;
      await expectLater(
        const BridgeBoardExportService().send(
          board: board,
          projectId: 'project',
          projectName: '项目',
          workflow: true,
          client: client,
        ),
        throwsA(isA<BridgeLoopbackException>()),
      );
      expect(submissions, 1, reason: '旧接收端不能静默降级成仅图片导出');
    },
  );
}
