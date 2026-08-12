import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

const defaultVideoAspectRatio = 16 / 9;

Size constrainedVideoSize({
  required double maxWidth,
  required double maxHeight,
  required double aspectRatio,
}) {
  final safeWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 1.0;
  final safeHeight = maxHeight.isFinite && maxHeight > 0
      ? maxHeight
      : double.infinity;
  final safeRatio = aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio
      : defaultVideoAspectRatio;
  var width = safeWidth;
  var height = width / safeRatio;
  if (height > safeHeight) {
    height = safeHeight;
    width = math.min(safeWidth, height * safeRatio);
  }
  return Size(width, height);
}

class AdaptiveVideoViewport extends StatefulWidget {
  const AdaptiveVideoViewport({
    super.key,
    required this.child,
    this.player,
    this.initialAspectRatio = defaultVideoAspectRatio,
    this.maxHeight = double.infinity,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Player? player;
  final double initialAspectRatio;
  final double maxHeight;
  final Alignment alignment;

  @override
  State<AdaptiveVideoViewport> createState() => _AdaptiveVideoViewportState();
}

class _AdaptiveVideoViewportState extends State<AdaptiveVideoViewport> {
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;
  int? _videoWidth;
  int? _videoHeight;

  @override
  void initState() {
    super.initState();
    _bindPlayer();
  }

  @override
  void didUpdateWidget(covariant AdaptiveVideoViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _unbindPlayer();
      _bindPlayer();
    }
  }

  void _bindPlayer() {
    final player = widget.player;
    if (player == null) return;
    _videoWidth = player.state.width;
    _videoHeight = player.state.height;
    _widthSubscription = player.stream.width.listen((value) {
      if (value != null && value > 0 && mounted) {
        setState(() => _videoWidth = value);
      }
    });
    _heightSubscription = player.stream.height.listen((value) {
      if (value != null && value > 0 && mounted) {
        setState(() => _videoHeight = value);
      }
    });
  }

  void _unbindPlayer() {
    unawaited(_widthSubscription?.cancel());
    unawaited(_heightSubscription?.cancel());
    _widthSubscription = null;
    _heightSubscription = null;
    _videoWidth = null;
    _videoHeight = null;
  }

  double get _aspectRatio {
    final width = _videoWidth;
    final height = _videoHeight;
    if (width != null && height != null && width > 0 && height > 0) {
      return width / height;
    }
    return widget.initialAspectRatio.isFinite && widget.initialAspectRatio > 0
        ? widget.initialAspectRatio
        : defaultVideoAspectRatio;
  }

  @override
  void dispose() {
    _unbindPlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final constrainedHeight = constraints.hasBoundedHeight
            ? math.min(constraints.maxHeight, widget.maxHeight)
            : widget.maxHeight;
        final size = constrainedVideoSize(
          maxWidth: maxWidth,
          maxHeight: constrainedHeight,
          aspectRatio: _aspectRatio,
        );
        return Align(
          alignment: widget.alignment,
          widthFactor: constraints.hasBoundedWidth ? null : 1,
          heightFactor: constraints.hasBoundedHeight ? null : 1,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: widget.child,
          ),
        );
      },
    );
  }
}
