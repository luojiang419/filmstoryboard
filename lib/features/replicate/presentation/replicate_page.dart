import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../settings/application/settings_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/application/script_analysis_controller.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/application/shooting_asset_library_controller.dart';
import '../../shooting_script/domain/shooting_asset_library_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/presentation/video_generation_page.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../storyboard/presentation/widgets/image_generation_model_selector.dart';
import '../application/replicate_controller.dart';
import '../data/seedance_prompt_generation_service.dart';
import '../domain/replicate_models.dart';

class ReplicatePage extends ConsumerStatefulWidget {
  const ReplicatePage({
    super.key,
    this.onOpenShootingScript,
    this.onBackToShootingScript,
    this.embedded = false,
  });

  final VoidCallback? onOpenShootingScript;
  final VoidCallback? onBackToShootingScript;

  /// When true, render only the three-step workflow so the shooting-script
  /// page can own the surrounding page chrome and navigation.
  final bool embedded;

  @override
  ConsumerState<ReplicatePage> createState() => _ReplicatePageState();
}

class _ReplicatePageState extends ConsumerState<ReplicatePage> {
  static const _assetTypes = XTypeGroup(
    label: '复刻参考素材',
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

  late final ReplicateController _controller;
  bool _useBuiltInTemplate = false;
  bool _isOpeningAssetPicker = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(replicateControllerProvider);
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(replicateControllerProvider);
    final analysisController = ref.watch(scriptAnalysisControllerProvider);
    final assetBindingController = ref.watch(
      scriptAssetBindingControllerProvider,
    );
    final assetLibraryController = ref.watch(
      shootingAssetLibraryControllerProvider,
    );
    final settingsController = ref.watch(settingsControllerProvider);
    return ValueListenableBuilder<ReplicateState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.scripts.isEmpty) {
          return _NoScriptState(
            onOpenShootingScript:
                widget.onOpenShootingScript ?? widget.onBackToShootingScript,
          );
        }
        final run = state.run;
        if (run == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final workflow = AnimatedBuilder(
          animation: Listenable.merge([
            analysisController,
            assetBindingController,
            assetLibraryController,
            settingsController,
          ]),
          builder: (context, _) => _buildWorkflow(
            context,
            state: state,
            controller: controller,
            analysisController: analysisController,
            assetBindingController: assetBindingController,
            assetLibraryState: assetLibraryController.value,
            run: run,
            settingsController: settingsController,
          ),
        );
        if (widget.embedded) {
          return workflow;
        }
        return Padding(
          key: const ValueKey('replicate-page'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PageHeader(
                state: state,
                controller: controller,
                useBuiltInTemplate: _useBuiltInTemplate,
                onBackToShootingScript: widget.onBackToShootingScript,
                onToggleTemplate: () {
                  setState(() {
                    _useBuiltInTemplate = !_useBuiltInTemplate;
                  });
                },
              ),
              const SizedBox(height: 12),
              Expanded(child: workflow),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWorkflow(
    BuildContext context, {
    required ReplicateState state,
    required ReplicateController controller,
    required ShootingScriptAnalysisController analysisController,
    required ShootingScriptAssetBindingController assetBindingController,
    required ShootingAssetLibraryState assetLibraryState,
    required ReplicateRun run,
    required SettingsController settingsController,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepBar(state: state, controller: controller),
        const SizedBox(height: 12),
        if (state.isBusy || _isOpeningAssetPicker)
          const LinearProgressIndicator(minHeight: 3),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _useBuiltInTemplate
                ? switch (run.currentStep) {
                    ReplicateStep.confirmShots => _ConfirmShotsStep(
                      key: const ValueKey('replicate-confirm-shots-step'),
                      state: state,
                      controller: controller,
                      settingsController: settingsController,
                    ),
                    ReplicateStep.prepareAssets => _PrepareAssetsStep(
                      key: const ValueKey('replicate-prepare-assets-step'),
                      state: state,
                      controller: controller,
                      onImport: _importAssets,
                      onGenerate: _generateAsset,
                      onEdit: _editAsset,
                      onReplace: _replaceAsset,
                      onDelete: _deleteAsset,
                    ),
                    ReplicateStep.composePrompts => _ComposePromptsStep(
                      key: const ValueKey('replicate-compose-prompts-step'),
                      state: state,
                      controller: controller,
                      onCopyAll: _copyAllPrompts,
                    ),
                    ReplicateStep.generateVideos => VideoGenerationWorkspace(
                      key: ValueKey('replicate-generate-videos-step'),
                      scriptId: run.scriptId,
                    ),
                  }
                : switch (run.currentStep) {
                    ReplicateStep.confirmShots => _NewConfirmShotsStep(
                      key: const ValueKey('replicate-new-confirm-shots-step'),
                      state: state,
                      controller: controller,
                      analysisController: analysisController,
                      settingsController: settingsController,
                      onOpenPrompt: _showPromptPreview,
                    ),
                    ReplicateStep.prepareAssets => _NewPrepareAssetsStep(
                      key: const ValueKey('replicate-new-prepare-assets-step'),
                      state: state,
                      controller: controller,
                      assetBindingController: assetBindingController,
                      assetLibraryState: assetLibraryState,
                      onImport: _importAssets,
                      onImportLocalAsset: _importSingleAsset,
                      onGenerate: _generateAsset,
                      onEdit: _editAsset,
                      onReplace: _replaceAsset,
                      onDelete: _deleteAsset,
                    ),
                    ReplicateStep.composePrompts => _NewComposePromptsStep(
                      key: const ValueKey('replicate-new-compose-prompts-step'),
                      state: state,
                      controller: controller,
                      onCopyAll: _copyAllPrompts,
                    ),
                    ReplicateStep.generateVideos => VideoGenerationWorkspace(
                      key: ValueKey('replicate-new-generate-videos-step'),
                      scriptId: run.scriptId,
                    ),
                  },
          ),
        ),
      ],
    );
  }

  Future<void> _importAssets(ReplicateAssetType type) async {
    final files = await _pickAssetFiles();
    for (final file in files) {
      final initialType = _normalizedTypeForPath(type, file.path);
      final result = await _showAssetEditor(
        title: '添加参考素材',
        initialType: initialType,
        initialName: p.basenameWithoutExtension(file.path),
        allowTypeChange: true,
      );
      if (result == null) {
        continue;
      }
      await _controller.importAsset(
        sourcePath: file.path,
        type: _normalizedTypeForPath(result.type, file.path),
        name: result.name,
        description: result.description,
      );
    }
  }

  Future<ReplicateAsset?> _importSingleAsset(ReplicateAssetType type) async {
    final file = await _pickAssetFile();
    if (file == null) return null;
    final initialType = _normalizedTypeForPath(type, file.path);
    final result = await _showAssetEditor(
      title: '添加并绑定参考素材',
      initialType: initialType,
      initialName: p.basenameWithoutExtension(file.path),
      allowTypeChange: true,
    );
    if (result == null) return null;
    return _controller.importAsset(
      sourcePath: file.path,
      type: _normalizedTypeForPath(result.type, file.path),
      name: result.name,
      description: result.description,
    );
  }

  Future<void> _generateAsset(ReplicateAssetType initialType) async {
    final result = await _showAssetEditor(
      title: '生成参考图片',
      initialType: initialType,
      allowTypeChange: true,
      imageTypesOnly: true,
    );
    if (result == null) return;
    await _controller.generateImageAsset(
      type: result.type,
      name: result.name,
      description: result.description,
    );
  }

  Future<void> _editAsset(ReplicateAsset asset) async {
    final result = await _showAssetEditor(
      title: '编辑素材信息',
      initialType: asset.type,
      initialName: asset.name,
      initialDescription: asset.description,
      allowTypeChange: true,
    );
    if (result == null) return;
    _controller.updateAsset(
      asset.copyWith(
        type: result.type,
        name: result.name,
        description: result.description,
      ),
    );
  }

  Future<void> _replaceAsset(ReplicateAsset asset) async {
    final file = await _pickAssetFile();
    if (file != null) {
      await _controller.replaceAssetFile(asset.id, file.path);
    }
  }

