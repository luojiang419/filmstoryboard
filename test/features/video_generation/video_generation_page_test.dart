import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('LibTV 预设提供浏览器授权、动态模型与 schema 参数控件', () {
    final generationSource = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final settingsSource = File(
      'lib/features/settings/presentation/settings_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(generationSource, contains("'confirm-libtv-login'"));
    expect(generationSource, contains("'confirm-libtv-batch'"));
    expect(
      generationSource,
      contains('controller.shouldRequestActiveCliLogin'),
    );
    expect(
      generationSource,
      contains('controller.shouldRequestActiveCliInstall'),
    );
    expect(generationSource, contains("'confirm-libtv-install'"));
    expect(generationSource, contains("'confirm-kling-install'"));
    expect(generationSource, contains('KlingCliInstallRegion.china'));
    expect(generationSource, contains('KlingCliInstallRegion.global'));
    expect(generationSource, contains('await _runCliLoginAuthorization'));
    expect(generationSource, contains('安装包内置的 LibTV 官方安装脚本'));
    expect(generationSource, contains('通过 winget 安装 Node.js LTS'));
    final controllerSource = File(
      'lib/features/video_generation/application/video_generation_controller.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(controllerSource, contains('_normalizedLibTvDuration(seconds)'));
    expect(generationSource, contains("'libtv-model-"));
    expect(generationSource, contains("'libtv-mode-"));
    expect(generationSource, contains("'libtv-parameter-"));
    expect(generationSource, contains('controller.selectLibTvModel'));
    expect(
      generationSource,
      contains('controller.selectedLibTvModelKey.isEmpty'),
    );
    expect(generationSource, contains('controller.updateLibTvModeType'));
    expect(generationSource, contains('controller.updateLibTvParameter'));
    expect(generationSource, contains('LibTvModelParameterSpec'));
    expect(settingsSource, contains('VideoGenerationApiConfigKind.libTvCli'));
    expect(settingsSource, contains('即梦 2.0 官方提示词教程'));
    expect(settingsSource, contains('脚本专属 LibTV 画布'));
    expect(
      settingsSource,
      contains('AppSettings.defaultLibTvCliVideoGenerationModel'),
    );
  });

  test('完成视频恢复格子内直接点击播放，生成中格子不使用持续动画', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(source, contains('class _InlineGeneratedVideoPlayer'));
    expect(
      source,
      contains("key: ValueKey('generated-video-player-\${latest!.id}')"),
    );
    expect(source, contains('generated-video-play-\${widget.file.path}'));
    expect(
      source,
      isNot(contains('class _GeneratedVideoCompletedPlaceholder')),
    );
    expect(source, isNot(contains('点击预览时才加载播放器')));
    expect(source, isNot(contains('CircularProgressIndicator')));
    expect(source, isNot(contains('Timer.periodic')));
    expect(source, contains('Future<void> _showFullscreenGeneratedVideo'));
    expect(source, contains('class _FullscreenGeneratedVideo'));
    expect(source, contains('LogicalKeyboardKey.escape'));
    expect(source, contains('KeyEventResult.handled'));
    expect(source, contains('class _HistoryVideoVersionCard'));
    expect(source, contains("GridView.builder"));
    expect(
      source,
      contains("key: ValueKey('generated-video-history-card-\${task.id}')"),
    );
    expect(source, contains('controller.generatedVideoFileFor(task)'));
    expect(source, contains('缩略图加载失败'));
    expect(source, contains('本地视频不可用'));
    expect(source, contains("VideoGenerationTaskStatus.running => '视频生成中'"));
    expect(
      source,
      contains("import '../../shooting_script/domain/script_shot_group.dart';"),
    );
    expect(
      source,
      contains('final groups = ScriptShotGroup.group(state.shots)'),
    );
    expect(source, contains("const _HeaderCell('原视频帧')"));
    expect(source, contains("const _HeaderCell('复刻分镜图')"));
    expect(source, contains("const _HeaderCell('时长')"));
    expect(source, contains("'video-generation-five-column-table'"));
    expect(source, contains('class _GenerationDurationCell'));
    expect(source, contains('controller.updateDesiredDurationFor'));
    expect(source, contains('生成提示词中的秒数会同步更新'));
    expect(source, contains('class _VideoGroupFrameStrip'));
    expect(
      source,
      contains(
        "'video-generation-\$keyPrefix-range-\${group.startNumber}-\${group.endNumber}'",
      ),
    );
    expect(source, contains('fileForShot: controller.videoFrameFileForShot'));
    expect(
      source,
      contains('endShot: group.shots.length > 1 ? group.shots.last : null'),
    );
    expect(source, contains('start: widget.range.inPoint'));
    expect(source, contains('end: widget.range.outPoint'));
    expect(
      source,
      isNot(contains('Media(widget.range.sourceVideo.path), play: false')),
    );
    expect(
      source,
      contains('fileForShot: controller.replicatedImageFileForShot'),
    );
    expect(source, contains('Future<void> _showScriptShotGroupImageGallery'));
    expect(source, contains('required String initialShotId'));
    expect(source, contains('final ValueChanged<ScriptShot> onOpen'));
    expect(source, contains('onTap: hasFile ? onTap : null'));
    expect(
      source,
      contains('items.indexWhere((item) => item.shotId == initialShotId)'),
    );
    expect(
      source,
      contains('initialIndex: initialIndex < 0 ? 0 : initialIndex'),
    );
    expect(source, contains('来源：复刻分镜图'));
    expect(source, contains("value: 'continue_query'"));
    expect(source, contains("Text('继续查询')"));
    expect(source, contains('controller.resumeTaskQuery(latest)'));
    expect(source, contains('controller.generatedVideoFileFor(latest)'));
    expect(source, isNot(contains('File(latest.localPath)')));
    expect(source, isNot(contains('已等待')));
    expect(source, isNot(contains('generated-video-elapsed-')));
    expect(source, isNot(contains('String _formatElapsed')));
    expect(source, contains("VideoGenerationTaskStatus.queued => '排队等待中'"));
    expect(
      source,
      contains('tasks.where(_shouldKeepVideoTaskInCell).firstOrNull'),
    );
    expect(source, contains("key: ValueKey('export-timeline-xml')"));
    expect(source, contains("key: const ValueKey('export-timeline-menu')"));
    expect(source, contains("key: ValueKey('send-timeline-to-davinci')"));
    expect(source, contains("title: Text('导出 XML 时间线')"));
    expect(source, contains("title: Text('发送到达芬奇')"));
    expect(source, contains('controller.sendTimelineToDaVinci()'));
    expect(source, contains("label: const Text('导出时间线')"));
    expect(source, contains("key: const ValueKey('export-composed-video')"));
    expect(source, contains("label: const Text('导出视频')"));
    expect(source, contains('controller.exportVideo'));
    expect(source, contains("'generated-video-io-button-\${latest.id}'"));
    final generatedCellStart = source.indexOf('class _GeneratedVideoCell');
    final generatedCellBuildEnd = source.indexOf(
      'Future<void> _editTrim',
      generatedCellStart,
    );
    final generatedCellBuild = source.substring(
      generatedCellStart,
      generatedCellBuildEnd,
    );
    expect(generatedCellBuild, contains('height: 150'));
    expect(generatedCellBuild, contains('OutlinedButton.icon('));
    expect(generatedCellBuild, isNot(contains('FilledButton.tonalIcon(')));
    expect(
      generatedCellBuild.indexOf("'generated-video-menu-\${shot.id}'"),
      lessThan(
        generatedCellBuild.indexOf("'generated-video-io-button-\${latest.id}'"),
      ),
    );
    expect(source, contains('showGeneratedVideoTrimEditor('));
    expect(source, contains('controller.updateTaskTrimRange(task, range)'));
    expect(source, contains('start: widget.range.inPoint'));
    expect(source, contains('end: widget.range.outPoint'));
    expect(
      source,
      contains(
        'oldWidget.range.inPoint != widget.range.inPoint ||\n'
        '        oldWidget.range.outPoint != widget.range.outPoint) {\n'
        '      unawaited(_applyRange());',
      ),
    );
    expect(source, contains('await _player.open(Media(widget.file.path)'));
    expect(source, contains('await _player.seek(widget.range.inPoint);'));
    expect(
      source.indexOf("key: const ValueKey('generate-all-videos')"),
      lessThan(source.indexOf("key: const ValueKey('export-timeline-menu')")),
    );
    expect(source, contains('bool _shouldKeepVideoTaskInCell'));
    final keepHelperStart = source.indexOf('bool _shouldKeepVideoTaskInCell');
    final labelHelperStart = source.indexOf(
      'String _activeVideoTaskLabel',
      keepHelperStart,
    );
    final keepHelper = source.substring(keepHelperStart, labelHelperStart);
    expect(
      keepHelper,
      isNot(contains('task.status == VideoGenerationTaskStatus.canceled')),
    );
    expect(
      source,
      isNot(contains("VideoGenerationTaskStatus.running => '正在生成视频'")),
    );
    expect(source, isNot(contains('正在启动隐藏 ComfyUI 后端并加载 H3 模型')));

    final progressBranch = source.indexOf('else if (isGenerating)');
    final completedBranch = source.indexOf('else if (hasLocalVideo)');
    expect(progressBranch, greaterThanOrEqualTo(0));
    expect(completedBranch, greaterThanOrEqualTo(0));
    expect(progressBranch, lessThan(completedBranch));
  });

  test('IO 点预览与生成视频播放器提供空格播放暂停快捷键', () {
    final generationSource = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final trimEditorSource = File(
      'lib/features/video_generation/presentation/widgets/'
      'generated_video_trim_editor.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      generationSource,
      contains('generated-video-inline-keyboard-\${widget.file.path}'),
    );
    expect(
      generationSource,
      contains("'generated-video-fullscreen-keyboard-scope'"),
    );
    expect(generationSource, contains("'source-range-preview-keyboard-scope'"));
    expect(
      RegExp(r'LogicalKeyboardKey\.space').allMatches(generationSource).length,
      greaterThanOrEqualTo(3),
    );
    expect(trimEditorSource, contains("'generated-video-io-keyboard-scope'"));
    expect(trimEditorSource, contains('LogicalKeyboardKey.space'));
    expect(trimEditorSource, contains('unawaited(_togglePlayback())'));
  });

  test('视频生成页 XML 导出复用设置页默认时间线目录', () {
    final source = File(
      'lib/features/video_generation/application/video_generation_controller.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(source, contains('DefaultExportDirectories('));
    expect(source, contains('settings.exportDirectory'));
    expect(source, contains(').timelines'));
    expect(source, contains('ffprobeExecutable: settings.ffprobeExecutable'));
  });

  test('生成视频右侧作品管理面板按脚本镜头折叠归纳版本', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains("key: const ValueKey('video-generation-work-management-panel')"),
    );
    expect(source, contains("'video-generation-work-panel-resize-handle'"));
    expect(source, contains("'expand-video-generation-work-management-panel'"));
    expect(
      source,
      contains("'collapse-video-generation-work-management-panel'"),
    );
    expect(source, contains("SystemMouseCursors.resizeColumn"));
    expect(source, contains("final panel = _WorkManagementPanel("));
    expect(source, contains("class _WorkManagementPanel"));
    expect(source, contains("'作品管理'"));
    expect(
      source,
      contains("key: const ValueKey('clean-invalid-generated-works')"),
    );
    expect(source, contains("label: const Text('清理')"));
    expect(source, contains('controller.invalidWorkTaskCount == 0'));
    expect(source, contains('controller.cleanInvalidWorks'));
    expect(
      source,
      contains("List<_WorkVideoShotGroup> _orderedWorkVideoShotGroups"),
    );
    expect(source, contains("class _WorkVideoShotGroup"));
    expect(source, contains("class _WorkManagementShotGroupTile"));
    expect(source, contains("ExpansionTile("));
    expect(
      source,
      contains("_shouldExpandWorkGroup(context, group, controller)"),
    );
    expect(source, contains("for (final shot in state.shots)"));
    expect(source, contains("task.shotId == shot.id"));
    expect(source, contains("task.scriptId == selectedScriptId"));
    expect(
      source,
      contains(
        'final entries = group.entries.reversed.toList(growable: false)',
      ),
    );
    expect(source, contains('entry: entries[index]'));
    expect(source, contains("'work-management-generated-shot-group-list'"));
    expect(source, contains("'work-management-shot-group-\${group.shot.id}'"));
    expect(
      source,
      contains("'work-management-shot-group-version-list-\${group.shot.id}'"),
    );
    expect(
      source,
      contains("Divider(\n                            height: 17"),
    );
    expect(source, contains("class _WorkManagementVideoItem"));
    expect(
      source,
      contains("'work-management-generated-video-player-\${task.id}'"),
    );
    expect(source, contains("file: file"));
    expect(source, contains("_showFullscreenGeneratedVideo("));
    expect(source, contains("_missingWorkVideoMessage(task)"));
    expect(source, contains("该脚本暂无生成作品"));

    final itemStart = source.indexOf('class _WorkManagementVideoItem');
    final entryStart = source.indexOf('class _WorkVideoTaskEntry', itemStart);
    expect(itemStart, greaterThanOrEqualTo(0));
    expect(entryStart, greaterThan(itemStart));
    final itemSource = source.substring(itemStart, entryStart);
    expect(itemSource, contains("_InlineGeneratedVideoPlayer("));
    expect(itemSource, isNot(contains('onGenerate')));
    expect(itemSource, isNot(contains('generateShot')));
    expect(itemSource, contains('onSecondaryTapDown:'));
    expect(itemSource, contains("title: Text('打开路径')"));
    expect(itemSource, contains("title: Text('另存为')"));
    expect(itemSource, contains("title: Text('删除')"));
    expect(itemSource, contains('controller.revealGeneratedVideo(task)'));
    expect(itemSource, contains('controller.saveGeneratedVideoCopy('));
    expect(itemSource, contains('controller.deleteTask(task)'));
    expect(itemSource, contains('删除该作品？'));
    expect(itemSource, contains('controller.selectWorkPreviewTask(task)'));
    expect(source, contains('class _WorkVideoTrimPreview'));
    expect(source, contains("'work-management-large-preview-\${task.id}'"));
    expect(source, contains('GeneratedVideoTrimEditor('));
    expect(source, contains('LogicalKeyboardKey.arrowLeft'));
    expect(source, contains('LogicalKeyboardKey.arrowRight'));
    expect(source, contains('controller.closeWorkPreview()'));
    expect(source, contains("'close-work-management-large-preview'"));
  });

  test('合成提示词页按镜头组显示多帧画面', () {
    final source = File(
      'lib/features/replicate/presentation/replicate_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(source, contains('final groups = ScriptShotGroup.group(shots)'));
    expect(source, contains("_ComposeTableHeaderCell('原视频帧')"));
    expect(source, contains("_ComposeTableHeaderCell('复刻分镜图')"));
    expect(source, contains('class _ComposeGroupFrameCell'));
    expect(source, contains('class _ComposeGroupFrameThumbnail'));
    expect(
      source,
      contains(
        "'compose-prompt-\$keyPrefix-range-\${group.startNumber}-\${group.endNumber}'",
      ),
    );
    expect(source, contains('prompt: prompts[group.shots.first.id]'));
    expect(source, isNot(contains('controller.tailShotForDisplay(shot)')));
  });

  test('视频提示词输入框保持控制器，连续键入不会因草稿更新时间重建', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    final promptCellStart = source.indexOf('class _PromptCell extends');
    final cellEnd = source.indexOf('class _Cell extends', promptCellStart);
    final promptCell = source.substring(promptCellStart, cellEnd);
    expect(promptCell, contains('class _PromptCell extends StatefulWidget'));
    expect(
      promptCell,
      contains('late final TextEditingController _textController'),
    );
    expect(promptCell, contains('void didUpdateWidget'));
    expect(promptCell, contains("ValueKey('video-prompt-\${widget.shot.id}')"));
    expect(promptCell, contains('controller: _textController'));
    expect(promptCell, isNot(contains('updatedAt.microsecondsSinceEpoch')));
    expect(promptCell, isNot(contains('initialValue:')));
  });

  test('批量生成中只锁定正在运行的镜头', () {
    final source = File(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains(
        'final canGenerateAny = controller.generationTargets().isNotEmpty',
      ),
    );
    expect(
      source,
      contains('state.isBusy && !state.isGeneratingAll'),
      reason: '生成批次本身不应锁死一键生成入口',
    );
    expect(
      source,
      contains('!controller.isGenerationActiveFor(owner)'),
      reason: '已终止或已失败镜头应可在原页面立即重新生成',
    );
    expect(source, isNot(contains('enabled: !state.isGeneratingAll')));
  });
}
