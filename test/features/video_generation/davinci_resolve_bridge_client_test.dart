import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/video_generation/data/davinci_resolve_bridge_client.dart';
import 'package:filmstoryboard/features/video_generation/domain/video_timeline_snapshot.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('健康检查只访问 localhost 并携带共享令牌', () async {
    final client = DaVinciResolveBridgeClient(
      tokenProvider: () async => 'test-token-123456789012345678901234567890',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://127.0.0.1:47861/v1/health');
        expect(
          request.headers['X-FilmStoryboard-Token'],
          'test-token-123456789012345678901234567890',
        );
        return http.Response(
          jsonEncode({
            'status': 'ok',
            'pluginVersion': '1.0.0',
            'resolveVersion': '21.0.0.47',
            'projectName': '剪辑项目',
            'projectId': 'resolve-project-1',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final health = await client.health();

    expect(health.pluginVersion, '1.0.0');
    expect(health.resolveVersion, '21.0.0.47');
    expect(health.projectName, '剪辑项目');
    expect(health.projectId, 'resolve-project-1');
  });

  test('同步请求发送完整时间线快照并解析结果', () async {
    final snapshot = _snapshot();
    final client = DaVinciResolveBridgeClient(
      tokenProvider: () async => 'test-token-123456789012345678901234567890',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'http://127.0.0.1:47861/v1/timelines/sync',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['schemaVersion'], 1);
        expect(body['scriptId'], 'script-1');
        expect(body['revision'], snapshot.revision);
        expect((body['clips'] as List), hasLength(1));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'status': 'ok',
              'timelineName': '拍摄脚本',
              'revision': snapshot.revision,
              'created': true,
              'unchanged': false,
              'importedClipCount': 1,
              'syncedClipCount': 1,
              'removedClipCount': 0,
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await client.sync(snapshot);

    expect(result.timelineName, '拍摄脚本');
    expect(result.revision, snapshot.revision);
    expect(result.created, isTrue);
    expect(result.unchanged, isFalse);
    expect(result.importedClipCount, 1);
    expect(result.syncedClipCount, 1);
  });

  test('插件未启动时返回可自动恢复的离线错误', () async {
    final client = DaVinciResolveBridgeClient(
      tokenProvider: () async => 'test-token-123456789012345678901234567890',
      client: MockClient((_) async => throw const SocketException('offline')),
    );

    expect(
      client.health,
      throwsA(
        isA<DaVinciBridgeException>()
            .having((error) => error.message, 'message', contains('未检测到达芬奇'))
            .having(
              (error) => error.kind,
              'kind',
              DaVinciBridgeFailureKind.pluginUnavailable,
            ),
      ),
    );
  });

  test('响应超时使用独立错误类型避免误判插件状态', () async {
    final pendingResponse = Completer<http.Response>();
    final client = DaVinciResolveBridgeClient(
      timeout: const Duration(milliseconds: 1),
      tokenProvider: () async => 'test-token-123456789012345678901234567890',
      client: MockClient((_) => pendingResponse.future),
    );

    expect(
      client.health,
      throwsA(
        isA<DaVinciBridgeException>()
            .having(
              (error) => error.kind,
              'kind',
              DaVinciBridgeFailureKind.timeout,
            )
            .having((error) => error.message, 'message', contains('响应超时')),
      ),
    );
  });
}

VideoTimelineSnapshot _snapshot() => VideoTimelineSnapshot(
  scriptId: 'script-1',
  scriptName: '拍摄脚本',
  width: 1920,
  height: 1080,
  frameRate: const VideoTimelineFrameRate.standard(30),
  generatedAt: DateTime.utc(2026, 8, 12),
  clips: const [
    VideoTimelineSnapshotClip(
      shotId: 'shot-1',
      shotNumber: 1,
      timelineShotNumber: 1,
      taskId: 'task-1',
      filePath: r'G:\project\shot-1.mp4',
      fileSize: 1024,
      fileModifiedAtMs: 1000,
      sourceDurationMs: 5000,
      trimInMs: 500,
      trimOutMs: 4500,
      sourceDurationFrames: 150,
      sourceInFrame: 15,
      sourceOutFrame: 135,
      recordStartFrame: 0,
      recordEndFrame: 120,
      sourceWidth: 1920,
      sourceHeight: 1080,
      sourceFrameRate: 30,
      hasAudio: true,
    ),
  ],
);
