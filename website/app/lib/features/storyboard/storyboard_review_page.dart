import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';

class StoryboardReviewPage extends StatefulWidget {
  const StoryboardReviewPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<StoryboardReviewPage> createState() => _StoryboardReviewPageState();
}

class _StoryboardReviewPageState extends State<StoryboardReviewPage> {
  final _nameController = TextEditingController();
  final _outlineController = TextEditingController();
  final _contentController = TextEditingController();
  final _scenesController = TextEditingController();
  final _propsController = TextEditingController();
  final _annotationController = TextEditingController();
  final Map<String, TextEditingController> _captionControllers = {};
  final List<TextEditingController> _rowCaptionControllers = [];

  String _loadedBoardId = '';
  int _loadedRevision = 0;
  bool _dirty = false;
  bool _saving = false;
  bool _annotationTargetsItem = false;

  bool get _editable {
    final detail = widget.controller.selectedStoryboard;
    return widget.controller.canEdit && detail != null && !detail.locked;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _outlineController.dispose();
    _contentController.dispose();
    _scenesController.dispose();
    _propsController.dispose();
    _annotationController.dispose();
    for (final controller in _captionControllers.values) {
      controller.dispose();
    }
    for (final controller in _rowCaptionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.controller.selectedStoryboard;
    _syncForm(detail);
    if (!widget.controller.storyboardsAvailable) {
      return const _EmptyReviewState(
        icon: Icons.extension_off_outlined,
        title: '桌面端尚未开放故事板远程审阅',
        message: '请更新桌面端并重新连接。拍摄脚本功能仍可继续使用。',
      );
    }
    if (widget.controller.storyboards.isEmpty) {
      return const _EmptyReviewState(
        icon: Icons.dashboard_customize_outlined,
        title: '当前工程还没有故事板',
        message: '请先在桌面端创建画板或从视频解析结果生成故事板。',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 1040;
        final boardList = _StoryboardBoardList(
          controller: widget.controller,
          groups: widget.controller.storyboardGroups,
        );
        final editor = detail == null
            ? const Center(child: Text('选择一个故事板开始审阅'))
            : _buildEditor(detail);
        if (desktop) {
          return Row(
            children: [
              SizedBox(width: 286, child: boardList),
              const VerticalDivider(width: 1),
              Expanded(child: editor),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: 174, child: boardList),
            const Divider(height: 1),
            Expanded(child: editor),
          ],
        );
      },
    );
  }

  Widget _buildEditor(RemoteStoryboardDetail detail) {
    final controller = widget.controller;
    final canAnnotate = controller.canEdit;
    final revisionChangedWhileEditing =
        _dirty && detail.revision != _loadedRevision;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 420,
                    child: TextField(
                      key: const ValueKey('storyboard-name-field'),
                      controller: _nameController,
                      readOnly: !_editable,
                      decoration: const InputDecoration(
                        labelText: '画板名称',
                        prefixIcon: Icon(Icons.dashboard_customize_outlined),
                      ),
                      onChanged: (_) => _markDirty(),
                    ),
                  ),
                  _StateChip(
                    icon: detail.locked
                        ? Icons.lock_outline_rounded
                        : Icons.lock_open_rounded,
                    label: detail.locked ? '桌面端已锁定' : '可编辑',
                    warning: detail.locked,
                  ),
                  _StateChip(
                    icon: controller.canEdit
                        ? Icons.edit_note_rounded
                        : Icons.visibility_outlined,
                    label: controller.canEdit ? '导演权限' : '只读权限',
                  ),
                  Text('修订 ${detail.revision}'),
                ],
              ),
              if (revisionChangedWhileEditing) ...[
                const SizedBox(height: 12),
                const MaterialBanner(
                  content: Text('检测到桌面端或其他导演已有新修改。保存时会执行版本检查，不会静默覆盖。'),
                  actions: [SizedBox.shrink()],
                ),
              ],
              const SizedBox(height: 18),
              _sectionTitle(
                '画板审阅',
                '${detail.rows} 行 × ${detail.columns} 列 · ${detail.itemCount} 个镜头',
              ),
              const SizedBox(height: 10),
              _StoryboardGrid(
                controller: controller,
                detail: detail,
                captionControllers: _captionControllers,
                editable: _editable,
                onCaptionChanged: _markDirty,
              ),
              const SizedBox(height: 20),
              _buildSummaryEditor(detail),
              const SizedBox(height: 20),
              _buildRowCaptionEditor(detail),
              const SizedBox(height: 20),
              _buildAnnotations(detail, canAnnotate: canAnnotate),
              const SizedBox(height: 22),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const ValueKey('save-storyboard-review'),
                  onPressed: _dirty && _editable && !_saving ? _save : null,
                  icon: const Icon(Icons.cloud_done_outlined),
                  label: Text(_saving ? '正在同步…' : '保存故事板修改'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryEditor(RemoteStoryboardDetail detail) => Card(
    child: ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(Icons.auto_stories_outlined),
      title: const Text('故事概述'),
      subtitle: const Text('梗概、主要内容、场景与道具'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      children: [
        _textField(_outlineController, '故事梗概', lines: 2),
        const SizedBox(height: 10),
        _textField(_contentController, '主要内容', lines: 3),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _textField(_scenesController, '场景', lines: 2)),
            const SizedBox(width: 10),
            Expanded(child: _textField(_propsController, '道具', lines: 2)),
          ],
        ),
      ],
    ),
  );

  Widget _buildRowCaptionEditor(RemoteStoryboardDetail detail) {
    if (!detail.rowDescriptionEnabled) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.view_stream_outlined),
        title: const Text('逐行描述'),
        subtitle: Text('${detail.rows} 行故事描述'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        children: [
          for (
            var index = 0;
            index < _rowCaptionControllers.length;
            index++
          ) ...[
            _textField(
              _rowCaptionControllers[index],
              '第 ${index + 1} 行',
              lines: 2,
            ),
            if (index != _rowCaptionControllers.length - 1)
              const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildAnnotations(
    RemoteStoryboardDetail detail, {
    required bool canAnnotate,
  }) {
    final selectedItem = widget.controller.selectedStoryboardItem;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle('审阅批注', '${detail.unresolvedAnnotationCount} 条未解决'),
            const SizedBox(height: 12),
            if (canAnnotate) ...[
              SegmentedButton<bool>(
                segments: [
                  const ButtonSegment(
                    value: false,
                    icon: Icon(Icons.dashboard_outlined),
                    label: Text('画板整体'),
                  ),
                  ButtonSegment(
                    value: true,
                    enabled: selectedItem != null,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      selectedItem == null
                          ? '先选镜头'
                          : '镜头 ${selectedItem.slotIndex + 1}',
                    ),
                  ),
                ],
                selected: {_annotationTargetsItem && selectedItem != null},
                onSelectionChanged: (values) =>
                    setState(() => _annotationTargetsItem = values.first),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('new-storyboard-annotation'),
                controller: _annotationController,
                minLines: 2,
                maxLines: 4,
                maxLength: 4000,
                decoration: const InputDecoration(
                  labelText: '写下导演批注',
                  hintText: '例如：人物视线向左一些，衔接上一镜动作。',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('add-storyboard-annotation'),
                  onPressed: widget.controller.busy ? null : _addAnnotation,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('添加批注'),
                ),
              ),
              const Divider(height: 28),
            ] else
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('当前为只读会话，可查看批注但不能新增或修改。'),
              ),
            if (detail.annotations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('还没有批注。'),
              )
            else
              for (final annotation in detail.annotations)
                _AnnotationTile(
                  annotation: annotation,
                  item: detail.items.cast<RemoteStoryboardItem?>().firstWhere(
                    (item) => item?.assetId == annotation.assetId,
                    orElse: () => null,
                  ),
                  canEdit: canAnnotate,
                  busy: widget.controller.busy,
                  onResolve: () => widget.controller.updateStoryboardAnnotation(
                    annotationId: annotation.id,
                    resolved: !annotation.resolved,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    int lines = 1,
  }) => TextField(
    controller: controller,
    readOnly: !_editable,
    minLines: lines,
    maxLines: lines,
    decoration: InputDecoration(labelText: label),
    onChanged: (_) => _markDirty(),
  );

  Widget _sectionTitle(String title, String subtitle) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
      ),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  void _syncForm(RemoteStoryboardDetail? detail) {
    if (detail == null) {
      _loadedBoardId = '';
      _loadedRevision = 0;
      return;
    }
    final boardChanged = detail.id != _loadedBoardId;
    final revisionChanged = detail.revision != _loadedRevision;
    if (!boardChanged && (!revisionChanged || _dirty)) return;
    _loadedBoardId = detail.id;
    _loadedRevision = detail.revision;
    _dirty = false;
    _nameController.text = detail.name;
    _outlineController.text = detail.storySummary?.outline ?? '';
    _contentController.text = detail.storySummary?.content ?? '';
    _scenesController.text = detail.storySummary?.scenes ?? '';
    _propsController.text = detail.storySummary?.props ?? '';
    final validAssetIds = detail.items.map((item) => item.assetId).toSet();
    final removedIds = _captionControllers.keys
        .where((id) => !validAssetIds.contains(id))
        .toList();
    for (final id in removedIds) {
      _captionControllers.remove(id)?.dispose();
    }
    for (final item in detail.items) {
      (_captionControllers[item.assetId] ??= TextEditingController()).text =
          item.caption;
    }
    while (_rowCaptionControllers.length < detail.rows) {
      _rowCaptionControllers.add(TextEditingController());
    }
    while (_rowCaptionControllers.length > detail.rows) {
      _rowCaptionControllers.removeLast().dispose();
    }
    for (var index = 0; index < detail.rows; index++) {
      _rowCaptionControllers[index].text = index < detail.rowCaptions.length
          ? detail.rowCaptions[index]
          : '';
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    final detail = widget.controller.selectedStoryboard;
    if (detail == null || !_editable || _saving) return;
    setState(() => _saving = true);
    await widget.controller.saveSelectedStoryboard({
      'name': _nameController.text,
      'summary': {
        'outline': _outlineController.text,
        'content': _contentController.text,
        'scenes': _scenesController.text,
        'props': _propsController.text,
      },
      'itemCaptions': {
        for (final item in detail.items)
          item.assetId: _captionControllers[item.assetId]?.text ?? '',
      },
      if (detail.rowDescriptionEnabled)
        'rowCaptions': [
          for (final controller in _rowCaptionControllers) controller.text,
        ],
    }, expectedRevision: _loadedRevision);
    if (!mounted) return;
    final shouldReloadFromController =
        widget.controller.errorMessage.isEmpty ||
        widget.controller.errorMessage.contains('已为你加载最新版本');
    setState(() {
      _saving = false;
      if (shouldReloadFromController) _dirty = false;
    });
  }

  Future<void> _addAnnotation() async {
    final body = _annotationController.text.trim();
    if (body.isEmpty) return;
    final assetId = _annotationTargetsItem
        ? widget.controller.selectedStoryboardItem?.assetId
        : null;
    await widget.controller.addStoryboardAnnotation(
      body: body,
      assetId: assetId,
    );
    if (!mounted || widget.controller.errorMessage.isNotEmpty) return;
    _annotationController.clear();
  }
}

class _StoryboardBoardList extends StatelessWidget {
  const _StoryboardBoardList({required this.controller, required this.groups});

  final RemoteAppController controller;
  final List<RemoteStoryboardGroup> groups;

  @override
  Widget build(BuildContext context) {
    final groupNames = {for (final group in groups) group.id: group.name};
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: controller.storyboards.length,
        itemBuilder: (context, index) {
          final board = controller.storyboards[index];
          final selected = controller.selectedStoryboard?.id == board.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: ListTile(
              key: ValueKey('storyboard-nav-${board.id}'),
              selected: selected,
              selectedTileColor: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: .65),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: Icon(
                board.locked
                    ? Icons.lock_outline_rounded
                    : Icons.dashboard_customize_outlined,
              ),
              title: Text(
                board.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                '${groupNames[board.groupId] ?? '未编组'} · ${board.itemCount} 镜头 · r${board.revision}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: board.unresolvedAnnotationCount == 0
                  ? null
                  : Badge(
                      label: Text('${board.unresolvedAnnotationCount}'),
                      child: const Icon(Icons.comment_outlined, size: 18),
                    ),
              onTap: controller.busy
                  ? null
                  : () => controller.selectStoryboard(board.id),
            ),
          );
        },
      ),
    );
  }
}

