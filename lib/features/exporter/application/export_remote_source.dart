import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/services/workspace_directories.dart';
import '../../remote_access/domain/remote_export_models.dart';
import '../../settings/application/settings_controller.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/data/shooting_script_repository.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../storyboard/domain/storyboard_canvas_style.dart';
import '../../storyboard/domain/storyboard_models.dart';
import '../../video_analysis/data/analysis_report_export_service.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/data/video_generation_repository.dart';
import '../../video_generation/data/video_timeline_xml_export_service.dart';
import '../../video_generation/domain/video_generation_models.dart';
import '../data/shooting_script_export_service.dart';
import '../data/storyboard_export_service.dart';

class ExportRemoteSource extends ChangeNotifier implements RemoteExportSource {
  ExportRemoteSource({
    required StoryboardController storyboardController,
    required ShootingScriptController shootingScriptController,
    required SettingsController settingsController,
    required AppDatabase database,
    required WorkspaceDirectories directories,
  }) : _storyboardController = storyboardController,
       _shootingScriptController = shootingScriptController,
       _settingsController = settingsController,
       _database = database,
       _directories = directories {
    _storyboardController.addListener(_handleSourceChanged);
    _shootingScriptController.addListener(_handleSourceChanged);
    _settingsController.addListener(_handleSourceChanged);
  }

  final StoryboardController _storyboardController;
  final ShootingScriptController _shootingScriptController;
  final SettingsController _settingsController;
  final AppDatabase _database;
  final WorkspaceDirectories _directories;

  @override
  RemoteExportOptionsRecord get options {
    final videoRepository = VideoAnalysisRepository(_database);
    final generationRepository = VideoGenerationRepository(_database);
    final scriptRepository = ShootingScriptRepository(_database);
    final settings = _settingsController.value;
    return RemoteExportOptionsRecord(
      boards: [
        for (final board in _storyboardController.value.boards)
          RemoteExportBoardRecord(
            id: board.id,
            name: board.name,
            itemCount: board.items.length,
          ),
      ],
      videos: [
        for (final video in videoRepository.listSourceVideos())
          if (videoRepository.getVideoSummary(video.id) != null)
            RemoteExportVideoRecord(
              id: video.id,
              name: p.basename(video.fileName),
            ),
      ],
      scripts: [
        for (final script in scriptRepository.listScripts())
          RemoteExportScriptRecord(
            id: script.id,
            name: script.name,
            timelineAvailable: const VideoTimelineXmlExportService()
                .timelineClips(
                  script: script,
                  shots: scriptRepository.listShots(script.id),
                  tasks: generationRepository.listTasks(scriptId: script.id),
                  fileForTask: _generatedVideoFileForTask,
                )
                .isNotEmpty,
          ),
      ],
      includeSummaryPage: settings.storyboardSummaryPageEnabled,
      includeMultiDimensionAnalysis:
          settings.videoAnalysisMultiDimensionEnabled,
      includeShotDetails: settings.videoAnalysisShotDetailsEnabled,
    );
  }

  @override
  Future<List<RemoteExportProducedFile>> export(
    RemoteExportCommand command, {
    required Directory outputDirectory,
    required RemoteExportProgressCallback onProgress,
    required RemoteExportCancellationCheck isCancelled,
  }) async {
    await outputDirectory.create(recursive: true);
    return switch (command.kind) {
      'storyboardDocument' => _exportStoryboards(
        command,
        outputDirectory,
        onProgress,
        isCancelled,
      ),
      'boardImages' => _exportBoardImages(
        command,
        outputDirectory,
        onProgress,
        isCancelled,
      ),
      'shootingScript' => _exportShootingScript(
        command,
        outputDirectory,
        onProgress,
        isCancelled,
      ),
      'analysisReport' => _exportAnalysisReport(
        command,
        outputDirectory,
        onProgress,
        isCancelled,
      ),
      'timelineXml' => _exportTimeline(
        command,
        outputDirectory,
        onProgress,
        isCancelled,
      ),
      _ => throw const RemoteExportSourceException(
        'export_kind_invalid',
        '不支持的导出类型',
      ),
    };
  }

