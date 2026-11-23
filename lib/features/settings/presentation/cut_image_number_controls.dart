import 'package:flutter/material.dart';

import '../domain/app_settings.dart';

class CutImageNumberControls extends StatelessWidget {
  const CutImageNumberControls({
    super.key,
    required this.enabled,
    required this.position,
    required this.backgroundOpacity,
    required this.textScale,
    this.captionNumberEnabled,
    required this.onEnabledChanged,
    required this.onPositionChanged,
    required this.onBackgroundOpacityChanged,
    required this.onBackgroundOpacityChangeEnd,
    required this.onTextScaleChanged,
    required this.onTextScaleChangeEnd,
    this.onCaptionNumberEnabledChanged,
  });

  final bool enabled;
  final CutImageNumberPosition position;
  final double backgroundOpacity;
  final double textScale;
  final bool? captionNumberEnabled;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<CutImageNumberPosition> onPositionChanged;
  final ValueChanged<double> onBackgroundOpacityChanged;
  final ValueChanged<double> onBackgroundOpacityChangeEnd;
  final ValueChanged<double> onTextScaleChanged;
  final ValueChanged<double> onTextScaleChangeEnd;
  final ValueChanged<bool>? onCaptionNumberEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.format_list_numbered_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '图片编号',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Switch(value: enabled, onChanged: onEnabledChanged),
          ],
        ),
        if (captionNumberEnabled != null &&
            onCaptionNumberEnabledChanged != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.short_text_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '文本框编号',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Switch(
                key: const ValueKey('storyboard-caption-number-switch'),
                value: captionNumberEnabled!,
                onChanged: onCaptionNumberEnabledChanged,
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        DropdownButtonFormField<CutImageNumberPosition>(
          initialValue: position,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '编号位置',
            isDense: true,
            prefixIcon: const Icon(Icons.place_rounded, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          items: [
            for (final option in CutImageNumberPosition.values)
              DropdownMenuItem(value: option, child: Text(option.label)),
          ],
          onChanged: enabled
              ? (value) {
                  if (value == null) {
                    return;
                  }
                  onPositionChanged(value);
                }
              : null,
        ),
        const SizedBox(height: 12),
        _NumberSlider(
          icon: Icons.opacity_rounded,
          label: '圆圈透明度',
          value: backgroundOpacity,
          min: 0,
          max: 1,
          divisions: 20,
          valueLabel: '${(backgroundOpacity * 100).round()}%',
          onChanged: enabled ? onBackgroundOpacityChanged : null,
          onChangeEnd: enabled ? onBackgroundOpacityChangeEnd : null,
        ),
        const SizedBox(height: 8),
        _NumberSlider(
          icon: Icons.format_size_rounded,
          label: '数字尺寸',
          value: textScale,
          min: 0.7,
          max: 1.6,
          divisions: 18,
          valueLabel: '${(textScale * 100).round()}%',
          onChanged: enabled ? onTextScaleChanged : null,
          onChangeEnd: enabled ? onTextScaleChangeEnd : null,
        ),
      ],
    );
  }
}

class _NumberSlider extends StatelessWidget {
  const _NumberSlider({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveValue = value.clamp(min, max).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
        Slider(
          value: effectiveValue,
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
