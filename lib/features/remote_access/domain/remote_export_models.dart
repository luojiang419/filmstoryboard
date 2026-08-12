import 'dart:io';

import 'package:flutter/foundation.dart';

class RemoteExportBoardRecord {
  const RemoteExportBoardRecord({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final String id;
  final String name;
  final int itemCount;
}

class RemoteExportVideoRecord {
  const RemoteExportVideoRecord({required this.id, required this.name});

  final String id;
  final String name;
}

class RemoteExportScriptRecord {
  const RemoteExportScriptRecord({
    required this.id,
    required this.name,
    required this.timelineAvailable,
  });

  final String id;
  final String name;
  final bool timelineAvailable;
}

class RemoteExportOptionsRecord {
  const RemoteExportOptionsRecord({
    required this.boards,
    required this.videos,
    required this.scripts,
    required this.includeSummaryPage,
    required this.includeMultiDimensionAnalysis,
    required this.includeShotDetails,
  });

  final List<RemoteExportBoardRecord> boards;
  final List<RemoteExportVideoRecord> videos;
  final List<RemoteExportScriptRecord> scripts;
  final bool includeSummaryPage;
  final bool includeMultiDimensionAnalysis;
  final bool includeShotDetails;
}

class RemoteExportCommand {
  const RemoteExportCommand({
    required this.kind,
    this.boardIds = const [],
    this.videoId = '',
    this.scriptId = '',
    this.format = '',
    this.resolution = '',
    this.includeSummaryPage,
    this.includeMultiDimensionAnalysis,
    this.includeShotDetails,
  });

  final String kind;
  final List<String> boardIds;
  final String videoId;
  final String scriptId;
  final String format;
  final String resolution;
  final bool? includeSummaryPage;
  final bool? includeMultiDimensionAnalysis;
  final bool? includeShotDetails;
}

class RemoteExportProducedFile {
  const RemoteExportProducedFile(this.file);

  final File file;
}

typedef RemoteExportProgressCallback =
    void Function(int current, int total, String message);
typedef RemoteExportCancellationCheck = bool Function();

abstract interface class RemoteExportSource implements Listenable {
  RemoteExportOptionsRecord get options;

  Future<List<RemoteExportProducedFile>> export(
    RemoteExportCommand command, {
    required Directory outputDirectory,
    required RemoteExportProgressCallback onProgress,
    required RemoteExportCancellationCheck isCancelled,
  });
}

class RemoteExportSourceException implements Exception {
  const RemoteExportSourceException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
