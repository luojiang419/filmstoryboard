// 显式提供真实画板 JSON 才运行；只调用与导出按钮相同的发送服务，不进行生成。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/features/bridge/data/bridge_board_export_service.dart';
import 'package:filmstoryboard/features/storyboard/domain/storyboard_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final input = Platform.environment['FILM_INSTALLED_EXPORT_INPUT'];
  test(
    'installed apps export real source board to dedicated canvas and reuse it',
    () async {
      final data = jsonDecode(await File(input!).readAsString()) as Map;
      final value = data['board'] as Map;
      final board = StoryboardBoard(
        id: value['id'] as String,
        name: value['name'] as String,
        width: (value['width'] as num).toInt(),
        height: (value['height'] as num).toInt(),
        rows: (value['rows'] as num).toInt(),
        columns: (value['columns'] as num).toInt(),
        gap: (value['gap'] as num).toDouble(),
        items: [
          for (final item in value['items'] as List)
            StoryboardItem(
              slotIndex: (item['slotIndex'] as num).toInt(),
              caption: '${item['caption'] ?? ''}',
              asset: StoryboardCutAsset(
                id: item['asset']['id'] as String,
                imageId: item['asset']['imageId'] as String,
                sourceName: item['asset']['sourceName'] as String,
                path: item['asset']['path'] as String,
                indexNo: (item['asset']['indexNo'] as num).toInt(),
              ),
            ),
        ],
      );
      const sender = BridgeBoardExportService();
      final first = await sender.send(
        board: board,
        projectId: data['project_id'] as String,
        projectName: data['project_name'] as String,
        workflow: true,
      );
      expect(first.canvasId, isNot(data['wrong_canvas_id']));
      expect(first.frameCount, board.items.length);
      expect(first.canvasTitle, board.name);
      final repeat = await sender.send(
        board: board,
        projectId: data['project_id'] as String,
        projectName: data['project_name'] as String,
        workflow: false,
      );
      expect(repeat.canvasId, first.canvasId);
      expect(repeat.groupId, first.groupId);
      final result = {
        'canvas_id': first.canvasId,
        'canvas_title': first.canvasTitle,
        'group_id': first.groupId,
        'frame_count': first.frameCount,
        'repeat_same_canvas': true,
      };
      await File('$input.result.json').writeAsString(jsonEncode(result));
      // 回执只含项目标识与数量，不打印图片、提示词或工作流令牌。
    },
    skip: input == null
        ? '需要显式指定 FILM_INSTALLED_EXPORT_INPUT，并事先备份与获得真实导出授权'
        : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
