import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds only when the selected slice of a [ValueListenable] changes.
///
/// This is intentionally similar to Riverpod's `select`, but works with the
/// existing ValueNotifier controllers used by the desktop feature pages.
class ValueListenableSelector<T, S> extends StatefulWidget {
  const ValueListenableSelector({
    super.key,
    required this.valueListenable,
    required this.selector,
    required this.builder,
    this.shouldRebuild,
    this.child,
  });

  final ValueListenable<T> valueListenable;
  final S Function(T value) selector;
  final bool Function(S previous, S next)? shouldRebuild;
  final Widget Function(BuildContext context, S value, Widget? child) builder;
  final Widget? child;

  @override
  State<ValueListenableSelector<T, S>> createState() =>
      _ValueListenableSelectorState<T, S>();
}

class _ValueListenableSelectorState<T, S>
    extends State<ValueListenableSelector<T, S>> {
  late S _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selector(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(covariant ValueListenableSelector<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.valueListenable, widget.valueListenable)) {
      oldWidget.valueListenable.removeListener(_handleValueChanged);
      _selected = widget.selector(widget.valueListenable.value);
      widget.valueListenable.addListener(_handleValueChanged);
      return;
    }
    final next = widget.selector(widget.valueListenable.value);
    if (_needsRebuild(_selected, next)) {
      _selected = next;
    }
  }

  bool _needsRebuild(S previous, S next) =>
      widget.shouldRebuild?.call(previous, next) ?? previous != next;

  void _handleValueChanged() {
    final next = widget.selector(widget.valueListenable.value);
    if (!_needsRebuild(_selected, next)) {
      return;
    }
    setState(() => _selected = next);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _selected, widget.child);
}
