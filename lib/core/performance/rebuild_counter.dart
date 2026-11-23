import 'package:flutter/widgets.dart';

import 'performance_probe.dart';

/// A zero-behavior wrapper that counts builds in debug/profile diagnostics.
///
/// The child is returned unchanged, so adding this wrapper does not alter
/// layout, hit testing, semantics or lifecycle behavior.
class RebuildCounter extends StatelessWidget {
  const RebuildCounter({super.key, required this.name, required this.child});

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild(name);
    return child;
  }
}
