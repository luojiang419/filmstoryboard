import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../core/widgets/adaptive_video_viewport.dart';
import '../../domain/generated_video_trim_range.dart';
import 'generated_video_trim_timeline.dart';

typedef GeneratedVideoTrimCommit =
    FutureOr<void> Function(GeneratedVideoTrimRange range);

Future<void> showGeneratedVideoTrimEditor(
  BuildContext context, {
  required String title,
  required File file,
  required GeneratedVideoTrimRange initialRange,
  required GeneratedVideoTrimCommit onChanged,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _GeneratedVideoTrimEditorDialog(
    title: title,
    file: file,
    initialRange: initialRange,
    onChanged: onChanged,
  ),
);

class _GeneratedVideoTrimEditorDialog extends StatelessWidget {
  const _GeneratedVideoTrimEditorDialog({
    required this.title,
    required this.file,
    required this.initialRange,
    required this.onChanged,
  });

  final String title;
  final File file;
  final GeneratedVideoTrimRange initialRange;
  final GeneratedVideoTrimCommit onChanged;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 880,
      height: math.min(MediaQuery.sizeOf(context).height * 0.72, 700),
      child: GeneratedVideoTrimEditor(
        file: file,
        initialRange: initialRange,
        onChanged: onChanged,
      ),
    ),
    actions: [
      FilledButton(
        key: const ValueKey('close-generated-video-io-editor'),
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

class GeneratedVideoTrimEditor extends StatefulWidget {
  const GeneratedVideoTrimEditor({
    super.key,
    required this.file,
    required this.initialRange,
    required this.onChanged,
  });

  final File file;
  final GeneratedVideoTrimRange initialRange;
  final GeneratedVideoTrimCommit onChanged;

  @override
  State<GeneratedVideoTrimEditor> createState() =>
      _GeneratedVideoTrimEditorState();
}

class _GeneratedVideoTrimEditorState extends State<GeneratedVideoTrimEditor> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  late GeneratedVideoTrimRange _range;
  late bool _followFullOutPoint;
  Duration _position = Duration.zero;
  Duration _persistedSourceDuration = Duration.zero;
  var _playing = false;
  var _error = '';

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    _followFullOutPoint = widget.initialRange.isFullRange;
    _position = _range.inPoint;
    _player = Player();
    _videoController = VideoController(_player);
    _durationSubscription = _player.stream.duration.listen(_handleDuration);
    _positionSubscription = _player.stream.position.listen(_handlePosition);
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant GeneratedVideoTrimEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path == widget.file.path) return;
    _range = widget.initialRange;
    _followFullOutPoint = widget.initialRange.isFullRange;
    _position = _range.inPoint;
    _persistedSourceDuration = Duration.zero;
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.file.path), play: false);
      _handleDuration(_player.state.duration);
      await _player.seek(_range.inPoint);
      if (mounted) setState(() => _error = '');
    } catch (error) {
      if (mounted) setState(() => _error = '视频加载失败：$error');
    }
  }

  void _handleDuration(Duration duration) {
    if (!mounted || duration <= Duration.zero) return;
    final normalized = GeneratedVideoTrimRange.fromMilliseconds(
      sourceDurationMs: duration.inMilliseconds,
      trimInMs: _range.inPoint.inMilliseconds,
      trimOutMs: _followFullOutPoint ? 0 : _range.outPoint.inMilliseconds,
      fallbackDurationMs: duration.inMilliseconds,
    );
    setState(() {
      _range = normalized;
      _position = _clampPosition(_position, normalized);
    });
    if (_persistedSourceDuration != normalized.sourceDuration) {
      _persistedSourceDuration = normalized.sourceDuration;
      unawaited(_commit(normalized));
    }
  }

  void _handlePosition(Duration position) {
    if (_playing && position >= _range.outPoint) {
      unawaited(_player.pause());
      unawaited(_player.seek(_range.inPoint));
      if (mounted) setState(() => _position = _range.inPoint);
      return;
    }
    if (mounted) setState(() => _position = position);
  }

  Future<void> _seekTo(Duration position) async {
    final target = Duration(
      milliseconds: position.inMilliseconds.clamp(
        0,
        _range.sourceDuration.inMilliseconds,
      ),
    );
    if (_playing) await _player.pause();
    if (mounted) setState(() => _position = target);
    await _player.seek(target);
  }

  void _handleRangeChanged(GeneratedVideoTrimRange range) {
    final inPointChanged = range.inPoint != _range.inPoint;
    _followFullOutPoint = range.isFullRange;
    setState(() {
      _range = range;
      _position = _clampPosition(_position, range);
    });
    final seekTarget = inPointChanged
        ? range.inPoint
        : range.outPoint - const Duration(milliseconds: 33);
    unawaited(_player.seek(_clampPosition(seekTarget, range)));
  }

  void _handleRangeChangeEnd(GeneratedVideoTrimRange range) {
    _handleRangeChanged(range);
    unawaited(_commit(range));
  }

  Future<void> _commit(GeneratedVideoTrimRange range) async {
    try {
      await widget.onChanged(range);
    } catch (error) {
      if (mounted) setState(() => _error = '保存 IO 点失败：$error');
    }
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (_position < _range.inPoint || _position >= _range.outPoint) {
      await _player.seek(_range.inPoint);
    }
    await _player.play();
  }

  void _resetRange() {
    _followFullOutPoint = true;
    final fullRange = GeneratedVideoTrimRange(
      sourceDuration: _range.sourceDuration,
      inPoint: Duration.zero,
      outPoint: _range.sourceDuration,
    );
    setState(() {
      _range = fullRange;
      _position = Duration.zero;
    });
    unawaited(_player.seek(Duration.zero));
    unawaited(_commit(fullRange));
  }

  Duration _clampPosition(Duration position, GeneratedVideoTrimRange range) {
    if (position < range.inPoint) return range.inPoint;
    if (position >= range.outPoint) return range.inPoint;
    return position;
  }

  @override
  void dispose() {
    unawaited(_durationSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: AdaptiveVideoViewport(
          player: _player,
          child: _error.isEmpty
              ? Video(
                  controller: _videoController,
                  controls: null,
                  fit: BoxFit.contain,
                )
              : Center(child: Text(_error)),
        ),
      ),
      const SizedBox(height: 14),
      GeneratedVideoTrimTimeline(
        range: _range,
        position: _position,
        onSeek: (position) => unawaited(_seekTo(position)),
        onChanged: _handleRangeChanged,
        onChangeEnd: _handleRangeChangeEnd,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          IconButton.filledTonal(
            key: const ValueKey('generated-video-io-play'),
            onPressed: _error.isEmpty ? _togglePlayback : null,
            icon: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'I ${formatVideoTimecode(_range.inPoint)}  ·  '
            '${formatVideoTimecode(_position)}  ·  '
            'O ${formatVideoTimecode(_range.outPoint)}',
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('generated-video-io-reset'),
            onPressed: _resetRange,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('恢复完整范围'),
          ),
        ],
      ),
    ],
  );
}
