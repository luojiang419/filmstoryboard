import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'retained_page.dart';

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
  bool _active = true;
  Widget? _content;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = PageActivityScope.isActive(context);
    if (_active) {
      final next = widget.selector(widget.valueListenable.value);
      if (!(widget.equals?.call(_selected, next) ?? _selected == next)) {
        _selected = next;
        _content = null;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.selector(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(ValueListenableSelectorBuilder<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content = null;
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
    if (!_active) return;
    final next = widget.selector(widget.valueListenable.value);
    final unchanged = widget.equals?.call(_selected, next) ?? _selected == next;
    if (unchanged) {
      return;
    }
    setState(() {
      _selected = next;
      _content = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final builder = widget.builder;
    final child = widget.child;
    return _content ??= Builder(
      builder: (context) => builder(context, selected, child),
    );
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
