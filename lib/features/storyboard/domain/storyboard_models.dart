import 'dart:math' as math;

import '../../../core/database/app_database.dart';

/// 自动扩展故事板时允许的单边宫格上限（最多 10,000 张图片）。
const storyboardMaxGridExtent = 100;

class StoryboardCutAsset {
  const StoryboardCutAsset({
    required this.id,
    required this.imageId,
    required this.sourceName,
    required this.path,
    required this.indexNo,
  });

  final String id;
  final String imageId;
  final String sourceName;
  final String path;
  final int indexNo;

  factory StoryboardCutAsset.fromRecord(CutResultRecord record) {
    return StoryboardCutAsset(
      id: record.id,
      imageId: record.imageId,
      sourceName: record.originalName,
      path: record.path,
      indexNo: record.indexNo,
    );
  }
}

class StoryboardExternalImage {
  const StoryboardExternalImage({
    required this.stableId,
    required this.sourceName,
    required this.path,
    required this.width,
    required this.height,
    this.caption = '',
  });

  final String stableId;
  final String sourceName;
  final String path;
  final int width;
  final int height;
  final String caption;
}

class StoryboardFolder {
  const StoryboardFolder({
    required this.id,
    required this.name,
    required this.path,
    required this.assets,
  });

  final String id;
  final String name;
  final String path;
  final List<StoryboardCutAsset> assets;
}

class StoryboardResourceGroup {
  const StoryboardResourceGroup({
    required this.id,
    required this.name,
    required this.assetIds,
    required this.sourceImageIds,
    required this.folderIds,
    this.parentGroupId,
    this.childOrder = const [],
    this.expanded = true,
  });

  final String id;
  final String name;
  final List<String> assetIds;
  final List<String> sourceImageIds;
  final List<String> folderIds;
  final String? parentGroupId;
  final List<String> childOrder;
  final bool expanded;

  bool get isEmpty =>
      assetIds.isEmpty && sourceImageIds.isEmpty && folderIds.isEmpty;

  StoryboardResourceGroup copyWith({
    String? name,
    List<String>? assetIds,
    List<String>? sourceImageIds,
    List<String>? folderIds,
    Object? parentGroupId = _copyWithSentinel,
    List<String>? childOrder,
    bool? expanded,
  }) {
    return StoryboardResourceGroup(
      id: id,
      name: name ?? this.name,
      assetIds: assetIds ?? this.assetIds,
      sourceImageIds: sourceImageIds ?? this.sourceImageIds,
      folderIds: folderIds ?? this.folderIds,
      parentGroupId: identical(parentGroupId, _copyWithSentinel)
          ? this.parentGroupId
          : parentGroupId as String?,
      childOrder: childOrder ?? this.childOrder,
      expanded: expanded ?? this.expanded,
    );
  }
}

enum StoryboardResourceNodeKind { group, folder, source }

class StoryboardResourceNodeRef {
  const StoryboardResourceNodeRef({required this.kind, required this.id});

  const StoryboardResourceNodeRef.group(String id)
    : this(kind: StoryboardResourceNodeKind.group, id: id);

  const StoryboardResourceNodeRef.folder(String id)
    : this(kind: StoryboardResourceNodeKind.folder, id: id);

  const StoryboardResourceNodeRef.source(String id)
    : this(kind: StoryboardResourceNodeKind.source, id: id);

  final StoryboardResourceNodeKind kind;
  final String id;

  String get key => '${kind.name}:$id';

  static StoryboardResourceNodeRef? tryParse(String value) {
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      return null;
    }
    final kindName = value.substring(0, separator);
    final id = value.substring(separator + 1);
    for (final kind in StoryboardResourceNodeKind.values) {
      if (kind.name == kindName) {
        return StoryboardResourceNodeRef(kind: kind, id: id);
      }
    }
    return null;
  }
}

class StoryboardBoardGroup {
  const StoryboardBoardGroup({required this.id, required this.name});

  final String id;
  final String name;

  StoryboardBoardGroup copyWith({String? name}) {
    return StoryboardBoardGroup(id: id, name: name ?? this.name);
  }
}

