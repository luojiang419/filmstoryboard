import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class MiddleDragAutoScrollController {
  final Set<_MiddleDragScrollTargetState> _targets =
      <_MiddleDragScrollTargetState>{};

  void _register(_MiddleDragScrollTargetState target) {
    _targets.add(target);
  }

  void _unregister(_MiddleDragScrollTargetState target) {
    _targets.remove(target);
  }

  _ActiveMiddleDragTargets? _resolveTargets(Offset globalPosition) {
    final candidates =
        _targets
            .where(
              (target) => target.contains(globalPosition) && target.canScroll,
            )
            .toList()
          ..sort(_compareTargets);
    if (candidates.isEmpty) {
      return null;
    }

    _MiddleDragScrollTargetState? horizontal;
    _MiddleDragScrollTargetState? vertical;
    for (final target in candidates) {
      switch (target.axis) {
        case Axis.horizontal:
          horizontal ??= target;
        case Axis.vertical:
          vertical ??= target;
      }
      if (horizontal != null && vertical != null) {
        break;
      }
    }
    if (horizontal == null && vertical == null) {
      return null;
    }
    return _ActiveMiddleDragTargets(horizontal: horizontal, vertical: vertical);
  }

  int _compareTargets(
    _MiddleDragScrollTargetState first,
    _MiddleDragScrollTargetState second,
  ) {
    final areaCompare = first.globalRect.size.longestSide.compareTo(
      second.globalRect.size.longestSide,
    );
    if (areaCompare != 0) {
      return areaCompare;
    }
    return first.globalRect.size.shortestSide.compareTo(
      second.globalRect.size.shortestSide,
    );
  }
}

class MiddleDragScrollBehavior extends MaterialScrollBehavior {
  const MiddleDragScrollBehavior({required this.controller});

  final MiddleDragAutoScrollController controller;

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final decorated = super.buildScrollbar(context, child, details);
    final scrollController = details.controller;
    if (scrollController == null) {
      return decorated;
    }
    return _MiddleDragScrollTarget(
      controller: controller,
      scrollController: scrollController,
      axisDirection: details.direction,
      child: decorated,
    );
  }
}

class MiddleDragAutoScroll extends StatefulWidget {
  const MiddleDragAutoScroll({
    super.key,
    required this.controller,
    required this.child,
    this.deadZone = 10,
    this.speedFactor = 0.24,
    this.maximumStep = 48,
  });

  final MiddleDragAutoScrollController controller;
  final Widget child;
  final double deadZone;
  final double speedFactor;
  final double maximumStep;

  @override
  State<MiddleDragAutoScroll> createState() => _MiddleDragAutoScrollState();
}

class _MiddleDragAutoScrollState extends State<MiddleDragAutoScroll> {
  Timer? _timer;
  int? _pointer;
  Offset? _anchor;
  Offset _dragDistance = Offset.zero;
  _ActiveMiddleDragTargets? _targets;

  bool get _active => _pointer != null && _anchor != null && _targets != null;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _active ? SystemMouseCursors.allScroll : MouseCursor.defer,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_active) _MiddleDragAnchorIndicator(anchor: _anchor!),
          ],
        ),
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kMiddleMouseButton) == 0) {
      return;
    }
    final targets = widget.controller._resolveTargets(event.position);
    if (targets == null) {
      return;
    }
    _timer?.cancel();
    setState(() {
      _pointer = event.pointer;
      _anchor = event.position;
      _dragDistance = Offset.zero;
      _targets = targets;
    });
    _timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _scrollStep(),
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || !_active) {
      return;
    }
    _dragDistance = event.position - _anchor!;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer == _pointer) {
      _stop();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      _stop();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _pointer = null;
      _anchor = null;
      _dragDistance = Offset.zero;
      _targets = null;
    });
  }

  void _scrollStep() {
    final targets = _targets;
    if (!_active || targets == null) {
      return;
    }
    final horizontalStep = _stepForDistance(_dragDistance.dx);
    final verticalStep = _stepForDistance(_dragDistance.dy);
    targets.horizontal?.scrollBy(horizontalStep);
    targets.vertical?.scrollBy(verticalStep);
  }

  double _stepForDistance(double distance) {
    final magnitude = distance.abs() - widget.deadZone;
    if (magnitude <= 0) {
      return 0;
    }
    return distance.sign *
        (magnitude * widget.speedFactor).clamp(0, widget.maximumStep);
  }
}

class _MiddleDragAnchorIndicator extends StatelessWidget {
  const _MiddleDragAnchorIndicator({required this.anchor});

  final Offset anchor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: anchor.dx - 17,
      top: anchor.dy - 17,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            shape: BoxShape.circle,
            border: Border.all(color: scheme.surface, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 12,
              ),
            ],
          ),
          child: SizedBox(
            key: const ValueKey('middle-drag-scroll-anchor'),
            width: 34,
            height: 34,
            child: Center(
              child: Icon(
                Icons.open_with_rounded,
                size: 18,
                color: scheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiddleDragScrollTarget extends StatefulWidget {
  const _MiddleDragScrollTarget({
    required this.controller,
    required this.scrollController,
    required this.axisDirection,
    required this.child,
  });

  final MiddleDragAutoScrollController controller;
  final ScrollController scrollController;
  final AxisDirection axisDirection;
  final Widget child;

  @override
  State<_MiddleDragScrollTarget> createState() =>
      _MiddleDragScrollTargetState();
}

class _MiddleDragScrollTargetState extends State<_MiddleDragScrollTarget> {
  Axis get axis {
    return switch (widget.axisDirection) {
      AxisDirection.up || AxisDirection.down => Axis.vertical,
      AxisDirection.left || AxisDirection.right => Axis.horizontal,
    };
  }

  Rect get globalRect {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return Rect.zero;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  bool get canScroll {
    if (!widget.scrollController.hasClients) {
      return false;
    }
    return widget.scrollController.positions.any(
      (position) => position.maxScrollExtent > position.minScrollExtent,
    );
  }

  bool contains(Offset globalPosition) {
    final rect = globalRect;
    return !rect.isEmpty && rect.contains(globalPosition);
  }

  void scrollBy(double delta) {
    if (delta == 0 || !widget.scrollController.hasClients) {
      return;
    }
    final signedDelta = switch (widget.axisDirection) {
      AxisDirection.down || AxisDirection.right => delta,
      AxisDirection.up || AxisDirection.left => -delta,
    };
    for (final position in widget.scrollController.positions.toList()) {
      final next = (position.pixels + signedDelta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) {
        position.jumpTo(next);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller._register(this);
  }

  @override
  void didUpdateWidget(_MiddleDragScrollTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._unregister(this);
      widget.controller._register(this);
    }
  }

  @override
  void dispose() {
    widget.controller._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ActiveMiddleDragTargets {
  const _ActiveMiddleDragTargets({this.horizontal, this.vertical});

  final _MiddleDragScrollTargetState? horizontal;
  final _MiddleDragScrollTargetState? vertical;
}
