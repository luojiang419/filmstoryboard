import 'package:flutter/material.dart';

import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';
import 'export_artifact_launcher.dart';

class ExporterPage extends StatefulWidget {
  const ExporterPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<ExporterPage> createState() => _ExporterPageState();
}

class _ExporterPageState extends State<ExporterPage> {
  String _kind = 'storyboardDocument';
  final Set<String> _boardIds = {};
  String _storyboardFormat = 'png';
  String _storyboardResolution = 'sourceDetail';
  bool _includeSummaryPage = true;
  String _videoId = '';
  String _analysisFormat = 'xlsx';
  bool _includeMultiDimensionAnalysis = true;
  bool _includeShotDetails = true;
  String _scriptId = '';
  bool _defaultsApplied = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.exportsAvailable) {
      return const _ExportUnavailable();
    }
    final options = widget.controller.exportOptions;
    if (options == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('正在读取本机导出能力…'),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: widget.controller.exportCommandBusy
                  ? null
                  : widget.controller.refreshExports,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新读取'),
            ),
          ],
        ),
      );
    }
    _syncOptions(options);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1120;
        final configuration = _ConfigurationPanel(
          options: options,
          kind: _kind,
          boardIds: _boardIds,
          storyboardFormat: _storyboardFormat,
          storyboardResolution: _storyboardResolution,
          includeSummaryPage: _includeSummaryPage,
          videoId: _videoId,
          analysisFormat: _analysisFormat,
          includeMultiDimensionAnalysis: _includeMultiDimensionAnalysis,
          includeShotDetails: _includeShotDetails,
          scriptId: _scriptId,
          canEdit: widget.controller.canEdit,
          busy: widget.controller.exportCommandBusy,
          canStart: _canStart(options),
          onKindChanged: (value) => setState(() => _kind = value),
          onBoardChanged: (id, selected) => setState(() {
            if (selected) {
              _boardIds.add(id);
            } else {
              _boardIds.remove(id);
            }
          }),
          onStoryboardFormatChanged: (value) =>
              setState(() => _storyboardFormat = value),
          onStoryboardResolutionChanged: (value) =>
              setState(() => _storyboardResolution = value),
          onIncludeSummaryPageChanged: (value) =>
              setState(() => _includeSummaryPage = value),
          onVideoChanged: (value) => setState(() => _videoId = value),
          onAnalysisFormatChanged: (value) =>
              setState(() => _analysisFormat = value),
          onIncludeMultiDimensionAnalysisChanged: (value) =>
              setState(() => _includeMultiDimensionAnalysis = value),
          onIncludeShotDetailsChanged: (value) =>
              setState(() => _includeShotDetails = value),
          onScriptChanged: (value) => setState(() => _scriptId = value),
          onStart: () => _startExport(options),
        );
        final tasks = _TaskPanel(controller: widget.controller);
        return ColoredBox(
          key: const ValueKey('exporter-page'),
          color: Theme.of(context).colorScheme.surface,
          child: wide
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 520, child: configuration),
                      const SizedBox(width: 20),
                      Expanded(child: SingleChildScrollView(child: tasks)),
                    ],
                  ),
                )
              : ListView(
                  key: const ValueKey('exporter-mobile-scroll'),
                  padding: const EdgeInsets.all(16),
                  children: [configuration, const SizedBox(height: 18), tasks],
                ),
        );
      },
    );
  }

  void _syncOptions(RemoteExportOptions options) {
    final validBoardIds = options.boards.map((board) => board.id).toSet();
    _boardIds.removeWhere((id) => !validBoardIds.contains(id));
    if (_boardIds.isEmpty && options.boards.isNotEmpty) {
      _boardIds.add(options.boards.first.id);
    }
    if (!_defaultsApplied) {
      _storyboardFormat = options.defaults.storyboardFormat;
      _storyboardResolution = options.defaults.storyboardResolution;
      _includeSummaryPage = options.defaults.includeSummaryPage;
      _analysisFormat = options.defaults.analysisReportFormat;
      _includeMultiDimensionAnalysis =
          options.defaults.includeMultiDimensionAnalysis;
      _includeShotDetails = options.defaults.includeShotDetails;
      _defaultsApplied = true;
    }
    if (!options.storyboardFormats.contains(_storyboardFormat)) {
      _storyboardFormat = options.storyboardFormats.firstOrNull ?? 'png';
    }
    if (!options.storyboardResolutions.contains(_storyboardResolution)) {
      _storyboardResolution =
          options.storyboardResolutions.firstOrNull ?? 'sourceDetail';
    }
    if (!options.analysisReportFormats.contains(_analysisFormat)) {
      _analysisFormat = options.analysisReportFormats.firstOrNull ?? 'xlsx';
    }
    if (!options.videos.any((video) => video.id == _videoId)) {
      _videoId = options.videos.firstOrNull?.id ?? '';
    }
    final timelineScripts = options.scripts
        .where((script) => script.timelineAvailable)
        .toList(growable: false);
    if (!timelineScripts.any((script) => script.id == _scriptId)) {
      _scriptId = timelineScripts.firstOrNull?.id ?? '';
    }
  }

  bool _canStart(RemoteExportOptions options) {
    if (!widget.controller.canEdit || widget.controller.exportCommandBusy) {
      return false;
    }
    return switch (_kind) {
      'storyboardDocument' ||
      'boardImages' ||
      'shootingScript' => _boardIds.isNotEmpty,
      'analysisReport' => _videoId.isNotEmpty,
      'timelineXml' => _scriptId.isNotEmpty,
      _ => false,
    };
  }

  void _startExport(RemoteExportOptions options) {
    if (!_canStart(options)) return;
    final request = switch (_kind) {
      'storyboardDocument' => RemoteExportRequest(
        kind: _kind,
        boardIds: _boardIds.toList(growable: false),
        format: _storyboardFormat,
        resolution: _storyboardResolution,
        includeSummaryPage: _includeSummaryPage,
      ),
      'boardImages' || 'shootingScript' => RemoteExportRequest(
        kind: _kind,
        boardIds: _boardIds.toList(growable: false),
      ),
      'analysisReport' => RemoteExportRequest(
        kind: _kind,
        videoId: _videoId,
        format: _analysisFormat,
        includeMultiDimensionAnalysis: _includeMultiDimensionAnalysis,
        includeShotDetails: _includeShotDetails,
      ),
      'timelineXml' => RemoteExportRequest(kind: _kind, scriptId: _scriptId),
      _ => throw StateError('未知导出类型'),
    };
    widget.controller.startExport(request);
  }
}

