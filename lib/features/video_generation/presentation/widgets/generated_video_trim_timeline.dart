import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/generated_video_trim_range.dart';

class GeneratedVideoTrimTimeline extends StatelessWidget {
  const GeneratedVideoTrimTimeline({
    super.key,
    required this.range,
    required this.position,
    required this.onSeek,
    required this.onChanged,
    required this.onChangeEnd,
    this.frameRate = 30,
  });

  final GeneratedVideoTrimRange range;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<GeneratedVideoTrimRange> onChanged;
  final ValueChanged<GeneratedVideoTrimRange> onChangeEnd;
  final int frameRate;

  @override
  Widget build(BuildContext context) {
    final durationMs = math.max(1, range.sourceDuration.inMilliseconds);
    final values = RangeValues(
      range.inPoint.inMilliseconds.toDouble().clamp(0, durationMs.toDouble()),
      range.outPoint.inMilliseconds.toDouble().clamp(0, durationMs.toDouble()),
    );
    return SizedBox(
      key: const ValueKey('generated-video-io-timeline'),
      height: 104,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _VideoTimecodeRulerPainter(
                range: range,
                position: position,
                frameRate: frameRate,
                colorScheme: Theme.of(context).colorScheme,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 66,
            child: LayoutBuilder(
              builder: (context, constraints) {
                void seekToLocalPosition(Offset localPosition) {
                  final width = math.max(1.0, constraints.maxWidth);
                  final fraction = (localPosition.dx / width).clamp(0.0, 1.0);
                  onSeek(
                    Duration(milliseconds: (durationMs * fraction).round()),
                  );
                }

                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: const ValueKey('generated-video-io-seek-area'),
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) =>
                        seekToLocalPosition(details.localPosition),
                    onHorizontalDragStart: (details) =>
                        seekToLocalPosition(details.localPosition),
                    onHorizontalDragUpdate: (details) =>
                        seekToLocalPosition(details.localPosition),
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: RangeSlider(
              key: const ValueKey('generated-video-io-range-slider'),
              min: 0,
              max: durationMs.toDouble(),
              values: values,
              labels: RangeLabels(
                'I ${formatVideoTimecode(range.inPoint, frameRate: frameRate)}',
                'O ${formatVideoTimecode(range.outPoint, frameRate: frameRate)}',
              ),
              onChanged: (next) =>
                  onChanged(_normalizedRange(next, durationMs: durationMs)),
              onChangeEnd: (next) =>
                  onChangeEnd(_normalizedRange(next, durationMs: durationMs)),
            ),
          ),
        ],
      ),
    );
  }

  GeneratedVideoTrimRange _normalizedRange(
    RangeValues values, {
    required int durationMs,
  }) {
    final frameMs = math.max(1, (1000 / frameRate).round());
    int snap(double value) =>
        ((value / frameMs).round() * frameMs).clamp(0, durationMs);

    var inPointMs = snap(values.start).clamp(0, durationMs - 1);
    var outPointMs = snap(values.end).clamp(1, durationMs);
    if (outPointMs - inPointMs < frameMs) {
      if (inPointMs + frameMs <= durationMs) {
        outPointMs = inPointMs + frameMs;
      } else {
        inPointMs = math.max(0, durationMs - frameMs);
        outPointMs = durationMs;
      }
    }
    return GeneratedVideoTrimRange(
      sourceDuration: Duration(milliseconds: durationMs),
      inPoint: Duration(milliseconds: inPointMs),
      outPoint: Duration(milliseconds: outPointMs),
    );
  }
}

class _VideoTimecodeRulerPainter extends CustomPainter {
  const _VideoTimecodeRulerPainter({
    required this.range,
    required this.position,
    required this.frameRate,
    required this.colorScheme,
  });

  final GeneratedVideoTrimRange range;
  final Duration position;
  final int frameRate;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final durationMs = math.max(1, range.sourceDuration.inMilliseconds);
    double xFor(Duration value) =>
        size.width * value.inMilliseconds.clamp(0, durationMs) / durationMs;

    final background = Paint()..color = colorScheme.surfaceContainerHighest;
    final selected = Paint()
      ..color = colorScheme.primaryContainer.withValues(alpha: 0.82);
    final tick = Paint()
      ..color = colorScheme.onSurfaceVariant.withValues(alpha: 0.72)
      ..strokeWidth = 1;
    final playhead = Paint()
      ..color = colorScheme.error
      ..strokeWidth = 2;
    final trackRect = Rect.fromLTWH(0, 24, size.width, 42);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(6)),
      background,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        xFor(range.inPoint),
        trackRect.top,
        xFor(range.outPoint),
        trackRect.bottom,
      ),
      selected,
    );

    final intervalMs = _tickIntervalMs(durationMs);
    for (
      var timestampMs = 0;
      timestampMs <= durationMs;
      timestampMs += intervalMs
    ) {
      final x = size.width * timestampMs / durationMs;
      canvas.drawLine(Offset(x, 24), Offset(x, 38), tick);
      final label = TextPainter(
        text: TextSpan(
          text: formatVideoTimecode(
            Duration(milliseconds: timestampMs),
            frameRate: frameRate,
          ),
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      label.paint(
        canvas,
        Offset(
          (x - label.width / 2).clamp(0, math.max(0, size.width - label.width)),
          5,
        ),
      );
    }

    final positionX = xFor(position);
    canvas.drawLine(
      Offset(positionX, trackRect.top - 4),
      Offset(positionX, trackRect.bottom + 4),
      playhead,
    );
    _paintPointLabel(canvas, 'I', xFor(range.inPoint), colorScheme.primary);
    _paintPointLabel(canvas, 'O', xFor(range.outPoint), colorScheme.primary);
  }

  void _paintPointLabel(Canvas canvas, String label, double x, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(x - painter.width / 2, 68));
  }

  int _tickIntervalMs(int durationMs) => switch (durationMs) {
    <= 10000 => 1000,
    <= 30000 => 2000,
    <= 120000 => 10000,
    <= 600000 => 30000,
    _ => 60000,
  };

  @override
  bool shouldRepaint(covariant _VideoTimecodeRulerPainter oldDelegate) =>
      oldDelegate.range != range ||
      oldDelegate.position != position ||
      oldDelegate.frameRate != frameRate ||
      oldDelegate.colorScheme != colorScheme;
}

String formatVideoTimecode(Duration duration, {int frameRate = 30}) {
  final totalFrames = math.max(
    0,
    (duration.inMicroseconds * frameRate / Duration.microsecondsPerSecond)
        .floor(),
  );
  final frames = totalFrames % frameRate;
  final totalSeconds = totalFrames ~/ frameRate;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}:'
      '${frames.toString().padLeft(2, '0')}';
}