class StoryboardItem {
  const StoryboardItem({
    required this.asset,
    required this.caption,
    required this.slotIndex,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.resourceRemoved = false,
  });

  final StoryboardCutAsset asset;
  final String caption;
  final int slotIndex;
  final bool flipHorizontal;
  final bool flipVertical;

  /// 左侧裁切资源已删除时，手动画板保留原格位供用户替换或移除。
  final bool resourceRemoved;

  StoryboardItem copyWith({
    StoryboardCutAsset? asset,
    String? caption,
    int? slotIndex,
    bool? flipHorizontal,
    bool? flipVertical,
    bool? resourceRemoved,
  }) {
    return StoryboardItem(
      asset: asset ?? this.asset,
      caption: caption ?? this.caption,
      slotIndex: slotIndex ?? this.slotIndex,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      resourceRemoved: resourceRemoved ?? this.resourceRemoved,
    );
  }
}

enum StoryboardDividerStyle {
  solid('实线'),
  dashed('虚线');

  const StoryboardDividerStyle(this.label);

  final String label;
}

enum StoryboardTitleAlignment {
  center('居中'),
  left('居左'),
  right('居右');

  const StoryboardTitleAlignment(this.label);

  final String label;
}

class StoryboardBoard {
  static const landscapeImageAspectRatio = 16 / 9;
  static const defaultImageAspectRatio = landscapeImageAspectRatio;
  static const _tilePadding = 6.0;
  static const _imageCaptionGap = 6.0;
  static const _tileLayoutSafety = 1.0;

