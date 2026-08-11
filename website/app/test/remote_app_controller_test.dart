import 'dart:typed_data';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:filmstoryboard_remote_web/core/models/remote_models.dart';
import 'package:filmstoryboard_remote_web/features/workspace/remote_app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('刷新工作区会加载故事板列表和当前详情', () async {
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..storyboardsAvailable = true;
    addTearDown(controller.dispose);

    await controller.refreshAll();

    expect(controller.storyboards.single.id, 'board-1');
    expect(controller.selectedStoryboard?.revision, 1);
    expect(controller.selectedStoryboardItem?.assetId, 'asset-1');
    expect(api.storyboardDetailRequests, 1);
  });

  test('故事板 409 冲突会自动恢复最新详情且 viewer 不会写入', () async {
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
      ..phase = RemoteAppPhase.ready
      ..session = _director
      ..storyboardsAvailable = true;
    addTearDown(controller.dispose);
    await controller.refreshAll();
    api
      ..detail = _detail(revision: 2, caption: '桌面端新内容')
      ..conflictOnUpdate = true;

    await controller.saveSelectedStoryboard(const {
      'itemCaptions': {'asset-1': '远程旧内容'},
    });

    expect(controller.selectedStoryboard?.revision, 2);
    expect(controller.selectedStoryboardItem?.caption, '桌面端新内容');
    expect(controller.errorMessage, contains('已为你加载最新版本'));
    expect(api.updateRequests, 1);

    controller.session = const RemoteSession(
      id: 'viewer',
      clientName: '场记',
      role: 'viewer',
      expiresAt: null,
    );
    await controller.addStoryboardAnnotation(body: '不应写入');
    expect(api.annotationRequests, 0);
  });
}

const _director = RemoteSession(
  id: 'director',
  clientName: '远端导演',
  role: 'director',
  expiresAt: null,
);

RemoteStoryboardDetail _detail({
  required int revision,
  String caption = '初始描述',
}) => RemoteStoryboardDetail(
  id: 'board-1',
  name: '画板 1',
  groupId: null,
  revision: revision,
  locked: false,
  rows: 1,
  columns: 1,
  itemCount: 1,
  annotationCount: 0,
  unresolvedAnnotationCount: 0,
  width: 1920,
  height: 1080,
  gap: 18,
  storyDescriptionEnabled: true,
  rowDescriptionEnabled: false,
  rowCaptions: const [''],
  rowDividerEnabled: true,
  rowDividerStyle: 'dashed',
  rowDividerOpacity: .35,
  titleAlignment: 'center',
  portraitMode: false,
  storySummary: null,
  items: [
    RemoteStoryboardItem(
      assetId: 'asset-1',
      sourceName: '焦点帧',
      indexNo: 1,
      caption: caption,
      slotIndex: 0,
      flipHorizontal: false,
      flipVertical: false,
      resourceRemoved: false,
      imageMediaId: 'media-1',
    ),
  ],
  annotations: const [],
);

class _FakeRemoteApi implements RemoteApi {
  RemoteStoryboardDetail detail = _detail(revision: 1);
  bool conflictOnUpdate = false;
  int updateRequests = 0;
  int annotationRequests = 0;
  int storyboardDetailRequests = 0;

  @override
  Uri get baseUri => Uri.parse('http://localhost:47836');

  @override
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  }) async {
    annotationRequests++;
    return detail;
  }

  @override
  Future<Map<String, Object?>> capabilities() async => const {
    'capabilities': {'storyboards': true},
  };

  @override
  void close() {}

  @override
  Future<void> logout() async {}

  @override
  Future<RemoteMediaBytes> media(String id) async =>
      RemoteMediaBytes(bytes: Uint8List(0), contentType: 'image/png');

  @override
  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  }) async => const RemotePairResult(session: _director);

  @override
  Future<RemoteScriptDetail> script(String id) => throw UnimplementedError();

  @override
  Future<List<RemoteScriptSummary>> scripts() async => const [];

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) async {
    storyboardDetailRequests++;
    return detail;
  }

  @override
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards() async => (
    groups: const <RemoteStoryboardGroup>[],
    items: <RemoteStoryboardSummary>[detail],
  );

  @override
  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) => throw UnimplementedError();

  @override
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async {
    updateRequests++;
    if (conflictOnUpdate) {
      throw const RemoteApiFailure(
        statusCode: 409,
        code: 'revision_conflict',
        message: '故事板已更新',
        details: {'currentRevision': 2},
      );
    }
    return detail;
  }

  @override
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) async {
    annotationRequests++;
    return detail;
  }

  @override
  Future<String> webSocketTicket() async => 'ticket';

  @override
  Future<RemoteWorkspace> workspace() async => const RemoteWorkspace(
    phase: 'editor',
    project: RemoteProject(
      id: 'project',
      name: '项目 A',
      storyboardCount: 1,
      scriptCount: 0,
      shotCount: 0,
    ),
  );
}
