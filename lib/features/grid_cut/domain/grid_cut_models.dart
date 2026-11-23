import 'dart:math' as math;

class GridLayout {
  const GridLayout({
    required this.imageWidth,
    required this.imageHeight,
    required this.xLines,
    required this.yLines,
    required this.confidence,
    required this.usedFallback,
  });

  static const int minLineGap = 8;

  final int imageWidth;
  final int imageHeight;
  final List<int> xLines;
  final List<int> yLines;
  final double confidence;
  final bool usedFallback;

  int get columns => math.max(0, xLines.length - 1);
  int get rows => math.max(0, yLines.length - 1);
  int get cellCount => rows * columns;

  GridLayout copyWith({
    List<int>? xLines,
    List<int>? yLines,
    double? confidence,
    bool? usedFallback,
  }) {
    return GridLayout(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      xLines: xLines ?? this.xLines,
      yLines: yLines ?? this.yLines,
      confidence: confidence ?? this.confidence,
      usedFallback: usedFallback ?? this.usedFallback,
    );
  }

  GridLayout insertVerticalLine(int imageX) {
    final lines = _insertLine(xLines, imageX, imageWidth);
    if (identical(lines, xLines)) {
      return this;
    }
    return copyWith(xLines: lines, usedFallback: true);
  }

  GridLayout insertHorizontalLine(int imageY) {
    final lines = _insertLine(yLines, imageY, imageHeight);
    if (identical(lines, yLines)) {
      return this;
    }
    return copyWith(yLines: lines, usedFallback: true);
  }

  GridLayout removeVerticalLine(int lineIndex) {
    final lines = _removeLine(xLines, lineIndex);
    if (identical(lines, xLines)) {
      return this;
    }
    return copyWith(xLines: lines, usedFallback: true);
  }

  GridLayout removeHorizontalLine(int lineIndex) {
    final lines = _removeLine(yLines, lineIndex);
    if (identical(lines, yLines)) {
      return this;
    }
    return copyWith(yLines: lines, usedFallback: true);
  }

  GridLayout moveVerticalLine(int lineIndex, int imageX) {
    return moveVerticalLineWithIndex(lineIndex, imageX).layout;
  }

  GridLineMoveResult moveVerticalLineWithIndex(int lineIndex, int imageX) {
    final result = _moveLine(xLines, lineIndex, imageX, imageWidth);
    if (identical(result.lines, xLines)) {
      return GridLineMoveResult(layout: this, lineIndex: result.lineIndex);
    }
    return GridLineMoveResult(
      layout: copyWith(xLines: result.lines, usedFallback: true),
      lineIndex: result.lineIndex,
    );
  }

  GridLayout moveHorizontalLine(int lineIndex, int imageY) {
    return moveHorizontalLineWithIndex(lineIndex, imageY).layout;
  }

  GridLineMoveResult moveHorizontalLineWithIndex(int lineIndex, int imageY) {
    final result = _moveLine(yLines, lineIndex, imageY, imageHeight);
    if (identical(result.lines, yLines)) {
      return GridLineMoveResult(layout: this, lineIndex: result.lineIndex);
    }
    return GridLineMoveResult(
      layout: copyWith(yLines: result.lines, usedFallback: true),
      lineIndex: result.lineIndex,
    );
  }

  GridCell cellAt(int index) {
    final row = index ~/ columns;
    final column = index % columns;
    return GridCell(
      index: index,
      row: row,
      column: column,
      x: xLines[column],
      y: yLines[row],
      width: xLines[column + 1] - xLines[column],
      height: yLines[row + 1] - yLines[row],
    );
  }

  List<GridCell> cells() {
    return [for (var i = 0; i < cellCount; i++) cellAt(i)];
  }

  static List<int> _insertLine(List<int> source, int value, int maxValue) {
    final sorted =
        source.map((line) => line.clamp(0, maxValue)).toSet().toList()..sort();
    if (sorted.contains(value)) {
      return source;
    }

    var nextIndex = sorted.indexWhere((line) => line > value);
    if (nextIndex == -1) {
      nextIndex = sorted.length - 1;
    }
    final previousIndex = (nextIndex - 1).clamp(0, sorted.length - 1);
    final previous = sorted[previousIndex];
    final next = sorted[nextIndex];
    if (next - previous < minLineGap * 2) {
      return source;
    }

    final inserted = value.clamp(previous + minLineGap, next - minLineGap);
    if (sorted.contains(inserted)) {
      return source;
    }
    sorted.insert(nextIndex, inserted);
    return sorted;
  }

  static List<int> _removeLine(List<int> source, int lineIndex) {
    if (lineIndex <= 0 || lineIndex >= source.length - 1) {
      return source;
    }
    return [...source]..removeAt(lineIndex);
  }

