import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ImageGenerationDiagnosticLogger {
  ImageGenerationDiagnosticLogger(this.logsDirectory);

  static const retention = Duration(days: 7);
  static const _filePrefix = 'image-generation-';

  final Directory logsDirectory;
  Future<void> _pendingWrite = Future<void>.value();

  Future<void> write(String event, Map<String, Object?> details) {
    _pendingWrite = _pendingWrite.then((_) => _write(event, details));
    return _pendingWrite;
  }

  Future<void> _write(String event, Map<String, Object?> details) async {
    try {
      final now = DateTime.now();
      if (!logsDirectory.existsSync()) {
        await logsDirectory.create(recursive: true);
      }
      await _deleteExpiredLogs(now);
      final file = File(
        p.join(logsDirectory.path, '$_filePrefix${_dateKey(now)}.log'),
      );
      await file.writeAsString(
        '${jsonEncode(<String, Object?>{'time': now.toIso8601String(), 'event': event, ...details})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 诊断日志失败不能中断或改变图片生成结果。
    }
  }

  Future<void> _deleteExpiredLogs(DateTime now) async {
    final cutoff = now.subtract(retention);
    for (final file in logsDirectory.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (!name.startsWith(_filePrefix) || !name.endsWith('.log')) {
        continue;
      }
      if ((await file.lastModified()).isBefore(cutoff)) {
        await file.delete();
      }
    }
  }

  static String safeError(Object error) {
    var text = error.toString().replaceFirst(RegExp(r'^\w+Exception:\s*'), '');
    text = text.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/-]+', caseSensitive: false),
      'Bearer ***',
    );
    text = text.replaceAll(
      RegExp(r'([?&](?:key|api_key|token)=)[^&\s]+', caseSensitive: false),
      r'$1***',
    );
    return text.length <= 1200 ? text : '${text.substring(0, 1200)}…';
  }

  String _dateKey(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }
}
