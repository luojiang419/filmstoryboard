import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../shooting_script/domain/shooting_script_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../application/replicate_controller.dart';
import '../data/seedance_prompt_generation_service.dart';
import '../domain/replicate_models.dart';

class ReplicatePage extends ConsumerStatefulWidget {
  const ReplicatePage({super.key, this.onOpenShootingScript});

  final VoidCallback? onOpenShootingScript;

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
  String _lastNotice = '';

  @override
  void initState() {
    super.initState();
    _controller = ref.read(replicateControllerProvider)
      ..addListener(_showControllerNotice);
  }

  @override
  void dispose() {
    _controller.removeListener(_showControllerNotice);
    super.dispose();
  }

  void _showControllerNotice() {
    if (!mounted) return;
    final state = _controller.value;
    final notice = state.errorMessage.isNotEmpty
        ? 'error:${state.errorMessage}'
        : state.message.isNotEmpty
        ? 'message:${state.message}'
        : '';
    if (notice.isEmpty || notice == _lastNotice) return;
    _lastNotice = notice;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          state.errorMessage.isNotEmpty ? state.errorMessage : state.message,
        ),
        backgroundColor: state.errorMessage.isNotEmpty
            ? Theme.of(context).colorScheme.error
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(replicateControllerProvider);
    return ValueListenableBuilder<ReplicateState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.scripts.isEmpty) {
          return _NoScriptState(
            onOpenShootingScript: widget.onOpenShootingScript,
          );
        }
        final run = state.run;
        if (run == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Padding(
          key: const ValueKey('replicate-page'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PageHeader(state: state, controller: controller),
              const SizedBox(height: 12),
              _StepBar(state: state, controller: controller),
              const SizedBox(height: 12),
              if (state.isBusy) const LinearProgressIndicator(minHeight: 3),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: switch (run.currentStep) {
                    ReplicateStep.confirmShots => _ConfirmShotsStep(
                      key: const ValueKey('replicate-confirm-shots-step'),
                      state: state,
                      controller: controller,
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
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importAssets(ReplicateAssetType type) async {
    final files = await openFiles(acceptedTypeGroups: const [_assetTypes]);
    for (final file in files) {
      await _controller.importAsset(
        sourcePath: file.path,
        type: _normalizedTypeForPath(type, file.path),
      );
    }
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
      allowTypeChange: false,
    );
    if (result == null) return;
    _controller.updateAsset(
      asset.copyWith(name: result.name, description: result.description),
    );
  }

  Future<void> _replaceAsset(ReplicateAsset asset) async {
    final file = await openFile(acceptedTypeGroups: const [_assetTypes]);
    if (file != null) {
      await _controller.replaceAssetFile(asset.id, file.path);
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
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制全部提示词')));
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
  const _PageHeader({required this.state, required this.controller});

  final ReplicateState state;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '一键复刻',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const Text(
              '从已整理的拍摄脚本出发，逐镜生成可直接使用的 Seedance 2 提示词。',
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
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: selector),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            SizedBox(width: 320, child: selector),
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
    return SizedBox(
      height: 94,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _StepCard(
            number: 1,
            title: '确认镜头',
            summary: '${run.confirmedShotIds.length}/${state.shots.length} 已确认',
            status: run.confirmShotsStatus,
            selected: run.currentStep == ReplicateStep.confirmShots,
            onTap: () => controller.moveToStep(ReplicateStep.confirmShots),
          ),
          const _StepConnector(),
          _StepCard(
            number: 2,
            title: '准备素材',
            summary:
                '${state.assets.where((item) => item.status == ProcessingStatus.completed).length}/${state.assets.length} 可用',
            status: run.prepareAssetsStatus,
            selected: run.currentStep == ReplicateStep.prepareAssets,
            onTap: () => controller.moveToStep(ReplicateStep.prepareAssets),
          ),
          const _StepConnector(),
          _StepCard(
            number: 3,
            title: '合成提示词',
            summary: '${run.completedCount}/${run.totalCount} 已合成',
            status: run.composePromptsStatus,
            selected: run.currentStep == ReplicateStep.composePrompts,
            onTap: () => controller.moveToStep(ReplicateStep.composePrompts),
          ),
        ],
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
      width: 230,
      child: Card(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: selected
                      ? scheme.primary
                      : scheme.secondaryContainer,
                  foregroundColor: selected
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                  child: Text('$number'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(summary),
                      Text(
                        status.label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: status.color(scheme),
                        ),
                      ),
                    ],
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

class _StepConnector extends StatelessWidget {
  const _StepConnector();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 42,
    child: Divider(color: Theme.of(context).colorScheme.outlineVariant),
  );
}

class _ConfirmShotsStep extends StatelessWidget {
  const _ConfirmShotsStep({
    super.key,
    required this.state,
    required this.controller,
  });

  final ReplicateState state;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final confirmed = state.run!.confirmedShotIds.toSet();
    return _WorkspacePanel(
      child: Column(
        children: [
          _StepToolbar(
            title: '步骤 1 · 核对并确认脚本镜头',
            subtitle: '修改会同步回拍摄脚本；只有勾选的镜头进入提示词生成。',
            actions: [
              OutlinedButton.icon(
                onPressed: state.shots.isEmpty
                    ? null
                    : controller.confirmAllShots,
                icon: const Icon(Icons.done_all_rounded),
                label: const Text('全部确认'),
              ),
              OutlinedButton.icon(
                onPressed: confirmed.isEmpty
                    ? null
                    : controller.clearConfirmedShots,
                icon: const Icon(Icons.remove_done_rounded),
                label: const Text('清除确认'),
              ),
              FilledButton.icon(
                key: const ValueKey('replicate-next-assets'),
                onPressed: confirmed.isEmpty
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
                width: 1260,
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
                                  confirmed: confirmed.contains(shot.id),
                                  controller: controller,
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
        _HeaderCell('确认', 62),
        _HeaderCell('镜号', 66),
        _HeaderCell('时长', 80),
        _HeaderCell('画面描述', 270),
        _HeaderCell('景别', 110),
        _HeaderCell('摄影/光影', 190),
        _HeaderCell('对白/旁白', 180),
        _HeaderCell('音效', 150),
        _HeaderCell('运镜', 152),
      ],
    ),
  );
}

class _ConfirmShotRow extends StatelessWidget {
  const _ConfirmShotRow({
    super.key,
    required this.shot,
    required this.confirmed,
    required this.controller,
  });

  final ScriptShot shot;
  final bool confirmed;
  final ReplicateController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: confirmed
          ? scheme.primaryContainer.withValues(alpha: 0.26)
          : Colors.transparent,
      child: SizedBox(
        height: 92,
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Checkbox(
                value: confirmed,
                onChanged: (value) =>
                    controller.toggleShotConfirmed(shot.id, value ?? false),
              ),
            ),
            _TextCell('${shot.shotNumber}'.padLeft(2, '0'), 66),
            _TextCell('${shot.durationSeconds.toStringAsFixed(1)}s', 80),
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
              value: shot.cameraNotes,
              width: 190,
              maxLines: 3,
              onCommit: (value) =>
                  controller.updateShot(shot.copyWith(cameraNotes: value)),
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
            title: '步骤 3 · 合成 Seedance 2 提示词',
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
                label: const Text('导出 TXT/JSON'),
              ),
              IconButton(
                tooltip: '打开提示词目录',
                onPressed: controller.openPromptDirectory,
                icon: const Icon(Icons.folder_open_rounded),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: state.prompts.isEmpty
                ? _EmptyPrompts(onGenerate: controller.composeAllPrompts)
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

  final VoidCallback onGenerate;

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
