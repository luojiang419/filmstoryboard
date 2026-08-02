import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/widgets/preview_file_image.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/data/seedance_prompt_generation_service.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../video_analysis/application/video_analysis_controller.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../application/shooting_asset_library_controller.dart';
import '../application/shooting_script_controller.dart';
import '../domain/shooting_asset_library_models.dart';
import '../domain/shooting_script_models.dart';

class ShootingScriptPage extends ConsumerWidget {
  const ShootingScriptPage({super.key});

  static const _imageTypes = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
  );
  static const _assetTypes = XTypeGroup(
    label: '视频资产',
    extensions: [
      'png',
      'jpg',
      'jpeg',
      'webp',
      'bmp',
      'gif',
      'mp4',
      'mov',
      'mkv',
      'avi',
      'webm',
      'mp3',
      'wav',
      'm4a',
      'aac',
      'flac',
      'ogg',
    ],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(shootingScriptControllerProvider);
    final replicateController = ref.watch(replicateControllerProvider);
    final assetLibraryController = ref.watch(
      shootingAssetLibraryControllerProvider,
    );
    final videoController = ref.watch(videoAnalysisControllerProvider);
    final storyboardController = ref.watch(storyboardControllerProvider);
    return ValueListenableBuilder<ShootingScriptState>(
      valueListenable: controller,
      builder: (context, state, _) => ValueListenableBuilder<ReplicateState>(
        valueListenable: replicateController,
        builder: (context, replicateState, _) =>
            ValueListenableBuilder<ShootingAssetLibraryState>(
              valueListenable: assetLibraryController,
              builder: (context, libraryState, _) => ColoredBox(
                key: const ValueKey('shooting-script-page'),
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _PageHeader(
                        state: state,
                        controller: controller,
                        onRename: () =>
                            _renameScript(context, controller, state),
                        onDelete: () =>
                            _deleteScript(context, controller, state),
                      ),
                      if (state.message.isNotEmpty ||
                          state.errorMessage.isNotEmpty ||
                          replicateState.message.isNotEmpty ||
                          replicateState.errorMessage.isNotEmpty ||
                          libraryState.message.isNotEmpty ||
                          libraryState.errorMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _noticeText(state, replicateState, libraryState),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  state.errorMessage.isNotEmpty ||
                                      replicateState.errorMessage.isNotEmpty ||
                                      libraryState.errorMessage.isNotEmpty
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (state.selectedScript != null &&
                          replicateState.run != null) ...[
                        _ShootingScriptStepBar(
                          scriptState: state,
                          replicateState: replicateState,
                          controller: replicateController,
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final sidebar = _ScriptSidebar(
                              state: state,
                              controller: controller,
                              onCreate: () =>
                                  _createScript(context, controller),
                              onCreateFromVideo: () =>
                                  controller.createFromVideo(
                                    video: videoController.value.selectedVideo!,
                                    frames: videoController.value.frames,
                                    videoShots: videoController.value.shots,
                                    analyses:
                                        videoController.value.frameAnalyses,
                                  ),
                              canCreateFromVideo:
                                  videoController.value.selectedVideo != null,
                              onCreateFromStoryboard: () =>
                                  controller.createFromStoryboard(
                                    storyboardController.value.selectedBoard,
                                  ),
                              canCreateFromStoryboard:
                                  storyboardController.value.selectedBoard !=
                                  null,
                            );
                            final workspace = state.selectedScript == null
                                ? const _EmptyScriptState()
                                : _ScriptWorkspace(
                                    state: state,
                                    controller: controller,
                                    onBatchEdit: () =>
                                        _batchEdit(context, controller),
                                    onPickFrame: (shot) =>
                                        _pickFrame(controller, shot),
                                  );
                            final assetPanel = _AssetLibraryPanel(
                              state: libraryState,
                              replicateState: replicateState,
                              libraryController: assetLibraryController,
                              replicateController: replicateController,
                              onManage: () => _openAssetManager(
                                context,
                                assetLibraryController,
                                replicateController,
                              ),
                            );
                            if (constraints.maxWidth < 900) {
                              return Column(
                                children: [
                                  SizedBox(height: 250, child: sidebar),
                                  const SizedBox(height: 12),
                                  Expanded(child: workspace),
                                ],
                              );
                            }
                            if (constraints.maxWidth < 1260) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(width: 280, child: sidebar),
                                  const VerticalDivider(width: 20),
                                  Expanded(child: workspace),
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(width: 280, child: sidebar),
                                const VerticalDivider(width: 20),
                                Expanded(child: workspace),
                                const VerticalDivider(width: 20),
                                SizedBox(width: 310, child: assetPanel),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ),
    );
  }

  static String _noticeText(
    ShootingScriptState state,
    ReplicateState replicateState,
    ShootingAssetLibraryState libraryState,
  ) {
    for (final text in [
      state.errorMessage,
      replicateState.errorMessage,
      libraryState.errorMessage,
      state.message,
      replicateState.message,
      libraryState.message,
    ]) {
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  Future<void> _openAssetManager(
    BuildContext context,
    ShootingAssetLibraryController libraryController,
    ReplicateController replicateController,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => _AssetManagerPage(
          libraryController: libraryController,
          replicateController: replicateController,
          onPickFiles: _pickLibraryFiles,
          onManualAdd: _manualAddLibraryAsset,
          onEdit: _editLibraryAsset,
        ),
      ),
    );
  }

  Future<void> _pickLibraryFiles(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  ) async {
    final files = await openFiles(acceptedTypeGroups: const [_assetTypes]);
    for (final file in files) {
      await controller.importItem(sourcePath: file.path, type: type);
    }
  }

  Future<void> _manualAddLibraryAsset(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  ) async {
    final result = await _showLibraryAssetEditor(
      context,
      title: '手动添加资产',
      initialType: type,
      allowTypeChange: true,
      includePath: true,
    );
    if (result == null || result.path.trim().isEmpty) {
      return;
    }
    await controller.importItem(
      sourcePath: result.path,
      type: result.type,
      name: result.name,
      description: result.description,
    );
  }

  Future<void> _editLibraryAsset(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ShootingAssetLibraryItem item,
  ) async {
    final result = await _showLibraryAssetEditor(
      context,
      title: '编辑资产',
      initialType: item.type,
      initialName: item.name,
      initialDescription: item.description,
      initialPath: item.path,
      allowTypeChange: true,
      includePath: false,
    );
    if (result == null) {
      return;
    }
    controller.updateItem(
      item.copyWith(
        type: result.type,
        name: result.name,
        description: result.description,
      ),
    );
  }

  Future<_LibraryAssetEditorResult?> _showLibraryAssetEditor(
    BuildContext context, {
    required String title,
    required ReplicateAssetType initialType,
    String initialName = '',
    String initialDescription = '',
    String initialPath = '',
    required bool allowTypeChange,
    required bool includePath,
  }) async {
    var type = initialType;
    final nameController = TextEditingController(text: initialName);
    final descriptionController = TextEditingController(
      text: initialDescription,
    );
    final pathController = TextEditingController(text: initialPath);
    final result = await showDialog<_LibraryAssetEditorResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ReplicateAssetType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '资产类型'),
                  items: [
                    for (final item in ReplicateAssetType.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: allowTypeChange
                      ? (value) {
                          if (value != null) {
                            setDialogState(() => type = value);
                          }
                        }
                      : null,
                ),
                if (includePath) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: pathController,
                    decoration: const InputDecoration(labelText: '文件路径'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '资产名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '特征描述',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _LibraryAssetEditorResult(
                  type: type,
                  name: nameController.text.trim(),
                  description: descriptionController.text.trim(),
                  path: pathController.text.trim(),
                ),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    descriptionController.dispose();
    pathController.dispose();
    return result;
  }

  Future<void> _createScript(
    BuildContext context,
    ShootingScriptController controller,
  ) async {
    final name = await _askName(context, title: '新建拍摄脚本', initial: '新建脚本');
    if (name != null) {
      controller.createEmpty(name: name);
    }
  }

  Future<void> _renameScript(
    BuildContext context,
    ShootingScriptController controller,
    ShootingScriptState state,
  ) async {
    final script = state.selectedScript;
    if (script == null) {
      return;
    }
    final name = await _askName(
      context,
      title: '重命名拍摄脚本',
      initial: script.name,
    );
    if (name != null) {
      controller.renameSelectedScript(name);
    }
  }

  Future<void> _deleteScript(
    BuildContext context,
    ShootingScriptController controller,
    ShootingScriptState state,
  ) async {
    final script = state.selectedScript;
    if (script == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除拍摄脚本？'),
        content: Text(
          '将删除“${script.name}”及其 ${state.shots.length} 个镜头。已导出的文件不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.deleteSelectedScript();
    }
  }

  Future<void> _pickFrame(
    ShootingScriptController controller,
    ScriptShot shot,
  ) async {
    final result = await openFile(acceptedTypeGroups: const [_imageTypes]);
    if (result != null) {
      controller.updateShot(
        shot.copyWith(
          framePath: result.path,
          status: ProcessingStatus.completed,
        ),
      );
    }
  }

  Future<void> _batchEdit(
    BuildContext context,
    ShootingScriptController controller,
  ) async {
    var field = ShootingScriptBatchField.shotSize;
    final valueController = TextEditingController();
    final result =
        await showDialog<({ShootingScriptBatchField field, String value})>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('批量修改全部镜头'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<ShootingScriptBatchField>(
                    initialValue: field,
                    decoration: const InputDecoration(labelText: '字段'),
                    items: [
                      for (final item in ShootingScriptBatchField.values)
                        DropdownMenuItem(value: item, child: Text(item.label)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => field = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: valueController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '统一值',
                      helperText: '留空将清空所选字段',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop((field: field, value: valueController.text)),
                  child: const Text('应用到全部镜头'),
                ),
              ],
            ),
          ),
        );
    valueController.dispose();
    if (result != null) {
      controller.batchUpdateShots(
        field: result.field,
        fieldValue: result.value,
      );
    }
  }

  Future<String?> _askName(
    BuildContext context, {
    required String title,
    required String initial,
  }) async {
    final textController = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '脚本名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    textController.dispose();
    return result?.trim().isEmpty == true ? null : result?.trim();
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.state,
    required this.controller,
    required this.onRename,
    required this.onDelete,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '拍摄脚本',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                state.selectedScript == null
                    ? '新建空脚本，或从当前视频/故事板生成'
                    : '${state.selectedScript!.name} · 版本 ${state.selectedScript!.version}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Flexible(
          flex: 3,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: state.selectedScript == null ? null : onRename,
                icon: const Icon(Icons.drive_file_rename_outline_rounded),
                label: const Text('重命名'),
              ),
              OutlinedButton.icon(
                onPressed: state.selectedScript == null
                    ? null
                    : controller.duplicateSelectedScript,
                icon: const Icon(Icons.copy_rounded),
                label: const Text('复制脚本'),
              ),
              OutlinedButton.icon(
                onPressed: state.selectedScript == null
                    ? null
                    : controller.toggleArchiveSelectedScript,
                icon: Icon(
                  state.selectedScript?.status == ShootingScriptStatus.archived
                      ? Icons.unarchive_rounded
                      : Icons.archive_outlined,
                ),
                label: Text(
                  state.selectedScript?.status == ShootingScriptStatus.archived
                      ? '恢复'
                      : '归档',
                ),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('export-shooting-script-xlsx'),
                onPressed: state.selectedScript == null || state.isExporting
                    ? null
                    : controller.exportXlsx,
                icon: const Icon(Icons.table_view_rounded),
                label: const Text('导出 XLSX'),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('export-shooting-script-originals'),
                onPressed:
                    state.selectedScript == null ||
                        state.isExporting ||
                        state.shots.isEmpty
                    ? null
                    : controller.exportOriginalImages,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('导出原图'),
              ),
              IconButton(
                tooltip: '打开脚本导出目录',
                onPressed: controller.openOutputDirectory,
                icon: const Icon(Icons.folder_open_rounded),
              ),
              IconButton(
                tooltip: '删除当前脚本',
                onPressed: state.selectedScript == null ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScriptSidebar extends StatelessWidget {
  const _ScriptSidebar({
    required this.state,
    required this.controller,
    required this.onCreate,
    required this.onCreateFromVideo,
    required this.canCreateFromVideo,
    required this.onCreateFromStoryboard,
    required this.canCreateFromStoryboard,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final VoidCallback onCreate;
  final VoidCallback onCreateFromVideo;
  final bool canCreateFromVideo;
  final VoidCallback onCreateFromStoryboard;
  final bool canCreateFromStoryboard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('脚本列表', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: state.scripts.isEmpty
                  ? const Center(child: Text('尚未创建脚本'))
                  : ListView.separated(
                      itemCount: state.scripts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final script = state.scripts[index];
                        final selected = script.id == state.selectedScriptId;
                        return ListTile(
                          selected: selected,
                          selectedTileColor: scheme.secondaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(
                            script.status == ShootingScriptStatus.archived
                                ? Icons.archive_outlined
                                : Icons.description_outlined,
                          ),
                          title: Text(
                            script.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            'v${script.version} · ${script.status.label}',
                          ),
                          onTap: () => controller.selectScript(script.id),
                        );
                      },
                    ),
            ),
            const Divider(),
            FilledButton.icon(
              key: const ValueKey('create-empty-shooting-script'),
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建空脚本'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('create-shooting-script-from-video'),
              onPressed: canCreateFromVideo ? onCreateFromVideo : null,
              icon: const Icon(Icons.video_file_rounded),
              label: const Text('从当前视频生成'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('create-shooting-script-from-storyboard'),
              onPressed: canCreateFromStoryboard
                  ? onCreateFromStoryboard
                  : null,
              icon: const Icon(Icons.dashboard_customize_rounded),
              label: const Text('从当前故事板生成'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShootingScriptStepBar extends StatelessWidget {
  const _ShootingScriptStepBar({
    required this.scriptState,
    required this.replicateState,
    required this.controller,
  });

  final ShootingScriptState scriptState;
  final ReplicateState replicateState;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final run = replicateState.run!;
    final readyAssets = replicateState.assets
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    return SizedBox(
      height: 74,
      child: Row(
        children: [
          Expanded(
            child: _FlowStepPill(
              number: 1,
              title: '确认镜头',
              summary:
                  '${run.confirmedShotIds.length}/${scriptState.shots.length} 已确认',
              status: run.confirmShotsStatus,
              selected: run.currentStep == ReplicateStep.confirmShots,
              onTap: () => controller.moveToStep(ReplicateStep.confirmShots),
              action: TextButton(
                onPressed: scriptState.shots.isEmpty
                    ? null
                    : controller.confirmAllShots,
                child: const Text('全部确认'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FlowStepPill(
              number: 2,
              title: '准备资产',
              summary: '$readyAssets/${replicateState.assets.length} 可用',
              status: run.prepareAssetsStatus,
              selected: run.currentStep == ReplicateStep.prepareAssets,
              onTap: () => controller.moveToStep(ReplicateStep.prepareAssets),
              action: TextButton(
                onPressed: run.confirmedShotIds.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.prepareAssets),
                child: const Text('去匹配'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FlowStepPill(
              number: 3,
              title: '合成提示词',
              summary: '${run.completedCount}/${run.totalCount} 已合成',
              status: run.composePromptsStatus,
              selected: run.currentStep == ReplicateStep.composePrompts,
              onTap: () => controller.moveToStep(ReplicateStep.composePrompts),
              action: TextButton(
                onPressed: replicateState.isBusy
                    ? null
                    : controller.composeAllPrompts,
                child: Text(replicateState.prompts.isEmpty ? '生成' : '重生成'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowStepPill extends StatelessWidget {
  const _FlowStepPill({
    required this.number,
    required this.title,
    required this.summary,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.action,
  });

  final int number;
  final String title;
  final String summary;
  final ProcessingStatus status;
  final bool selected;
  final VoidCallback onTap;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: selected
                      ? scheme.primary
                      : scheme.secondaryContainer,
                  foregroundColor: selected
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                  child: Text('$number'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '$summary · ${status.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: status.color(scheme),
                        ),
                      ),
                    ],
                  ),
                ),
                action,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetLibraryPanel extends StatelessWidget {
  const _AssetLibraryPanel({
    required this.state,
    required this.replicateState,
    required this.libraryController,
    required this.replicateController,
    required this.onManage,
  });

  final ShootingAssetLibraryState state;
  final ReplicateState replicateState;
  final ShootingAssetLibraryController libraryController;
  final ReplicateController replicateController;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '资产库',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '管理资产',
                  onPressed: onManage,
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _AssetDropBox(
              enabled: replicateState.run != null,
              onAccept: replicateController.importLibraryAsset,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: state.items.isEmpty
                  ? const Center(child: Text('暂无常用资产'))
                  : ListView.separated(
                      itemCount: state.items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = state.items[index];
                        return _CompactLibraryAssetCard(
                          item: item,
                          enabled: replicateState.run != null,
                          onUse: () =>
                              replicateController.importLibraryAsset(item),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetDropBox extends StatelessWidget {
  const _AssetDropBox({required this.enabled, required this.onAccept});

  final bool enabled;
  final ValueChanged<ShootingAssetLibraryItem> onAccept;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (_) => enabled,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 96,
          decoration: BoxDecoration(
            color: active
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.upload_file_rounded,
                  color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 5),
                Text(
                  enabled ? '拖入当前脚本素材' : '先选择拍摄脚本',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CompactLibraryAssetCard extends StatelessWidget {
  const _CompactLibraryAssetCard({
    required this.item,
    required this.enabled,
    required this.onUse,
  });

  final ShootingAssetLibraryItem item;
  final bool enabled;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final child = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(width: 58, height: 58, child: _LibraryAssetPreview(item)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    item.type.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  if (item.description.isNotEmpty)
                    Text(
                      item.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '使用资产',
              onPressed: enabled ? onUse : null,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
      ),
    );
    return Draggable<ShootingAssetLibraryItem>(
      data: item,
      feedback: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: 240, child: child),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: child),
      child: child,
    );
  }
}

class _AssetManagerPage extends StatefulWidget {
  const _AssetManagerPage({
    required this.libraryController,
    required this.replicateController,
    required this.onPickFiles,
    required this.onManualAdd,
    required this.onEdit,
  });

  final ShootingAssetLibraryController libraryController;
  final ReplicateController replicateController;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  )
  onPickFiles;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ReplicateAssetType type,
  )
  onManualAdd;
  final Future<void> Function(
    BuildContext context,
    ShootingAssetLibraryController controller,
    ShootingAssetLibraryItem item,
  )
  onEdit;

  @override
  State<_AssetManagerPage> createState() => _AssetManagerPageState();
}

class _AssetManagerPageState extends State<_AssetManagerPage> {
  ReplicateAssetType _type = ReplicateAssetType.character;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ShootingAssetLibraryState>(
      valueListenable: widget.libraryController,
      builder: (context, state, _) => Scaffold(
        appBar: AppBar(
          title: const Text('资产管理'),
          actions: [
            IconButton(
              tooltip: '打开资产目录',
              onPressed: widget.libraryController.openLibraryDirectory,
              icon: const Icon(Icons.folder_open_rounded),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<ReplicateAssetType>(
                      initialValue: _type,
                      decoration: const InputDecoration(labelText: '添加类型'),
                      items: [
                        for (final item in ReplicateAssetType.values)
                          DropdownMenuItem(
                            value: item,
                            child: Text(item.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _type = value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => widget.onPickFiles(
                      context,
                      widget.libraryController,
                      _type,
                    ),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('添加文件'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => widget.onManualAdd(
                      context,
                      widget.libraryController,
                      _type,
                    ),
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('手动添加'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (state.isBusy) const LinearProgressIndicator(minHeight: 3),
              Expanded(
                child: state.items.isEmpty
                    ? const Center(child: Text('暂无资产'))
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 260,
                              mainAxisExtent: 250,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final item = state.items[index];
                          return _ManagedLibraryAssetCard(
                            item: item,
                            onUse: () => widget.replicateController
                                .importLibraryAsset(item),
                            onEdit: () => widget.onEdit(
                              context,
                              widget.libraryController,
                              item,
                            ),
                            onDelete: () =>
                                widget.libraryController.deleteItem(item.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagedLibraryAssetCard extends StatelessWidget {
  const _ManagedLibraryAssetCard({
    required this.item,
    required this.onUse,
    required this.onEdit,
    required this.onDelete,
  });

  final ShootingAssetLibraryItem item;
  final VoidCallback onUse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _LibraryAssetPreview(item)),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '资产操作',
                      onSelected: (action) => switch (action) {
                        'use' => onUse(),
                        'edit' => onEdit(),
                        'delete' => onDelete(),
                        _ => null,
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'use', child: Text('用于当前脚本')),
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
                Text(item.type.label),
                Text(
                  item.description.isEmpty
                      ? p.basename(item.path)
                      : item.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryAssetPreview extends StatelessWidget {
  const _LibraryAssetPreview(this.item);

  final ShootingAssetLibraryItem item;

  @override
  Widget build(BuildContext context) {
    final isImage =
        SeedancePromptGenerationService.mediaKind(
          ReplicateAsset(
            id: item.id,
            runId: '',
            type: item.type,
            name: item.name,
            description: item.description,
            path: item.path,
            referenceNumber: 0,
            status: ProcessingStatus.completed,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
          ),
        ) ==
        ReplicateMediaKind.image;
    if (isImage && item.path.isNotEmpty) {
      return Image.file(
        File(item.path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _AssetTypeIcon(item.type),
      );
    }
    return _AssetTypeIcon(item.type);
  }
}

class _AssetTypeIcon extends StatelessWidget {
  const _AssetTypeIcon(this.type);

  final ReplicateAssetType type;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(child: Icon(type.icon, size: 38)),
  );
}

class _ScriptWorkspace extends StatefulWidget {
  const _ScriptWorkspace({
    required this.state,
    required this.controller,
    required this.onBatchEdit,
    required this.onPickFrame,
  });

  final ShootingScriptState state;
  final ShootingScriptController controller;
  final VoidCallback onBatchEdit;
  final ValueChanged<ScriptShot> onPickFrame;

  @override
  State<_ScriptWorkspace> createState() => _ScriptWorkspaceState();
}

class _ScriptWorkspaceState extends State<_ScriptWorkspace> {
  final _horizontalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '官方模板字段 · 拖动镜号左侧手柄可排序',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed: widget.controller.addShot,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('插入镜头'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: state.shots.isEmpty ? null : widget.onBatchEdit,
                  icon: const Icon(Icons.playlist_add_check_rounded),
                  label: const Text('批量设置'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _horizontalController,
              thumbVisibility: true,
              notificationPredicate: (notification) => notification.depth == 0,
              child: SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: _ScriptTableRow.totalWidth,
                  child: Column(
                    children: [
                      const _ScriptTableHeader(),
                      Expanded(
                        child: state.shots.isEmpty
                            ? const Center(child: Text('当前脚本暂无镜头'))
                            : ReorderableListView.builder(
                                buildDefaultDragHandles: false,
                                itemCount: state.shots.length,
                                onReorder: widget.controller.reorderShots,
                                itemBuilder: (context, index) {
                                  final shot = state.shots[index];
                                  return _ScriptTableRow(
                                    key: ValueKey(shot.id),
                                    index: index,
                                    shot: shot,
                                    selected: shot.id == state.selectedShotId,
                                    controller: widget.controller,
                                    onPickFrame: () => widget.onPickFrame(shot),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 190,
            child: state.selectedShot == null
                ? const Center(child: Text('选择一个镜头查看附加字段'))
                : _ShotInspector(
                    shot: state.selectedShot!,
                    controller: widget.controller,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ScriptTableHeader extends StatelessWidget {
  const _ScriptTableHeader();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const Row(
        children: [
          _HeaderCell('镜号', 76),
          _HeaderCell('画面', 150),
          _HeaderCell('内容', 220),
          _HeaderCell('景别', 100),
          _HeaderCell('运镜', 110),
          _HeaderCell('摄影备注', 200),
          _HeaderCell('基地场景', 140),
          _HeaderCell('款号', 110),
          _HeaderCell('图片', 150),
          _HeaderCell('产品搭配', 170),
          _HeaderCell('操作', 104),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label, this.width);

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 42,
    child: Center(
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

class _ScriptTableRow extends StatelessWidget {
  const _ScriptTableRow({
    super.key,
    required this.index,
    required this.shot,
    required this.selected,
    required this.controller,
    required this.onPickFrame,
  });

  static const totalWidth = 1530.0;

  final int index;
  final ScriptShot shot;
  final bool selected;
  final ShootingScriptController controller;
  final VoidCallback onPickFrame;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: InkWell(
        onTap: () => controller.selectShot(shot.id),
        child: SizedBox(
          height: 116,
          child: Row(
            children: [
              SizedBox(
                width: 76,
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.drag_indicator_rounded),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        shot.shotNumber.toString().padLeft(2, '0'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 150,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child:
                            shot.framePath.isNotEmpty &&
                                File(shot.framePath).existsSync()
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image(
                                  image: previewFileImageProvider(
                                    path: shot.framePath,
                                    logicalWidth: 138,
                                    devicePixelRatio:
                                        MediaQuery.devicePixelRatioOf(context),
                                  ),
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(Icons.image_not_supported_outlined),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: IconButton.filledTonal(
                          tooltip: '选择原图',
                          visualDensity: VisualDensity.compact,
                          onPressed: onPickFrame,
                          icon: const Icon(Icons.edit_rounded, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _editor(220, '内容', shot.content, (value) {
                controller.updateShot(shot.copyWith(content: value));
              }),
              _editor(100, '景别', shot.shotSize, (value) {
                controller.updateShot(shot.copyWith(shotSize: value));
              }),
              _editor(110, '运镜', shot.cameraMovement, (value) {
                controller.updateShot(shot.copyWith(cameraMovement: value));
              }),
              _editor(200, '摄影备注', shot.cameraNotes, (value) {
                controller.updateShot(shot.copyWith(cameraNotes: value));
              }),
              _editor(140, '基地场景', shot.scene, (value) {
                controller.updateShot(shot.copyWith(scene: value));
              }),
              _editor(110, '款号', shot.productCode, (value) {
                controller.updateShot(shot.copyWith(productCode: value));
              }),
              _editor(150, '图片', shot.visual, (value) {
                controller.updateShot(shot.copyWith(visual: value));
              }),
              _editor(170, '产品搭配', shot.productStyling, (value) {
                controller.updateShot(shot.copyWith(productStyling: value));
              }),
              SizedBox(
                width: 104,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '复制镜头',
                      onPressed: () => controller.duplicateShot(shot.id),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                    IconButton(
                      tooltip: '删除镜头',
                      onPressed: () => controller.deleteShot(shot.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor(
    double width,
    String label,
    String value,
    ValueChanged<String> onSaved,
  ) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: _CommitTextField(
        key: ValueKey('${shot.id}-$label'),
        initialValue: value,
        label: label,
        maxLines: 4,
        onSaved: onSaved,
      ),
    ),
  );
}

class _ShotInspector extends StatelessWidget {
  const _ShotInspector({required this.shot, required this.controller});

  final ScriptShot shot;
  final ShootingScriptController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1080,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 110,
                child: _CommitTextField(
                  key: ValueKey('${shot.id}-duration'),
                  initialValue: shot.durationSeconds == 0
                      ? ''
                      : shot.durationSeconds.toStringAsFixed(2),
                  label: '时长（秒）',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onSaved: (value) => controller.updateShot(
                    shot.copyWith(durationSeconds: double.tryParse(value) ?? 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CommitTextField(
                  key: ValueKey('${shot.id}-dialogue'),
                  initialValue: shot.dialogue,
                  label: '对白 / 旁白',
                  maxLines: 4,
                  onSaved: (value) =>
                      controller.updateShot(shot.copyWith(dialogue: value)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CommitTextField(
                  key: ValueKey('${shot.id}-sound'),
                  initialValue: shot.sound,
                  label: '音效',
                  maxLines: 4,
                  onSaved: (value) =>
                      controller.updateShot(shot.copyWith(sound: value)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _CommitTextField(
                  key: ValueKey('${shot.id}-prompt'),
                  initialValue: shot.prompt,
                  label: '最终提示词',
                  maxLines: 5,
                  onSaved: (value) =>
                      controller.updateShot(shot.copyWith(prompt: value)),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 210,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        shot.framePath.isEmpty
                            ? '原图：未设置'
                            : '原图：${shot.framePath}',
                        maxLines: 6,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: shot.framePath.isEmpty
                          ? null
                          : () => controller.openShotOriginal(shot),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('打开原图位置'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommitTextField extends StatefulWidget {
  const _CommitTextField({
    super.key,
    required this.initialValue,
    required this.label,
    required this.onSaved,
    this.maxLines = 1,
    this.keyboardType,
  });

  final String initialValue;
  final String label;
  final ValueChanged<String> onSaved;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  State<_CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<_CommitTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _lastSaved = widget.initialValue;
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _CommitTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.initialValue != _controller.text) {
      _controller.text = widget.initialValue;
      _lastSaved = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      _commit();
    }
  }

  void _commit() {
    final current = _controller.text;
    if (current == _lastSaved) {
      return;
    }
    _lastSaved = current;
    widget.onSaved(current);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: widget.keyboardType,
      maxLines: widget.maxLines,
      minLines: 1,
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => _commit(),
    );
  }
}

class _EmptyScriptState extends StatelessWidget {
  const _EmptyScriptState();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.table_chart_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        const Text('选择或创建一个拍摄脚本'),
      ],
    ),
  );
}

class _LibraryAssetEditorResult {
  const _LibraryAssetEditorResult({
    required this.type,
    required this.name,
    required this.description,
    required this.path,
  });

  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
}

extension on ShootingScriptStatus {
  String get label => switch (this) {
    ShootingScriptStatus.draft => '草稿',
    ShootingScriptStatus.active => '使用中',
    ShootingScriptStatus.archived => '已归档',
  };
}

extension on ShootingScriptBatchField {
  String get label => switch (this) {
    ShootingScriptBatchField.shotSize => '景别',
    ShootingScriptBatchField.cameraMovement => '运镜',
    ShootingScriptBatchField.cameraNotes => '摄影备注',
    ShootingScriptBatchField.scene => '基地场景',
    ShootingScriptBatchField.productCode => '款号',
    ShootingScriptBatchField.visual => '图片',
    ShootingScriptBatchField.productStyling => '产品搭配',
  };
}

extension on ReplicateAssetType {
  String get label => switch (this) {
    ReplicateAssetType.character => '角色',
    ReplicateAssetType.product => '产品',
    ReplicateAssetType.scene => '场景',
    ReplicateAssetType.prop => '道具',
    ReplicateAssetType.video => '视频',
    ReplicateAssetType.audio => '音频',
    ReplicateAssetType.reference => '综合参考',
    ReplicateAssetType.other => '其他',
  };

  IconData get icon => switch (this) {
    ReplicateAssetType.character => Icons.person_outline_rounded,
    ReplicateAssetType.product => Icons.inventory_2_outlined,
    ReplicateAssetType.scene => Icons.landscape_outlined,
    ReplicateAssetType.prop => Icons.chair_outlined,
    ReplicateAssetType.video => Icons.movie_outlined,
    ReplicateAssetType.audio => Icons.audio_file_outlined,
    ReplicateAssetType.reference => Icons.collections_outlined,
    ReplicateAssetType.other => Icons.attach_file_rounded,
  };
}

extension on ProcessingStatus {
  String get label => switch (this) {
    ProcessingStatus.pending => '待处理',
    ProcessingStatus.running => '处理中',
    ProcessingStatus.completed => '已完成',
    ProcessingStatus.partial => '部分完成',
    ProcessingStatus.failed => '失败',
    ProcessingStatus.retrying => '重试中',
  };

  Color color(ColorScheme scheme) => switch (this) {
    ProcessingStatus.completed => scheme.primary,
    ProcessingStatus.failed => scheme.error,
    ProcessingStatus.partial => scheme.tertiary,
    ProcessingStatus.running || ProcessingStatus.retrying => scheme.secondary,
    ProcessingStatus.pending => scheme.onSurfaceVariant,
  };
}
