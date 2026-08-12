import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';
import 'remote_video_preview.dart';

class VideoGenerationPage extends StatefulWidget {
  const VideoGenerationPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<VideoGenerationPage> createState() => _VideoGenerationPageState();
}

class _VideoGenerationPageState extends State<VideoGenerationPage> {
  RemoteVideoGenerationOptions? _syncedOptions;
  String _syncedScriptId = '';
  String _model = '';
  final Map<String, String> _parameters = {};
  final Map<String, TextEditingController> _parameterControllers = {};
  final Set<String> _selectedGroupIds = {};
  final Map<String, TextEditingController> _promptControllers = {};
  final Map<String, TextEditingController> _durationControllers = {};

  @override
  void dispose() {
    for (final controller in [
      ..._parameterControllers.values,
      ..._promptControllers.values,
      ..._durationControllers.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncRemoteState() {
    final options = widget.controller.videoGenerationOptions;
    if (options == null) return;
    final scriptChanged = options.selectedScriptId != _syncedScriptId;
    if (_syncedOptions == null || scriptChanged) {
      _model = options.selectedModelId;
      _parameters
        ..clear()
        ..addEntries(
          options.parameters.map((item) => MapEntry(item.key, item.value)),
        );
      _selectedGroupIds
        ..clear()
        ..addAll(
          widget.controller.videoGenerationGroups
              .where((group) => group.canGenerate && group.isActive)
              .map((group) => group.id),
        );
    } else {
      final validKeys = options.parameters.map((item) => item.key).toSet();
      _parameters.removeWhere((key, _) => !validKeys.contains(key));
      for (final parameter in options.parameters) {
        _parameters.putIfAbsent(parameter.key, () => parameter.value);
      }
    }
    final validGroupIds = widget.controller.videoGenerationGroups
        .map((group) => group.id)
        .toSet();
    _selectedGroupIds.removeWhere((id) => !validGroupIds.contains(id));
    for (final parameter in options.parameters) {
      final controller = _parameterControllers.putIfAbsent(
        parameter.key,
        () => TextEditingController(),
      );
      final value = _parameters[parameter.key] ?? parameter.value;
      if (controller.text != value) controller.text = value;
    }
    _disposeRemovedControllers(
      _parameterControllers,
      options.parameters.map((item) => item.key).toSet(),
    );
    for (final group in widget.controller.videoGenerationGroups) {
      _promptControllers.putIfAbsent(
        group.id,
        () => TextEditingController(text: group.prompt),
      );
      _durationControllers.putIfAbsent(
        group.id,
        () => TextEditingController(text: _durationText(group.durationSeconds)),
      );
    }
    _disposeRemovedControllers(_promptControllers, validGroupIds);
    _disposeRemovedControllers(_durationControllers, validGroupIds);
    _syncedOptions = options;
    _syncedScriptId = options.selectedScriptId;
  }

  void _disposeRemovedControllers(
    Map<String, TextEditingController> controllers,
    Set<String> validKeys,
  ) {
    final removed = controllers.keys
        .where((key) => !validKeys.contains(key))
        .toList(growable: false);
    for (final key in removed) {
      controllers.remove(key)?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.videoGenerationAvailable) {
      return const _Unavailable();
    }
    _syncRemoteState();
    final options = widget.controller.videoGenerationOptions;
    if (options == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1280;
        final configuration = _ConfigurationPanel(
          controller: widget.controller,
          options: options,
          model: _model,
          parameters: _parameters,
          parameterControllers: _parameterControllers,
          selectedCount: _selectedGroupIds.length,
          onModelChanged: (value) => setState(() => _model = value),
          onParameterChanged: (key, value) => setState(() {
            _parameters[key] = value;
            final textController = _parameterControllers[key];
            if (textController != null && textController.text != value) {
              textController.text = value;
            }
          }),
          onGenerate: _startGeneration,
        );
        final shots = _ShotSelection(
          controller: widget.controller,
          selectedIds: _selectedGroupIds,
          promptControllers: _promptControllers,
          durationControllers: _durationControllers,
          onToggle: (group, selected) => setState(() {
            if (selected) {
              _selectedGroupIds.add(group.id);
            } else {
              _selectedGroupIds.remove(group.id);
            }
          }),
          onSelectAll: () => setState(() {
            _selectedGroupIds.addAll(
              widget.controller.videoGenerationGroups
                  .where((group) => group.canGenerate)
                  .map((group) => group.id),
            );
          }),
          onClear: () => setState(_selectedGroupIds.clear),
        );
        if (wide) {
          return Padding(
            key: const ValueKey('video-generation-page'),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1480),
                child: SizedBox(
                  height: math.max(0, constraints.maxHeight - 60),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('generation-main-scroll'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _PageHeader(
                                controller: widget.controller,
                                options: options,
                              ),
                              const SizedBox(height: 18),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: 330, child: configuration),
                                  const SizedBox(width: 18),
                                  Expanded(child: shots),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      SizedBox(
                        width: 370,
                        child: _WorkManagementPanel(
                          controller: widget.controller,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return SingleChildScrollView(
          key: const ValueKey('video-generation-page'),
          padding: const EdgeInsets.fromLTRB(14, 20, 14, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PageHeader(controller: widget.controller, options: options),
                  const SizedBox(height: 18),
                  configuration,
                  const SizedBox(height: 18),
                  _CompactWorkManagement(controller: widget.controller),
                  const SizedBox(height: 18),
                  shots,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _startGeneration() async {
    final selected = widget.controller.videoGenerationGroups
        .where((group) => _selectedGroupIds.contains(group.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final overrides = <String, RemoteVideoGenerationShotOverride>{};
    for (final group in selected) {
      final prompt = _promptControllers[group.id]!.text.trim();
      final duration = double.tryParse(
        _durationControllers[group.id]!.text.trim(),
      );
      if (duration == null || duration <= 0 || prompt.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${group.title} 的提示词或时长无效')));
        return;
      }
      if (prompt != group.prompt || duration != group.durationSeconds) {
        overrides[group.id] = RemoteVideoGenerationShotOverride(
          prompt: prompt,
          promptMode: prompt == group.prompt ? group.promptMode : 'edited',
          durationSeconds: duration,
        );
      }
    }
    await widget.controller.startVideoGeneration(
      shotIds: selected.map((group) => group.id).toList(growable: false),
      model: _model,
      parameters: Map.unmodifiable(_parameters),
      shotOverrides: overrides,
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.controller, required this.options});

  final RemoteAppController controller;
  final RemoteVideoGenerationOptions options;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '生成视频',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            Text(
              '${options.projectAspectRatio} · ${options.backend.name} · 全部命令由本机执行',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      IconButton.filledTonal(
        key: const ValueKey('refresh-video-generation'),
        tooltip: '刷新生成状态',
        onPressed: controller.videoGenerationCommandBusy
            ? null
            : controller.refreshVideoGeneration,
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
  );
}

class _ConfigurationPanel extends StatelessWidget {
  const _ConfigurationPanel({
    required this.controller,
    required this.options,
    required this.model,
    required this.parameters,
    required this.parameterControllers,
    required this.selectedCount,
    required this.onModelChanged,
    required this.onParameterChanged,
    required this.onGenerate,
  });

  final RemoteAppController controller;
  final RemoteVideoGenerationOptions options;
  final String model;
  final Map<String, String> parameters;
  final Map<String, TextEditingController> parameterControllers;
  final int selectedCount;
  final ValueChanged<String> onModelChanged;
  final void Function(String key, String value) onParameterChanged;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scripts = options.scripts;
    final models = options.models;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.tune_rounded),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    '生成配置',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: options.backend.ready
                        ? const Color(0xffdff6e9)
                        : scheme.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    options.backend.ready ? '后端就绪' : '后端未就绪',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (options.backend.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                options.backend.message,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
              key: const ValueKey('generation-script-select'),
              initialValue:
                  scripts.any((item) => item.id == options.selectedScriptId)
                  ? options.selectedScriptId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '拍摄脚本'),
              items: [
                for (final script in scripts)
                  DropdownMenuItem(value: script.id, child: Text(script.name)),
              ],
              onChanged:
                  controller.canEdit && !controller.videoGenerationCommandBusy
                  ? (value) {
                      if (value != null) {
                        controller.selectVideoGenerationScript(value);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<String>(
              key: const ValueKey('generation-model-select'),
              initialValue: models.any((item) => item.id == model)
                  ? model
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '生成模型'),
              items: [
                for (final item in models)
                  DropdownMenuItem(value: item.id, child: Text(item.name)),
              ],
              onChanged: controller.canEdit
                  ? (value) {
                      if (value != null) onModelChanged(value);
                    }
                  : null,
            ),
            if (options.parameters.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                '模型参数',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              for (final parameter in options.parameters) ...[
                _DynamicParameterField(
                  parameter: parameter,
                  value: parameters[parameter.key] ?? parameter.value,
                  textController: parameterControllers[parameter.key]!,
                  enabled: controller.canEdit,
                  onChanged: (value) =>
                      onParameterChanged(parameter.key, value),
                ),
                const SizedBox(height: 11),
              ],
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('start-video-generation'),
              onPressed:
                  controller.canEdit &&
                      options.backend.ready &&
                      !controller.videoGenerationCommandBusy &&
                      selectedCount > 0 &&
                      model.isNotEmpty
                  ? onGenerate
                  : null,
              icon: controller.videoGenerationCommandBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded),
              label: Text(
                selectedCount == 0 ? '请选择镜头' : '生成 $selectedCount 个镜头组',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DynamicParameterField extends StatelessWidget {
  const _DynamicParameterField({
    required this.parameter,
    required this.value,
    required this.textController,
    required this.enabled,
    required this.onChanged,
  });

  final RemoteVideoGenerationParameter parameter;
  final String value;
  final TextEditingController textController;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final component = parameter.component.toLowerCase();
    if (parameter.options.isNotEmpty ||
        component == 'select' ||
        component == 'radio') {
      final validValue = parameter.options.any((item) => item.value == value)
          ? value
          : null;
      return DropdownButtonFormField<String>(
        key: ValueKey('generation-parameter-${parameter.key}'),
        initialValue: validValue,
        isExpanded: true,
        decoration: InputDecoration(labelText: parameter.label),
        items: [
          for (final option in parameter.options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: enabled
            ? (next) {
                if (next != null) onChanged(next);
              }
            : null,
      );
    }
    if (component == 'switch' || component == 'checkbox') {
      final selected = value == 'true' || value == '1';
      return SwitchListTile.adaptive(
        key: ValueKey('generation-parameter-${parameter.key}'),
        contentPadding: EdgeInsets.zero,
        title: Text(parameter.label),
        value: selected,
        onChanged: enabled ? (next) => onChanged('$next') : null,
      );
    }
    if (component == 'slider' &&
        parameter.min != null &&
        parameter.max != null) {
      final min = parameter.min!.toDouble();
      final max = parameter.max!.toDouble();
      final selected = (double.tryParse(value) ?? min).clamp(min, max);
      final divisions = parameter.step == null || parameter.step == 0
          ? null
          : ((max - min) / parameter.step!.toDouble()).round();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${parameter.label} · ${_durationText(selected)}'),
          Slider(
            key: ValueKey('generation-parameter-${parameter.key}'),
            value: selected,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: enabled
                ? (next) => onChanged(_durationText(next))
                : null,
          ),
        ],
      );
    }
    return TextField(
      key: ValueKey('generation-parameter-${parameter.key}'),
      controller: textController,
      enabled: enabled,
      keyboardType: component == 'number'
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: parameter.label,
        helperText: _rangeLabel(parameter),
      ),
      onChanged: onChanged,
    );
  }
}

class _ShotSelection extends StatelessWidget {
  const _ShotSelection({
    required this.controller,
    required this.selectedIds,
    required this.promptControllers,
    required this.durationControllers,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
  });

  final RemoteAppController controller;
  final Set<String> selectedIds;
  final Map<String, TextEditingController> promptControllers;
  final Map<String, TextEditingController> durationControllers;
  final void Function(RemoteVideoGenerationGroup group, bool selected) onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final groups = controller.videoGenerationGroups;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.view_timeline_outlined),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '镜头选择 · ${selectedIds.length}/${groups.length}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ),
                TextButton(onPressed: onSelectAll, child: const Text('全选')),
                TextButton(onPressed: onClear, child: const Text('清空')),
              ],
            ),
            const SizedBox(height: 12),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: Text('当前拍摄脚本没有可生成镜头')),
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final group in groups)
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width >= 760
                          ? 320
                          : double.infinity,
                      child: _ShotGroupCard(
                        controller: controller,
                        group: group,
                        selected: selectedIds.contains(group.id),
                        promptController: promptControllers[group.id]!,
                        durationController: durationControllers[group.id]!,
                        onChanged: (selected) => onToggle(group, selected),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ShotGroupCard extends StatelessWidget {
  const _ShotGroupCard({
    required this.controller,
    required this.group,
    required this.selected,
    required this.promptController,
    required this.durationController,
    required this.onChanged,
  });

  final RemoteAppController controller;
  final RemoteVideoGenerationGroup group;
  final bool selected;
  final TextEditingController promptController;
  final TextEditingController durationController;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('generation-shot-${group.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: .45)
            : scheme.surfaceContainerLow,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: group.canGenerate
                    ? (value) => onChanged(value ?? false)
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      _shotRange(group.shotNumbers),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              Text('${_durationText(group.durationSeconds)}s'),
            ],
          ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _ReferenceImage(
              controller: controller,
              mediaId: group.referenceImageMediaId,
            ),
          ),
          if (selected) ...[
            const SizedBox(height: 12),
            TextField(
              key: ValueKey('generation-prompt-${group.id}'),
              controller: promptController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '逐镜头提示词'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: ValueKey('generation-duration-${group.id}'),
              controller: durationController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '时长（秒）'),
            ),
          ],
          if (!group.canGenerate) ...[
            const SizedBox(height: 8),
            Text(
              '缺少首帧或提示词，暂不可生成',
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReferenceImage extends StatelessWidget {
  const _ReferenceImage({required this.controller, required this.mediaId});

  final RemoteAppController controller;
  final String? mediaId;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.image_outlined)),
    );
    if (mediaId == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: FutureBuilder<Uint8List>(
        future: controller.mediaBytes(mediaId!),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.isEmpty) return placeholder;
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      ),
    );
  }
}

class _WorkManagementPanel extends StatelessWidget {
  const _WorkManagementPanel({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final taskCount =
        controller.videoGenerationOperations.length +
        controller.videoGenerationTasks.length;
    return Card(
      key: const ValueKey('generation-work-management-panel'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.video_library_outlined, size: 22),
                    SizedBox(width: 9),
                    Text(
                      '作品管理',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '$taskCount 个任务 · ${controller.videoGenerationWorks.length} 个镜头版本',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              key: const ValueKey('generation-work-management-scroll'),
              padding: const EdgeInsets.all(14),
              children: [_WorkManagementSections(controller: controller)],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactWorkManagement extends StatelessWidget {
  const _CompactWorkManagement({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('generation-compact-work-management'),
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      leading: const Icon(Icons.video_library_outlined),
      title: const Text('作品管理', style: TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Text(
        '${controller.videoGenerationTasks.length} 个镜头任务 · '
        '${controller.videoGenerationWorks.length} 个镜头版本',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [_WorkManagementSections(controller: controller)],
    ),
  );
}

class _WorkManagementSections extends StatelessWidget {
  const _WorkManagementSections({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final operations = controller.videoGenerationOperations;
    final tasks = controller.videoGenerationTasks;
    final works = controller.videoGenerationWorks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ManagementSectionHeader(label: '生成任务', count: operations.length),
        if (operations.isEmpty)
          const _ManagementEmpty(message: '还没有浏览器提交任务')
        else
          for (final task in operations)
            _OuterTaskTile(controller: controller, task: task),
        const Divider(height: 28),
        _ManagementSectionHeader(label: '镜头任务', count: tasks.length),
        if (tasks.isEmpty)
          const _ManagementEmpty(message: '还没有视频生成任务')
        else
          for (final task in tasks)
            _GenerationTaskTile(controller: controller, task: task),
        const Divider(height: 28),
        _ManagementSectionHeader(label: '镜头版本', count: works.length),
        if (works.isEmpty)
          const _ManagementEmpty(message: '完成的作品会出现在这里')
        else ...[
          const SizedBox(height: 4),
          for (final work in works) ...[
            _WorkCard(controller: controller, work: work),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }
}

class _ManagementSectionHeader extends StatelessWidget {
  const _ManagementSectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
          ),
        ),
        Text('$count', style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}

class _ManagementEmpty extends StatelessWidget {
  const _ManagementEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

class _OuterTaskTile extends StatelessWidget {
  const _OuterTaskTile({required this.controller, required this.task});

  final RemoteAppController controller;
  final RemoteTask task;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('generation-operation-${task.id}'),
    contentPadding: EdgeInsets.zero,
    leading: const CircleAvatar(child: Icon(Icons.cloud_upload_outlined)),
    title: const Text('浏览器提交操作'),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(task.errorMessage.isNotEmpty ? task.errorMessage : task.message),
        if (!task.terminal) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: task.progress),
        ],
      ],
    ),
    trailing: task.cancellable && controller.canEdit
        ? TextButton(
            onPressed: controller.videoGenerationCommandBusy
                ? null
                : () => controller.cancelVideoGenerationOperation(task.id),
            child: const Text('取消提交'),
          )
        : Text(_taskStatusLabel(task.status)),
  );
}

class _GenerationTaskTile extends StatelessWidget {
  const _GenerationTaskTile({required this.controller, required this.task});

  final RemoteAppController controller;
  final RemoteVideoGenerationTask task;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('generation-task-${task.id}'),
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(child: Text('${task.shotNumber}')),
    title: Text('镜头 ${task.shotNumber} · ${task.model}'),
    subtitle: Text(
      task.errorMessage.isNotEmpty
          ? task.errorMessage
          : '${task.durationSeconds}s · ${_generationStatusLabel(task.status)}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: task.running && controller.canEdit
        ? TextButton(
            onPressed: controller.videoGenerationCommandBusy
                ? null
                : () => controller.cancelVideoGenerationTask(task.id),
            child: const Text('取消生成'),
          )
        : task.retryable && controller.canEdit
        ? TextButton(
            onPressed: controller.videoGenerationCommandBusy
                ? null
                : () => controller.retryVideoGenerationTask(task.id),
            child: const Text('重试'),
          )
        : Text(_generationStatusLabel(task.status)),
  );
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({required this.controller, required this.work});

  final RemoteAppController controller;
  final RemoteVideoGenerationTask work;

  @override
  Widget build(BuildContext context) => Material(
    key: ValueKey('generation-work-${work.id}'),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: work.mediaId == null ? null : () => _showPreview(context),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xff151d28), Color(0xff31465f)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '镜头 ${work.shotNumber}',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            Text(
              '${work.model} · ${work.durationSeconds}s',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    ),
  );

  void _showPreview(BuildContext context) {
    final mediaId = work.mediaId;
    if (mediaId == null) return;
    showDialog<void>(
      context: context,
      builder: (context) {
        final viewport = MediaQuery.sizeOf(context);
        final ratio = _aspectRatio(
          controller.videoGenerationOptions?.projectAspectRatio,
        );
        return Dialog(
          child: SizedBox(
            width: math.min(900, viewport.width * .9),
            height: math.min(760, viewport.height * .82),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '镜头 ${work.shotNumber} 作品预览',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: ratio < 1 ? 420 : 860,
                        ),
                        child: RemoteVideoPreview(
                          uri: controller.mediaUri(mediaId),
                          aspectRatio: ratio,
                        ),
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

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome_motion_outlined,
            size: 58,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          const Text(
            '当前桌面端未开放视频生成',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          const Text('请确认工程已加载，并在桌面端完成视频生成后端配置。'),
        ],
      ),
    ),
  );
}

String _durationText(num value) => value == value.roundToDouble()
    ? '${value.toInt()}'
    : value.toStringAsFixed(1);

String? _rangeLabel(RemoteVideoGenerationParameter parameter) {
  if (parameter.min == null && parameter.max == null) return null;
  return '${parameter.min ?? '不限'}–${parameter.max ?? '不限'}'
      '${parameter.step == null ? '' : '，步进 ${parameter.step}'}';
}

String _shotRange(List<int> numbers) {
  if (numbers.isEmpty) return '未关联镜头';
  if (numbers.length == 1) return '镜头 ${numbers.first}';
  return '镜头 ${numbers.first}–${numbers.last}';
}

String _taskStatusLabel(String status) => switch (status) {
  'queued' => '排队中',
  'running' => '执行中',
  'succeeded' => '已提交',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => status,
};

String _generationStatusLabel(String status) => switch (status) {
  'draft' => '准备中',
  'submitting' => '提交中',
  'queued' => '排队中',
  'running' => '生成中',
  'completed' => '已完成',
  'partialCompleted' => '部分完成',
  'failed' => '失败',
  'canceled' => '已取消',
  'timedOut' => '已超时',
  _ => status,
};

double _aspectRatio(String? value) {
  final parts = value?.split(':') ?? const [];
  if (parts.length != 2) return 16 / 9;
  final width = double.tryParse(parts[0]);
  final height = double.tryParse(parts[1]);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return 16 / 9;
  }
  return width / height;
}