class _StoryboardGrid extends StatelessWidget {
  const _StoryboardGrid({
    required this.controller,
    required this.detail,
    required this.captionControllers,
    required this.editable,
    required this.onCaptionChanged,
  });

  final RemoteAppController controller;
  final RemoteStoryboardDetail detail;
  final Map<String, TextEditingController> captionControllers;
  final bool editable;
  final VoidCallback onCaptionChanged;

  @override
  Widget build(BuildContext context) {
    final items = [...detail.items]
      ..sort((first, second) => first.slotIndex.compareTo(second.slotIndex));
    if (items.isEmpty) {
      return const SizedBox(
        height: 180,
        child: Center(child: Text('当前画板还没有镜头图片。')),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final responsiveColumns = (constraints.maxWidth / 230).floor().clamp(
          1,
          6,
        );
        final columns = detail.portraitMode
            ? 1
            : detail.columns.clamp(1, responsiveColumns);
        final rows = (items.length / columns).ceil();
        final height = (rows * 248).clamp(260, 820).toDouble();
        return SizedBox(
          height: height,
          child: GridView.builder(
            key: const ValueKey('remote-storyboard-grid'),
            itemCount: items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: .92,
            ),
            itemBuilder: (context, index) {
              final item = items[index];
              final selected =
                  controller.selectedStoryboardItem?.assetId == item.assetId;
              return Card(
                clipBehavior: Clip.antiAlias,
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: InkWell(
                  onTap: () => controller.selectStoryboardItem(item.assetId),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _StoryboardRemoteImage(
                              controller: controller,
                              mediaId: item.imageMediaId,
                              flipHorizontal: item.flipHorizontal,
                              flipVertical: item.flipVertical,
                            ),
                            Positioned(
                              left: 8,
                              top: 8,
                              child: CircleAvatar(
                                radius: 15,
                                child: Text('${item.slotIndex + 1}'),
                              ),
                            ),
                            if (item.resourceRemoved)
                              const Center(child: Chip(label: Text('源图片已移除'))),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                        child: TextField(
                          key: ValueKey('storyboard-caption-${item.assetId}'),
                          controller: captionControllers[item.assetId],
                          readOnly: !editable,
                          minLines: 2,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '镜头描述',
                            border: InputBorder.none,
                          ),
                          onChanged: (_) => onCaptionChanged(),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _StoryboardRemoteImage extends StatelessWidget {
  const _StoryboardRemoteImage({
    required this.controller,
    required this.mediaId,
    required this.flipHorizontal,
    required this.flipVertical,
  });

  final RemoteAppController controller;
  final String? mediaId;
  final bool flipHorizontal;
  final bool flipVertical;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.image_not_supported_outlined)),
    );
    if (mediaId == null) return placeholder;
    return FutureBuilder<Uint8List>(
      future: controller.mediaBytes(mediaId!),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return placeholder;
        final image = Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        );
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(
            flipHorizontal ? -1 : 1,
            flipVertical ? -1 : 1,
            1,
          ),
          child: image,
        );
      },
    );
  }
}

class _AnnotationTile extends StatelessWidget {
  const _AnnotationTile({
    required this.annotation,
    required this.item,
    required this.canEdit,
    required this.busy,
    required this.onResolve,
  });

  final RemoteStoryboardAnnotation annotation;
  final RemoteStoryboardItem? item;
  final bool canEdit;
  final bool busy;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      annotation.resolved
          ? Icons.check_circle_rounded
          : Icons.chat_bubble_outline_rounded,
      color: annotation.resolved ? const Color(0xff43a777) : null,
    ),
    title: Text(
      annotation.body,
      style: TextStyle(
        decoration: annotation.resolved ? TextDecoration.lineThrough : null,
      ),
    ),
    subtitle: Text(
      '${annotation.authorName} · ${item == null ? '画板整体' : '镜头 ${item!.slotIndex + 1}'}',
    ),
    trailing: canEdit
        ? TextButton(
            onPressed: busy ? null : onResolve,
            child: Text(annotation.resolved ? '重新打开' : '标记解决'),
          )
        : null,
  );
}

class _StateChip extends StatelessWidget {
  const _StateChip({
    required this.icon,
    required this.label,
    this.warning = false,
  });

  final IconData icon;
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 17),
    label: Text(label),
    backgroundColor: warning
        ? Theme.of(context).colorScheme.errorContainer
        : null,
  );
}

class _EmptyReviewState extends StatelessWidget {
  const _EmptyReviewState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
