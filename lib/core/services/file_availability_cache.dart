import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

typedef FileExistsCheck = Future<bool> Function(String path);

class FileAvailabilityCache extends ChangeNotifier {
  FileAvailabilityCache({
    FileExistsCheck? fileExists,
    this.staleAfter = const Duration(seconds: 2),
  }) : _fileExists = fileExists ?? _defaultFileExists;

  final FileExistsCheck _fileExists;
  final Duration staleAfter;
  final Map<String, _FileAvailabilityEntry> _entries = {};
  var _disposed = false;

  bool exists(String rawPath, {bool defaultValue = false}) {
    final path = rawPath.trim();
    if (path.isEmpty) {
      return false;
    }
    final now = DateTime.now();
    final entry = _entries.putIfAbsent(
      path,
      () => _FileAvailabilityEntry(exists: defaultValue),
    );
    final checkedAt = entry.checkedAt;
    final stale = checkedAt == null || now.difference(checkedAt) >= staleAfter;
    if (stale && entry.inFlight == null) {
      unawaited(_refresh(path, entry));
    }
    return entry.exists ?? defaultValue;
  }

  Future<bool> checkNow(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) {
      return false;
    }
    final entry = _entries.putIfAbsent(path, _FileAvailabilityEntry.new);
    return entry.inFlight ?? _refresh(path, entry);
  }

  void invalidate(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return;
    _entries.remove(path);
    if (!_disposed) notifyListeners();
  }

  Future<bool> _refresh(String path, _FileAvailabilityEntry entry) {
    final future = _performRefresh(path, entry);
    entry.inFlight = future;
    return future;
  }

  Future<bool> _performRefresh(
    String path,
    _FileAvailabilityEntry entry,
  ) async {
    bool result;
    try {
      result = await _fileExists(path);
    } catch (_) {
      result = false;
    }
    final previous = entry.exists;
    entry
      ..exists = result
      ..checkedAt = DateTime.now()
      ..inFlight = null;
    if (!_disposed && previous != result) {
      notifyListeners();
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<bool> _defaultFileExists(String path) => File(path).exists();
}

class FileAvailabilityScope extends InheritedNotifier<FileAvailabilityCache> {
  const FileAvailabilityScope({
    super.key,
    required FileAvailabilityCache cache,
    required super.child,
  }) : super(notifier: cache);

  static FileAvailabilityCache of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<FileAvailabilityScope>();
    assert(scope != null, 'FileAvailabilityScope is missing');
    return scope!.notifier!;
  }
}

class _FileAvailabilityEntry {
  _FileAvailabilityEntry({this.exists});

  bool? exists;
  DateTime? checkedAt;
  Future<bool>? inFlight;
}
