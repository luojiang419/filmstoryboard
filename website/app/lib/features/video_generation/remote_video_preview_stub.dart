import 'package:flutter/material.dart';

class RemoteVideoPreview extends StatelessWidget {
  const RemoteVideoPreview({
    super.key,
    required this.uri,
    required this.aspectRatio,
  });

  final Uri uri;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspectRatio,
    child: ColoredBox(
      key: const ValueKey('remote-video-preview'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.play_circle_outline_rounded)),
    ),
  );
}
