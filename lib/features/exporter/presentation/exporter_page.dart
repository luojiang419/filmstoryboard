import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/file_availability_cache.dart';
import '../../../core/services/workspace_directories.dart';
import '../../../core/widgets/preview_file_image.dart';
import '../../settings/domain/app_settings.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../storyboard/application/storyboard_controller.dart';
import '../../storyboard/domain/storyboard_canvas_style.dart';
import '../../storyboard/domain/storyboard_models.dart';
import '../../video_analysis/data/analysis_report_export_service.dart';
import '../../video_analysis/data/ffmpeg_frame_extractor.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../../video_generation/data/video_generation_repository.dart';
import '../../video_generation/data/video_timeline_xml_export_service.dart';
import '../../video_generation/domain/video_generation_models.dart';
import '../data/default_export_directories.dart';
import '../data/shooting_script_export_service.dart';
import '../data/storyboard_export_service.dart';

class ExporterPage extends ConsumerStatefulWidget {
  const ExporterPage({super.key});

  @override
  ConsumerState<ExporterPage> createState() => _ExporterPageState();
}

class _ExporterPageState extends ConsumerState<ExporterPage> {
  static const _uiStateKey = 'exporterPageUiState';

  final _selectedBoardIds = <String>{};
  StoryboardExportFormat _format = StoryboardExportFormat.png;
  StoryboardExportResolution _resolution =
      StoryboardExportResolution.sourceDetail;
  String _message = '选择需要导出的故事板';
  bool _isExporting = false;
  bool _exportCanCancel = false;
  bool _exportCancelRequested = false;
  double? _exportProgress;
  int? _anchorIndex;
  String? _previewBoardId;
  final _fileAvailabilityCache = FileAvailabilityCache();

  @override
  void initState() {
    super.initState();
    _restoreUiState();
  }

