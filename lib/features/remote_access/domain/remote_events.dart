import 'dart:async';

class RemoteChangeEvent {
  const RemoteChangeEvent({
    required this.sequence,
    required this.type,
    required this.timestamp,
    this.projectId,
    this.resourceId,
    this.revision,
    this.data = const {},
  });

  final int sequence;
  final String type;
  final DateTime timestamp;
  final String? projectId;
  final String? resourceId;
  final int? revision;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'type': type,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (projectId != null) 'projectId': projectId,
    if (resourceId != null) 'resourceId': resourceId,
    if (revision != null) 'revision': revision,
    if (data.isNotEmpty) 'data': data,
  };
}

class RemoteChangeBus {
  final StreamController<RemoteChangeEvent> _controller =
      StreamController<RemoteChangeEvent>.broadcast(sync: true);
  int _sequence = 0;

  Stream<RemoteChangeEvent> get events => _controller.stream;
  int get lastSequence => _sequence;

  RemoteChangeEvent publish({
    required String type,
    String? projectId,
    String? resourceId,
    int? revision,
    Map<String, Object?> data = const {},
  }) {
    final event = RemoteChangeEvent(
      sequence: ++_sequence,
      type: type,
      timestamp: DateTime.now().toUtc(),
      projectId: projectId,
      resourceId: resourceId,
      revision: revision,
      data: data,
    );
    _controller.add(event);
    return event;
  }

  Future<void> close() => _controller.close();
}
