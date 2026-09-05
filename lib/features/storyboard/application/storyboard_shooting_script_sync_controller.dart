import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../domain/storyboard_models.dart';
import 'storyboard_controller.dart';

/// Keeps the shared storyboard fields (image, order and caption) synchronized
/// with each storyboard's primary shooting script.
class StoryboardShootingScriptSyncController {
  StoryboardShootingScriptSyncController({
    required StoryboardController storyboardController,
    required ShootingScriptController shootingScriptController,
  }) : _storyboardController = storyboardController,
       _shootingScriptController = shootingScriptController {
    _captureBoardSignatures();
    _captureSelectedScriptSignature();
    _storyboardController.addListener(_handleStoryboardChanged);
    _shootingScriptController.addListener(_handleShootingScriptChanged);
  }

  final StoryboardController _storyboardController;
  final ShootingScriptController _shootingScriptController;
  final _boardsById = <String, StoryboardBoard>{};
  final _scriptSignatures = <String, String>{};
  var _synchronizing = false;

  void dispose() {
    _storyboardController.removeListener(_handleStoryboardChanged);
    _shootingScriptController.removeListener(_handleShootingScriptChanged);
  }

  void _handleStoryboardChanged() {
    if (_synchronizing) {
      return;
    }
    final changedBoards = [
      for (final board in _storyboardController.value.boards)
        if (!identical(_boardsById[board.id], board) &&
            (_boardsById[board.id] == null ||
                _boardSignature(_boardsById[board.id]) !=
                    _boardSignature(board)))
          (board: board, previousBoard: _boardsById[board.id]),
    ];
    final currentBoardIds = {
      for (final board in _storyboardController.value.boards) board.id,
    };
    final deletedBoardIds = _boardsById.keys
        .where((boardId) => !currentBoardIds.contains(boardId))
        .toSet();
    if (changedBoards.isEmpty && deletedBoardIds.isEmpty) {
      return;
    }
    _synchronize(() {
      _shootingScriptController.deleteVideoLinkedScriptsForStoryboards(
        deletedBoardIds,
      );
      for (final change in changedBoards) {
        if (change.previousBoard == null) {
          _shootingScriptController.createForStoryboard(change.board);
        } else {
          _shootingScriptController.syncFromStoryboard(
            change.board,
            previousBoard: change.previousBoard,
          );
        }
      }
    });
  }

  void _handleShootingScriptChanged() {
    if (_synchronizing) {
      return;
    }
    final state = _shootingScriptController.value;
    final script = state.selectedScript;
    if (script == null ||
        !_shootingScriptController.isPrimaryStoryboardScript(script)) {
      _captureSelectedScriptSignature();
      return;
    }
    final signature = _scriptSignature(state.shots);
    final previous = _scriptSignatures[script.id];
    if (previous == null) {
      _scriptSignatures[script.id] = signature;
      return;
    }
    if (previous == signature) {
      return;
    }
    _synchronize(() {
      _storyboardController.syncFromShootingScript(
        boardId: script.sourceStoryboardId!,
        shots: state.shots,
      );
    });
  }

  void _synchronize(void Function() action) {
    _synchronizing = true;
    try {
      action();
    } finally {
      _captureBoardSignatures();
      _captureSelectedScriptSignature();
      _synchronizing = false;
    }
  }

  void _captureBoardSignatures() {
    _boardsById
      ..clear()
      ..addEntries(
        _storyboardController.value.boards.map(
          (board) => MapEntry(board.id, board),
        ),
      );
  }

  void _captureSelectedScriptSignature() {
    final state = _shootingScriptController.value;
    final script = state.selectedScript;
    if (script != null) {
      _scriptSignatures[script.id] = _scriptSignature(state.shots);
    }
  }

  String _boardSignature(StoryboardBoard? board) {
    if (board == null) {
      return '';
    }
    final items = board.items.toList()
      ..sort((first, second) => first.slotIndex.compareTo(second.slotIndex));
    return items
        .map(
          (item) =>
              '${item.asset.id}\u001f${item.asset.path}\u001f${item.caption}',
        )
        .join('\u001e');
  }

  String _scriptSignature(List<ScriptShot> shots) => shots
      .where((shot) => shot.sourceStoryboardAssetId != null)
      .map(
        (shot) =>
            '${shot.sourceStoryboardAssetId}\u001f${shot.shotNumber}\u001f${shot.framePath}\u001f${shot.content}',
      )
      .join('\u001e');
}
