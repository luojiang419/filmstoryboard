import '../../shooting_script/data/shooting_script_repository.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../data/remote_storyboard_review_repository.dart';
import '../domain/remote_events.dart';
import '../domain/remote_storyboard_models.dart';
import 'remote_media_registry.dart';
import 'remote_storyboard_registry.dart';
import 'remote_workspace_registry.dart';

class RemoteOperationException implements Exception {
  const RemoteOperationException(
    this.code,
    this.message, [
    this.details = const {},
  ]);

  final String code;
  final String message;
  final Map<String, Object?> details;
}

class RemoteAccessFacade {
  const RemoteAccessFacade({
    required RemoteWorkspaceRegistry workspaceRegistry,
    required RemoteChangeBus changeBus,
    RemoteMediaRegistry? mediaRegistry,
    RemoteStoryboardRegistry? storyboardRegistry,
  }) : _workspaceRegistry = workspaceRegistry,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _storyboardRegistry = storyboardRegistry;

  static const editableShotFields = {
    'durationSeconds',
    'visual',
    'content',
    'freeCreationDescription',
    'shotSize',
    'cameraMovement',
    'cameraNotes',
    'composition',
    'cameraAngle',
    'lightingMood',
    'colorPalette',
    'visualFocus',
    'transitionHint',
    'movementTrend',
    'actionStage',
    'scene',
    'productCode',
    'productStyling',
    'dialogue',
    'sound',
    'prompt',
    'replicationInstructions',
    'generationFeedback',
  };

  static const editableStoryboardFields = {
    'name',
    'summary',
    'itemCaptions',
    'rowCaptions',
  };

  static const editableAnnotationFields = {'body', 'resolved'};

  final RemoteWorkspaceRegistry _workspaceRegistry;
  final RemoteChangeBus _changeBus;
  final RemoteMediaRegistry? _mediaRegistry;
  final RemoteStoryboardRegistry? _storyboardRegistry;