  Future<List<RemoteExportProducedFile>> _exportStoryboards(
    RemoteExportCommand command,
    Directory outputDirectory,
    RemoteExportProgressCallback onProgress,
    RemoteExportCancellationCheck isCancelled,
  ) async {
    final boards = _requireBoards(command.boardIds);
    final format = _storyboardFormat(command.format);
    final resolution = _storyboardResolution(command.resolution);
    final settings = _settingsController.value;
    final files = <File>[];
    final usedPaths = <String>{};
    for (var index = 0; index < boards.length; index++) {
      _throwIfCancelled(isCancelled);
      final board = boards[index];
      final path = _deduplicatePath(
        p.join(
          outputDirectory.path,
          storyboardExportFileName(boardName: board.name, format: format),
        ),
        usedPaths,
      );
      usedPaths.add(p.normalize(path).toLowerCase());
      files.addAll(
        await const StoryboardExportService().exportBoard(
          board: board,
          format: format,
          resolution: resolution,
          outputPath: path,
          canvasColors: StoryboardCanvasStyle.darkColors,
          includeSummaryPage:
              command.includeSummaryPage ??
              settings.storyboardSummaryPageEnabled,
          numberEnabled: settings.cutImageNumberEnabled,
          numberPosition: settings.cutImageNumberPosition,
          numberBackgroundOpacity: settings.cutImageNumberBackgroundOpacity,
          numberTextScale: settings.cutImageNumberTextScale,
          captionNumberEnabled: settings.storyboardCaptionNumberEnabled,
          isCancelled: isCancelled,
          onProgress: (progress) => onProgress(
            ((index + progress) * 1000).round(),
            boards.length * 1000,
            '正在导出故事板 ${index + 1}/${boards.length}',
          ),
        ),
      );
    }
    _throwIfCancelled(isCancelled);
    return [for (final file in files) RemoteExportProducedFile(file)];
  }

  Future<List<RemoteExportProducedFile>> _exportBoardImages(
    RemoteExportCommand command,
    Directory outputDirectory,
    RemoteExportProgressCallback onProgress,
    RemoteExportCancellationCheck isCancelled,
  ) async {
    final boards = _requireBoards(command.boardIds);
    final files = <File>[];
    for (var index = 0; index < boards.length; index++) {
      _throwIfCancelled(isCancelled);
      onProgress(
        index,
        boards.length,
        '正在复制画板图片 ${index + 1}/${boards.length}',
      );
      final result = await const StoryboardExportService().exportBoardImages(
        board: boards[index],
        outputDirectory: outputDirectory.path,
      );
      files.addAll(result.files);
    }
    _throwIfCancelled(isCancelled);
    onProgress(boards.length, boards.length, '画板图片已导出');
    return [for (final file in files) RemoteExportProducedFile(file)];
  }

  Future<List<RemoteExportProducedFile>> _exportShootingScript(
    RemoteExportCommand command,
    Directory outputDirectory,
    RemoteExportProgressCallback onProgress,
    RemoteExportCancellationCheck isCancelled,
  ) async {
    final boards = _requireBoards(command.boardIds);
    _throwIfCancelled(isCancelled);
    onProgress(0, 1, '正在生成拍摄脚本');
    final file = await const ShootingScriptExportService().export(
      boards: boards,
      analysisBatches: {
        for (final board in boards)
          board.id: _database.getLatestVisionAnalysisBatchForBoard(board.id),
      },
      outputPath: p.join(
        outputDirectory.path,
        shootingScriptExportFileName(boardName: boards.first.name),
      ),
    );
    _throwIfCancelled(isCancelled);
    onProgress(1, 1, '拍摄脚本已导出');
    return [RemoteExportProducedFile(file)];
  }

  Future<List<RemoteExportProducedFile>> _exportAnalysisReport(
    RemoteExportCommand command,
    Directory outputDirectory,
    RemoteExportProgressCallback onProgress,
    RemoteExportCancellationCheck isCancelled,
  ) async {
    final repository = VideoAnalysisRepository(_database);
    final video = repository
        .listSourceVideos()
        .where((item) => item.id == command.videoId)
        .firstOrNull;
    final summary = video == null ? null : repository.getVideoSummary(video.id);
    if (video == null || summary == null) {
      throw const RemoteExportSourceException(
        'export_video_not_found',
        '视频不存在或尚无可导出的解析报告',
      );
    }
    _throwIfCancelled(isCancelled);
    onProgress(0, 1, '正在生成视频解析报告');
    final settings = _settingsController.value;
    final result = await const AnalysisReportExportService().export(
      format: _analysisFormat(command.format),
      outputDirectory: outputDirectory,
      video: video,
      frames: repository.listVideoFrames(video.id),
      frameAnalyses: repository.listVideoFrameAnalyses(video.id),
      summary: summary,
      marketingAnalyses: repository.listMarketingAnalyses(video.id),
      includeMultiDimensionAnalysis:
          command.includeMultiDimensionAnalysis ??
          settings.videoAnalysisMultiDimensionEnabled,
      includeShotDetails:
          command.includeShotDetails ??
          settings.videoAnalysisShotDetailsEnabled,
      resolveFrame: _resolveReportFrame,
    );
    _throwIfCancelled(isCancelled);
    onProgress(1, 1, '视频解析报告已导出');
    return [for (final file in result.files) RemoteExportProducedFile(file)];
  }

