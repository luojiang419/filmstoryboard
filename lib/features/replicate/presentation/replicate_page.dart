import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_availability_cache.dart';
import '../../../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../../../core/widgets/fullscreen_zoom_gallery.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../../core/widgets/value_listenable_selector.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/app_settings.dart';
import '../../story_design/application/story_design_controller.dart';
import '../../storyboard/data/image_generation_service.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/application/script_analysis_controller.dart';
import '../../shooting_script/application/script_asset_binding_controller.dart';
import '../../shooting_script/application/shooting_asset_library_controller.dart';
import '../../shooting_script/domain/shooting_asset_library_models.dart';
import '../../shooting_script/domain/script_asset_slot_policy.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/presentation/video_generation_page.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../application/replicate_controller.dart';
import '../data/seedance_prompt_generation_service.dart';
import '../domain/h3_prompt_style.dart';
import '../domain/quick_replication_input_capacity.dart';
import '../domain/replicate_models.dart';
import 'line_art_color_style_picker.dart';
import 'replicate_pose_editor_dialog.dart';
import 'replicate_shot_navigation_controller.dart';

bool _hasActiveComposing(TextEditingController controller) {
  final composing = controller.value.composing;
  return composing.isValid && !composing.isCollapsed;
}

void _replaceControllerText(TextEditingController controller, String text) {
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}

bool _replicatePageStateChanged(ReplicateState previous, ReplicateState next) {
  return !identical(previous.scripts, next.scripts) ||
      !identical(previous.shots, next.shots) ||
      previous.selectedScriptId != next.selectedScriptId ||
      !identical(previous.run, next.run) ||
      !identical(previous.assets, next.assets) ||
      !identical(previous.replicatedImages, next.replicatedImages) ||
      !identical(previous.prompts, next.prompts) ||
      !identical(previous.shotGuides, next.shotGuides) ||
      !identical(previous.colorStylePresets, next.colorStylePresets) ||
      previous.isBusy != next.isBusy ||
      previous.isAnalyzingFrames != next.isAnalyzingFrames;
}

class ReplicatePage extends ConsumerStatefulWidget {
  const ReplicatePage({
    super.key,
    this.onOpenShootingScript,
    this.onBackToShootingScript,
    this.onManageAssets,
    this.embedded = false,
    this.externalizeStepRightPanel = false,
    this.shotNavigationController,
  });

  final VoidCallback? onOpenShootingScript;
  final VoidCallback? onBackToShootingScript;
  final VoidCallback? onManageAssets;

  /// When true, render only the three-step workflow so the shooting-script
  /// page can own the surrounding page chrome and navigation.
  final bool embedded;
  final bool externalizeStepRightPanel;
  final ReplicateShotNavigationController? shotNavigationController;

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
  static const _colorStyleThumbnailTypes = XTypeGroup(
    label: '色彩预设缩略图',
    extensions: ['png', 'jpg', 'jpeg', 'webp'],
  );