  const StoryboardBoard({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.rows,
    required this.columns,
    required this.gap,
    required this.items,
    this.configuredRows,
    this.configuredColumns,
    this.storyDescriptionEnabled = true,
    this.rowDescriptionEnabled = false,
    this.captionFontFamily = 'Microsoft YaHei UI',
    this.captionFontSize = 12,
    this.rowCaptions = const [],
    this.rowDividerEnabled = true,
    this.rowDividerStyle = StoryboardDividerStyle.dashed,
    this.rowDividerOpacity = 0.35,
    this.titleAlignment = StoryboardTitleAlignment.center,
    this.portraitMode = false,
    this.locked = false,
    this.autoGeneratedSourceImageId,
    this.groupId,
    this.summary,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final int rows;
  final int columns;
  final double gap;
  final List<StoryboardItem> items;
  final int? configuredRows;
  final int? configuredColumns;
  final bool storyDescriptionEnabled;
  final bool rowDescriptionEnabled;
  final String captionFontFamily;
  final double captionFontSize;
  final List<String> rowCaptions;
  final bool rowDividerEnabled;
  final StoryboardDividerStyle rowDividerStyle;
  final double rowDividerOpacity;
  final StoryboardTitleAlignment titleAlignment;
  final bool portraitMode;
  final bool locked;

  /// 自动生成画板所绑定的裁切资源组；手动画板始终为 null。
  final String? autoGeneratedSourceImageId;
  final String? groupId;
  final StoryboardSummary? summary;

  int get slotCount => rows * columns;

  int get effectiveConfiguredRows => configuredRows ?? rows;

  int get effectiveConfiguredColumns => configuredColumns ?? columns;

  int get configuredSlotCount =>
      effectiveConfiguredRows * effectiveConfiguredColumns;

  bool get isAutoExpandedFromConfiguredLayout {
    return rows != effectiveConfiguredRows ||
        columns != effectiveConfiguredColumns;
  }

  double get imageAspectRatio => landscapeImageAspectRatio;

  int get visibleItemCount {
    return items
        .where((item) => item.slotIndex >= 0 && item.slotIndex < slotCount)
        .length;
  }

  StoryboardItem? itemAtSlot(int slotIndex) {
    for (final item in items) {
      if (item.slotIndex == slotIndex) {
        return item;
      }
    }
    return null;
  }

  String rowCaptionAt(int rowIndex) {
    if (rowIndex < 0 || rowIndex >= rowCaptions.length) {
      return '';
    }
    return rowCaptions[rowIndex];
  }

  int? firstEmptySlot() {
    final usedSlots = {
      for (final item in items)
        if (item.slotIndex >= 0 && item.slotIndex < slotCount) item.slotIndex,
    };
    for (var index = 0; index < slotCount; index++) {
      if (!usedSlots.contains(index)) {
        return index;
      }
    }
    return null;
  }

  static int heightForLayout({
    required int width,
    required int rows,
    required int columns,
    double gap = 18,
    List<StoryboardItem> items = const [],
    bool storyDescriptionEnabled = true,
    bool rowDescriptionEnabled = false,
    double captionFontSize = 12,
    List<String> rowCaptions = const [],
    bool portraitMode = false,
  }) {
    final safeWidth = width.clamp(1, 12000).toInt();
    final safeRows = rows
        .clamp(
          1,
          portraitMode
              ? storyboardMaxGridExtent * storyboardMaxGridExtent
              : storyboardMaxGridExtent,
        )
        .toInt();
    final safeColumns = columns.clamp(1, storyboardMaxGridExtent).toInt();
    final titleHeight = titleHeightFor(captionFontSize);
    final cellWidth = math.max(
      1.0,
      (safeWidth - gap * (safeColumns + 1)) / safeColumns,
    );
    final cellHeight = !portraitMode && items.isEmpty
        ? cellWidth
        : math.max(
            1.0,
            (cellWidth - _tilePadding * 2) / landscapeImageAspectRatio +
                _tilePadding * 2 +
                _tileLayoutSafety,
          );
    final gridHeight = gap * (safeRows + 1) + cellHeight * safeRows;
    final titledGridHeight = gridHeight + titleHeight + gap;
    if (!storyDescriptionEnabled) {
      return titledGridHeight
          .ceil()
          .clamp(1, portraitMode ? 60000 : 12000)
          .toInt();
    }
    final textHeight = rowDescriptionEnabled
        ? maxRowCaptionHeight(
            width: safeWidth.toDouble(),
            gap: gap,
            rows: safeRows,
            rowCaptions: rowCaptions,
            fontSize: captionFontSize,
          )
        : maxItemCaptionHeight(
            width: safeWidth.toDouble(),
            gap: gap,
            columns: safeColumns,
            items: items,
            fontSize: captionFontSize,
          );
    if (textHeight <= 0) {
      return titledGridHeight
          .ceil()
          .clamp(1, portraitMode ? 60000 : 12000)
          .toInt();
    }
    final captionGap = rowDescriptionEnabled
        ? math.max(4.0, math.min(8.0, gap * 0.45))
        : _imageCaptionGap;
    return (titledGridHeight + safeRows * (textHeight + captionGap))
        .ceil()
        .clamp(1, 60000)
        .toInt();
  }

  static double titleFontSizeFor(double captionFontSize) {
    return (captionFontSize * 1.35).clamp(18.0, 64.0).toDouble();
  }

  static double titleHeightFor(double captionFontSize) {
    final titleFontSize = titleFontSizeFor(captionFontSize);
    return math.max(34.0, titleFontSize * 1.35 + 8.0);
  }

  int adaptiveHeight() {
    return heightForLayout(
      width: width,
      rows: rows,
      columns: columns,
      gap: gap,
      items: items,
      storyDescriptionEnabled: storyDescriptionEnabled,
      rowDescriptionEnabled: rowDescriptionEnabled,
      captionFontSize: captionFontSize,
      rowCaptions: rowCaptions,
      portraitMode: portraitMode,
    );
  }

  StoryboardBoard withAdaptiveHeight() {
    final nextHeight = adaptiveHeight();
    if (nextHeight == height) {
      return this;
    }
    return copyWith(height: nextHeight);
  }

  static double maxItemCaptionHeight({
    required double width,
    required double gap,
    required int columns,
    required List<StoryboardItem> items,
    required double fontSize,
  }) {
    final safeColumns = math.max(1, columns);
    final cellWidth = math.max(
      1.0,
      (width - gap * (safeColumns + 1)) / safeColumns,
    );
    final sequenceBadgeWidth =
        math.max(28.0, math.min(44.0, fontSize * 2.0)) + 6;
    final textWidth = math.max(1.0, cellWidth - 24 - sequenceBadgeWidth);
    var maxHeight = 0.0;
    for (final item in items) {
      if (item.slotIndex < 0) {
        continue;
      }
      maxHeight = math.max(
        maxHeight,
        estimatedTextBoxHeight(
          item.caption,
          width: textWidth,
          fontSize: fontSize,
        ),
      );
    }
    return maxHeight;
  }

  static double maxRowCaptionHeight({
    required double width,
    required double gap,
    required int rows,
    required List<String> rowCaptions,
    required double fontSize,
  }) {
    final textWidth = math.max(1.0, width - gap * 2 - 28);
    var maxHeight = 0.0;
    for (var rowIndex = 0; rowIndex < rows; rowIndex++) {
      final text = rowIndex < rowCaptions.length ? rowCaptions[rowIndex] : '';
      maxHeight = math.max(
        maxHeight,
        estimatedTextBoxHeight(text, width: textWidth, fontSize: fontSize),
      );
    }
    return maxHeight;
  }

  static double estimatedTextBoxHeight(
    String text, {
    required double width,
    required double fontSize,
    int minLines = 1,
  }) {
    final safeFontSize = fontSize.clamp(8.0, 96.0).toDouble();
    final safeWidth = math.max(1.0, width);
    final maxUnitsPerLine = math.max(1.0, safeWidth / (safeFontSize * 0.88));
    var lines = 0;
    final segments = text.trim().isEmpty
        ? const ['']
        : text.split(RegExp(r'\r?\n'));
    for (final segment in segments) {
      final units = _textUnits(segment);
      lines += math.max(1, (units / maxUnitsPerLine).ceil());
    }
    final safeLines = math.max(minLines, lines);
    final verticalPadding = math.max(3.0, math.min(7.0, safeFontSize * 0.35));
    final minimumFieldHeight = math.max(
      28.0,
      safeFontSize * 1.25 + verticalPadding * 2 + 6,
    );
    return math.max(minimumFieldHeight, safeLines * safeFontSize * 1.32 + 14);
  }

  static double _textUnits(String value) {
    var units = 0.0;
    for (final rune in value.runes) {
      if (rune <= 0x20) {
        units += 0.35;
      } else if (rune <= 0x007f) {
        units += 0.58;
      } else {
        units += 1.0;
      }
    }
    return units;
  }

  StoryboardBoard copyWith({
    String? id,
    String? name,
    int? width,
    int? height,
    int? rows,
    int? columns,
    double? gap,
    List<StoryboardItem>? items,
    int? configuredRows,
    int? configuredColumns,
    bool? storyDescriptionEnabled,
    bool? rowDescriptionEnabled,
    String? captionFontFamily,
    double? captionFontSize,
    List<String>? rowCaptions,
    bool? rowDividerEnabled,
    StoryboardDividerStyle? rowDividerStyle,
    double? rowDividerOpacity,
    StoryboardTitleAlignment? titleAlignment,
    bool? portraitMode,
    bool? locked,
    Object? autoGeneratedSourceImageId = _copyWithSentinel,
    Object? groupId = _copyWithSentinel,
    StoryboardSummary? summary,
    bool clearSummary = false,
  }) {
    return StoryboardBoard(
      id: id ?? this.id,
      name: name ?? this.name,
      width: width ?? this.width,
      height: height ?? this.height,
      rows: rows ?? this.rows,
      columns: columns ?? this.columns,
      gap: gap ?? this.gap,
      items: items ?? this.items,
      configuredRows: configuredRows ?? this.configuredRows,
      configuredColumns: configuredColumns ?? this.configuredColumns,
      storyDescriptionEnabled:
          storyDescriptionEnabled ?? this.storyDescriptionEnabled,
      rowDescriptionEnabled:
          rowDescriptionEnabled ?? this.rowDescriptionEnabled,
      captionFontFamily: captionFontFamily ?? this.captionFontFamily,
      captionFontSize: captionFontSize ?? this.captionFontSize,
      rowCaptions: rowCaptions ?? this.rowCaptions,
      rowDividerEnabled: rowDividerEnabled ?? this.rowDividerEnabled,
      rowDividerStyle: rowDividerStyle ?? this.rowDividerStyle,
      rowDividerOpacity: rowDividerOpacity ?? this.rowDividerOpacity,
      titleAlignment: titleAlignment ?? this.titleAlignment,
      portraitMode: portraitMode ?? this.portraitMode,
      locked: locked ?? this.locked,
      autoGeneratedSourceImageId:
          identical(autoGeneratedSourceImageId, _copyWithSentinel)
          ? this.autoGeneratedSourceImageId
          : autoGeneratedSourceImageId as String?,
      groupId: identical(groupId, _copyWithSentinel)
          ? this.groupId
          : groupId as String?,
      summary: clearSummary ? null : summary ?? this.summary,
    );
  }
}

class StoryboardSummary {
  const StoryboardSummary({
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
  });

  final String outline;
  final String content;
  final String scenes;
  final String props;

  bool get isEmpty {
    return outline.trim().isEmpty &&
        content.trim().isEmpty &&
        scenes.trim().isEmpty &&
        props.trim().isEmpty;
  }
}

enum StoryboardVisionTaskKind { analyze, reorder }

class StoryboardVisionTask {
  const StoryboardVisionTask({required this.boardId, required this.kind});

  final String boardId;
  final StoryboardVisionTaskKind kind;

  bool sameTarget(StoryboardVisionTask other) {
    return boardId == other.boardId && kind == other.kind;
  }
}

class StoryboardState {
  const StoryboardState({
    required this.assets,
    required this.folders,
    required this.resourceGroups,
    this.resourceRootOrder = const [],
    required this.boards,
    this.boardGroups = const [],
    this.openBoardIds = const [],
    required this.selectedBoardId,
    required this.message,
    required this.isAnalyzing,
    required this.isCancellingAnalysis,
    required this.isGeneratingImage,
    this.assetNormalizationRequired = false,
    this.isNormalizingAssets = false,
    this.legacyAiEditedImageCount = 0,
    this.legacyManualReplacementImageCount = 0,
    required this.reorderAnimationToken,
    this.activeVisionBoardId,
    this.activeVisionTaskKind,
    this.activeVisionTasks = const [],
    this.queuedVisionTasks = const [],
    this.generatingImageBoardIds = const [],
  });

  const StoryboardState.initial()
    : assets = const [],
      folders = const [],
      resourceGroups = const [],
      resourceRootOrder = const [],
      boards = const [],
      boardGroups = const [],
      openBoardIds = const [],
      selectedBoardId = null,
      message = '先在多宫格裁切页导出图片，然后刷新裁切资源',
      isAnalyzing = false,
      isCancellingAnalysis = false,
      isGeneratingImage = false,
      assetNormalizationRequired = false,
      isNormalizingAssets = false,
      legacyAiEditedImageCount = 0,
      legacyManualReplacementImageCount = 0,
      reorderAnimationToken = 0,
      activeVisionBoardId = null,
      activeVisionTaskKind = null,
      activeVisionTasks = const [],
      queuedVisionTasks = const [],
      generatingImageBoardIds = const [];

  final List<StoryboardCutAsset> assets;
  final List<StoryboardFolder> folders;
  final List<StoryboardResourceGroup> resourceGroups;
  final List<String> resourceRootOrder;
  final List<StoryboardBoard> boards;
  final List<StoryboardBoardGroup> boardGroups;
  final List<String> openBoardIds;
  final String? selectedBoardId;
  final String message;
  final bool isAnalyzing;
  final bool isCancellingAnalysis;
  final bool isGeneratingImage;
  final bool assetNormalizationRequired;
  final bool isNormalizingAssets;
  final int legacyAiEditedImageCount;
  final int legacyManualReplacementImageCount;
  final int reorderAnimationToken;
  final String? activeVisionBoardId;
  final StoryboardVisionTaskKind? activeVisionTaskKind;
  final List<StoryboardVisionTask> activeVisionTasks;
  final List<StoryboardVisionTask> queuedVisionTasks;
  final List<String> generatingImageBoardIds;

  List<StoryboardBoard> get openBoards {
    final byId = {for (final board in boards) board.id: board};
    return openBoardIds
        .map((boardId) => byId[boardId])
        .whereType<StoryboardBoard>()
        .toList(growable: false);
  }

  StoryboardBoard? get selectedBoard {
    for (final board in openBoards) {
      if (board.id == selectedBoardId) {
        return board;
      }
    }
    final opened = openBoards;
    return opened.isEmpty ? null : opened.first;
  }

  Set<String> get usedAssetIds {
    final board = selectedBoard;
    if (board == null) {
      return {};
    }
    return board.items.map((item) => item.asset.id).toSet();
  }

  bool isVisionTaskActiveFor(String boardId, [StoryboardVisionTaskKind? kind]) {
    return activeVisionTasks.any(
      (task) => task.boardId == boardId && (kind == null || task.kind == kind),
    );
  }

  bool isGeneratingImageFor(String boardId) {
    return generatingImageBoardIds.contains(boardId);
  }

  bool isVisionTaskQueuedFor(String boardId, [StoryboardVisionTaskKind? kind]) {
    return queuedVisionTasks.any(
      (task) => task.boardId == boardId && (kind == null || task.kind == kind),
    );
  }

  StoryboardState copyWith({
    List<StoryboardCutAsset>? assets,
    List<StoryboardFolder>? folders,
    List<StoryboardResourceGroup>? resourceGroups,
    List<String>? resourceRootOrder,
    List<StoryboardBoard>? boards,
    List<StoryboardBoardGroup>? boardGroups,
    List<String>? openBoardIds,
    Object? selectedBoardId = _copyWithSentinel,
    String? message,
    bool? isAnalyzing,
    bool? isCancellingAnalysis,
    bool? isGeneratingImage,
    bool? assetNormalizationRequired,
    bool? isNormalizingAssets,
    int? legacyAiEditedImageCount,
    int? legacyManualReplacementImageCount,
    int? reorderAnimationToken,
    Object? activeVisionBoardId = _copyWithSentinel,
    Object? activeVisionTaskKind = _copyWithSentinel,
    List<StoryboardVisionTask>? activeVisionTasks,
    List<StoryboardVisionTask>? queuedVisionTasks,
    List<String>? generatingImageBoardIds,
  }) {
    return StoryboardState(
      assets: assets ?? this.assets,
      folders: folders ?? this.folders,
      resourceGroups: resourceGroups ?? this.resourceGroups,
      resourceRootOrder: resourceRootOrder ?? this.resourceRootOrder,
      boards: boards ?? this.boards,
      boardGroups: boardGroups ?? this.boardGroups,
      openBoardIds: openBoardIds ?? this.openBoardIds,
      selectedBoardId: identical(selectedBoardId, _copyWithSentinel)
          ? this.selectedBoardId
          : selectedBoardId as String?,
      message: message ?? this.message,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      isCancellingAnalysis: isCancellingAnalysis ?? this.isCancellingAnalysis,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      assetNormalizationRequired:
          assetNormalizationRequired ?? this.assetNormalizationRequired,
      isNormalizingAssets: isNormalizingAssets ?? this.isNormalizingAssets,
      legacyAiEditedImageCount:
          legacyAiEditedImageCount ?? this.legacyAiEditedImageCount,
      legacyManualReplacementImageCount:
          legacyManualReplacementImageCount ??
          this.legacyManualReplacementImageCount,
      reorderAnimationToken:
          reorderAnimationToken ?? this.reorderAnimationToken,
      activeVisionBoardId: identical(activeVisionBoardId, _copyWithSentinel)
          ? this.activeVisionBoardId
          : activeVisionBoardId as String?,
      activeVisionTaskKind: identical(activeVisionTaskKind, _copyWithSentinel)
          ? this.activeVisionTaskKind
          : activeVisionTaskKind as StoryboardVisionTaskKind?,
      activeVisionTasks: activeVisionTasks ?? this.activeVisionTasks,
      queuedVisionTasks: queuedVisionTasks ?? this.queuedVisionTasks,
      generatingImageBoardIds:
          generatingImageBoardIds ?? this.generatingImageBoardIds,
    );
  }
}

const Object _copyWithSentinel = Object();
