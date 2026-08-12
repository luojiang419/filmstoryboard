// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class RemoteVideoPreview extends StatefulWidget {
  const RemoteVideoPreview({
    super.key,
    required this.uri,
    required this.aspectRatio,
  });

  final Uri uri;
  final double aspectRatio;

  @override
  State<RemoteVideoPreview> createState() => _RemoteVideoPreviewState();
}

class _RemoteVideoPreviewState extends State<RemoteVideoPreview> {
  static int _nextViewId = 0;
  late final String _viewType;
  late final html.VideoElement _video;

  @override
  void initState() {
    super.initState();
    _viewType = 'remote-generated-video-${_nextViewId++}';
    _video = html.VideoElement()
      ..src = widget.uri.toString()
      ..controls = true
      ..preload = 'metadata'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#090d12';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _video);
  }

  @override
  void didUpdateWidget(covariant RemoteVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) _video.src = widget.uri.toString();
  }

  @override
  void dispose() {
    _video
      ..pause()
      ..removeAttribute('src')
      ..load();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: widget.aspectRatio,
    child: HtmlElementView(
      key: const ValueKey('remote-video-preview'),
      viewType: _viewType,
    ),
  );
}
