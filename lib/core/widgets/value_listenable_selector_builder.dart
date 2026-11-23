import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef ValueSelector<T, S> = S Function(T value);
typedef SelectedValueEquals<S> = bool Function(S previous, S next);

class ValueListenableSelectorBuilder<T, S> extends StatefulWidget {
  const ValueListenableSelectorBuilder({
    super.key,
    required this.valueListenable,
    required this.selector,
    required this.builder,
    this.equals,
    this.child,
  });

  final ValueListenable<T> valueListenable;
  final ValueSelector<T, S> selector;
  final SelectedValueEquals<S>? equals;
  final ValueWidgetBuilder<S> builder;
  final Widget? child;

  @override
  State<ValueListenableSelectorBuilder<T, S>> createState() =>
      _ValueListenableSelectorBuilderState<T, S>();
}

class _ValueListenableSelectorBuilderState<T, S>
    extends State<ValueListenableSelectorBuilder<T, S>> {
  late S _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selector(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(ValueListenableSelectorBuilder<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_handleValueChanged);
      widget.valueListenable.addListener(_handleValueChanged);
    }
    _selected = widget.selector(widget.valueListenable.value);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  void _handleValueChanged() {
    final next = widget.selector(widget.valueListenable.value);
    final unchanged = widget.equals?.call(_selected, next) ?? _selected == next;
    if (unchanged) {
      return;
    }
    setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _selected, widget.child);
  }
}

class AnimatedCollapsibleContent extends StatelessWidget {
  const AnimatedCollapsibleContent({
    super.key,
    required this.expanded,
    required this.child,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOutCubic,
    this.alignment = Alignment.topCenter,
  });

  final bool expanded;
  final Widget child;
  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: curve,
        alignment: alignment,
        child: expanded ? child : const SizedBox.shrink(),
      ),
    );
  }
}