  Map<String, Object?> workspaceOverview() {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      return const {'phase': 'home', 'project': null};
    }
    final repository = ShootingScriptRepository(workspace.database);
    final scripts = repository.listScripts();
    var shotCount = 0;
    for (final script in scripts) {
      shotCount += repository.listShots(script.id).length;
    }
    final storyboardSource = _storyboardRegistry?.source;
    return {
      'phase': 'editor',
      'project': {
        'id': workspace.projectId,
        'name': workspace.projectName,
        'statistics': {
          'shootingScriptCount': scripts.length,
          'shotCount': shotCount,
          'storyboardCount': storyboardSource?.boards.length ?? 0,
        },
      },
      'eventSequence': _changeBus.lastSequence,
    };
  }

  Map<String, Object?> listScripts() {
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    return {
      'projectId': workspace.projectId,
      'items': [
        for (final script in repository.listScripts())
          _scriptSummary(
            script,
            shotCount: repository.listShots(script.id).length,
          ),
      ],
    };
  }

  Map<String, Object?> scriptDetail(String scriptId) {
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    final script = repository.getScript(scriptId);
    if (script == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本不存在');
    }
    return _scriptDetail(repository, script);
  }

  Map<String, Object?> updateShot({
    required String scriptId,
    required String shotId,
    required int expectedVersion,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的镜头字段');
    }
    final unknown = changes.keys.toSet().difference(editableShotFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许远程修改的镜头字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    final workspace = _requireWorkspace();
    final repository = ShootingScriptRepository(workspace.database);
    final script = repository.getScript(scriptId);
    if (script == null) {
      throw const RemoteOperationException('not_found', '拍摄脚本不存在');
    }
    if (script.version != expectedVersion) {
      throw RemoteOperationException('revision_conflict', '拍摄脚本已在其他位置更新', {
        'currentVersion': script.version,
      });
    }
    final shot = repository.getShot(scriptId, shotId);
    if (shot == null) {
      throw const RemoteOperationException('not_found', '脚本镜头不存在');
    }
    final now = DateTime.now().toUtc();
    final updatedShot = _applyShotChanges(shot, changes, now);
    final updatedScript = script.copyWith(
      version: script.version + 1,
      updatedAt: now,
    );
    final saved = repository.updateShotIfScriptVersion(
      updatedScript: updatedScript,
      updatedShot: updatedShot,
      expectedVersion: expectedVersion,
    );
    if (!saved) {
      final currentVersion = repository.getScript(scriptId)?.version;
      throw RemoteOperationException('revision_conflict', '拍摄脚本已在其他位置更新', {
        'currentVersion': ?currentVersion,
      });
    }
    _changeBus.publish(
      type: 'shootingScript.changed',
      projectId: workspace.projectId,
      resourceId: scriptId,
      revision: updatedScript.version,
      data: {'shotId': shotId, 'source': 'remote'},
    );
    return _scriptDetail(repository, updatedScript);
  }

  Map<String, Object?> listStoryboards() {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    _pruneAnnotations(repository, source);
    return {
      'projectId': workspace.projectId,
      'groups': [
        for (final group in source.boardGroups)
          {'id': group.id, 'name': group.name},
      ],
      'items': [
        for (final board in source.boards)
          _storyboardSummary(
            board,
            revision: _storyboardRegistry!.revisionFor(board.id),
            annotations: repository.listForBoard(board.id),
          ),
      ],
    };
  }

  Map<String, Object?> storyboardDetail(String boardId) {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    _pruneAnnotations(repository, source);
    return _storyboardDetail(
      board,
      revision: _storyboardRegistry!.revisionFor(board.id),
      annotations: repository.listForBoard(board.id),
    );
  }

  Map<String, Object?> updateStoryboard({
    required String boardId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的故事板字段');
    }
    final unknown = changes.keys.toSet().difference(editableStoryboardFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许远程修改的故事板字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final command = _storyboardEditCommand(board, changes);
    final outcome = _storyboardRegistry!.performRemoteMutation(
      (currentSource) => currentSource.applyEdit(command),
    );
    switch (outcome) {
      case RemoteStoryboardEditOutcome.updated:
      case RemoteStoryboardEditOutcome.unchanged:
        return storyboardDetail(boardId);
      case RemoteStoryboardEditOutcome.locked:
        throw const RemoteOperationException(
          'storyboard_locked',
          '故事板已锁定，请先在桌面端解锁',
        );
      case RemoteStoryboardEditOutcome.notFound:
        throw const RemoteOperationException('not_found', '故事板不存在');
    }
  }

  Map<String, Object?> addStoryboardAnnotation({
    required String boardId,
    required int expectedRevision,
    required String body,
    required String authorSessionId,
    required String authorName,
    String? assetId,
  }) {
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    final board = source.boardById(boardId);
    if (board == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final normalizedAssetId = assetId?.trim();
    if (normalizedAssetId != null &&
        normalizedAssetId.isNotEmpty &&
        !board.items.any((item) => item.assetId == normalizedAssetId)) {
      throw const RemoteOperationException('not_found', '批注目标镜头不存在');
    }
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    try {
      repository.create(
        boardId: boardId,
        assetId: normalizedAssetId?.isEmpty == true ? null : normalizedAssetId,
        body: body,
        authorSessionId: authorSessionId,
        authorName: authorName,
      );
    } on ArgumentError catch (error) {
      throw RemoteOperationException('invalid_changes', '${error.message}');
    }
    _storyboardRegistry!.publishAnnotationChanged(boardId, action: 'created');
    return storyboardDetail(boardId);
  }

  Map<String, Object?> updateStoryboardAnnotation({
    required String boardId,
    required String annotationId,
    required int expectedRevision,
    required Map<String, Object?> changes,
  }) {
    if (changes.isEmpty) {
      throw const RemoteOperationException('invalid_changes', '没有需要保存的批注字段');
    }
    final unknown = changes.keys.toSet().difference(editableAnnotationFields);
    if (unknown.isNotEmpty) {
      throw RemoteOperationException('invalid_changes', '包含不允许修改的批注字段', {
        'fields': unknown.toList()..sort(),
      });
    }
    final workspace = _requireWorkspace();
    final source = _requireStoryboardSource();
    if (source.boardById(boardId) == null) {
      throw const RemoteOperationException('not_found', '故事板不存在');
    }
    _requireStoryboardRevision(boardId, expectedRevision);
    final repository = RemoteStoryboardReviewRepository(workspace.database);
    final current = repository.getById(annotationId);
    if (current == null || current.boardId != boardId) {
      throw const RemoteOperationException('not_found', '故事板批注不存在');
    }
    final body = changes.containsKey('body') ? changes['body'] : null;
    final resolved = changes.containsKey('resolved')
        ? changes['resolved']
        : null;
    if (changes.containsKey('body') && body is! String) {
      throw const RemoteOperationException('invalid_changes', 'body 必须是文本');
    }
    if (changes.containsKey('resolved') && resolved is! bool) {
      throw const RemoteOperationException(
        'invalid_changes',
        'resolved 必须是布尔值',
      );
    }
    try {
      repository.update(
        annotationId: annotationId,
        body: body as String?,
        resolved: resolved as bool?,
      );
    } on ArgumentError catch (error) {
      throw RemoteOperationException('invalid_changes', '${error.message}');
    }
    _storyboardRegistry!.publishAnnotationChanged(boardId, action: 'updated');
    return storyboardDetail(boardId);
  }

  RemoteWorkspaceContext _requireWorkspace() {
    final workspace = _workspaceRegistry.current;
    if (workspace == null) {
      throw const RemoteOperationException(
        'workspace_unavailable',
        '桌面端当前没有打开工程',
      );
    }
    return workspace;
  }

  RemoteStoryboardSource _requireStoryboardSource() {
    final source = _storyboardRegistry?.source;
    if (source == null) {
      throw const RemoteOperationException(
        'workspace_unavailable',
        '桌面端故事板工作区尚未就绪',
      );
    }
    return source;
  }

  void _requireStoryboardRevision(String boardId, int expectedRevision) {
    final currentRevision = _storyboardRegistry!.revisionFor(boardId);
    if (currentRevision != expectedRevision) {
      throw RemoteOperationException('revision_conflict', '故事板已在其他位置更新', {
        'currentRevision': currentRevision,
      });
    }
  }

  RemoteStoryboardEditCommand _storyboardEditCommand(
    RemoteStoryboardBoardRecord board,
    Map<String, Object?> changes,
  ) {
    String? name;
    if (changes.containsKey('name')) {
      final value = changes['name'];
      if (value is! String ||
          value.trim().isEmpty ||
          value.trim().length > 200) {
        throw const RemoteOperationException(
          'invalid_changes',
          'name 必须是 1 到 200 个字符',
        );
      }
      name = value.trim();
    }

    var itemCaptions = const <String, String>{};
    if (changes.containsKey('itemCaptions')) {
      final value = changes['itemCaptions'];
      if (value is! Map) {
        throw const RemoteOperationException(
          'invalid_changes',
          'itemCaptions 必须是对象',
        );
      }
      final validAssetIds = board.items.map((item) => item.assetId).toSet();
      final parsed = <String, String>{};
      for (final entry in value.entries) {
        final assetId = '${entry.key}'.trim();
        final caption = entry.value;
        if (!validAssetIds.contains(assetId)) {
          throw RemoteOperationException(
            'invalid_changes',
            '故事板中不存在镜头 $assetId',
          );
        }
        if (caption is! String || caption.length > 60000) {
          throw const RemoteOperationException(
            'invalid_changes',
            '镜头描述必须是最多 60000 个字符的文本',
          );
        }
        parsed[assetId] = caption;
      }
      itemCaptions = parsed;
    }

    List<String>? rowCaptions;
    if (changes.containsKey('rowCaptions')) {
      final value = changes['rowCaptions'];
      if (value is! List || value.length != board.rows) {
        throw RemoteOperationException(
          'invalid_changes',
          'rowCaptions 必须包含 ${board.rows} 行文本',
        );
      }
      final parsed = <String>[];
      for (final caption in value) {
        if (caption is! String || caption.length > 60000) {
          throw const RemoteOperationException(
            'invalid_changes',
            '逐行描述必须是最多 60000 个字符的文本',
          );
        }
        parsed.add(caption);
      }
      rowCaptions = parsed;
    }

    RemoteStoryboardSummaryRecord? summary;
    var clearSummary = false;
    if (changes.containsKey('summary')) {
      final value = changes['summary'];
      if (value is! Map) {
        throw const RemoteOperationException(
          'invalid_changes',
          'summary 必须是对象',
        );
      }
      const fields = {'outline', 'content', 'scenes', 'props'};
      final unknown = value.keys
          .map((key) => '$key')
          .toSet()
          .difference(fields);
      if (unknown.isNotEmpty) {
        throw RemoteOperationException('invalid_changes', 'summary 包含未知字段', {
          'fields': unknown.toList()..sort(),
        });
      }
      String summaryText(String key) {
        final current = switch (key) {
          'outline' => board.summary?.outline ?? '',
          'content' => board.summary?.content ?? '',
          'scenes' => board.summary?.scenes ?? '',
          _ => board.summary?.props ?? '',
        };
        if (!value.containsKey(key)) return current;
        final next = value[key];
        if (next is! String || next.length > 60000) {
          throw RemoteOperationException(
            'invalid_changes',
            '$key 必须是最多 60000 个字符的文本',
          );
        }
        return next;
      }

      summary = RemoteStoryboardSummaryRecord(
        outline: summaryText('outline'),
        content: summaryText('content'),
        scenes: summaryText('scenes'),
        props: summaryText('props'),
      );
      clearSummary =
          summary.outline.trim().isEmpty &&
          summary.content.trim().isEmpty &&
          summary.scenes.trim().isEmpty &&
          summary.props.trim().isEmpty;
    }
    return RemoteStoryboardEditCommand(
      boardId: board.id,
      name: name,
      itemCaptions: itemCaptions,
      rowCaptions: rowCaptions,
      summary: clearSummary ? null : summary,
      clearSummary: clearSummary,
    );
  }

  void _pruneAnnotations(
    RemoteStoryboardReviewRepository repository,
    RemoteStoryboardSource source,
  ) {
    repository.prune(
      boardIds: source.boards.map((board) => board.id).toSet(),
      assetIdsByBoard: {
        for (final board in source.boards)
          board.id: board.items.map((item) => item.assetId).toSet(),
      },
    );
  }

  Map<String, Object?> _storyboardSummary(
    RemoteStoryboardBoardRecord board, {
    required int revision,
    required List<RemoteStoryboardAnnotation> annotations,
  }) => {
    'id': board.id,
    'name': board.name,
    'groupId': board.groupId,
    'revision': revision,
    'locked': board.locked,
    'rows': board.rows,
    'columns': board.columns,
    'itemCount': board.items.length,
    'annotationCount': annotations.length,
    'unresolvedAnnotationCount': annotations
        .where((annotation) => !annotation.resolved)
        .length,
  };

  Map<String, Object?> _storyboardDetail(
    RemoteStoryboardBoardRecord board, {
    required int revision,
    required List<RemoteStoryboardAnnotation> annotations,
  }) => {
    ..._storyboardSummary(board, revision: revision, annotations: annotations),
    'width': board.width,
    'height': board.height,
    'gap': board.gap,
    'storyDescriptionEnabled': board.storyDescriptionEnabled,
    'rowDescriptionEnabled': board.rowDescriptionEnabled,
    'rowCaptions': board.rowCaptions,
    'rowDividerEnabled': board.rowDividerEnabled,
    'rowDividerStyle': board.rowDividerStyle,
    'rowDividerOpacity': board.rowDividerOpacity,
    'titleAlignment': board.titleAlignment,
    'portraitMode': board.portraitMode,
    'summary': board.summary == null
        ? null
        : {
            'outline': board.summary!.outline,
            'content': board.summary!.content,
            'scenes': board.summary!.scenes,
            'props': board.summary!.props,
          },
    'items': [for (final item in board.items) _storyboardItemJson(item)],
    'annotations': [
      for (final annotation in annotations) _annotationJson(annotation),
    ],
  };

  Map<String, Object?> _storyboardItemJson(RemoteStoryboardItemRecord item) {
    final mediaId = _mediaRegistry?.registerProjectFile(item.localPath);
    return {
      'assetId': item.assetId,
      'sourceName': item.sourceName,
      'indexNo': item.indexNo,
      'caption': item.caption,
      'slotIndex': item.slotIndex,
      'flipHorizontal': item.flipHorizontal,
      'flipVertical': item.flipVertical,
      'resourceRemoved': item.resourceRemoved,
      'imageRemotelyAvailable': mediaId != null,
      'imageMediaId': ?mediaId,
    };
  }

  Map<String, Object?> _annotationJson(RemoteStoryboardAnnotation annotation) =>
      {
        'id': annotation.id,
        'assetId': annotation.assetId,
        'body': annotation.body,
        'authorName': annotation.authorName,
        'createdAt': annotation.createdAt.toUtc().toIso8601String(),
        'updatedAt': annotation.updatedAt.toUtc().toIso8601String(),
        'resolved': annotation.resolved,
      };

  ScriptShot _applyShotChanges(
    ScriptShot shot,
    Map<String, Object?> changes,
    DateTime now,
  ) {
    String text(String key, String current) {
      if (!changes.containsKey(key)) return current;
      final value = changes[key];
      if (value is! String) {
        throw RemoteOperationException('invalid_changes', '$key 必须是文本');
      }
      if (value.length > 60000) {
        throw RemoteOperationException('invalid_changes', '$key 超过 60000 个字符');
      }
      return value;
    }

    double duration() {
      if (!changes.containsKey('durationSeconds')) return shot.durationSeconds;
      final value = changes['durationSeconds'];
      if (value is! num || !value.isFinite || value < 0 || value > 3600) {
        throw const RemoteOperationException(
          'invalid_changes',
          'durationSeconds 必须是 0 到 3600 之间的数字',
        );
      }
      return value.toDouble();
    }

    return shot.copyWith(
      durationSeconds: duration(),
      visual: text('visual', shot.visual),
      content: text('content', shot.content),
      freeCreationDescription: text(
        'freeCreationDescription',
        shot.freeCreationDescription,
      ),
      shotSize: text('shotSize', shot.shotSize),
      cameraMovement: text('cameraMovement', shot.cameraMovement),
      cameraNotes: text('cameraNotes', shot.cameraNotes),
      composition: text('composition', shot.composition),
      cameraAngle: text('cameraAngle', shot.cameraAngle),
      lightingMood: text('lightingMood', shot.lightingMood),
      colorPalette: text('colorPalette', shot.colorPalette),
      visualFocus: text('visualFocus', shot.visualFocus),
      transitionHint: text('transitionHint', shot.transitionHint),
      movementTrend: text('movementTrend', shot.movementTrend),
      actionStage: text('actionStage', shot.actionStage),
      scene: text('scene', shot.scene),
      productCode: text('productCode', shot.productCode),
      productStyling: text('productStyling', shot.productStyling),
      dialogue: text('dialogue', shot.dialogue),
      sound: text('sound', shot.sound),
      prompt: text('prompt', shot.prompt),
      replicationInstructions: text(
        'replicationInstructions',
        shot.replicationInstructions,
      ),
      generationFeedback: text('generationFeedback', shot.generationFeedback),
      updatedAt: now,
    );
  }

  Map<String, Object?> _scriptDetail(
    ShootingScriptRepository repository,
    ShootingScript script,
  ) => {
    ..._scriptSummary(
      script,
      shotCount: repository.listShots(script.id).length,
    ),
    'shots': [
      for (final shot in repository.listShots(script.id)) _shotJson(shot),
    ],
  };

  Map<String, Object?> _scriptSummary(
    ShootingScript script, {
    required int shotCount,
  }) => {
    'id': script.id,
    'name': script.name,
    'status': script.status.name,
    'version': script.version,
    'shotCount': shotCount,
    'updatedAt': script.updatedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> _shotJson(ScriptShot shot) {
    final mediaId = _mediaRegistry?.registerProjectFile(shot.framePath);
    return {
      'id': shot.id,
      'shotNumber': shot.shotNumber,
      'durationSeconds': shot.durationSeconds,
      'frameAvailable': shot.framePath.trim().isNotEmpty,
      'frameRemotelyAvailable': mediaId != null,
      'frameMediaId': ?mediaId,
      'visual': shot.visual,
      'content': shot.content,
      'freeCreationDescription': shot.freeCreationDescription,
      'shotSize': shot.shotSize,
      'cameraMovement': shot.cameraMovement,
      'cameraNotes': shot.cameraNotes,
      'composition': shot.composition,
      'cameraAngle': shot.cameraAngle,
      'lightingMood': shot.lightingMood,
      'colorPalette': shot.colorPalette,
      'visualFocus': shot.visualFocus,
      'transitionHint': shot.transitionHint,
      'movementTrend': shot.movementTrend,
      'actionStage': shot.actionStage,
      'continuesFromPrevious': shot.continuesFromPrevious,
      'continuesToNext': shot.continuesToNext,
      'scene': shot.scene,
      'productCode': shot.productCode,
      'productStyling': shot.productStyling,
      'dialogue': shot.dialogue,
      'sound': shot.sound,
      'prompt': shot.prompt,
      'replicationInstructions': shot.replicationInstructions,
      'generationFeedback': shot.generationFeedback,
      'status': shot.status.name,
      'updatedAt': shot.updatedAt.toUtc().toIso8601String(),
    };
  }
}