class _ConfigurationPanel extends StatelessWidget {
  const _ConfigurationPanel({
    required this.options,
    required this.kind,
    required this.boardIds,
    required this.storyboardFormat,
    required this.storyboardResolution,
    required this.includeSummaryPage,
    required this.videoId,
    required this.analysisFormat,
    required this.includeMultiDimensionAnalysis,
    required this.includeShotDetails,
    required this.scriptId,
    required this.canEdit,
    required this.busy,
    required this.canStart,
    required this.onKindChanged,
    required this.onBoardChanged,
    required this.onStoryboardFormatChanged,
    required this.onStoryboardResolutionChanged,
    required this.onIncludeSummaryPageChanged,
    required this.onVideoChanged,
    required this.onAnalysisFormatChanged,
    required this.onIncludeMultiDimensionAnalysisChanged,
    required this.onIncludeShotDetailsChanged,
    required this.onScriptChanged,
    required this.onStart,
  });

  final RemoteExportOptions options;
  final String kind;
  final Set<String> boardIds;
  final String storyboardFormat;
  final String storyboardResolution;
  final bool includeSummaryPage;
  final String videoId;
  final String analysisFormat;
  final bool includeMultiDimensionAnalysis;
  final bool includeShotDetails;
  final String scriptId;
  final bool canEdit;
  final bool busy;
  final bool canStart;
  final ValueChanged<String> onKindChanged;
  final void Function(String id, bool selected) onBoardChanged;
  final ValueChanged<String> onStoryboardFormatChanged;
  final ValueChanged<String> onStoryboardResolutionChanged;
  final ValueChanged<bool> onIncludeSummaryPageChanged;
  final ValueChanged<String> onVideoChanged;
  final ValueChanged<String> onAnalysisFormatChanged;
  final ValueChanged<bool> onIncludeMultiDimensionAnalysisChanged;
  final ValueChanged<bool> onIncludeShotDetailsChanged;
  final ValueChanged<String> onScriptChanged;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.ios_share_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '导出交付文件',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '浏览器只提交资源和格式选项，文件由本机生成并通过安全链接交付。',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            const _SectionLabel('导出类型'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in const [
                  ('storyboardDocument', '故事板文件', Icons.dashboard_rounded),
                  ('boardImages', '画板原图', Icons.photo_library_outlined),
                  ('shootingScript', '拍摄脚本', Icons.table_chart_outlined),
                  ('analysisReport', '解析报告', Icons.analytics_outlined),
                  ('timelineXml', '剪辑时间线', Icons.movie_filter_outlined),
                ])
                  ChoiceChip(
                    key: ValueKey('export-kind-${item.$1}'),
                    avatar: Icon(item.$3, size: 18),
                    label: Text(item.$2),
                    selected: kind == item.$1,
                    onSelected: (_) => onKindChanged(item.$1),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            if (const {
              'storyboardDocument',
              'boardImages',
              'shootingScript',
            }.contains(kind)) ...[
              const _SectionLabel('选择故事板'),
              const SizedBox(height: 8),
              if (options.boards.isEmpty)
                const _EmptyHint('当前工程没有可导出的故事板')
              else
                for (final board in options.boards)
                  CheckboxListTile(
                    key: ValueKey('export-board-${board.id}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: boardIds.contains(board.id),
                    title: Text(board.name),
                    subtitle: Text('${board.itemCount} 个镜头素材'),
                    onChanged: canEdit
                        ? (value) => onBoardChanged(board.id, value == true)
                        : null,
                  ),
            ],
            if (kind == 'storyboardDocument') ...[
              const SizedBox(height: 14),
              _ChoiceField(
                label: '文件格式',
                values: options.storyboardFormats,
                selected: storyboardFormat,
                labelFor: _formatLabel,
                onChanged: onStoryboardFormatChanged,
              ),
              const SizedBox(height: 14),
              _ChoiceField(
                label: '导出精度',
                values: options.storyboardResolutions,
                selected: storyboardResolution,
                labelFor: _resolutionLabel,
                onChanged: onStoryboardResolutionChanged,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('包含故事板内容页'),
                subtitle: const Text('沿用桌面导出的摘要页能力'),
                value: includeSummaryPage,
                onChanged: canEdit ? onIncludeSummaryPageChanged : null,
              ),
            ],
            if (kind == 'analysisReport') ...[
              _DropdownField(
                key: const ValueKey('export-video-select'),
                label: '解析视频',
                value: videoId,
                items: [
                  for (final item in options.videos) (item.id, item.name),
                ],
                onChanged: onVideoChanged,
                emptyText: '当前没有已完成解析的视频',
              ),
              const SizedBox(height: 14),
              _ChoiceField(
                label: '报告格式',
                values: options.analysisReportFormats,
                selected: analysisFormat,
                labelFor: _formatLabel,
                onChanged: onAnalysisFormatChanged,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('包含多维度分析'),
                value: includeMultiDimensionAnalysis,
                onChanged: canEdit
                    ? onIncludeMultiDimensionAnalysisChanged
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('包含镜头明细'),
                value: includeShotDetails,
                onChanged: canEdit ? onIncludeShotDetailsChanged : null,
              ),
            ],
            if (kind == 'timelineXml')
              _DropdownField(
                key: const ValueKey('export-script-select'),
                label: '含已生成视频的拍摄脚本',
                value: scriptId,
                items: [
                  for (final item in options.scripts)
                    if (item.timelineAvailable) (item.id, item.name),
                ],
                onChanged: onScriptChanged,
                emptyText: '当前没有可生成时间线的本机视频',
              ),
            const SizedBox(height: 22),
            FilledButton.icon(
              key: const ValueKey('start-export'),
              onPressed: canStart ? onStart : null,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.rocket_launch_outlined),
              label: Text(canEdit ? '交给本机导出' : '只读会话不能启动导出'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskPanel extends StatelessWidget {
  const _TaskPanel({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final tasks = controller.exportTasks;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '本机导出任务',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新导出状态',
                  onPressed: controller.exportCommandBusy
                      ? null
                      : controller.refreshExports,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '刷新浏览器后仍可恢复当前桌面进程中的任务和安全下载。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (tasks.isEmpty)
              const _EmptyHint('还没有 Web 导出任务')
            else
              for (final task in tasks) ...[
                _ExportTaskCard(controller: controller, task: task),
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

class _ExportTaskCard extends StatelessWidget {
  const _ExportTaskCard({required this.controller, required this.task});

  final RemoteAppController controller;
  final RemoteTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artifacts = task.exportArtifacts;
    return Container(
      key: ValueKey('export-task-${task.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _taskIcon(task.status),
                color: _taskColor(scheme, task.status),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _exportKindLabel(task.exportKind),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      _taskStatusLabel(task.status),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (task.cancellable && controller.canEdit)
                TextButton(
                  onPressed: controller.exportCommandBusy
                      ? null
                      : () => controller.cancelExportTask(task.id),
                  child: const Text('取消'),
                )
              else if (task.exportRetryable && controller.canEdit)
                TextButton.icon(
                  onPressed: controller.exportCommandBusy
                      ? null
                      : () => controller.retryExportTask(task.id),
                  icon: const Icon(Icons.replay_rounded, size: 18),
                  label: const Text('重试'),
                ),
            ],
          ),
          if (!task.terminal) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: task.progress),
          ],
          if (task.errorMessage.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(task.errorMessage, style: TextStyle(color: scheme.error)),
          ] else if (task.message.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(task.message),
          ],
          if (artifacts.isNotEmpty) ...[
            const Divider(height: 26),
            for (final artifact in artifacts)
              _ArtifactTile(controller: controller, artifact: artifact),
          ],
        ],
      ),
    );
  }
}

class _ArtifactTile extends StatelessWidget {
  const _ArtifactTile({required this.controller, required this.artifact});

  final RemoteAppController controller;
  final RemoteExportArtifact artifact;

  @override
  Widget build(BuildContext context) {
    final previewUri = controller.exportArtifactUri(artifact, download: false);
    final downloadUri = controller.exportArtifactUri(artifact, download: true);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(_artifactIcon(artifact.contentType), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artifact.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(_fileSize(artifact.size)),
              ],
            ),
          ),
          if (artifact.previewable)
            IconButton(
              key: ValueKey('preview-export-artifact-${artifact.id}'),
              tooltip: '安全预览',
              onPressed: previewUri == null
                  ? null
                  : () => openExportArtifact(
                      previewUri,
                      download: false,
                      fileName: artifact.fileName,
                    ),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          IconButton(
            key: ValueKey('download-export-artifact-${artifact.id}'),
            tooltip: '下载',
            onPressed: downloadUri == null
                ? null
                : () => openExportArtifact(
                    downloadUri,
                    download: true,
                    fileName: artifact.fileName,
                  ),
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
    );
  }
}

class _ChoiceField extends StatelessWidget {
  const _ChoiceField({
    required this.label,
    required this.values,
    required this.selected,
    required this.labelFor,
    required this.onChanged,
  });

