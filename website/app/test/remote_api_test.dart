import 'dart:convert';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('配对请求使用同源 API 并解析 HttpOnly 会话响应', () async {
    late http.Request captured;
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'session': {
              'id': 'session-1',
              'clientName': '导演平板',
              'role': 'director',
              'expiresAt': '2026-08-11T00:00:00Z',
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.pair(code: '123456', clientName: '导演平板');

    expect(captured.url.path, '/api/v1/auth/pair');
    expect(captured.method, 'POST');
    expect(jsonDecode(captured.body)['code'], '123456');
    expect(result.session.role, 'director');
  });

  test('409 响应保留 revision_conflict 和当前版本', () async {
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {
                'code': 'revision_conflict',
                'message': '拍摄脚本已在其他位置更新',
                'details': {'currentVersion': 8},
              },
            }),
          ),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    expect(
      () => api.updateShot(
        scriptId: 'script',
        shotId: 'shot',
        expectedVersion: 7,
        changes: const {'content': '新内容'},
      ),
      throwsA(
        isA<RemoteApiFailure>()
            .having((error) => error.code, 'code', 'revision_conflict')
            .having(
              (error) => error.details['currentVersion'],
              'currentVersion',
              8,
            ),
      ),
    );
  });

  test('故事板编辑使用修订号并解析安全媒体投影', () async {
    late http.Request captured;
    final api = HttpRemoteApi(
      baseUri: Uri.parse('https://director.example.com'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'id': 'board-1',
            'name': '导演审阅版',
            'revision': 6,
            'locked': false,
            'rows': 1,
            'columns': 1,
            'itemCount': 1,
            'annotationCount': 0,
            'unresolvedAnnotationCount': 0,
            'width': 1920,
            'height': 1080,
            'gap': 18,
            'storyDescriptionEnabled': true,
            'rowDescriptionEnabled': false,
            'rowCaptions': [''],
            'rowDividerEnabled': true,
            'rowDividerStyle': 'dashed',
            'rowDividerOpacity': .35,
            'titleAlignment': 'center',
            'portraitMode': false,
            'items': [
              {
                'assetId': 'asset-1',
                'sourceName': '焦点帧',
                'indexNo': 1,
                'caption': '新的描述',
                'slotIndex': 0,
                'imageMediaId': 'media-safe-id',
              },
            ],
            'annotations': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final detail = await api.updateStoryboard(
      storyboardId: 'board-1',
      expectedRevision: 5,
      changes: const {
        'itemCaptions': {'asset-1': '新的描述'},
      },
    );

    expect(captured.method, 'PATCH');
    expect(captured.url.path, '/api/v1/storyboards/board-1');
    expect(jsonDecode(captured.body)['expectedRevision'], 5);
    expect(detail.revision, 6);
    expect(detail.items.single.imageMediaId, 'media-safe-id');
  });
}
