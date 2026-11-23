import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

class GeneratedImageRecovery {
  static Future<({Map<String, String> paths, bool scanned})> resolve(
    String rootPath,
    Map<String, String> pathsById,
  ) => Isolate.run(() => _resolve(rootPath, pathsById));

  static Future<({Map<String, String> paths, bool scanned})> _resolve(
    String rootPath,
    Map<String, String> pathsById,
  ) async {
    final missing = <String, String>{
      for (final entry in pathsById.entries)
        if (entry.value.isNotEmpty && !File(entry.value).existsSync())
          entry.key: p.basename(entry.value),
    };
    final root = Directory(rootPath);
    if (missing.isEmpty || !await root.exists()) {
      return (paths: <String, String>{}, scanned: false);
    }
    final byName = <String, String>{};
    final ambiguous = <String>{};
    final wanted = missing.values.toSet();
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!wanted.contains(name)) continue;
      if (byName.containsKey(name)) ambiguous.add(name);
      byName[name] = entry.path;
    }
    return (
      paths: <String, String>{
        for (final entry in missing.entries)
          if (byName.containsKey(entry.value) &&
              !ambiguous.contains(entry.value))
            entry.key: byName[entry.value]!,
      },
      scanned: true,
    );
  }
}
