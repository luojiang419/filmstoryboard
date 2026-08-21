import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../domain/line_art_color_style_catalog.dart';
import '../domain/replicate_models.dart';

enum LineArtColorStyleCardAction {
  viewSource,
  importThumbnail,
  removeThumbnail,
  edit,
  duplicate,
  delete,
}

class LineArtColorStylePresetDraft {
  const LineArtColorStylePresetDraft({
    required this.name,
    required this.description,
    required this.prompt,
    required this.swatches,
    required this.useCase,
  });

  final String name;
  final String description;
  final String prompt;
  final List<String> swatches;
  final LineArtColorStyleUseCase useCase;
}

class LineArtColorStylePicker extends StatelessWidget {
  const LineArtColorStylePicker({
    super.key,
    required this.presets,
    required this.selectedId,
    required this.projectRoot,
    required this.availableWidth,
    required this.onSelected,
    required this.onCreate,
    required this.onAction,
  });

  final List<LineArtColorStylePreset> presets;
  final String selectedId;
  final Directory projectRoot;
  final double availableWidth;
  final ValueChanged<String> onSelected;
  final VoidCallback onCreate;
  final void Function(
    LineArtColorStylePreset preset,
    LineArtColorStyleCardAction action,
  )
  onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _presetById(selectedId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '线稿全片色彩',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '同一任务锁定一套电影级调色，保护服装、产品、肤色与材质本色。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey('create-line-art-color-style-preset'),
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('自定义预设'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Builder(
          builder: (context) {
            final columns = availableWidth >= 760
                ? 3
                : availableWidth >= 480
                ? 2
                : 1;
            const spacing = 12.0;
            final cardWidth =
                (availableWidth - spacing * (columns - 1)) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final preset in presets)
                  SizedBox(
                    width: cardWidth,
                    child: _ColorStylePresetCard(
                      preset: preset,
                      projectRoot: projectRoot,
                      selected: preset.id == selectedId,
                      onTap: () => onSelected(preset.id),
                      onAction: (action) => onAction(preset, action),
                    ),
                  ),
              ],
            );
          },
        ),
        if (selected != null) ...[
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          selected.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      _PresetTypeChip(preset: selected),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(selected.description),
                  const SizedBox(height: 8),
                  Text(
                    selected.prompt,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  LineArtColorStylePreset? _presetById(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

class _ColorStylePresetCard extends StatelessWidget {
  const _ColorStylePresetCard({
    required this.preset,
    required this.projectRoot,
    required this.selected,
    required this.onTap,
    required this.onAction,
  });

  final LineArtColorStylePreset preset;
  final Directory projectRoot;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<LineArtColorStyleCardAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '${preset.name}，${preset.description}',
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.36)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('line-art-color-style-card-${preset.id}'),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _ColorStyleThumbnail(
                      preset: preset,
                      projectRoot: projectRoot,
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(alpha: 0.88),
                        shape: BoxShape.circle,
                      ),
                      child: PopupMenuButton<LineArtColorStyleCardAction>(
                        key: ValueKey('line-art-color-style-menu-${preset.id}'),
                        tooltip: '预设操作',
                        padding: EdgeInsets.zero,
                        iconSize: 19,
                        onSelected: onAction,
                        itemBuilder: (context) => [
                          if (preset.isBuiltIn)
                            const PopupMenuItem(
                              value: LineArtColorStyleCardAction.viewSource,
                              child: Text('查看来源与许可'),
                            ),
                          PopupMenuItem(
                            value: LineArtColorStyleCardAction.importThumbnail,
                            child: Text(
                              preset.thumbnail?.type ==
                                      ColorStyleThumbnailType.projectFile
                                  ? '替换缩略图'
                                  : preset.isBuiltIn
                                  ? '设置项目缩略图'
                                  : '添加缩略图',
                            ),
                          ),
                          if (preset.thumbnail?.type ==
                              ColorStyleThumbnailType.projectFile)
                            const PopupMenuItem(
                              value:
                                  LineArtColorStyleCardAction.removeThumbnail,
                              child: Text('移除项目缩略图'),
                            ),
                          if (!preset.isBuiltIn)
                            const PopupMenuItem(
                              value: LineArtColorStyleCardAction.edit,
                              child: Text('编辑预设'),
                            ),
                          const PopupMenuItem(
                            value: LineArtColorStyleCardAction.duplicate,
                            child: Text('复制为自定义预设'),
                          ),
                          if (!preset.isBuiltIn)
                            const PopupMenuItem(
                              value: LineArtColorStyleCardAction.delete,
                              child: Text('删除预设'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (selected)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor: colors.primary,
                        foregroundColor: colors.onPrimary,
                        child: const Icon(Icons.check_rounded, size: 17),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        preset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _SwatchRow(swatches: preset.swatches),
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

class _ColorStyleThumbnail extends StatelessWidget {
  const _ColorStyleThumbnail({required this.preset, required this.projectRoot});

  final LineArtColorStylePreset preset;
  final Directory projectRoot;

  @override
  Widget build(BuildContext context) {
    final reference = preset.thumbnail;
    if (reference?.type == ColorStyleThumbnailType.bundledAsset) {
      return Image.asset(
        reference!.path,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _PaletteFallback(swatches: preset.swatches),
      );
    }
    if (reference?.type == ColorStyleThumbnailType.projectFile) {
      final file = File(p.normalize(p.join(projectRoot.path, reference!.path)));
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _PaletteFallback(swatches: preset.swatches),
      );
    }
    return _PaletteFallback(swatches: preset.swatches);
  }
}

class _PaletteFallback extends StatelessWidget {
  const _PaletteFallback({required this.swatches});

  final List<String> swatches;

  @override
  Widget build(BuildContext context) {
    final colors = swatches.map(_parseHexColor).whereType<Color>().toList();
    final fallback = Theme.of(context).colorScheme.surfaceContainerHighest;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors.length >= 2 ? colors : [fallback, fallback],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.palette_outlined,
          color:
              ThemeData.estimateBrightnessForColor(
                    colors.firstOrNull ?? fallback,
                  ) ==
                  Brightness.dark
              ? Colors.white70
              : Colors.black54,
        ),
      ),
    );
  }
}

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({required this.swatches});

  final List<String> swatches;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final swatch in swatches.take(3))
        Container(
          width: 13,
          height: 13,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: _parseHexColor(swatch) ?? Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
    ],
  );
}

