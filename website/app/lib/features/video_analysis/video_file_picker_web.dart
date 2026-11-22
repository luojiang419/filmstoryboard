// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'selected_video_file.dart';

Future<RemoteSelectedVideoFile?> pickVideoFile() async {
  final input = html.FileUploadInputElement()
    ..accept = '.mp4,.mov,.mkv,.avi,.webm,.m4v,video/*';
  input.click();
  await input.onChange.first;
  final file = input.files?.firstOrNull;
  if (file == null) return null;
  return RemoteSelectedVideoFile(
    name: file.name,
    size: file.size,
    openRead: () => _readChunks(file),
  );
}

Stream<List<int>> _readChunks(html.File file) async* {
  const chunkSize = 8 * 1024 * 1024;
  for (var offset = 0; offset < file.size; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, file.size);
    final reader = html.FileReader()
      ..readAsArrayBuffer(file.slice(offset, end));
    await reader.onLoad.first;
    final result = reader.result;
    if (result is ByteBuffer) {
      yield result.asUint8List();
    } else if (result is Uint8List) {
      yield result;
    } else {
      throw StateError('浏览器未返回可读取的视频数据');
    }
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
