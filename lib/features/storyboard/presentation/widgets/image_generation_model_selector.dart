import 'package:flutter/material.dart';

import '../../domain/image_generation_model_catalog.dart';

class ImageGenerationModelSelector extends StatelessWidget {
  const ImageGenerationModelSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.requireReferenceSupport = false,
    this.labelText = '模型',
    this.prefixIcon = const Icon(Icons.auto_awesome_rounded),
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool requireReferenceSupport;
  final String labelText;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) {
    final descriptor = ImageGenerationCatalog.descriptorFor(value);
    final label = descriptor?.label ?? value;
    final providerLabel = ImageGenerationCatalog.providerLabelFor(value);
    final displayLabel = descriptor == null ? label : '$providerLabel · $label';
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: enabled ? () => _openSelector(context) : null,
      child: InputDecorator(
        isEmpty: value.trim().isEmpty,
        decoration: InputDecoration(
          labelText: labelText,
          prefixIcon: prefixIcon,
          enabled: enabled,
          suffixIcon: const Icon(Icons.unfold_more_rounded),
        ),
        child: Text(displayLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Future<void> _openSelector(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _ImageGenerationModelDialog(
        value: value,
        requireReferenceSupport: requireReferenceSupport,
      ),
    );
    if (selected != null && selected != value) {
      onChanged(selected);
    }
  }
}

class _ImageGenerationModelDialog extends StatefulWidget {
  const _ImageGenerationModelDialog({
    required this.value,
    required this.requireReferenceSupport,
  });

  final String value;
  final bool requireReferenceSupport;

  @override
  State<_ImageGenerationModelDialog> createState() =>
      _ImageGenerationModelDialogState();
}

class _ImageGenerationModelDialogState
    extends State<_ImageGenerationModelDialog> {
  String? _expandedProviderId;
  String? _expandedFamilyId;

  @override
  void initState() {
    super.initState();
    for (final provider in _visibleProviders) {
      for (final family in _visibleFamilies(provider)) {
        if (_visibleModelIds(family).contains(widget.value)) {
          _expandedProviderId = provider.id;
          _expandedFamilyId = family.id;
          return;
        }
      }
    }
  }

  List<ImageGenerationModelProvider> get _visibleProviders {
    return [
      for (final provider in ImageGenerationCatalog.providers)
        if (_visibleFamilies(provider).isNotEmpty) provider,
    ];
  }

  List<ImageGenerationModelFamily> _visibleFamilies(
    ImageGenerationModelProvider provider,
  ) {
    return [
      for (final family in provider.families)
        if (_visibleModelIds(family).isNotEmpty) family,
    ];
  }

  List<String> _visibleModelIds(ImageGenerationModelFamily family) {
    return [
      for (final id in family.modelIds)
        if (_isVisibleModel(id)) id,
    ];
  }

  bool _isVisibleModel(String id) {
    final descriptor = ImageGenerationCatalog.descriptorFor(id);
    if (descriptor == null) {
      return false;
    }
    return !widget.requireReferenceSupport ||
        descriptor.supportsReferenceImages;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.account_tree_rounded),
          SizedBox(width: 8),
          Text('选择图片生成模型'),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 540,
        child: ListView.separated(
          itemCount: _visibleProviders.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final provider = _visibleProviders[index];
            return _buildProvider(context, provider);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _buildProvider(
    BuildContext context,
    ImageGenerationModelProvider provider,
  ) {
    final expanded = _expandedProviderId == provider.id;
    final families = _visibleFamilies(provider);
    final modelCount = families.fold<int>(
      0,
      (total, family) => total + _visibleModelIds(family).length,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DrawerHeader(
            key: ValueKey('image-model-provider-${provider.id}'),
            icon: Icons.cloud_queue_rounded,
            label: provider.label,
            detail: '$modelCount 个模型',
            expanded: expanded,
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedProviderId = null;
                  _expandedFamilyId = null;
                } else {
                  _expandedProviderId = provider.id;
                  _expandedFamilyId = null;
                }
              });
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(
                      children: [
                        for (final family in families)
                          _buildFamily(context, family),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildFamily(BuildContext context, ImageGenerationModelFamily family) {
    final expanded = _expandedFamilyId == family.id;
    final modelIds = _visibleModelIds(family);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DrawerHeader(
              key: ValueKey('image-model-family-${family.id}'),
              icon: Icons.folder_open_rounded,
              label: family.label,
              detail: '${modelIds.length}',
              expanded: expanded,
              dense: true,
              onTap: () {
                setState(() {
                  _expandedFamilyId = expanded ? null : family.id;
                });
              },
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: expanded
                  ? Column(
                      children: [
                        const Divider(height: 1),
                        for (final modelId in modelIds)
                          _buildModel(context, modelId),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModel(BuildContext context, String modelId) {
    final descriptor = ImageGenerationCatalog.descriptorFor(modelId)!;
    final selected = widget.value == modelId;
    return ListTile(
      key: ValueKey('image-model-option-$modelId'),
      dense: true,
      selected: selected,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(descriptor.label),
      subtitle: Text(descriptor.apiModel, maxLines: 1),
      onTap: () => Navigator.of(context).pop(modelId),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.expanded,
    required this.onTap,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool expanded;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 10 : 12,
            vertical: dense ? 9 : 12,
          ),
          child: Row(
            children: [
              Icon(icon, size: dense ? 18 : 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: dense
                      ? Theme.of(context).textTheme.bodyMedium
                      : Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                detail,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 5),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: const Icon(Icons.expand_more_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