  final String label;
  final List<String> values;
  final String selected;
  final String Function(String) labelFor;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SectionLabel(label),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final value in values)
            ChoiceChip(
              label: Text(labelFor(value)),
              selected: value == selected,
              onSelected: (_) => onChanged(value),
            ),
        ],
      ),
    ],
  );
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.emptyText,
  });

  final String label;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return _EmptyHint(emptyText);
    return DropdownButtonFormField<String>(
      initialValue: items.any((item) => item.$1 == value) ? value : null,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in items)
          DropdownMenuItem(value: item.$1, child: Text(item.$2)),
      ],
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text),
  );
}

class _ExportUnavailable extends StatelessWidget {
  const _ExportUnavailable();

  @override
  Widget build(BuildContext context) =>
      const Center(child: _EmptyHint('当前桌面版本未启用 Web 导出能力'));
}

String _formatLabel(String value) => switch (value) {
  'png' => 'PNG',
  'jpg' => 'JPG',
  'pdf' => 'PDF',
  'xlsx' => 'XLSX',
  _ => value.toUpperCase(),
};

String _resolutionLabel(String value) => switch (value) {
  'standard' => '标准尺寸',
  'sourceDetail' => '原图细节',
  _ => value,
};

String _exportKindLabel(String value) => switch (value) {
  'storyboardDocument' => '故事板文件',
  'boardImages' => '画板原图',
  'shootingScript' => '拍摄脚本',
  'analysisReport' => '视频解析报告',
  'timelineXml' => '剪辑时间线',
  _ => '导出任务',
};

String _taskStatusLabel(String value) => switch (value) {
  'queued' => '等待本机处理',
  'running' => '本机正在生成',
  'succeeded' => '导出完成',
  'failed' => '导出失败',
  'cancelled' => '已取消',
  _ => value,
};

IconData _taskIcon(String status) => switch (status) {
  'succeeded' => Icons.check_circle_rounded,
  'failed' => Icons.error_rounded,
  'cancelled' => Icons.cancel_rounded,
  _ => Icons.pending_rounded,
};

Color _taskColor(ColorScheme scheme, String status) => switch (status) {
  'succeeded' => Colors.green,
  'failed' => scheme.error,
  'cancelled' => scheme.onSurfaceVariant,
  _ => scheme.primary,
};

IconData _artifactIcon(String contentType) {
  if (contentType.startsWith('image/')) return Icons.image_outlined;
  if (contentType == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (contentType.contains('spreadsheet')) return Icons.table_chart_outlined;
  return Icons.description_outlined;
}

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
