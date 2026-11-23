import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class VisionRunLogger {
  const VisionRunLogger(this.logsDirectory);

  static const retention = Duration(days: 3);
  static const _filePrefix = 'vision-auto-sort-';

  final Directory logsDirectory;

  Future<void> write(String event, Map<String, Object?> details) async {
    try {
      final now = DateTime.now();
      if (!logsDirectory.existsSync()) {
        await logsDirectory.create(recursive: true);
      }
      await _deleteExpiredLogs(now);
      final file = File(
        p.join(logsDirectory.path, '$_filePrefix${_dateKey(now)}.log'),
      );
      final payload = <String, Object?>{
        'time': now.toIso8601String(),
        'event': event,
        ...details,
      };
      await file.writeAsString(
        '${jsonEncode(payload)}\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // 日志不能影响用户的自动解析/重排序主流程。
    }
  }

  Future<void> _deleteExpiredLogs(DateTime now) async {
    final cutoff = now.subtract(retention);
    final entries = logsDirectory.listSync().whereType<File>();
    for (final file in entries) {
      final name = p.basename(file.path);
      if (!name.startsWith(_filePrefix) || !name.endsWith('.log')) {
        continue;
      }
      final modified = await file.lastModified();
      if (modified.isBefore(cutoff)) {
        await file.delete();
      }
    }
  }

  String _dateKey(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }
}