  Future<List<RemoteExportProducedFile>> _exportTimeline(
    RemoteExportCommand command,
    Directory outputDirectory,
    RemoteExportProgressCallback onProgress,
    RemoteExportCancellationCheck isCancelled,
  ) async {
    final scriptRepository = ShootingScriptRepository(_database);
    final script = scriptRepository.getScript(command.scriptId);
    if (script == null) {
      throw const RemoteExportSourceException(
        'export_script_not_found',
        '拍摄脚本不存在',
      );
    }
    _throwIfCancelled(isCancelled);
    onProgress(0, 1, '正在生成剪辑时间线');
    final file = await const VideoTimelineXmlExportService().export(
      script: script,
      shots: scriptRepository.listShots(script.id),
      tasks: VideoGenerationRepository(
        _database,
      ).listTasks(scriptId: script.id),
      fileForTask: _generatedVideoFileForTask,
      outputDirectory: outputDirectory,
    );
    _throwIfCancelled(isCancelled);
    onProgress(1, 1, '剪辑时间线已导出');
    return [RemoteExportProducedFile(file)];
  }

  List<StoryboardBoard> _requireBoards(List<String> boardIds) {
    if (boardIds.isEmpty) {
      throw const RemoteExportSourceException(
        'export_boards_required',
        '请至少选择一个故事板',
      );
    }
    final byId = {
      for (final board in _storyboardController.value.boards) board.id: board,
    };
    final boards = <StoryboardBoard>[];
    for (final id in boardIds) {
      final board = byId[id];
      if (board == null) {
        throw const RemoteExportSourceException(
          'export_board_not_found',
          '选择的故事板不存在',
        );
      }
      boards.add(board);
    }
    return boards;
  }

  StoryboardExportFormat _storyboardFormat(String value) => switch (value) {
    'png' => StoryboardExportFormat.png,
    'jpg' => StoryboardExportFormat.jpg,
    'pdf' => StoryboardExportFormat.pdf,
    _ => throw const RemoteExportSourceException(
      'export_format_invalid',
      '故事板格式必须是 png、jpg 或 pdf',
    ),
  };

  StoryboardExportResolution _storyboardResolution(String value) =>
      switch (value) {
        'standard' => StoryboardExportResolution.standard,
        'sourceDetail' => StoryboardExportResolution.sourceDetail,
        _ => throw const RemoteExportSourceException(
          'export_resolution_invalid',
          '故事板分辨率必须是 standard 或 sourceDetail',
        ),
      };

  AnalysisReportFormat _analysisFormat(String value) => switch (value) {
    'xlsx' => AnalysisReportFormat.xlsx,
    'pdf' => AnalysisReportFormat.pdf,
    'png' => AnalysisReportFormat.png,
    'jpg' => AnalysisReportFormat.jpg,
    _ => throw const RemoteExportSourceException(
      'export_format_invalid',
      '解析报告格式必须是 xlsx、pdf、png 或 jpg',
    ),
  };

  File _resolveReportFrame(VideoFrame frame) {
    final normalized = frame.path.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(_directories.workspaceRoot.path, normalized),
    );
  }

  File _generatedVideoFileForTask(VideoGenerationTask task) {
    final normalized = task.localPath.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(_directories.workspaceRoot.path, normalized),
    );
  }

  String _deduplicatePath(String path, Set<String> usedPaths) {
    if (!usedPaths.contains(p.normalize(path).toLowerCase())) return path;
    final extension = p.extension(path);
    final base = path.substring(0, path.length - extension.length);
    var index = 2;
    while (true) {
      final candidate = '$base-$index$extension';
      if (!usedPaths.contains(p.normalize(candidate).toLowerCase())) {
        return candidate;
      }
      index++;
    }
  }

  void _throwIfCancelled(RemoteExportCancellationCheck isCancelled) {
    if (isCancelled()) {
      throw const RemoteExportSourceException('export_cancelled', '导出已取消');
    }
  }

  void _handleSourceChanged() => notifyListeners();

  @override
  void dispose() {
    _storyboardController.removeListener(_handleSourceChanged);
    _shootingScriptController.removeListener(_handleSourceChanged);
    _settingsController.removeListener(_handleSourceChanged);
    super.dispose();
  }
}
