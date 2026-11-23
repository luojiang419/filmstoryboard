import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef FullscreenZoomItemBuilder<T> =
    Widget Function(BuildContext context, T item);
typedef FullscreenZoomLabelBuilder<T> =
    String Function(T item, int index, int total);

Future<void> showFullscreenZoomGallery<T>({
  required BuildContext context,
  required List<T> items,
  required int initialIndex,
  required FullscreenZoomItemBuilder<T> itemBuilder,
  FullscreenZoomLabelBuilder<T>? labelBuilder,
  double maxScale = 8.0,
}) {
  if (items.isEmpty) {
    return Future.value();
  }
  final safeInitialIndex = initialIndex.clamp(0, items.length - 1).toInt();
  return showGeneralDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    barrierDismissible: true,
    barrierLabel: '关闭预览',
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => FullscreenZoomGallery<T>(
      items: items,
      initialIndex: safeInitialIndex,
      itemBuilder: itemBuilder,
      labelBuilder: labelBuilder,
      maxScale: maxScale,
    ),
    transitionBuilder: (context, animation, _, child) {
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.98, end: 1.0).animate(animation),
          child: child,
        ),
      );
    },
  );
}

class FullscreenZoomGallery<T> extends StatefulWidget {
  const FullscreenZoomGallery({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.itemBuilder,
    this.labelBuilder,
    this.maxScale = 8.0,
  }) : assert(maxScale >= 1.0);

  final List<T> items;
  final int initialIndex;
  final FullscreenZoomItemBuilder<T> itemBuilder;
  final FullscreenZoomLabelBuilder<T>? labelBuilder;
  final double maxScale;

  @override
  State<FullscreenZoomGallery<T>> createState() =>
      _FullscreenZoomGalleryState<T>();
}

class _FullscreenZoomGalleryState<T> extends State<FullscreenZoomGallery<T>> {
  static const _minScale = 1.0;
  static const _buttonZoomFactor = 1.25;

  late int _index = widget.initialIndex;
  double _scale = 1;
  Offset _offset = Offset.zero;
  bool _isPanning = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _showNext();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _showPrevious();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.digit0 ||
            event.logicalKey == LogicalKeyboardKey.numpad0) {
          _resetView();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Listener(
              onPointerSignal: (event) =>
                  _handlePointerSignal(event, constraints.biggest),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MouseRegion(
                      cursor: _scale > _minScale
                          ? _isPanning
                                ? SystemMouseCursors.grabbing
                                : SystemMouseCursors.grab
                          : SystemMouseCursors.basic,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: _scale > _minScale
                            ? (_) => setState(() => _isPanning = true)
                            : null,
                        onPanUpdate: _scale > _minScale
                            ? (details) =>
                                  setState(() => _offset += details.delta)
                            : null,
                        onPanEnd: _scale > _minScale
                            ? (_) => setState(() => _isPanning = false)
                            : null,
                        onPanCancel: _scale > _minScale
                            ? () => setState(() => _isPanning = false)
                            : null,
                        onDoubleTap: _resetView,
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 260),
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0.04, 0),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                            child: Transform.translate(
                              key: ValueKey(_index),
                              offset: _offset,
                              child: Transform.scale(
                                scale: _scale,
                                child: widget.itemBuilder(
                                  context,
                                  widget.items[_index],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 22,
                    top: 22,
                    child: IconButton.filledTonal(
                      tooltip: '关闭预览',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 22,
                    child: Row(
                      children: [
                        IconButton.filledTonal(
                          tooltip: '上一张',
                          onPressed: _showPrevious,
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        const Spacer(),
                        IconButton.filledTonal(
                          tooltip: '缩小',
                          onPressed: () => _zoomBy(1 / _buttonZoomFactor),
                          icon: const Icon(Icons.remove_rounded),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: '重置视图',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _resetView,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                ),
                                child: Text(
                                  _labelText(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: '放大',
                          onPressed: () => _zoomBy(_buttonZoomFactor),
                          icon: const Icon(Icons.add_rounded),
                        ),
                        const Spacer(),
                        IconButton.filledTonal(
                          tooltip: '下一张',
                          onPressed: _showNext,
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _labelText() {
    final labelBuilder = widget.labelBuilder;
    final label = labelBuilder == null
        ? '${_index + 1} / ${widget.items.length}'
        : labelBuilder(widget.items[_index], _index, widget.items.length);
    return '$label · ${(_scale * 100).round()}%';
  }

  void _handlePointerSignal(PointerSignalEvent event, Size viewportSize) {
    if (event is! PointerScrollEvent) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final factor = math.pow(1.0015, -event.scrollDelta.dy).toDouble();
      _zoomBy(
        factor,
        focalPoint: event.localPosition,
        viewportSize: viewportSize,
      );
    });
  }

  void _zoomBy(double factor, {Offset? focalPoint, Size? viewportSize}) {
    final nextScale = (_scale * factor)
        .clamp(_minScale, widget.maxScale)
        .toDouble();
    if ((nextScale - _scale).abs() < 0.001) {
      return;
    }
    setState(() {
      if (focalPoint == null || viewportSize == null) {
        _offset = nextScale <= _minScale ? Offset.zero : _offset;
      } else if (nextScale <= _minScale) {
        _offset = Offset.zero;
      } else {
        final viewportCenter = Offset(
          viewportSize.width / 2,
          viewportSize.height / 2,
        );
        final focalFromCenter = focalPoint - viewportCenter;
        final imagePoint = (focalFromCenter - _offset) / _scale;
        _offset = focalFromCenter - imagePoint * nextScale;
      }
      _scale = nextScale;
      if (_scale <= _minScale) {
        _offset = Offset.zero;
        _isPanning = false;
      }
    });
  }

  void _showPrevious() {
    setState(() {
      _index = (_index - 1 + widget.items.length) % widget.items.length;
      _resetViewValues();
    });
  }

  void _showNext() {
    setState(() {
      _index = (_index + 1) % widget.items.length;
      _resetViewValues();
    });
  }

  void _resetView() {
    setState(_resetViewValues);
  }

  void _resetViewValues() {
    _scale = 1;
    _offset = Offset.zero;
    _isPanning = false;
  }
}