class _PresetTypeChip extends StatelessWidget {
  const _PresetTypeChip({required this.preset});

  final LineArtColorStylePreset preset;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        preset.isBuiltIn ? '内置' : '自定义',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ),
  );
}

Future<LineArtColorStylePresetDraft?> showLineArtColorStylePresetEditor(
  BuildContext context, {
  LineArtColorStylePreset? initialPreset,
}) => showDialog<LineArtColorStylePresetDraft>(
  context: context,
  builder: (context) =>
      _ColorStylePresetEditorDialog(initialPreset: initialPreset),
);

class _ColorStylePresetEditorDialog extends StatefulWidget {
  const _ColorStylePresetEditorDialog({this.initialPreset});

  final LineArtColorStylePreset? initialPreset;

  @override
  State<_ColorStylePresetEditorDialog> createState() =>
      _ColorStylePresetEditorDialogState();
}

class _ColorStylePresetEditorDialogState
    extends State<_ColorStylePresetEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _promptController;
  late final TextEditingController _swatchesController;
  late LineArtColorStyleUseCase _useCase;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final preset = widget.initialPreset;
    _nameController = TextEditingController(text: preset?.name ?? '');
    _descriptionController = TextEditingController(
      text: preset?.description ?? '',
    );
    _promptController = TextEditingController(text: preset?.prompt ?? '');
    _swatchesController = TextEditingController(
      text: preset?.swatches.join(', ') ?? '#D8C2AC, #53616A, #22272B',
    );
    _useCase = preset?.useCase ?? LineArtColorStyleUseCase.fashion;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    _swatchesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('line-art-color-style-editor-dialog'),
    title: Text(widget.initialPreset == null ? '创建色彩预设' : '编辑色彩预设'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('color-style-editor-name'),
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<LineArtColorStyleUseCase>(
              key: const ValueKey('color-style-editor-use-case'),
              initialValue: _useCase,
              decoration: const InputDecoration(labelText: '主要用途'),
              items: const [
                DropdownMenuItem(
                  value: LineArtColorStyleUseCase.fashion,
                  child: Text('高端服装广告'),
                ),
                DropdownMenuItem(
                  value: LineArtColorStyleUseCase.cinema,
                  child: Text('电影实景'),
                ),
                DropdownMenuItem(
                  value: LineArtColorStyleUseCase.commercial,
                  child: Text('商业摄影'),
                ),
                DropdownMenuItem(
                  value: LineArtColorStyleUseCase.stylized,
                  child: Text('艺术化（谨慎使用）'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _useCase = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('color-style-editor-description'),
              controller: _descriptionController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '简要说明'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('color-style-editor-prompt'),
              controller: _promptController,
              minLines: 5,
              maxLines: 9,
              decoration: const InputDecoration(
                labelText: '英文色彩提示词',
                helperText: '只描述全局调色、反差、高光、阴影和颗粒；不要改写人物、服装或产品。',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('color-style-editor-swatches'),
              controller: _swatchesController,
              decoration: const InputDecoration(
                labelText: '色板',
                hintText: '#D8C2AC, #53616A, #22272B',
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('save-line-art-color-style-preset'),
        onPressed: _save,
        child: const Text('保存'),
      ),
    ],
  );

  void _save() {
    final name = _nameController.text.trim();
    final prompt = _promptController.text.trim();
    final swatches = _swatchesController.text
        .split(RegExp(r'[,，\s]+'))
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (name.isEmpty || prompt.isEmpty) {
      setState(() => _error = '名称和英文色彩提示词不能为空');
      return;
    }
    if (swatches.length < 2 ||
        swatches.any((value) => !RegExp(r'^#[0-9A-F]{6}$').hasMatch(value))) {
      setState(() => _error = '请至少填写 2 个六位 HEX 色值，例如 #D8C2AC');
      return;
    }
    Navigator.of(context).pop(
      LineArtColorStylePresetDraft(
        name: name,
        description: _descriptionController.text.trim(),
        prompt: prompt,
        swatches: swatches,
        useCase: _useCase,
      ),
    );
  }
}

Future<void> showLineArtColorStyleSourceDialog(
  BuildContext context,
  LineArtColorStylePreset preset,
) async {
  final builtIn = LineArtColorStyleCatalog.findById(preset.id);
  final attribution = builtIn?.thumbnail?.attribution;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('line-art-color-style-source-dialog'),
      title: Text('${preset.name}｜来源与许可'),
      content: SizedBox(
        width: 560,
        child: attribution == null
            ? const Text('这是用户创建的预设或色板占位，没有内置开源图片归因。')
            : SingleChildScrollView(
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('仓库：${attribution.repositoryName}'),
                      const SizedBox(height: 8),
                      Text('许可：${attribution.licenseName}'),
                      const SizedBox(height: 8),
                      Text('作者：${attribution.author}'),
                      const SizedBox(height: 12),
                      Text('仓库：${attribution.repositoryUrl}'),
                      const SizedBox(height: 6),
                      Text('许可证：${attribution.licenseUrl}'),
                      const SizedBox(height: 6),
                      Text('原帖：${attribution.sourcePostUrl}'),
                      const SizedBox(height: 12),
                      const Text(
                        '改编说明：已中心裁切为 16:9、缩放至 960×540 并重新编码，用作离线卡片缩略图。',
                      ),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Color? _parseHexColor(String value) {
  final normalized = value.trim().replaceFirst('#', '');
  if (normalized.length != 6) return null;
  final parsed = int.tryParse(normalized, radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}
