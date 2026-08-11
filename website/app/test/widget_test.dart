import 'dart:typed_data';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:filmstoryboard_remote_web/core/models/remote_models.dart';
import 'package:filmstoryboard_remote_web/features/auth/pairing_page.dart';
import 'package:filmstoryboard_remote_web/features/workspace/remote_app_controller.dart';
import 'package:filmstoryboard_remote_web/features/workspace/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('配对页展示安全说明和 6 位配对输入', (tester) async {
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.signedOut;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: PairingPage(controller: controller)),
    );

    expect(find.text('片场之外，\n也能一起定镜头。'), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
    expect(find.text('进入导演工作台'), findsOneWidget);
    expect(find.textContaining('模型密钥不会发送到浏览器'), findsOneWidget);
  });

  testWidgets('桌面宽度呈现工作台统计与脚本导航', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'session',
        clientName: '导演平板',
        role: 'director',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '项目 A',
          storyboardCount: 0,
          scriptCount: 1,
          shotCount: 1,
        ),
      )
      ..scripts = const [
        RemoteScriptSummary(
          id: 'script',
          name: '项目 A 拍摄脚本',
          status: 'active',
          version: 1,
          shotCount: 1,
          updatedAt: null,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );

    expect(find.text('导演工作台'), findsOneWidget);
    expect(find.text('项目 A'), findsWidgets);
    expect(find.text('镜头总数'), findsOneWidget);
    expect(find.text('最近拍摄脚本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演可进入故事板审阅并看到格位编辑与批注', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = RemoteStoryboardDetail(
      id: 'board-1',
      name: '第一场',
      groupId: null,
      revision: 3,
      locked: false,
      rows: 1,
      columns: 1,
      itemCount: 1,
      annotationCount: 1,
      unresolvedAnnotationCount: 1,
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
      storySummary: const RemoteStoryboardStorySummary(
        outline: '寻找线索',
        content: '',
        scenes: '书房',
        props: '旧照片',
      ),
      items: const [
        RemoteStoryboardItem(
          assetId: 'asset-1',
          sourceName: '焦点帧',
          indexNo: 1,
          caption: '人物推门进入',
          slotIndex: 0,
          flipHorizontal: false,
          flipVertical: false,
          resourceRemoved: false,
          imageMediaId: null,
        ),
      ],
      annotations: const [
        RemoteStoryboardAnnotation(
          id: 'annotation-1',
          assetId: 'asset-1',
          body: '视线再向左一点',
          authorName: '远端导演',
          createdAt: null,
          updatedAt: null,
          resolved: false,
        ),
      ],
    );
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'session',
        clientName: '导演平板',
        role: 'director',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '项目 A',
          storyboardCount: 1,
          scriptCount: 0,
          shotCount: 0,
        ),
      )
      ..storyboardsAvailable = true
      ..storyboards = [detail]
      ..selectedStoryboard = detail
      ..selectedStoryboardItemId = 'asset-1';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('故事板审阅'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-storyboard-grid')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('storyboard-name-field')), findsOneWidget);
    expect(find.text('人物推门进入'), findsOneWidget);
    expect(find.text('视线再向左一点'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('new-storyboard-annotation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 viewer 可通过底部导航只读审阅故事板且无溢出', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = _narrowReviewDetail();
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'viewer',
        clientName: '只读场记',
        role: 'viewer',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '窄屏工程',
          storyboardCount: 1,
          scriptCount: 0,
          shotCount: 0,
        ),
      )
      ..storyboardsAvailable = true
      ..storyboards = [detail]
      ..selectedStoryboard = detail
      ..selectedStoryboardItemId = 'asset-mobile';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    final storyboardDestination = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('故事板'),
    );
    await tester.tap(storyboardDestination);
    await tester.pumpAndSettle();

    final nameField = tester.widget<TextField>(
      find.byKey(const ValueKey('storyboard-name-field')),
    );
    expect(nameField.readOnly, isTrue);
    expect(find.text('只读权限'), findsOneWidget);
    expect(find.textContaining('只读会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

RemoteStoryboardDetail _narrowReviewDetail() => const RemoteStoryboardDetail(
  id: 'board-mobile',
  name: '移动端画板',
  groupId: null,
  revision: 1,
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
  rowCaptions: [''],
  rowDividerEnabled: true,
  rowDividerStyle: 'dashed',
  rowDividerOpacity: .35,
  titleAlignment: 'center',
  portraitMode: false,
  storySummary: null,
  items: [
    RemoteStoryboardItem(
      assetId: 'asset-mobile',
      sourceName: '焦点帧',
      indexNo: 1,
      caption: '移动端镜头',
      slotIndex: 0,
      flipHorizontal: false,
      flipVertical: false,
      resourceRemoved: false,
      imageMediaId: null,
    ),
  ],
  annotations: [],
);

class _FakeRemoteApi implements RemoteApi {
  @override
  Uri get baseUri => Uri.parse('http://localhost:47836');

  @override
  Future<Map<String, Object?>> capabilities() async => const {};

  @override
  void close() {}

  @override
  Future<void> logout() async {}

  @override
  Future<RemoteStoryboardDetail> addStoryboardAnnotation({
    required String storyboardId,
    required int expectedRevision,
    required String body,
    String? assetId,
  }) => throw UnimplementedError();

  @override
  Future<RemoteMediaBytes> media(String id) async =>
      RemoteMediaBytes(bytes: Uint8List(0), contentType: 'image/png');

  @override
  Future<RemotePairResult> pair({
    required String code,
    required String clientName,
  }) async => RemotePairResult(
    session: RemoteSession(
      id: 'session',
      clientName: clientName,
      role: 'director',
      expiresAt: null,
    ),
  );

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) =>
      throw UnimplementedError();

  @override
  Future<
    ({List<RemoteStoryboardGroup> groups, List<RemoteStoryboardSummary> items})
  >
  storyboards() async => (
    groups: const <RemoteStoryboardGroup>[],
    items: const <RemoteStoryboardSummary>[],
  );

  @override
  Future<RemoteScriptDetail> script(String id) async => _detail;

  @override
  Future<List<RemoteScriptSummary>> scripts() async => [_detail];

  @override
  Future<RemoteScriptDetail> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) async => _detail;

  @override
  Future<RemoteStoryboardDetail> updateStoryboard({
    required String storyboardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) => throw UnimplementedError();

  @override
  Future<RemoteStoryboardDetail> updateStoryboardAnnotation({
    required String storyboardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) => throw UnimplementedError();

  @override
  Future<String> webSocketTicket() async => 'ticket';

  @override
  Future<RemoteWorkspace> workspace() async => const RemoteWorkspace(
    phase: 'editor',
    project: RemoteProject(
      id: 'project',
      name: '项目 A',
      storyboardCount: 0,
      scriptCount: 1,
      shotCount: 0,
    ),
  );

  static const _detail = RemoteScriptDetail(
    id: 'script',
    name: '项目 A 拍摄脚本',
    status: 'active',
    version: 1,
    shotCount: 0,
    updatedAt: null,
    shots: [],
  );
}
