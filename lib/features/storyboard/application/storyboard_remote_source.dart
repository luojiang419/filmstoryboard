import 'dart:async';
import 'dart:convert';

import '../../remote_access/domain/remote_storyboard_models.dart';
import '../domain/storyboard_models.dart';
import 'storyboard_controller.dart';

class StoryboardRemoteSource implements RemoteStoryboardSource {
  StoryboardRemoteSource(this._controller) {
    _boardSignatures = _captureBoardSignatures();
    _groupSignature = _captureGroupSignature();
    _controller.addListener(_handleControllerChanged);
  }

  final StoryboardController _controller;
  final StreamController<RemoteStoryboardSourceChange> _changes =
      StreamController<RemoteStoryboardSourceChange>.broadcast(sync: true);

  late Map<String, String> _boardSignatures;
  late String _groupSignature;
  bool _disposed = false;
  final _signatureBoards = <String, StoryboardBoard>{};

  @override
  List<RemoteStoryboardBoardRecord> get boards =>
      _controller.value.boards.map(_boardRecord).toList(growable: false);

  @override
  List<RemoteStoryboardBoardGroupRecord> get boardGroups => _controller
      .value
      .boardGroups
      .map(
        (group) =>
            RemoteStoryboardBoardGroupRecord(id: group.id, name: group.name),
      )
      .toList(growable: false);

  @override
  List<RemoteStoryboardAssetRecord> get assets => _allAssets
      .map(
        (asset) => RemoteStoryboardAssetRecord(
          id: asset.id,
          sourceName: asset.sourceName,
          indexNo: asset.indexNo,
          localPath: asset.path,
        ),
      )
      .toList(growable: false);

  @override
  Stream<RemoteStoryboardSourceChange> get changes => _changes.stream;

  @override
  RemoteStoryboardBoardRecord? boardById(String boardId) {
    for (final board in _controller.value.boards) {
      if (board.id == boardId) return _boardRecord(board);
    }
    return null;
  }

  @override
  RemoteStoryboardEditOutcome applyEdit(RemoteStoryboardEditCommand command) {
    final current = _controller.value.boards
        .cast<StoryboardBoard?>()
        .firstWhere(
          (board) => board?.id == command.boardId,
          orElse: () => null,
        );
    if (current == null) return RemoteStoryboardEditOutcome.notFound;
    if (current.locked) return RemoteStoryboardEditOutcome.locked;
    final changed = _controller.updateBoardReviewFields(
      boardId: command.boardId,
      name: command.name,
      itemCaptionsByAssetId: command.itemCaptions,
      rowCaptions: command.rowCaptions,
      summary: command.summary == null
          ? null
          : StoryboardSummary(
              outline: command.summary!.outline,
              content: command.summary!.content,
              scenes: command.summary!.scenes,
              props: command.summary!.props,
            ),
      clearSummary: command.clearSummary,
    );
    return changed
        ? RemoteStoryboardEditOutcome.updated
        : RemoteStoryboardEditOutcome.unchanged;
  }

  @override
  RemoteStoryboardEditOutcome applyLayout(
    RemoteStoryboardLayoutCommand command,
  ) {
    final current = _controller.value.boards
        .cast<StoryboardBoard?>()
        .firstWhere(
          (board) => board?.id == command.boardId,
          orElse: () => null,
        );
    if (current == null) return RemoteStoryboardEditOutcome.notFound;
    if (current.locked) return RemoteStoryboardEditOutcome.locked;
    _controller.openBoard(command.boardId);
    final before = jsonEncode(_boardSignatureJson(current));
    switch (command.action) {
      case RemoteStoryboardLayoutAction.add:
        final asset = _assetById(command.assetId);
        if (asset == null) return RemoteStoryboardEditOutcome.notFound;
        final slotIndex = command.slotIndex;
        if (slotIndex == null) {
          _controller.addOrRemoveAsset(asset);
        } else {
          _controller.placeAssetAtSlot(asset, slotIndex);
        }
      case RemoteStoryboardLayoutAction.move:
        final item = current.items.cast<StoryboardItem?>().firstWhere(
          (candidate) => candidate?.asset.id == command.assetId,
          orElse: () => null,
        );
        if (item == null) return RemoteStoryboardEditOutcome.notFound;
        _controller.moveItem(item.slotIndex, command.slotIndex!);
      case RemoteStoryboardLayoutAction.remove:
        if (!current.items.any((item) => item.asset.id == command.assetId)) {
          return RemoteStoryboardEditOutcome.notFound;
        }
        _controller.removeAsset(command.assetId);
    }
    final updated = _controller.value.boards
        .cast<StoryboardBoard?>()
        .firstWhere(
          (board) => board?.id == command.boardId,
          orElse: () => null,
        );
    if (updated == null) return RemoteStoryboardEditOutcome.notFound;
    return before == jsonEncode(_boardSignatureJson(updated))
        ? RemoteStoryboardEditOutcome.unchanged
        : RemoteStoryboardEditOutcome.updated;
  }

  StoryboardCutAsset? _assetById(String assetId) => _allAssets
      .cast<StoryboardCutAsset?>()
      .firstWhere((asset) => asset?.id == assetId, orElse: () => null);

