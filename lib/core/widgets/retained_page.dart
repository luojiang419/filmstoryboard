import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Presentation activity is separate from controller/task lifetime.
class PageActivityScope extends InheritedWidget {
  const PageActivityScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageActivityScope>()?.active ??
      true;

  @override
  bool updateShouldNotify(PageActivityScope oldWidget) =>
      active != oldWidget.active;
}

/// Keeps editing state, but hidden pages do not participate in shell layout,
/// painting, focus, semantics or tickers. Unlike Offstage, hiding a page does
/// not lay out the entire hidden subtree on each window resize.
class RetainedPage extends StatelessWidget {
  const RetainedPage({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => PageActivityScope(
    active: active,
    child: ExcludeFocus(
      excluding: !active,
      child: TickerMode(
        enabled: active,
        child: _PageViewport(active: active, child: child),
      ),
    ),
  );
}

class _PageViewport extends SingleChildRenderObjectWidget {
  const _PageViewport({required this.active, required super.child});

  final bool active;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPageViewport(active);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPageViewport renderObject,
  ) {
    renderObject.active = active;
  }
}

class _RenderPageViewport extends RenderProxyBox {
  _RenderPageViewport(this._active);

  bool _active;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    markNeedsLayout();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight);
    size = constraints.biggest;
    if (_active) child?.layout(BoxConstraints.tight(size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_active) super.paint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _active && super.hitTestChildren(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_active) super.visitChildrenForSemantics(visitor);
  }
}
