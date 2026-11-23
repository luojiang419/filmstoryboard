import 'package:flutter/widgets.dart';

/// Ensures native desktop drop listeners are active only on the visible page.
class DesktopDropTargetScope extends InheritedWidget {
  const DesktopDropTargetScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopDropTargetScope>()
          ?.enabled ??
      true;

  @override
  bool updateShouldNotify(DesktopDropTargetScope oldWidget) =>
      enabled != oldWidget.enabled;
}