  List<StoryboardCutAsset> get _allAssets {
    final byId = <String, StoryboardCutAsset>{
      for (final asset in _controller.value.assets) asset.id: asset,
    };
    for (final board in _controller.value.boards) {
      for (final item in board.items) {
        byId.putIfAbsent(item.asset.id, () => item.asset);
      }
    }
    return byId.values.toList(growable: false);
  }

  void _handleControllerChanged() {
    if (_disposed) return;
    final nextBoardSignatures = _captureBoardSignatures();
    final changedBoardIds =
        <String>{..._boardSignatures.keys, ...nextBoardSignatures.keys}
          ..removeWhere(
            (boardId) =>
                _boardSignatures[boardId] == nextBoardSignatures[boardId],
          );
    final nextGroupSignature = _captureGroupSignature();
    final structureChanged =
        nextGroupSignature != _groupSignature ||
        !_sameIds(_boardSignatures.keys, nextBoardSignatures.keys);
    _boardSignatures = nextBoardSignatures;
    _groupSignature = nextGroupSignature;
    if (changedBoardIds.isEmpty && !structureChanged) return;
    _changes.add(
      RemoteStoryboardSourceChange(
        boardIds: changedBoardIds,
        structureChanged: structureChanged,
      ),
    );
  }

  Map<String, String> _captureBoardSignatures() {
    final next = <String, String>{};
    for (final board in _controller.value.boards) {
      next[board.id] = identical(_signatureBoards[board.id], board)
          ? _boardSignatures[board.id]!
          : jsonEncode(_boardSignatureJson(board));
    }
    _signatureBoards
      ..clear()
      ..addEntries(
        _controller.value.boards.map((board) => MapEntry(board.id, board)),
      );
    return next;
  }

  String _captureGroupSignature() => jsonEncode([
    for (final group in _controller.value.boardGroups)
      {'id': group.id, 'name': group.name},
  ]);

  Map<String, Object?> _boardSignatureJson(StoryboardBoard board) => {
    'id': board.id,
    'name': board.name,
    'width': board.width,
    'height': board.height,
    'rows': board.rows,
    'columns': board.columns,
    'gap': board.gap,
    'storyDescriptionEnabled': board.storyDescriptionEnabled,
    'rowDescriptionEnabled': board.rowDescriptionEnabled,
    'rowCaptions': board.rowCaptions,
    'rowDividerEnabled': board.rowDividerEnabled,
    'rowDividerStyle': board.rowDividerStyle.name,
    'rowDividerOpacity': board.rowDividerOpacity,
    'titleAlignment': board.titleAlignment.name,
    'portraitMode': board.portraitMode,
    'imageAspectRatio': board.imageAspectRatio,
    'locked': board.locked,
    'groupId': board.groupId,
    'summary': board.summary == null
        ? null
        : {
            'outline': board.summary!.outline,
            'content': board.summary!.content,
            'scenes': board.summary!.scenes,
            'props': board.summary!.props,
          },
    'items': [
      for (final item in board.items)
        {
          'assetId': item.asset.id,
          'sourceName': item.asset.sourceName,
          'indexNo': item.asset.indexNo,
          'localPath': item.asset.path,
          'caption': item.caption,
          'slotIndex': item.slotIndex,
          'flipHorizontal': item.flipHorizontal,
          'flipVertical': item.flipVertical,
          'resourceRemoved': item.resourceRemoved,
        },
    ],
  };

  RemoteStoryboardBoardRecord _boardRecord(StoryboardBoard board) =>
      RemoteStoryboardBoardRecord(
        id: board.id,
        name: board.name,
        width: board.width,
        height: board.height,
        rows: board.rows,
        columns: board.columns,
        gap: board.gap,
        storyDescriptionEnabled: board.storyDescriptionEnabled,
        rowDescriptionEnabled: board.rowDescriptionEnabled,
        rowCaptions: List.unmodifiable(board.rowCaptions),
        rowDividerEnabled: board.rowDividerEnabled,
        rowDividerStyle: board.rowDividerStyle.name,
        rowDividerOpacity: board.rowDividerOpacity,
        titleAlignment: board.titleAlignment.name,
        portraitMode: board.portraitMode,
        locked: board.locked,
        groupId: board.groupId,
        summary: board.summary == null
            ? null
            : RemoteStoryboardSummaryRecord(
                outline: board.summary!.outline,
                content: board.summary!.content,
                scenes: board.summary!.scenes,
                props: board.summary!.props,
              ),
        items: board.items
            .map(
              (item) => RemoteStoryboardItemRecord(
                assetId: item.asset.id,
                sourceName: item.asset.sourceName,
                indexNo: item.asset.indexNo,
                localPath: item.asset.path,
                caption: item.caption,
                slotIndex: item.slotIndex,
                flipHorizontal: item.flipHorizontal,
                flipVertical: item.flipVertical,
                resourceRemoved: item.resourceRemoved,
              ),
            )
            .toList(growable: false),
      );

  static bool _sameIds(Iterable<String> first, Iterable<String> second) {
    final firstSet = first.toSet();
    final secondSet = second.toSet();
    return firstSet.length == secondSet.length &&
        firstSet.containsAll(secondSet);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_handleControllerChanged);
    unawaited(_changes.close());
  }
}
