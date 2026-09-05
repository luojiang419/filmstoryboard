import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'retained_page.dart';

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
  bool _active = true;
  Widget? _content;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = PageActivityScope.isActive(context);
    if (_active) {
      final next = widget.selector(widget.valueListenable.value);
      if (_needsRebuild(_selected, next)) {
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
  void didUpdateWidget(covariant ValueListenableSelector<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content = null;
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
    if (!_active) return;
    final next = widget.selector(widget.valueListenable.value);
    if (!_needsRebuild(_selected, next)) {
      return;
    }
    setState(() {
      _selected = next;
      _content = null;
    });
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final builder = widget.builder;
    final child = widget.child;
    // Theme and MediaQuery dependencies belong to the child Builder. Page
    // activity alone must not rerun expensive, otherwise unchanged builders.
    return _content ??= Builder(
      builder: (context) => builder(context, selected, child),
    );
  }
}

/// ValueListenableBuilder semantics, with hidden-page notification suspension.
class PageValueListenableBuilder<T> extends ValueListenableSelector<T, T> {
  PageValueListenableBuilder({
    super.key,
    required super.valueListenable,
    required super.builder,
    super.child,
  }) : super(selector: (value) => value);
}

class PageListenableBuilder extends StatefulWidget {
  const PageListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });
  final Listenable listenable;
  final TransitionBuilder builder;

  @override
  State<PageListenableBuilder> createState() => _PageListenableBuilderState();
}

class _PageListenableBuilderState extends State<PageListenableBuilder> {
  bool _active = true;
  bool _dirty = true;
  Widget? _content;
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = PageActivityScope.isActive(context);
  }

  @override
  void didUpdateWidget(PageListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content = null;
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  void _changed() {
    _dirty = true;
    if (_active) setState(() => _content = null);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final builder = widget.builder;
    if (_active && _dirty) {
      _content = null;
      _dirty = false;
    }
    return _content ??= Builder(builder: (context) => builder(context, null));
  }
}