  @override
  void dispose() {
    _fileAvailabilityCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('exporter.page');
    final storyboardController = ref.watch(storyboardControllerProvider);
    final shootingScriptController = ref.watch(
      shootingScriptControllerProvider,
    );
    final settingsController = ref.watch(settingsControllerProvider);
    final database = ref.watch(appDatabaseProvider);
    final projectDirectories = ref.watch(projectDirectoriesProvider);
    final videoRepository = VideoAnalysisRepository(database);
    final reportVideo = _latestReportVideo(videoRepository);

    return FileAvailabilityScope(
      cache: _fileAvailabilityCache,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          storyboardController,
          shootingScriptController,
        ]),
        builder: (context, _) {
          final boards = storyboardController.value.boards;
          final shooting = shootingScriptController.value;
          _syncSelectionWithBoards(boards);
          final selectedBoards = _selectedBoards(boards);
          final previewBoard = _previewBoardId == null
              ? null
              : boards.cast<StoryboardBoard?>().firstWhere(
                  (board) => board?.id == _previewBoardId,
                  orElse: () => null,
                );
          final canExport = boards.isNotEmpty && selectedBoards.isNotEmpty;
          final canExportTimeline = _canExportTimelineXml(
            shooting: shooting,
            database: database,
            projectDirectories: projectDirectories,
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final sidebarWidth = constraints.maxWidth < 1000 ? 300.0 : 340.0;
              return Row(
                children: [
                  SizedBox(
                    width: sidebarWidth,
                    child: _ExportSidebar(
                      format: _format,
                      resolution: _resolution,
                      message: _message,
                      boardCount: boards.length,
                      selectedBoards: selectedBoards,
                      isExporting: _isExporting,
                      progress: _exportProgress,
                      onCancelExport: _exportCanCancel ? _cancelExport : null,
                      onFormatChanged: _setFormat,
                      onResolutionChanged: _setResolution,
                      onExportSelected: canExport
                          ? () => _exportSelected(
                              boards,
                              settingsController.value,
                            )
                          : null,
                      onExportDefault: canExport
                          ? () => _exportToDefault(
                              boards,
                              settingsController.value,
                            )
                          : null,
                      onExportBoardImages: canExport
                          ? () => _exportBoardImagesSelected(
                              boards,
                              settingsController.value,
                            )
                          : null,
                      onExportShootingScript: canExport
                          ? () => _exportShootingScript(
                              boards,
                              settingsController.value,
                            )
                          : null,
                      onExportTimeline: canExportTimeline
                          ? () => _exportTimelineXml(
                              shooting: shooting,
                              database: database,
                              projectDirectories: projectDirectories,
                              settings: settingsController.value,
                            )
                          : null,
                      onExportVideoAnalysisReport: reportVideo == null
                          ? null
                          : () => _exportVideoAnalysisReport(
                              repository: videoRepository,
                              video: reportVideo,
                              settings: settingsController.value,
                            ),
                      onOpenDefaultExportDirectory: () =>
                          _openDefaultExportDirectory(
                            settingsController.value.exportDirectory,
                          ),
                    ),
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: previewBoard == null
                          ? _BoardSelectionPane(
                              key: const ValueKey('exporter-board-browser'),
                              boards: boards,
                              selectedIds: _selectedBoardIds,
                              onSelect: _selectBoard,
                              onPreview: _enterBoardPreview,
                            )
                          : _BoardExportPreviewPane(
                              key: ValueKey(
                                'exporter-board-preview-${previewBoard.id}',
                              ),
                              board: previewBoard,
                              captionNumberEnabled: settingsController
                                  .value
                                  .storyboardCaptionNumberEnabled,
                              onBack: _closeBoardPreview,
                            ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _selectBoard(int index, StoryboardBoard board, bool selected) {
    final shift = HardwareKeyboard.instance.logicalKeysPressed.any(
      (key) =>
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight,
    );
    setState(() {
      if (shift && _anchorIndex != null) {
        final boards = ref.read(storyboardControllerProvider).value.boards;
        final start = _anchorIndex! < index ? _anchorIndex! : index;
        final end = _anchorIndex! > index ? _anchorIndex! : index;
        for (var i = start; i <= end; i++) {
          if (selected) {
            _selectedBoardIds.add(boards[i].id);
          } else {
            _selectedBoardIds.remove(boards[i].id);
          }
        }
      } else if (selected) {
        _selectedBoardIds.add(board.id);
      } else {
        _selectedBoardIds.remove(board.id);
      }
      _anchorIndex = index;
      _message = '已选择 ${_selectedBoardIds.length} 个故事板';
    });
    _saveUiState();
  }

  void _setFormat(StoryboardExportFormat format) {
    if (_format == format) {
      return;
    }
    setState(() => _format = format);
    _saveUiState();
  }

  void _setResolution(StoryboardExportResolution resolution) {
    if (_resolution == resolution) {
      return;
    }
    setState(() => _resolution = resolution);
    _saveUiState();
  }

  void _syncSelectionWithBoards(List<StoryboardBoard> boards) {
    final validIds = boards.map((board) => board.id).toSet();
    final beforeCount = _selectedBoardIds.length;
    _selectedBoardIds.removeWhere((id) => !validIds.contains(id));
    final anchorIndex = _anchorIndex;
    if (anchorIndex != null &&
        (anchorIndex < 0 || anchorIndex >= boards.length)) {
      _anchorIndex = null;
    }
    if (_previewBoardId != null && !validIds.contains(_previewBoardId)) {
      _previewBoardId = null;
    }
    if (beforeCount != _selectedBoardIds.length) {
      _message = _selectedBoardIds.isEmpty
          ? '选择需要导出的故事板'
          : '已选择 ${_selectedBoardIds.length} 个故事板';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _saveUiState();
        }
      });
    }
  }

  void _restoreUiState() {
    try {
      final raw = ref.read(appDatabaseProvider).getSetting(_uiStateKey);
      if (raw == null || raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      _format = _formatFromJson(decoded['format']);
      _resolution = _resolutionFromJson(decoded['resolution']);
      _selectedBoardIds
        ..clear()
        ..addAll(_jsonStringSet(decoded['selectedBoardIds']));
      _anchorIndex = _jsonNullableInt(decoded['anchorIndex']);
      if (_selectedBoardIds.isNotEmpty) {
        _message = '已选择 ${_selectedBoardIds.length} 个故事板';
      }
    } catch (_) {
      return;
    }
  }

  void _saveUiState() {
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(
            _uiStateKey,
            jsonEncode({
              'format': _format.name,
              'resolution': _resolution.name,
              'selectedBoardIds': _selectedBoardIds.toList()..sort(),
              'anchorIndex': _anchorIndex,
            }),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  StoryboardExportFormat _formatFromJson(Object? value) {
    final name = value?.toString();
    for (final format in StoryboardExportFormat.values) {
      if (format.name == name) {
        return format;
      }
    }
    return StoryboardExportFormat.png;
  }

  StoryboardExportResolution _resolutionFromJson(Object? value) {
    final name = value?.toString();
    for (final resolution in StoryboardExportResolution.values) {
      if (resolution.name == name) {
        return resolution;
      }
    }
    return StoryboardExportResolution.sourceDetail;
  }

  Set<String> _jsonStringSet(Object? value) {
    if (value is! List) {
      return const <String>{};
    }
    return {for (final item in value) item?.toString() ?? ''}..remove('');
  }

  int? _jsonNullableInt(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value.toString());
  }

  Future<void> _exportSelected(
    List<StoryboardBoard> boards,
    AppSettings settings,
  ) async {
    final selectedBoards = _selectedBoards(boards);
    final first = selectedBoards.first;
    final location = await ref
        .read(desktopFileDialogServiceProvider)
        .getSaveLocation(
          source: 'exporter.export_selected',
          initialDirectory: settings.exportDirectory,
          suggestedName: _defaultFileName(first, _format),
          acceptedTypeGroups: [
            XTypeGroup(label: _format.label, extensions: [_format.extension]),
          ],
          confirmButtonText: '导出',
        );
    if (location == null) {
      return;
    }
    late final List<File> exportedFiles;
    try {
      exportedFiles = await _exportBoards(
        selectedBoards,
        location.path,
        settings,
      );
    } on StoryboardExportCancelled {
      return;
    }
    if (_selectedBoardIds.length > 1) {
      final firstFileName = exportedFiles.isEmpty
          ? p.basename(location.path)
          : p.basename(exportedFiles.first.path);
      setState(
        () => _message =
            '已导出 ${_selectedBoardIds.length} 个故事板，首个文件：$firstFileName',
      );
    } else {
      setState(() => _message = '已导出 ${first.name}');
    }
  }

  Future<void> _exportToDefault(
    List<StoryboardBoard> boards,
    AppSettings settings,
  ) async {
    final selectedBoards = _selectedBoards(boards);
    final directory = DefaultExportDirectories(
      settings.exportDirectory,
    ).storyboards;
    final path = p.join(
      directory.path,
      _defaultFileName(selectedBoards.first, _format),
    );
    try {
      await _exportBoards(selectedBoards, path, settings);
    } on StoryboardExportCancelled {
      return;
    }
    setState(() => _message = '故事板已导出：${directory.path}');
  }

  Future<void> _exportBoardImagesSelected(
    List<StoryboardBoard> boards,
    AppSettings settings,
  ) async {
    final directory = DefaultExportDirectories(
      settings.exportDirectory,
    ).boardImages;
    await _exportBoardImages(_selectedBoards(boards), directory.path);
  }

  Future<void> _exportShootingScript(
    List<StoryboardBoard> boards,
    AppSettings settings,
  ) async {
    final selectedBoards = _selectedBoards(boards);
    final directory = DefaultExportDirectories(
      settings.exportDirectory,
    ).shootingScripts;
    final outputPath = p.join(
      directory.path,
      shootingScriptExportFileName(boardName: selectedBoards.first.name),
    );

    setState(() => _isExporting = true);
    try {
      final database = ref.read(appDatabaseProvider);
      final result = await const ShootingScriptExportService().export(
        boards: selectedBoards,
        analysisBatches: {
          for (final board in selectedBoards)
            board.id: database.getLatestVisionAnalysisBatchForBoard(board.id),
        },
        outputPath: outputPath,
      );
      if (mounted) {
        setState(() => _message = '拍摄脚本已导出：${p.basename(result.path)}');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '导出拍摄脚本失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  SourceVideo? _latestReportVideo(VideoAnalysisRepository repository) {
    for (final video in repository.listSourceVideos()) {
      if (repository.getVideoSummary(video.id) != null) {
        return video;
      }
    }
    return null;
  }

  File _resolveReportFrame(VideoFrame frame) {
    final directories = ref.read(projectDirectoriesProvider);
    final normalized = frame.path.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(directories.workspaceRoot.path, normalized),
    );
  }

  Future<void> _exportVideoAnalysisReport({
    required VideoAnalysisRepository repository,
    required SourceVideo video,
    required AppSettings settings,
  }) async {
    final format = await _chooseAnalysisReportFormat();
    if (format == null) {
      return;
    }
    final summary = repository.getVideoSummary(video.id);
    if (summary == null) {
      setState(() => _message = '该视频还没有可导出的多维度解析报告');
      return;
    }
    setState(() {
      _isExporting = true;
      _message = '正在导出 ${_shortVideoName(video.fileName)} 多维度解析报告...';
    });
    try {
      final result = await const AnalysisReportExportService().export(
        format: format,
        outputDirectory: DefaultExportDirectories(
          settings.exportDirectory,
        ).analysisReports,
        video: video,
        frames: repository.listVideoFrames(video.id),
        frameAnalyses: repository.listVideoFrameAnalyses(video.id),
        summary: summary,
        marketingAnalyses: repository.listMarketingAnalyses(video.id),
        includeMultiDimensionAnalysis:
            settings.videoAnalysisMultiDimensionEnabled,
        includeShotDetails: settings.videoAnalysisShotDetailsEnabled,
        resolveFrame: _resolveReportFrame,
      );
      if (mounted) {
        setState(
          () => _message =
              '多维度解析报告已导出：${result.files.map((file) => p.basename(file.path)).join('、')}',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '导出多维度解析报告失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  bool _canExportTimelineXml({
    required ShootingScriptState shooting,
    required AppDatabase database,
    required WorkspaceDirectories projectDirectories,
  }) {
    final script = shooting.selectedScript;
    if (script == null) {
      return false;
    }
    final repository = VideoGenerationRepository(database);
    return const VideoTimelineXmlExportService()
        .timelineClips(
          script: script,
          shots: shooting.shots,
          tasks: repository.listTasks(scriptId: script.id),
          fileForTask: (task) =>
              _generatedVideoFileForTask(task, projectDirectories),
        )
        .isNotEmpty;
  }

  Future<void> _exportTimelineXml({
    required ShootingScriptState shooting,
    required AppDatabase database,
    required WorkspaceDirectories projectDirectories,
    required AppSettings settings,
  }) async {
    final script = shooting.selectedScript;
    if (script == null) {
      setState(() => _message = '尚未选择拍摄脚本');
      return;
    }
    setState(() {
      _isExporting = true;
      _message = '正在导出剪辑时间线...';
    });
    try {
      final repository = VideoGenerationRepository(database);
      final file = await const VideoTimelineXmlExportService().export(
        script: script,
        shots: shooting.shots,
        tasks: repository.listTasks(scriptId: script.id),
        fileForTask: (task) =>
            _generatedVideoFileForTask(task, projectDirectories),
        outputDirectory: DefaultExportDirectories(
          settings.exportDirectory,
        ).timelines,
        metadataProbe: FfmpegFrameExtractor(
          ffprobeExecutable: settings.ffprobeExecutable,
        ).probe,
      );
      if (mounted) {
        setState(() => _message = '时间线 XML 已导出：${file.path}');
      }
    } on VideoTimelineXmlExportException catch (error) {
      if (mounted) {
        setState(() => _message = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '导出时间线失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  File _generatedVideoFileForTask(
    VideoGenerationTask task,
    WorkspaceDirectories projectDirectories,
  ) {
    final path = task.localPath.trim();
    if (path.isEmpty) {
      return File('');
    }
    final normalized = path.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(projectDirectories.workspaceRoot.path, normalized),
    );
  }

  Future<AnalysisReportFormat?> _chooseAnalysisReportFormat() {
    return showDialog<AnalysisReportFormat>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择多维度解析报告格式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in AnalysisReportFormat.values)
              ListTile(
                leading: Icon(switch (item) {
                  AnalysisReportFormat.xlsx => Icons.table_view_rounded,
                  AnalysisReportFormat.pdf => Icons.picture_as_pdf_rounded,
                  AnalysisReportFormat.png => Icons.image_rounded,
                  AnalysisReportFormat.jpg => Icons.photo_rounded,
                }),
                title: Text(item.label),
                subtitle: Text(switch (item) {
                  AnalysisReportFormat.xlsx => '四个工作表，可继续编辑',
                  AnalysisReportFormat.pdf => '多页视觉报告',
                  AnalysisReportFormat.png => '按报告页输出无损图片',
                  AnalysisReportFormat.jpg => '按报告页输出高质量图片',
                }),
                onTap: () => Navigator.of(context).pop(item),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBoardImages(
    List<StoryboardBoard> boards,
    String outputDirectory,
  ) async {
    setState(() => _isExporting = true);
    try {
      final service = const StoryboardExportService();
      final rootDirectory = boards.length > 1
          ? await _createAvailableDirectory(
              p.join(outputDirectory, _defaultBoardImagesFolderName()),
            )
          : Directory(outputDirectory);
      if (!await rootDirectory.exists()) {
        await rootDirectory.create(recursive: true);
      }

      var exportedCount = 0;
      StoryboardBoardImageExportResult? lastResult;
      for (final board in boards) {
        lastResult = await service.exportBoardImages(
          board: board,
          outputDirectory: rootDirectory.path,
        );
        exportedCount += lastResult.files.length;
      }

      if (!mounted) {
        return;
      }
      if (boards.length > 1) {
        setState(
          () => _message =
              '已导出 ${boards.length} 个画板的 $exportedCount 张图片：${rootDirectory.path}',
        );
      } else {
        final directoryPath = lastResult?.directory.path ?? rootDirectory.path;
        setState(() => _message = '已导出 $exportedCount 张画板图片：$directoryPath');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '导出画板图片失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<List<File>> _exportBoards(
    List<StoryboardBoard> boards,
    String firstPath,
    AppSettings settings,
  ) async {
    final canvasColors = StoryboardCanvasStyle.of(context);
    setState(() {
      _isExporting = true;
      _exportCanCancel = true;
      _exportCancelRequested = false;
      _exportProgress = 0;
      _message = '正在准备导出...';
    });
    final exportedFiles = <File>[];
    try {
      final service = const StoryboardExportService();
      final outputDirectory = p.dirname(firstPath);
      final usedOutputPaths = <String>{};
      for (var i = 0; i < boards.length; i++) {
        if (_exportCancelRequested) {
          throw const StoryboardExportCancelled();
        }
        final outputPath = boards.length == 1
            ? firstPath
            : _deduplicatePath(
                p.join(outputDirectory, _defaultFileName(boards[i], _format)),
                usedOutputPaths,
              );
        usedOutputPaths.add(p.normalize(outputPath).toLowerCase());
        exportedFiles.addAll(
          await service.exportBoard(
            board: boards[i],
            format: _format,
            resolution: _resolution,
            outputPath: outputPath,
            canvasColors: canvasColors,
            includeSummaryPage: settings.storyboardSummaryPageEnabled,
            numberEnabled: settings.cutImageNumberEnabled,
            numberPosition: settings.cutImageNumberPosition,
            numberBackgroundOpacity: settings.cutImageNumberBackgroundOpacity,
            numberTextScale: settings.cutImageNumberTextScale,
            captionNumberEnabled: settings.storyboardCaptionNumberEnabled,
            isCancelled: () => _exportCancelRequested,
            onProgress: (boardProgress) {
              if (!mounted) {
                return;
              }
              final progress = (i + boardProgress) / boards.length;
              setState(() {
                _exportProgress = progress;
                _message =
                    '正在导出 ${i + 1}/${boards.length} · ${(progress * 100).round()}%';
              });
            },
          ),
        );
      }
    } on StoryboardExportCancelled {
      for (final file in exportedFiles) {
        try {
          await file.delete();
        } on FileSystemException {
          // 尽力清理已完成画板，保留取消状态。
        }
      }
      if (mounted) {
        setState(() => _message = '导出已取消，已清理本次生成文件');
      }
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _exportCanCancel = false;
          _exportProgress = null;
        });
      }
    }
    return exportedFiles;
  }

  void _cancelExport() {
    if (!_isExporting || !_exportCanCancel || _exportCancelRequested) {
      return;
    }
    setState(() {
      _exportCancelRequested = true;
      _message = '正在取消导出...';
    });
  }

  List<StoryboardBoard> _selectedBoards(List<StoryboardBoard> boards) {
    return boards
        .where((board) => _selectedBoardIds.contains(board.id))
        .toList();
  }

  String _defaultFileName(
    StoryboardBoard board,
    StoryboardExportFormat format,
  ) {
    return storyboardExportFileName(boardName: board.name, format: format);
  }

  String _defaultBoardImagesFolderName() {
    final date = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    return '导出画板图片-$date';
  }

  String _deduplicatePath(String path, Set<String> usedPaths) {
    final normalizedPath = p.normalize(path).toLowerCase();
    if (!usedPaths.contains(normalizedPath)) {
      return path;
    }

    final extension = p.extension(path);
    final base = extension.isEmpty
        ? path
        : path.substring(0, path.length - extension.length);
    var index = 2;
    while (true) {
      final candidate = '$base-$index$extension';
      final normalizedCandidate = p.normalize(candidate).toLowerCase();
      if (!usedPaths.contains(normalizedCandidate)) {
        return candidate;
      }
      index++;
    }
  }

  Future<Directory> _createAvailableDirectory(String path) async {
    var directory = Directory(path);
    if (!await directory.exists()) {
      return directory.create(recursive: true);
    }
    if (await _directoryIsEmpty(directory)) {
      return directory;
    }

    var index = 2;
    while (true) {
      directory = Directory('$path-$index');
      if (!await directory.exists()) {
        return directory.create(recursive: true);
      }
      if (await _directoryIsEmpty(directory)) {
        return directory;
      }
      index++;
    }
  }

  Future<bool> _directoryIsEmpty(Directory directory) async {
    try {
      return directory.list().isEmpty;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _openDefaultExportDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await Process.start('explorer.exe', [directory.path]);
  }

  void _enterBoardPreview(int index, StoryboardBoard board) {
    setState(() {
      _selectedBoardIds.add(board.id);
      _anchorIndex = index;
      _previewBoardId = board.id;
      _message = '已选择 ${_selectedBoardIds.length} 个故事板';
    });
    _saveUiState();
  }

  void _closeBoardPreview() {
    if (_previewBoardId == null) {
      return;
    }
    setState(() => _previewBoardId = null);
  }
}

class _ExportSidebar extends StatelessWidget {
  const _ExportSidebar({
    required this.format,
    required this.resolution,
    required this.message,
    required this.boardCount,
    required this.selectedBoards,
    required this.isExporting,
    required this.progress,
    required this.onCancelExport,
    required this.onFormatChanged,
    required this.onResolutionChanged,
    required this.onExportSelected,
    required this.onExportDefault,
    required this.onExportBoardImages,
    required this.onExportShootingScript,
    required this.onExportTimeline,
    required this.onExportVideoAnalysisReport,
    required this.onOpenDefaultExportDirectory,
  });

  final StoryboardExportFormat format;
  final StoryboardExportResolution resolution;
  final String message;
  final int boardCount;
  final List<StoryboardBoard> selectedBoards;
  final bool isExporting;
  final double? progress;
  final VoidCallback? onCancelExport;
  final ValueChanged<StoryboardExportFormat> onFormatChanged;
  final ValueChanged<StoryboardExportResolution> onResolutionChanged;
  final VoidCallback? onExportSelected;
  final VoidCallback? onExportDefault;
  final VoidCallback? onExportBoardImages;
  final VoidCallback? onExportShootingScript;
  final VoidCallback? onExportTimeline;
  final VoidCallback? onExportVideoAnalysisReport;
  final VoidCallback onOpenDefaultExportDirectory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedShotCount = selectedBoards.fold<int>(
      0,
      (sum, board) => sum + board.visibleItemCount,
    );
    final outputName = switch (selectedBoards.length) {
      0 => '选择画板后自动命名',
      1 => storyboardExportFileName(
        boardName: selectedBoards.single.name,
        format: format,
      ),
      _ => '批量导出 ${selectedBoards.length} 个画板',
    };

    return ColoredBox(
      key: const ValueKey('exporter-sidebar'),
      color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.ios_share_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  '导出故事板',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '先在右侧选择画板；双击卡片可进入导出预览。文件仅在本机生成。',
              style: TextStyle(height: 1.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            const _ExportSectionLabel('文件名称'),
            const SizedBox(height: 8),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                outputName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 18),
            const _ExportSectionLabel('导出格式'),
            const SizedBox(height: 8),
            SegmentedButton<StoryboardExportFormat>(
              showSelectedIcon: false,
              segments: [
                for (final item in StoryboardExportFormat.values)
                  ButtonSegment(value: item, label: Text(item.label)),
              ],
              selected: {format},
              onSelectionChanged: (selection) =>
                  onFormatChanged(selection.first),
            ),
            const SizedBox(height: 18),
            const _ExportSectionLabel('导出清晰度'),
            const SizedBox(height: 8),
            SegmentedButton<StoryboardExportResolution>(
              showSelectedIcon: false,
              segments: [
                for (final item in StoryboardExportResolution.values)
                  ButtonSegment(value: item, label: Text(item.label)),
              ],
              selected: {resolution},
              onSelectionChanged: (selection) =>
                  onResolutionChanged(selection.first),
            ),
            const SizedBox(height: 6),
            Text(
              resolution.description,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _ExportSummaryRow(label: '全部画板', value: '$boardCount 个'),
                  _ExportSummaryRow(
                    label: '已选择',
                    value: '${selectedBoards.length} 个',
                  ),
                  _ExportSummaryRow(
                    label: '镜头数量',
                    value: '$selectedShotCount 个',
                  ),
                  _ExportSummaryRow(
                    label: '布局',
                    value: selectedBoards.length == 1
                        ? '${selectedBoards.single.columns} 列'
                        : '多画板',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: isExporting ? null : onExportSelected,
              icon: const Icon(Icons.save_as_rounded),
              label: const Text('导出到...'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onExportDefault,
              icon: const Icon(Icons.folder_special_rounded),
              label: const Text('导出到默认位置'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onExportBoardImages,
              icon: const Icon(Icons.drive_folder_upload_rounded),
              label: const Text('导出画板图片'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onExportShootingScript,
              icon: const Icon(Icons.description_outlined),
              label: const Text('导出拍摄脚本'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onExportTimeline,
              icon: const Icon(Icons.account_tree_outlined),
              label: const Text('导出时间线'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onExportVideoAnalysisReport,
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('导出多维度报告'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: isExporting ? null : onOpenDefaultExportDirectory,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('打开默认导出位置'),
            ),
            if (isExporting) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: progress),
            ],
            if (isExporting && onCancelExport != null) ...[
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: onCancelExport,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('取消导出'),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isExporting ? Icons.sync_rounded : Icons.shield_outlined,
                    color: scheme.primary,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: const TextStyle(fontSize: 12, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportSectionLabel extends StatelessWidget {
  const _ExportSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(fontWeight: FontWeight.w700));
  }
}

class _ExportSummaryRow extends StatelessWidget {
  const _ExportSummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _BoardSelectionPane extends StatelessWidget {
  const _BoardSelectionPane({
    super.key,
    required this.boards,
    required this.selectedIds,
    required this.onSelect,
    required this.onPreview,
  });

  final List<StoryboardBoard> boards;
  final Set<String> selectedIds;
  final void Function(int index, StoryboardBoard board, bool selected) onSelect;
  final void Function(int index, StoryboardBoard board) onPreview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface.withValues(alpha: 0.72),
      child: Column(
        children: [
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '故事板',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Icon(Icons.touch_app_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  '${boards.length} 个画板 · 单击选择，双击预览',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: _BoardSelectionGrid(
                boards: boards,
                selectedIds: selectedIds,
                onSelect: onSelect,
                onPreview: onPreview,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardSelectionGrid extends StatelessWidget {
  const _BoardSelectionGrid({
    required this.boards,
    required this.selectedIds,
    required this.onSelect,
    required this.onPreview,
  });

  final List<StoryboardBoard> boards;
  final Set<String> selectedIds;
  final void Function(int index, StoryboardBoard board, bool selected) onSelect;
  final void Function(int index, StoryboardBoard board) onPreview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (boards.isEmpty) {
      return Center(
        child: Text(
          '请先在故事板拼图页创建画板',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisExtent: 230,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: boards.length,
      itemBuilder: (context, index) {
        final board = boards[index];
        final selected = selectedIds.contains(board.id);
        return MouseRegion(
          onEnter: (_) {
            final shift = HardwareKeyboard.instance.logicalKeysPressed.any(
              (key) =>
                  key == LogicalKeyboardKey.shiftLeft ||
                  key == LogicalKeyboardKey.shiftRight,
            );
            if (shift) {
              onSelect(index, board, true);
            }
          },
          child: GestureDetector(
            key: ValueKey('export-board-${board.id}'),
            onTap: () => onSelect(index, board, !selected),
            onDoubleTap: () => onPreview(index, board),
            onSecondaryTap: () => onSelect(index, board, false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primaryContainer.withValues(alpha: 0.8)
                    : scheme.surfaceContainerLow.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.58)
                      : scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.16),
                          blurRadius: 22,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          board.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(child: _MiniBoardPreview(board: board)),
                  const SizedBox(height: 8),
                  Text(
                    '${board.width} x ${board.height} · ${board.rows} x ${board.columns} · ${board.visibleItemCount}/${board.slotCount} 格',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniBoardPreview extends StatelessWidget {
  const _MiniBoardPreview({required this.board});

  final StoryboardBoard board;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final itemsBySlot = buildExporterPreviewSlotItems(board.items);
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: canvasColors.background,
          borderRadius: BorderRadius.circular(6),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 4.0;
            final rows = math.max(1, board.rows);
            final columns = math.max(1, board.columns);
            final slotWidth = math.max(
              1.0,
              (constraints.maxWidth - gap * (columns - 1)) / columns,
            );
            final slotHeight = math.max(
              1.0,
              (constraints.maxHeight - gap * (rows - 1)) / rows,
            );
            return Stack(
              children: [
                for (var index = 0; index < board.slotCount; index++)
                  Positioned(
                    left: (index % columns) * (slotWidth + gap),
                    top: (index ~/ columns) * (slotHeight + gap),
                    width: slotWidth,
                    height: slotHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: canvasColors.slotBackground,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: canvasColors.slotBorder),
                      ),
                      child: _MiniSlotImage(
                        item: itemsBySlot[index],
                        logicalWidth: slotWidth,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MiniSlotImage extends StatelessWidget {
  const _MiniSlotImage({required this.item, required this.logicalWidth});

  final StoryboardItem? item;
  final double logicalWidth;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item == null) {
      return const SizedBox.shrink();
    }
    final imageProvider = previewFileImageProvider(
      path: item.asset.path,
      logicalWidth: logicalWidth,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image(image: imageProvider, fit: BoxFit.contain),
    );
  }
}

@visibleForTesting
Map<int, StoryboardItem> buildExporterPreviewSlotItems(
  Iterable<StoryboardItem> items,
) {
  final itemsBySlot = <int, StoryboardItem>{};
  for (final item in items) {
    itemsBySlot.putIfAbsent(item.slotIndex, () => item);
  }
  return itemsBySlot;
}

class _BoardExportPreviewPane extends StatelessWidget {
  const _BoardExportPreviewPane({
    super.key,
    required this.board,
    required this.captionNumberEnabled,
    required this.onBack,
  });

  final StoryboardBoard board;
  final bool captionNumberEnabled;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stageColor = scheme.brightness == Brightness.dark
        ? const Color(0xFF080C10)
        : scheme.surface;
    return Focus(
      key: const ValueKey('exporter-preview-focus'),
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onBack();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ColoredBox(
        key: const ValueKey('exporter-preview-stage'),
        color: stageColor,
        child: Column(
          children: [
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow.withValues(alpha: 0.96),
                border: Border(
                  bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('exporter-preview-back'),
                    tooltip: '返回故事板',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '导出预览',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      board.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '本地渲染',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                minScale: 0.25,
                maxScale: 8,
                boundaryMargin: const EdgeInsets.all(420),
                child: Center(
                  child: _FullscreenBoardPreview(
                    board: board,
                    captionNumberEnabled: captionNumberEnabled,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenBoardPreview extends StatelessWidget {
  const _FullscreenBoardPreview({
    required this.board,
    required this.captionNumberEnabled,
  });

  final StoryboardBoard board;
  final bool captionNumberEnabled;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : viewport.width;
        final maxHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : viewport.height;
        final boardWidth = math.max(1.0, board.width.toDouble());
        final boardHeight = math.max(1.0, board.height.toDouble());
        final fitScale = math.min(
          math.max(1.0, maxWidth * 0.86) / boardWidth,
          math.max(1.0, maxHeight * 0.78) / boardHeight,
        );
        final scale = fitScale.isFinite && fitScale > 0
            ? math.min(1.0, fitScale)
            : 1.0;
        return SizedBox(
          width: boardWidth * scale,
          height: boardHeight * scale,
          child: FittedBox(
            child: SizedBox(
              width: boardWidth,
              height: boardHeight,
              child: _BoardPreviewCanvas(
                board: board,
                scale: 1,
                captionNumberEnabled: captionNumberEnabled,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BoardPreviewCanvas extends StatelessWidget {
  const _BoardPreviewCanvas({
    required this.board,
    required this.scale,
    required this.captionNumberEnabled,
  });

  final StoryboardBoard board;
  final double scale;
  final bool captionNumberEnabled;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: canvasColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: canvasColors.slotBorder.withValues(alpha: 0.8),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 28,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gap = board.gap * scale;
            final columns = math.max(1, board.columns);
            final rows = math.max(1, board.rows);
            final showItemCaptions =
                board.storyDescriptionEnabled && !board.rowDescriptionEnabled;
            final showRowCaptions =
                board.storyDescriptionEnabled && board.rowDescriptionEnabled;
            final captionFontSize = _scaledPreviewCaptionFontSize(board, scale);
            final slotWidth = math.max(
              1.0,
              (constraints.maxWidth - gap * (columns - 1)) / columns,
            );
            final rowBandHeight = math.max(
              1.0,
              (constraints.maxHeight - gap * (rows - 1)) / rows,
            );
            final rowCaptionHeight = showRowCaptions
                ? _rowCaptionHeight(rowBandHeight, captionFontSize)
                : 0.0;
            final rowCaptionGap = rowCaptionHeight > 0
                ? math.max(4.0, math.min(8.0, gap * 0.45))
                : 0.0;
            final slotHeight = math.max(
              1.0,
              rowBandHeight - rowCaptionHeight - rowCaptionGap,
            );
            final itemCaptionHeight = showItemCaptions
                ? _itemCaptionHeight(rowBandHeight, captionFontSize)
                : 0.0;
            final slotRects = [
              for (var index = 0; index < board.slotCount; index++)
                _slotRect(
                  index,
                  slotWidth,
                  slotHeight,
                  gap,
                  columns,
                  rowBandHeight,
                ),
            ];
            return Stack(
              fit: StackFit.expand,
              children: [
                for (var index = 0; index < board.slotCount; index++)
                  Positioned.fromRect(
                    rect: slotRects[index],
                    child: _BoardPreviewEmptySlot(index: index),
                  ),
                for (final item in board.items)
                  if (item.slotIndex >= 0 && item.slotIndex < board.slotCount)
                    Positioned.fromRect(
                      rect: slotRects[item.slotIndex],
                      child: _BoardPreviewTile(
                        item: item,
                        index: item.slotIndex,
                        showCaption: showItemCaptions,
                        captionHeight: itemCaptionHeight,
                        captionFontFamily: board.captionFontFamily,
                        captionFontSize: captionFontSize,
                        captionNumberEnabled: captionNumberEnabled,
                      ),
                    ),
                if (showRowCaptions)
                  for (var rowIndex = 0; rowIndex < rows; rowIndex++)
                    Positioned.fromRect(
                      rect: Rect.fromLTWH(
                        0,
                        rowIndex * (rowBandHeight + gap) +
                            slotHeight +
                            rowCaptionGap,
                        constraints.maxWidth,
                        rowCaptionHeight,
                      ),
                      child: _BoardPreviewCaptionBox(
                        text: board.rowCaptionAt(rowIndex),
                        fontFamily: board.captionFontFamily,
                        fontSize: captionFontSize,
                        height: rowCaptionHeight,
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }

  Rect _slotRect(
    int index,
    double slotWidth,
    double slotHeight,
    double gap,
    int columns,
    double rowBandHeight,
  ) {
    return Rect.fromLTWH(
      (index % columns) * (slotWidth + gap),
      (index ~/ columns) * (rowBandHeight + gap),
      slotWidth,
      slotHeight,
    );
  }

  double _rowCaptionHeight(double rowBandHeight, double captionFontSize) {
    final preferred =
        StoryboardBoard.maxRowCaptionHeight(
          width: board.width.toDouble(),
          gap: board.gap,
          rows: board.rows,
          rowCaptions: board.rowCaptions,
          fontSize: board.captionFontSize,
        ) *
        scale;
    final minimum = _previewCaptionMinHeight(captionFontSize);
    return math.min(
      math.max(preferred, minimum),
      math.max(0.0, rowBandHeight - 28),
    );
  }

  double _itemCaptionHeight(double rowBandHeight, double captionFontSize) {
    final preferred =
        StoryboardBoard.maxItemCaptionHeight(
          width: board.width.toDouble(),
          gap: board.gap,
          columns: board.columns,
          items: board.items,
          fontSize: board.captionFontSize,
        ) *
        scale;
    final minimum = _previewCaptionMinHeight(captionFontSize);
    return math.min(
      math.max(preferred, minimum),
      math.max(0.0, rowBandHeight - 28),
    );
  }
}

class _BoardPreviewEmptySlot extends StatelessWidget {
  const _BoardPreviewEmptySlot({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: canvasColors.slotBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: canvasColors.slotBorder),
      ),
      child: Center(
        child: Text(
          '${index + 1}',
          style: TextStyle(
            color: canvasColors.mutedText.withValues(alpha: 0.42),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _BoardPreviewTile extends StatelessWidget {
  const _BoardPreviewTile({
    required this.item,
    required this.index,
    required this.showCaption,
    required this.captionHeight,
    required this.captionFontFamily,
    required this.captionFontSize,
    required this.captionNumberEnabled,
  });

  final StoryboardItem item;
  final int index;
  final bool showCaption;
  final double captionHeight;
  final String captionFontFamily;
  final double captionFontSize;
  final bool captionNumberEnabled;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: canvasColors.tileBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: canvasColors.slotBorder),
      ),
      child: Column(
        children: [
          Expanded(child: _BoardPreviewImage(item: item)),
          if (showCaption && captionHeight > 0) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: captionHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (captionNumberEnabled) ...[
                    _BoardPreviewSequenceBadge(
                      number: index + 1,
                      fontSize: captionFontSize,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: _BoardPreviewCaptionBox(
                      text: item.caption,
                      fontFamily: captionFontFamily,
                      fontSize: captionFontSize,
                      height: captionHeight,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BoardPreviewImage extends StatelessWidget {
  const _BoardPreviewImage({required this.item});

  final StoryboardItem item;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final file = File(item.asset.path);
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageProvider = previewFileImageProvider(
          path: item.asset.path,
          logicalWidth: constraints.maxWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ColoredBox(
              color: canvasColors.imageBackground,
              child:
                  FileAvailabilityScope.of(
                    context,
                  ).exists(file.path, defaultValue: true)
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(
                        item.flipHorizontal ? -1.0 : 1.0,
                        item.flipVertical ? -1.0 : 1.0,
                        1.0,
                      ),
                      child: Image(image: imageProvider, fit: BoxFit.contain),
                    )
                  : Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: canvasColors.mutedText,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _BoardPreviewCaptionBox extends StatelessWidget {
  const _BoardPreviewCaptionBox({
    required this.text,
    required this.fontFamily,
    required this.fontSize,
    required this.height,
  });

  final String text;
  final String fontFamily;
  final double fontSize;
  final double height;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final displayText = text.trim();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: _previewCaptionVerticalPadding(fontSize),
      ),
      decoration: BoxDecoration(
        color: canvasColors.imageBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: canvasColors.slotBorder),
      ),
      alignment: Alignment.topLeft,
      child: Text(
        displayText,
        maxLines: _previewCaptionMaxLines(height, fontSize),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: displayText.isEmpty
              ? canvasColors.mutedText
              : canvasColors.text,
          fontFamily: fontFamily,
          fontSize: fontSize,
          height: 1.2,
        ),
      ),
    );
  }
}

class _BoardPreviewSequenceBadge extends StatelessWidget {
  const _BoardPreviewSequenceBadge({
    required this.number,
    required this.fontSize,
  });

  final int number;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final canvasColors = StoryboardCanvasStyle.of(context);
    final size = math.max(22.0, math.min(38.0, fontSize * 1.9));
    return Container(
      width: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: canvasColors.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: canvasColors.accent.withValues(alpha: 0.38)),
      ),
      child: Text(
        '$number',
        style: TextStyle(
          color: canvasColors.text,
          fontSize: math.max(10.0, fontSize * 0.9),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

double _scaledPreviewCaptionFontSize(StoryboardBoard board, double scale) {
  return math.max(6.0, math.min(18.0, board.captionFontSize * scale));
}

double _previewCaptionVerticalPadding(double fontSize) {
  return math.max(3.0, math.min(8.0, fontSize * 0.36));
}

double _previewCaptionMinHeight(double fontSize) {
  return fontSize * 1.2 + _previewCaptionVerticalPadding(fontSize) * 2;
}

int _previewCaptionMaxLines(double height, double fontSize) {
  final lineHeight = math.max(1.0, fontSize * 1.2);
  return math.max(1, (height / lineHeight).floor());
}

String _shortVideoName(String value) {
  final dot = value.lastIndexOf('.');
  return dot <= 0 ? value : value.substring(0, dot);
}
