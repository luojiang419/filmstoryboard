import 'package:flutter/material.dart';

final class StoryboardCanvasStyle {
  const StoryboardCanvasStyle._();

  static const background = Color(0xFF242A2E);
  static const tileBackground = Color(0xFF1A2024);
  static const imageBackground = Color(0xFF11171B);
  static const slotBackground = Color(0xFF20272C);
  static const slotBorder = Color(0xFF3A454B);
  static const accent = Color(0xFF6EE7F9);
  static const text = Color(0xFFE8EDF0);
  static const mutedText = Color(0xFF9FAAB2);

  static const darkColors = StoryboardCanvasColors(
    background: background,
    tileBackground: tileBackground,
    imageBackground: imageBackground,
    slotBackground: slotBackground,
    slotBorder: slotBorder,
    accent: accent,
    text: text,
    mutedText: mutedText,
  );

  static StoryboardCanvasColors of(BuildContext context) {
    return fromColorScheme(Theme.of(context).colorScheme);
  }

  static StoryboardCanvasColors fromColorScheme(ColorScheme scheme) {
    if (scheme.brightness == Brightness.dark) {
      return darkColors;
    }
    return StoryboardCanvasColors(
      background: scheme.surfaceContainerHighest,
      tileBackground: scheme.surfaceContainerLow,
      imageBackground: scheme.surface,
      slotBackground: scheme.surfaceContainerHigh,
      slotBorder: scheme.outlineVariant.withValues(alpha: 0.82),
      accent: scheme.primary,
      text: scheme.onSurface,
      mutedText: scheme.onSurfaceVariant,
    );
  }
}

final class StoryboardCanvasColors {
  const StoryboardCanvasColors({
    required this.background,
    required this.tileBackground,
    required this.imageBackground,
    required this.slotBackground,
    required this.slotBorder,
    required this.accent,
    required this.text,
    required this.mutedText,
  });

  final Color background;
  final Color tileBackground;
  final Color imageBackground;
  final Color slotBackground;
  final Color slotBorder;
  final Color accent;
  final Color text;
  final Color mutedText;
}