  late final ReplicateController _controller;
  final _localShotNavigationController = ReplicateShotNavigationController();
  final _fileAvailabilityCache = FileAvailabilityCache();
  bool _useBuiltInTemplate = false;
  bool _isOpeningAssetPicker = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(replicateControllerProvider);
  }

  @override
  void dispose() {
    _fileAvailabilityCache.dispose();
    _localShotNavigationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('replicate.page');
    final controller = ref.watch(replicateControllerProvider);
    final analysisController = ref.watch(scriptAnalysisControllerProvider);
    final assetBindingController = ref.watch(
      scriptAssetBindingControllerProvider,
    );
    final assetLibraryController = ref.watch(
      shootingAssetLibraryControllerProvider,
    );
    final settingsController = ref.watch(settingsControllerProvider);
    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ValueListenableSelector<ReplicateState, ReplicateState>(
        valueListenable: controller,
        selector: (state) => state,
        shouldRebuild: _replicatePageStateChanged,
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
          final workflow = _buildWorkflow(
            context,
            state: state,
            controller: controller,
            analysisController: analysisController,
            assetBindingController: assetBindingController,
            assetLibraryController: assetLibraryController,
            run: run,
            settingsController: settingsController,
            externalizeStepRightPanel: widget.externalizeStepRightPanel,
            shotNavigationController:
                widget.shotNavigationController ??
                _localShotNavigationController,
          );
          if (widget.embedded) {
            return workflow;
          }
          return CollapsiblePanelShortcutScope(
            child: Padding(
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
            ),
          );
        },
      ),
    );
  }

  Widget _buildWorkflow(
    BuildContext context, {
    required ReplicateState state,
    required ReplicateController controller,
    required ShootingScriptAnalysisController analysisController,
    required ShootingScriptAssetBindingController assetBindingController,
    required ShootingAssetLibraryController assetLibraryController,
    required ReplicateRun run,
    required SettingsController settingsController,
    required bool externalizeStepRightPanel,
    required ReplicateShotNavigationController shotNavigationController,
  }) {
    final stepContent = _buildStepContent(
      state: state,
      controller: controller,
      analysisController: analysisController,
      assetBindingController: assetBindingController,
      assetLibraryController: assetLibraryController,
      run: run,
      settingsController: settingsController,
      externalizeStepRightPanel: externalizeStepRightPanel,
      shotNavigationController: shotNavigationController,
    );
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
            child: stepContent,
          ),
        ),
      ],
    );
  }

  Widget _buildStepContent({
    required ReplicateState state,
    required ReplicateController controller,
    required ShootingScriptAnalysisController analysisController,
    required ShootingScriptAssetBindingController assetBindingController,
    required ShootingAssetLibraryController assetLibraryController,
    required ReplicateRun run,
    required SettingsController settingsController,
    required bool externalizeStepRightPanel,
    required ReplicateShotNavigationController shotNavigationController,
  }) {
    if (_useBuiltInTemplate) {
      return switch (run.currentStep) {
        ReplicateStep.confirmShots => ValueListenableBuilder<AppSettings>(
          valueListenable: settingsController,
          builder: (context, _, _) => _ConfirmShotsStep(
            key: const ValueKey('replicate-confirm-shots-step'),
            state: state,
            controller: controller,
            settingsController: settingsController,
          ),
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
          key: const ValueKey('replicate-generate-videos-step'),
          scriptId: run.scriptId,
          uiStateKey: widget.embedded
              ? 'shootingScriptVideoGenerationPageUiState'
              : 'replicateVideoGenerationPageUiState',
        ),
      };
    }
    return switch (run.currentStep) {
      ReplicateStep.confirmShots => _NewConfirmShotsStep(
        key: const ValueKey('replicate-new-confirm-shots-step'),
        state: state,
        controller: controller,
        analysisController: analysisController,
        settingsController: settingsController,
        onOpenPrompt: _showPromptPreview,
        externalizeRightPanel: externalizeStepRightPanel,
        shotNavigationController: shotNavigationController,
      ),
      ReplicateStep.prepareAssets =>
        ValueListenableSelector<ScriptAnalysisState, ScriptAnalysisState>(
          valueListenable: analysisController,
          selector: (value) => value,
          builder: (context, analysisState, _) =>
              ValueListenableSelector<
                ScriptAssetBindingState,
                ScriptAssetBindingState
              >(
                valueListenable: assetBindingController,
                selector: (value) => value,
                builder: (context, _, _) =>
                    ValueListenableSelector<
                      ShootingAssetLibraryState,
                      ShootingAssetLibraryState
                    >(
                      valueListenable: assetLibraryController,
                      selector: (value) => value,
                      builder: (context, libraryState, _) =>
                          _NewPrepareAssetsStep(
                            key: const ValueKey(
                              'replicate-new-prepare-assets-step',
                            ),
                            state: state,
                            controller: controller,
                            analysisState: analysisState,
                            assetBindingController: assetBindingController,
                            assetLibraryState: libraryState,
                            onImportLocalAsset: _importSingleAsset,
                            projectRoot: controller.workspaceRoot,
                            onPickColorStyleThumbnail: _pickColorStyleThumbnail,
                            onManageAssets: widget.onManageAssets,
                            externalizeRightPanel: externalizeStepRightPanel,
                          ),
                    ),
              ),
        ),
      ReplicateStep.composePrompts => _NewComposePromptsStep(
        key: const ValueKey('replicate-new-compose-prompts-step'),
        state: state,
        controller: controller,
        onCopyAll: _copyAllPrompts,
        externalizeRightPanel: externalizeStepRightPanel,
      ),
      ReplicateStep.generateVideos => VideoGenerationWorkspace(
        key: const ValueKey('replicate-new-generate-videos-step'),
        scriptId: run.scriptId,
        externalizeWorkPanel: externalizeStepRightPanel,
        uiStateKey: widget.embedded
            ? 'shootingScriptVideoGenerationPageUiState'
            : 'replicateVideoGenerationPageUiState',
      ),
    };
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
      title: '添加参考素材',
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
      return await ref
          .read(desktopFileDialogServiceProvider)
          .openFiles(
            source: 'replicate.pick_assets',
            acceptedTypeGroups: const [_assetTypes],
            initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
          );
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
      return await ref
          .read(desktopFileDialogServiceProvider)
          .openFile(
            source: 'replicate.replace_asset',
            acceptedTypeGroups: const [_assetTypes],
            initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
          );
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

  Future<File?> _pickColorStyleThumbnail() async {
    if (_isOpeningAssetPicker) return null;
    setState(() => _isOpeningAssetPicker = true);
    try {
      if (!mounted) return null;
      final selected = await ref
          .read(desktopFileDialogServiceProvider)
          .openFile(
            source: 'replicate.color_style_thumbnail',
            acceptedTypeGroups: const [_colorStyleThumbnailTypes],
            initialDirectory: ref.read(projectDirectoriesProvider).imports.path,
          );
      return selected == null ? null : File(selected.path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开缩略图选择器失败：$error')));
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
  }) => _showReplicateAssetEditor(
    context,
    title: title,
    initialType: initialType,
    initialName: initialName,
    initialDescription: initialDescription,
    allowTypeChange: allowTypeChange,
    imageTypesOnly: imageTypesOnly,
  );

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

Future<_AssetEditorResult?> _showReplicateAssetEditor(
  BuildContext context, {
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
  final descriptionController = TextEditingController(text: initialDescription);
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

class ReplicateEmbeddedStepRightPanel extends ConsumerStatefulWidget {
  const ReplicateEmbeddedStepRightPanel({
    super.key,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.shotNavigationController,
    this.onManageAssets,
  });

  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final ReplicateShotNavigationController shotNavigationController;
  final VoidCallback? onManageAssets;

  @override
  ConsumerState<ReplicateEmbeddedStepRightPanel> createState() =>
      _ReplicateEmbeddedStepRightPanelState();
}

class _ReplicateEmbeddedStepRightPanelState
    extends ConsumerState<ReplicateEmbeddedStepRightPanel> {
  final _fileAvailabilityCache = FileAvailabilityCache();

  @override
  void dispose() {
    _fileAvailabilityCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('shooting_script.step_right_panel');
    final controller = ref.watch(replicateControllerProvider);
    final assetBindingController = ref.watch(
      scriptAssetBindingControllerProvider,
    );
    final assetLibraryController = ref.watch(
      shootingAssetLibraryControllerProvider,
    );
    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ValueListenableSelector<ReplicateState, ReplicateState>(
        valueListenable: controller,
        selector: (state) => state,
        shouldRebuild: _rightPanelStateChanged,
        builder: (context, state, _) {
          PerformanceProbe.shared.countBuild(
            'shooting_script.step_right_panel.content',
          );
          final run = state.run;
          if (state.scripts.isEmpty || run == null) {
            return const SizedBox.shrink();
          }
          if (widget.collapsed) {
            return _EmbeddedStepPanelFrame(
              child: _CollapsedStepRightPanel(
                label: _externalPanelLabel(run.currentStep),
                expandButtonKey: _externalPanelExpandKey(run.currentStep),
                onExpand: widget.onToggleCollapsed,
              ),
            );
          }
          final panel = switch (run.currentStep) {
            ReplicateStep.confirmShots =>
              run.freeCreationEnabled
                  ? _FreeCreationStoryPanel(
                      controller: controller,
                      onToggleCollapsed: widget.onToggleCollapsed,
                    )
                  : _StoryboardStoryPanel(
                      groups: ScriptShotGroup.group(state.shots),
                      onToggleCollapsed: widget.onToggleCollapsed,
                      onSelectGroup: (group) => widget.shotNavigationController
                          .navigateTo(group.shots.first.id),
                    ),
            ReplicateStep.prepareAssets =>
              ValueListenableSelector<
                ShootingAssetLibraryState,
                ShootingAssetLibraryState
              >(
                valueListenable: assetLibraryController,
                selector: (state) => state,
                shouldRebuild: (previous, next) =>
                    !identical(previous.items, next.items),
                builder: (context, libraryState, _) =>
                    _PrepareAssetLibrarySidePanel(
                      assetLibraryState: libraryState,
                      onManageAssets: widget.onManageAssets,
                      onToggleCollapsed: widget.onToggleCollapsed,
                    ),
              ),
            ReplicateStep.composePrompts => AnimatedBuilder(
              animation: assetBindingController,
              builder: (context, _) => _ComposePromptStatusPanel(
                state: state,
                controller: controller,
                completedReplicaCount: state.replicatedImages
                    .where(
                      (image) =>
                          image.status == ProcessingStatus.completed &&
                          image.generatedFramePath.isNotEmpty,
                    )
                    .length,
                onToggleCollapsed: widget.onToggleCollapsed,
              ),
            ),
            ReplicateStep.generateVideos => VideoGenerationExternalWorkPanel(
              scriptId: run.scriptId,
              collapsed: false,
              onToggleCollapsed: widget.onToggleCollapsed,
            ),
          };
          return _EmbeddedStepPanelFrame(child: panel);
        },
      ),
    );
  }

  static bool _rightPanelStateChanged(
    ReplicateState previous,
    ReplicateState next,
  ) {
    return !identical(previous.scripts, next.scripts) ||
        !identical(previous.shots, next.shots) ||
        !identical(previous.run, next.run) ||
        !identical(previous.prompts, next.prompts) ||
        !identical(previous.replicatedImages, next.replicatedImages) ||
        previous.selectedScriptId != next.selectedScriptId;
  }
}

class _EmbeddedStepPanelFrame extends StatelessWidget {
  const _EmbeddedStepPanelFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final panelColor = scheme.surfaceContainerLow.withValues(alpha: 0.82);
    return DecoratedBox(
      key: const ValueKey('embedded-step-right-panel-frame'),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Theme(
          data: theme.copyWith(
            colorScheme: scheme.copyWith(surface: panelColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

String _externalPanelLabel(ReplicateStep step) => switch (step) {
  ReplicateStep.confirmShots => '分镜故事',
  ReplicateStep.prepareAssets => '资产库',
  ReplicateStep.composePrompts => '提示词状态',
  ReplicateStep.generateVideos => '作品管理',
};

Key _externalPanelExpandKey(ReplicateStep step) => switch (step) {
  ReplicateStep.confirmShots => const ValueKey('expand-confirm-story-panel'),
  ReplicateStep.prepareAssets => const ValueKey(
    'expand-prepare-assets-right-panel',
  ),
  ReplicateStep.composePrompts => const ValueKey(
    'expand-compose-prompts-right-panel',
  ),
  ReplicateStep.generateVideos => const ValueKey(
    'expand-video-generation-work-management-panel',
  ),
};

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
              '确认镜头、准备参考资产，并逐镜生成可直接使用的可灵 / H3 / 即梦提示词。',
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
                title: '准备资产',
                summary:
                    '$readyAssets/${state.assets.length} 已生成、还差${state.assets.length - readyAssets}个',
                status: run.prepareAssetsStatus,
                selected: run.currentStep == ReplicateStep.prepareAssets,
                onTap: () => controller.moveToStep(ReplicateStep.prepareAssets),
              ),
              const _StepConnector(),
              _StepCard(
                number: 2,
                title: '确认镜头',
                summary: '${state.shots.length}个镜头已就绪',
                status: run.confirmShotsStatus,
                selected: run.currentStep == ReplicateStep.confirmShots,
                onTap: () => controller.moveToStep(ReplicateStep.confirmShots),
              ),
              const _StepConnector(),
              _StepCard(
                number: 3,
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
                  '提示词已在确认镜头页生成',
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

class _BuildCameraStyleSelector extends StatelessWidget {
  const _BuildCameraStyleSelector({
    required this.selectedStyle,
    required this.enabled,
    required this.onChanged,
  });

  final H3PromptStyle selectedStyle;
  final bool enabled;
  final Future<void> Function(String styleId) onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 210,
    child: DropdownButtonFormField<String>(
      key: ValueKey('build-camera-style-dropdown-${selectedStyle.id}'),
      initialValue: selectedStyle.id,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        labelText: '本地 H3 Skill 路由偏好',
        prefixIcon: Icon(Icons.movie_filter_outlined),
        border: OutlineInputBorder(),
      ),
      items: [
        for (final style in H3PromptStyle.values)
          DropdownMenuItem(value: style.id, child: Text(style.label)),
      ],
      onChanged: !enabled
          ? null
          : (styleId) async {
              if (styleId != null) await onChanged(styleId);
            },
    ),
  );
}

class _NewConfirmShotsStep extends StatefulWidget {
  const _NewConfirmShotsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.analysisController,
    required this.settingsController,
    required this.onOpenPrompt,
    required this.externalizeRightPanel,
    required this.shotNavigationController,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ShootingScriptAnalysisController analysisController;
  final SettingsController settingsController;
  final ValueChanged<ShotPrompt> onOpenPrompt;
  final bool externalizeRightPanel;
  final ReplicateShotNavigationController shotNavigationController;

  @override
  State<_NewConfirmShotsStep> createState() => _NewConfirmShotsStepState();
}

class _NewConfirmShotsStepState extends State<_NewConfirmShotsStep> {
  bool _showBuiltScript = false;

  @override
  void initState() {
    super.initState();
    _showBuiltScript = _hasBuiltDraft(widget.state);
    widget.shotNavigationController.addListener(_handleNavigationRequest);
  }

  @override
  void didUpdateWidget(covariant _NewConfirmShotsStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.selectedScriptId != widget.state.selectedScriptId) {
      _showBuiltScript = _hasBuiltDraft(widget.state);
    }
    if (oldWidget.shotNavigationController == widget.shotNavigationController) {
      return;
    }
    oldWidget.shotNavigationController.removeListener(_handleNavigationRequest);
    widget.shotNavigationController.addListener(_handleNavigationRequest);
  }

  static bool _hasBuiltDraft(ReplicateState state) => state.prompts.isNotEmpty;

  @override
  void dispose() {
    widget.shotNavigationController.removeListener(_handleNavigationRequest);
    super.dispose();
  }

  void _handleNavigationRequest() {
    if (_showBuiltScript && mounted) {
      setState(() => _showBuiltScript = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('shooting_script.confirm_shots');
    final freeCreationEnabled = widget.state.run?.freeCreationEnabled ?? false;
    final builtShots = ScriptShotGroup.group(widget.state.shots);
    final feedbackShotIds = {
      for (final group in builtShots)
        if (group.shots.first.generationFeedback.trim().isNotEmpty)
          group.shots.first.id,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in widget.state.replicatedImages)
        image.scriptShotId: image,
    };
    final completedReplicaPathByShotId = <String, String>{
      for (final image in widget.state.replicatedImages)
        if (image.status == ProcessingStatus.completed &&
            image.generatedFramePath.isNotEmpty)
          image.scriptShotId: image.generatedFramePath,
    };
    final content = freeCreationEnabled
        ? _FreeCreationShotTable(
            state: widget.state,
            controller: widget.controller,
            showPrompt: _showBuiltScript && widget.state.prompts.isNotEmpty,
            shotNavigationController: widget.shotNavigationController,
            onAnalyze: (group) async {
              final succeeded = await widget.controller
                  .buildFreeCreationPrompts(
                    onlyShotIds: {group.shots.first.id},
                    overwriteUserEdited: true,
                  );
              if (succeeded && mounted) {
                setState(() => _showBuiltScript = true);
              }
            },
            onOpenFrame: (group, showOriginal) => _showScriptFrameGallery(
              context,
              group.shots,
              0,
              showReplica: !showOriginal,
              replicatedByShotId: showOriginal
                  ? const <String, ReplicatedShotImage>{}
                  : replicaByShotId,
            ),
          )
        : _showBuiltScript
        ? _BuiltScriptTable(
            groups: builtShots,
            replicatedByShotId: replicaByShotId,
            onFeedbackChanged:
                widget.analysisController.updateGenerationFeedback,
            onOpenFrames: (group, showReplica) => _showScriptFrameGallery(
              context,
              group.shots,
              0,
              showReplica: showReplica,
              replicatedByShotId: showReplica
                  ? replicaByShotId
                  : const <String, ReplicatedShotImage>{},
            ),
          )
        : _NewShotTable(
            state: widget.state,
            controller: widget.controller,
            confirmed: const <String>{},
            startEndFrameMode: false,
            onOpenPrompt: widget.onOpenPrompt,
            shotNavigationController: widget.shotNavigationController,
            onOpenFrame: (index, showOriginal) => _showScriptFrameGallery(
              context,
              widget.state.shots,
              index,
              showReplica: !showOriginal,
              replicatedByShotId: showOriginal
                  ? const <String, ReplicatedShotImage>{}
                  : replicaByShotId,
            ),
          );
    return _WorkspacePanel(
      child: Column(
        children: [
          ValueListenableSelector<
            ScriptAnalysisState,
            ({bool isBusy, int completedCount, int totalCount})
          >(
            valueListenable: widget.analysisController,
            selector: (state) => (
              isBusy: state.isBusy,
              completedCount: state.completedCount,
              totalCount: state.totalCount,
            ),
            builder: (context, analysis, _) {
              PerformanceProbe.shared.countBuild(
                'shooting_script.confirm_shots.toolbar',
              );
              return _StepToolbar(
                title: '步骤 2 · 确认镜头',
                subtitle: freeCreationEnabled
                    ? _showBuiltScript && widget.state.prompts.isNotEmpty
                          ? '自由创作已按${widget.controller.composePromptModelLabel}独立规则生成 ${builtShots.length} 个提示词，可直接编辑保存。'
                          : '设置镜头范围后可按需填写剧情描述；留空时将自动分析参考图并生成最合适的提示词。'
                    : _showBuiltScript
                    ? !widget.controller.showsH3SkillRoutingPreference
                          ? '已按${widget.controller.composePromptModelLabel}独立规则构建 ${builtShots.length} 个镜头组；可前往步骤 3 生成视频。'
                          : widget.controller.selectedH3PromptStyle.isGeneral
                          ? '已按各镜头剧情自动匹配 Skill 并构建 ${builtShots.length} 个镜头组；提示词已自动拼接，可前往步骤 3 生成视频。'
                          : '已按“${widget.controller.selectedH3PromptStyle.label}”覆盖自动匹配并构建 ${builtShots.length} 个镜头组；提示词已自动拼接，可前往步骤 3 生成视频。'
                    : '先手动设置每个镜头的首帧和结束帧范围；范围内全部图片按顺序合并为一次多图视觉请求，未设置范围的帧各自独立。构建进度 ${analysis.completedCount}/${analysis.totalCount}。',
                actions: [
                  if (widget.controller.showsH3SkillRoutingPreference)
                    _BuildCameraStyleSelector(
                      selectedStyle: widget.controller.selectedH3PromptStyle,
                      enabled: !analysis.isBusy && !widget.state.isBusy,
                      onChanged: (styleId) async {
                        await widget.controller.selectH3PromptStyle(styleId);
                        if (mounted) setState(() => _showBuiltScript = false);
                      },
                    ),
                  FilledButton.icon(
                    key: const ValueKey('script-build-continuous-shots'),
                    onPressed:
                        widget.state.shots.isEmpty ||
                            analysis.isBusy ||
                            widget.state.isBusy
                        ? null
                        : () async {
                            if (freeCreationEnabled) {
                              setState(() => _showBuiltScript = false);
                              widget.controller.clearPromptsBeforeBuild();
                              await widget.controller.composeAllPrompts(
                                navigateToComposeStep: false,
                              );
                              if (mounted) {
                                setState(() => _showBuiltScript = true);
                              }
                              return;
                            }
                            final feedbackRebuild =
                                _showBuiltScript && feedbackShotIds.isNotEmpty;
                            if (_showBuiltScript && !feedbackRebuild) {
                              setState(() => _showBuiltScript = false);
                              return;
                            }
                            setState(() => _showBuiltScript = false);
                            widget.controller.clearPromptsBeforeBuild();
                            final analysisController =
                                widget.analysisController;
                            final replicateController = widget.controller;
                            final buildCompleted = await analysisController
                                .buildScript(
                                  imagePathOverrides:
                                      completedReplicaPathByShotId,
                                  onlyFeedbackGroups: feedbackRebuild,
                                );
                            if (buildCompleted) {
                              if (feedbackRebuild) {
                                await replicateController
                                    .composePromptsForShotIds(feedbackShotIds);
                              } else {
                                await replicateController.composeAllPrompts(
                                  navigateToComposeStep: false,
                                );
                              }
                            }
                            if (mounted) {
                              setState(() => _showBuiltScript = true);
                            }
                          },
                    icon: Icon(
                      _showBuiltScript
                          ? feedbackShotIds.isNotEmpty
                                ? Icons.replay_rounded
                                : Icons.edit_note_rounded
                          : Icons.account_tree_rounded,
                    ),
                    label: Text(
                      analysis.isBusy
                          ? '构建中…'
                          : widget.state.isBusy
                          ? '拼接提示词中…'
                          : freeCreationEnabled && _showBuiltScript
                          ? '重新构建'
                          : _showBuiltScript
                          ? feedbackShotIds.isNotEmpty
                                ? '根据反馈重构'
                                : '返回编辑'
                          : '构建脚本',
                    ),
                  ),
                  if (analysis.isBusy)
                    OutlinedButton.icon(
                      onPressed: widget.analysisController.cancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('取消构建'),
                    ),
                  FilledButton.icon(
                    key: const ValueKey('replicate-new-next-videos'),
                    onPressed: widget.state.shots.isEmpty
                        ? null
                        : () => widget.controller.moveToStep(
                            ReplicateStep.generateVideos,
                          ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('下一步'),
                  ),
                ],
              );
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.externalizeRightPanel
                ? content
                : _ResizableStepRightPanel(
                    uiStateKey: 'shootingScriptStepPanelCollapsed',
                    resizeHandleKey: const ValueKey(
                      'confirm-story-panel-resize-handle',
                    ),
                    expandButtonKey: const ValueKey(
                      'expand-confirm-story-panel',
                    ),
                    collapsedLabel: '分镜故事',
                    defaultWidth: 330,
                    compactBreakpoint: 980,
                    compactHeight: 210,
                    content: content,
                    panelBuilder: (context, onToggleCollapsed) =>
                        freeCreationEnabled
                        ? _FreeCreationStoryPanel(
                            controller: widget.controller,
                            onToggleCollapsed: onToggleCollapsed,
                          )
                        : _StoryboardStoryPanel(
                            groups: builtShots,
                            onToggleCollapsed: onToggleCollapsed,
                            onSelectGroup: (group) => widget
                                .shotNavigationController
                                .navigateTo(group.shots.first.id),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StoryboardStoryPanel extends StatelessWidget {
  const _StoryboardStoryPanel({
    required this.groups,
    required this.onToggleCollapsed,
    required this.onSelectGroup,
  });

  final List<ScriptShotGroup> groups;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<ScriptShotGroup> onSelectGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      key: const ValueKey('confirm-story-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Row(
              children: [
                Icon(
                  Icons.subject_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '分镜故事',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${groups.length}组',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  key: const ValueKey('collapse-confirm-story-panel'),
                  tooltip: '折叠分镜故事',
                  onPressed: onToggleCollapsed,
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('构建脚本后将在这里核对全局故事'))
                : ListView(
                    key: const ValueKey('confirm-story-list'),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                    children: [
                      Text(
                        ScriptShotGroup.globalStoryText(groups),
                        key: const ValueKey('confirm-story-global-summary'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 14),
                      for (var index = 0; index < groups.length; index++) ...[
                        _StoryGroupSummary(
                          group: groups[index],
                          onTap: () => onSelectGroup(groups[index]),
                        ),
                        if (index < groups.length - 1)
                          Divider(
                            key: ValueKey('confirm-story-divider-$index'),
                            height: 15,
                            thickness: 1,
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.72,
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FreeCreationStoryPanel extends StatefulWidget {
  const _FreeCreationStoryPanel({
    required this.controller,
    required this.onToggleCollapsed,
  });

  final ReplicateController controller;
  final VoidCallback onToggleCollapsed;

  @override
  State<_FreeCreationStoryPanel> createState() =>
      _FreeCreationStoryPanelState();
}

class _FreeCreationStoryPanelState extends State<_FreeCreationStoryPanel> {
  static const _saveDelay = Duration(milliseconds: 450);

  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  late String _lastSavedText;
  late String _lastObservedText;
  Timer? _saveTimer;
  bool _wasComposing = false;
  bool _synchronizing = false;

  @override
  void initState() {
    super.initState();
    _lastSavedText =
        widget.controller.value.run?.freeCreationStoryOverride ?? '';
    _lastObservedText = _lastSavedText;
    _textController = TextEditingController(text: _lastSavedText)
      ..addListener(_handleEditingValueChanged);
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _FreeCreationStoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stored = widget.controller.value.run?.freeCreationStoryOverride ?? '';
    if (stored == _textController.text) {
      _lastSavedText = stored;
      return;
    }
    if (_focusNode.hasFocus || _isComposing) return;
    if (_textController.text == _lastSavedText) {
      _lastSavedText = stored;
      _replaceLocalText(stored);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _textController
      ..removeListener(_handleEditingValueChanged)
      ..dispose();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  bool get _isComposing {
    final composing = _textController.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _handleEditingValueChanged() {
    if (_synchronizing) return;
    final text = _textController.text;
    final composing = _isComposing;
    final compositionEnded = _wasComposing && !composing;
    final textChanged = text != _lastObservedText;
    _lastObservedText = text;
    _wasComposing = composing;
    if (composing) {
      _saveTimer?.cancel();
      _saveTimer = null;
      return;
    }
    if (text == _lastSavedText) {
      _saveTimer?.cancel();
      _saveTimer = null;
      return;
    }
    if (textChanged || compositionEnded) _scheduleCommit();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) return;
    final stored = widget.controller.value.run?.freeCreationStoryOverride ?? '';
    _commit(force: _textController.text != stored);
  }

  void _scheduleCommit() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _commit);
  }

  void _commit({bool force = false}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_isComposing) {
      _scheduleCommit();
      return;
    }
    final text = _textController.text;
    if (!force && text == _lastSavedText) return;
    _lastSavedText = text;
    widget.controller.updateFreeCreationStoryOverride(text);
  }

  void _replaceLocalText(String text) {
    _synchronizing = true;
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _lastObservedText = text;
    _wasComposing = false;
    _synchronizing = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final automaticStory = widget.controller.automaticFreeCreationStory;
    final hasOverride =
        (widget.controller.value.run?.freeCreationStoryOverride ?? '')
            .trim()
            .isNotEmpty;
    return ColoredBox(
      key: const ValueKey('confirm-story-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Row(
              children: [
                Icon(
                  Icons.subject_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '分镜故事',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('collapse-confirm-story-panel'),
                  tooltip: '折叠分镜故事',
                  onPressed: widget.onToggleCollapsed,
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                TextField(
                  key: const ValueKey('free-creation-story-override-field'),
                  controller: _textController,
                  focusNode: _focusNode,
                  minLines: 8,
                  maxLines: 18,
                  onTapOutside: (_) {
                    _commit();
                    _focusNode.unfocus();
                  },
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    labelText: '全局分镜故事（可编辑）',
                    hintText: automaticStory.isEmpty
                        ? '尚无故事板自动解析摘要，可在此手动输入'
                        : automaticStory,
                    helperText: hasOverride
                        ? '当前使用手动故事；清空后恢复自动摘要'
                        : automaticStory.isEmpty
                        ? '当前无可用自动摘要'
                        : '当前使用关联故事板自动摘要',
                  ),
                ),
                if (!hasOverride && automaticStory.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    automaticStory,
                    key: const ValueKey(
                      'free-creation-effective-story-preview',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryGroupSummary extends StatelessWidget {
  const _StoryGroupSummary({required this.group, required this.onTap});

  final ScriptShotGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return KeyedSubtree(
      key: ValueKey(
        'confirm-story-group-${group.startNumber}-${group.endNumber}',
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${group.rangeLabel} · ${_durationText(group.durationSeconds)}',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey(
                  'confirm-story-description-${group.startNumber}-${group.endNumber}',
                ),
                onTap: onTap,
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    group.storyText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              [
                if (group.sceneText.isNotEmpty) '场景：${group.sceneText}',
                if (group.focusText.isNotEmpty) '焦点：${group.focusText}',
                '运镜：${group.cameraMovement}',
              ].join('  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BuiltScriptTable extends StatelessWidget {
  const _BuiltScriptTable({
    required this.groups,
    required this.replicatedByShotId,
    required this.onFeedbackChanged,
    required this.onOpenFrames,
  });

  static const rowHeight = 180.0;

  final List<ScriptShotGroup> groups;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final void Function(String shotId, String feedback) onFeedbackChanged;
  final void Function(ScriptShotGroup group, bool showReplica) onOpenFrames;

  @override
  Widget build(BuildContext context) {
    const columns = [
      _BuiltScriptColumn('镜头', 94),
      _BuiltScriptColumn('原视频帧范围', 300),
      _BuiltScriptColumn('复刻分镜范围', 300),
      _BuiltScriptColumn('时长', 76),
      _BuiltScriptColumn('画面描述', 440),
      _BuiltScriptColumn('生成反馈', 360),
      _BuiltScriptColumn('导演运镜', 420),
      _BuiltScriptColumn('构图 / 机位', 340),
      _BuiltScriptColumn('焦点 / 衔接', 340),
      _BuiltScriptColumn('摄影备注', 380),
    ];
    final tableWidth = columns.fold<double>(
      0,
      (total, column) => total + column.width,
    );
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: tableWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      for (final column in columns)
                        _BuiltScriptGridCell(
                          width: column.width,
                          height: 44,
                          child: Center(
                            child: Text(
                              column.label,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: groups.isEmpty
                      ? const Center(child: Text('当前脚本暂无镜头'))
                      : ListView.builder(
                          itemCount: groups.length,
                          itemBuilder: (context, index) {
                            final group = groups[index];
                            return _BuiltScriptTableRow(
                              key: ValueKey(
                                'built-shot-group-row-${group.startNumber}-${group.endNumber}',
                              ),
                              group: group,
                              index: index,
                              replicatedByShotId: replicatedByShotId,
                              onFeedbackChanged: onFeedbackChanged,
                              onOpenFrames: onOpenFrames,
                            );
                          },
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

class _BuiltScriptColumn {
  const _BuiltScriptColumn(this.label, this.width);

  final String label;
  final double width;
}

class _BuiltScriptTableRow extends StatelessWidget {
  const _BuiltScriptTableRow({
    super.key,
    required this.group,
    required this.index,
    required this.replicatedByShotId,
    required this.onFeedbackChanged,
    required this.onOpenFrames,
  });

  final ScriptShotGroup group;
  final int index;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final void Function(String shotId, String feedback) onFeedbackChanged;
  final void Function(ScriptShotGroup group, bool showReplica) onOpenFrames;

  @override
  Widget build(BuildContext context) {
    final color = index.isEven
        ? Theme.of(
            context,
          ).colorScheme.surfaceContainerLow.withValues(alpha: 0.45)
        : Colors.transparent;
    return Material(
      color: color,
      child: SizedBox(
        height: _BuiltScriptTable.rowHeight,
        child: Row(
          children: [
            _BuiltScriptGridCell(
              width: 94,
              child: Center(
                child: Text(
                  group.rangeLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ),
            _BuiltFrameRangeCell(
              group: group,
              width: 300,
              label: '原视频帧 ${group.frameRangeLabel}',
              showReplica: false,
              replicatedByShotId: replicatedByShotId,
              onOpen: () => onOpenFrames(group, false),
            ),
            _BuiltFrameRangeCell(
              group: group,
              width: 300,
              label: '复刻分镜 ${group.frameRangeLabel}',
              showReplica: true,
              replicatedByShotId: replicatedByShotId,
              onOpen: () => onOpenFrames(group, true),
            ),
            _BuiltScriptGridCell(
              width: 76,
              child: Center(child: Text(_durationText(group.durationSeconds))),
            ),
            _BuiltScriptGridCell(
              width: 440,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  group.scriptText.isEmpty ? '暂无画面描述' : group.scriptText,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _BuiltScriptGridCell(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _GenerationFeedbackField(
                  key: ValueKey('generation-feedback-${group.shots.first.id}'),
                  feedback: group.shots.first.generationFeedback,
                  onChanged: (feedback) =>
                      onFeedbackChanged(group.shots.first.id, feedback),
                ),
              ),
            ),
            _BuiltScriptGridCell(
              width: 420,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  group.cameraDesignText.isEmpty
                      ? group.cameraMovement
                      : group.cameraDesignText,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _BuiltScriptGridCell(
              width: 340,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  group.compositionAndAngleText.isEmpty
                      ? '待补充'
                      : group.compositionAndAngleText,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _BuiltScriptGridCell(
              width: 340,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  group.focusAndTransitionText.isEmpty
                      ? '待补充'
                      : group.focusAndTransitionText,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _BuiltScriptGridCell(
              width: 380,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  group.cameraNotesText.isEmpty ? '待补充' : group.cameraNotesText,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GenerationFeedbackField extends StatefulWidget {
  const _GenerationFeedbackField({
    super.key,
    required this.feedback,
    required this.onChanged,
  });

  final String feedback;
  final ValueChanged<String> onChanged;

  @override
  State<_GenerationFeedbackField> createState() =>
      _GenerationFeedbackFieldState();
}

class _GenerationFeedbackFieldState extends State<_GenerationFeedbackField> {
  static const _saveDelay = Duration(milliseconds: 450);

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _lastSavedFeedback;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _lastSavedFeedback = widget.feedback;
    _controller = TextEditingController(text: widget.feedback);
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _GenerationFeedbackField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text == widget.feedback) {
      _lastSavedFeedback = widget.feedback;
      return;
    }
    if ((_focusNode.hasFocus || _hasActiveComposing(_controller)) &&
        _controller.text != _lastSavedFeedback) {
      return;
    }
    _saveTimer?.cancel();
    _lastSavedFeedback = widget.feedback;
    _replaceControllerText(_controller, widget.feedback);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) return;
    _commit(force: _controller.text != widget.feedback);
  }

  void _scheduleCommit(String _) {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _commit);
  }

  void _commit({bool force = false}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    final feedback = _controller.text;
    if (!force && feedback == _lastSavedFeedback) return;
    _lastSavedFeedback = feedback;
    widget.onChanged(feedback);
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: _controller,
    focusNode: _focusNode,
    minLines: 4,
    maxLines: 7,
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      alignLabelWithHint: true,
      hintText: '例如：去掉慢动作，人物表情更自然',
    ),
    onChanged: _scheduleCommit,
  );
}

class _BuiltFrameRangeCell extends StatelessWidget {
  const _BuiltFrameRangeCell({
    required this.group,
    required this.width,
    required this.label,
    required this.showReplica,
    required this.replicatedByShotId,
    required this.onOpen,
  });

  final ScriptShotGroup group;
  final double width;
  final String label;
  final bool showReplica;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final shots = group.shots.take(3).toList(growable: false);
    final keyPrefix = showReplica ? 'replica' : 'original';
    return _BuiltScriptGridCell(
      width: width,
      child: Tooltip(
        message: '$label，点击全屏浏览',
        child: InkWell(
          key: ValueKey(
            'built-shot-$keyPrefix-range-${group.startNumber}-${group.endNumber}',
          ),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                for (final shot in shots)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _BuiltFrameThumbnail(
                        path: _framePathForBuiltRange(
                          shot,
                          showReplica,
                          replicatedByShotId,
                        ),
                        label: shot.shotNumber.toString(),
                      ),
                    ),
                  ),
                if (group.shots.length > shots.length)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('+${group.shots.length - shots.length}'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _framePathForBuiltRange(
  ScriptShot shot,
  bool showReplica,
  Map<String, ReplicatedShotImage> replicatedByShotId,
) {
  if (!showReplica) return shot.framePath;
  final path = replicatedByShotId[shot.id]?.generatedFramePath ?? '';
  return path.trim().isEmpty ? '' : path;
}

bool _fileExists(BuildContext context, String path) =>
    FileAvailabilityScope.of(context).exists(path);

class _BuiltFrameThumbnail extends StatelessWidget {
  const _BuiltFrameThumbnail({required this.path, required this.label});

  final String path;
  final String label;

  @override
  Widget build(BuildContext context) {
    final exists = _fileExists(context, path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: exists
                ? PreviewFileImage(path: path, fit: BoxFit.contain)
                : Icon(
                    Icons.image_not_supported_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ),
          Positioned(
            left: 3,
            bottom: 3,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                shadows: [Shadow(color: Colors.black, blurRadius: 3)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BuiltScriptGridCell extends StatelessWidget {
  const _BuiltScriptGridCell({
    required this.width,
    required this.child,
    this.height = _BuiltScriptTable.rowHeight,
  });

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
          bottom: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
      child: child,
    ),
  );
}

class _NewComposePromptsStep extends StatelessWidget {
  const _NewComposePromptsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.onCopyAll,
    required this.externalizeRightPanel,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ValueChanged<ReplicateState> onCopyAll;
  final bool externalizeRightPanel;

  @override
  Widget build(BuildContext context) {
    final structuredReadyCount = controller.structuredPromptContextReadyCount;
    final usesOfficialH3 = controller.usesOfficialH3PromptWriting;
    final completedReplicaIds = {
      for (final image in state.replicatedImages)
        if (image.status == ProcessingStatus.completed &&
            image.generatedFramePath.isNotEmpty)
          image.scriptShotId,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in state.replicatedImages) image.scriptShotId: image,
    };
    final canCompose = state.confirmedShots.isNotEmpty && !state.isBusy;
    final content = _ComposePromptTable(
      state: state,
      controller: controller,
      replicatedByShotId: replicaByShotId,
    );
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 3 · 合成提示词',
            subtitle:
                '复刻分镜 ${completedReplicaIds.length}/${state.confirmedShots.length} · 构建阶段结构化解析 $structuredReadyCount/${state.confirmedShots.length} · '
                '合成阶段视觉模型 0 次 · ${usesOfficialH3 ? 'H3 格式 · 本地字段拼接' : '本地结构化拼接'}',
            actions: [
              FilledButton.icon(
                key: const ValueKey('new-compose-all-seedance-prompts'),
                onPressed: canCompose ? controller.composeAllPrompts : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  state.prompts.isEmpty
                      ? usesOfficialH3
                            ? '拼接全部 H3 提示词'
                            : '本地拼接全部'
                      : usesOfficialH3
                      ? '重新拼接 H3 提示词'
                      : '重新本地拼接',
                ),
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
            child: externalizeRightPanel
                ? content
                : _ResizableStepRightPanel(
                    uiStateKey: 'shootingScriptStepPanelCollapsed',
                    resizeHandleKey: const ValueKey(
                      'compose-prompts-right-panel-resize-handle',
                    ),
                    expandButtonKey: const ValueKey(
                      'expand-compose-prompts-right-panel',
                    ),
                    collapsedLabel: '提示词状态',
                    defaultWidth: 320,
                    minPanelWidth: 260,
                    compactBreakpoint: 1040,
                    compactHeight: 220,
                    content: content,
                    panelBuilder: (context, onToggleCollapsed) =>
                        _ComposePromptStatusPanel(
                          state: state,
                          controller: controller,
                          completedReplicaCount: completedReplicaIds.length,
                          onToggleCollapsed: onToggleCollapsed,
                        ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ComposePromptStatusPanel extends StatelessWidget {
  const _ComposePromptStatusPanel({
    required this.state,
    required this.controller,
    required this.completedReplicaCount,
    required this.onToggleCollapsed,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final int completedReplicaCount;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = state.prompts
        .where((item) => item.status == ProcessingStatus.completed)
        .length;
    final failed = state.prompts
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    final running = state.prompts
        .where(
          (item) =>
              item.status == ProcessingStatus.running ||
              item.status == ProcessingStatus.retrying,
        )
        .length;
    final pending = math.max(0, state.confirmedShots.length - completed);
    return ColoredBox(
      key: const ValueKey('compose-prompts-right-status-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Row(
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '提示词状态',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '$completed/${state.confirmedShots.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  key: const ValueKey('collapse-compose-prompts-right-panel'),
                  tooltip: '折叠提示词状态',
                  onPressed: onToggleCollapsed,
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
              children: [
                _ComposeStatusMetricGrid(
                  completedReplicaCount: completedReplicaCount,
                  confirmedShotCount: state.confirmedShots.length,
                  completedPromptCount: completed,
                  failedPromptCount: failed,
                  runningPromptCount: running,
                  pendingPromptCount: pending,
                ),
                const SizedBox(height: 12),
                _ComposePromptSettingSummary(
                  modelLabel: controller.composePromptModelLabel,
                  usesOfficialH3: controller.usesOfficialH3PromptWriting,
                  startEndFrameMode: false,
                  structuredReadyCount:
                      controller.structuredPromptContextReadyCount,
                  structuredTotalCount: ScriptShotGroup.group(
                    state.confirmedShots,
                  ).length,
                ),
                if (controller.showsH3SkillRoutingPreference) ...[
                  const SizedBox(height: 12),
                  _H3PromptStyleSelector(
                    selectedStyle: controller.selectedH3PromptStyle,
                  ),
                ],
                if (failed > 0) ...[
                  const SizedBox(height: 12),
                  _FailedPromptSummary(prompts: state.prompts),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposeStatusMetricGrid extends StatelessWidget {
  const _ComposeStatusMetricGrid({
    required this.completedReplicaCount,
    required this.confirmedShotCount,
    required this.completedPromptCount,
    required this.failedPromptCount,
    required this.runningPromptCount,
    required this.pendingPromptCount,
  });

  final int completedReplicaCount;
  final int confirmedShotCount;
  final int completedPromptCount;
  final int failedPromptCount;
  final int runningPromptCount;
  final int pendingPromptCount;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _ComposeStatusMetric(
        label: '复刻分镜',
        value: '$completedReplicaCount/$confirmedShotCount',
      ),
      _ComposeStatusMetric(label: '已完成', value: '$completedPromptCount'),
      _ComposeStatusMetric(label: '合成中', value: '$runningPromptCount'),
      _ComposeStatusMetric(label: '待处理', value: '$pendingPromptCount'),
      _ComposeStatusMetric(label: '失败', value: '$failedPromptCount'),
    ],
  );
}

class _ComposeStatusMetric extends StatelessWidget {
  const _ComposeStatusMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 118,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposePromptSettingSummary extends StatelessWidget {
  const _ComposePromptSettingSummary({
    required this.modelLabel,
    required this.usesOfficialH3,
    required this.startEndFrameMode,
    required this.structuredReadyCount,
    required this.structuredTotalCount,
  });

  final String modelLabel;
  final bool usesOfficialH3;
  final bool startEndFrameMode;
  final int structuredReadyCount;
  final int structuredTotalCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missingCount = structuredTotalCount - structuredReadyCount;
    return DecoratedBox(
      key: const ValueKey('local-prompt-compiler-summary'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '合成配置',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text('输出格式：$modelLabel', style: theme.textTheme.bodySmall),
            Text(
              usesOfficialH3 ? '执行方式：H3 格式本地字段拼接' : '执行方式：本地结构化拼接',
              style: theme.textTheme.bodySmall,
            ),
            Text('合成阶段视觉模型调用：0 次', style: theme.textTheme.bodySmall),
            Text(
              '结构化解析：$structuredReadyCount/$structuredTotalCount',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              startEndFrameMode ? '首尾帧提示词' : '单帧提示词',
              style: theme.textTheme.bodySmall,
            ),
            if (missingCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '有 $missingCount 个镜头缺少新版结构化解析，将使用现有脚本字段本地合成；如需更完整细节，可返回脚本解析页重新解析。',
                key: const ValueKey(
                  'structured-prompt-context-fallback-notice',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _H3PromptStyleSelector extends StatelessWidget {
  const _H3PromptStyleSelector({required this.selectedStyle});

  final H3PromptStyle selectedStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('selected-build-camera-style-summary'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '构建镜头风格',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              selectedStyle.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              selectedStyle.description,
              key: const ValueKey('h3-prompt-style-description'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '规则来源：MiniMax-H3 / ${selectedStyle.officialSkillPath}',
              key: const ValueKey('h3-prompt-style-source'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              selectedStyle.isGeneral
                  ? '仅当设置页选中本地 MiniMax H3 时，系统才会按每个镜头的剧情描述自动加载至多一个中文专项 Skill；未命中时只使用通用 H3。其他视频模型不会显示或执行此路由。'
                  : '这是本地 MiniMax H3 的手动覆盖项：构建时固定读取该中文专项 Skill，不再按剧情自动判断；其他视频模型不会显示或执行此路由。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailedPromptSummary extends StatelessWidget {
  const _FailedPromptSummary({required this.prompts});

  final List<ShotPrompt> prompts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failedPrompts = prompts
        .where((item) => item.status == ProcessingStatus.failed)
        .take(4)
        .toList(growable: false);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '失败镜头',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            for (final prompt in failedPrompts)
              Text(
                '镜头 ${prompt.shotNumber}：${prompt.errorMessage.isEmpty ? '待重试' : prompt.errorMessage}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _ComposePromptTable extends StatelessWidget {
  const _ComposePromptTable({
    required this.state,
    required this.controller,
    required this.replicatedByShotId,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final Map<String, ReplicatedShotImage> replicatedByShotId;

  @override
  Widget build(BuildContext context) {
    final prompts = {
      for (final prompt in state.prompts)
        if (prompt.scriptShotId != null) prompt.scriptShotId!: prompt,
    };
    final shots = [...state.confirmedShots]
      ..sort((first, second) => first.shotNumber.compareTo(second.shotNumber));
    final groups = ScriptShotGroup.group(shots);
    return Scrollbar(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1180,
            child: Table(
              key: const ValueKey('compose-prompt-three-column-table'),
              border: TableBorder.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              columnWidths: const {
                0: FixedColumnWidth(300),
                1: FixedColumnWidth(300),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                const TableRow(
                  children: [
                    _ComposeTableHeaderCell('原视频帧'),
                    _ComposeTableHeaderCell('复刻分镜图'),
                    _ComposeTableHeaderCell('生成提示词'),
                  ],
                ),
                for (final group in groups)
                  _composePromptRow(
                    group: group,
                    prompt: prompts[group.shots.first.id],
                    replicatedByShotId: replicatedByShotId,
                    controller: controller,
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
  required ScriptShotGroup group,
  required ShotPrompt? prompt,
  required Map<String, ReplicatedShotImage> replicatedByShotId,
  required ReplicateController controller,
}) {
  return TableRow(
    children: [
      _ComposeGroupFrameCell(
        group: group,
        keyPrefix: 'original',
        emptyLabel: '原视频帧暂不可用',
        filePathForShot: (shot) => shot.framePath,
        onOpen: (context) => _showScriptFrameGallery(context, group.shots, 0),
      ),
      _ComposeGroupFrameCell(
        group: group,
        keyPrefix: 'replica',
        emptyLabel: '待复刻分镜',
        filePathForShot: (shot) =>
            replicatedByShotId[shot.id]?.generatedFramePath ?? '',
        onOpen: (context) => _showScriptFrameGallery(
          context,
          group.shots,
          0,
          showReplica: true,
          replicatedByShotId: replicatedByShotId,
        ),
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

class _ComposeGroupFrameCell extends StatelessWidget {
  const _ComposeGroupFrameCell({
    required this.group,
    required this.keyPrefix,
    required this.emptyLabel,
    required this.filePathForShot,
    required this.onOpen,
  });

  final ScriptShotGroup group;
  final String keyPrefix;
  final String emptyLabel;
  final String Function(ScriptShot shot) filePathForShot;
  final void Function(BuildContext context) onOpen;

  @override
  Widget build(BuildContext context) {
    final shots = group.shots.take(3).toList(growable: false);
    final hasAnyFile = group.shots.any(_hasFileForShot);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.rangeLabel,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: '${group.rangeLabel} · $emptyLabel',
            child: InkWell(
              key: ValueKey(
                'compose-prompt-$keyPrefix-range-${group.startNumber}-${group.endNumber}',
              ),
              onTap: hasAnyFile ? () => onOpen(context) : null,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 150,
                child: Row(
                  children: [
                    for (final shot in shots)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: _ComposeGroupFrameThumbnail(
                            path: filePathForShot(shot),
                            label: shot.shotNumber.toString(),
                            emptyLabel: emptyLabel,
                          ),
                        ),
                      ),
                    if (group.shots.length > shots.length)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text('+${group.shots.length - shots.length}'),
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

  bool _hasFileForShot(ScriptShot shot) {
    final path = filePathForShot(shot).trim();
    return path.isNotEmpty;
  }
}

class _ComposeGroupFrameThumbnail extends StatelessWidget {
  const _ComposeGroupFrameThumbnail({
    required this.path,
    required this.label,
    required this.emptyLabel,
  });

  final String path;
  final String label;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasFile = _fileExists(context, path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: hasFile
                ? Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        Center(child: Text('$emptyLabel加载失败')),
                  )
                : Center(
                    child: Text(
                      emptyLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
          ),
          Positioned(
            left: 5,
            bottom: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.66),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
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
                      value: ShotPromptFormat.kling,
                      label: Text('可灵'),
                    ),
                    ButtonSegment(
                      value: ShotPromptFormat.h3,
                      label: Text('H3'),
                    ),
                    ButtonSegment(
                      value: ShotPromptFormat.sd2,
                      label: Text('即梦'),
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

class _FreeCreationShotTable extends StatefulWidget {
  const _FreeCreationShotTable({
    required this.state,
    required this.controller,
    required this.showPrompt,
    required this.shotNavigationController,
    required this.onAnalyze,
    required this.onOpenFrame,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final bool showPrompt;
  final ReplicateShotNavigationController shotNavigationController;
  final Future<void> Function(ScriptShotGroup group) onAnalyze;
  final void Function(ScriptShotGroup group, bool showOriginal) onOpenFrame;

  @override
  State<_FreeCreationShotTable> createState() => _FreeCreationShotTableState();
}

class _FreeCreationShotTableState extends State<_FreeCreationShotTable> {
  static const _shotNumberWidth = 84.0;
  static const _originalWidth = 250.0;
  static const _replicaWidth = 250.0;
  static const _descriptionWidth = 430.0;
  static const _promptWidth = 620.0;
  static const _actionWidth = 112.0;

  final _horizontalController = ScrollController();
  final _verticalController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.shotNavigationController.addListener(_navigateToRequestedShot);
  }

  @override
  void didUpdateWidget(covariant _FreeCreationShotTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shotNavigationController == widget.shotNavigationController) {
      return;
    }
    oldWidget.shotNavigationController.removeListener(_navigateToRequestedShot);
    widget.shotNavigationController.addListener(_navigateToRequestedShot);
  }

  @override
  void dispose() {
    widget.shotNavigationController.removeListener(_navigateToRequestedShot);
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  void _navigateToRequestedShot() {
    final shotId = widget.shotNavigationController.requestedShotId;
    if (!mounted || shotId == null) return;
    if (!_verticalController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _navigateToRequestedShot(),
      );
      return;
    }
    final groups = ScriptShotGroup.group(widget.state.shots);
    final index = groups.indexWhere(
      (group) => group.shots.any((shot) => shot.id == shotId),
    );
    if (index < 0) return;
    _verticalController.animateTo(
      (index * _NewShotTable.rowHeight).clamp(
        0.0,
        _verticalController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = ScriptShotGroup.group(widget.state.shots);
    final replicatedByShotId = <String, ReplicatedShotImage>{
      for (final image in widget.state.replicatedImages)
        image.scriptShotId: image,
    };
    final promptByShotId = <String, ShotPrompt>{
      for (final prompt in widget.state.prompts)
        if (prompt.scriptShotId != null) prompt.scriptShotId!: prompt,
    };
    final totalWidth =
        _shotNumberWidth +
        _originalWidth +
        _replicaWidth +
        _descriptionWidth +
        (widget.showPrompt ? _promptWidth : 0) +
        _actionWidth;
    final table = SizedBox(
      width: totalWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          children: [
            Row(
              key: const ValueKey('free-creation-table-header'),
              children: [
                const _FreeCreationHeaderCell(
                  label: '镜号',
                  width: _shotNumberWidth,
                ),
                const _FreeCreationHeaderCell(
                  label: '原视频帧范围',
                  width: _originalWidth,
                ),
                const _FreeCreationHeaderCell(
                  label: '复刻分镜范围',
                  width: _replicaWidth,
                ),
                const _FreeCreationHeaderCell(
                  label: '剧情描述',
                  width: _descriptionWidth,
                ),
                if (widget.showPrompt)
                  _FreeCreationPromptHeaderCell(
                    width: _promptWidth,
                    prompts: widget.state.prompts,
                    controller: widget.controller,
                  ),
                const _FreeCreationHeaderCell(
                  label: '功能菜单',
                  width: _actionWidth,
                ),
              ],
            ),
            Expanded(
              child: groups.isEmpty
                  ? const Center(child: Text('当前脚本暂无镜头'))
                  : Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ReorderableListView.builder(
                        scrollController: _verticalController,
                        buildDefaultDragHandles: false,
                        itemCount: groups.length,
                        onReorder: widget.controller.reorderShotGroups,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          final head = group.shots.first;
                          return _FreeCreationShotRow(
                            key: ValueKey('free-creation-row-${head.id}'),
                            index: index,
                            group: group,
                            head: head,
                            controller: widget.controller,
                            replicatedByShotId: replicatedByShotId,
                            prompt: promptByShotId[head.id],
                            showPrompt: widget.showPrompt,
                            shotNumberWidth: _shotNumberWidth,
                            originalWidth: _originalWidth,
                            replicaWidth: _replicaWidth,
                            descriptionWidth: _descriptionWidth,
                            promptWidth: _promptWidth,
                            actionWidth: _actionWidth,
                            actionsEnabled: !widget.state.isBusy,
                            onOpenFrame: widget.onOpenFrame,
                            onAnalyze: () => widget.onAnalyze(group),
                            onRemove: () => _confirmRemoveGroup(group),
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
      child: SingleChildScrollView(
        controller: _horizontalController,
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    );
  }

  Future<void> _confirmRemoveGroup(ScriptShotGroup group) async {
    final frameCount = group.shots.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除镜头条目？'),
        content: Text(
          frameCount == 1
              ? '将从当前拍摄脚本中移除该镜头，关联提示词和复刻记录也会移除。已生成的本地文件不会删除。'
              : '将从当前拍摄脚本中移除该镜头组的 $frameCount 帧，关联提示词和复刻记录也会移除。已生成的本地文件不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-free-creation-shot-group'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      widget.controller.removeShotGroup(group.shots.first.id);
    }
  }
}

class _FreeCreationHeaderCell extends StatelessWidget {
  const _FreeCreationHeaderCell({required this.label, required this.width});

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 44,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Center(
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}

class _FreeCreationPromptHeaderCell extends StatelessWidget {
  const _FreeCreationPromptHeaderCell({
    required this.width,
    required this.prompts,
    required this.controller,
  });

  final double width;
  final List<ShotPrompt> prompts;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final format = controller.promptFormatFor(prompts.first);
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      height: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border(
            right: BorderSide(color: theme.colorScheme.outlineVariant),
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '提示词',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                key: const ValueKey('free-creation-prompt-format-selector'),
                width: 260,
                height: 36,
                child: SegmentedButton<ShotPromptFormat>(
                  segments: const [
                    ButtonSegment(
                      value: ShotPromptFormat.kling,
                      label: Text('可灵'),
                    ),
                    ButtonSegment(
                      value: ShotPromptFormat.h3,
                      label: Text('H3'),
                    ),
                    ButtonSegment(
                      value: ShotPromptFormat.sd2,
                      label: Text('即梦'),
                    ),
                  ],
                  selected: {format},
                  onSelectionChanged: (selection) =>
                      controller.selectPromptFormatForAll(selection.first),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FreeCreationShotRow extends StatelessWidget {
  const _FreeCreationShotRow({
    super.key,
    required this.index,
    required this.group,
    required this.head,
    required this.controller,
    required this.replicatedByShotId,
    required this.prompt,
    required this.showPrompt,
    required this.shotNumberWidth,
    required this.originalWidth,
    required this.replicaWidth,
    required this.descriptionWidth,
    required this.promptWidth,
    required this.actionWidth,
    required this.actionsEnabled,
    required this.onOpenFrame,
    required this.onAnalyze,
    required this.onRemove,
  });

  final int index;
  final ScriptShotGroup group;
  final ScriptShot head;
  final ReplicateController controller;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final ShotPrompt? prompt;
  final bool showPrompt;
  final double shotNumberWidth;
  final double originalWidth;
  final double replicaWidth;
  final double descriptionWidth;
  final double promptWidth;
  final double actionWidth;
  final bool actionsEnabled;
  final void Function(ScriptShotGroup group, bool showOriginal) onOpenFrame;
  final Future<void> Function() onAnalyze;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _NewShotTable.rowHeight,
      child: Row(
        children: [
          _NewShotNumberCell(
            group: group,
            sequenceNumber: index + 1,
            shot: head,
            confirmed: false,
            enabled: false,
            width: shotNumberWidth,
            controller: controller,
            contextMenuItems: () => _manualGroupMenuItems(context),
            onContextMenuSelected: _handleManualGroupAction,
          ),
          _ShotFrameRangeOrSingleCell(
            group: group,
            shot: head,
            replicatedImage: replicatedByShotId[head.id],
            replicatedByShotId: replicatedByShotId,
            showOriginal: true,
            width: originalWidth,
            contextMenuItems: () => _manualGroupMenuItems(context),
            onContextMenuSelected: _handleManualGroupAction,
            onOpen: () => onOpenFrame(group, true),
          ),
          _ShotFrameRangeOrSingleCell(
            group: group,
            shot: head,
            replicatedImage: replicatedByShotId[head.id],
            replicatedByShotId: replicatedByShotId,
            showOriginal: false,
            width: replicaWidth,
            contextMenuItems: () => _manualGroupMenuItems(context),
            onContextMenuSelected: _handleManualGroupAction,
            onOpen: () => onOpenFrame(group, false),
          ),
          _FreeCreationDescriptionCell(
            key: ValueKey('free-creation-description-cell-${head.id}'),
            shot: head,
            controller: controller,
            width: descriptionWidth,
          ),
          if (showPrompt)
            _FreeCreationPromptCell(
              key: ValueKey('free-creation-prompt-cell-${head.id}'),
              prompt: prompt,
              controller: controller,
              width: promptWidth,
            ),
          _FreeCreationActionCell(
            index: index,
            shotId: head.id,
            width: actionWidth,
            enabled: actionsEnabled,
            isGroup: group.shots.length > 1,
            onAnalyze: onAnalyze,
            onRemove: onRemove,
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _manualGroupMenuItems(BuildContext context) {
    final pendingStartId = controller.pendingManualShotGroupStartId;
    final isGrouped = controller.shotIsInManualGroup(head.id);
    if (pendingStartId != null) {
      if (pendingStartId == head.id) {
        return const [
          PopupMenuItem(enabled: false, child: Text('已设为首帧')),
          PopupMenuItem(value: 'clear-manual-group', child: Text('取消镜头组')),
        ];
      }
      if (controller.canSelectManualShotGroupEnd(head.id)) {
        return const [
          PopupMenuItem(value: 'set-manual-end', child: Text('设为结束帧')),
        ];
      }
      return const [PopupMenuItem(enabled: false, child: Text('只能选择后续镜头'))];
    }
    return [
      PopupMenuItem(
        value: controller.canSelectManualShotGroupStart(head.id)
            ? 'set-manual-start'
            : null,
        enabled: controller.canSelectManualShotGroupStart(head.id),
        child: const Text('设为首帧'),
      ),
      if (isGrouped)
        const PopupMenuItem(value: 'clear-manual-group', child: Text('取消镜头组')),
    ];
  }

  void _handleManualGroupAction(String action) {
    switch (action) {
      case 'set-manual-start':
        controller.selectManualShotGroupStart(head.id);
      case 'set-manual-end':
        controller.setManualShotGroupEnd(head.id);
      case 'clear-manual-group':
        controller.clearManualShotGroup(head.id);
    }
  }
}

class _FreeCreationActionCell extends StatelessWidget {
  const _FreeCreationActionCell({
    required this.index,
    required this.shotId,
    required this.width,
    required this.enabled,
    required this.isGroup,
    required this.onAnalyze,
    required this.onRemove,
  });

  final int index;
  final String shotId;
  final double width;
  final bool enabled;
  final bool isGroup;
  final Future<void> Function() onAnalyze;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: _NewShotTable.rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.center,
          children: [
            IconButton(
              key: ValueKey('free-creation-analyze-$shotId'),
              tooltip: isGroup ? '解析当前镜头组' : '解析当前镜头',
              onPressed: enabled ? () => onAnalyze() : null,
              icon: const Icon(Icons.manage_search_rounded),
            ),
            ReorderableDragStartListener(
              index: index,
              enabled: enabled,
              child: KeyedSubtree(
                key: ValueKey('free-creation-reorder-$shotId'),
                child: Tooltip(
                  message: '拖拽排序',
                  child: Semantics(
                    button: true,
                    enabled: enabled,
                    label: '拖拽排序',
                    child: MouseRegion(
                      cursor: enabled
                          ? SystemMouseCursors.grab
                          : SystemMouseCursors.basic,
                      child: SizedBox.square(
                        dimension: 40,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          color: enabled
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).disabledColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('free-creation-remove-$shotId'),
              tooltip: '移除',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _FreeCreationDescriptionCell extends StatefulWidget {
  const _FreeCreationDescriptionCell({
    super.key,
    required this.shot,
    required this.controller,
    required this.width,
  });

  final ScriptShot shot;
  final ReplicateController controller;
  final double width;

  @override
  State<_FreeCreationDescriptionCell> createState() =>
      _FreeCreationDescriptionCellState();
}

class _FreeCreationDescriptionCellState
    extends State<_FreeCreationDescriptionCell> {
  static const _saveDelay = Duration(milliseconds: 450);

  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  late String _lastSavedText;
  late String _lastObservedText;
  Timer? _saveTimer;
  bool _wasComposing = false;
  bool _synchronizing = false;

  @override
  void initState() {
    super.initState();
    _lastSavedText = widget.shot.freeCreationDescription;
    _lastObservedText = _lastSavedText;
    _textController = TextEditingController(text: _lastSavedText)
      ..addListener(_handleEditingValueChanged);
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _FreeCreationDescriptionCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stored = widget.shot.freeCreationDescription;
    if (oldWidget.shot.id != widget.shot.id) {
      _saveTimer?.cancel();
      _lastSavedText = stored;
      _replaceLocalText(stored);
      return;
    }
    if (stored == _textController.text) {
      _lastSavedText = stored;
      return;
    }
    if (_focusNode.hasFocus || _isComposing) return;
    if (_textController.text == _lastSavedText) {
      _lastSavedText = stored;
      _replaceLocalText(stored);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _textController
      ..removeListener(_handleEditingValueChanged)
      ..dispose();
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  bool get _isComposing {
    final composing = _textController.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _handleEditingValueChanged() {
    if (_synchronizing) return;
    final text = _textController.text;
    final composing = _isComposing;
    final compositionEnded = _wasComposing && !composing;
    final textChanged = text != _lastObservedText;
    _lastObservedText = text;
    _wasComposing = composing;
    if (composing) {
      _saveTimer?.cancel();
      _saveTimer = null;
      return;
    }
    if (text == _lastSavedText) {
      _saveTimer?.cancel();
      _saveTimer = null;
      return;
    }
    if (textChanged || compositionEnded) _scheduleCommit();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) return;
    _commit(force: _textController.text != widget.shot.freeCreationDescription);
  }

  void _scheduleCommit() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _commit);
  }

  void _commit({bool force = false}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_isComposing) {
      _scheduleCommit();
      return;
    }
    final text = _textController.text;
    if (!force && text == _lastSavedText) return;
    final saved = widget.controller.updateFreeCreationDescription(
      widget.shot.id,
      text,
    );
    if (saved) {
      _lastSavedText = text;
    } else if (mounted) {
      _scheduleCommit();
    }
  }

  void _replaceLocalText(String text) {
    _synchronizing = true;
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _lastObservedText = text;
    _wasComposing = false;
    _synchronizing = false;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: _NewShotTable.rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: TextFormField(
            key: ValueKey('free-creation-description-${widget.shot.id}'),
            controller: _textController,
            focusNode: _focusNode,
            minLines: 3,
            maxLines: 4,
            onTapOutside: (_) {
              _commit();
              _focusNode.unfocus();
            },
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: '选填：描述创作意图、节奏、风格或声音；留空则自动分析',
            ),
          ),
        ),
      ),
    );
  }
}

class _FreeCreationPromptCell extends StatefulWidget {
  const _FreeCreationPromptCell({
    super.key,
    required this.prompt,
    required this.controller,
    required this.width,
  });

  final ShotPrompt? prompt;
  final ReplicateController controller;
  final double width;

  @override
  State<_FreeCreationPromptCell> createState() =>
      _FreeCreationPromptCellState();
}

class _FreeCreationPromptCellState extends State<_FreeCreationPromptCell> {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _selectedText());
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _FreeCreationPromptCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _selectedText();
    if (_textController.text == next) return;
    if (oldWidget.prompt?.id == widget.prompt?.id &&
        (_focusNode.hasFocus || _hasActiveComposing(_textController))) {
      return;
    }
    _replaceControllerText(_textController, next);
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
  void dispose() {
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    return SizedBox(
      width: widget.width,
      height: _NewShotTable.rowHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: prompt == null
            ? const Center(child: Text('待构建'))
            : Padding(
                padding: const EdgeInsets.fromLTRB(7, 4, 5, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('free-creation-prompt-${prompt.id}'),
                        controller: _textController,
                        focusNode: _focusNode,
                        minLines: 3,
                        maxLines: 4,
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          labelText: prompt.isUserEdited
                              ? '已手动修改'
                              : prompt.status == ProcessingStatus.failed
                              ? '生成失败'
                              : _promptFormatLabel(
                                  widget.controller.promptFormatFor(prompt),
                                ),
                          errorText: prompt.status == ProcessingStatus.failed
                              ? prompt.errorMessage
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 36,
                      height: 92,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '保存提示词',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              onPressed: _textController.text.trim().isEmpty
                                  ? null
                                  : () => widget.controller.updatePromptText(
                                      prompt.id,
                                      _textController.text,
                                    ),
                              icon: const Icon(Icons.save_rounded, size: 18),
                            ),
                            IconButton(
                              tooltip: '复制提示词',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              onPressed: () => Clipboard.setData(
                                ClipboardData(text: _textController.text),
                              ),
                              icon: const Icon(Icons.copy_rounded, size: 18),
                            ),
                            IconButton(
                              tooltip: prompt.status == ProcessingStatus.failed
                                  ? '重试生成'
                                  : '单镜头重新生成',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              onPressed: () => _regenerate(context, prompt),
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  static String _promptFormatLabel(ShotPromptFormat format) => switch (format) {
    ShotPromptFormat.kling => '可灵提示词',
    ShotPromptFormat.h3 => 'H3 Ref2VA',
    ShotPromptFormat.sd2 => '即梦提示词',
  };

  Future<void> _regenerate(BuildContext context, ShotPrompt prompt) async {
    if (prompt.isUserEdited) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖手动修改？'),
          content: const Text('重新生成将覆盖当前已手动修改的提示词。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认覆盖'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await widget.controller.regeneratePrompt(prompt.id);
  }
}

class _NewShotTable extends ConsumerStatefulWidget {
  const _NewShotTable({
    required this.state,
    required this.controller,
    required this.confirmed,
    required this.startEndFrameMode,
    required this.onOpenPrompt,
    required this.shotNavigationController,
    this.onOpenFrame,
  });

  static const rowHeight = 112.0;
  static const textCellMaxLines = 4;

  final ReplicateState state;
  final ReplicateController controller;
  final Set<String> confirmed;
  final bool startEndFrameMode;
  final ValueChanged<ShotPrompt> onOpenPrompt;
  final ReplicateShotNavigationController shotNavigationController;
  final void Function(int index, bool showOriginal)? onOpenFrame;

  @override
  ConsumerState<_NewShotTable> createState() => _NewShotTableState();
}

class _NewShotTableState extends ConsumerState<_NewShotTable> {
  static const _columnWidthsSettingKey = 'replicateConfirmShotColumnWidths';

  final _horizontalController = ScrollController();
  final _verticalController = ScrollController();
  late final Map<String, double> _columnWidths = _loadColumnWidths();

  @override
  void initState() {
    super.initState();
    widget.shotNavigationController.addListener(_navigateToRequestedShot);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToRequestedShot();
    });
  }

  @override
  void didUpdateWidget(covariant _NewShotTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shotNavigationController == widget.shotNavigationController) {
      return;
    }
    oldWidget.shotNavigationController.removeListener(_navigateToRequestedShot);
    widget.shotNavigationController.addListener(_navigateToRequestedShot);
  }

  @override
  void dispose() {
    widget.shotNavigationController.removeListener(_navigateToRequestedShot);
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  void _navigateToRequestedShot() {
    final shotId = widget.shotNavigationController.requestedShotId;
    if (!mounted || shotId == null) return;
    if (!_verticalController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigateToRequestedShot();
      });
      return;
    }
    final groups = ScriptShotGroup.group(widget.state.shots);
    final index = groups.indexWhere(
      (group) => group.shots.any((shot) => shot.id == shotId),
    );
    if (index < 0) return;
    final target = (index * _NewShotTable.rowHeight).clamp(
      0.0,
      _verticalController.position.maxScrollExtent,
    );
    _verticalController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('shooting_script.shot_list');
    final promptByShotId = <String, ShotPrompt>{
      for (final prompt in widget.state.prompts)
        if (prompt.scriptShotId != null) prompt.scriptShotId!: prompt,
    };
    final replicaByShotId = <String, ReplicatedShotImage>{
      for (final image in widget.state.replicatedImages)
        image.scriptShotId: image,
    };
    final groups = ScriptShotGroup.group(widget.state.shots);
    final visibleColumns = _NewShotTableColumn.columns(
      widget.startEndFrameMode,
    );
    final table = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SizedBox(
        width: _NewShotTableColumn.totalWidth(visibleColumns, _columnWidths),
        child: Column(
          children: [
            _NewShotTableHeader(
              columns: visibleColumns,
              columnWidths: _columnWidths,
              onResize: _resizeColumn,
            ),
            Expanded(
              child: widget.state.shots.isEmpty
                  ? const Center(child: Text('当前脚本暂无镜头'))
                  : Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _verticalController,
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          final shot = group.shots.first;
                          final shotIndex = widget.state.shots.indexWhere(
                            (candidate) => candidate.id == shot.id,
                          );
                          return _NewShotTableRow(
                            key: ValueKey('new-shot-row-${shot.id}'),
                            index: index,
                            group: group,
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
                            columnWidths: _columnWidths,
                            onOpenPrompt: widget.onOpenPrompt,
                            onOpenFrame:
                                widget.onOpenFrame == null || shotIndex < 0
                                ? null
                                : (showOriginal) => widget.onOpenFrame!(
                                    shotIndex,
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

  Map<String, double> _loadColumnWidths() {
    final widths = {
      for (final column in _NewShotTableColumn.allColumns)
        column.id: column.defaultWidth,
    };
    final raw = ref
        .read(appDatabaseProvider)
        .getSetting(_columnWidthsSettingKey);
    if (raw == null || raw.trim().isEmpty) return widths;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final column in _NewShotTableColumn.allColumns) {
          final value = decoded[column.id];
          final width = value is num ? value.toDouble() : null;
          if (width != null) {
            widths[column.id] = column.clampWidth(width);
          }
        }
      }
    } on FormatException {
      // 配置损坏时回退默认宽度，避免阻断确认镜头页打开。
    }
    return widths;
  }

  void _resizeColumn(_NewShotTableColumn column, double delta) {
    if (delta == 0) return;
    setState(() {
      final current = _columnWidths[column.id] ?? column.defaultWidth;
      _columnWidths[column.id] = column.clampWidth(current + delta);
    });
    _saveColumnWidths();
  }

  void _saveColumnWidths() {
    ref
        .read(appDatabaseProvider)
        .setSetting(
          _columnWidthsSettingKey,
          jsonEncode({
            for (final column in _NewShotTableColumn.allColumns)
              column.id: (_columnWidths[column.id] ?? column.defaultWidth)
                  .round(),
          }),
        );
  }
}

class _NewShotTableColumn {
  const _NewShotTableColumn(
    this.id,
    this.label,
    this.defaultWidth, {
    this.minWidth = 48,
    this.maxWidth = 760,
  });

  final String id;
  final String label;
  final double defaultWidth;
  final double minWidth;
  final double maxWidth;

  double clampWidth(double width) => width.clamp(minWidth, maxWidth).toDouble();

  static double widthOf(
    Map<String, double> widths,
    _NewShotTableColumn column,
  ) {
    return column.clampWidth(widths[column.id] ?? column.defaultWidth);
  }

  static double totalWidth(
    List<_NewShotTableColumn> columns,
    Map<String, double> widths,
  ) => columns.fold(0, (total, column) => total + widthOf(widths, column));

  static List<_NewShotTableColumn> columns(bool startEndFrameMode) => [
    shotNumber,
    startEndFrameMode ? originalStartFrame : originalFrame,
    if (startEndFrameMode) originalTailFrame,
    startEndFrameMode ? replicaStartFrame : replicaFrame,
    if (startEndFrameMode) replicaTailFrame,
    duration,
    content,
    shotSize,
    composition,
    cameraAngle,
    lightingMood,
    colorPalette,
    visualFocus,
    productStyling,
    transitionHint,
    dialogue,
    sound,
    cameraMovement,
    prompt,
    actions,
  ];

  static const shotNumber = _NewShotTableColumn(
    'shotNumber',
    '镜号',
    48,
    minWidth: 44,
    maxWidth: 90,
  );
  static const originalFrame = _NewShotTableColumn(
    'originalFrame',
    '原图',
    168,
    minWidth: 120,
  );
  static const originalStartFrame = _NewShotTableColumn(
    'originalFrame',
    '首帧',
    168,
    minWidth: 120,
  );
  static const originalTailFrame = _NewShotTableColumn(
    'originalTailFrame',
    '尾帧',
    168,
    minWidth: 120,
  );
  static const replicaFrame = _NewShotTableColumn(
    'replicaFrame',
    '复刻分镜',
    168,
    minWidth: 120,
  );
  static const replicaStartFrame = _NewShotTableColumn(
    'replicaFrame',
    '复刻首帧',
    168,
    minWidth: 120,
  );
  static const replicaTailFrame = _NewShotTableColumn(
    'replicaTailFrame',
    '复刻尾帧',
    168,
    minWidth: 120,
  );
  static const duration = _NewShotTableColumn(
    'duration',
    '时长',
    64,
    minWidth: 56,
    maxWidth: 110,
  );
  static const content = _NewShotTableColumn(
    'content',
    '画面描述',
    680,
    minWidth: 220,
    maxWidth: 960,
  );
  static const shotSize = _NewShotTableColumn(
    'shotSize',
    '景别',
    58,
    minWidth: 52,
    maxWidth: 120,
  );
  static const composition = _NewShotTableColumn('composition', '构图', 220);
  static const cameraAngle = _NewShotTableColumn('cameraAngle', '机位', 150);
  static const lightingMood = _NewShotTableColumn('lightingMood', '光影/氛围', 235);
  static const colorPalette = _NewShotTableColumn('colorPalette', '色彩', 200);
  static const visualFocus = _NewShotTableColumn('visualFocus', '视觉焦点', 220);
  static const productStyling = _NewShotTableColumn(
    'productStyling',
    '搭配',
    120,
  );
  static const transitionHint = _NewShotTableColumn(
    'transitionHint',
    '剪辑衔接',
    220,
  );
  static const dialogue = _NewShotTableColumn('dialogue', '对白/旁白', 365);
  static const sound = _NewShotTableColumn('sound', '音效', 223);
  static const cameraMovement = _NewShotTableColumn(
    'cameraMovement',
    '运镜',
    223,
  );
  static const prompt = _NewShotTableColumn(
    'prompt',
    '最终提示词',
    85,
    minWidth: 76,
    maxWidth: 180,
  );
  static const actions = _NewShotTableColumn(
    'actions',
    '操作',
    58,
    minWidth: 54,
    maxWidth: 120,
  );

  static const allColumns = [
    shotNumber,
    originalFrame,
    originalTailFrame,
    replicaFrame,
    replicaTailFrame,
    duration,
    content,
    shotSize,
    composition,
    cameraAngle,
    lightingMood,
    colorPalette,
    visualFocus,
    productStyling,
    transitionHint,
    dialogue,
    sound,
    cameraMovement,
    prompt,
    actions,
  ];
}

class _NewShotTableHeader extends StatelessWidget {
  const _NewShotTableHeader({
    required this.columns,
    required this.columnWidths,
    required this.onResize,
  });

  final List<_NewShotTableColumn> columns;
  final Map<String, double> columnWidths;
  final void Function(_NewShotTableColumn column, double delta) onResize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          for (final column in columns)
            _NewHeaderCell(
              column: column,
              width: _NewShotTableColumn.widthOf(columnWidths, column),
              onResize: (delta) => onResize(column, delta),
            ),
        ],
      ),
    );
  }
}

class _NewHeaderCell extends StatelessWidget {
  const _NewHeaderCell({
    required this.column,
    required this.width,
    required this.onResize,
  });

  final _NewShotTableColumn column;
  final double width;
  final ValueChanged<double> onResize;

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
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  column.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  key: ValueKey('confirm-shot-column-resize-${column.id}'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) =>
                      onResize(details.primaryDelta ?? 0),
                  child: const SizedBox(
                    width: 12,
                    child: Center(child: VerticalDivider(width: 1)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewShotTableRow extends StatelessWidget {
  const _NewShotTableRow({
    super.key,
    required this.index,
    required this.group,
    required this.shot,
    required this.tailShot,
    required this.replicatedImage,
    required this.replicatedByShotId,
    required this.prompt,
    required this.confirmed,
    required this.startEndFrameMode,
    required this.controller,
    required this.columnWidths,
    required this.onOpenPrompt,
    this.onOpenFrame,
  });

  final int index;
  final ScriptShotGroup group;
  final ScriptShot shot;
  final ScriptShot? tailShot;
  final ReplicatedShotImage? replicatedImage;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final ShotPrompt? prompt;
  final bool confirmed;
  final bool startEndFrameMode;
  final ReplicateController controller;
  final Map<String, double> columnWidths;
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
              group: group,
              sequenceNumber: index + 1,
              shot: shot,
              confirmed: confirmed,
              enabled: false,
              width: _width(_NewShotTableColumn.shotNumber),
              controller: controller,
              contextMenuItems: () => _startEndFrameMenuItems(context),
              onContextMenuSelected: _handleStartEndFrameAction,
            ),
            _ShotFrameRangeOrSingleCell(
              group: group,
              shot: shot,
              replicatedImage: replicatedImage,
              replicatedByShotId: replicatedByShotId,
              showOriginal: true,
              width: _width(_NewShotTableColumn.originalFrame),
              labelOverride: startEndFrameMode ? '首帧' : null,
              contextMenuItems: () => _startEndFrameMenuItems(context),
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
                width: _width(_NewShotTableColumn.originalTailFrame),
                labelOverride: tailShot == null ? '无尾帧' : '尾帧',
                emptyLabel: '无尾帧',
                forceEmpty: tailShot == null,
                keySuffix: 'tail-original',
                onOpen: null,
              ),
            _ShotFrameRangeOrSingleCell(
              group: group,
              shot: shot,
              replicatedImage: replicatedImage,
              replicatedByShotId: replicatedByShotId,
              showOriginal: false,
              width: _width(_NewShotTableColumn.replicaFrame),
              labelOverride: startEndFrameMode ? '复刻首帧' : null,
              contextMenuItems: () => _startEndFrameMenuItems(context),
              onContextMenuSelected: _handleStartEndFrameAction,
              onOpen: onOpenFrame == null ? null : () => onOpenFrame!(false),
            ),
            if (startEndFrameMode)
              _ShotFrameCell(
                shot: tailShot ?? shot,
                replicatedImage: tailShot == null
                    ? null
                    : replicatedByShotId[tailShot!.id],
                showOriginal: false,
                width: _width(_NewShotTableColumn.replicaTailFrame),
                labelOverride: tailShot == null ? '待尾帧' : '复刻尾帧',
                emptyLabel: tailShot == null ? '待尾帧' : '待复刻尾帧',
                forceEmpty: tailShot == null,
                keySuffix: 'tail-replica',
                onOpen: null,
              ),
            _NewDurationCell(
              key: ValueKey('shot-duration-${shot.id}'),
              value: group.durationSeconds,
              width: _width(_NewShotTableColumn.duration),
              onCommit: (seconds) => controller.updateShot(
                group.shots.last.copyWith(durationSeconds: seconds),
              ),
            ),
            _NewInlineCell(
              value: shot.content,
              width: _width(_NewShotTableColumn.content),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(content: value)),
            ),
            _NewInlineCell(
              value: shot.shotSize,
              width: _width(_NewShotTableColumn.shotSize),
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(shotSize: value)),
            ),
            _NewInlineCell(
              value: shot.composition,
              width: _width(_NewShotTableColumn.composition),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(composition: value)),
            ),
            _NewInlineCell(
              value: shot.cameraAngle,
              width: _width(_NewShotTableColumn.cameraAngle),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraAngle: value)),
            ),
            _NewInlineCell(
              value: shot.lightingMood,
              width: _width(_NewShotTableColumn.lightingMood),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(lightingMood: value)),
            ),
            _NewInlineCell(
              value: shot.colorPalette,
              width: _width(_NewShotTableColumn.colorPalette),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(colorPalette: value)),
            ),
            _NewInlineCell(
              value: shot.visualFocus,
              width: _width(_NewShotTableColumn.visualFocus),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(visualFocus: value)),
            ),
            _NewInlineCell(
              value: shot.productStyling,
              width: _width(_NewShotTableColumn.productStyling),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(productStyling: value)),
            ),
            _NewInlineCell(
              value: shot.transitionHint,
              width: _width(_NewShotTableColumn.transitionHint),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(transitionHint: value)),
            ),
            _NewInlineCell(
              value: shot.dialogue,
              width: _width(_NewShotTableColumn.dialogue),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(dialogue: value)),
            ),
            _NewInlineCell(
              value: shot.sound,
              width: _width(_NewShotTableColumn.sound),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(sound: value)),
            ),
            _NewInlineCell(
              value: shot.cameraMovement,
              width: _width(_NewShotTableColumn.cameraMovement),
              maxLines: _NewShotTable.textCellMaxLines,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraMovement: value)),
            ),
            _NewGridCell(
              width: _width(_NewShotTableColumn.prompt),
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
              width: _width(_NewShotTableColumn.actions),
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

  double _width(_NewShotTableColumn column) =>
      _NewShotTableColumn.widthOf(columnWidths, column);

  List<PopupMenuEntry<String>> _startEndFrameMenuItems(BuildContext context) {
    return _manualShotGroupMenuItems(context);
  }

  List<PopupMenuEntry<String>> _manualShotGroupMenuItems(BuildContext context) {
    final pendingStartId = controller.pendingManualShotGroupStartId;
    final isGrouped = controller.shotIsInManualGroup(shot.id);
    if (pendingStartId != null) {
      if (pendingStartId == shot.id) {
        return const [
          PopupMenuItem(enabled: false, child: Text('已设为首帧')),
          PopupMenuItem(value: 'clear-manual-group', child: Text('取消镜头组')),
        ];
      }
      if (controller.canSelectManualShotGroupEnd(shot.id)) {
        return const [
          PopupMenuItem(value: 'set-manual-end', child: Text('设为结束帧')),
        ];
      }
      return const [PopupMenuItem(enabled: false, child: Text('只能选择后续镜头'))];
    }
    return [
      PopupMenuItem(
        value: controller.canSelectManualShotGroupStart(shot.id)
            ? 'set-manual-start'
            : null,
        enabled: controller.canSelectManualShotGroupStart(shot.id),
        child: const Text('设为首帧'),
      ),
      if (isGrouped)
        const PopupMenuItem(value: 'clear-manual-group', child: Text('取消镜头组')),
    ];
  }

  void _handleStartEndFrameAction(String action) {
    switch (action) {
      case 'set-manual-start':
        controller.selectManualShotGroupStart(shot.id);
        break;
      case 'set-manual-end':
        controller.setManualShotGroupEnd(shot.id);
        break;
      case 'clear-manual-group':
        controller.clearManualShotGroup(shot.id);
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
  if (seconds == null || !seconds.isFinite || seconds <= 0) {
    return null;
  }
  return seconds;
}

class _ShotFrameCell extends StatelessWidget {
  const _ShotFrameCell({
    required this.shot,
    required this.replicatedImage,
    required this.showOriginal,
    required this.width,
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
  final double width;
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
    final hasGenerated = generatedPath.trim().isNotEmpty;
    final selectedPath = forceEmpty
        ? ''
        : showOriginal
        ? shot.framePath
        : (hasGenerated ? generatedPath : '');
    final label = labelOverride ?? (showOriginal ? '原图' : '复刻');
    return _NewGridCell(
      width: width,
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

class _ShotFrameRangeOrSingleCell extends StatelessWidget {
  const _ShotFrameRangeOrSingleCell({
    required this.group,
    required this.shot,
    required this.replicatedImage,
    required this.replicatedByShotId,
    required this.showOriginal,
    required this.width,
    this.labelOverride,
    this.contextMenuItems,
    this.onContextMenuSelected,
    this.onOpen,
  });

  final ScriptShotGroup group;
  final ScriptShot shot;
  final ReplicatedShotImage? replicatedImage;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final bool showOriginal;
  final double width;
  final String? labelOverride;
  final List<PopupMenuEntry<String>> Function()? contextMenuItems;
  final ValueChanged<String>? onContextMenuSelected;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (group.shots.length <= 1) {
      return _ShotFrameCell(
        shot: shot,
        replicatedImage: replicatedImage,
        showOriginal: showOriginal,
        width: width,
        labelOverride: labelOverride,
        contextMenuItems: contextMenuItems,
        onContextMenuSelected: onContextMenuSelected,
        onOpen: onOpen,
      );
    }
    final label = showOriginal
        ? '原视频帧 ${group.frameRangeLabel}'
        : '复刻分镜 ${group.frameRangeLabel}';
    return _NewGridCell(
      width: width,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: _ContextMenuRegion(
          contextMenuItems: contextMenuItems,
          onContextMenuSelected: onContextMenuSelected,
          child: Tooltip(
            message: '$label，点击全屏浏览',
            child: InkWell(
              key: ValueKey(
                'replicate-shot-${showOriginal ? 'original' : 'replica'}-range-${group.startNumber}-${group.endNumber}',
              ),
              onTap: onOpen,
              borderRadius: BorderRadius.circular(5),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Row(
                  children: [
                    for (final item in group.shots.take(3))
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: _BuiltFrameThumbnail(
                            path: _framePathForBuiltRange(
                              item,
                              !showOriginal,
                              replicatedByShotId,
                            ),
                            label: item.shotNumber.toString(),
                          ),
                        ),
                      ),
                    if (group.shots.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text('+${group.shots.length - 3}'),
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
}

class _ContextMenuRegion extends StatelessWidget {
  const _ContextMenuRegion({
    required this.child,
    this.contextMenuItems,
    this.onContextMenuSelected,
  });

  final Widget child;
  final List<PopupMenuEntry<String>> Function()? contextMenuItems;
  final ValueChanged<String>? onContextMenuSelected;

  @override
  Widget build(BuildContext context) {
    if (contextMenuItems == null || onContextMenuSelected == null) {
      return child;
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
      child: child,
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
    final exists = _fileExists(context, path);
    return Tooltip(
      message: exists ? '$label：$path' : '$label暂不可用',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: path.trim().isNotEmpty ? onTap : null,
          borderRadius: BorderRadius.circular(5),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: exists
                      ? PreviewFileImage(
                          path: path,
                          fit: BoxFit.contain,
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
  bool showReplica = false,
  Map<String, ReplicatedShotImage> replicatedByShotId = const {},
}) {
  final items = [
    for (final shot in shots)
      _FrameGalleryItem(
        shotNumber: shot.shotNumber,
        path: showReplica
            ? replicatedByShotId[shot.id]?.generatedFramePath ?? ''
            : shot.framePath,
        label: showReplica ? '复刻分镜' : '原视频帧',
      ),
  ];
  return showFullscreenZoomGallery<_FrameGalleryItem>(
    context: context,
    items: items,
    initialIndex: initialIndex,
    labelBuilder: (item, index, total) =>
        '镜头 ${item.shotNumber.toString().padLeft(2, '0')} · ${item.label} · ${index + 1}/$total',
    itemBuilder: (context, item) {
      if (item.path.isEmpty) {
        return const Center(
          child: Text('当前镜头暂无可预览的图片', style: TextStyle(color: Colors.white)),
        );
      }
      return Image.file(
        File(item.path),
        key: ValueKey(
          'script-frame-gallery-image-${item.shotNumber}-${item.label}',
        ),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Center(
          child: Text('当前图片无法读取', style: TextStyle(color: Colors.white)),
        ),
      );
    },
  );
}

Future<void> _showAssetImageGallery(
  BuildContext context, {
  required String path,
  required String label,
  required Key imageKey,
}) => showFullscreenZoomGallery<String>(
  context: context,
  items: [path],
  initialIndex: 0,
  labelBuilder: (_, _, _) => label,
  itemBuilder: (context, imagePath) => Image.file(
    File(imagePath),
    key: imageKey,
    fit: BoxFit.contain,
    errorBuilder: (_, _, _) => const Center(
      child: Text('当前图片无法读取', style: TextStyle(color: Colors.white)),
    ),
  ),
);

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
    required this.group,
    required this.sequenceNumber,
    required this.shot,
    required this.confirmed,
    required this.enabled,
    required this.width,
    required this.controller,
    this.contextMenuItems,
    this.onContextMenuSelected,
  });

  final ScriptShotGroup group;
  final int sequenceNumber;
  final ScriptShot shot;
  final bool confirmed;
  final bool enabled;
  final double width;
  final ReplicateController controller;
  final List<PopupMenuEntry<String>> Function()? contextMenuItems;
  final ValueChanged<String>? onContextMenuSelected;

  @override
  Widget build(BuildContext context) => _NewGridCell(
    width: width,
    child: _ContextMenuRegion(
      contextMenuItems: contextMenuItems,
      onContextMenuSelected: onContextMenuSelected,
      child: InkWell(
        key: ValueKey('toggle-new-shot-${shot.id}'),
        onTap: enabled
            ? () => controller.toggleShotConfirmed(shot.id, !confirmed)
            : null,
        child: Center(
          child: Text(
            group.sequentialRangeLabel(sequenceNumber),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
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

class _NewPrepareAssetsStep extends StatefulWidget {
  const _NewPrepareAssetsStep({
    super.key,
    required this.state,
    required this.controller,
    required this.analysisState,
    required this.assetBindingController,
    required this.assetLibraryState,
    required this.onImportLocalAsset,
    required this.projectRoot,
    required this.onPickColorStyleThumbnail,
    required this.onManageAssets,
    required this.externalizeRightPanel,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ScriptAnalysisState analysisState;
  final ShootingScriptAssetBindingController assetBindingController;
  final ShootingAssetLibraryState assetLibraryState;
  final Future<ReplicateAsset?> Function(ReplicateAssetType type)
  onImportLocalAsset;
  final Directory projectRoot;
  final Future<File?> Function() onPickColorStyleThumbnail;
  final VoidCallback? onManageAssets;
  final bool externalizeRightPanel;

  @override
  State<_NewPrepareAssetsStep> createState() => _NewPrepareAssetsStepState();
}

class _NewPrepareAssetsStepState extends State<_NewPrepareAssetsStep> {
  ReplicationGenerationMode _mode = ReplicationGenerationMode.quick;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final controller = widget.controller;
    final analysisState = widget.analysisState;
    final assetBindingController = widget.assetBindingController;
    final assetLibraryState = widget.assetLibraryState;
    final onImportLocalAsset = widget.onImportLocalAsset;
    final onManageAssets = widget.onManageAssets;
    final externalizeRightPanel = widget.externalizeRightPanel;
    final preciseMode = _mode == ReplicationGenerationMode.precise;
    final canContinue = state.assets.any(
      (item) =>
          item.status == ProcessingStatus.completed && item.path.isNotEmpty,
    );
    final bindingState = assetBindingController.value;
    QuickReplicationInputCapacity quickCapacityForShot(String shotId) =>
        controller.quickReplicationCapacityForLinks(
          bindingState.linksForShot(shotId),
        );
    final hasConfirmedBinding = bindingState.links.any(
      (link) => link.confirmed,
    );
    final baseCanGenerate = preciseMode
        ? canContinue || hasConfirmedBinding
        : hasConfirmedBinding;
    String quickBatchLimitError = '';
    var maximumQuickInputCount = 1;
    QuickReplicationInputCapacity? quickModelCapacity;
    if (!preciseMode) {
      for (final shot in state.confirmedShots) {
        final capacity = quickCapacityForShot(shot.id);
        quickModelCapacity ??= capacity;
        maximumQuickInputCount = math.max(
          maximumQuickInputCount,
          capacity.totalInputCount,
        );
        if (quickBatchLimitError.isEmpty && !capacity.isWithinLimits) {
          quickBatchLimitError = '镜头${shot.shotNumber}：${capacity.error}';
        }
      }
      quickModelCapacity ??= controller.quickReplicationCapacityForLinks(
        const [],
      );
    }
    final canGenerate =
        baseCanGenerate && (preciseMode || quickBatchLimitError.isEmpty);
    final isExtractingDwPose = state.shotGuides.any(
      (guide) => guide.poseStatus == ProcessingStatus.running,
    );
    final content = Padding(
      key: const ValueKey('replicate-asset-library-scroll'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      child: _PrepareAssetsContent(
        state: state,
        controller: controller,
        analysisState: analysisState,
        bindingState: bindingState,
        assetBindingController: assetBindingController,
        assetLibraryState: assetLibraryState,
        onImportLocalAsset: onImportLocalAsset,
        mode: _mode,
      ),
    );
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: preciseMode ? '步骤 1 · 精确匹配资产' : '步骤 1 · 快速多图复刻',
            subtitle: preciseMode
                ? '适合严格产品替换：分析主体、锁定姿势并逐项控制保留、替换或移除。'
                : '可一键解析原帧人数并生成模特、产品与可选场景槽；也可直接添加编号参考图。',
            actions: [
              SegmentedButton<ReplicationGenerationMode>(
                key: const ValueKey('replication-generation-mode'),
                segments: const [
                  ButtonSegment(
                    value: ReplicationGenerationMode.quick,
                    icon: Icon(Icons.flash_on_rounded),
                    label: Text('快速'),
                  ),
                  ButtonSegment(
                    value: ReplicationGenerationMode.precise,
                    icon: Icon(Icons.tune_rounded),
                    label: Text('精确'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: state.isBusy
                    ? null
                    : (selection) => setState(() => _mode = selection.single),
                showSelectedIcon: false,
              ),
              if (preciseMode)
                OutlinedButton.icon(
                  key: const ValueKey('analyze-all-replication-frames'),
                  onPressed: state.shots.isEmpty || state.isAnalyzingFrames
                      ? null
                      : controller.analyzeAllReplicationFrames,
                  icon: state.isAnalyzingFrames
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.center_focus_strong_rounded),
                  label: Text(state.isAnalyzingFrames ? '分析原帧中…' : '分析全部原帧'),
                ),
              if (!preciseMode)
                OutlinedButton.icon(
                  key: const ValueKey('quick-parse-all-replication-frames'),
                  onPressed: state.shots.isEmpty || state.isAnalyzingFrames
                      ? null
                      : controller.analyzeAllQuickReplicationFrames,
                  icon: state.isAnalyzingFrames
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.document_scanner_outlined),
                  label: Text(state.isAnalyzingFrames ? '解析原帧中…' : '全部一键解析'),
                ),
              if (preciseMode)
                OutlinedButton.icon(
                  key: const ValueKey('extract-all-dwpose'),
                  onPressed: state.shots.isEmpty || isExtractingDwPose
                      ? null
                      : controller.extractDwPoseForAllShots,
                  icon: isExtractingDwPose
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.accessibility_new_rounded),
                  label: Text(isExtractingDwPose ? '提取骨架中…' : '提取全部骨架'),
                ),
              if (preciseMode)
                OutlinedButton.icon(
                  key: const ValueKey('script-auto-match-assets'),
                  onPressed: assetBindingController.value.isBusy
                      ? null
                      : () => assetBindingController.autoMatchAll(
                          preferredAssets: state.assets,
                          maximumProductCountsByShotId: {
                            for (final guide in state.shotGuides)
                              guide.shotId: guide.subjects
                                  .where(
                                    (subject) =>
                                        subject.type ==
                                        ReplicateSubjectType.product,
                                  )
                                  .length,
                          },
                        ),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(
                    assetBindingController.value.isBusy ? '匹配中…' : '自动匹配资产',
                  ),
                ),
              OutlinedButton.icon(
                key: const ValueKey('replicate-generation-parameters'),
                onPressed: state.isBusy
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (context) =>
                            _ReplicateGenerationParametersDialog(
                              controller: controller,
                              run: state.run!,
                              projectRoot: widget.projectRoot,
                              onPickThumbnail: widget.onPickColorStyleThumbnail,
                            ),
                      ),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('生成参数'),
              ),
              if (assetBindingController.value.isBusy)
                OutlinedButton.icon(
                  onPressed: assetBindingController.cancelMatching,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('取消匹配'),
                ),
              if (!preciseMode && quickModelCapacity != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    quickBatchLimitError.isEmpty
                        ? '单镜头输入 $maximumQuickInputCount/${quickModelCapacity.maximumTotalInputCount} 张'
                        : quickBatchLimitError,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: quickBatchLimitError.isEmpty
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton.icon(
                key: const ValueKey('replicate-all-shot-images'),
                onPressed: canGenerate && !state.isBusy
                    ? () => _confirmReplicateAll(
                        context,
                        state,
                        controller,
                        mode: _mode,
                      )
                    : null,
                icon: const Icon(Icons.auto_awesome_motion_rounded),
                label: Text(
                  state.isBusy
                      ? '复刻中…'
                      : preciseMode
                      ? '精确复刻'
                      : '快速复刻',
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('replicate-new-next-confirm'),
                onPressed: canGenerate
                    ? () => controller.moveToStep(ReplicateStep.confirmShots)
                    : null,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('下一步'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: externalizeRightPanel
                ? content
                : _ResizableStepRightPanel(
                    uiStateKey: 'shootingScriptStepPanelCollapsed',
                    resizeHandleKey: const ValueKey(
                      'prepare-assets-right-panel-resize-handle',
                    ),
                    expandButtonKey: const ValueKey(
                      'expand-prepare-assets-right-panel',
                    ),
                    collapsedLabel: '资产库',
                    defaultWidth: 360,
                    compactBreakpoint: 1040,
                    compactHeight: 300,
                    content: content,
                    panelBuilder: (context, onToggleCollapsed) =>
                        _PrepareAssetLibrarySidePanel(
                          assetLibraryState: assetLibraryState,
                          onManageAssets: onManageAssets,
                          onToggleCollapsed: onToggleCollapsed,
                        ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReplicateGenerationParametersDialog extends StatefulWidget {
  const _ReplicateGenerationParametersDialog({
    required this.controller,
    required this.run,
    required this.projectRoot,
    required this.onPickThumbnail,
  });

  final ReplicateController controller;
  final ReplicateRun run;
  final Directory projectRoot;
  final Future<File?> Function() onPickThumbnail;

  @override
  State<_ReplicateGenerationParametersDialog> createState() =>
      _ReplicateGenerationParametersDialogState();
}

class _ReplicateGenerationParametersDialogState
    extends State<_ReplicateGenerationParametersDialog> {
  late final String _model;
  late String _aspectRatio;
  late bool _inheritSourceAspectRatio;
  late String _imageSize;
  late String _quality;
  late ReplicateSourceFrameMode _sourceFrameMode;
  late String _colorStylePresetId;

  List<String> get _aspectRatioOptions =>
      StoryDesignController.aspectRatioOptionsFor(_model);

  List<String> get _imageSizeOptions =>
      StoryDesignController.imageSizeOptionsFor(_model, _aspectRatio);

  List<String> get _qualityOptions =>
      StoryDesignController.qualityOptionsFor(_model);

  Map<String, String>? get _imageSizeLabels =>
      StoryDesignController.imageSizeLabelsFor(_model, _aspectRatio);

  @override
  void initState() {
    super.initState();
    _model = widget.controller.resolvedGenerationModel;
    _inheritSourceAspectRatio = widget.run.inheritSourceAspectRatio;
    _aspectRatio = _normalizedOption(
      widget.run.generationAspectRatio,
      _aspectRatioOptions,
    );
    _imageSize = _normalizedOption(
      widget.run.generationImageSize,
      _imageSizeOptions,
    );
    _quality = _normalizedOption(widget.run.generationQuality, _qualityOptions);
    _sourceFrameMode =
        widget.run.sourceFrameMode == ReplicateSourceFrameMode.lineArt
        ? ReplicateSourceFrameMode.lineArt
        : ReplicateSourceFrameMode.colorReference;
    _colorStylePresetId = widget.run.colorStylePresetId.trim().isEmpty
        ? 'natural_cinema'
        : widget.run.colorStylePresetId;
    widget.controller.addListener(_handleControllerChanged);
    _normalizeSelectedPreset();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(_normalizeSelectedPreset);
  }

  void _normalizeSelectedPreset() {
    final presets = widget.controller.value.colorStylePresets;
    if (presets.isEmpty) return;
    if (!presets.any((preset) => preset.id == _colorStylePresetId)) {
      _colorStylePresetId = presets.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final supportsQuality = StoryDesignController.supportsQuality(_model);
    final contentWidth = math.min(
      900.0,
      math.max(280.0, MediaQuery.sizeOf(context).width - 160),
    );
    final stackGenerationFields = contentWidth < 680;
    return AlertDialog(
      key: const ValueKey('replicate-generation-parameters-dialog'),
      title: const Text('生成参数'),
      content: SizedBox(
        width: contentWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.76,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '当前图片模型：${ImageGenerationModelCatalog.labelFor(_model)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Text(
                  '原帧类型',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                SegmentedButton<ReplicateSourceFrameMode>(
                  key: const ValueKey('replicate-source-frame-mode'),
                  segments: const [
                    ButtonSegment(
                      value: ReplicateSourceFrameMode.colorReference,
                      icon: Icon(Icons.photo_outlined),
                      label: Text('彩色原帧'),
                    ),
                    ButtonSegment(
                      value: ReplicateSourceFrameMode.lineArt,
                      icon: Icon(Icons.gesture_rounded),
                      label: Text('黑白线稿'),
                    ),
                  ],
                  selected: {_sourceFrameMode},
                  onSelectionChanged: (selection) =>
                      setState(() => _sourceFrameMode = selection.single),
                ),
                const SizedBox(height: 6),
                Text(
                  _sourceFrameMode == ReplicateSourceFrameMode.lineArt
                      ? '线稿只约束构图、机位、姿态和空间关系；颜色由资产本色与下方全片预设决定。'
                      : '彩色原帧继续提供场景外观、材质与光色参考，不额外启用线稿调色预设。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Divider(height: 30),
                SwitchListTile.adaptive(
                  key: const ValueKey('replicate-inherit-source-aspect-ratio'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('跟随原帧画幅'),
                  subtitle: const Text('每个镜头自动选择最接近原图的模型支持比例'),
                  value: _inheritSourceAspectRatio,
                  onChanged: (value) =>
                      setState(() => _inheritSourceAspectRatio = value),
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final fields = [
                      DropdownButtonFormField<String>(
                        key: const ValueKey(
                          'replicate-generation-aspect-ratio',
                        ),
                        initialValue: _aspectRatioOptions.contains(_aspectRatio)
                            ? _aspectRatio
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '比例',
                          prefixIcon: Icon(Icons.aspect_ratio_rounded),
                        ),
                        items: [
                          for (final ratio in _aspectRatioOptions)
                            DropdownMenuItem(
                              value: ratio,
                              child: Text(
                                ratio,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _inheritSourceAspectRatio
                            ? null
                            : (ratio) {
                                if (ratio == null) return;
                                setState(() {
                                  _aspectRatio = ratio;
                                  _imageSize = _normalizedOption(
                                    '',
                                    _imageSizeOptions,
                                  );
                                });
                              },
                      ),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'replicate-generation-image-size-$_aspectRatio',
                        ),
                        initialValue: _imageSizeOptions.contains(_imageSize)
                            ? _imageSize
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '分辨率',
                          prefixIcon: Icon(
                            Icons.photo_size_select_large_rounded,
                          ),
                        ),
                        items: [
                          for (final size in _imageSizeOptions)
                            DropdownMenuItem(
                              value: size,
                              child: Text(
                                _imageSizeLabels?[size] ?? size,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (size) {
                          if (size != null) setState(() => _imageSize = size);
                        },
                      ),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('replicate-generation-quality'),
                        initialValue: _qualityOptions.contains(_quality)
                            ? _quality
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '质量',
                          prefixIcon: Icon(Icons.high_quality_rounded),
                        ),
                        items: [
                          for (final quality in _qualityOptions)
                            DropdownMenuItem(
                              value: quality,
                              child: Text(
                                GptImageGenerationPreset
                                        .qualityLabels[quality] ??
                                    quality,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: !supportsQuality
                            ? null
                            : (quality) {
                                if (quality != null) {
                                  setState(() => _quality = quality);
                                }
                              },
                      ),
                    ];
                    if (stackGenerationFields) {
                      return Column(
                        children: [
                          for (
                            var index = 0;
                            index < fields.length;
                            index++
                          ) ...[
                            fields[index],
                            if (index < fields.length - 1)
                              const SizedBox(height: 12),
                          ],
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var index = 0; index < fields.length; index++) ...[
                          Expanded(child: fields[index]),
                          if (index < fields.length - 1)
                            const SizedBox(width: 12),
                        ],
                      ],
                    );
                  },
                ),
                if (_sourceFrameMode == ReplicateSourceFrameMode.lineArt) ...[
                  const Divider(height: 32),
                  LineArtColorStylePicker(
                    presets: widget.controller.value.colorStylePresets,
                    selectedId: _colorStylePresetId,
                    projectRoot: widget.projectRoot,
                    availableWidth: contentWidth,
                    onSelected: (id) =>
                        setState(() => _colorStylePresetId = id),
                    onCreate: _createPreset,
                    onAction: _handlePresetAction,
                  ),
                  if (widget.controller.isSelectedColorStyleChanged) ...[
                    const SizedBox(height: 10),
                    Text(
                      '当前任务冻结的预设与最新版本不同；保存后将使用当前卡片重新冻结。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ],
                  if (widget
                      .controller
                      .hasReplicatedImagesWithStaleColorStyle) ...[
                    const SizedBox(height: 10),
                    Text(
                      '已有成图使用旧色彩指纹；保存新预设后，相关镜头需要重新生成。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-replicate-generation-parameters'),
          onPressed: () {
            widget.controller.updateGenerationDefaults(
              aspectRatio: _aspectRatio,
              inheritSourceAspectRatio: _inheritSourceAspectRatio,
              multiViewEnhancementEnabled: false,
              imageSize: _imageSize,
              quality: _quality,
              sourceFrameMode: _sourceFrameMode,
              colorStylePresetId:
                  _sourceFrameMode == ReplicateSourceFrameMode.lineArt
                  ? _colorStylePresetId
                  : null,
            );
            Navigator.of(context).pop();
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  static String _normalizedOption(String value, List<String> options) {
    if (options.isEmpty) return '';
    return options.contains(value) ? value : options.first;
  }

  Future<void> _createPreset() async {
    final draft = await showLineArtColorStylePresetEditor(context);
    if (draft == null || !mounted) return;
    final id = widget.controller.saveCustomColorStylePreset(
      name: draft.name,
      description: draft.description,
      prompt: draft.prompt,
      swatches: draft.swatches,
      useCase: draft.useCase,
    );
    if (mounted) setState(() => _colorStylePresetId = id);
  }

  Future<void> _handlePresetAction(
    LineArtColorStylePreset preset,
    LineArtColorStyleCardAction action,
  ) async {
    try {
      switch (action) {
        case LineArtColorStyleCardAction.viewSource:
          await showLineArtColorStyleSourceDialog(context, preset);
        case LineArtColorStyleCardAction.importThumbnail:
          final file = await widget.onPickThumbnail();
          if (file != null) {
            await widget.controller.importColorStyleThumbnail(
              presetId: preset.id,
              source: file,
            );
          }
        case LineArtColorStyleCardAction.removeThumbnail:
          await widget.controller.removeColorStyleThumbnail(preset.id);
        case LineArtColorStyleCardAction.edit:
          final draft = await showLineArtColorStylePresetEditor(
            context,
            initialPreset: preset,
          );
          if (draft != null) {
            widget.controller.saveCustomColorStylePreset(
              id: preset.id,
              name: draft.name,
              description: draft.description,
              prompt: draft.prompt,
              swatches: draft.swatches,
              useCase: draft.useCase,
            );
          }
        case LineArtColorStyleCardAction.duplicate:
          final id = widget.controller.duplicateColorStylePreset(preset.id);
          if (mounted) setState(() => _colorStylePresetId = id);
        case LineArtColorStyleCardAction.delete:
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('删除自定义色彩预设'),
              content: Text(
                widget.run.colorStylePresetId == preset.id
                    ? '“${preset.name}”正在被当前任务使用。删除后仍会保留已经冻结的任务快照，是否继续？'
                    : '确定删除“${preset.name}”吗？',
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
            await widget.controller.deleteCustomColorStylePreset(
              preset.id,
              force: true,
            );
          }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('色彩预设操作失败：$error')));
      }
    }
  }
}

class _PrepareAssetLibrarySidePanel extends StatelessWidget {
  const _PrepareAssetLibrarySidePanel({
    required this.assetLibraryState,
    required this.onManageAssets,
    required this.onToggleCollapsed,
  });

  final ShootingAssetLibraryState assetLibraryState;
  final VoidCallback? onManageAssets;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      key: const ValueKey('prepare-assets-right-asset-library-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Row(
              children: [
                Icon(
                  Icons.video_library_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '资产库',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('manage-prepare-assets-library'),
                  tooltip: '管理资产',
                  onPressed: onManageAssets,
                  icon: const Icon(Icons.tune_rounded),
                ),
                IconButton(
                  key: const ValueKey('collapse-prepare-assets-right-panel'),
                  tooltip: '折叠资产库',
                  onPressed: onToggleCollapsed,
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: assetLibraryState.items.isEmpty
                ? const Center(child: Text('暂无常用资产'))
                : _PrepareAssetLibraryList(items: assetLibraryState.items),
          ),
        ],
      ),
    );
  }
}

class _PrepareAssetLibraryList extends StatelessWidget {
  const _PrepareAssetLibraryList({required this.items});

  final List<ShootingAssetLibraryItem> items;

  @override
  Widget build(BuildContext context) {
    final entries = <_PrepareAssetLibraryEntry>[];
    for (final type in ReplicateAssetType.values) {
      final typedItems = [
        for (final item in items)
          if (item.type == type) item,
      ];
      if (typedItems.isEmpty) continue;
      entries.add(_PrepareAssetLibraryEntry.header(type, typedItems.length));
      for (final item in typedItems) {
        entries.add(_PrepareAssetLibraryEntry.item(item));
      }
    }
    return ListView.builder(
      key: const ValueKey('prepare-assets-right-asset-library-scroll'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.type case final type?) {
          return Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Row(
              children: [
                Icon(type.icon, size: 16),
                const SizedBox(width: 6),
                Text(
                  type.label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 6),
                Text('${entry.itemCount}'),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _PrepareAssetLibraryCard(item: entry.item!),
        );
      },
    );
  }
}

class _PrepareAssetLibraryEntry {
  const _PrepareAssetLibraryEntry.header(this.type, this.itemCount)
    : item = null;

  const _PrepareAssetLibraryEntry.item(this.item) : type = null, itemCount = 0;

  final ReplicateAssetType? type;
  final int itemCount;
  final ShootingAssetLibraryItem? item;
}

class _PrepareAssetLibraryCard extends StatelessWidget {
  const _PrepareAssetLibraryCard({required this.item});

  final ShootingAssetLibraryItem item;

  @override
  Widget build(BuildContext context) {
    final child = Card(
      key: ValueKey('prepare-asset-library-item-${item.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              height: 58,
              child: _BindingAssetPreview(path: item.path, label: item.name),
            ),
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
                  Text(item.type.label),
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

class _PrepareAssetsContent extends StatelessWidget {
  const _PrepareAssetsContent({
    required this.state,
    required this.controller,
    required this.analysisState,
    required this.bindingState,
    required this.assetBindingController,
    required this.assetLibraryState,
    required this.onImportLocalAsset,
    required this.mode,
  });

  final ReplicateState state;
  final ReplicateController controller;
  final ScriptAnalysisState analysisState;
  final ScriptAssetBindingState bindingState;
  final ShootingScriptAssetBindingController assetBindingController;
  final ShootingAssetLibraryState assetLibraryState;
  final Future<ReplicateAsset?> Function(ReplicateAssetType type)
  onImportLocalAsset;
  final ReplicationGenerationMode mode;

  @override
  Widget build(BuildContext context) {
    final bindingBoard = _ShotAssetBindingBoard(
      state: state,
      startEndFrameMode: false,
      rows: state.shots,
      tailShotForDisplay: controller.tailShotForDisplay,
      analysisState: analysisState,
      bindingState: bindingState,
      libraryState: assetLibraryState,
      onDrop: (item, shotId, replaceScriptAssetId, slotSortOrder, slotLabel) =>
          assetBindingController.replaceLibraryAssetOnShot(
            item,
            shotId,
            replaceScriptAssetId: replaceScriptAssetId,
            slotSortOrder: slotSortOrder,
            slotLabel: slotLabel,
          ),
      onSelectStepAsset:
          (item, shotId, replaceScriptAssetId, slotSortOrder, slotLabel) =>
              assetBindingController.addStepAssetToShot(
                item,
                shotId,
                replaceScriptAssetId: replaceScriptAssetId,
                slotSortOrder: slotSortOrder,
                slotLabel: slotLabel,
              ),
      onSelectLibraryAsset:
          (item, shotId, replaceScriptAssetId, slotSortOrder, slotLabel) =>
              assetBindingController.replaceLibraryAssetOnShot(
                item,
                shotId,
                replaceScriptAssetId: replaceScriptAssetId,
                slotSortOrder: slotSortOrder,
                slotLabel: slotLabel,
              ),
      onSelectLocalAsset:
          (type, shotId, replaceScriptAssetId, slotSortOrder, slotLabel) async {
            final asset = await onImportLocalAsset(type);
            if (asset == null) return null;
            return assetBindingController.addStepAssetToShot(
              asset,
              shotId,
              replaceScriptAssetId: replaceScriptAssetId,
              slotSortOrder: slotSortOrder,
              slotLabel: slotLabel,
            );
          },
      onRemove: assetBindingController.removeAssetFromShot,
      onUpdateLink: assetBindingController.updateLink,
      onMatchShot: (shotId) => assetBindingController.autoMatchShot(
        shotId,
        preferredAssets: state.assets,
        maximumProductCount: controller
            .shotGuideFor(shotId)
            ?.subjects
            .where((subject) => subject.type == ReplicateSubjectType.product)
            .length,
      ),
      onUpdateInstructions: (shot, instructions) => controller.updateShot(
        shot.copyWith(replicationInstructions: instructions),
      ),
      guideForShot: controller.shotGuideFor,
      isGuideCurrent: mode == ReplicationGenerationMode.quick
          ? controller.isQuickReplicationAnalysisReady
          : controller.isPreciseReplicationAnalysisReady,
      onAnalyzeFrame: mode == ReplicationGenerationMode.quick
          ? controller.analyzeQuickReplicationFrame
          : controller.analyzeReplicationFrame,
      onExtractPose: controller.extractDwPoseForShot,
      onRemovePose: controller.removeDwPoseForShot,
      onSaveEditablePose: controller.saveEditablePoseForShot,
      onTogglePreservedElement: controller.setPreservedElementSelected,
      onSetSubjectDecision: controller.setDetectedSubjectDecision,
      onSetProductMarkAuthorization: (shotId, authorization) =>
          controller.setProductMarkAuthorization(
            shotId: shotId,
            authorization: authorization,
          ),
      onRemoveSubject: controller.removeDetectedSubject,
      onAddPreservedElement: controller.addManualPreservedElement,
      onReplicateShot: mode == ReplicationGenerationMode.quick
          ? controller.replicateShotQuick
          : controller.replicateShot,
      quickCapacityForShot: (shotId) => controller
          .quickReplicationCapacityForLinks(bindingState.linksForShot(shotId)),
      mode: mode,
      onOpenOriginalFrame: (shot) {
        final index = state.shots.indexWhere(
          (candidate) => candidate.id == shot.id,
        );
        if (index < 0) return;
        _showScriptFrameGallery(context, state.shots, index);
      },
      onOpenReplicatedFrame: (shot) {
        final index = state.shots.indexWhere(
          (candidate) => candidate.id == shot.id,
        );
        if (index < 0) return;
        _showScriptFrameGallery(
          context,
          state.shots,
          index,
          showReplica: true,
          replicatedByShotId: {
            for (final image in state.replicatedImages)
              image.scriptShotId: image,
          },
        );
      },
    );
    return bindingBoard;
  }
}

class _ShotAssetBindingBoard extends StatefulWidget {
  const _ShotAssetBindingBoard({
    required this.state,
    required this.startEndFrameMode,
    required this.rows,
    required this.tailShotForDisplay,
    required this.analysisState,
    required this.bindingState,
    required this.libraryState,
    required this.onDrop,
    required this.onSelectStepAsset,
    required this.onSelectLibraryAsset,
    required this.onSelectLocalAsset,
    required this.onRemove,
    required this.onUpdateLink,
    required this.onMatchShot,
    required this.onUpdateInstructions,
    required this.guideForShot,
    required this.isGuideCurrent,
    required this.onAnalyzeFrame,
    required this.onExtractPose,
    required this.onRemovePose,
    required this.onSaveEditablePose,
    required this.onTogglePreservedElement,
    required this.onSetSubjectDecision,
    required this.onSetProductMarkAuthorization,
    required this.onRemoveSubject,
    required this.onAddPreservedElement,
    required this.onReplicateShot,
    required this.quickCapacityForShot,
    required this.onOpenOriginalFrame,
    required this.onOpenReplicatedFrame,
    required this.mode,
  });

  final ReplicateState state;
  final bool startEndFrameMode;
  final List<ScriptShot> rows;
  final ScriptShot? Function(ScriptShot shot) tailShotForDisplay;
  final ScriptAnalysisState analysisState;
  final ScriptAssetBindingState bindingState;
  final ShootingAssetLibraryState libraryState;
  final Future<ScriptAsset?> Function(
    ShootingAssetLibraryItem item,
    String shotId,
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onDrop;
  final Future<ScriptAsset?> Function(
    ReplicateAsset item,
    String shotId,
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectStepAsset;
  final Future<ScriptAsset?> Function(
    ShootingAssetLibraryItem item,
    String shotId,
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectLibraryAsset;
  final Future<ScriptAsset?> Function(
    ReplicateAssetType type,
    String shotId,
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectLocalAsset;
  final void Function(String shotId, String scriptAssetId) onRemove;
  final ValueChanged<ScriptShotAssetLink> onUpdateLink;
  final Future<void> Function(String shotId) onMatchShot;
  final void Function(ScriptShot shot, String instructions)
  onUpdateInstructions;
  final ReplicateShotGuide? Function(String shotId) guideForShot;
  final bool Function(String shotId) isGuideCurrent;
  final Future<void> Function(String shotId) onAnalyzeFrame;
  final Future<void> Function(String shotId) onExtractPose;
  final Future<void> Function(String shotId) onRemovePose;
  final Future<void> Function(
    String shotId,
    ReplicateEditablePoseData editablePose,
  )
  onSaveEditablePose;
  final void Function(String shotId, String elementId, bool selected)
  onTogglePreservedElement;
  final void Function(
    String shotId,
    String subjectId,
    ReplicateSubjectDecision decision,
  )
  onSetSubjectDecision;
  final bool Function(
    String shotId,
    ReplicateProductMarkAuthorization authorization,
  )
  onSetProductMarkAuthorization;
  final void Function(String shotId, String subjectId) onRemoveSubject;
  final void Function(String shotId, String label) onAddPreservedElement;
  final Future<bool> Function(String shotId) onReplicateShot;
  final QuickReplicationInputCapacity Function(String shotId)
  quickCapacityForShot;
  final ValueChanged<ScriptShot> onOpenOriginalFrame;
  final ValueChanged<ScriptShot> onOpenReplicatedFrame;
  final ReplicationGenerationMode mode;

  @override
  State<_ShotAssetBindingBoard> createState() => _ShotAssetBindingBoardState();
}

class _ShotAssetBindingBoardState extends State<_ShotAssetBindingBoard>
    with AutomaticKeepAliveClientMixin {
  final _expandedShotIds = <String>{};
  bool _isShotListVisible = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _expandedShotIds.addAll(widget.rows.map((shot) => shot.id));
  }

  @override
  void didUpdateWidget(covariant _ShotAssetBindingBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousIds = oldWidget.rows.map((shot) => shot.id).toSet();
    for (final shot in widget.rows) {
      if (!previousIds.contains(shot.id)) {
        _expandedShotIds.add(shot.id);
      }
    }
  }

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
    final preciseMode = widget.mode == ReplicationGenerationMode.precise;
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
    _expandedShotIds.removeWhere((id) => !shotIds.contains(id));
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
                    preciseMode ? '精确资产控制' : '参考图片',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (preciseMode)
                  Text(
                    '默认展开脚本内容',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
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
              preciseMode
                  ? '分析原帧后会按识别到的人物和产品创建资产格；逐项选择保留、替换或移除。'
                  : '图片1固定为原分镜；依次添加人物、服装/产品、背景或其他参考图，再用一句话说明它们的关系。',
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
              Expanded(
                child: ListView.separated(
                  key: const PageStorageKey('replicate-asset-rows'),
                  itemCount: widget.rows.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final shot = widget.rows[index];
                    PerformanceProbe.shared.countBuild('replicate.asset_row');
                    return RepaintBoundary(
                      key: ValueKey('replicate-asset-row-${shot.id}'),
                      child: _ShotAssetDropRow(
                        shot: shot,
                        tailShot: widget.tailShotForDisplay(shot),
                        replicatedByShotId: replicatedByShotId,
                        startEndFrameMode: widget.startEndFrameMode,
                        analysis: widget.analysisState.forShot(shot.id),
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
                        onDrop: (item, replaceId, sortOrder, slotLabel) =>
                            widget.onDrop(
                              item,
                              shot.id,
                              replaceId,
                              sortOrder,
                              slotLabel,
                            ),
                        onSelectStepAsset:
                            (item, replaceId, sortOrder, slotLabel) =>
                                widget.onSelectStepAsset(
                                  item,
                                  shot.id,
                                  replaceId,
                                  sortOrder,
                                  slotLabel,
                                ),
                        onSelectLibraryAsset:
                            (item, replaceId, sortOrder, slotLabel) =>
                                widget.onSelectLibraryAsset(
                                  item,
                                  shot.id,
                                  replaceId,
                                  sortOrder,
                                  slotLabel,
                                ),
                        onSelectLocalAsset:
                            (type, replaceId, sortOrder, slotLabel) =>
                                widget.onSelectLocalAsset(
                                  type,
                                  shot.id,
                                  replaceId,
                                  sortOrder,
                                  slotLabel,
                                ),
                        onRemove: (assetId) =>
                            widget.onRemove(shot.id, assetId),
                        onUpdateLink: widget.onUpdateLink,
                        onMatch: () => widget.onMatchShot(shot.id),
                        onUpdateInstructions: (instructions) =>
                            widget.onUpdateInstructions(shot, instructions),
                        guide: widget.guideForShot(shot.id),
                        guideIsCurrent: widget.isGuideCurrent(shot.id),
                        onAnalyzeFrame: () => widget.onAnalyzeFrame(shot.id),
                        onExtractPose: () => widget.onExtractPose(shot.id),
                        onRemovePose: () => widget.onRemovePose(shot.id),
                        onSaveEditablePose: (editablePose) =>
                            widget.onSaveEditablePose(shot.id, editablePose),
                        onTogglePreservedElement: (elementId, selected) =>
                            widget.onTogglePreservedElement(
                              shot.id,
                              elementId,
                              selected,
                            ),
                        onSetSubjectDecision: (subjectId, decision) => widget
                            .onSetSubjectDecision(shot.id, subjectId, decision),
                        onSetProductMarkAuthorization: (authorization) =>
                            widget.onSetProductMarkAuthorization(
                              shot.id,
                              authorization,
                            ),
                        onRemoveSubject: (subjectId) =>
                            widget.onRemoveSubject(shot.id, subjectId),
                        onAddPreservedElement: (label) =>
                            widget.onAddPreservedElement(shot.id, label),
                        replicatedImage: replicatedByShotId[shot.id],
                        onReplicate: () => widget.onReplicateShot(shot.id),
                        quickCapacity: widget.quickCapacityForShot(shot.id),
                        onOpenOriginalFrame: widget.onOpenOriginalFrame,
                        onOpenReplicatedFrame: widget.onOpenReplicatedFrame,
                        mode: widget.mode,
                      ),
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

typedef _QuickBindingEntry = ({ScriptShotAssetLink link, ScriptAsset asset});

class _ShotAssetDropRow extends StatelessWidget {
  const _ShotAssetDropRow({
    required this.shot,
    required this.tailShot,
    required this.replicatedByShotId,
    required this.startEndFrameMode,
    required this.analysis,
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
    required this.onUpdateLink,
    required this.onMatch,
    required this.onUpdateInstructions,
    required this.guide,
    required this.guideIsCurrent,
    required this.onAnalyzeFrame,
    required this.onExtractPose,
    required this.onRemovePose,
    required this.onSaveEditablePose,
    required this.onTogglePreservedElement,
    required this.onSetSubjectDecision,
    required this.onSetProductMarkAuthorization,
    required this.onRemoveSubject,
    required this.onAddPreservedElement,
    required this.replicatedImage,
    required this.onReplicate,
    required this.quickCapacity,
    required this.onOpenOriginalFrame,
    required this.onOpenReplicatedFrame,
    required this.mode,
  });

  final ScriptShot shot;
  final ScriptShot? tailShot;
  final Map<String, ReplicatedShotImage> replicatedByShotId;
  final bool startEndFrameMode;
  final ScriptShotAnalysisRecord? analysis;
  final List<ScriptShotAssetLink> links;
  final ScriptAssetBindingState bindingState;
  final List<ShootingAssetLibraryItem> libraryItems;
  final List<ReplicateAsset> stepAssets;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Future<ScriptAsset?> Function(
    ShootingAssetLibraryItem item,
    String? replaceId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onDrop;
  final Future<ScriptAsset?> Function(
    ReplicateAsset item,
    String? replaceId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectStepAsset;
  final Future<ScriptAsset?> Function(
    ShootingAssetLibraryItem item,
    String? replaceId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectLibraryAsset;
  final Future<ScriptAsset?> Function(
    ReplicateAssetType type,
    String? replaceId,
    int? slotSortOrder,
    String? slotLabel,
  )
  onSelectLocalAsset;
  final ValueChanged<String> onRemove;
  final ValueChanged<ScriptShotAssetLink> onUpdateLink;
  final VoidCallback onMatch;
  final ValueChanged<String> onUpdateInstructions;
  final ReplicateShotGuide? guide;
  final bool guideIsCurrent;
  final Future<void> Function() onAnalyzeFrame;
  final Future<void> Function() onExtractPose;
  final Future<void> Function() onRemovePose;
  final Future<void> Function(ReplicateEditablePoseData editablePose)
  onSaveEditablePose;
  final void Function(String elementId, bool selected) onTogglePreservedElement;
  final void Function(String subjectId, ReplicateSubjectDecision decision)
  onSetSubjectDecision;
  final bool Function(ReplicateProductMarkAuthorization authorization)
  onSetProductMarkAuthorization;
  final ValueChanged<String> onRemoveSubject;
  final ValueChanged<String> onAddPreservedElement;
  final ReplicatedShotImage? replicatedImage;
  final Future<bool> Function() onReplicate;
  final QuickReplicationInputCapacity quickCapacity;
  final ValueChanged<ScriptShot> onOpenOriginalFrame;
  final ValueChanged<ScriptShot> onOpenReplicatedFrame;
  final ReplicationGenerationMode mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preciseMode = mode == ReplicationGenerationMode.precise;
    final analysisRunning = guide?.analysisStatus == ProcessingStatus.running;
    final hasAnalysisResult =
        guide?.analysisStatus == ProcessingStatus.completed;
    final analysisReady = hasAnalysisResult && guideIsCurrent;
    final poseRunning = guide?.poseStatus == ProcessingStatus.running;
    final poseReady =
        guide?.poseStatus == ProcessingStatus.completed &&
        (guide?.skeletonPath.trim().isNotEmpty ?? false);
    final assetSlots = preciseMode
        ? _buildAssetSlots(context)
        : _buildQuickAssetSlots(context);
    final frameStrip = _ShotAssetFrameStrip(
      shot: shot,
      tailShot: tailShot,
      replicatedImage: replicatedImage,
      tailReplicatedImage: tailShot == null
          ? null
          : replicatedByShotId[tailShot!.id],
      startEndFrameMode: startEndFrameMode,
      onOpenOriginalFrame: onOpenOriginalFrame,
      onOpenReplicatedFrame: onOpenReplicatedFrame,
      numberedOriginal: !preciseMode,
    );
    final instructionsField = _ShotReplicationInstructionsField(
      key: ValueKey('replicate-user-instructions-${shot.id}'),
      value: shot.replicationInstructions,
      onCommit: onUpdateInstructions,
      quickMode: !preciseMode,
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
                    if (preciseMode)
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
                    if (preciseMode)
                      OutlinedButton.icon(
                        key: ValueKey('analyze-replication-frame-${shot.id}'),
                        onPressed: analysisRunning || analysisReady
                            ? null
                            : onAnalyzeFrame,
                        icon: analysisRunning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.center_focus_strong_rounded,
                                size: 16,
                              ),
                        label: Text(
                          analysisReady
                              ? '原帧已分析'
                              : guide?.analysisStatus == ProcessingStatus.failed
                              ? '重试分析原帧'
                              : '分析原帧',
                        ),
                      ),
                    if (!preciseMode)
                      OutlinedButton.icon(
                        key: ValueKey('quick-parse-frame-${shot.id}'),
                        onPressed: analysisRunning || analysisReady
                            ? null
                            : onAnalyzeFrame,
                        icon: analysisRunning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.document_scanner_outlined,
                                size: 16,
                              ),
                        label: Text(
                          analysisRunning
                              ? '解析中…'
                              : analysisReady
                              ? '已解析 ${guide?.personCount ?? 0} 人'
                              : guide?.analysisStatus == ProcessingStatus.failed
                              ? '重试解析'
                              : '一键解析',
                        ),
                      ),
                    if (preciseMode) const SizedBox(width: 6),
                    if (preciseMode)
                      OutlinedButton.icon(
                        key: ValueKey('extract-dwpose-${shot.id}'),
                        onPressed: poseRunning || !guideIsCurrent
                            ? null
                            : onExtractPose,
                        icon: poseRunning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.device_hub_rounded, size: 16),
                        label: Text(poseReady ? '重新提取骨架' : '提取骨架'),
                      ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      key: ValueKey('replicate-shot-image-${shot.id}'),
                      onPressed:
                          (preciseMode || quickCapacity.isWithinLimits) &&
                              (links.isNotEmpty ||
                                  (preciseMode &&
                                      guideIsCurrent &&
                                      (guide?.subjects.isNotEmpty ?? false)))
                          ? onReplicate
                          : null,
                      icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                      label: Text(
                        !preciseMode
                            ? '生成复刻'
                            : startEndFrameMode && tailShot != null
                            ? '复刻首尾帧'
                            : '一键替换产品',
                      ),
                    ),
                  ],
                ),
                if (!preciseMode)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 4),
                    child: Row(
                      children: [
                        Text(
                          '输入图片 ${quickCapacity.totalInputCount}/${quickCapacity.maximumTotalInputCount}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (!quickCapacity.isWithinLimits) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              quickCapacity.error,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.error),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  key: ValueKey('shot-asset-visual-row-${shot.id}'),
                  builder: (context, constraints) {
                    final frameWidth = startEndFrameMode ? 304.0 : 292.0;
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
                const SizedBox(height: 8),
                if (preciseMode) ...[
                  _ShotFrameGuidePanel(
                    shot: shot,
                    guide: guide,
                    isCurrent: guideIsCurrent,
                    onToggleElement: onTogglePreservedElement,
                    onAddElement: onAddPreservedElement,
                  ),
                  _ProductMarkAuthorizationPanel(
                    shot: shot,
                    guide: guide,
                    isCurrent: guideIsCurrent,
                    referenceOptions: _productMarkReferenceOptions(),
                    onSave: onSetProductMarkAuthorization,
                  ),
                ],
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
                final frameWidth = startEndFrameMode ? 304.0 : 292.0;
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

  Widget _buildQuickAssetSlots(BuildContext context) {
    final entries = <_QuickBindingEntry>[];
    for (final link in links) {
      final asset = bindingState.assetById(link.scriptAssetId);
      if (asset != null) entries.add((link: link, asset: asset));
    }
    entries.sort((left, right) {
      final order = (left.link.quickReferenceOrder ?? 1 << 30).compareTo(
        right.link.quickReferenceOrder ?? 1 << 30,
      );
      return order != 0
          ? order
          : left.link.createdAt.compareTo(right.link.createdAt);
    });

    final imageNumberByAssetId = <String, int>{
      for (var index = 0; index < entries.length; index++)
        entries[index].asset.id: index + 2,
    };
    final templateReady =
        guideIsCurrent && guide?.analysisStatus == ProcessingStatus.completed;
    final detectedPersonCount = templateReady
        ? guide!.subjects
              .where((subject) => subject.type == ReplicateSubjectType.person)
              .length
        : 0;
    final characterCount = templateReady
        ? math
              .max(guide?.personCount ?? 0, detectedPersonCount)
              .clamp(0, 20)
              .toInt()
        : 0;
    final templates = <({ScriptAssetPresetSlot slot, QuickReferenceRole role})>[
      if (templateReady)
        for (var index = 0; index < characterCount; index++) ...[
          (
            slot: ScriptAssetPresetSlot.character(index),
            role: QuickReferenceRole.model,
          ),
          (
            slot: ScriptAssetPresetSlot.product(index),
            role: QuickReferenceRole.product,
          ),
        ],
      if (templateReady)
        (
          slot: const ScriptAssetPresetSlot.scene(),
          role: QuickReferenceRole.scene,
        ),
    ];
    final assignedAssetIds = <String>{};

    _QuickBindingEntry? takeTemplateEntry(
      ScriptAssetPresetSlot slot,
      QuickReferenceRole role,
    ) {
      _QuickBindingEntry? selected;
      for (final entry in entries) {
        if (assignedAssetIds.contains(entry.asset.id) ||
            entry.link.sortOrder != slot.sortOrder ||
            _effectiveQuickRole(entry) != role) {
          continue;
        }
        selected = entry;
        break;
      }
      if (selected == null) {
        for (final entry in entries) {
          if (assignedAssetIds.contains(entry.asset.id) ||
              _effectiveQuickRole(entry) != role ||
              templates.any(
                (template) =>
                    template.role == role &&
                    template.slot.sortOrder == entry.link.sortOrder,
              )) {
            continue;
          }
          selected = entry;
          break;
        }
      }
      if (selected != null) assignedAssetIds.add(selected.asset.id);
      return selected;
    }

    Widget buildCard(
      _QuickBindingEntry entry, {
      ScriptAssetPresetSlot? templateSlot,
    }) {
      final imageNumber = imageNumberByAssetId[entry.asset.id]!;
      final bindingLabel = templateSlot == null
          ? null
          : _quickTemplateLabel(templateSlot);
      return _QuickAssetBindingCard(
        key: ValueKey('quick-reference-${shot.id}-${entry.link.scriptAssetId}'),
        asset: entry.asset,
        link: entry.link,
        imageNumber: imageNumber,
        selectedRoleLabel: bindingLabel,
        groupLabel: _quickGroupLabel(entry, entries),
        onTap: () => _openAssetPicker(
          context,
          replaceScriptAssetId: entry.link.scriptAssetId,
          presetSlot: templateSlot,
          bindingLabel: bindingLabel,
          pickerTitle: bindingLabel == null
              ? '替换图$imageNumber资产'
              : '替换$bindingLabel资产图',
        ),
        onDrop: (item) => onDrop(
          item,
          entry.link.scriptAssetId,
          templateSlot?.sortOrder ?? entry.link.sortOrder,
          bindingLabel,
        ),
        onRemove: () => onRemove(entry.link.scriptAssetId),
        onRoleChanged: (role) => onUpdateLink(
          entry.link.copyWith(
            quickReferenceRole: role,
            clearQuickGroupAnchorAssetId: true,
            clearQuickGroupConfidence: true,
            quickGroupWarning: '',
          ),
        ),
        onDescriptionChanged: (description) => onUpdateLink(
          entry.link.copyWith(
            quickDescription: description,
            clearQuickGroupAnchorAssetId: true,
            clearQuickGroupConfidence: true,
            quickGroupWarning: '',
          ),
        ),
      );
    }

    Widget buildEmptyTemplateSlot(
      ScriptAssetPresetSlot slot,
      QuickReferenceRole role,
    ) {
      final label = _quickTemplateLabel(slot);
      return _EmptyAssetBindingSlot(
        key: ValueKey(
          'quick-template-slot-${shot.id}-${slot.kind.name}-${slot.sortOrder}',
        ),
        label: label,
        icon: switch (role) {
          QuickReferenceRole.model => Icons.person_add_alt_1_outlined,
          QuickReferenceRole.product => Icons.inventory_2_outlined,
          QuickReferenceRole.scene => Icons.landscape_outlined,
          _ => Icons.add_photo_alternate_outlined,
        },
        accepts: (item) => slot.acceptsAsset(
          type: item.type,
          name: item.name,
          description: item.description,
          aliases: item.aliases,
        ),
        onTap: () => _openAssetPicker(
          context,
          presetSlot: slot,
          bindingLabel: label,
          pickerTitle: '选择$label资产图',
        ),
        onDrop: (item) => onDrop(item, null, slot.sortOrder, label),
      );
    }

    return Wrap(
      key: ValueKey('quick-reference-images-${shot.id}'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final template in templates)
          if (takeTemplateEntry(template.slot, template.role) case final entry?)
            buildCard(entry, templateSlot: template.slot)
          else
            buildEmptyTemplateSlot(template.slot, template.role),
        for (final entry in entries)
          if (!assignedAssetIds.contains(entry.asset.id)) buildCard(entry),
        _EmptyAssetBindingSlot(
          key: ValueKey('quick-add-asset-${shot.id}'),
          label: templateReady ? '添加其他资产图' : '添加资产图',
          icon: Icons.add_photo_alternate_outlined,
          accepts: (_) => true,
          onTap: () => _openAssetPicker(
            context,
            pickerTitle: templateReady ? '添加其他资产图' : '添加资产图',
          ),
          onDrop: (item) => onDrop(item, null, null, null),
        ),
      ],
    );
  }

  String? _quickGroupLabel(
    _QuickBindingEntry entry,
    List<_QuickBindingEntry> entries,
  ) {
    final role = entry.link.quickReferenceRole;
    if (role != QuickReferenceRole.product &&
        role != QuickReferenceRole.productDetail) {
      return null;
    }
    final anchorId = entry.link.quickGroupAnchorAssetId;
    if (anchorId == null || anchorId.isEmpty) return '待自动归组';
    var productIndex = 0;
    for (final candidate in entries) {
      if (candidate.link.quickReferenceRole != QuickReferenceRole.product) {
        continue;
      }
      if (candidate.asset.id == anchorId) {
        final label = _alphabeticLabel(productIndex);
        return role == QuickReferenceRole.product
            ? '产品$label'
            : '产品$label · 已归组';
      }
      productIndex++;
    }
    return '待重新归组';
  }

  static String _alphabeticLabel(int index) => index < 26
      ? String.fromCharCode('A'.codeUnitAt(0) + index)
      : '${index + 1}';

  static QuickReferenceRole _effectiveQuickRole(_QuickBindingEntry entry) =>
      entry.link.quickReferenceRole ??
      switch (entry.asset.type) {
        ReplicateAssetType.character => QuickReferenceRole.model,
        ReplicateAssetType.scene => QuickReferenceRole.scene,
        ReplicateAssetType.product => QuickReferenceRole.product,
        ReplicateAssetType.prop => QuickReferenceRole.prop,
        ReplicateAssetType.video ||
        ReplicateAssetType.audio ||
        ReplicateAssetType.reference ||
        ReplicateAssetType.other => QuickReferenceRole.otherReference,
      };

  static String _quickTemplateLabel(ScriptAssetPresetSlot slot) =>
      switch (slot.kind) {
        ScriptAssetPresetSlotKind.character =>
          '模特${ScriptAssetSlotPolicy.characterSuffix(slot.characterIndex)}',
        ScriptAssetPresetSlotKind.product =>
          '产品${ScriptAssetSlotPolicy.characterSuffix(slot.productIndex)}',
        ScriptAssetPresetSlotKind.productDetail =>
          '产品细节${ScriptAssetSlotPolicy.characterSuffix(slot.productIndex)}',
        ScriptAssetPresetSlotKind.scene => '场景（可选）',
      };

  Widget _buildAssetSlots(BuildContext context) {
    final assetsByLink = <ScriptShotAssetLink, ScriptAsset>{};
    for (final link in links) {
      final asset = bindingState.assetById(link.scriptAssetId);
      if (asset != null) assetsByLink[link] = asset;
    }
    final subjects = guideIsCurrent
        ? guide?.subjects ?? const <ReplicateDetectedSubject>[]
        : const <ReplicateDetectedSubject>[];
    final characterCount = subjects
        .where((subject) => subject.type == ReplicateSubjectType.person)
        .length;
    final productCount = subjects
        .where((subject) => subject.type == ReplicateSubjectType.product)
        .length;
    final skeletonPath = guide?.skeletonPath.trim() ?? '';
    final showSkeleton =
        guideIsCurrent &&
        guide?.poseStatus == ProcessingStatus.completed &&
        skeletonPath.isNotEmpty;
    final assignments = <String, ScriptShotAssetLink>{};
    final assignedLinks = <ScriptShotAssetLink>{};

    ScriptAssetPresetSlot slotFor(ReplicateDetectedSubject subject) =>
        subject.type == ReplicateSubjectType.person
        ? ScriptAssetPresetSlot.character(subject.slotIndex)
        : ScriptAssetPresetSlot.product(subject.slotIndex);

    bool sameSubjectSlot(
      ScriptAssetPresetSlot slot,
      ReplicateDetectedSubject subject,
    ) => switch ((slot.kind, subject.type)) {
      (ScriptAssetPresetSlotKind.character, ReplicateSubjectType.person) =>
        slot.characterIndex == subject.slotIndex,
      (ScriptAssetPresetSlotKind.product, ReplicateSubjectType.product) =>
        slot.productIndex == subject.slotIndex,
      _ => false,
    };

    for (final subject in subjects) {
      final slot = slotFor(subject);
      for (final entry in assetsByLink.entries) {
        if (assignedLinks.contains(entry.key)) continue;
        final persistedSlot = ScriptAssetSlotPolicy.presetSlotForSortOrder(
          entry.key.sortOrder,
        );
        if (persistedSlot == null ||
            !sameSubjectSlot(persistedSlot, subject) ||
            !slot.acceptsAsset(
              type: entry.value.type,
              name: entry.value.name,
              description: entry.value.description,
            )) {
          continue;
        }
        assignments[subject.id] = entry.key;
        assignedLinks.add(entry.key);
        break;
      }
    }

    for (final subject in subjects) {
      if (assignments.containsKey(subject.id)) continue;
      final slot = slotFor(subject);
      for (final entry in assetsByLink.entries) {
        if (assignedLinks.contains(entry.key)) continue;
        final persistedSlot = ScriptAssetSlotPolicy.presetSlotForSortOrder(
          entry.key.sortOrder,
        );
        if (persistedSlot != null && persistedSlot.kind != slot.kind) {
          continue;
        }
        if (!slot.acceptsAsset(
          type: entry.value.type,
          name: entry.value.name,
          description: entry.value.description,
        )) {
          continue;
        }
        assignments[subject.id] = entry.key;
        assignedLinks.add(entry.key);
        break;
      }
    }
    final remainingLinks = [
      for (final link in links)
        if (assetsByLink.containsKey(link) && !assignedLinks.contains(link))
          link,
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (subjects.isEmpty)
          _DetectedSubjectAssetEmptyState(
            guideIsCurrent: guideIsCurrent,
            analysisStatus: guide?.analysisStatus,
          ),
        for (final subject in subjects) ...[
          _DetectedSubjectAssetSlot(
            key: ValueKey(
              'detected-subject-asset-slot-${shot.id}-${subject.id}',
            ),
            decisionKey: ValueKey(
              'replicate-subject-decision-${shot.id}-${subject.id}',
            ),
            pickerKey: ValueKey(
              'detected-subject-asset-picker-${shot.id}-${subject.id}',
            ),
            removeKey: ValueKey(
              'remove-detected-subject-asset-slot-${shot.id}-${subject.id}',
            ),
            subject: subject,
            asset: assignments[subject.id] == null
                ? null
                : assetsByLink[assignments[subject.id]!],
            link: assignments[subject.id],
            accepts: (item) => slotFor(subject).acceptsAsset(
              type: item.type,
              name: item.name,
              description: item.description,
              aliases: item.aliases,
            ),
            onTap: () => _openAssetPicker(
              context,
              replaceScriptAssetId: assignments[subject.id]?.scriptAssetId,
              presetSlot: slotFor(subject),
              bindingLabel: _detectedSubjectBindingLabel(
                subject,
                characterCount: characterCount,
                productCount: productCount,
              ),
              pickerTitle: '选择“${subject.label}”的替换资产',
              onAssetSelected: (_) => onSetSubjectDecision(
                subject.id,
                ReplicateSubjectDecision.replace,
              ),
            ),
            onDrop: (item) async {
              final slot = slotFor(subject);
              await onDrop(
                item,
                assignments[subject.id]?.scriptAssetId,
                slot.sortOrder,
                _detectedSubjectBindingLabel(
                  subject,
                  characterCount: characterCount,
                  productCount: productCount,
                ),
              );
              onSetSubjectDecision(
                subject.id,
                ReplicateSubjectDecision.replace,
              );
            },
            onRemove: assignments[subject.id] == null
                ? null
                : () => onRemove(assignments[subject.id]!.scriptAssetId),
            onRemoveSlot: () {
              final assignment = assignments[subject.id];
              if (assignment != null) onRemove(assignment.scriptAssetId);
              onRemoveSubject(subject.id);
            },
            onDecisionChanged: (decision) =>
                _changeSubjectDecision(subject, decision),
          ),
        ],
        for (final link in remainingLinks)
          _AssetBindingSlot(
            key: ValueKey(
              'supplemental-shot-asset-${shot.id}-${link.scriptAssetId}',
            ),
            asset: assetsByLink[link]!,
            link: link,
            slotLabel: '补充资产',
            accepts: (_) => true,
            onTap: () => _openAssetPicker(
              context,
              replaceScriptAssetId: link.scriptAssetId,
            ),
            onDrop: (item) => onDrop(item, link.scriptAssetId, null, null),
            onRemove: () => onRemove(link.scriptAssetId),
          ),
        if (showSkeleton)
          _SkeletonAssetSlot(
            key: ValueKey('shot-skeleton-asset-${shot.id}'),
            path: skeletonPath,
            onTap: () => _showAssetImageGallery(
              context,
              path: skeletonPath,
              label:
                  '镜头 ${shot.shotNumber.toString().padLeft(2, '0')} · DWPose 骨架',
              imageKey: ValueKey('dwpose-gallery-image-${shot.id}'),
            ),
            onEdit:
                guide!.editablePose.isEmpty ||
                    guide!.editablePose.sourceWidth <= 0 ||
                    guide!.editablePose.sourceHeight <= 0 ||
                    guide!.editablePose.people.any(
                      (person) => person.keypoints.length != 133,
                    )
                ? null
                : () => _openPoseEditor(context),
            onRemove: onRemovePose,
          ),
        _EmptyAssetBindingSlot(
          key: ValueKey('add-supplemental-shot-asset-${shot.id}'),
          label: '添加补充资产',
          icon: Icons.add_photo_alternate_outlined,
          accepts: (_) => true,
          onTap: () => _openAssetPicker(context),
          onDrop: (item) => onDrop(item, null, null, null),
        ),
      ],
    );
  }

  List<_ProductMarkReferenceOption> _productMarkReferenceOptions() {
    final options = <_ProductMarkReferenceOption>[];
    for (final link in links) {
      final slot = ScriptAssetSlotPolicy.presetSlotForSortOrder(link.sortOrder);
      if (slot == null ||
          (slot.kind != ScriptAssetPresetSlotKind.product &&
              slot.kind != ScriptAssetPresetSlotKind.productDetail)) {
        continue;
      }
      final asset = bindingState.assetById(link.scriptAssetId);
      if (asset == null) continue;
      options.add(
        _ProductMarkReferenceOption(
          assetId: asset.id,
          productSlotIndex: slot.productIndex,
          label:
              '${slot.kind == ScriptAssetPresetSlotKind.productDetail ? '细节图' : '产品主图'} · ${asset.name}',
        ),
      );
    }
    options.sort((left, right) {
      final slotOrder = left.productSlotIndex.compareTo(right.productSlotIndex);
      return slotOrder != 0 ? slotOrder : left.label.compareTo(right.label);
    });
    return options;
  }

  Future<void> _openPoseEditor(BuildContext context) async {
    final pose = guide?.editablePose ?? ReplicateEditablePoseData.empty;
    if (pose.isEmpty) return;
    final edited = await showReplicatePoseEditorDialog(
      context: context,
      initialPose: pose,
    );
    if (edited != null) await onSaveEditablePose(edited);
  }

  void _changeSubjectDecision(
    ReplicateDetectedSubject subject,
    ReplicateSubjectDecision decision,
  ) {
    onSetSubjectDecision(subject.id, decision);
  }

  Future<ScriptAsset?> _openAssetPicker(
    BuildContext context, {
    String? replaceScriptAssetId,
    ScriptAssetPresetSlot? presetSlot,
    String? bindingLabel,
    String? pickerTitle,
    ValueChanged<ScriptAsset>? onAssetSelected,
  }) async {
    final choices = [
      for (final asset in stepAssets)
        if (asset.path.trim().isNotEmpty &&
            (presetSlot?.acceptsAsset(
                  type: asset.type,
                  name: asset.name,
                  description: asset.description,
                ) ??
                true))
          _ShotAssetChoice.step(asset),
      for (final item in libraryItems)
        if (presetSlot?.acceptsAsset(
              type: item.type,
              name: item.name,
              description: item.description,
              aliases: item.aliases,
            ) ??
            true)
          _ShotAssetChoice.library(item),
    ];
    final recognizedCharacterCount = ScriptAssetSlotPolicy.presetSlotsFor(
      shot: shot,
      analysis: analysis,
      minimumCharacterCount: guideIsCurrent ? guide?.personCount ?? 1 : 1,
    ).where((slot) => slot.kind == ScriptAssetPresetSlotKind.character).length;
    final characterCount = math.max(
      recognizedCharacterCount,
      presetSlot?.kind == ScriptAssetPresetSlotKind.character
          ? presetSlot!.characterIndex + 1
          : 1,
    );
    final slotLabel =
        bindingLabel ?? presetSlot?.label(characterCount: characterCount);
    final fileAvailabilityCache = FileAvailabilityScope.of(context);
    final selected = await showDialog<_ShotAssetChoice>(
      context: context,
      builder: (dialogContext) => FileAvailabilityScope(
        cache: fileAvailabilityCache,
        child: AlertDialog(
          title: Text(
            pickerTitle ??
                (slotLabel == null
                    ? replaceScriptAssetId == null
                          ? '选择镜头资产'
                          : '重新选择镜头资产'
                    : '选择$slotLabel资产图'),
          ),
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
                        leading: SizedBox(
                          width: 64,
                          height: 48,
                          child: _BindingAssetPreview(
                            path: choice.path,
                            label: choice.name,
                          ),
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
      ),
    );
    if (selected == null) return null;
    ScriptAsset? selectedAsset;
    if (selected.isLocalFile) {
      selectedAsset = await onSelectLocalAsset(
        presetSlot?.preferredAssetType ?? ReplicateAssetType.reference,
        replaceScriptAssetId,
        presetSlot?.sortOrder,
        slotLabel,
      );
    } else if (selected.stepAsset != null) {
      selectedAsset = await onSelectStepAsset(
        selected.stepAsset!,
        replaceScriptAssetId,
        presetSlot?.sortOrder,
        slotLabel,
      );
    } else if (selected.libraryItem != null) {
      selectedAsset = await onSelectLibraryAsset(
        selected.libraryItem!,
        replaceScriptAssetId,
        presetSlot?.sortOrder,
        slotLabel,
      );
    }
    if (selectedAsset != null) onAssetSelected?.call(selectedAsset);
    return selectedAsset;
  }
}

String _detectedSubjectBindingLabel(
  ReplicateDetectedSubject subject, {
  required int characterCount,
  required int productCount,
}) {
  final count = subject.type == ReplicateSubjectType.person
      ? characterCount
      : productCount;
  final prefix = subject.type == ReplicateSubjectType.person ? '模特' : '产品';
  if (count <= 1 && subject.slotIndex == 0) return prefix;
  return '$prefix${ScriptAssetSlotPolicy.characterSuffix(subject.slotIndex)}';
}

class _ProductMarkReferenceOption {
  const _ProductMarkReferenceOption({
    required this.assetId,
    required this.productSlotIndex,
    required this.label,
  });

  final String assetId;
  final int productSlotIndex;
  final String label;
}

class _ProductMarkAuthorizationPanel extends StatelessWidget {
  const _ProductMarkAuthorizationPanel({
    required this.shot,
    required this.guide,
    required this.isCurrent,
    required this.referenceOptions,
    required this.onSave,
  });

  final ScriptShot shot;
  final ReplicateShotGuide? guide;
  final bool isCurrent;
  final List<_ProductMarkReferenceOption> referenceOptions;
  final bool Function(ReplicateProductMarkAuthorization authorization) onSave;

  @override
  Widget build(BuildContext context) {
    final productSlots = [
      for (final subject
          in guide?.subjects ?? const <ReplicateDetectedSubject>[])
        if (subject.type == ReplicateSubjectType.product &&
            subject.decision == ReplicateSubjectDecision.replace)
          subject.slotIndex,
    ]..sort();
    final authorizations = {
      for (final authorization
          in guide?.productMarkAuthorizations ??
              const <ReplicateProductMarkAuthorization>[])
        authorization.productSlotIndex: authorization,
    };
    if (!isCurrent || productSlots.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        key: ValueKey('product-mark-authorization-panel-${shot.id}'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final slotIndex in productSlots) ...[
                _buildSlotRow(
                  context,
                  slotIndex: slotIndex,
                  authorization: authorizations[slotIndex],
                  options: [
                    for (final option in referenceOptions)
                      if (option.productSlotIndex == slotIndex) option,
                  ],
                ),
                if (slotIndex != productSlots.last) const SizedBox(height: 7),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlotRow(
    BuildContext context, {
    required int slotIndex,
    required ReplicateProductMarkAuthorization? authorization,
    required List<_ProductMarkReferenceOption> options,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final referenceAvailable =
        authorization == null ||
        options.any(
          (option) => option.assetId == authorization.referenceAssetId,
        );
    final staleReference =
        authorization?.isAuthorized == true && !referenceAvailable;
    final authorized =
        authorization?.isAuthorized == true && referenceAvailable;
    final pending =
        authorization?.enabled == true && !authorized && !staleReference;
    final status = authorized
        ? '已确认生效'
        : staleReference
        ? '参考图已变化，需重新确认'
        : pending
        ? '等待明确确认'
        : authorization?.status == ReplicateAuthorizationStatus.revoked
        ? '已撤销'
        : '未启用';
    return DecoratedBox(
      key: ValueKey('product-mark-authorization-${shot.id}-$slotIndex'),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: authorized
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '产品${ScriptAssetSlotPolicy.characterSuffix(slotIndex)} · $status',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: authorized ? scheme.primary : null,
                    ),
                  ),
                  if (authorization != null && authorization.enabled)
                    Text(
                      [
                        authorization.location,
                        authorization.allowedTypes
                            .map(_markTypeLabel)
                            .join('、'),
                        if (authorization.exactText.isNotEmpty)
                          '“${authorization.exactText}”',
                      ].where((text) => text.trim().isNotEmpty).join(' · '),
                      style: Theme.of(context).textTheme.labelSmall,
                    )
                  else
                    Text(
                      options.isEmpty ? '请先绑定本产品的主图或细节图。' : '不会生成或继承任何产品文字与标识。',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
            if (authorization?.enabled == true)
              TextButton(
                key: ValueKey('revoke-product-mark-${shot.id}-$slotIndex'),
                onPressed: () => onSave(
                  authorization!.copyWith(
                    enabled: false,
                    status: ReplicateAuthorizationStatus.revoked,
                    clearConfirmedAt: true,
                  ),
                ),
                child: const Text('撤销'),
              ),
            OutlinedButton(
              key: ValueKey('configure-product-mark-${shot.id}-$slotIndex'),
              onPressed: options.isEmpty
                  ? null
                  : () => _showAuthorizationDialog(
                      context,
                      slotIndex: slotIndex,
                      authorization: authorization,
                      options: options,
                    ),
              child: Text(authorization == null ? '配置' : '编辑'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAuthorizationDialog(
    BuildContext context, {
    required int slotIndex,
    required ReplicateProductMarkAuthorization? authorization,
    required List<_ProductMarkReferenceOption> options,
  }) async {
    var enabled = authorization?.enabled ?? true;
    var selectedReferenceId =
        options.any(
          (option) => option.assetId == authorization?.referenceAssetId,
        )
        ? authorization!.referenceAssetId
        : options.first.assetId;
    final selectedTypes = <ReplicateAuthorizedMarkType>{
      ...?authorization?.allowedTypes,
    };
    final exactTextController = TextEditingController(
      text: authorization?.exactText ?? '',
    );
    final locationController = TextEditingController(
      text: authorization?.location ?? '',
    );
    String errorText = '';
    final result = await showDialog<ReplicateProductMarkAuthorization>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          ReplicateProductMarkAuthorization draft(
            ReplicateAuthorizationStatus status,
          ) => ReplicateProductMarkAuthorization(
            productSlotIndex: slotIndex,
            enabled: enabled,
            referenceAssetId: selectedReferenceId,
            exactText: exactTextController.text,
            allowedTypes: selectedTypes.toList(),
            status: status,
            confirmedAt: status == ReplicateAuthorizationStatus.confirmed
                ? DateTime.now().toUtc()
                : null,
            location: locationController.text,
          );

          void confirm() {
            final requiresText = selectedTypes.any(
              (type) => type != ReplicateAuthorizedMarkType.logo,
            );
            final error = !enabled
                ? '请先启用授权白名单。'
                : selectedTypes.isEmpty
                ? '请至少选择一种允许的标识类型。'
                : locationController.text.trim().isEmpty
                ? '请填写标识在产品上的准确位置。'
                : requiresText && exactTextController.text.trim().isEmpty
                ? '名称、型号或包装文字必须填写逐字准确文本。'
                : '';
            if (error.isNotEmpty) {
              setDialogState(() => errorText = error);
              return;
            }
            Navigator.of(
              dialogContext,
            ).pop(draft(ReplicateAuthorizationStatus.confirmed));
          }

          return AlertDialog(
            title: Text(
              '产品${ScriptAssetSlotPolicy.characterSuffix(slotIndex)}标识授权',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: ValueKey(
                        'enable-product-mark-${shot.id}-$slotIndex',
                      ),
                      contentPadding: EdgeInsets.zero,
                      value: enabled,
                      onChanged: (value) => setDialogState(() {
                        enabled = value;
                        errorText = '';
                      }),
                      title: const Text('启用本产品授权白名单'),
                      subtitle: const Text('关闭时保持零文字、零标识。'),
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'product-mark-reference-${shot.id}-$slotIndex',
                      ),
                      initialValue: selectedReferenceId,
                      decoration: const InputDecoration(labelText: '权威参考图'),
                      items: [
                        for (final option in options)
                          DropdownMenuItem(
                            value: option.assetId,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: enabled
                          ? (value) => setDialogState(() {
                              selectedReferenceId =
                                  value ?? selectedReferenceId;
                              errorText = '';
                            })
                          : null,
                    ),
                    const SizedBox(height: 12),
                    const Text('允许的标识类型'),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final type in ReplicateAuthorizedMarkType.values)
                          FilterChip(
                            key: ValueKey(
                              'product-mark-type-${shot.id}-$slotIndex-${type.name}',
                            ),
                            label: Text(_markTypeLabel(type)),
                            selected: selectedTypes.contains(type),
                            onSelected: enabled
                                ? (selected) => setDialogState(() {
                                    selected
                                        ? selectedTypes.add(type)
                                        : selectedTypes.remove(type);
                                    errorText = '';
                                  })
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: ValueKey(
                        'product-mark-location-${shot.id}-$slotIndex',
                      ),
                      controller: locationController,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: '准确位置（必填）',
                        hintText: '例如：鞋舌正面、包装盒右下角',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: ValueKey(
                        'product-mark-exact-text-${shot.id}-$slotIndex',
                      ),
                      controller: exactTextController,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: '逐字文本',
                        hintText: '名称、型号或包装文字必填；纯图形 Logo 可留空',
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '确认后只授权所选产品槽位、参考图、类型、位置和逐字文本的交集；不会授权素材中的其他文字或标识。',
                    ),
                    if (errorText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText,
                        key: ValueKey(
                          'product-mark-error-${shot.id}-$slotIndex',
                        ),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                key: ValueKey(
                  'save-pending-product-mark-${shot.id}-$slotIndex',
                ),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(draft(ReplicateAuthorizationStatus.unconfirmed)),
                child: const Text('保存待确认'),
              ),
              FilledButton(
                key: ValueKey('confirm-product-mark-${shot.id}-$slotIndex'),
                onPressed: confirm,
                child: const Text('确认并授权'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null) onSave(result);
  }

  static String _markTypeLabel(ReplicateAuthorizedMarkType type) =>
      switch (type) {
        ReplicateAuthorizedMarkType.logo => 'Logo/图形商标',
        ReplicateAuthorizedMarkType.productName => '产品名称',
        ReplicateAuthorizedMarkType.model => '型号',
        ReplicateAuthorizedMarkType.packagingText => '包装文字',
      };
}

class _ShotFrameGuidePanel extends StatelessWidget {
  const _ShotFrameGuidePanel({
    required this.shot,
    required this.guide,
    required this.isCurrent,
    required this.onToggleElement,
    required this.onAddElement,
  });

  final ScriptShot shot;
  final ReplicateShotGuide? guide;
  final bool isCurrent;
  final void Function(String elementId, bool selected) onToggleElement;
  final ValueChanged<String> onAddElement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = guide?.analysisStatus == ProcessingStatus.failed;
    final hasResult = guide?.analysisStatus == ProcessingStatus.completed;
    final elements = guide?.elements ?? const <ReplicatePreservedElement>[];
    final stale = guide != null && !isCurrent;
    return DecoratedBox(
      key: ValueKey('replicate-frame-guide-${shot.id}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: stale || failed
              ? scheme.error.withValues(alpha: 0.55)
              : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.accessibility_new_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '原帧配饰/道具白名单',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (stale)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '原视频帧已改变，当前勾选和动作约束不会用于复刻，请重新解析。',
                  key: ValueKey('replicate-frame-guide-stale-${shot.id}'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  guide!.errorMessage.isEmpty
                      ? '原帧分析失败，请重试。'
                      : guide!.errorMessage,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            if (elements.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '勾选后才允许保留；未勾选会移除：',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  for (final element in elements)
                    FilterChip(
                      key: ValueKey(
                        'preserved-element-${shot.id}-${element.id}',
                      ),
                      selected: element.selected,
                      onSelected: stale
                          ? null
                          : (selected) => onToggleElement(element.id, selected),
                      avatar: element.isManual
                          ? const Icon(Icons.edit_rounded, size: 14)
                          : null,
                      label: Text(element.label),
                      tooltip: [
                        element.description,
                        element.location,
                        element.relationship,
                      ].where((text) => text.trim().isNotEmpty).join('；'),
                    ),
                  ActionChip(
                    key: ValueKey('add-preserved-element-${shot.id}'),
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('手动补充'),
                    onPressed: stale ? null : () => _showAddDialog(context),
                  ),
                ],
              ),
            ] else if (hasResult && isCurrent) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(child: Text('未识别到独立配饰或关键道具。')),
                  TextButton.icon(
                    onPressed: () => _showAddDialog(context),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('手动补充'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final textController = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动补充保留元素'),
        content: TextField(
          key: ValueKey('manual-preserved-element-input-${shot.id}'),
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '例如：黑色手提包、白色运动鞋'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: ValueKey('save-manual-preserved-element-${shot.id}'),
            onPressed: () =>
                Navigator.of(context).pop(textController.text.trim()),
            child: const Text('添加并勾选'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (label != null && label.trim().isNotEmpty) onAddElement(label);
  }
}

class _DetectedSubjectAssetEmptyState extends StatelessWidget {
  const _DetectedSubjectAssetEmptyState({
    required this.guideIsCurrent,
    required this.analysisStatus,
  });

  final bool guideIsCurrent;
  final ProcessingStatus? analysisStatus;

  @override
  Widget build(BuildContext context) {
    final message = !guideIsCurrent
        ? '请先分析原帧，识别到的人物和产品会在这里自动创建资产格。'
        : analysisStatus == ProcessingStatus.running
        ? '正在识别原帧人物和产品…'
        : analysisStatus == ProcessingStatus.failed
        ? '原帧识别失败，请重新解析。'
        : '未识别到需要保留、替换或移除的人物和产品。';
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 520),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

class _DetectedSubjectAssetSlot extends StatelessWidget {
  const _DetectedSubjectAssetSlot({
    super.key,
    required this.decisionKey,
    required this.pickerKey,
    required this.removeKey,
    required this.subject,
    required this.asset,
    required this.link,
    required this.accepts,
    required this.onTap,
    required this.onDrop,
    required this.onRemove,
    required this.onRemoveSlot,
    required this.onDecisionChanged,
  });

  final Key decisionKey;
  final Key pickerKey;
  final Key removeKey;
  final ReplicateDetectedSubject subject;
  final ScriptAsset? asset;
  final ScriptShotAssetLink? link;
  final bool Function(ShootingAssetLibraryItem item) accepts;
  final VoidCallback? onTap;
  final Future<void> Function(ShootingAssetLibraryItem item) onDrop;
  final VoidCallback? onRemove;
  final VoidCallback onRemoveSlot;
  final ValueChanged<ReplicateSubjectDecision> onDecisionChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typeLabel = subject.type == ReplicateSubjectType.person
        ? '人物 ${subject.slotIndex + 1}'
        : '产品 ${subject.slotIndex + 1}';
    final helper = [
      subject.location,
      subject.relationship,
    ].where((text) => text.trim().isNotEmpty).join('；');
    final bound = asset != null && link != null;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => unawaited(onDrop(details.data)),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return SizedBox(
          width: 210,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: active
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: active ? scheme.primary : scheme.outlineVariant,
                width: active ? 1.5 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '$typeLabel · ${subject.label}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        key: removeKey,
                        tooltip: '移除资产参考图格子',
                        onPressed: onRemoveSlot,
                        icon: const Icon(Icons.close_rounded, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  if (helper.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      helper,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 108,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Material(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(7),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: pickerKey,
                              onTap: onTap,
                              child: bound
                                  ? Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            child: _BindingAssetPreview(
                                              path: asset!.path,
                                              label: asset!.name,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            asset!.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            subject.type ==
                                                    ReplicateSubjectType.person
                                                ? Icons.person_add_alt_1_rounded
                                                : Icons.inventory_2_outlined,
                                            size: 24,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            active ? '松开绑定' : '点击绑定替换资产',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelSmall,
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        if (onRemove != null)
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
                  ),
                  const SizedBox(height: 7),
                  InputDecorator(
                    key: decisionKey,
                    decoration: const InputDecoration(
                      labelText: '处理方式',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<ReplicateSubjectDecision>(
                        value: subject.decision,
                        isDense: true,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                            value: ReplicateSubjectDecision.undecided,
                            child: Text('请选择处理方式'),
                          ),
                          DropdownMenuItem(
                            value: ReplicateSubjectDecision.keep,
                            child: Text('保留（沿用原视频帧）'),
                          ),
                          DropdownMenuItem(
                            value: ReplicateSubjectDecision.replace,
                            child: Text('替换（必须绑定对应资产）'),
                          ),
                          DropdownMenuItem(
                            value: ReplicateSubjectDecision.remove,
                            child: Text('从画面移除'),
                          ),
                        ],
                        onChanged: (decision) {
                          if (decision != null) {
                            onDecisionChanged(decision);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ShotReplicationInstructionsField extends StatefulWidget {
  const _ShotReplicationInstructionsField({
    super.key,
    required this.value,
    required this.onCommit,
    this.quickMode = false,
  });

  final String value;
  final ValueChanged<String> onCommit;
  final bool quickMode;

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
      decoration: InputDecoration(
        labelText: widget.quickMode ? '补充说明（可选）' : '复刻补充说明',
        hintText: widget.quickMode
            ? '例如：图3的模特穿图4的裤子，在图2的场景中做图1的动作'
            : '仅影响本镜头之后的复刻…',
        alignLabelWithHint: true,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
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
    required this.onOpenOriginalFrame,
    required this.onOpenReplicatedFrame,
    this.numberedOriginal = false,
  });

  final ScriptShot shot;
  final ScriptShot? tailShot;
  final ReplicatedShotImage? replicatedImage;
  final ReplicatedShotImage? tailReplicatedImage;
  final bool startEndFrameMode;
  final ValueChanged<ScriptShot> onOpenOriginalFrame;
  final ValueChanged<ScriptShot> onOpenReplicatedFrame;
  final bool numberedOriginal;

  @override
  Widget build(BuildContext context) {
    if (!startEndFrameMode) {
      return SizedBox(
        width: 292,
        height: 118,
        child: Row(
          children: [
            Expanded(
              child: _ShotFrameThumbnail(
                key: ValueKey('prepare-asset-original-frame-${shot.id}'),
                path: shot.framePath,
                label: numberedOriginal ? '图1 · 原分镜' : '原视频帧',
                emptyIcon: Icons.video_library_outlined,
                onTap: () => onOpenOriginalFrame(shot),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ShotFrameThumbnail(
                key: ValueKey('prepare-asset-replica-frame-${shot.id}'),
                path: _completedReplicatedPath(replicatedImage),
                label: '复刻分镜',
                emptyIcon: Icons.auto_awesome_outlined,
                onTap: () => onOpenReplicatedFrame(shot),
              ),
            ),
          ],
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
          onTap: () => onOpenOriginalFrame(shot),
        ),
        _smallFrame(
          shot: tailShot ?? shot,
          path: tailShot?.framePath ?? '',
          label: tailShot == null ? '无尾帧' : '尾帧',
          icon: Icons.video_library_outlined,
          onTap: tailShot == null ? null : () => onOpenOriginalFrame(tailShot!),
        ),
        _smallFrame(
          shot: shot,
          path: firstReplicaPath,
          label: '复刻首帧',
          icon: Icons.auto_awesome_outlined,
          onTap: () => onOpenReplicatedFrame(shot),
        ),
        _smallFrame(
          shot: tailShot ?? shot,
          path: tailShot == null ? '' : tailReplicaPath,
          label: tailShot == null ? '待尾帧' : '复刻尾帧',
          icon: Icons.auto_awesome_outlined,
          onTap: tailShot == null
              ? null
              : () => onOpenReplicatedFrame(tailShot!),
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
    return path;
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

class _QuickAssetBindingCard extends StatefulWidget {
  const _QuickAssetBindingCard({
    super.key,
    required this.asset,
    required this.link,
    required this.imageNumber,
    required this.selectedRoleLabel,
    required this.groupLabel,
    required this.onTap,
    required this.onRemove,
    required this.onDrop,
    required this.onRoleChanged,
    required this.onDescriptionChanged,
  });

  final ScriptAsset asset;
  final ScriptShotAssetLink link;
  final int imageNumber;
  final String? selectedRoleLabel;
  final String? groupLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final ValueChanged<ShootingAssetLibraryItem> onDrop;
  final ValueChanged<QuickReferenceRole> onRoleChanged;
  final ValueChanged<String> onDescriptionChanged;

  @override
  State<_QuickAssetBindingCard> createState() => _QuickAssetBindingCardState();
}

class _QuickAssetBindingCardState extends State<_QuickAssetBindingCard> {
  late final TextEditingController _description;
  late final FocusNode _descriptionFocus;
  late String _lastDescription;

  @override
  void initState() {
    super.initState();
    _lastDescription = widget.link.quickDescription;
    _description = TextEditingController(text: _lastDescription);
    _descriptionFocus = FocusNode()..addListener(_handleDescriptionFocus);
  }

  @override
  void didUpdateWidget(covariant _QuickAssetBindingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = widget.link.quickDescription;
    if (!_descriptionFocus.hasFocus && _description.text != value) {
      _description.text = value;
      _lastDescription = value;
    }
  }

  @override
  void dispose() {
    _descriptionFocus
      ..removeListener(_handleDescriptionFocus)
      ..dispose();
    _description.dispose();
    super.dispose();
  }

  void _handleDescriptionFocus() {
    if (!_descriptionFocus.hasFocus) _commitDescription();
  }

  void _commitDescription() {
    final value = _description.text.trim();
    if (value == _lastDescription) return;
    _lastDescription = value;
    widget.onDescriptionChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => widget.onDrop(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 190,
          height: 286,
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: active ? scheme.primaryContainer : scheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? scheme.primary : scheme.outlineVariant,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 26,
                child: Row(
                  children: [
                    Text(
                      '图${widget.imageNumber}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '移除资产图',
                      onPressed: widget.onRemove,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onTap,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _BindingAssetPreview(
                        path: widget.asset.path,
                        label: widget.asset.name,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.asset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              DropdownButtonFormField<QuickReferenceRole>(
                key: ValueKey(
                  'quick-reference-role-${widget.link.shotId}-${widget.link.scriptAssetId}',
                ),
                initialValue:
                    widget.link.quickReferenceRole ??
                    QuickReferenceRole.otherReference,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '类型',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                ),
                items: [
                  for (final role in QuickReferenceRole.values)
                    DropdownMenuItem(value: role, child: Text(role.label)),
                ],
                selectedItemBuilder: (context) => [
                  for (final role in QuickReferenceRole.values)
                    Text(
                      role == QuickReferenceRole.model &&
                              widget.selectedRoleLabel != null
                          ? widget.selectedRoleLabel!
                          : role.label,
                    ),
                ],
                onChanged: (role) {
                  if (role != null && role != widget.link.quickReferenceRole) {
                    widget.onRoleChanged(role);
                  }
                },
              ),
              const SizedBox(height: 5),
              TextField(
                key: ValueKey(
                  'quick-reference-description-${widget.link.shotId}-${widget.link.scriptAssetId}',
                ),
                controller: _description,
                focusNode: _descriptionFocus,
                minLines: 1,
                maxLines: 2,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commitDescription(),
                onTapOutside: (_) {
                  _commitDescription();
                  _descriptionFocus.unfocus();
                },
                decoration: const InputDecoration(
                  labelText: '描述（可选）',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.groupLabel != null) ...[
                const SizedBox(height: 5),
                Tooltip(
                  message: widget.link.quickGroupWarning.isEmpty
                      ? '系统自动归组结果'
                      : widget.link.quickGroupWarning,
                  child: Row(
                    children: [
                      Icon(
                        widget.link.quickGroupWarning.isEmpty
                            ? Icons.account_tree_outlined
                            : Icons.warning_amber_rounded,
                        size: 14,
                        color: widget.link.quickGroupWarning.isEmpty
                            ? scheme.primary
                            : scheme.error,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.groupLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AssetBindingSlot extends StatelessWidget {
  const _AssetBindingSlot({
    super.key,
    required this.asset,
    required this.link,
    required this.slotLabel,
    required this.onTap,
    required this.onRemove,
    required this.onDrop,
    this.accepts,
  });

  final ScriptAsset asset;
  final ScriptShotAssetLink link;
  final String slotLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final ValueChanged<ShootingAssetLibraryItem> onDrop;
  final bool Function(ShootingAssetLibraryItem item)? accepts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (details) => accepts?.call(details.data) ?? true,
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 142,
          height: 136,
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
                        Text(
                          slotLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 3),
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

class _SkeletonAssetSlot extends StatelessWidget {
  const _SkeletonAssetSlot({
    super.key,
    required this.path,
    required this.onTap,
    this.onEdit,
    required this.onRemove,
  });

  final String path;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 142,
      height: 136,
      child: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Tooltip(
                message: 'DWPose 骨架，点击全屏浏览',
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '动作骨架',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Expanded(
                          child: _BindingAssetPreview(
                            path: path,
                            label: 'DWPose 骨架',
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'DWPose 骨架',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '姿态参考 · 点击放大',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: IconButton(
              key: const ValueKey('edit-pose-joints'),
              tooltip: onEdit == null ? '暂无可编辑关节数据' : '编辑动作关节',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: '移除动作骨架',
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 15),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAssetBindingSlot extends StatelessWidget {
  const _EmptyAssetBindingSlot({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    required this.onDrop,
    this.accepts,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final ValueChanged<ShootingAssetLibraryItem> onDrop;
  final bool Function(ShootingAssetLibraryItem item)? accepts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ShootingAssetLibraryItem>(
      onWillAcceptWithDetails: (details) => accepts?.call(details.data) ?? true,
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidateData, _) {
        final active = candidateData.isNotEmpty;
        return SizedBox(
          width: 142,
          height: 136,
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
                      Icon(icon, size: 24),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: active ? scheme.primary : null,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        active ? '松开绑定' : '拖入或点击选择',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
    final exists = _fileExists(context, path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: exists
            ? Image.file(
                File(path),
                fit: BoxFit.contain,
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
  ReplicateController controller, {
  ReplicationGenerationMode mode = ReplicationGenerationMode.precise,
}) async {
  final confirmed = state.confirmedShots.length;
  final existing = state.replicatedImages
      .where((image) => image.status == ProcessingStatus.completed)
      .length;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        mode == ReplicationGenerationMode.quick ? '确认快速复刻' : '确认精确复刻',
      ),
      content: Text(
        '${mode == ReplicationGenerationMode.quick ? '每个镜头提交原帧、编号参考图和一句话说明；已完成的一键解析只用于生成快速资产槽位，不执行骨架与自动纠偏。\n\n' : ''}'
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
  if (accepted == true) {
    mode == ReplicationGenerationMode.quick
        ? await controller.replicateAllShotsQuick()
        : await controller.replicateAllShots();
  }
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
            title: '步骤 2 · 查阅脚本镜头',
            subtitle: '请自行查阅并编辑镜头内容，修改会同步回拍摄脚本。',
            actions: [
              FilledButton.icon(
                key: const ValueKey('replicate-next-assets'),
                onPressed: state.shots.isEmpty
                    ? null
                    : () => controller.moveToStep(ReplicateStep.generateVideos),
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
                width: 2400,
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
        _HeaderCell('搭配', 120),
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
              value: shot.productStyling,
              width: 120,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(productStyling: value)),
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
            title: '步骤 1 · 准备参考素材',
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
                          item.path.isNotEmpty,
                    )
                    ? () => controller.moveToStep(ReplicateStep.confirmShots)
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
                      fit: BoxFit.contain,
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
    final usesOfficialH3 = controller.usesOfficialH3PromptWriting;
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 3 · 合成可灵 / H3 / 即梦提示词',
            subtitle:
                '${state.run!.globalStyle} · ${usesOfficialH3 ? 'H3 格式 · 本地字段拼接' : '本地结构化拼接'}',
            actions: [
              FilledButton.icon(
                key: const ValueKey('compose-all-seedance-prompts'),
                onPressed: state.isBusy ? null : controller.composeAllPrompts,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  state.prompts.isEmpty
                      ? usesOfficialH3
                            ? '拼接全部 H3 提示词'
                            : '本地拼接全部'
                      : usesOfficialH3
                      ? '重新拼接 H3 提示词'
                      : '重新本地拼接',
                ),
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
                    usesOfficialH3: usesOfficialH3,
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
  const _EmptyPrompts({required this.usesOfficialH3, required this.onGenerate});

  final bool usesOfficialH3;
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
        Text(
          usesOfficialH3
              ? '视觉解析已在构建脚本阶段完成；此处只读取结构化字段，在本地按 H3 格式顺序拼接。'
              : '视觉解析已在构建脚本阶段完成；此处只从数据库读取脚本字段并在本地拼接。',
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onGenerate,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(usesOfficialH3 ? '拼接全部 H3 提示词' : '本地拼接全部提示词'),
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

class _ResizableStepRightPanel extends ConsumerStatefulWidget {
  const _ResizableStepRightPanel({
    required this.uiStateKey,
    required this.content,
    required this.panelBuilder,
    required this.resizeHandleKey,
    required this.expandButtonKey,
    required this.collapsedLabel,
    required this.defaultWidth,
    required this.compactBreakpoint,
    required this.compactHeight,
    this.minPanelWidth = 280,
  });

  final String uiStateKey;
  final Widget content;
  final Widget Function(BuildContext context, VoidCallback onToggleCollapsed)
  panelBuilder;
  final Key resizeHandleKey;
  final Key expandButtonKey;
  final String collapsedLabel;
  final double defaultWidth;
  final double compactBreakpoint;
  final double compactHeight;
  final double minPanelWidth;

  @override
  ConsumerState<_ResizableStepRightPanel> createState() =>
      _ResizableStepRightPanelState();
}

class _ResizableStepRightPanelState
    extends ConsumerState<_ResizableStepRightPanel> {
  static const _collapsedWidth = 52.0;
  static const _handleWidth = 10.0;
  static const _gap = 0.0;

  late double _panelWidth = widget.defaultWidth;
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    try {
      _collapsed =
          ref.read(appDatabaseProvider).getSetting(widget.uiStateKey) == 'true';
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常恢复。
    }
  }

  @override
  Widget build(BuildContext context) => CollapsiblePanelRegistration(
    expanded: !_collapsed,
    onExpandedChanged: _setExpanded,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final panel = widget.panelBuilder(context, _toggleCollapsed);
        if (constraints.maxWidth < widget.compactBreakpoint) {
          return Column(
            children: [
              Expanded(child: widget.content),
              const Divider(height: 1),
              if (_collapsed)
                SizedBox(
                  height: _collapsedWidth,
                  child: Row(
                    children: [
                      IconButton(
                        key: widget.expandButtonKey,
                        tooltip: '展开${widget.collapsedLabel}',
                        onPressed: () => _setExpanded(true),
                        icon: const Icon(
                          Icons.keyboard_double_arrow_up_rounded,
                        ),
                      ),
                      Text(
                        widget.collapsedLabel,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                )
              else
                SizedBox(height: widget.compactHeight, child: panel),
            ],
          );
        }

        final maximumWidth = math.max(
          widget.minPanelWidth,
          constraints.maxWidth - 520 - _handleWidth - _gap,
        );
        final panelWidth = _panelWidth
            .clamp(widget.minPanelWidth, maximumWidth)
            .toDouble();
        final rightPanel = _collapsed
            ? _CollapsedStepRightPanel(
                label: widget.collapsedLabel,
                expandButtonKey: widget.expandButtonKey,
                onExpand: () => _setExpanded(true),
              )
            : SizedBox(width: panelWidth, child: panel);
        return Row(
          children: [
            Expanded(child: widget.content),
            _StepRightPanelResizeHandle(
              key: widget.resizeHandleKey,
              enabled: !_collapsed,
              onDrag: (delta) => setState(() {
                _panelWidth = (panelWidth - delta)
                    .clamp(widget.minPanelWidth, maximumWidth)
                    .toDouble();
              }),
            ),
            rightPanel,
          ],
        );
      },
    ),
  );

  void _toggleCollapsed() {
    _setExpanded(_collapsed);
  }

  void _setExpanded(bool expanded) {
    if (_collapsed == !expanded) {
      return;
    }
    setState(() => _collapsed = !expanded);
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(widget.uiStateKey, _collapsed.toString());
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }
}

class _StepRightPanelResizeHandle extends StatelessWidget {
  const _StepRightPanelResizeHandle({
    super.key,
    required this.enabled,
    required this.onDrag,
  });

  final bool enabled;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: enabled
            ? (details) => onDrag(details.delta.dx)
            : null,
        child: SizedBox(
          width: _ResizableStepRightPanelState._handleWidth,
          child: Center(
            child: Container(
              width: 1,
              height: double.infinity,
              color: scheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedStepRightPanel extends StatelessWidget {
  const _CollapsedStepRightPanel({
    required this.label,
    required this.expandButtonKey,
    required this.onExpand,
  });

  final String label;
  final Key expandButtonKey;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _ResizableStepRightPanelState._collapsedWidth,
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: Column(
          children: [
            const SizedBox(height: 8),
            IconButton(
              key: expandButtonKey,
              tooltip: '展开$label',
              onPressed: onExpand,
              icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: RotatedBox(
                quarterTurns: 1,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _CommitCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        _text.text != widget.value &&
        !_focusNode.hasFocus &&
        !_hasActiveComposing(_text)) {
      _replaceControllerText(_text, widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
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
        focusNode: _focusNode,
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

extension on QuickReferenceRole {
  String get label => switch (this) {
    QuickReferenceRole.model => '模特',
    QuickReferenceRole.scene => '场景',
    QuickReferenceRole.clothing => '服装',
    QuickReferenceRole.shoes => '鞋子',
    QuickReferenceRole.accessory => '配饰',
    QuickReferenceRole.product => '产品',
    QuickReferenceRole.productDetail => '产品细节',
    QuickReferenceRole.prop => '道具',
    QuickReferenceRole.styleReference => '风格参考',
    QuickReferenceRole.otherReference => '其他参考',
  };
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