  Future<List<XFile>> _pickAssetFiles() async {
    if (_isOpeningAssetPicker) return const [];
    setState(() => _isOpeningAssetPicker = true);
    try {
      if (!mounted) return const [];
      return await openFiles(acceptedTypeGroups: const [_assetTypes]);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开文件选择器失败：$error')));
      }
      return const [];
    } finally {
      if (mounted) setState(() => _isOpeningAssetPicker = false);
    }
  }

  Future<XFile?> _pickAssetFile() async {
    if (_isOpeningAssetPicker) return null;
    setState(() => _isOpeningAssetPicker = true);
    try {
      if (!mounted) return null;
      return await openFile(acceptedTypeGroups: const [_assetTypes]);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开文件选择器失败：$error')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _isOpeningAssetPicker = false);
    }
  }

  Future<void> _deleteAsset(ReplicateAsset asset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除参考素材'),
        content: Text('确定删除“${asset.name}”吗？该引用编号不会分配给后续素材。'),
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
    if (confirmed == true) await _controller.deleteAsset(asset.id);
  }

  Future<_AssetEditorResult?> _showAssetEditor({
    required String title,
    required ReplicateAssetType initialType,
    String initialName = '',
    String initialDescription = '',
    required bool allowTypeChange,
    bool imageTypesOnly = false,
  }) async {
    var type = initialType;
    if (imageTypesOnly && !type.isImageType) {
      type = ReplicateAssetType.character;
    }
    final nameController = TextEditingController(text: initialName);
    final descriptionController = TextEditingController(
      text: initialDescription,
    );
    final result = await showDialog<_AssetEditorResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ReplicateAssetType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '素材类型'),
                  items: [
                    for (final item in ReplicateAssetType.values)
                      if (!imageTypesOnly || item.isImageType)
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
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '素材名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '特征或生成描述',
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
                _AssetEditorResult(
                  type: type,
                  name: nameController.text.trim(),
                  description: descriptionController.text.trim(),
                ),
              ),
              child: Text(imageTypesOnly ? '开始生成' : '保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    descriptionController.dispose();
    return result;
  }

  Future<void> _copyAllPrompts(ReplicateState state) async {
    final sorted = [...state.prompts]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    if (sorted.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(
        text: sorted
            .map((item) => '镜头 ${item.shotNumber}\n${item.prompt}')
            .join(
              '\n\n------------------------------------------------------------------------\n\n',
            ),
      ),
    );
  }

  Future<void> _showPromptPreview(ShotPrompt prompt) async {
    final textController = TextEditingController(text: prompt.prompt);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('镜头 ${prompt.shotNumber} · 最终提示词'),
        content: SizedBox(
          width: 720,
          child: TextField(
            controller: textController,
            minLines: 8,
            maxLines: 16,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '最终提示词',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: textController.text)),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (result != null && result.trim().isNotEmpty) {
      _controller.updatePromptText(prompt.id, result);
    }
  }

  static ReplicateAssetType _normalizedTypeForPath(
    ReplicateAssetType requested,
    String path,
  ) {
    final extension = p.extension(path).toLowerCase();
    if (const {'.mp4', '.mov', '.mkv', '.avi', '.webm'}.contains(extension)) {
      return ReplicateAssetType.video;
    }
    if (const {
      '.mp3',
      '.wav',
      '.m4a',
      '.aac',
      '.flac',
      '.ogg',
    }.contains(extension)) {
      return ReplicateAssetType.audio;
    }
    return requested == ReplicateAssetType.video ||
            requested == ReplicateAssetType.audio
        ? ReplicateAssetType.reference
        : requested;
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.state,
    required this.controller,
    required this.useBuiltInTemplate,
    required this.onBackToShootingScript,
    required this.onToggleTemplate,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final bool useBuiltInTemplate;
  final VoidCallback? onBackToShootingScript;
  final VoidCallback onToggleTemplate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              onBackToShootingScript == null ? '一键复刻' : '拍摄脚本 · 复刻流程',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const Text(
              '确认镜头、准备参考资产，并逐镜生成可直接使用的即梦 / 可灵提示词。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
        final selector = DropdownButtonFormField<String>(
          key: const ValueKey('replicate-script-selector'),
          initialValue: state.selectedScriptId,
          decoration: const InputDecoration(
            labelText: '当前拍摄脚本',
            isDense: true,
            prefixIcon: Icon(Icons.description_outlined),
          ),
          items: [
            for (final script in state.scripts)
              DropdownMenuItem(value: script.id, child: Text(script.name)),
          ],
          onChanged: (id) {
            if (id != null) controller.selectScript(id);
          },
        );
        final templateButton = OutlinedButton.icon(
          key: const ValueKey('toggle-shooting-script-template'),
          onPressed: onToggleTemplate,
          icon: const Icon(Icons.swap_horiz_rounded),
          label: Text(useBuiltInTemplate ? '使用新脚本样式' : '切换脚本模版'),
        );
        final backButton = onBackToShootingScript == null
            ? null
            : OutlinedButton.icon(
                key: const ValueKey('back-to-shooting-script'),
                onPressed: onBackToShootingScript,
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('返回脚本编辑'),
              );
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              if (backButton != null) ...[
                const SizedBox(height: 8),
                backButton,
              ],
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: selector),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: templateButton),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            if (backButton != null) ...[backButton, const SizedBox(width: 10)],
            const SizedBox(width: 12),
            SizedBox(width: 320, child: selector),
            const SizedBox(width: 10),
            templateButton,
          ],
        );
      },
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.state, required this.controller});

  final ReplicateState state;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final run = state.run!;
    final readyAssets = state.assets
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    return SizedBox(
      height: 58,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final steps = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepCard(
                number: 1,
                title: '确认镜头',
                summary: '${state.shots.length}个镜头已就绪',
                status: run.confirmShotsStatus,
                selected: run.currentStep == ReplicateStep.confirmShots,
                onTap: () => controller.moveToStep(ReplicateStep.confirmShots),
              ),
              const _StepConnector(),
              _StepCard(
                number: 2,
                title: '准备资产',
                summary:
                    '$readyAssets/${state.assets.length} 已生成、还差${state.assets.length - readyAssets}个',
                status: run.prepareAssetsStatus,
                selected: run.currentStep == ReplicateStep.prepareAssets,
                onTap: () => controller.moveToStep(ReplicateStep.prepareAssets),
              ),
              const _StepConnector(),
              _StepCard(
                number: 3,
                title: '合成提示词',
                summary: '${run.completedCount}/${state.shots.length} 已合成',
                status: run.composePromptsStatus,
                selected: run.currentStep == ReplicateStep.composePrompts,
                onTap: () =>
                    controller.moveToStep(ReplicateStep.composePrompts),
              ),
              const _StepConnector(),
              _StepCard(
                number: 4,
                title: '生成视频',
                summary: '可灵图生视频',
                status: run.generateVideosStatus,
                selected: run.currentStep == ReplicateStep.generateVideos,
                onTap: () =>
                    controller.moveToStep(ReplicateStep.generateVideos),
              ),
            ],
          );
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Center(child: steps),
                ),
              ),
              if (constraints.maxWidth >= 980) ...[
                const SizedBox(width: 12),
                Text(
                  '步骤 3 完成后可批量生成视频',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.summary,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final String title;
  final String summary;
  final ProcessingStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 174,
      height: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor: selected
                      ? scheme.onSurface
                      : scheme.surfaceContainerHighest,
                  foregroundColor: selected
                      ? scheme.surface
                      : scheme.onSurfaceVariant,
                  child: Text('$number', style: const TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: status.color(scheme),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                if (status == ProcessingStatus.completed)
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 14,
                    color: status.color(scheme),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepConnector extends StatelessWidget {
  const _StepConnector();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 34,
    child: Divider(
      color: Theme.of(context).colorScheme.outlineVariant,
      thickness: 1,
    ),
  );
}

class _StartEndFrameModeSwitch extends StatelessWidget {
  const _StartEndFrameModeSwitch({required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.value.videoStartEndFrameModeEnabled;
    return Tooltip(
      message: '实验功能：仅把双向确认属于同一连续动作的首帧和尾帧合并为一条视频生成请求',
      child: Semantics(
        container: true,
        label: '首尾帧模式',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('首尾帧模式', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 4),
            Switch(
              key: const ValueKey('video-start-end-frame-mode-switch'),
              value: enabled,
              onChanged: controller.setVideoStartEndFrameModeEnabled,
            ),
            const Text('实验', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _NewConfirmShotsStep extends StatelessWidget {
  const _NewConfirmShotsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.analysisController,
    required this.settingsController,
    required this.onOpenPrompt,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ShootingScriptAnalysisController analysisController;
  final SettingsController settingsController;
  final ValueChanged<ShotPrompt> onOpenPrompt;

  @override
  Widget build(BuildContext context) {
    final analysis = analysisController.value;
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in state.replicatedImages) image.scriptShotId: image,
    };
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 1 · 确认镜头',
            subtitle:
                '请查阅并按需编辑镜头内容，修改会同步回拍摄脚本。自动解析 ${analysis.completedCount}/${analysis.totalCount}。',
            actions: [
              _StartEndFrameModeSwitch(controller: settingsController),
              FilledButton.icon(
                key: const ValueKey('script-auto-analyze-all'),
                onPressed: analysis.isBusy
                    ? null
                    : () => analysisController.analyzeAll(),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(analysis.isBusy ? '解析中…' : '自动解析全部'),
              ),
              if (analysis.isBusy)
                OutlinedButton.icon(
                  onPressed: analysisController.cancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('取消解析'),
                ),
              FilledButton.icon(
                key: const ValueKey('replicate-new-next-assets'),
                onPressed: state.shots.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.prepareAssets),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _NewShotTable(
              state: state,
              controller: controller,
              confirmed: const <String>{},
              startEndFrameMode:
                  settingsController.value.videoStartEndFrameModeEnabled,
              onOpenPrompt: onOpenPrompt,
              onOpenFrame: (index, showOriginal) => _showScriptFrameGallery(
                context,
                state.shots,
                index,
                replicatedByShotId: showOriginal
                    ? const <String, ReplicatedShotImage>{}
                    : replicaByShotId,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewComposePromptsStep extends StatelessWidget {
  const _NewComposePromptsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.onCopyAll,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ValueChanged<ReplicateState> onCopyAll;

  @override
  Widget build(BuildContext context) {
    final completedReplicaIds = {
      for (final image in state.replicatedImages)
        if (image.status == ProcessingStatus.completed &&
            image.generatedFramePath.isNotEmpty &&
            File(image.generatedFramePath).existsSync())
          image.scriptShotId,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in state.replicatedImages) image.scriptShotId: image,
    };
    final canCompose = state.confirmedShots.isNotEmpty && !state.isBusy;
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 3 · 合成提示词',
            subtitle:
                '复刻分镜 ${completedReplicaIds.length}/${state.confirmedShots.length} · 基于已解析脚本字段合成；需要视觉重析请先在步骤 1 自动解析',
            actions: [
              FilledButton.icon(
                key: const ValueKey('new-compose-all-seedance-prompts'),
                onPressed: canCompose ? controller.composeAllPrompts : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(state.prompts.isEmpty ? '合成全部' : '重新合成全部'),
              ),
              OutlinedButton.icon(
                onPressed:
                    state.prompts.any(
                      (item) => item.status == ProcessingStatus.failed,
                    )
                    ? controller.retryFailedPrompts
                    : null,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试失败'),
              ),
              OutlinedButton.icon(
                onPressed: state.prompts.isEmpty
                    ? null
                    : () => onCopyAll(state),
                icon: const Icon(Icons.copy_all_rounded),
                label: const Text('复制全部'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('new-export-seedance-prompts'),
                onPressed: state.prompts.isEmpty
                    ? null
                    : controller.exportPrompts,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('导出 XLSX'),
              ),
              FilledButton.icon(
                key: const ValueKey('new-go-video-generation'),
                onPressed: state.prompts.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.generateVideos),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步：生成视频'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _ComposePromptTable(
              state: state,
              controller: controller,
              replicatedByShotId: replicaByShotId,
              startEndFrameMode: controller.startEndFrameModeEnabled,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposePromptTable extends StatelessWidget {
  const _ComposePromptTable({
    required this.state,
    required this.controller,
    required this.replicatedByShotId,
    required this.startEndFrameMode,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final bool startEndFrameMode;

  @override
  Widget build(BuildContext context) {
    final prompts = {
      for (final prompt in state.prompts)
        if (prompt.scriptShotId != null) prompt.scriptShotId!: prompt,
    };
    final shots = startEndFrameMode
        ? controller.startEndRows
        : ([...state.confirmedShots]..sort(
            (first, second) => first.shotNumber.compareTo(second.shotNumber),
          ));
    final columnWidths = startEndFrameMode
        ? const {
            0: FixedColumnWidth(210),
            1: FixedColumnWidth(210),
            2: FixedColumnWidth(210),
            3: FixedColumnWidth(210),
            4: FlexColumnWidth(),
          }
        : const {
            0: FixedColumnWidth(230),
            1: FixedColumnWidth(230),
            2: FlexColumnWidth(),
          };
    return Scrollbar(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: startEndFrameMode ? 1460 : 1180,
            child: Table(
              key: const ValueKey('compose-prompt-three-column-table'),
              border: TableBorder.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              columnWidths: columnWidths,
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                TableRow(
                  children: startEndFrameMode
                      ? const [
                          _ComposeTableHeaderCell('首帧'),
                          _ComposeTableHeaderCell('尾帧'),
                          _ComposeTableHeaderCell('复刻首帧'),
                          _ComposeTableHeaderCell('复刻尾帧'),
                          _ComposeTableHeaderCell('生成提示词'),
                        ]
                      : const [
                          _ComposeTableHeaderCell('原图'),
                          _ComposeTableHeaderCell('复刻分镜图'),
                          _ComposeTableHeaderCell('生成提示词'),
                        ],
                ),
                for (final shot in shots)
                  _composePromptRow(
                    shot: shot,
                    prompt: prompts[shot.id],
                    tailShot: controller.tailShotForDisplay(shot),
                    replicatedByShotId: replicatedByShotId,
                    controller: controller,
                    startEndFrameMode: startEndFrameMode,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TableRow _composePromptRow({
  required ScriptShot shot,
  required ShotPrompt? prompt,
  required ScriptShot? tailShot,
  required Map<String, ReplicatedShotImage> replicatedByShotId,
  required ReplicateController controller,
  required bool startEndFrameMode,
}) {
  if (!startEndFrameMode) {
    return TableRow(
      children: [
        _ComposeImageCell(
          label: '镜头 ${shot.shotNumber} 原图',
          path: shot.framePath,
        ),
        _ComposeImageCell(
          label: '镜头 ${shot.shotNumber} 复刻分镜图',
          path: replicatedByShotId[shot.id]?.generatedFramePath ?? '',
        ),
        _ComposePromptCell(prompt: prompt, controller: controller),
      ],
    );
  }
  return TableRow(
    children: [
      _ComposeImageCell(
        label: '镜头 ${shot.shotNumber} 首帧',
        path: shot.framePath,
      ),
      _ComposeImageCell(
        label: tailShot == null ? '无尾帧' : '镜头 ${tailShot.shotNumber} 尾帧',
        path: tailShot?.framePath ?? '',
      ),
      _ComposeImageCell(
        label: '镜头 ${shot.shotNumber} 复刻首帧',
        path: replicatedByShotId[shot.id]?.generatedFramePath ?? '',
      ),
      _ComposeImageCell(
        label: tailShot == null ? '待尾帧' : '镜头 ${tailShot.shotNumber} 复刻尾帧',
        path: tailShot == null
            ? ''
            : replicatedByShotId[tailShot.id]?.generatedFramePath ?? '',
      ),
      _ComposePromptCell(prompt: prompt, controller: controller),
    ],
  );
}

class _ComposeTableHeaderCell extends StatelessWidget {
  const _ComposeTableHeaderCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

class _ComposeImageCell extends StatelessWidget {
  const _ComposeImageCell({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          if (path.trim().isEmpty || !file.existsSync())
            const SizedBox(height: 150, child: Center(child: Text('图片不可用')))
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                file,
                width: 208,
                height: 150,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 150,
                  child: Center(child: Text('图片预览失败')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ComposePromptCell extends StatefulWidget {
  const _ComposePromptCell({required this.prompt, required this.controller});

  final ShotPrompt? prompt;
  final ReplicateController controller;

  @override
  State<_ComposePromptCell> createState() => _ComposePromptCellState();
}

class _ComposePromptCellState extends State<_ComposePromptCell> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _selectedText());
  }

  @override
  void didUpdateWidget(covariant _ComposePromptCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prompt?.updatedAt != widget.prompt?.updatedAt) {
      _textController.text = _selectedText();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String _selectedText() {
    final prompt = widget.prompt;
    if (prompt == null) return '';
    return widget.controller.promptTextFor(
      prompt,
      widget.controller.promptFormatFor(prompt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    if (prompt == null) {
      return const SizedBox.shrink();
    }
    final format = widget.controller.promptFormatFor(prompt);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<ShotPromptFormat>(
                  segments: const [
                    ButtonSegment(
                      value: ShotPromptFormat.sd2,
                      label: Text('即梦规则版'),
                    ),
                    ButtonSegment(
                      value: ShotPromptFormat.kling,
                      label: Text('可灵'),
                    ),
                  ],
                  selected: {format},
                  onSelectionChanged: (selection) => widget.controller
                      .selectPromptFormat(prompt.id, selection.first),
                ),
              ),
              IconButton(
                tooltip: '复制当前版本',
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: _textController.text),
                ),
                icon: const Icon(Icons.copy_rounded),
              ),
              IconButton.filledTonal(
                tooltip: '保存当前版本',
                onPressed: () => widget.controller.updatePromptText(
                  prompt.id,
                  _textController.text,
                ),
                icon: const Icon(Icons.save_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _textController,
            minLines: 6,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
              labelText: '生成提示词',
            ),
          ),
        ],
      ),
    );
  }
}

class _NewShotTable extends StatefulWidget {
  const _NewShotTable({
    required this.state,
    required this.controller,
    required this.confirmed,
    required this.startEndFrameMode,
    required this.onOpenPrompt,
    this.onOpenFrame,
  });

  static double totalWidth(bool startEndFrameMode) =>
      3385.0 + (startEndFrameMode ? 336.0 : 0.0);
  static const rowHeight = 112.0;
  static const textCellMaxLines = 4;

  final ReplicateState state;
  final ReplicateController controller;
  final Set<String> confirmed;
  final bool startEndFrameMode;
  final ValueChanged<ShotPrompt> onOpenPrompt;
  final void Function(int index, bool showOriginal)? onOpenFrame;

  @override
  State<_NewShotTable> createState() => _NewShotTableState();
}

class _NewShotTableState extends State<_NewShotTable> {
  final _horizontalController = ScrollController();
  final _verticalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final promptByShotId = <String, ShotPrompt>{
      for (final prompt in widget.state.prompts)
        if (prompt.scriptShotId != null) prompt.scriptShotId!: prompt,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in widget.state.replicatedImages)
        image.scriptShotId: image,
    };
    final rows = widget.startEndFrameMode
        ? widget.controller.startEndRows
        : widget.state.shots;
    final table = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SizedBox(
        width: _NewShotTable.totalWidth(widget.startEndFrameMode),
        child: Column(
          children: [
            _NewShotTableHeader(startEndFrameMode: widget.startEndFrameMode),
            Expanded(
              child: widget.state.shots.isEmpty
                  ? const Center(child: Text('当前脚本暂无镜头'))
                  : Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _verticalController,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final shot = rows[index];
                          final shotIndex = widget.state.shots.indexOf(shot);
                          return _NewShotTableRow(
                            key: ValueKey('new-shot-row-${shot.id}'),
                            index: index,
                            shot: shot,
                            tailShot: widget.controller.tailShotForDisplay(
                              shot,
                            ),
                            replicatedImage: replicaByShotId[shot.id],
                            replicatedByShotId: replicaByShotId,
                            prompt: promptByShotId[shot.id],
                            confirmed: widget.confirmed.contains(shot.id),
                            startEndFrameMode: widget.startEndFrameMode,
                            controller: widget.controller,
                            onOpenPrompt: widget.onOpenPrompt,
                            onOpenFrame: widget.onOpenFrame == null
                                ? null
                                : (showOriginal) => widget.onOpenFrame!(
                                    shotIndex < 0 ? index : shotIndex,
                                    showOriginal,
                                  ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    return Scrollbar(
      controller: _horizontalController,
      thumbVisibility: true,
      notificationPredicate: (notification) => notification.depth == 0,
      child: SingleChildScrollView(
        controller: _horizontalController,
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    );
  }
}

class _NewShotTableHeader extends StatelessWidget {
  const _NewShotTableHeader({required this.startEndFrameMode});

  final bool startEndFrameMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          const _NewHeaderCell('镜号', 48),
          _NewHeaderCell(startEndFrameMode ? '首帧' : '原图', 168),
          if (startEndFrameMode) const _NewHeaderCell('尾帧', 168),
          _NewHeaderCell(startEndFrameMode ? '复刻首帧' : '复刻分镜', 168),
          if (startEndFrameMode) const _NewHeaderCell('复刻尾帧', 168),
          const _NewHeaderCell('时长', 64),
          const _NewHeaderCell('画面描述', 680),
          const _NewHeaderCell('景别', 58),
          const _NewHeaderCell('构图', 220),
          const _NewHeaderCell('机位', 150),
          const _NewHeaderCell('光影/氛围', 235),
          const _NewHeaderCell('色彩', 200),
          const _NewHeaderCell('视觉焦点', 220),
          const _NewHeaderCell('剪辑衔接', 220),
          const _NewHeaderCell('对白/旁白', 365),
          const _NewHeaderCell('音效', 223),
          const _NewHeaderCell('运镜', 223),
          const _NewHeaderCell('最终提示词', 85),
          const _NewHeaderCell('操作', 58),
        ],
      ),
    );
  }
}

class _NewHeaderCell extends StatelessWidget {
  const _NewHeaderCell(this.label, this.width);

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.75);
    return SizedBox(
      width: width,
      height: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: divider),
            bottom: BorderSide(color: divider),
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

class _NewShotTableRow extends StatelessWidget {
  const _NewShotTableRow({
    super.key,
    required this.index,
    required this.shot,
    required this.tailShot,
    required this.replicatedImage,
    required this.replicatedByShotId,
    required this.prompt,
    required this.confirmed,
    required this.startEndFrameMode,
    required this.controller,
    required this.onOpenPrompt,
    this.onOpenFrame,
  });

  final int index;
  final ScriptShot shot;
  final ScriptShot? tailShot;
  final ReplicatedShotImage? replicatedImage;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final ShotPrompt? prompt;
  final bool confirmed;
  final bool startEndFrameMode;
  final ReplicateController controller;
  final ValueChanged<ShotPrompt> onOpenPrompt;
  final ValueChanged<bool>? onOpenFrame;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final promptText = prompt?.prompt ?? shot.prompt;
    final hasPrompt = prompt != null || promptText.trim().isNotEmpty;
    final rowColor = confirmed
        ? scheme.primary.withValues(alpha: 0.08)
        : index.isEven
        ? scheme.surfaceContainerLow.withValues(alpha: 0.45)
        : Colors.transparent;
    return Material(
      color: rowColor,
      child: SizedBox(
        height: _NewShotTable.rowHeight,
        child: Row(
          children: [
            _NewShotNumberCell(
              shot: shot,
              confirmed: confirmed,
              enabled: false,
              controller: controller,
            ),
            _ShotFrameCell(
              shot: shot,
              replicatedImage: replicatedImage,
              showOriginal: true,
              labelOverride: startEndFrameMode ? '首帧' : null,
              contextMenuItems: startEndFrameMode
                  ? () => _startEndFrameMenuItems(context)
                  : null,
              onContextMenuSelected: _handleStartEndFrameAction,
              onOpen: onOpenFrame == null ? null : () => onOpenFrame!(true),
            ),
            if (startEndFrameMode)
              _ShotFrameCell(
                shot: tailShot ?? shot,
                replicatedImage: tailShot == null
                    ? null
                    : replicatedByShotId[tailShot!.id],
                showOriginal: true,
                labelOverride: tailShot == null ? '无尾帧' : '尾帧',
                emptyLabel: '无尾帧',
                forceEmpty: tailShot == null,
                keySuffix: 'tail-original',
                onOpen: null,
              ),
            _ShotFrameCell(
              shot: shot,
              replicatedImage: replicatedImage,
              showOriginal: false,
              labelOverride: startEndFrameMode ? '复刻首帧' : null,
              onOpen: onOpenFrame == null ? null : () => onOpenFrame!(false),
            ),
            if (startEndFrameMode)
              _ShotFrameCell(
                shot: tailShot ?? shot,
                replicatedImage: tailShot == null
                    ? null
                    : replicatedByShotId[tailShot!.id],
                showOriginal: false,
                labelOverride: tailShot == null ? '待尾帧' : '复刻尾帧',
                emptyLabel: tailShot == null ? '待尾帧' : '待复刻尾帧',
                forceEmpty: tailShot == null,
                keySuffix: 'tail-replica',
                onOpen: null,
              ),
            _NewDurationCell(
              key: ValueKey('shot-duration-${shot.id}'),
              value: shot.durationSeconds,
              width: 64,
              onCommit: (seconds) => controller.updateShot(
                shot.copyWith(durationSeconds: seconds),
              ),
            ),
            _NewInlineCell(
              value: shot.content,
              width: 680,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(content: value)),
            ),
            _NewInlineCell(
              value: shot.shotSize,
              width: 58,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(shotSize: value)),
            ),
            _NewInlineCell(
              value: shot.composition,
              width: 220,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(composition: value)),
            ),
            _NewInlineCell(
              value: shot.cameraAngle,
              width: 150,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraAngle: value)),
            ),
            _NewInlineCell(
              value: shot.lightingMood,
              width: 235,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(lightingMood: value)),
            ),
            _NewInlineCell(
              value: shot.colorPalette,
              width: 200,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(colorPalette: value)),
            ),
            _NewInlineCell(
              value: shot.visualFocus,
              width: 220,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(visualFocus: value)),
            ),
            _NewInlineCell(
              value: shot.transitionHint,
              width: 220,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(transitionHint: value)),
            ),
            _NewInlineCell(
              value: shot.dialogue,
              width: 365,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(dialogue: value)),
            ),
            _NewInlineCell(
              value: shot.sound,
              width: 223,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(sound: value)),
            ),
            _NewInlineCell(
              value: shot.cameraMovement,
              width: 223,
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraMovement: value)),
            ),
            _NewGridCell(
              width: 85,
              child: TextButton(
                onPressed: hasPrompt && prompt != null
                    ? () => onOpenPrompt(prompt!)
                    : null,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  '查看提示词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _NewGridCell(
              width: 58,
              child: PopupMenuButton<String>(
                tooltip: '操作',
                padding: EdgeInsets.zero,
                iconSize: 17,
                onSelected: (action) {
                  if (action == 'prompt' && prompt != null) {
                    onOpenPrompt(prompt!);
                  } else if (action == 'delete') {
                    controller.deleteShot(shot.id);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'delete', child: Text('删除分镜脚本')),
                  if (prompt != null)
                    const PopupMenuItem(value: 'prompt', child: Text('查看提示词')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _startEndFrameMenuItems(BuildContext context) {
    final pendingStartId = controller.pendingStartFrameShotId;
    final hasTail = tailShot != null;
    if (hasTail) {
      return const [PopupMenuItem(value: 'clear-pair', child: Text('取消首尾帧配对'))];
    }
    if (pendingStartId != null) {
      if (pendingStartId == shot.id) {
        return const [PopupMenuItem(enabled: false, child: Text('已设为首帧'))];
      }
      if (controller.canSelectTailFrame(shot.id)) {
        return const [PopupMenuItem(value: 'set-tail', child: Text('设为尾帧'))];
      }
      return const [PopupMenuItem(enabled: false, child: Text('只能选择后续未占用镜头'))];
    }
    return [
      PopupMenuItem(
        value: controller.canSelectStartFrame(shot.id) ? 'set-start' : null,
        enabled: controller.canSelectStartFrame(shot.id),
        child: const Text('设为首帧'),
      ),
      const PopupMenuItem(enabled: false, child: Text('设为尾帧')),
    ];
  }

  void _handleStartEndFrameAction(String action) {
    switch (action) {
      case 'set-start':
        controller.selectStartFrame(shot.id);
        break;
      case 'set-tail':
        controller.setTailFrame(shot.id);
        break;
      case 'clear-pair':
        controller.clearStartEndPair(shot.id);
        break;
    }
  }
}

class _NewDurationCell extends StatelessWidget {
  const _NewDurationCell({
    super.key,
    required this.value,
    required this.width,
    required this.onCommit,
  });

  final double value;
  final double width;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) => _NewInlineCell(
    value: _durationText(value),
    width: width,
    onCommit: (text) {
      final seconds = _parseDurationSeconds(text);
      if (seconds != null) onCommit(seconds);
    },
  );
}

String _durationText(double seconds) {
  if (seconds == seconds.roundToDouble()) {
    return '${seconds.toInt()}s';
  }
  return '${seconds.toStringAsFixed(1)}s';
}

double? _parseDurationSeconds(String value) {
  var normalized = value.trim().toLowerCase();
  normalized = normalized.replaceAll('秒', '');
  normalized = normalized.replaceFirst(RegExp(r's$'), '').trim();
  final seconds = double.tryParse(normalized);
  if (seconds == null || !seconds.isFinite || seconds < 0) {
    return null;
  }
  return seconds;
}

class _NewTextCell extends StatelessWidget {
  const _NewTextCell(this.value, this.width, {this.centered = false});

  final String value;
  final double width;
  final bool centered;

  @override
  Widget build(BuildContext context) => _NewGridCell(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: centered ? Alignment.center : Alignment.centerLeft,
        child: Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

class _ShotFrameCell extends StatelessWidget {
  const _ShotFrameCell({
    required this.shot,
    required this.replicatedImage,
    required this.showOriginal,
    this.labelOverride,
    this.emptyLabel,
    this.forceEmpty = false,
    this.keySuffix = '',
    this.contextMenuItems,
    this.onContextMenuSelected,
    this.onOpen,
  });

  final ScriptShot shot;
  final ReplicatedShotImage? replicatedImage;
  final bool showOriginal;
  final String? labelOverride;
  final String? emptyLabel;
  final bool forceEmpty;
  final String keySuffix;
  final List<PopupMenuEntry<String>> Function()? contextMenuItems;
  final ValueChanged<String>? onContextMenuSelected;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final generatedPath = replicatedImage?.generatedFramePath ?? '';
    final hasGenerated =
        generatedPath.isNotEmpty && File(generatedPath).existsSync();
    final selectedPath = forceEmpty
        ? ''
        : showOriginal
        ? shot.framePath
        : (hasGenerated ? generatedPath : '');
    final label = labelOverride ?? (showOriginal ? '原图' : '复刻');
    return _NewGridCell(
      width: 168,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Builder(
          builder: (context) {
            final thumbnail = _ShotFrameThumbnail(
              key: ValueKey(
                'replicate-shot-${showOriginal ? 'original' : 'replica'}-thumbnail-${shot.id}${keySuffix.isEmpty ? '' : '-$keySuffix'}',
              ),
              path: selectedPath,
              label: selectedPath.isEmpty ? emptyLabel ?? label : label,
              emptyIcon: showOriginal
                  ? Icons.video_library_outlined
                  : Icons.auto_awesome_outlined,
              onTap: onOpen,
            );
            if (contextMenuItems == null || onContextMenuSelected == null) {
              return thumbnail;
            }
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (details) async {
                final selected = await showMenu<String>(
                  context: context,
                  position: RelativeRect.fromLTRB(
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                  ),
                  items: contextMenuItems!(),
                );
                if (selected != null) onContextMenuSelected!(selected);
              },
              child: thumbnail,
            );
          },
        ),
      ),
    );
  }
}

class _ShotFrameThumbnail extends StatelessWidget {
  const _ShotFrameThumbnail({
    super.key,
    required this.path,
    required this.label,
    required this.emptyIcon,
    this.onTap,
  });

  final String path;
  final String label;
  final IconData emptyIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exists = path.isNotEmpty && File(path).existsSync();
    return Tooltip(
      message: exists ? '$label：$path' : '$label暂不可用',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: exists ? onTap : null,
          borderRadius: BorderRadius.circular(5),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: exists
                      ? Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(emptyIcon, size: 20),
                        )
                      : Icon(
                          emptyIcon,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                ),
                Positioned(
                  left: 3,
                  bottom: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.66),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FrameGalleryItem {
  const _FrameGalleryItem({
    required this.shotNumber,
    required this.path,
    required this.label,
  });

  final int shotNumber;
  final String path;
  final String label;
}

Future<void> _showScriptFrameGallery(
  BuildContext context,
  List<ScriptShot> shots,
  int initialIndex, {
  Map<String, ReplicatedShotImage> replicatedByShotId = const {},
}) {
  final items = [
    for (final shot in shots)
      _FrameGalleryItem(
        shotNumber: shot.shotNumber,
        path: _framePathForGallery(shot, replicatedByShotId),
        label: _frameLabelForGallery(shot, replicatedByShotId),
      ),
  ];
  return showFullscreenZoomGallery<_FrameGalleryItem>(
    context: context,
    items: items,
    initialIndex: initialIndex,
    labelBuilder: (item, index, total) =>
        '镜头 ${item.shotNumber.toString().padLeft(2, '0')} · ${item.label} · ${index + 1}/$total',
    itemBuilder: (context, item) {
      final exists = item.path.isNotEmpty && File(item.path).existsSync();
      if (!exists) {
        return const Center(
          child: Text('当前镜头暂无可预览的原视频帧', style: TextStyle(color: Colors.white)),
        );
      }
      return Image.file(
        File(item.path),
        key: ValueKey(
          'script-frame-gallery-image-${item.shotNumber}-${item.label}',
        ),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Center(
          child: Text('原视频帧无法读取', style: TextStyle(color: Colors.white)),
        ),
      );
    },
  );
}

String _framePathForGallery(
  ScriptShot shot,
  Map<String, ReplicatedShotImage> replicatedByShotId,
) {
  final replicated = replicatedByShotId[shot.id]?.generatedFramePath ?? '';
  if (replicated.isNotEmpty && File(replicated).existsSync()) {
    return replicated;
  }
  return shot.framePath;
}

String _frameLabelForGallery(
  ScriptShot shot,
  Map<String, ReplicatedShotImage> replicatedByShotId,
) {
  final replicated = replicatedByShotId[shot.id]?.generatedFramePath ?? '';
  return replicated.isNotEmpty && File(replicated).existsSync()
      ? '复刻帧'
      : '原视频帧';
}

class _NewGridCell extends StatelessWidget {
  const _NewGridCell({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.55);
    return SizedBox(
      width: width,
      height: _NewShotTable.rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: divider),
            bottom: BorderSide(color: divider),
          ),
        ),
        child: child,
      ),
    );
  }
}

class _NewShotNumberCell extends StatelessWidget {
  const _NewShotNumberCell({
    required this.shot,
    required this.confirmed,
    required this.enabled,
    required this.controller,
  });

  final ScriptShot shot;
  final bool confirmed;
  final bool enabled;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) => _NewGridCell(
    width: 48,
    child: InkWell(
      key: ValueKey('toggle-new-shot-${shot.id}'),
      onTap: enabled
          ? () => controller.toggleShotConfirmed(shot.id, !confirmed)
          : null,
      child: Center(
        child: Text(
          shot.shotNumber.toString(),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

class _NewInlineCell extends StatefulWidget {
  const _NewInlineCell({
    required this.value,
    required this.width,
    required this.onCommit,
    this.maxLines = 1,
  });

  final String value;
  final double width;
  final ValueChanged<String> onCommit;
  final int maxLines;

  @override
  State<_NewInlineCell> createState() => _NewInlineCellState();
}

class _NewInlineCellState extends State<_NewInlineCell> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _lastSaved = widget.value;
    _text = TextEditingController(text: widget.value);
    _focus = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _NewInlineCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _text.text) {
      _text.text = widget.value;
      _lastSaved = widget.value;
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_handleFocusChange)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (_text.text == _lastSaved) return;
    _lastSaved = _text.text;
    widget.onCommit(_text.text);
  }

  @override
  Widget build(BuildContext context) => _NewGridCell(
    width: widget.width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
      child: TextField(
        controller: _text,
        focusNode: _focus,
        minLines: 1,
        maxLines: widget.maxLines,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _commit(),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 1.2,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 7,
          ),
        ),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

class _NewPrepareAssetsStep extends StatelessWidget {
  const _NewPrepareAssetsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.assetBindingController,
    required this.assetLibraryState,
    required this.onImport,
    required this.onImportLocalAsset,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ShootingScriptAssetBindingController assetBindingController;
  final ShootingAssetLibraryState assetLibraryState;
  final ValueChanged<ReplicateAssetType> onImport;
  final Future<ReplicateAsset?> Function(ReplicateAssetType type)
  onImportLocalAsset;
  final ValueChanged<ReplicateAssetType> onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;

  @override
  Widget build(BuildContext context) {
    final canContinue = state.assets.any(
      (item) =>
          item.status == ProcessingStatus.completed &&
          item.path.isNotEmpty &&
          File(item.path).existsSync(),
    );
    const assetTypes = [
      ReplicateAssetType.character,
      ReplicateAssetType.scene,
      ReplicateAssetType.prop,
      ReplicateAssetType.product,
      ReplicateAssetType.reference,
      ReplicateAssetType.video,
      ReplicateAssetType.audio,
      ReplicateAssetType.other,
    ];
    final bindingState = assetBindingController.value;
    final hasConfirmedBinding = bindingState.links.any(
      (link) => link.confirmed,
    );
    return DefaultTabController(
      length: 2,
      child: _WorkspacePanel(
        child: Column(
          children: [
            _StepToolbar(
              title: '步骤 2 · 准备资产',
              subtitle: '点击上传框添加角色、场景、道具和其他参考资产。',
              actions: [
                OutlinedButton.icon(
                  key: const ValueKey('script-auto-match-assets'),
                  onPressed: assetBindingController.value.isBusy
                      ? null
                      : () => assetBindingController.autoMatchAll(
                          preferredAssets: state.assets,
                        ),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(
                    assetBindingController.value.isBusy ? '匹配中…' : '自动匹配资产',
                  ),
                ),
                if (assetBindingController.value.isBusy)
                  OutlinedButton.icon(
                    onPressed: assetBindingController.cancelMatching,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('取消匹配'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => onImport(ReplicateAssetType.reference),
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('批量上传'),
                ),
                FilledButton.icon(
                  key: const ValueKey('replicate-all-shot-images'),
                  onPressed:
                      (canContinue || hasConfirmedBinding) && !state.isBusy
                      ? () => _confirmReplicateAll(context, state, controller)
                      : null,
                  icon: const Icon(Icons.auto_awesome_motion_rounded),
                  label: Text(state.isBusy ? '复刻中…' : '一键复刻'),
                ),
                FilledButton.icon(
                  key: const ValueKey('replicate-new-next-prompts'),
                  onPressed: (canContinue || hasConfirmedBinding)
                      ? () =>
                            controller.moveToStep(ReplicateStep.composePrompts)
                      : null,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('下一步'),
                ),
              ],
            ),
            const Divider(height: 1),
            const TabBar(
              tabs: [
                Tab(text: '资产库'),
                Tab(text: '生成参数设置'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    key: const ValueKey('replicate-asset-library-scroll'),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                    children: [
                      _NewPromptRulesBar(
                        key: ValueKey(state.run!.id),
                        run: state.run!,
                        controller: controller,
                      ),
                      if (state.assets.length > 5) ...[
                        const SizedBox(height: 12),
                        const _AssetRiskNotice(),
                      ],
                      const SizedBox(height: 14),
                      _PrepareAssetsContent(
                        state: state,
                        controller: controller,
                        bindingState: bindingState,
                        assetBindingController: assetBindingController,
                        assetLibraryState: assetLibraryState,
                        onImportLocalAsset: onImportLocalAsset,
                      ),
                      const SizedBox(height: 14),
                      _AssetReferenceTable(
                        key: const ValueKey('replicate-asset-reference-table'),
                        types: assetTypes,
                        assets: state.assets,
                        onImport: onImport,
                        onGenerate: onGenerate,
                        onEdit: onEdit,
                        onReplace: onReplace,
                        onDelete: onDelete,
                        onRegenerate: (asset) =>
                            controller.regenerateImageAsset(asset.id),
                      ),
                    ],
                  ),
                  _GenerationParametersTab(
                    run: state.run!,
                    controller: controller,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrepareAssetsContent extends StatelessWidget {
  const _PrepareAssetsContent({
    required this.state,
    required this.controller,
    required this.bindingState,
    required this.assetBindingController,
    required this.assetLibraryState,
    required this.onImportLocalAsset,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ScriptAssetBindingState bindingState;
  final ShootingScriptAssetBindingController assetBindingController;
  final ShootingAssetLibraryState assetLibraryState;
  final Future<ReplicateAsset?> Function(ReplicateAssetType type)
  onImportLocalAsset;

  @override
  Widget build(BuildContext context) {
    final bindingBoard = _ShotAssetBindingBoard(
      state: state,
      startEndFrameMode: controller.startEndFrameModeEnabled,
      rows: controller.startEndFrameModeEnabled
          ? controller.startEndRows
          : state.shots,
      tailShotForDisplay: controller.tailShotForDisplay,
      bindingState: bindingState,
      libraryState: assetLibraryState,
      onDrop: (item, shotId, replaceScriptAssetId) =>
          assetBindingController.replaceLibraryAssetOnShot(
            item,
            shotId,
            replaceScriptAssetId: replaceScriptAssetId,
          ),
      onSelectStepAsset: (item, shotId, replaceScriptAssetId) =>
          assetBindingController.addStepAssetToShot(
            item,
            shotId,
            replaceScriptAssetId: replaceScriptAssetId,
          ),
      onSelectLibraryAsset: (item, shotId, replaceScriptAssetId) =>
          assetBindingController.replaceLibraryAssetOnShot(
            item,
            shotId,
            replaceScriptAssetId: replaceScriptAssetId,
          ),
      onSelectLocalAsset: (type, shotId, replaceScriptAssetId) async {
        final asset = await onImportLocalAsset(type);
        if (asset == null) return;
        await assetBindingController.addStepAssetToShot(
          asset,
          shotId,
          replaceScriptAssetId: replaceScriptAssetId,
        );
      },
      onRemove: assetBindingController.removeAssetFromShot,
      onMatchShot: (shotId) => assetBindingController.autoMatchShot(
        shotId,
        preferredAssets: state.assets,
      ),
      onUpdateInstructions: (shot, instructions) => controller.updateShot(
        shot.copyWith(replicationInstructions: instructions),
      ),
      onReplicateShot: controller.replicateShot,
      onOpenFrame: (shot) => _showScriptFrameGallery(
        context,
        state.shots,
        state.shots.indexOf(shot),
      ),
    );
    return bindingBoard;
  }
}

class _GenerationParametersTab extends StatelessWidget {
  const _GenerationParametersTab({required this.run, required this.controller});

  final ReplicateRun run;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final fallbackModel = ImageGenerationCatalog.models.first.id;
    final model =
        ImageGenerationCatalog.descriptorFor(run.generationModel) == null
        ? fallbackModel
        : run.generationModel;
    final descriptor = ImageGenerationCatalog.descriptorFor(model)!;
    final aspectRatio = _selectedCatalogValue(
      run.generationAspectRatio,
      descriptor.aspectRatios,
      preferred: '16:9',
    );
    final imageSizes = ImageGenerationCatalog.resolutionsFor(
      model,
      aspectRatio,
    );
    final imageSize = _selectedCatalogValue(
      run.generationImageSize,
      imageSizes,
      preferred: '2K',
    );
    final quality = _selectedCatalogValue(
      run.generationQuality,
      descriptor.qualities,
      preferred: 'high',
    );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '一键复刻默认生成参数',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          '这里的设置会保存到当前拍摄脚本；点击“一键复刻”或镜头内“一键替换产品”时自动使用。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            SizedBox(
              width: 320,
              child: ImageGenerationModelSelector(
                key: const ValueKey('replicate-generation-model'),
                value: model,
                requireReferenceSupport: true,
                labelText: '模型',
                prefixIcon: const Icon(Icons.auto_awesome_outlined),
                onChanged: (value) =>
                    controller.updateGenerationDefaults(model: value),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('replicate-generation-aspect-ratio'),
                initialValue: aspectRatio,
                decoration: const InputDecoration(
                  labelText: '比例',
                  prefixIcon: Icon(Icons.crop_16_9_outlined),
                ),
                items: [
                  for (final option in descriptor.aspectRatios)
                    DropdownMenuItem(value: option, child: Text(option)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateGenerationDefaults(aspectRatio: value);
                  }
                },
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('replicate-generation-resolution'),
                initialValue: imageSize,
                decoration: const InputDecoration(
                  labelText: '分辨率',
                  prefixIcon: Icon(Icons.high_quality_outlined),
                ),
                items: [
                  for (final option in imageSizes)
                    DropdownMenuItem(value: option, child: Text(option)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateGenerationDefaults(imageSize: value);
                  }
                },
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('replicate-generation-quality'),
                initialValue: quality,
                decoration: const InputDecoration(
                  labelText: '质量',
                  prefixIcon: Icon(Icons.tune_rounded),
                ),
                items: [
                  for (final option in descriptor.qualities)
                    DropdownMenuItem(value: option, child: Text(option)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateGenerationDefaults(quality: value);
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

String _selectedCatalogValue(
  String value,
  List<String> options, {
  required String preferred,
}) {
  if (options.contains(value)) return value;
  if (options.contains(preferred)) return preferred;
  return options.first;
}

class _ShotAssetBindingBoard extends StatefulWidget {
  const _ShotAssetBindingBoard({
    required this.state,
    required this.startEndFrameMode,
    required this.rows,
    required this.tailShotForDisplay,
    required this.bindingState,
    required this.libraryState,
    required this.onDrop,
    required this.onSelectStepAsset,
    required this.onSelectLibraryAsset,
    required this.onSelectLocalAsset,
    required this.onRemove,
    required this.onMatchShot,
    required this.onUpdateInstructions,
    required this.onReplicateShot,
    required this.onOpenFrame,
  });

  final ReplicateState state;
  final bool startEndFrameMode;
  final List<ScriptShot> rows;
  final ScriptShot? Function(ScriptShot shot) tailShotForDisplay;
  final ScriptAssetBindingState bindingState;
  final ShootingAssetLibraryState libraryState;
  final Future<void> Function(
    ShootingAssetLibraryItem item,
    String shotId,
    String? replaceScriptAssetId,
  )
  onDrop;
  final Future<void> Function(
    ReplicateAsset item,
    String shotId,
    String? replaceScriptAssetId,
  )
  onSelectStepAsset;
  final Future<void> Function(
    ShootingAssetLibraryItem item,
    String shotId,
    String? replaceScriptAssetId,
  )
  onSelectLibraryAsset;
  final Future<void> Function(
    ReplicateAssetType type,
    String shotId,
    String? replaceScriptAssetId,
  )
  onSelectLocalAsset;
  final void Function(String shotId, String scriptAssetId) onRemove;
  final Future<void> Function(String shotId) onMatchShot;
  final void Function(ScriptShot shot, String instructions)
  onUpdateInstructions;
  final Future<bool> Function(String shotId) onReplicateShot;
  final ValueChanged<ScriptShot> onOpenFrame;

  @override
  State<_ShotAssetBindingBoard> createState() => _ShotAssetBindingBoardState();
}

class _ShotAssetBindingBoardState extends State<_ShotAssetBindingBoard>
    with AutomaticKeepAliveClientMixin {
  final _expandedShotIds = <String>{};
  bool _isShotListVisible = true;

  @override
  bool get wantKeepAlive => true;

  void _toggleAllShotScripts() {
    final shotIds = widget.rows.map((shot) => shot.id).toSet();
    final areAllExpanded =
        shotIds.isNotEmpty && _expandedShotIds.containsAll(shotIds);
    setState(() {
      if (areAllExpanded) {
        _expandedShotIds.clear();
        _isShotListVisible = false;
      } else {
        _expandedShotIds
          ..clear()
          ..addAll(shotIds);
        _isShotListVisible = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final shotIds = widget.rows.map((shot) => shot.id).toSet();
    final areAllExpanded =
        shotIds.isNotEmpty && _expandedShotIds.containsAll(shotIds);
    final replicatedByShotId = {
      for (final image in widget.state.replicatedImages)
        image.scriptShotId: image,
    };
    final runningReplicationCount = widget.state.replicatedImages
        .where(
          (image) =>
              image.status == ProcessingStatus.running ||
              image.status == ProcessingStatus.retrying,
        )
        .length;
    final replicationMessage = widget.state.message.trim();
    final showReplicationProgress =
        runningReplicationCount > 0 ||
        (widget.state.isBusy && replicationMessage.contains('复刻'));
    _expandedShotIds.removeWhere(
      (id) => !widget.rows.any((shot) => shot.id == id),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '按镜头绑定资产',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text('默认折叠脚本内容', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(width: 4),
                TextButton.icon(
                  key: ValueKey(
                    areAllExpanded
                        ? 'collapse-all-shot-scripts'
                        : 'expand-all-shot-scripts',
                  ),
                  onPressed: widget.rows.isEmpty ? null : _toggleAllShotScripts,
                  icon: Icon(
                    areAllExpanded
                        ? Icons.unfold_less_rounded
                        : Icons.unfold_more_rounded,
                    size: 16,
                  ),
                  label: Text(areAllExpanded ? '全部折叠' : '全部展开'),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              '自动匹配优先使用本步骤已上传的资产；未匹配到时再从资产库寻找。点击资产格子可重新选择，也可将资产库卡片拖到格子替换。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (showReplicationProgress)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DecoratedBox(
                  key: const ValueKey('replicate-running-status'),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            replicationMessage.isNotEmpty
                                ? replicationMessage
                                : '正在复刻，当前有 $runningReplicationCount 个镜头处理中…',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.libraryState.items.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('资产库暂无内容；仍可直接使用本步骤已上传的资产。'),
              ),
            const Divider(height: 16),
            if (widget.rows.isEmpty)
              const Text('当前脚本暂无镜头')
            else if (_isShotListVisible)
              for (final shot in widget.rows) ...[
                _ShotAssetDropRow(
                  shot: shot,
                  tailShot: widget.tailShotForDisplay(shot),
                  replicatedByShotId: replicatedByShotId,
                  startEndFrameMode: widget.startEndFrameMode,
                  links: widget.bindingState.linksForShot(shot.id),
                  bindingState: widget.bindingState,
                  libraryItems: widget.libraryState.items,
                  stepAssets: widget.state.assets,
                  expanded: _expandedShotIds.contains(shot.id),
                  onToggleExpanded: () => setState(() {
                    if (!_expandedShotIds.add(shot.id)) {
                      _expandedShotIds.remove(shot.id);
                    }
                  }),
                  onDrop: (item, replaceId) =>
                      widget.onDrop(item, shot.id, replaceId),
                  onSelectStepAsset: (item, replaceId) =>
                      widget.onSelectStepAsset(item, shot.id, replaceId),
                  onSelectLibraryAsset: (item, replaceId) =>
                      widget.onSelectLibraryAsset(item, shot.id, replaceId),
                  onSelectLocalAsset: (type, replaceId) =>
                      widget.onSelectLocalAsset(type, shot.id, replaceId),
                  onRemove: (assetId) => widget.onRemove(shot.id, assetId),
                  onMatch: () => widget.onMatchShot(shot.id),
                  onUpdateInstructions: (instructions) =>
                      widget.onUpdateInstructions(shot, instructions),
                  replicatedImage: replicatedByShotId[shot.id],
                  onReplicate: () => widget.onReplicateShot(shot.id),
                  onOpenFrame: () => widget.onOpenFrame(shot),
                ),
                if (shot != widget.rows.last) const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

class _ShotAssetDropRow extends StatelessWidget {
  const _ShotAssetDropRow({
    required this.shot,
    required this.tailShot,
    required this.replicatedByShotId,
    required this.startEndFrameMode,
    required this.links,
    required this.bindingState,
    required this.libraryItems,
    required this.stepAssets,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onDrop,
    required this.onSelectStepAsset,
    required this.onSelectLibraryAsset,
    required this.onSelectLocalAsset,
    required this.onRemove,
    required this.onMatch,
    required this.onUpdateInstructions,
    required this.replicatedImage,
    required this.onReplicate,
    required this.onOpenFrame,
  });

  final ScriptShot shot;
  final ScriptShot? tailShot;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final bool startEndFrameMode;
  final List<ScriptShotAssetLink> links;
  final ScriptAssetBindingState bindingState;
  final List<ShootingAssetLibraryItem> libraryItems;
  final List<ReplicateAsset> stepAssets;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Future<void> Function(ShootingAssetLibraryItem item, String? replaceId)
  onDrop;
  final Future<void> Function(ReplicateAsset item, String? replaceId)
  onSelectStepAsset;
  final Future<void> Function(ShootingAssetLibraryItem item, String? replaceId)
  onSelectLibraryAsset;
  final Future<void> Function(ReplicateAssetType type, String? replaceId)
  onSelectLocalAsset;
  final ValueChanged<String> onRemove;
  final VoidCallback onMatch;
  final ValueChanged<String> onUpdateInstructions;
  final ReplicatedShotImage? replicatedImage;
  final Future<bool> Function() onReplicate;
  final VoidCallback onOpenFrame;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final assetSlots = _buildAssetSlots(context);
    final frameStrip = _ShotAssetFrameStrip(
      shot: shot,
      tailShot: tailShot,
      replicatedImage: replicatedImage,
      tailReplicatedImage: tailShot == null
          ? null
          : replicatedByShotId[tailShot!.id],
      startEndFrameMode: startEndFrameMode,
      onOpenFrame: onOpenFrame,
    );
    final instructionsField = _ShotReplicationInstructionsField(
      key: ValueKey('replicate-user-instructions-${shot.id}'),
      value: shot.replicationInstructions,
      onCommit: onUpdateInstructions,
    );
    final replicationStatus = replicatedImage == null
        ? null
        : Tooltip(
            key: ValueKey('replicate-shot-status-${shot.id}'),
            message: replicatedImage!.errorMessage.isEmpty
                ? _replicationStatusLabel(replicatedImage!.status)
                : replicatedImage!.errorMessage,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                _replicationStatusIcon(replicatedImage!.status),
                size: 18,
                color: replicatedImage!.status == ProcessingStatus.failed
                    ? scheme.error
                    : scheme.primary,
              ),
            ),
          );
    return AnimatedContainer(
      key: ValueKey('shot-asset-row-${shot.id}'),
      duration: const Duration(milliseconds: 120),
      padding: expanded ? const EdgeInsets.all(8) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: expanded ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: expanded ? Border.all(color: scheme.outlineVariant) : null,
      ),
      child: expanded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      key: ValueKey('toggle-shot-script-${shot.id}'),
                      tooltip: '折叠分镜脚本',
                      onPressed: onToggleExpanded,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '镜头 ${shot.shotNumber.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              shot.content.isEmpty ? shot.visual : shot.content,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '自动匹配此镜头',
                      onPressed: onMatch,
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    ),
                    // ignore: use_null_aware_elements
                    if (replicationStatus != null) replicationStatus,
                    OutlinedButton.icon(
                      key: ValueKey('replicate-shot-image-${shot.id}'),
                      onPressed: links.isNotEmpty ? onReplicate : null,
                      icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                      label: Text(
                        startEndFrameMode && tailShot != null
                            ? '复刻首尾帧'
                            : '一键替换产品',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  key: ValueKey('shot-asset-visual-row-${shot.id}'),
                  builder: (context, constraints) {
                    final frameWidth = startEndFrameMode ? 304.0 : 142.0;
                    if (constraints.maxWidth >= 760) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: frameWidth, child: frameStrip),
                          const SizedBox(width: 8),
                          Expanded(child: assetSlots),
                          const SizedBox(width: 10),
                          SizedBox(width: 300, child: instructionsField),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: frameWidth, child: frameStrip),
                            const SizedBox(width: 8),
                            Expanded(child: assetSlots),
                          ],
                        ),
                        const SizedBox(height: 8),
                        instructionsField,
                      ],
                    );
                  },
                ),
              ],
            )
          : LayoutBuilder(
              key: ValueKey('shot-asset-visual-row-${shot.id}'),
              builder: (context, constraints) {
                final leading = <Widget>[
                  IconButton(
                    key: ValueKey('toggle-shot-script-${shot.id}'),
                    tooltip: '展开分镜脚本',
                    onPressed: onToggleExpanded,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  // ignore: use_null_aware_elements
                  if (replicationStatus != null) replicationStatus,
                  const SizedBox(width: 4),
                ];
                final frameWidth = startEndFrameMode ? 304.0 : 142.0;
                if (constraints.maxWidth >= 720) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...leading,
                      SizedBox(width: frameWidth, child: frameStrip),
                      const SizedBox(width: 8),
                      Expanded(child: assetSlots),
                      const SizedBox(width: 10),
                      SizedBox(width: 280, child: instructionsField),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ...leading,
                          SizedBox(width: frameWidth, child: frameStrip),
                          const SizedBox(width: 8),
                          Expanded(child: assetSlots),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: instructionsField,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildAssetSlots(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final link in links)
          if (bindingState.assetById(link.scriptAssetId) case final asset?)
            _AssetBindingSlot(
              asset: asset,
              link: link,
              onTap: () => _openAssetPicker(
                context,
                replaceScriptAssetId: link.scriptAssetId,
              ),
              onDrop: (item) => onDrop(item, link.scriptAssetId),
              onRemove: () => onRemove(link.scriptAssetId),
            ),
        _EmptyAssetBindingSlot(
          onTap: () => _openAssetPicker(context),
          onDrop: (item) => onDrop(item, null),
        ),
      ],
    );
  }

  Future<void> _openAssetPicker(
    BuildContext context, {
    String? replaceScriptAssetId,
  }) async {
    final choices = [
      for (final asset in stepAssets)
        if (asset.path.trim().isNotEmpty) _ShotAssetChoice.step(asset),
      for (final item in libraryItems) _ShotAssetChoice.library(item),
    ];
    final selected = await showDialog<_ShotAssetChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(replaceScriptAssetId == null ? '选择镜头资产' : '重新选择镜头资产'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: choices.isEmpty
              ? const Center(child: Text('暂无可用资产，请先上传资产图或添加资产库内容。'))
              : ListView.separated(
                  itemCount: choices.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    return ListTile(
                      leading: _BindingAssetPreview(
                        path: choice.path,
                        label: choice.name,
                      ),
                      title: Text(choice.name),
                      subtitle: Text(
                        '${choice.type.label}${choice.description.isEmpty ? '' : ' · ${choice.description}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(dialogContext).pop(choice),
                    );
                  },
                ),
        ),
        actions: [
          TextButton.icon(
            key: ValueKey('select-local-shot-asset-$shot.id'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ShotAssetChoice.local()),
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('从本地文件添加'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    if (selected.isLocalFile) {
      await onSelectLocalAsset(
        ReplicateAssetType.reference,
        replaceScriptAssetId,
      );
    } else if (selected.stepAsset != null) {
      await onSelectStepAsset(selected.stepAsset!, replaceScriptAssetId);
    } else if (selected.libraryItem != null) {
      await onSelectLibraryAsset(selected.libraryItem!, replaceScriptAssetId);
    }
  }
}

class _ShotReplicationInstructionsField extends StatefulWidget {
  const _ShotReplicationInstructionsField({
    super.key,
    required this.value,
    required this.onCommit,
  });

  final String value;
  final ValueChanged<String> onCommit;

  @override
  State<_ShotReplicationInstructionsField> createState() =>
      _ShotReplicationInstructionsFieldState();
}

class _ShotReplicationInstructionsFieldState
    extends State<_ShotReplicationInstructionsField> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  late String _lastSaved;

  @override
  void initState() {
    super.initState();
    _lastSaved = widget.value;
    _text = TextEditingController(text: widget.value);
    _focus = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _ShotReplicationInstructionsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _text.text) {
      _text.text = widget.value;
      _lastSaved = widget.value;
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_handleFocusChange)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final normalized = _text.text.trim();
    if (normalized == _lastSaved) return;
    _lastSaved = normalized;
    widget.onCommit(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      focusNode: _focus,
      minLines: 2,
      maxLines: 3,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) {
        _commit();
        _focus.unfocus();
      },
      decoration: const InputDecoration(
        labelText: '复刻补充说明',
        hintText: '仅影响本镜头之后的复刻…',
        alignLabelWithHint: true,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      ),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

class _ShotAssetFrameStrip extends StatelessWidget {
  const _ShotAssetFrameStrip({
    required this.shot,
    required this.tailShot,
    required this.replicatedImage,
    required this.tailReplicatedImage,
    required this.startEndFrameMode,
    required this.onOpenFrame,
  });

  final ScriptShot shot;
  final ScriptShot? tailShot;
  final ReplicatedShotImage? replicatedImage;
  final ReplicatedShotImage? tailReplicatedImage;
  final bool startEndFrameMode;
  final VoidCallback onOpenFrame;

  @override
  Widget build(BuildContext context) {
    if (!startEndFrameMode) {
      return SizedBox(
        width: 142,
        height: 118,
        child: _ShotFrameThumbnail(
          key: ValueKey('prepare-asset-frame-${shot.id}'),
          path: shot.framePath,
          label: '原视频帧',
          emptyIcon: Icons.video_library_outlined,
          onTap: onOpenFrame,
        ),
      );
    }
    final firstReplicaPath = _completedReplicatedPath(replicatedImage);
    final tailReplicaPath = _completedReplicatedPath(tailReplicatedImage);
    return Wrap(
      key: ValueKey('prepare-asset-start-end-strip-${shot.id}'),
      spacing: 6,
      runSpacing: 6,
      children: [
        _smallFrame(
          shot: shot,
          path: shot.framePath,
          label: '首帧',
          icon: Icons.video_library_outlined,
          onTap: onOpenFrame,
        ),
        _smallFrame(
          shot: tailShot ?? shot,
          path: tailShot?.framePath ?? '',
          label: tailShot == null ? '无尾帧' : '尾帧',
          icon: Icons.video_library_outlined,
        ),
        _smallFrame(
          shot: shot,
          path: firstReplicaPath,
          label: '复刻首帧',
          icon: Icons.auto_awesome_outlined,
        ),
        _smallFrame(
          shot: tailShot ?? shot,
          path: tailShot == null ? '' : tailReplicaPath,
          label: tailShot == null ? '待尾帧' : '复刻尾帧',
          icon: Icons.auto_awesome_outlined,
        ),
      ],
    );
  }

  Widget _smallFrame({
    required ScriptShot shot,
    required String path,
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) => SizedBox(
    width: 149,
    height: 56,
    child: _ShotFrameThumbnail(
      key: ValueKey('prepare-asset-$label-${shot.id}'),
      path: path,
      label: label,
      emptyIcon: icon,
      onTap: onTap,
    ),
  );

  static String _completedReplicatedPath(ReplicatedShotImage? image) {
    if (image?.status != ProcessingStatus.completed) return '';
    final path = image?.generatedFramePath.trim() ?? '';
    return path.isNotEmpty && File(path).existsSync() ? path : '';
  }
}

class _ShotAssetChoice {
  const _ShotAssetChoice._({
    this.stepAsset,
    this.libraryItem,
    this.isLocalFile = false,
  });

  factory _ShotAssetChoice.step(ReplicateAsset asset) =>
      _ShotAssetChoice._(stepAsset: asset);

  factory _ShotAssetChoice.library(ShootingAssetLibraryItem item) =>
      _ShotAssetChoice._(libraryItem: item);

  factory _ShotAssetChoice.local() =>
      const _ShotAssetChoice._(isLocalFile: true);

  final ReplicateAsset? stepAsset;
  final ShootingAssetLibraryItem? libraryItem;
  final bool isLocalFile;

  String get name => stepAsset?.name ?? libraryItem!.name;
  String get description => stepAsset?.description ?? libraryItem!.description;
  String get path => stepAsset?.path ?? libraryItem!.path;
  ReplicateAssetType get type => stepAsset?.type ?? libraryItem!.type;
}

class _AssetBindingSlot extends StatelessWidget {
  const _AssetBindingSlot({
    required this.asset,
    required this.link,
    required this.onTap,
    required this.onDrop,
    required this.onRemove,
  });

  final ScriptAsset asset;
  final ScriptShotAssetLink link;
  final VoidCallback onTap;
  final ValueChanged<ShootingAssetLibraryItem> onDrop;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 142,
          height: 118,
          decoration: BoxDecoration(
            color: active ? scheme.primaryContainer : scheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? scheme.primary : scheme.outlineVariant,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _BindingAssetPreview(
                            path: asset.path,
                            label: asset.name,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${asset.type.label} · ${(link.confidence * 100).round()}%',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: '移除资产绑定',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, size: 15),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyAssetBindingSlot extends StatelessWidget {
  const _EmptyAssetBindingSlot({required this.onTap, required this.onDrop});

  final VoidCallback onTap;
  final ValueChanged<ShootingAssetLibraryItem> onDrop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return SizedBox(
          width: 142,
          height: 118,
          child: CustomPaint(
            painter: _DashedBorderPainter(
              active ? scheme.primary : scheme.outlineVariant,
            ),
            child: Material(
              color: active ? scheme.primaryContainer : Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined, size: 24),
                      const SizedBox(height: 4),
                      Text(
                        active ? '松开替换' : '添加资产图',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BindingAssetPreview extends StatelessWidget {
  const _BindingAssetPreview({required this.path, required this.label});

  final String path;
  final String label;

  @override
  Widget build(BuildContext context) {
    final exists = path.trim().isNotEmpty && File(path).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: exists
            ? Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              )
            : Center(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
      ),
    );
  }
}

Future<void> _confirmReplicateAll(
  BuildContext context,
  ReplicateState state,
  ReplicateController controller,
) async {
  final confirmed = state.confirmedShots.length;
  final existing = state.replicatedImages
      .where((image) => image.status == ProcessingStatus.completed)
      .length;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('确认一键复刻'),
      content: Text(
        '将按镜号顺序提交 $confirmed 个镜头，任务之间间隔约 '
        '${ReplicateController.defaultBatchReplicateStagger.inMilliseconds} 毫秒，'
        '最多同时处理 '
        '${ReplicateController.defaultBatchReplicateConcurrency} 个请求，'
        '结果会逐条返回并保存。'
        '${existing > 0 ? '\n\n已有 $existing 个结果会重新生成。' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const ValueKey('confirm-replicate-all-shot-images'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('确认提交'),
        ),
      ],
    ),
  );
  if (accepted == true) await controller.replicateAllShots();
}

String _replicationStatusLabel(ProcessingStatus status) => switch (status) {
  ProcessingStatus.pending => '等待复刻',
  ProcessingStatus.running => '正在复刻',
  ProcessingStatus.completed => '复刻完成',
  ProcessingStatus.partial => '部分完成',
  ProcessingStatus.failed => '复刻失败',
  ProcessingStatus.retrying => '正在重试',
};

IconData _replicationStatusIcon(ProcessingStatus status) => switch (status) {
  ProcessingStatus.pending => Icons.schedule_rounded,
  ProcessingStatus.running ||
  ProcessingStatus.retrying => Icons.hourglass_top_rounded,
  ProcessingStatus.completed => Icons.check_circle_rounded,
  ProcessingStatus.partial => Icons.warning_amber_rounded,
  ProcessingStatus.failed => Icons.error_outline_rounded,
};

class _NewPromptRulesBar extends StatefulWidget {
  const _NewPromptRulesBar({
    super.key,
    required this.run,
    required this.controller,
  });

  final ReplicateRun run;
  final ReplicateController controller;

  @override
  State<_NewPromptRulesBar> createState() => _NewPromptRulesBarState();
}

class _NewPromptRulesBarState extends State<_NewPromptRulesBar> {
  late final TextEditingController _style;
  late final TextEditingController _constraints;

  @override
  void initState() {
    super.initState();
    _style = TextEditingController(text: widget.run.globalStyle);
    _constraints = TextEditingController(text: widget.run.constraints);
  }

  @override
  void dispose() {
    _style.dispose();
    _constraints.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = _compactRuleField(controller: _style, label: '全局风格');
    final constraintsField = _compactRuleField(
      controller: _constraints,
      label: '整体约束',
    );
    final save = IconButton.filledTonal(
      tooltip: '保存提示词规则',
      onPressed: () => widget.controller.updatePromptRules(
        globalStyle: _style.text,
        constraints: _constraints.text,
      ),
      icon: const Icon(Icons.save_rounded, size: 17),
    );
    return LayoutBuilder(
      builder: (context, layoutConstraints) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: layoutConstraints.maxWidth < 720
                ? Column(
                    children: [
                      style,
                      const SizedBox(height: 7),
                      constraintsField,
                      Align(alignment: Alignment.centerRight, child: save),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: style),
                      const SizedBox(width: 8),
                      Expanded(child: constraintsField),
                      const SizedBox(width: 4),
                      save,
                    ],
                  ),
          ),
        );
      },
    );
  }

  static Widget _compactRuleField({
    required TextEditingController controller,
    required String label,
  }) => TextField(
    controller: controller,
    minLines: 1,
    maxLines: 1,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
    ),
    style: const TextStyle(fontSize: 12),
  );
}

class _AssetReferenceTable extends StatefulWidget {
  const _AssetReferenceTable({
    super.key,
    required this.types,
    required this.assets,
    required this.onImport,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
  });

  final List<ReplicateAssetType> types;
  final List<ReplicateAsset> assets;
  final ValueChanged<ReplicateAssetType> onImport;
  final ValueChanged<ReplicateAssetType> onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;
  final ValueChanged<ReplicateAsset> onRegenerate;

  @override
  State<_AssetReferenceTable> createState() => _AssetReferenceTableState();
}

class _AssetReferenceTableState extends State<_AssetReferenceTable> {
  late ReplicateAssetType _selectedType = widget.types.first;

  @override
  void didUpdateWidget(covariant _AssetReferenceTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.types.contains(_selectedType) && widget.types.isNotEmpty) {
      _selectedType = widget.types.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '添加参考图',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<ReplicateAssetType>(
                    key: const ValueKey('asset-type-selector'),
                    initialValue: _selectedType,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '参考图类型',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                    items: [
                      for (final type in widget.types)
                        DropdownMenuItem(
                          value: type,
                          child: Text(_newAssetLabel(type)),
                        ),
                    ],
                    selectedItemBuilder: (context) => [
                      for (final type in widget.types)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text('类型：${_newAssetLabel(type)}'),
                        ),
                    ],
                    onChanged: (type) {
                      if (type != null) setState(() => _selectedType = type);
                    },
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => widget.onImport(_selectedType),
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text('上传${_newAssetLabel(_selectedType)}'),
                ),
                if (_selectedType.isImageType)
                  FilledButton.tonalIcon(
                    onPressed: () => widget.onGenerate(_selectedType),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('按描述生成'),
                  ),
              ],
            ),
          ),
          Container(
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                const SizedBox(
                  width: 112,
                  child: Text(
                    '参考图类型',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const Expanded(
                  child: Text(
                    '资产图片（每种类型可添加多个）',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: Text(
                    '管理',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < widget.types.length; index++)
            _AssetReferenceTableRow(
              type: widget.types[index],
              assets: [
                for (final asset in widget.assets)
                  if (asset.type == widget.types[index]) asset,
              ],
              onImport: () => widget.onImport(widget.types[index]),
              onGenerate: widget.types[index].isImageType
                  ? () => widget.onGenerate(widget.types[index])
                  : null,
              onEdit: widget.onEdit,
              onReplace: widget.onReplace,
              onDelete: widget.onDelete,
              onRegenerate: widget.onRegenerate,
              isLast: index == widget.types.length - 1,
            ),
        ],
      ),
    );
  }
}

class _AssetReferenceTableRow extends StatelessWidget {
  const _AssetReferenceTableRow({
    required this.type,
    required this.assets,
    required this.onImport,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
    required this.isLast,
  });

  final ReplicateAssetType type;
  final List<ReplicateAsset> assets;
  final VoidCallback onImport;
  final VoidCallback? onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;
  final ValueChanged<ReplicateAsset> onRegenerate;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).colorScheme.outlineVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(type.icon, size: 17),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _newAssetLabel(type),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _NewAssetGroup(
                type: type,
                assets: assets,
                onImport: onImport,
                onGenerate: onGenerate,
                onEdit: onEdit,
                onReplace: onReplace,
                onDelete: onDelete,
                onRegenerate: onRegenerate,
                showLabel: false,
              ),
            ),
            const SizedBox(width: 8),
            const SizedBox(
              width: 78,
              child: Center(child: Icon(Icons.more_horiz_rounded, size: 18)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewAssetGroup extends StatelessWidget {
  const _NewAssetGroup({
    required this.type,
    required this.assets,
    required this.onImport,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
    this.showLabel = true,
  });

  final ReplicateAssetType type;
  final List<ReplicateAsset> assets;
  final VoidCallback onImport;
  final VoidCallback? onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;
  final ValueChanged<ReplicateAsset> onRegenerate;
  final bool showLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (showLabel) ...[
        Text(
          _newAssetLabel(type),
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
      ],
      Wrap(
        spacing: 8,
        runSpacing: 14,
        children: [
          for (final asset in assets)
            _NewAssetCard(
              asset: asset,
              type: type,
              onEdit: () => onEdit(asset),
              onReplace: () => onReplace(asset),
              onDelete: () => onDelete(asset),
              onRegenerate: () => onRegenerate(asset),
            ),
          _NewUploadCard(type: type, onTap: onImport, onGenerate: onGenerate),
        ],
      ),
    ],
  );
}

class _NewUploadCard extends StatelessWidget {
  const _NewUploadCard({
    required this.type,
    required this.onTap,
    required this.onGenerate,
  });

  final ReplicateAssetType type;
  final VoidCallback onTap;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 184,
    height: 106,
    child: Tooltip(
      message: onGenerate == null ? '点击上传资产' : '单击上传，长按生成',
      child: CustomPaint(
        painter: _DashedBorderPainter(
          Theme.of(context).colorScheme.outlineVariant,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('upload-asset-${type.name}'),
            onTap: onTap,
            onLongPress: onGenerate,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.add_rounded,
                    size: 22,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '新增${_newAssetLabel(type)}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _NewAssetCard extends StatelessWidget {
  const _NewAssetCard({
    required this.asset,
    required this.type,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
  });

  final ReplicateAsset asset;
  final ReplicateAssetType type;
  final VoidCallback onEdit;
  final VoidCallback onReplace;
  final VoidCallback onDelete;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final isImage =
        SeedancePromptGenerationService.mediaKind(asset) ==
        ReplicateMediaKind.image;
    final hasImage =
        isImage && asset.path.isNotEmpty && File(asset.path).existsSync();
    return SizedBox(
      width: 184,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 106,
            child: CustomPaint(
              painter: _DashedBorderPainter(
                Theme.of(context).colorScheme.outlineVariant,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasImage)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(File(asset.path), fit: BoxFit.cover),
                    )
                  else
                    Center(
                      child: Text(
                        isImage
                            ? '生成或上传${_newAssetLabel(type)}图'
                            : '上传${_newAssetLabel(type)}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: PopupMenuButton<String>(
                      tooltip: '资产操作',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      onSelected: (action) {
                        if (action == 'edit') {
                          onEdit();
                        } else if (action == 'replace') {
                          onReplace();
                        } else if (action == 'generate') {
                          onRegenerate();
                        } else if (action == 'delete') {
                          onDelete();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑信息')),
                        const PopupMenuItem(
                          value: 'replace',
                          child: Text('替换文件'),
                        ),
                        if (isImage)
                          const PopupMenuItem(
                            value: 'generate',
                            child: Text('按描述重新生成'),
                          ),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(
                  asset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                SeedancePromptGenerationService.referenceLabel(asset),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          Text(
            asset.description.isEmpty ? '未填写特征描述' : asset.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: ValueKey('edit-asset-${asset.id}'),
                tooltip: '编辑名称、描述和类型',
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: const Icon(Icons.edit_outlined, size: 16),
              ),
              IconButton(
                key: ValueKey('delete-asset-${asset.id}'),
                tooltip: '移除资产',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      );
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 8) {
        final end = (distance + 4).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, end), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

String _newAssetLabel(ReplicateAssetType type) => switch (type) {
  ReplicateAssetType.character => '角色',
  ReplicateAssetType.product => '产品',
  ReplicateAssetType.scene => '场景',
  ReplicateAssetType.prop => '道具',
  ReplicateAssetType.video => '视频',
  ReplicateAssetType.audio => '音频',
  ReplicateAssetType.reference => '参考',
  ReplicateAssetType.other => '其他',
};

class _ConfirmShotsStep extends StatelessWidget {
  const _ConfirmShotsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.settingsController,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final SettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 1 · 查阅脚本镜头',
            subtitle: '请自行查阅并编辑镜头内容，修改会同步回拍摄脚本。',
            actions: [
              _StartEndFrameModeSwitch(controller: settingsController),
              FilledButton.icon(
                key: const ValueKey('replicate-next-assets'),
                onPressed: state.shots.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.prepareAssets),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 2280,
                child: Column(
                  children: [
                    const _ConfirmTableHeader(),
                    Expanded(
                      child: state.shots.isEmpty
                          ? const Center(child: Text('当前脚本暂无镜头'))
                          : ListView.builder(
                              itemCount: state.shots.length,
                              itemBuilder: (context, index) {
                                final shot = state.shots[index];
                                return _ConfirmShotRow(
                                  key: ValueKey(shot.id),
                                  shot: shot,
                                  controller: controller,
                                  onOpenFrame: () => _showScriptFrameGallery(
                                    context,
                                    state.shots,
                                    index,
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmTableHeader extends StatelessWidget {
  const _ConfirmTableHeader();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: const Row(
      children: [
        _HeaderCell('原视频帧', 128),
        _HeaderCell('镜号', 66),
        _HeaderCell('时长', 80),
        _HeaderCell('画面描述', 270),
        _HeaderCell('景别', 110),
        _HeaderCell('构图', 200),
        _HeaderCell('机位', 140),
        _HeaderCell('光影/氛围', 190),
        _HeaderCell('色彩', 160),
        _HeaderCell('视觉焦点', 200),
        _HeaderCell('剪辑承接', 220),
        _HeaderCell('对白/旁白', 180),
        _HeaderCell('音效', 150),
        _HeaderCell('运镜', 152),
        _HeaderCell('操作', 58),
      ],
    ),
  );
}

class _ConfirmShotRow extends StatelessWidget {
  const _ConfirmShotRow({
    super.key,
    required this.shot,
    required this.controller,
    required this.onOpenFrame,
  });

  final ScriptShot shot;
  final ReplicateController controller;
  final VoidCallback onOpenFrame;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.transparent,
      child: SizedBox(
        height: 92,
        child: Row(
          children: [
            SizedBox(
              width: 128,
              height: 92,
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: _ShotFrameThumbnail(
                  path: shot.framePath,
                  label: '原图',
                  emptyIcon: Icons.video_library_outlined,
                  onTap: onOpenFrame,
                ),
              ),
            ),
            _TextCell('${shot.shotNumber}'.padLeft(2, '0'), 66),
            _DurationCommitCell(
              value: shot.durationSeconds,
              width: 80,
              onCommit: (seconds) => controller.updateShot(
                shot.copyWith(durationSeconds: seconds),
              ),
            ),
            _CommitCell(
              value: shot.content,
              width: 270,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(content: value)),
            ),
            _CommitCell(
              value: shot.shotSize,
              width: 110,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(shotSize: value)),
            ),
            _CommitCell(
              value: shot.composition,
              width: 200,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(composition: value)),
            ),
            _CommitCell(
              value: shot.cameraAngle,
              width: 140,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraAngle: value)),
            ),
            _CommitCell(
              value: shot.lightingMood,
              width: 190,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(lightingMood: value)),
            ),
            _CommitCell(
              value: shot.colorPalette,
              width: 160,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(colorPalette: value)),
            ),
            _CommitCell(
              value: shot.visualFocus,
              width: 200,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(visualFocus: value)),
            ),
            _CommitCell(
              value: shot.transitionHint,
              width: 220,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(transitionHint: value)),
            ),
            _CommitCell(
              value: shot.dialogue,
              width: 180,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(dialogue: value)),
            ),
            _CommitCell(
              value: shot.sound,
              width: 150,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(sound: value)),
            ),
            _CommitCell(
              value: shot.cameraMovement,
              width: 152,
              maxLines: 2,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraMovement: value)),
            ),
            SizedBox(
              width: 58,
              child: PopupMenuButton<String>(
                tooltip: '操作',
                onSelected: (action) {
                  if (action == 'delete') controller.deleteShot(shot.id);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除分镜脚本')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrepareAssetsStep extends StatelessWidget {
  const _PrepareAssetsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.onImport,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ValueChanged<ReplicateAssetType> onImport;
  final ValueChanged<ReplicateAssetType> onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;

  @override
  Widget build(BuildContext context) {
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 2 · 准备参考素材',
            subtitle: '模型引用使用图片N、视频N、音频N；删除后不改动既有编号。',
            actions: [
              OutlinedButton.icon(
                onPressed: () => onImport(ReplicateAssetType.reference),
                icon: const Icon(Icons.upload_file_rounded),
                label: const Text('批量上传'),
              ),
              FilledButton.icon(
                key: const ValueKey('replicate-next-prompts'),
                onPressed:
                    state.assets.any(
                      (item) =>
                          item.status == ProcessingStatus.completed &&
                          item.path.isNotEmpty &&
                          File(item.path).existsSync(),
                    )
                    ? () => controller.moveToStep(ReplicateStep.composePrompts)
                    : null,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                _PromptRulesEditor(
                  key: ValueKey(state.run!.id),
                  run: state.run!,
                  controller: controller,
                ),
                if (state.assets.length > 5) ...[
                  const SizedBox(height: 12),
                  const _AssetRiskNotice(),
                ],
                const SizedBox(height: 16),
                for (final type in ReplicateAssetType.values)
                  if (type != ReplicateAssetType.other) ...[
                    _AssetGroup(
                      type: type,
                      assets: [
                        for (final asset in state.assets)
                          if (asset.type == type) asset,
                      ],
                      onImport: () => onImport(type),
                      onGenerate: type.isImageType
                          ? () => onGenerate(type)
                          : null,
                      onEdit: onEdit,
                      onReplace: onReplace,
                      onDelete: onDelete,
                      onRegenerate: (asset) =>
                          controller.regenerateImageAsset(asset.id),
                      prompts: state.prompts,
                      totalShots: state.confirmedShots.length,
                    ),
                    const SizedBox(height: 16),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptRulesEditor extends StatefulWidget {
  const _PromptRulesEditor({
    super.key,
    required this.run,
    required this.controller,
  });

  final ReplicateRun run;
  final ReplicateController controller;

  @override
  State<_PromptRulesEditor> createState() => _PromptRulesEditorState();
}

class _PromptRulesEditorState extends State<_PromptRulesEditor> {
  late final TextEditingController _style;
  late final TextEditingController _constraints;

  @override
  void initState() {
    super.initState();
    _style = TextEditingController(text: widget.run.globalStyle);
    _constraints = TextEditingController(text: widget.run.constraints);
  }

  @override
  void dispose() {
    _style.dispose();
    _constraints.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final styleField = TextField(
          controller: _style,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '全局风格',
            alignLabelWithHint: true,
          ),
        );
        final constraintsField = TextField(
          controller: _constraints,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '整体约束',
            alignLabelWithHint: true,
          ),
        );
        final saveButton = FilledButton.tonalIcon(
          onPressed: () => widget.controller.updatePromptRules(
            globalStyle: _style.text,
            constraints: _constraints.text,
          ),
          icon: const Icon(Icons.save_rounded),
          label: const Text('保存'),
        );
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本任务提示词规则',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (constraints.maxWidth < 760) ...[
                  styleField,
                  const SizedBox(height: 12),
                  constraintsField,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: saveButton),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: styleField),
                      const SizedBox(width: 12),
                      Expanded(child: constraintsField),
                      const SizedBox(width: 12),
                      saveButton,
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AssetGroup extends StatelessWidget {
  const _AssetGroup({
    required this.type,
    required this.assets,
    required this.onImport,
    required this.onGenerate,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
    required this.prompts,
    required this.totalShots,
  });

  final ReplicateAssetType type;
  final List<ReplicateAsset> assets;
  final VoidCallback onImport;
  final VoidCallback? onGenerate;
  final ValueChanged<ReplicateAsset> onEdit;
  final ValueChanged<ReplicateAsset> onReplace;
  final ValueChanged<ReplicateAsset> onDelete;
  final ValueChanged<ReplicateAsset> onRegenerate;
  final List<ShotPrompt> prompts;
  final int totalShots;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(type.icon, size: 20),
            const SizedBox(width: 7),
            Text(type.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            Text('${assets.length} 个'),
            const Spacer(),
            if (onGenerate != null)
              TextButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('生成'),
              ),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add_rounded),
              label: const Text('上传'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (assets.isEmpty)
          Container(
            height: 76,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('尚未添加${type.label}素材'),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final asset in assets)
                _AssetCard(
                  asset: asset,
                  onEdit: () => onEdit(asset),
                  onReplace: () => onReplace(asset),
                  onDelete: () => onDelete(asset),
                  onRegenerate: () => onRegenerate(asset),
                  usageCount: prompts
                      .where((prompt) => prompt.assetIds.contains(asset.id))
                      .length,
                  totalShots: totalShots,
                ),
            ],
          ),
      ],
    );
  }
}

class _AssetRiskNotice extends StatelessWidget {
  const _AssetRiskNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline_rounded),
          SizedBox(width: 10),
          Expanded(child: Text('参考素材已超过推荐的 4–5 个；仍可继续，但主体和风格稳定性可能下降。')),
        ],
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.onEdit,
    required this.onReplace,
    required this.onDelete,
    required this.onRegenerate,
    required this.usageCount,
    required this.totalShots,
  });

  final ReplicateAsset asset;
  final VoidCallback onEdit;
  final VoidCallback onReplace;
  final VoidCallback onDelete;
  final VoidCallback onRegenerate;
  final int usageCount;
  final int totalShots;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isImage =
        SeedancePromptGenerationService.mediaKind(asset) ==
        ReplicateMediaKind.image;
    return SizedBox(
      width: 224,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 126,
              child: isImage && asset.path.isNotEmpty
                  ? Image.file(
                      File(asset.path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _AssetIcon(type: asset.type),
                    )
                  : _AssetIcon(type: asset.type),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '素材操作',
                        onSelected: (action) => switch (action) {
                          'edit' => onEdit(),
                          'replace' => onReplace(),
                          'generate' => onRegenerate(),
                          'delete' => onDelete(),
                          _ => null,
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('编辑信息'),
                          ),
                          const PopupMenuItem(
                            value: 'replace',
                            child: Text('替换文件'),
                          ),
                          if (isImage)
                            const PopupMenuItem(
                              value: 'generate',
                              child: Text('按描述重新生成'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    SeedancePromptGenerationService.referenceLabel(asset),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    asset.description.isEmpty ? '未填写特征描述' : asset.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    asset.status.label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: asset.status.color(scheme),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    usageCount == 0 ? '未使用' : '已用于 $usageCount/$totalShots 个镜头',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetIcon extends StatelessWidget {
  const _AssetIcon({required this.type});

  final ReplicateAssetType type;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(child: Icon(type.icon, size: 48)),
  );
}

class _ComposePromptsStep extends StatelessWidget {
  const _ComposePromptsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.onCopyAll,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ValueChanged<ReplicateState> onCopyAll;

  @override
  Widget build(BuildContext context) {
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 3 · 合成即梦 / 可灵提示词',
            subtitle: state.run!.globalStyle,
            actions: [
              FilledButton.icon(
                key: const ValueKey('compose-all-seedance-prompts'),
                onPressed: state.isBusy ? null : controller.composeAllPrompts,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(state.prompts.isEmpty ? '生成全部' : '重新生成全部'),
              ),
              OutlinedButton.icon(
                onPressed:
                    state.prompts.any(
                      (item) => item.status == ProcessingStatus.failed,
                    )
                    ? controller.retryFailedPrompts
                    : null,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试失败'),
              ),
              OutlinedButton.icon(
                onPressed: state.prompts.isEmpty
                    ? null
                    : () => onCopyAll(state),
                icon: const Icon(Icons.copy_all_rounded),
                label: const Text('复制全部'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('export-seedance-prompts'),
                onPressed: state.prompts.isEmpty
                    ? null
                    : controller.exportPrompts,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('导出 XLSX'),
              ),
              IconButton(
                tooltip: '打开提示词目录',
                onPressed: controller.openPromptDirectory,
                icon: const Icon(Icons.folder_open_rounded),
              ),
              FilledButton.icon(
                key: const ValueKey('go-video-generation'),
                onPressed: state.prompts.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.generateVideos),
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步：生成视频'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: state.prompts.isEmpty
                ? _EmptyPrompts(
                    onGenerate: state.isBusy
                        ? null
                        : controller.composeAllPrompts,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: state.prompts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final prompt = state.prompts[index];
                      ScriptShot? shot;
                      for (final item in state.shots) {
                        if (item.id == prompt.scriptShotId) shot = item;
                      }
                      return _PromptCard(
                        key: ValueKey(
                          '${prompt.id}-${prompt.updatedAt.microsecondsSinceEpoch}',
                        ),
                        prompt: prompt,
                        shot: shot,
                        controller: controller,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PromptCard extends StatefulWidget {
  const _PromptCard({
    super.key,
    required this.prompt,
    required this.shot,
    required this.controller,
  });

  final ShotPrompt prompt;
  final ScriptShot? shot;
  final ReplicateController controller;

  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.prompt.prompt);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warnings = _warnings(widget.prompt.rawResponse);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 210,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '镜头 ${widget.prompt.shotNumber.toString().padLeft(2, '0')}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${widget.shot?.durationSeconds.toStringAsFixed(1) ?? '0.0'}s · ${widget.shot?.shotSize ?? ''}',
                  ),
                  const SizedBox(height: 5),
                  Text(
                    widget.shot?.content ?? '原镜头已不存在',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.prompt.status.label,
                    style: TextStyle(
                      color: widget.prompt.status.color(scheme),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (warnings.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      warnings.join('；'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 6,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '最终提示词',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              children: [
                IconButton.filledTonal(
                  tooltip: '保存编辑',
                  onPressed: () => widget.controller.updatePromptText(
                    widget.prompt.id,
                    _text.text,
                  ),
                  icon: const Icon(Icons.save_rounded),
                ),
                IconButton(
                  tooltip: '复制',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _text.text)),
                  icon: const Icon(Icons.copy_rounded),
                ),
                IconButton(
                  tooltip: '重新生成',
                  onPressed: () =>
                      widget.controller.regeneratePrompt(widget.prompt.id),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static List<String> _warnings(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final values = decoded is Map ? decoded['warnings'] : null;
      return values is List ? values.map((item) => '$item').toList() : const [];
    } catch (_) {
      return const [];
    }
  }
}

class _EmptyPrompts extends StatelessWidget {
  const _EmptyPrompts({required this.onGenerate});

  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome_outlined, size: 54),
        const SizedBox(height: 12),
        Text('尚未合成提示词', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('将按已确认镜头顺序生成，并自动加入素材定义、全局风格和整体约束。'),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onGenerate,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('生成全部提示词'),
        ),
      ],
    ),
  );
}

class _StepToolbar extends StatelessWidget {
  const _StepToolbar({
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.all(12),
        child: constraints.maxWidth < 1020
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              )
            : Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ),
      );
    },
  );
}

class _WorkspacePanel extends StatelessWidget {
  const _WorkspacePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerLowest.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
  );
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

class _TextCell extends StatelessWidget {
  const _TextCell(this.value, this.width);

  final String value;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(value, textAlign: TextAlign.center),
    ),
  );
}

class _CommitCell extends StatefulWidget {
  const _CommitCell({
    required this.value,
    required this.width,
    required this.onCommit,
    this.maxLines = 1,
  });

  final String value;
  final double width;
  final int maxLines;
  final ValueChanged<String> onCommit;

  @override
  State<_CommitCell> createState() => _CommitCellState();
}

class _CommitCellState extends State<_CommitCell> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _CommitCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _text.text != widget.value) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: TextField(
        controller: _text,
        minLines: 1,
        maxLines: widget.maxLines,
        textInputAction: TextInputAction.done,
        onEditingComplete: () {
          widget.onCommit(_text.text);
          FocusScope.of(context).unfocus();
        },
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        ),
      ),
    ),
  );
}

class _DurationCommitCell extends StatelessWidget {
  const _DurationCommitCell({
    required this.value,
    required this.width,
    required this.onCommit,
  });

  final double value;
  final double width;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) => _CommitCell(
    value: _durationText(value),
    width: width,
    onCommit: (text) {
      final seconds = _parseDurationSeconds(text);
      if (seconds != null) onCommit(seconds);
    },
  );
}

class _NoScriptState extends StatelessWidget {
  const _NoScriptState({required this.onOpenShootingScript});

  final VoidCallback? onOpenShootingScript;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.description_outlined, size: 58),
        const SizedBox(height: 14),
        Text('还没有可复刻的拍摄脚本', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('先从视频或故事板生成拍摄脚本，再回来确认镜头。'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onOpenShootingScript,
          icon: const Icon(Icons.table_chart_rounded),
          label: const Text('前往拍摄脚本'),
        ),
      ],
    ),
  );
}

class _AssetEditorResult {
  const _AssetEditorResult({
    required this.type,
    required this.name,
    required this.description,
  });

  final ReplicateAssetType type;
  final String name;
  final String description;
}

extension on ReplicateAssetType {
  String get label => switch (this) {
    ReplicateAssetType.character => '人物',
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

  bool get isImageType => switch (this) {
    ReplicateAssetType.character ||
    ReplicateAssetType.product ||
    ReplicateAssetType.scene ||
    ReplicateAssetType.prop ||
    ReplicateAssetType.reference ||
    ReplicateAssetType.other => true,
    ReplicateAssetType.video || ReplicateAssetType.audio => false,
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
