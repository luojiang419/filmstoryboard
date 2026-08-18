import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'windows_sta_file_dialog_client.dart';

typedef OpenFileDialog =
    Future<file_selector.XFile?> Function({
      List<file_selector.XTypeGroup> acceptedTypeGroups,
      String? initialDirectory,
      String? confirmButtonText,
    });

typedef OpenFilesDialog =
    Future<List<file_selector.XFile>> Function({
      List<file_selector.XTypeGroup> acceptedTypeGroups,
      String? initialDirectory,
      String? confirmButtonText,
    });

typedef SaveFileDialog =
    Future<file_selector.FileSaveLocation?> Function({
      List<file_selector.XTypeGroup> acceptedTypeGroups,
      String? initialDirectory,
      String? suggestedName,
      String? confirmButtonText,
      bool? canCreateDirectories,
    });

typedef FileDialogEventSink = Future<void> Function(Map<String, Object?> event);

class DesktopFileDialogService {
  DesktopFileDialogService({
    required Directory defaultDirectory,
    Directory? logsDirectory,
    OpenFileDialog? openFileDialog,
    OpenFilesDialog? openFilesDialog,
    SaveFileDialog? saveFileDialog,
    WindowsStaFileDialogClient? windowsStaFileDialogClient,
    bool? useWindowsStaFileDialog,
    Future<void> Function()? beforeShow,
    FileDialogEventSink? eventSink,
    List<Duration> warningThresholds = const [
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : _defaultDirectory = defaultDirectory,
       _beforeShow = beforeShow ?? _yieldToNextFrame,
       _eventSink =
           eventSink ??
           (logsDirectory == null
               ? _debugEventSink
               : _JsonLineFileDialogLogger(
                   File(p.join(logsDirectory.path, 'file_dialog.jsonl')),
                 ).write),
       _warningThresholds = List.unmodifiable(warningThresholds) {
    final useStaDialog = useWindowsStaFileDialog ?? Platform.isWindows;
    final staClient =
        windowsStaFileDialogClient ?? const WindowsStaFileDialogClient();
    _openFileDialog =
        openFileDialog ??
        (useStaDialog ? staClient.openFile : file_selector.openFile);
    _openFilesDialog =
        openFilesDialog ??
        (useStaDialog ? staClient.openFiles : file_selector.openFiles);
    _saveFileDialog =
        saveFileDialog ??
        (useStaDialog
            ? staClient.getSaveLocation
            : file_selector.getSaveLocation);
  }

  final Directory _defaultDirectory;
  late final OpenFileDialog _openFileDialog;
  late final OpenFilesDialog _openFilesDialog;
  late final SaveFileDialog _saveFileDialog;
  final Future<void> Function() _beforeShow;
  final FileDialogEventSink _eventSink;
  final List<Duration> _warningThresholds;
  final ValueNotifier<bool> isBusy = ValueNotifier(false);

  var _requestSequence = 0;

  Future<file_selector.XFile?> openFile({
    required String source,
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) {
    return _run<file_selector.XFile?>(
      source: source,
      operation: 'openFile',
      initialDirectory: initialDirectory,
      busyResult: null,
      show: (safeDirectory) => _openFileDialog(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: safeDirectory,
        confirmButtonText: confirmButtonText,
      ),
      resultSummary: (result) => {'selectedCount': result == null ? 0 : 1},
    );
  }

  Future<List<file_selector.XFile>> openFiles({
    required String source,
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) {
    return _run<List<file_selector.XFile>>(
      source: source,
      operation: 'openFiles',
      initialDirectory: initialDirectory,
      busyResult: const [],
      show: (safeDirectory) => _openFilesDialog(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: safeDirectory,
        confirmButtonText: confirmButtonText,
      ),
      resultSummary: (result) => {'selectedCount': result.length},
    );
  }

  Future<file_selector.FileSaveLocation?> getSaveLocation({
    required String source,
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
    bool? canCreateDirectories,
  }) {
    return _run<file_selector.FileSaveLocation?>(
      source: source,
      operation: 'getSaveLocation',
      initialDirectory: initialDirectory,
      busyResult: null,
      show: (safeDirectory) => _saveFileDialog(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: safeDirectory,
        suggestedName: suggestedName,
        confirmButtonText: confirmButtonText,
        canCreateDirectories: canCreateDirectories,
      ),
      resultSummary: (result) => {'selectedCount': result == null ? 0 : 1},
    );
  }

  Future<T> _run<T>({
    required String source,
    required String operation,
    required String? initialDirectory,
    required T busyResult,
    required Future<T> Function(String safeDirectory) show,
    required Map<String, Object?> Function(T result) resultSummary,
  }) async {
    final requestId = ++_requestSequence;
    if (isBusy.value) {
      await _emit({
        'requestId': requestId,
        'source': source,
        'operation': operation,
        'phase': 'rejected_busy',
      });
      return busyResult;
    }

    isBusy.value = true;
    final stopwatch = Stopwatch()..start();
    final timers = <Timer>[];
    try {
      final safeDirectory = await _resolveInitialDirectory(initialDirectory);
      await _emit({
        'requestId': requestId,
        'source': source,
        'operation': operation,
        'phase': 'requested',
        'initialDirectory': safeDirectory,
      });

      await _beforeShow();
      for (final threshold in _warningThresholds) {
        timers.add(
          Timer(threshold, () {
            unawaited(
              _emit({
                'requestId': requestId,
                'source': source,
                'operation': operation,
                'phase': 'slow',
                'elapsedMs': stopwatch.elapsedMilliseconds,
                'thresholdMs': threshold.inMilliseconds,
                'initialDirectory': safeDirectory,
              }),
            );
          }),
        );
      }

      final result = await show(safeDirectory);
      await _emit({
        'requestId': requestId,
        'source': source,
        'operation': operation,
        'phase': 'completed',
        'elapsedMs': stopwatch.elapsedMilliseconds,
        'initialDirectory': safeDirectory,
        ...resultSummary(result),
      });
      return result;
    } catch (error, stackTrace) {
      await _emit({
        'requestId': requestId,
        'source': source,
        'operation': operation,
        'phase': 'failed',
        'elapsedMs': stopwatch.elapsedMilliseconds,
        'error': error.toString(),
      });
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
      stopwatch.stop();
      isBusy.value = false;
    }
  }

  Future<String> _resolveInitialDirectory(String? requestedPath) async {
    final requested = requestedPath?.trim();
    if (requested != null &&
        requested.isNotEmpty &&
        !_looksLikeUncPath(requested) &&
        await _directoryExistsQuickly(Directory(requested))) {
      return Directory(requested).absolute.path;
    }

    if (!await _directoryExistsQuickly(_defaultDirectory)) {
      try {
        await _defaultDirectory
            .create(recursive: true)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (await _directoryExistsQuickly(_defaultDirectory)) {
      return _defaultDirectory.absolute.path;
    }

    return Directory.current.absolute.path;
  }

  Future<bool> _directoryExistsQuickly(Directory directory) async {
    try {
      return await directory.exists().timeout(
        const Duration(seconds: 1),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _emit(Map<String, Object?> event) async {
    final enriched = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      ...event,
    };
    try {
      await _eventSink(enriched).timeout(const Duration(milliseconds: 500));
    } catch (error, stackTrace) {
      developer.log(
        '写入文件对话框诊断日志失败',
        name: 'filmstoryboard.file_dialog',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void dispose() => isBusy.dispose();

  static bool _looksLikeUncPath(String path) =>
      path.startsWith(r'\\') || path.startsWith('//');

  static Future<void> _yieldToNextFrame() async {
    await WidgetsBinding.instance.endOfFrame;
  }

  static Future<void> _debugEventSink(Map<String, Object?> event) async {
    developer.log(jsonEncode(event), name: 'filmstoryboard.file_dialog');
  }
}

class _JsonLineFileDialogLogger {
  _JsonLineFileDialogLogger(this.file);

  final File file;
  Future<void> _tail = Future.value();

  Future<void> write(Map<String, Object?> event) {
    _tail = _tail.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(event)}\n',
        mode: FileMode.append,
        flush: true,
      );
      developer.log(jsonEncode(event), name: 'filmstoryboard.file_dialog');
    });
    return _tail;
  }
}
