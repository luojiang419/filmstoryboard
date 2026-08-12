import 'dart:typed_data';

import 'package:filmstoryboard_remote_web/core/api/remote_api.dart';
import 'package:filmstoryboard_remote_web/core/models/remote_models.dart';
import 'package:filmstoryboard_remote_web/features/auth/pairing_page.dart';
import 'package:filmstoryboard_remote_web/features/projects/project_selection_page.dart';
import 'package:filmstoryboard_remote_web/features/workspace/remote_app_controller.dart';
import 'package:filmstoryboard_remote_web/features/workspace/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('配对页展示安全说明和 6 位配对输入', (tester) async {
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
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

    expect(find.text('工作台'), findsOneWidget);
    expect(find.text('项目 A'), findsWidgets);
    expect(find.text('镜头总数'), findsOneWidget);
    expect(find.text('最近拍摄脚本'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-bottom-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-dock-设置')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部 Dock 设置页只允许选择本机已有模型且不暴露配置字段', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
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
          scriptCount: 0,
          shotCount: 0,
        ),
      )
      ..settingsAvailable = true
      ..settingsSelection = _settingsSelection;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-dock-设置')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remote-settings-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-frame-extraction')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-video-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-vision-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-image-model')), findsOneWidget);
    expect(find.textContaining('API 地址、API Key、本机路径'), findsOneWidget);
    expect(find.text('API 地址'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拍摄脚本页提供准备资产、确认镜头、构建脚本和复刻分镜三步操作', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const workflow = RemoteShootingWorkflow(
      scriptId: 'script',
      currentStep: 'prepareAssets',
      confirmShotsStatus: 'pending',
      prepareAssetsStatus: 'pending',
      composePromptsStatus: 'pending',
      shotCount: 1,
      confirmedShotCount: 1,
      promptCount: 1,
      analysisCompleted: 0,
      analysisFailed: 0,
      analysisTotal: 1,
      isBusy: false,
      message: '',
      errorMessage: '',
      assets: [
        RemoteShootingWorkflowAsset(
          id: 'asset-1',
          name: '角色参考',
          type: 'character',
          description: '主角',
          referenceNumber: 1,
          mediaId: null,
        ),
      ],
      links: [],
      replicas: [],
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
          storyboardCount: 0,
          scriptCount: 1,
          shotCount: 1,
        ),
      )
      ..shootingWorkflowAvailable = true
      ..scripts = const [_FakeRemoteApi._detail]
      ..selectedScript = _FakeRemoteApi._detail
      ..shootingWorkflow = workflow;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-dock-拍摄脚本')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('shooting-prepare-assets-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('match-shooting-assets')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shooting-step-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('confirm-shooting-shots')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('build-shooting-script')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shooting-step-build')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('replicate-all-storyboards')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('replicate-selected-storyboard')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演可进入视频解析页查看候选帧、任务和本机命令', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
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
          name: '视频工程',
          storyboardCount: 0,
          scriptCount: 0,
          shotCount: 0,
        ),
      )
      ..videoAnalysisAvailable = true
      ..videoUploadsAvailable = true
      ..tasksAvailable = true
      ..videos = const [_widgetVideo]
      ..selectedVideo = _widgetVideoDetail
      ..selectedVideoFrameId = 'frame-1'
      ..tasks = [_widgetTask];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('视频解析'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remote-video-list')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-video-frame-grid')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('analyze-video')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generate-video-storyboard')),
      findsOneWidget,
    );
    expect(find.text('工作室'), findsOneWidget);
    expect(find.text('本机任务'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('video-frame-analysis-sidebar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remove-video-frame-frame-1')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('remove-video-frame-frame-1')));
    await tester.pumpAndSettle();
    expect(api.frameRemoveRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生成视频页宽屏固定右侧作品管理并保留生成链路', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
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
          name: '竖屏广告',
          storyboardCount: 1,
          scriptCount: 1,
          shotCount: 2,
        ),
      )
      ..videoGenerationAvailable = true
      ..tasksAvailable = true
      ..videoGenerationOptions = _generationOptions
      ..videoGenerationGroups = const [_generationGroup]
      ..videoGenerationTasks = const [
        _runningGenerationTask,
        _failedGenerationTask,
      ]
      ..videoGenerationWorks = const [_generationWork]
      ..tasks = const [_generationOperation];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('生成视频'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('video-generation-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generation-main-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-work-management-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-work-management-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-compact-work-management')),
      findsNothing,
    );
    expect(find.text('作品管理'), findsOneWidget);
    expect(find.text('生成任务'), findsOneWidget);
    expect(find.text('镜头任务'), findsOneWidget);
    expect(find.text('镜头版本'), findsOneWidget);
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('generation-work-management-panel')),
          )
          .dx,
      greaterThan(
        tester
            .getCenter(find.byKey(const ValueKey('generation-main-scroll')))
            .dx,
      ),
    );
    expect(
      find.byKey(const ValueKey('generation-script-select')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-model-select')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-parameter-ratio')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-prompt-group-1')),
      findsOneWidget,
    );
    expect(find.text('取消提交'), findsOneWidget);
    expect(find.text('取消生成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('generation-prompt-group-1')),
      'Web 覆盖提示词',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('start-video-generation')),
    );
    await tester.tap(find.byKey(const ValueKey('start-video-generation')));
    await tester.pump();
    expect(api.generationStartRequests, 1);
    expect(api.lastPrompt, 'Web 覆盖提示词');

    await tester.ensureVisible(
      find.byKey(const ValueKey('generation-work-generation-work')),
    );
    await tester.tap(
      find.byKey(const ValueKey('generation-work-generation-work')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-video-preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生成视频页窄屏使用可展开作品管理并保持单列可滚动', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'session',
        clientName: '导演手机',
        role: 'director',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '竖屏广告',
          storyboardCount: 1,
          scriptCount: 1,
          shotCount: 1,
        ),
      )
      ..videoGenerationAvailable = true
      ..videoGenerationOptions = _generationOptions
      ..videoGenerationGroups = const [_generationGroup]
      ..videoGenerationTasks = const [_runningGenerationTask]
      ..videoGenerationWorks = const [_generationWork]
      ..tasks = const [_generationOperation];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('生成视频'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-bottom-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-generation-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generation-compact-work-management')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-work-management-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('generation-shot-group-1')),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('作品管理'));
    await tester.tap(find.text('作品管理'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('generation-operation-outer-running')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-task-generation-running')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-work-generation-work')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出页覆盖五类真实选项、可恢复任务和安全产物操作', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeRemoteApi();
    final controller = RemoteAppController(api: api)
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
          name: '交付工程',
          storyboardCount: 1,
          scriptCount: 1,
          shotCount: 2,
        ),
      )
      ..exportsAvailable = true
      ..tasksAvailable = true
      ..exportOptions = _exportOptions
      ..tasks = const [
        _runningExportTask,
        _failedExportTask,
        _completedExportTask,
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('exporter-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('export-kind-storyboardDocument')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('export-kind-boardImages')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('export-kind-shootingScript')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('export-kind-analysisReport')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('export-kind-timelineXml')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('export-board-board-1')), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview-export-artifact-artifact-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('download-export-artifact-artifact-1')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const ValueKey('start-export')));
    await tester.tap(find.byKey(const ValueKey('start-export')));
    await tester.pump();
    expect(api.exportStartRequests, 1);
    expect(api.lastExportRequest?.kind, 'storyboardDocument');
    expect(api.lastExportRequest?.boardIds, ['board-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出页窄屏为单列滚动并显示解析报告和时间线真实可用项', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'session',
        clientName: '导演手机',
        role: 'director',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '移动交付',
          storyboardCount: 1,
          scriptCount: 1,
          shotCount: 1,
        ),
      )
      ..exportsAvailable = true
      ..exportOptions = _exportOptions;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-bottom-dock')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('exporter-mobile-scroll')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('export-kind-analysisReport')));
    await tester.pump();
    expect(find.byKey(const ValueKey('export-video-select')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('export-kind-timelineXml')));
    await tester.pump();
    expect(find.byKey(const ValueKey('export-script-select')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五工作页连续切换时共享工程任务且页面状态互不干扰', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storyboard = _narrowReviewDetail();
    const workflow = RemoteShootingWorkflow(
      scriptId: 'script',
      currentStep: 'prepareAssets',
      confirmShotsStatus: 'completed',
      prepareAssetsStatus: 'completed',
      composePromptsStatus: 'completed',
      shotCount: 1,
      confirmedShotCount: 1,
      promptCount: 1,
      analysisCompleted: 1,
      analysisFailed: 0,
      analysisTotal: 1,
      isBusy: false,
      message: '',
      errorMessage: '',
      assets: [],
      links: [],
      replicas: [],
    );
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.ready
      ..session = const RemoteSession(
        id: 'session',
        clientName: '联调导演',
        role: 'director',
        expiresAt: null,
      )
      ..workspace = const RemoteWorkspace(
        phase: 'editor',
        project: RemoteProject(
          id: 'project',
          name: '五页联调工程',
          storyboardCount: 1,
          scriptCount: 1,
          shotCount: 1,
        ),
      )
      ..videoAnalysisAvailable = true
      ..videoGenerationAvailable = true
      ..storyboardsAvailable = true
      ..exportsAvailable = true
      ..shootingWorkflowAvailable = true
      ..tasksAvailable = true
      ..videos = const [_widgetVideo]
      ..selectedVideo = _widgetVideoDetail
      ..selectedVideoFrameId = 'frame-1'
      ..storyboards = [storyboard]
      ..selectedStoryboard = storyboard
      ..selectedStoryboardItemId = 'asset-1'
      ..scripts = const [_FakeRemoteApi._detail]
      ..selectedScript = _FakeRemoteApi._detail
      ..shootingWorkflow = workflow
      ..videoGenerationOptions = _generationOptions
      ..videoGenerationGroups = const [_generationGroup]
      ..videoGenerationTasks = const [_runningGenerationTask]
      ..videoGenerationWorks = const [_generationWork]
      ..exportOptions = _exportOptions
      ..tasks = const [_widgetTask, _generationOperation, _completedExportTask];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );

    await tester.tap(find.byKey(const ValueKey('workspace-dock-视频解析')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-video-list')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remove-video-frame-frame-1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('workspace-dock-故事板')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-storyboard-grid')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('workspace-dock-拍摄脚本')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shooting-prepare-assets-page')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('workspace-dock-生成视频')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-generation-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generation-work-management-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-task-generation-running')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-work-generation-work')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('workspace-dock-导出')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('exporter-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-export-artifact-artifact-1')),
      findsOneWidget,
    );
    expect(controller.videoTasks, hasLength(1));
    expect(controller.videoGenerationOperations, hasLength(1));
    expect(controller.exportTasks, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('workspace-dock-视频解析')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-video-list')), findsOneWidget);
    expect(controller.selectedVideo?.video.id, _widgetVideo.id);
    expect(controller.selectedVideoFrameId, 'frame-1');
    expect(controller.selectedStoryboard?.id, storyboard.id);
    expect(controller.selectedStoryboardItemId, 'asset-1');
    expect(controller.selectedScript?.id, _FakeRemoteApi._detail.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('配对后先显示工程项目选择页和五模块说明', (tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = RemoteAppController(api: _FakeRemoteApi())
      ..phase = RemoteAppPhase.projectSelection
      ..session = const RemoteSession(
        id: 'session',
        clientName: '导演平板',
        role: 'director',
        expiresAt: null,
      )
      ..projects = const [
        RemoteProjectEntry(
          id: 'project',
          name: '项目 A',
          availability: 'available',
          canOpen: true,
          isActive: true,
          createdAt: null,
          updatedAt: null,
          lastOpenedAt: null,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ProjectSelectionPage(controller: controller)),
    );

    expect(find.text('选择要继续的工程'), findsOneWidget);
    expect(find.text('项目 A'), findsOneWidget);
    expect(find.textContaining('视频解析、故事板、拍摄脚本、生成视频和导出'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-project-project')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导演可进入故事板排版并看到拖拽、素材、重命名与批注', (tester) async {
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
      ..storyboardAssets = const [
        RemoteStoryboardAsset(
          id: 'asset-1',
          sourceName: '焦点帧',
          indexNo: 1,
          used: true,
          imageMediaId: null,
        ),
        RemoteStoryboardAsset(
          id: 'asset-2',
          sourceName: '候选帧',
          indexNo: 2,
          used: false,
          imageMediaId: null,
        ),
      ]
      ..selectedStoryboardItemId = 'asset-1';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspacePage(controller: controller)),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-dock-故事板')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-storyboard-grid')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('storyboard-name-field')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storyboard-tools-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('rename-storyboard-board')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('add-storyboard-asset-asset-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remove-storyboard-item-asset-1')),
      findsOneWidget,
    );
    expect(find.byType(LongPressDraggable<String>), findsNWidgets(2));
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
    await tester.tap(find.byKey(const ValueKey('workspace-dock-故事板')));
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

const _widgetVideo = RemoteVideoSummary(
  id: 'video-1',
  fileName: '竖屏样片.mp4',
  durationMs: 12000,
  frameRate: 25,
  width: 1920,
  height: 1080,
  displayWidth: 1080,
  displayHeight: 1920,
  rotationDegrees: 90,
  hasAudio: true,
  frameCount: 1,
  successfulFrames: 1,
  failedFrames: 0,
  status: 'pending',
  errorMessage: '',
  mediaId: null,
  createdAt: null,
  updatedAt: null,
);

const _widgetVideoDetail = RemoteVideoDetail(
  video: _widgetVideo,
  analysisState: RemoteVideoAnalysisState(
    isAnalyzing: false,
    isPaused: false,
    current: 1,
    total: 1,
    message: '候选帧已就绪',
    errorMessage: '',
    canUndoFrameRemoval: true,
  ),
  frames: [
    RemoteVideoFrame(
      id: 'frame-1',
      index: 0,
      timestampMs: 1000,
      width: 1080,
      height: 1920,
      sharpness: 88,
      brightness: .5,
      motionScore: .1,
      isFocus: true,
      status: 'completed',
      errorMessage: '',
      mediaId: null,
      analysis: RemoteVideoFrameAnalysis(
        id: 'analysis-1',
        sequenceNo: 1,
        dimensions: {'scene': '工作室', 'caption': '人物站在灯光下'},
        status: 'completed',
        errorMessage: '',
      ),
    ),
  ],
  shots: [],
  marketingAnalyses: [],
  summary: null,
);

const _widgetTask = RemoteTask(
  id: 'task-1',
  kind: 'videoAnalysis',
  status: 'running',
  current: 1,
  total: 3,
  message: '正在解析',
  errorCode: '',
  errorMessage: '',
  result: {},
  cancellable: true,
  createdAt: null,
  updatedAt: null,
);

const _generationOptions = RemoteVideoGenerationOptions(
  scripts: [
    RemoteVideoGenerationScript(
      id: 'script-1',
      name: '竖屏拍摄脚本',
      status: 'active',
      version: 3,
      isSelected: true,
    ),
  ],
  selectedScriptId: 'script-1',
  backend: RemoteVideoGenerationBackend(
    kind: 'libtvCli',
    name: 'LibTV',
    ready: true,
    message: '动态模型已加载',
  ),
  projectAspectRatio: '9:16',
  models: [RemoteVideoGenerationModel(id: 'model-h3', name: 'MiniMax H3')],
  selectedModelId: 'model-h3',
  parameters: [
    RemoteVideoGenerationParameter(
      key: 'ratio',
      label: '画幅',
      component: 'select',
      group: 'basic',
      value: '9:16',
      options: [
        RemoteVideoGenerationParameterOption(value: '9:16', label: '9:16'),
      ],
      min: null,
      max: null,
      step: null,
    ),
  ],
);

const _generationGroup = RemoteVideoGenerationGroup(
  id: 'group-1',
  scriptId: 'script-1',
  shotIds: ['shot-1', 'shot-2'],
  shotNumbers: [1, 2],
  title: '镜头 1–2',
  durationSeconds: 6,
  prompt: '雨夜追逐',
  promptMode: 'auto',
  canGenerate: true,
  isActive: true,
  referenceImageMediaId: null,
);

const _generationOperation = RemoteTask(
  id: 'outer-running',
  kind: 'videoGeneration',
  status: 'running',
  current: 0,
  total: 1,
  message: '等待本机生成',
  errorCode: '',
  errorMessage: '',
  result: {},
  cancellable: true,
  createdAt: null,
  updatedAt: null,
);

const _runningGenerationTask = RemoteVideoGenerationTask(
  id: 'generation-running',
  scriptId: 'script-1',
  shotId: 'group-1',
  shotNumber: 1,
  model: 'model-h3',
  parameters: {'ratio': '9:16'},
  durationSeconds: 6,
  promptMode: 'auto',
  prompt: '雨夜追逐',
  status: 'running',
  errorMessage: '',
  hasLocalResult: false,
  mediaId: null,
  createdAt: null,
  updatedAt: null,
  completedAt: null,
);

const _failedGenerationTask = RemoteVideoGenerationTask(
  id: 'generation-failed',
  scriptId: 'script-1',
  shotId: 'group-1',
  shotNumber: 2,
  model: 'model-h3',
  parameters: {'ratio': '9:16'},
  durationSeconds: 6,
  promptMode: 'auto',
  prompt: '雨夜追逐',
  status: 'failed',
  errorMessage: '远端生成失败',
  hasLocalResult: false,
  mediaId: null,
  createdAt: null,
  updatedAt: null,
  completedAt: null,
);

const _generationWork = RemoteVideoGenerationTask(
  id: 'generation-work',
  scriptId: 'script-1',
  shotId: 'group-1',
  shotNumber: 1,
  model: 'model-h3',
  parameters: {'ratio': '9:16'},
  durationSeconds: 6,
  promptMode: 'edited',
  prompt: '完成作品',
  status: 'completed',
  errorMessage: '',
  hasLocalResult: true,
  mediaId: 'work-media',
  createdAt: null,
  updatedAt: null,
  completedAt: null,
);

const _exportOptions = RemoteExportOptions(
  storyboardFormats: ['png', 'jpg', 'pdf'],
  storyboardResolutions: ['standard', 'sourceDetail'],
  analysisReportFormats: ['xlsx', 'pdf', 'png', 'jpg'],
  boards: [RemoteExportBoard(id: 'board-1', name: '画板 1', itemCount: 2)],
  videos: [RemoteExportVideo(id: 'video-1', name: '样片.mp4')],
  scripts: [
    RemoteExportScript(id: 'script-1', name: '拍摄脚本 1', timelineAvailable: true),
  ],
  defaults: RemoteExportDefaults(
    storyboardFormat: 'png',
    storyboardResolution: 'sourceDetail',
    includeSummaryPage: true,
    analysisReportFormat: 'xlsx',
    includeMultiDimensionAnalysis: true,
    includeShotDetails: true,
  ),
);

const _runningExportTask = RemoteTask(
  id: 'export-running',
  kind: 'export',
  status: 'running',
  current: 1,
  total: 2,
  message: '正在导出故事板',
  errorCode: '',
  errorMessage: '',
  result: {},
  cancellable: true,
  createdAt: null,
  updatedAt: null,
);

const _failedExportTask = RemoteTask(
  id: 'export-failed',
  kind: 'export',
  status: 'failed',
  current: 0,
  total: 1,
  message: '任务执行失败',
  errorCode: 'task_failed',
  errorMessage: '本机导出失败，请在桌面端检查日志',
  result: {},
  cancellable: false,
  createdAt: null,
  updatedAt: null,
);

const _completedExportTask = RemoteTask(
  id: 'export-completed',
  kind: 'export',
  status: 'succeeded',
  current: 1,
  total: 1,
  message: '导出完成',
  errorCode: '',
  errorMessage: '',
  result: {
    'exportKind': 'storyboardDocument',
    'artifacts': [
      {
        'id': 'artifact-1',
        'fileName': '画板.png',
        'contentType': 'image/png',
        'size': 1024,
        'previewable': true,
        'contentUrl': '/api/v1/exports/artifacts/artifact-1/content',
        'downloadUrl':
            '/api/v1/exports/artifacts/artifact-1/content?download=1',
      },
    ],
  },
  cancellable: false,
  createdAt: null,
  updatedAt: null,
);

class _FakeRemoteApi implements RemoteApi {
  int generationStartRequests = 0;
  int exportStartRequests = 0;
  int frameRemoveRequests = 0;
  String lastPrompt = '';
  RemoteExportRequest? lastExportRequest;
  @override
  Uri get baseUri => Uri.parse('http://localhost:47836');

  @override
  Future<RemoteTask> analyzeVideo(
    String videoId, {
    bool retryFailedOnly = false,
  }) => throw UnimplementedError();

  @override
  Future<RemoteVideoDetail> cancelVideo(String videoId) =>
      throw UnimplementedError();

  @override
  Future<RemoteVideoDetail> removeVideoFrame(
    String videoId,
    String frameId,
  ) async {
    frameRemoveRequests++;
    return _widgetVideoDetail;
  }

  @override
  Future<RemoteVideoDetail> undoVideoFrameRemoval(String videoId) =>
      Future.value(_widgetVideoDetail);

  @override
  Future<RemoteVideoDetail> redoVideoFrameRemoval(String videoId) =>
      Future.value(_widgetVideoDetail);

  @override
  Future<RemoteTask> cancelTask(String taskId) => throw UnimplementedError();

  @override
  Future<RemoteExportOptions> exportOptions() async => _exportOptions;

  @override
  Future<RemoteTask> startExport(RemoteExportRequest request) async {
    exportStartRequests++;
    lastExportRequest = request;
    return _runningExportTask;
  }

  @override
  Future<RemoteTask> retryExport(String taskId) async => _runningExportTask;

  @override
  Future<RemoteTask> generateVideoStoryboard(String videoId) =>
      throw UnimplementedError();

  @override
  Future<RemoteTask> importVideo(String uploadId) => throw UnimplementedError();

  @override
  Future<RemoteVideoDetail> pauseVideo(String videoId) =>
      throw UnimplementedError();

  @override
  Future<List<RemoteTask>> tasks() async => const [];

  @override
  Future<RemoteVideoUpload> uploadVideo({
    required String fileName,
    required int size,
    required Stream<List<int>> bytes,
    void Function(int sent, int total)? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<RemoteVideoDetail> video(String id) => throw UnimplementedError();

  @override
  Future<List<RemoteVideoSummary>> videos() async => const [];

  @override
  Future<Map<String, Object?>> capabilities() async => const {};

  @override
  Future<RemoteSettingsSelection> settingsSelection() async =>
      _settingsSelection;

  @override
  Future<RemoteSettingsSelection> updateSettingsSelection({
    String? extractionStrategy,
    String? visionModelId,
    String? imageGenerationModelId,
    String? videoGenerationModelId,
  }) async => _settingsSelection;

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
  Future<List<RemoteProjectEntry>> projects() async => const [
    RemoteProjectEntry(
      id: 'project',
      name: '项目 A',
      availability: 'available',
      canOpen: true,
      isActive: true,
      createdAt: null,
      updatedAt: null,
      lastOpenedAt: null,
    ),
  ];

  @override
  Future<Map<String, Object?>> openProject(String id) async => {
    'projectId': id,
    'projectName': '项目 A',
    'alreadyOpen': true,
  };

  @override
  Future<RemoteStoryboardDetail> storyboard(String id) =>
      throw UnimplementedError();

  @override
  Future<List<RemoteStoryboardAsset>> storyboardAssets(String id) async =>
      const [];

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
  Future<RemoteShootingWorkflow> shootingWorkflow(String scriptId) =>
      throw UnimplementedError();

  @override
  Future<RemoteShootingWorkflow> confirmShootingWorkflowShots(
    String scriptId,
  ) => throw UnimplementedError();

  @override
  Future<RemoteTask> startShootingWorkflowAction({
    required String scriptId,
    required String action,
    String? shotId,
  }) => throw UnimplementedError();

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
  Future<RemoteStoryboardDetail> updateStoryboardLayout({
    required String storyboardId,
    required int expectedRevision,
    required String action,
    required String assetId,
    int? slotIndex,
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
  Future<RemoteVideoGenerationTask> cancelVideoGenerationTask(String taskId) =>
      Future.value(_runningGenerationTask);

  @override
  Future<RemoteTask> retryVideoGenerationTask(String taskId) =>
      Future.value(_generationOperation);

  @override
  Future<
    ({
      RemoteVideoGenerationOptions options,
      List<RemoteVideoGenerationGroup> groups,
    })
  >
  selectVideoGenerationScript(String scriptId) async =>
      (options: _generationOptions, groups: const [_generationGroup]);

  @override
  Future<RemoteTask> startVideoGeneration({
    required String scriptId,
    required List<String> shotIds,
    required String model,
    required Map<String, String> parameters,
    required Map<String, RemoteVideoGenerationShotOverride> shotOverrides,
  }) async {
    generationStartRequests++;
    lastPrompt = shotOverrides['group-1']?.prompt ?? '';
    return _generationOperation;
  }

  @override
  Future<List<RemoteVideoGenerationGroup>> videoGenerationGroups() =>
      Future.value(const [_generationGroup]);

  @override
  Future<RemoteVideoGenerationOptions> videoGenerationOptions() =>
      Future.value(_generationOptions);

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationTasks() =>
      Future.value(const [_runningGenerationTask, _failedGenerationTask]);

  @override
  Future<List<RemoteVideoGenerationTask>> videoGenerationWorks() =>
      Future.value(const [_generationWork]);

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

const _settingsSelection = RemoteSettingsSelection(
  extractionStrategies: [
    RemoteSettingsOption(
      id: 'sceneAndInterval',
      name: '场景变化 + 间隔补帧',
      detail: '场景切换优先',
    ),
  ],
  selectedExtractionStrategy: 'sceneAndInterval',
  visionModels: [
    RemoteSettingsOption(id: 'vision', name: '视觉模型 A', detail: 'vision-a'),
  ],
  selectedVisionModelId: 'vision',
  imageGenerationModels: [
    RemoteSettingsOption(id: 'image', name: '图片模型 A', detail: 'image-a'),
  ],
  selectedImageGenerationModelId: 'image',
  videoGenerationModels: [
    RemoteSettingsOption(id: 'video', name: '视频模型 A', detail: 'video-a'),
  ],
  selectedVideoGenerationModelId: 'video',
);
