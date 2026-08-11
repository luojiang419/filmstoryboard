// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html';

class RemoteEventClient {
  WebSocket? _socket;
  StreamController<Map<String, Object?>>? _controller;

  Stream<Map<String, Object?>> connect(Uri uri) {
    unawaited(close());
    final controller = StreamController<Map<String, Object?>>.broadcast();
    final socket = WebSocket(uri.toString());
    _controller = controller;
    _socket = socket;
    socket.onMessage.listen((event) {
      try {
        final decoded = jsonDecode('${event.data}');
        if (decoded is Map) {
          controller.add(decoded.map((key, value) => MapEntry('$key', value)));
        }
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    });
    socket.onError.listen((_) {
      controller.addError(StateError('实时连接发生错误'));
    });
    socket.onClose.listen((_) {
      if (!controller.isClosed) unawaited(controller.close());
    });
    return controller.stream;
  }

  Future<void> close() async {
    _socket?.close();
    _socket = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
