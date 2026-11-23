import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 在外层滚动容器中按可见行构建子项，避免 shrinkWrap 网格一次创建全部内容。
class ViewportLazyGrid extends StatefulWidget {
  const ViewportLazyGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent,
    this.crossAxisCount,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
    this.cacheRows = 2,
  }) : assert(itemExtent != null || crossAxisCount != null),
       assert(itemExtent == null || itemExtent > 0),
       assert(crossAxisCount == null || crossAxisCount > 0);

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double? itemExtent;
  final int? crossAxisCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final int cacheRows;

  @override
  State<ViewportLazyGrid> createState() => _ViewportLazyGridState();
}

class _ViewportLazyGridState extends State<ViewportLazyGrid> {
  ScrollPosition? _position;
  int _firstVisibleRow = 0;
  int _lastVisibleRow = 0;
  int _rowCount = 0;
  double _rowStride = 0;
  bool _updateScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (identical(nextPosition, _position)) {
      return;
    }
    _position?.removeListener(_scheduleVisibleRangeUpdate);
    _position = nextPosition;
    _position?.addListener(_scheduleVisibleRangeUpdate);
  }

  @override
  void didUpdateWidget(covariant ViewportLazyGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount ||
        oldWidget.itemExtent != widget.itemExtent ||
        oldWidget.crossAxisCount != widget.crossAxisCount) {
      _scheduleVisibleRangeUpdate();
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleVisibleRangeUpdate);
    super.dispose();
  }

  void _scheduleVisibleRangeUpdate() {
    if (_updateScheduled) {
      return;
    }
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (mounted) {
        _updateVisibleRange();
      }
    });
  }

  void _updateVisibleRange() {
    if (_rowCount == 0 || _rowStride <= 0) {
      return;
    }
    final gridBox = context.findRenderObject();
    final scrollableBox = _position?.context.storageContext.findRenderObject();
    if (gridBox is! RenderBox ||
        !gridBox.hasSize ||
        scrollableBox is! RenderBox ||
        !scrollableBox.hasSize) {
      return;
    }
    final gridTop = gridBox.localToGlobal(Offset.zero).dy;
    final viewportTop = scrollableBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + scrollableBox.size.height;
    final first = math.max(
      0,
      ((viewportTop - gridTop) / _rowStride).floor() - widget.cacheRows,
    );
    final last = math.min(
      _rowCount - 1,
      ((viewportBottom - gridTop) / _rowStride).floor() + widget.cacheRows,
    );
    final nextFirst = first > last ? 0 : first;
    final nextLast = first > last ? -1 : last;
    if (nextFirst == _firstVisibleRow && nextLast == _lastVisibleRow) {
      return;
    }
    setState(() {
      _firstVisibleRow = nextFirst;
      _lastVisibleRow = nextLast;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns =
            widget.crossAxisCount ??
            math.max(
              1,
              ((width + widget.crossAxisSpacing) /
                      (widget.itemExtent! + widget.crossAxisSpacing))
                  .floor(),
            );
        final cellExtent =
            widget.itemExtent ??
            (width - widget.crossAxisSpacing * (columns - 1)) / columns;
        final rowCount = (widget.itemCount / columns).ceil();
        final rowStride = cellExtent + widget.mainAxisSpacing;
        _rowCount = rowCount;
        _rowStride = rowStride;
        if (_lastVisibleRow >= rowCount) {
          _lastVisibleRow = math.max(0, rowCount - 1);
        }
        _scheduleVisibleRangeUpdate();
        final totalHeight = rowCount == 0
            ? 0.0
            : rowCount * cellExtent + (rowCount - 1) * widget.mainAxisSpacing;
        return SizedBox(
          height: totalHeight,
          child: ClipRect(
            child: Stack(
              children: [
                for (
                  var row = _firstVisibleRow;
                  row <= _lastVisibleRow && row < rowCount;
                  row++
                )
                  Positioned(
                    left: 0,
                    right: 0,
                    top: row * rowStride,
                    height: cellExtent,
                    child: Row(
                      children: [
                        for (var column = 0; column < columns; column++) ...[
                          if (column > 0)
                            SizedBox(width: widget.crossAxisSpacing),
                          if (row * columns + column < widget.itemCount)
                            SizedBox(
                              width: cellExtent,
                              height: cellExtent,
                              child: widget.itemBuilder(
                                context,
                                row * columns + column,
                              ),
                            )
                          else
                            SizedBox(width: cellExtent, height: cellExtent),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