  static _LineMoveResult _moveLine(
    List<int> source,
    int lineIndex,
    int value,
    int maxValue,
  ) {
    if (lineIndex <= 0 || lineIndex >= source.length - 1) {
      return _LineMoveResult(source, lineIndex);
    }

    final sorted = [...source]..removeAt(lineIndex);
    sorted
      ..replaceRange(
        0,
        sorted.length,
        sorted.map((line) => line.clamp(0, maxValue).toInt()).toSet(),
      )
      ..sort();
    if (sorted.length < 2) {
      return _LineMoveResult(source, lineIndex);
    }

    final target = value.clamp(0, maxValue).toInt();
    int? moved;
    var bestDistance = maxValue + minLineGap;
    for (var i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i] + minLineGap;
      final end = sorted[i + 1] - minLineGap;
      if (start > end) {
        continue;
      }
      final candidate = target.clamp(start, end).toInt();
      final distance = (candidate - target).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        moved = candidate;
      }
    }
    if (moved == null || sorted.contains(moved)) {
      return _LineMoveResult(source, lineIndex);
    }

    var insertIndex = sorted.indexWhere((line) => line > moved!);
    if (insertIndex == -1) {
      insertIndex = sorted.length;
    }
    sorted.insert(insertIndex, moved);
    if (_sameLines(sorted, source)) {
      return _LineMoveResult(source, lineIndex);
    }
    return _LineMoveResult(sorted, insertIndex);
  }

  static bool _sameLines(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

class GridLineMoveResult {
  const GridLineMoveResult({required this.layout, required this.lineIndex});

  final GridLayout layout;
  final int lineIndex;
}

class _LineMoveResult {
  const _LineMoveResult(this.lines, this.lineIndex);

  final List<int> lines;
  final int lineIndex;
}

class GridCell {
  const GridCell({
    required this.index,
    required this.row,
    required this.column,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int index;
  final int row;
  final int column;
  final int x;
  final int y;
  final int width;
  final int height;
}

class GridCutImage {
  const GridCutImage({
    required this.id,
    required this.taskId,
    required this.originalPath,
    required this.originalName,
    required this.storedPath,
    required this.layout,
    required this.selectedCells,
    required this.exportedPaths,
    required this.createdAt,
  });

  final String id;
  final String taskId;
  final String originalPath;
  final String originalName;
  final String storedPath;
  final GridLayout layout;
  final Set<int> selectedCells;
  final List<String> exportedPaths;
  final DateTime createdAt;

  String get baseName {
    final dot = originalName.lastIndexOf('.');
    return dot <= 0 ? originalName : originalName.substring(0, dot);
  }

  GridCutImage copyWith({
    GridLayout? layout,
    Set<int>? selectedCells,
    List<String>? exportedPaths,
  }) {
    return GridCutImage(
      id: id,
      taskId: taskId,
      originalPath: originalPath,
      originalName: originalName,
      storedPath: storedPath,
      layout: layout ?? this.layout,
      selectedCells: selectedCells ?? this.selectedCells,
      exportedPaths: exportedPaths ?? this.exportedPaths,
      createdAt: createdAt,
    );
  }
}

class GridCutTaskGroup {
  const GridCutTaskGroup({
    required this.id,
    required this.name,
    required this.imageIds,
    this.expanded = true,
  });

  final String id;
  final String name;
  final List<String> imageIds;
  final bool expanded;

  GridCutTaskGroup copyWith({
    String? name,
    List<String>? imageIds,
    bool? expanded,
  }) {
    return GridCutTaskGroup(
      id: id,
      name: name ?? this.name,
      imageIds: imageIds ?? this.imageIds,
      expanded: expanded ?? this.expanded,
    );
  }
}

enum GridCutTaskNodeKind { group, image }

class GridCutTaskNodeRef {
  const GridCutTaskNodeRef({required this.kind, required this.id});

  const GridCutTaskNodeRef.group(String id)
    : this(kind: GridCutTaskNodeKind.group, id: id);

  const GridCutTaskNodeRef.image(String id)
    : this(kind: GridCutTaskNodeKind.image, id: id);

  final GridCutTaskNodeKind kind;
  final String id;

  String get key => '${kind.name}:$id';

  static GridCutTaskNodeRef? tryParse(String value) {
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      return null;
    }
    final kindName = value.substring(0, separator);
    final id = value.substring(separator + 1);
    for (final kind in GridCutTaskNodeKind.values) {
      if (kind.name == kindName) {
        return GridCutTaskNodeRef(kind: kind, id: id);
      }
    }
    return null;
  }
}

class GridCutState {
  const GridCutState({
    required this.images,
    required this.taskGroups,
    this.taskOrder = const [],
    required this.selectedImageId,
    required this.isBusy,
    required this.message,
    required this.isDraggingOver,
  });

  const GridCutState.initial()
    : images = const [],
      taskGroups = const [],
      taskOrder = const [],
      selectedImageId = null,
      isBusy = false,
      message = '拖拽、手动添加或粘贴图片开始裁切',
      isDraggingOver = false;

  final List<GridCutImage> images;
  final List<GridCutTaskGroup> taskGroups;
  final List<String> taskOrder;
  final String? selectedImageId;
  final bool isBusy;
  final String message;
  final bool isDraggingOver;

  GridCutImage? get selectedImage {
    for (final image in images) {
      if (image.id == selectedImageId) {
        return image;
      }
    }
    return images.isEmpty ? null : images.first;
  }

  GridCutState copyWith({
    List<GridCutImage>? images,
    List<GridCutTaskGroup>? taskGroups,
    List<String>? taskOrder,
    String? selectedImageId,
    bool clearSelectedImageId = false,
    bool? isBusy,
    String? message,
    bool? isDraggingOver,
  }) {
    return GridCutState(
      images: images ?? this.images,
      taskGroups: taskGroups ?? this.taskGroups,
      taskOrder: taskOrder ?? this.taskOrder,
      selectedImageId: clearSelectedImageId
          ? null
          : selectedImageId ?? this.selectedImageId,
      isBusy: isBusy ?? this.isBusy,
      message: message ?? this.message,
      isDraggingOver: isDraggingOver ?? this.isDraggingOver,
    );
  }
}
