import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/replicate_asset_preparation_models.dart';

Future<ReplicateEditablePoseData?> showReplicatePoseEditorDialog({
  required BuildContext context,
  required ReplicateEditablePoseData initialPose,
}) => showDialog<ReplicateEditablePoseData>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ReplicatePoseEditorDialog(initialPose: initialPose),
);

class ReplicatePoseEditorDialog extends StatefulWidget {
  const ReplicatePoseEditorDialog({super.key, required this.initialPose});

  final ReplicateEditablePoseData initialPose;

  @override
  State<ReplicatePoseEditorDialog> createState() =>
      _ReplicatePoseEditorDialogState();
}

class _ReplicatePoseEditorDialogState extends State<ReplicatePoseEditorDialog> {
  late ReplicateEditablePoseData _pose;
  late String _selectedPersonId;
  int? _activePointIndex;

  @override
  void initState() {
    super.initState();
    _pose = widget.initialPose;
    _selectedPersonId = _pose.peopleFromLeftToRight.first.id;
  }

  ReplicatePosePerson get _selectedPerson => _pose.people.firstWhere(
    (person) => person.id == _selectedPersonId,
    orElse: () => _pose.peopleFromLeftToRight.first,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 960,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.device_hub_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '编辑动作关节',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭关节编辑器',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Text('选择模特后拖动关节点；黄色点表示人工调整。保存会同步更新结构化数据和动作骨架图。'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final person in _pose.peopleFromLeftToRight)
                    ChoiceChip(
                      key: ValueKey(
                        'pose-editor-person-${person.modelSlotIndex}',
                      ),
                      label: Text(_personLabel(person.modelSlotIndex)),
                      selected: person.id == _selectedPersonId,
                      onSelected: (_) => setState(() {
                        _selectedPersonId = person.id;
                        _activePointIndex = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.biggest;
                        return GestureDetector(
                          key: const ValueKey('pose-editor-canvas'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (details) =>
                              _selectNearestPoint(details.localPosition, size),
                          onPanUpdate: (details) =>
                              _moveActivePoint(details.localPosition, size),
                          onPanEnd: (_) => setState(() {}),
                          child: CustomPaint(
                            painter: _ReplicatePosePainter(
                              pose: _pose,
                              selectedPersonId: _selectedPersonId,
                              activePointIndex: _activePointIndex,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _activePointIndex == null
                          ? '拖动任一可见关节点进行校正'
                          : '正在调整关节 #${_activePointIndex! + 1} · ${_personLabel(_selectedPerson.modelSlotIndex)}',
                      key: const ValueKey('pose-editor-selection-status'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('save-pose-editor'),
                    onPressed: () => Navigator.of(context).pop(_pose),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存关节调整'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectNearestPoint(Offset localPosition, Size size) {
    final transform = _PoseCanvasTransform.forCanvas(
      size,
      sourceWidth: _pose.sourceWidth,
      sourceHeight: _pose.sourceHeight,
    );
    var nearestDistance = 24.0;
    int? nearestIndex;
    for (final point in _selectedPerson.keypoints) {
      if (!_isEditable(point)) continue;
      final distance = (transform.toCanvas(point) - localPosition).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestIndex = point.index;
      }
    }
    setState(() => _activePointIndex = nearestIndex);
    if (nearestIndex != null) _moveActivePoint(localPosition, size);
  }

  void _moveActivePoint(Offset localPosition, Size size) {
    final pointIndex = _activePointIndex;
    if (pointIndex == null) return;
    final transform = _PoseCanvasTransform.forCanvas(
      size,
      sourceWidth: _pose.sourceWidth,
      sourceHeight: _pose.sourceHeight,
    );
    final source = transform.toSource(localPosition);
    final x = source.dx.clamp(0, _pose.sourceWidth - 1).toDouble();
    final y = source.dy.clamp(0, _pose.sourceHeight - 1).toDouble();
    setState(() {
      _pose = ReplicateEditablePoseData(
        sourceWidth: _pose.sourceWidth,
        sourceHeight: _pose.sourceHeight,
        people: [
          for (final person in _pose.people)
            if (person.id == _selectedPersonId)
              person.copyWith(
                keypoints: [
                  for (final point in person.keypoints)
                    point.index == pointIndex
                        ? point.copyWith(
                            x: x,
                            y: y,
                            confidence: 1,
                            manuallyAdjusted: true,
                          )
                        : point,
                ],
              )
            else
              person,
        ],
      );
    });
  }

  static bool _isEditable(ReplicatePoseKeypoint point) =>
      point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0;

  static String _personLabel(int slotIndex) {
    final suffix = slotIndex >= 0 && slotIndex < 26
        ? String.fromCharCode(65 + slotIndex)
        : '${slotIndex + 1}';
    return '模特 $suffix';
  }
}

class _ReplicatePosePainter extends CustomPainter {
  const _ReplicatePosePainter({
    required this.pose,
    required this.selectedPersonId,
    required this.activePointIndex,
  });

  final ReplicateEditablePoseData pose;
  final String selectedPersonId;
  final int? activePointIndex;

  static const _bodyEdges = <(int, int)>[
    (5, 6),
    (5, 7),
    (7, 9),
    (6, 8),
    (8, 10),
    (5, 11),
    (6, 12),
    (11, 12),
    (11, 13),
    (13, 15),
    (12, 14),
    (14, 16),
    (0, 1),
    (0, 2),
    (1, 3),
    (2, 4),
    (15, 17),
    (15, 18),
    (15, 19),
    (16, 20),
    (16, 21),
    (16, 22),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (pose.sourceWidth <= 0 || pose.sourceHeight <= 0) return;
    final transform = _PoseCanvasTransform.forCanvas(
      size,
      sourceWidth: pose.sourceWidth,
      sourceHeight: pose.sourceHeight,
    );
    for (final person in pose.peopleFromLeftToRight) {
      final selected = person.id == selectedPersonId;
      final linePaint = Paint()
        ..color = selected ? const Color(0xFF41C7FF) : const Color(0x5941C7FF)
        ..strokeWidth = selected ? 2.2 : 1.2
        ..strokeCap = StrokeCap.round;
      for (final (firstIndex, secondIndex) in _bodyEdges) {
        if (firstIndex >= person.keypoints.length ||
            secondIndex >= person.keypoints.length) {
          continue;
        }
        final first = person.keypoints[firstIndex];
        final second = person.keypoints[secondIndex];
        if (!_visible(first) || !_visible(second)) continue;
        canvas.drawLine(
          transform.toCanvas(first),
          transform.toCanvas(second),
          linePaint,
        );
      }
      for (final handStart in const [91, 112]) {
        _drawHand(canvas, transform, person, handStart, linePaint);
      }
      for (final point in person.keypoints) {
        if (!_visible(point)) continue;
        final active = selected && point.index == activePointIndex;
        final radius = active
            ? 6.0
            : point.index < 23
            ? 4.0
            : point.index < 91
            ? 2.1
            : 2.8;
        final pointPaint = Paint()
          ..color = point.manuallyAdjusted
              ? const Color(0xFFFFD54F)
              : selected
              ? const Color(0xFFFF557A)
              : const Color(0x66FF557A);
        canvas.drawCircle(transform.toCanvas(point), radius, pointPaint);
        if (active) {
          canvas.drawCircle(
            transform.toCanvas(point),
            radius + 3,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      }
    }
  }

  static void _drawHand(
    Canvas canvas,
    _PoseCanvasTransform transform,
    ReplicatePosePerson person,
    int start,
    Paint paint,
  ) {
    const fingers = <List<int>>[
      [0, 1, 2, 3, 4],
      [0, 5, 6, 7, 8],
      [0, 9, 10, 11, 12],
      [0, 13, 14, 15, 16],
      [0, 17, 18, 19, 20],
    ];
    for (final finger in fingers) {
      for (var index = 0; index < finger.length - 1; index++) {
        final firstIndex = start + finger[index];
        final secondIndex = start + finger[index + 1];
        if (firstIndex >= person.keypoints.length ||
            secondIndex >= person.keypoints.length) {
          continue;
        }
        final first = person.keypoints[firstIndex];
        final second = person.keypoints[secondIndex];
        if (!_visible(first) || !_visible(second)) continue;
        canvas.drawLine(
          transform.toCanvas(first),
          transform.toCanvas(second),
          paint,
        );
      }
    }
  }

  static bool _visible(ReplicatePoseKeypoint point) =>
      point.confidence > 0.3 &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.x >= 0 &&
      point.y >= 0;

  @override
  bool shouldRepaint(covariant _ReplicatePosePainter oldDelegate) =>
      oldDelegate.pose != pose ||
      oldDelegate.selectedPersonId != selectedPersonId ||
      oldDelegate.activePointIndex != activePointIndex;
}

class _PoseCanvasTransform {
  const _PoseCanvasTransform({required this.scale, required this.offset});

  factory _PoseCanvasTransform.forCanvas(
    Size size, {
    required int sourceWidth,
    required int sourceHeight,
  }) {
    final scale = math.min(
      size.width / sourceWidth,
      size.height / sourceHeight,
    );
    return _PoseCanvasTransform(
      scale: scale,
      offset: Offset(
        (size.width - sourceWidth * scale) / 2,
        (size.height - sourceHeight * scale) / 2,
      ),
    );
  }

  final double scale;
  final Offset offset;

  Offset toCanvas(ReplicatePoseKeypoint point) =>
      Offset(point.x * scale, point.y * scale) + offset;

  Offset toSource(Offset local) =>
      Offset((local.dx - offset.dx) / scale, (local.dy - offset.dy) / scale);
}
