class RemoteStoryboardSummaryRecord {
  const RemoteStoryboardSummaryRecord({
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
  });

  final String outline;
  final String content;
  final String scenes;
  final String props;
}

class RemoteStoryboardItemRecord {
  const RemoteStoryboardItemRecord({
    required this.assetId,
    required this.sourceName,
    required this.indexNo,
    required this.localPath,
    required this.caption,
    required this.slotIndex,
    required this.flipHorizontal,
    required this.flipVertical,
    required this.resourceRemoved,
  });

  final String assetId;
  final String sourceName;
  final int indexNo;

  /// 仅供桌面服务注册媒体白名单，禁止直接序列化到远程响应。
  final String localPath;
  final String caption;
  final int slotIndex;
  final bool flipHorizontal;
  final bool flipVertical;
  final bool resourceRemoved;
}

class RemoteStoryboardAssetRecord {
  const RemoteStoryboardAssetRecord({
    required this.id,
    required this.sourceName,
    required this.indexNo,
    required this.localPath,
  });

  final String id;
  final String sourceName;
  final int indexNo;

  /// 仅供桌面服务注册媒体白名单，禁止直接序列化到远程响应。
  final String localPath;
}

class RemoteStoryboardBoardRecord {
  const RemoteStoryboardBoardRecord({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.rows,
    required this.columns,
    required this.gap,
    required this.storyDescriptionEnabled,
    required this.rowDescriptionEnabled,
    required this.rowCaptions,
    required this.rowDividerEnabled,
    required this.rowDividerStyle,
    required this.rowDividerOpacity,
    required this.titleAlignment,
    required this.portraitMode,
    required this.locked,
    required this.groupId,
    required this.summary,
    required this.items,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final int rows;
  final int columns;
  final double gap;
  final bool storyDescriptionEnabled;
  final bool rowDescriptionEnabled;
  final List<String> rowCaptions;
  final bool rowDividerEnabled;
  final String rowDividerStyle;
  final double rowDividerOpacity;
  final String titleAlignment;
  final bool portraitMode;
  final bool locked;
  final String? groupId;
  final RemoteStoryboardSummaryRecord? summary;
  final List<RemoteStoryboardItemRecord> items;
}

class RemoteStoryboardBoardGroupRecord {
  const RemoteStoryboardBoardGroupRecord({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

class RemoteStoryboardEditCommand {
  const RemoteStoryboardEditCommand({
    required this.boardId,
    this.name,
    this.itemCaptions = const {},
    this.rowCaptions,
    this.summary,
    this.clearSummary = false,
  });

  final String boardId;
  final String? name;
  final Map<String, String> itemCaptions;
  final List<String>? rowCaptions;
  final RemoteStoryboardSummaryRecord? summary;
  final bool clearSummary;
}

enum RemoteStoryboardLayoutAction { add, move, remove }

class RemoteStoryboardLayoutCommand {
  const RemoteStoryboardLayoutCommand({
    required this.boardId,
    required this.action,
    required this.assetId,
    this.slotIndex,
  });

  final String boardId;
  final RemoteStoryboardLayoutAction action;
  final String assetId;
  final int? slotIndex;
}

enum RemoteStoryboardEditOutcome { updated, unchanged, notFound, locked }

class RemoteStoryboardAnnotation {
  const RemoteStoryboardAnnotation({
    required this.id,
    required this.boardId,
    required this.body,
    required this.authorSessionId,
    required this.authorName,
    required this.createdAt,
    required this.updatedAt,
    required this.resolved,
    this.assetId,
  });

  final String id;
  final String boardId;
  final String? assetId;
  final String body;
  final String authorSessionId;
  final String authorName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool resolved;

  RemoteStoryboardAnnotation copyWith({
    String? body,
    DateTime? updatedAt,
    bool? resolved,
  }) => RemoteStoryboardAnnotation(
    id: id,
    boardId: boardId,
    assetId: assetId,
    body: body ?? this.body,
    authorSessionId: authorSessionId,
    authorName: authorName,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    resolved: resolved ?? this.resolved,
  );
}

class RemoteStoryboardSourceChange {
  const RemoteStoryboardSourceChange({
    required this.boardIds,
    required this.structureChanged,
  });

  final Set<String> boardIds;
  final bool structureChanged;
}

abstract interface class RemoteStoryboardSource {
  List<RemoteStoryboardBoardRecord> get boards;
  List<RemoteStoryboardBoardGroupRecord> get boardGroups;
  List<RemoteStoryboardAssetRecord> get assets;
  Stream<RemoteStoryboardSourceChange> get changes;

  RemoteStoryboardBoardRecord? boardById(String boardId);

  RemoteStoryboardEditOutcome applyEdit(RemoteStoryboardEditCommand command);
  RemoteStoryboardEditOutcome applyLayout(
    RemoteStoryboardLayoutCommand command,
  );
}
