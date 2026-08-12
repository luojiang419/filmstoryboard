import 'dart:typed_data';

class RemotePairResult {
  const RemotePairResult({required this.session});

  final RemoteSession session;

  factory RemotePairResult.fromJson(Map<String, Object?> json) =>
      RemotePairResult(session: RemoteSession.fromJson(_map(json['session'])));
}

class RemoteSession {
  const RemoteSession({
    required this.id,
    required this.clientName,
    required this.role,
    required this.expiresAt,
  });

  final String id;
  final String clientName;
  final String role;
  final DateTime? expiresAt;

  factory RemoteSession.fromJson(Map<String, Object?> json) => RemoteSession(
    id: _text(json['id']),
    clientName: _text(json['clientName']),
    role: _text(json['role']),
    expiresAt: DateTime.tryParse(_text(json['expiresAt'])),
  );
}

class RemoteProjectEntry {
  const RemoteProjectEntry({
    required this.id,
    required this.name,
    required this.availability,
    required this.canOpen,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOpenedAt,
  });

  final String id;
  final String name;
  final String availability;
  final bool canOpen;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastOpenedAt;

  factory RemoteProjectEntry.fromJson(Map<String, Object?> json) =>
      RemoteProjectEntry(
        id: _text(json['id']),
        name: _text(json['name']),
        availability: _text(json['availability']),
        canOpen: json['canOpen'] == true,
        isActive: json['isActive'] == true,
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
        updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
        lastOpenedAt: DateTime.tryParse(_text(json['lastOpenedAt'])),
      );
}

class RemoteWorkspace {
  const RemoteWorkspace({
    required this.phase,
    this.project,
    this.eventSequence = 0,
  });

  final String phase;
  final RemoteProject? project;
  final int eventSequence;

  factory RemoteWorkspace.fromJson(Map<String, Object?> json) =>
      RemoteWorkspace(
        phase: _text(json['phase']),
        project: json['project'] is Map
            ? RemoteProject.fromJson(_map(json['project']))
            : null,
        eventSequence: _integer(json['eventSequence']),
      );
}

class RemoteProject {
  const RemoteProject({
    required this.id,
    required this.name,
    required this.storyboardCount,
    required this.scriptCount,
    required this.shotCount,
  });

  final String id;
  final String name;
  final int storyboardCount;
  final int scriptCount;
  final int shotCount;

  factory RemoteProject.fromJson(Map<String, Object?> json) {
    final statistics = _map(json['statistics']);
    return RemoteProject(
      id: _text(json['id']),
      name: _text(json['name']),
      storyboardCount: _integer(statistics['storyboardCount']),
      scriptCount: _integer(statistics['shootingScriptCount']),
      shotCount: _integer(statistics['shotCount']),
    );
  }
}

class RemoteStoryboardGroup {
  const RemoteStoryboardGroup({required this.id, required this.name});

  final String id;
  final String name;

  factory RemoteStoryboardGroup.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardGroup(id: _text(json['id']), name: _text(json['name']));
}

class RemoteStoryboardSummary {
  const RemoteStoryboardSummary({
    required this.id,
    required this.name,
    required this.groupId,
    required this.revision,
    required this.locked,
    required this.rows,
    required this.columns,
    required this.itemCount,
    required this.annotationCount,
    required this.unresolvedAnnotationCount,
  });

  final String id;
  final String name;
  final String? groupId;
  final int revision;
  final bool locked;
  final int rows;
  final int columns;
  final int itemCount;
  final int annotationCount;
  final int unresolvedAnnotationCount;

  factory RemoteStoryboardSummary.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardSummary(
        id: _text(json['id']),
        name: _text(json['name']),
        groupId: _nullableText(json['groupId']),
        revision: _integer(json['revision']),
        locked: json['locked'] == true,
        rows: _integer(json['rows']),
        columns: _integer(json['columns']),
        itemCount: _integer(json['itemCount']),
        annotationCount: _integer(json['annotationCount']),
        unresolvedAnnotationCount: _integer(json['unresolvedAnnotationCount']),
      );
}

class RemoteStoryboardDetail extends RemoteStoryboardSummary {
  const RemoteStoryboardDetail({
    required super.id,
    required super.name,
    required super.groupId,
    required super.revision,
    required super.locked,
    required super.rows,
    required super.columns,
    required super.itemCount,
    required super.annotationCount,
    required super.unresolvedAnnotationCount,
    required this.width,
    required this.height,
    required this.gap,
    required this.storyDescriptionEnabled,
    required this.rowDescriptionEnabled,
    required this.rowCaptions,
    required this.rowDividerEnabled,
    required this.rowDividerStyle,
    required this.rowDividerOpacity,
    required this.titleAlignment,
    required this.portraitMode,
    required this.storySummary,
    required this.items,
    required this.annotations,
  });

  final int width;
  final int height;
  final double gap;
  final bool storyDescriptionEnabled;
  final bool rowDescriptionEnabled;
  final List<String> rowCaptions;
  final bool rowDividerEnabled;
  final String rowDividerStyle;
  final double rowDividerOpacity;
  final String titleAlignment;
  final bool portraitMode;
  final RemoteStoryboardStorySummary? storySummary;
  final List<RemoteStoryboardItem> items;
  final List<RemoteStoryboardAnnotation> annotations;

  factory RemoteStoryboardDetail.fromJson(Map<String, Object?> json) {
    final summary = RemoteStoryboardSummary.fromJson(json);
    return RemoteStoryboardDetail(
      id: summary.id,
      name: summary.name,
      groupId: summary.groupId,
      revision: summary.revision,
      locked: summary.locked,
      rows: summary.rows,
      columns: summary.columns,
      itemCount: summary.itemCount,
      annotationCount: summary.annotationCount,
      unresolvedAnnotationCount: summary.unresolvedAnnotationCount,
      width: _integer(json['width']),
      height: _integer(json['height']),
      gap: _number(json['gap']),
      storyDescriptionEnabled: json['storyDescriptionEnabled'] == true,
      rowDescriptionEnabled: json['rowDescriptionEnabled'] == true,
      rowCaptions: _list(
        json['rowCaptions'],
      ).map(_text).toList(growable: false),
      rowDividerEnabled: json['rowDividerEnabled'] == true,
      rowDividerStyle: _text(json['rowDividerStyle']),
      rowDividerOpacity: _number(json['rowDividerOpacity']),
      titleAlignment: _text(json['titleAlignment']),
      portraitMode: json['portraitMode'] == true,
      storySummary: json['summary'] is Map
          ? RemoteStoryboardStorySummary.fromJson(_map(json['summary']))
          : null,
      items: _list(json['items'])
          .map((item) => RemoteStoryboardItem.fromJson(_map(item)))
          .toList(growable: false),
      annotations: _list(json['annotations'])
          .map((item) => RemoteStoryboardAnnotation.fromJson(_map(item)))
          .toList(growable: false),
    );
  }
}

class RemoteStoryboardStorySummary {
  const RemoteStoryboardStorySummary({
    required this.outline,
    required this.content,
    required this.scenes,
    required this.props,
  });

  final String outline;
  final String content;
  final String scenes;
  final String props;

  factory RemoteStoryboardStorySummary.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardStorySummary(
        outline: _text(json['outline']),
        content: _text(json['content']),
        scenes: _text(json['scenes']),
        props: _text(json['props']),
      );
}

class RemoteStoryboardItem {
  const RemoteStoryboardItem({
    required this.assetId,
    required this.sourceName,
    required this.indexNo,
    required this.caption,
    required this.slotIndex,
    required this.flipHorizontal,
    required this.flipVertical,
    required this.resourceRemoved,
    required this.imageMediaId,
  });

  final String assetId;
  final String sourceName;
  final int indexNo;
  final String caption;
  final int slotIndex;
  final bool flipHorizontal;
  final bool flipVertical;
  final bool resourceRemoved;
  final String? imageMediaId;

  factory RemoteStoryboardItem.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardItem(
        assetId: _text(json['assetId']),
        sourceName: _text(json['sourceName']),
        indexNo: _integer(json['indexNo']),
        caption: _text(json['caption']),
        slotIndex: _integer(json['slotIndex']),
        flipHorizontal: json['flipHorizontal'] == true,
        flipVertical: json['flipVertical'] == true,
        resourceRemoved: json['resourceRemoved'] == true,
        imageMediaId: _nullableText(json['imageMediaId']),
      );
}

class RemoteStoryboardAsset {
  const RemoteStoryboardAsset({
    required this.id,
    required this.sourceName,
    required this.indexNo,
    required this.used,
    required this.imageMediaId,
  });

  final String id;
  final String sourceName;
  final int indexNo;
  final bool used;
  final String? imageMediaId;

  factory RemoteStoryboardAsset.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardAsset(
        id: _text(json['id']),
        sourceName: _text(json['sourceName']),
        indexNo: _integer(json['indexNo']),
        used: json['used'] == true,
        imageMediaId: _nullableText(json['imageMediaId']),
      );
}

class RemoteStoryboardAnnotation {
  const RemoteStoryboardAnnotation({
    required this.id,
    required this.assetId,
    required this.body,
    required this.authorName,
    required this.createdAt,
    required this.updatedAt,
    required this.resolved,
  });

  final String id;
  final String? assetId;
  final String body;
  final String authorName;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool resolved;

  factory RemoteStoryboardAnnotation.fromJson(Map<String, Object?> json) =>
      RemoteStoryboardAnnotation(
        id: _text(json['id']),
        assetId: _nullableText(json['assetId']),
        body: _text(json['body']),
        authorName: _text(json['authorName']),
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
        updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
        resolved: json['resolved'] == true,
      );
}

class RemoteScriptSummary {
  const RemoteScriptSummary({
    required this.id,
    required this.name,
    required this.status,
    required this.version,
    required this.shotCount,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String status;
  final int version;
  final int shotCount;
  final DateTime? updatedAt;

  factory RemoteScriptSummary.fromJson(Map<String, Object?> json) =>
      RemoteScriptSummary(
        id: _text(json['id']),
        name: _text(json['name']),
        status: _text(json['status']),
        version: _integer(json['version']),
        shotCount: _integer(json['shotCount']),
        updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
      );
}

class RemoteScriptDetail extends RemoteScriptSummary {
  const RemoteScriptDetail({
    required super.id,
    required super.name,
    required super.status,
    required super.version,
    required super.shotCount,
    required super.updatedAt,
    required this.shots,
  });

  final List<RemoteShot> shots;

  factory RemoteScriptDetail.fromJson(Map<String, Object?> json) {
    final summary = RemoteScriptSummary.fromJson(json);
    return RemoteScriptDetail(
      id: summary.id,
      name: summary.name,
      status: summary.status,
      version: summary.version,
      shotCount: summary.shotCount,
      updatedAt: summary.updatedAt,
      shots: _list(
        json['shots'],
      ).map((item) => RemoteShot.fromJson(_map(item))).toList(growable: false),
    );
  }
}

class RemoteShootingWorkflow {
  const RemoteShootingWorkflow({
    required this.scriptId,
    required this.currentStep,
    required this.confirmShotsStatus,
    required this.prepareAssetsStatus,
    required this.composePromptsStatus,
    required this.shotCount,
    required this.confirmedShotCount,
    required this.promptCount,
    required this.analysisCompleted,
    required this.analysisFailed,
    required this.analysisTotal,
    required this.isBusy,
    required this.message,
    required this.errorMessage,
    required this.assets,
    required this.links,
    required this.replicas,
  });

  final String scriptId;
  final String currentStep;
  final String confirmShotsStatus;
  final String prepareAssetsStatus;
  final String composePromptsStatus;
  final int shotCount;
  final int confirmedShotCount;
  final int promptCount;
  final int analysisCompleted;
  final int analysisFailed;
  final int analysisTotal;
  final bool isBusy;
  final String message;
  final String errorMessage;
  final List<RemoteShootingWorkflowAsset> assets;
  final List<RemoteShootingWorkflowLink> links;
  final List<RemoteShootingWorkflowReplica> replicas;

  factory RemoteShootingWorkflow.fromJson(Map<String, Object?> json) {
    final statuses = _map(json['statuses']);
    final progress = _map(json['analysisProgress']);
    return RemoteShootingWorkflow(
      scriptId: _text(json['scriptId']),
      currentStep: _text(json['currentStep']),
      confirmShotsStatus: _text(statuses['confirmShots']),
      prepareAssetsStatus: _text(statuses['prepareAssets']),
      composePromptsStatus: _text(statuses['composePrompts']),
      shotCount: _integer(json['shotCount']),
      confirmedShotCount: _integer(json['confirmedShotCount']),
      promptCount: _integer(json['promptCount']),
      analysisCompleted: _integer(progress['completed']),
      analysisFailed: _integer(progress['failed']),
      analysisTotal: _integer(progress['total']),
      isBusy: json['isBusy'] == true,
      message: _text(json['message']),
      errorMessage: _text(json['errorMessage']),
      assets: _list(json['assets'])
          .map((item) => RemoteShootingWorkflowAsset.fromJson(_map(item)))
          .toList(growable: false),
      links: _list(json['links'])
          .map((item) => RemoteShootingWorkflowLink.fromJson(_map(item)))
          .toList(growable: false),
      replicas: _list(json['replicas'])
          .map((item) => RemoteShootingWorkflowReplica.fromJson(_map(item)))
          .toList(growable: false),
    );
  }
}

class RemoteShootingWorkflowAsset {
  const RemoteShootingWorkflowAsset({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    required this.referenceNumber,
    required this.mediaId,
  });

  final String id;
  final String name;
  final String type;
  final String description;
  final int referenceNumber;
  final String? mediaId;

  factory RemoteShootingWorkflowAsset.fromJson(Map<String, Object?> json) =>
      RemoteShootingWorkflowAsset(
        id: _text(json['id']),
        name: _text(json['name']),
        type: _text(json['type']),
        description: _text(json['description']),
        referenceNumber: _integer(json['referenceNumber']),
        mediaId: _nullableText(json['mediaId']),
      );
}

class RemoteShootingWorkflowLink {
  const RemoteShootingWorkflowLink({
    required this.shotId,
    required this.assetId,
    required this.matchSource,
    required this.confidence,
    required this.matchReason,
    required this.confirmed,
    required this.locked,
  });

  final String shotId;
  final String assetId;
  final String matchSource;
  final double confidence;
  final String matchReason;
  final bool confirmed;
  final bool locked;

  factory RemoteShootingWorkflowLink.fromJson(Map<String, Object?> json) =>
      RemoteShootingWorkflowLink(
        shotId: _text(json['shotId']),
        assetId: _text(json['assetId']),
        matchSource: _text(json['matchSource']),
        confidence: _number(json['confidence']),
        matchReason: _text(json['matchReason']),
        confirmed: json['confirmed'] == true,
        locked: json['locked'] == true,
      );
}

class RemoteShootingWorkflowReplica {
  const RemoteShootingWorkflowReplica({
    required this.shotId,
    required this.status,
    required this.errorMessage,
    required this.mediaId,
  });

  final String shotId;
  final String status;
  final String errorMessage;
  final String? mediaId;

  factory RemoteShootingWorkflowReplica.fromJson(Map<String, Object?> json) =>
      RemoteShootingWorkflowReplica(
        shotId: _text(json['shotId']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
        mediaId: _nullableText(json['mediaId']),
      );
}

class RemoteShot {
  const RemoteShot({
    required this.id,
    required this.shotNumber,
    required this.durationSeconds,
    required this.frameMediaId,
    required this.content,
    required this.visual,
    required this.shotSize,
    required this.cameraMovement,
    required this.composition,
    required this.cameraAngle,
    required this.lightingMood,
    required this.colorPalette,
    required this.scene,
    required this.dialogue,
    required this.sound,
    required this.prompt,
    required this.generationFeedback,
    required this.status,
    required this.continuesFromPrevious,
    required this.continuesToNext,
  });

  final String id;
  final int shotNumber;
  final double durationSeconds;
  final String? frameMediaId;
  final String content;
  final String visual;
  final String shotSize;
  final String cameraMovement;
  final String composition;
  final String cameraAngle;
  final String lightingMood;
  final String colorPalette;
  final String scene;
  final String dialogue;
  final String sound;
  final String prompt;
  final String generationFeedback;
  final String status;
  final bool continuesFromPrevious;
  final bool continuesToNext;

  factory RemoteShot.fromJson(Map<String, Object?> json) => RemoteShot(
    id: _text(json['id']),
    shotNumber: _integer(json['shotNumber']),
    durationSeconds: _number(json['durationSeconds']),
    frameMediaId: switch (_text(json['frameMediaId'])) {
      final value when value.isNotEmpty => value,
      _ => null,
    },
    content: _text(json['content']),
    visual: _text(json['visual']),
    shotSize: _text(json['shotSize']),
    cameraMovement: _text(json['cameraMovement']),
    composition: _text(json['composition']),
    cameraAngle: _text(json['cameraAngle']),
    lightingMood: _text(json['lightingMood']),
    colorPalette: _text(json['colorPalette']),
    scene: _text(json['scene']),
    dialogue: _text(json['dialogue']),
    sound: _text(json['sound']),
    prompt: _text(json['prompt']),
    generationFeedback: _text(json['generationFeedback']),
    status: _text(json['status']),
    continuesFromPrevious: json['continuesFromPrevious'] == true,
    continuesToNext: json['continuesToNext'] == true,
  );
}

class RemoteVideoUpload {
  const RemoteVideoUpload({
    required this.id,
    required this.fileName,
    required this.size,
    required this.createdAt,
  });

  final String id;
  final String fileName;
  final int size;
  final DateTime? createdAt;

  factory RemoteVideoUpload.fromJson(Map<String, Object?> json) =>
      RemoteVideoUpload(
        id: _text(json['id']),
        fileName: _text(json['fileName']),
        size: _integer(json['size']),
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
      );
}

class RemoteTask {
  const RemoteTask({
    required this.id,
    required this.kind,
    required this.status,
    required this.current,
    required this.total,
    required this.message,
    required this.errorCode,
    required this.errorMessage,
    required this.result,
    required this.cancellable,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String kind;
  final String status;
  final int current;
  final int total;
  final String message;
  final String errorCode;
  final String errorMessage;
  final Map<String, Object?> result;
  final bool cancellable;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get terminal =>
      status == 'succeeded' || status == 'failed' || status == 'cancelled';

  double? get progress => total <= 0 ? null : (current / total).clamp(0, 1);

  String get exportKind => _text(result['exportKind']);

  List<RemoteExportArtifact> get exportArtifacts => _list(result['artifacts'])
      .map((item) => RemoteExportArtifact.fromJson(_map(item)))
      .toList(growable: false);

  bool get exportRetryable =>
      kind == 'export' && (status == 'failed' || status == 'cancelled');

  factory RemoteTask.fromJson(Map<String, Object?> json) {
    final progress = _map(json['progress']);
    final error = _map(json['error']);
    return RemoteTask(
      id: _text(json['id']),
      kind: _text(json['kind']),
      status: _text(json['status']),
      current: _integer(progress['current']),
      total: _integer(progress['total']),
      message: _text(json['message']),
      errorCode: _text(error['code']),
      errorMessage: _text(error['message']),
      result: _map(json['result']),
      cancellable: json['cancellable'] == true,
      createdAt: DateTime.tryParse(_text(json['createdAt'])),
      updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
    );
  }
}

class RemoteExportBoard {
  const RemoteExportBoard({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final String id;
  final String name;
  final int itemCount;

  factory RemoteExportBoard.fromJson(Map<String, Object?> json) =>
      RemoteExportBoard(
        id: _text(json['id']),
        name: _text(json['name']),
        itemCount: _integer(json['itemCount']),
      );
}

class RemoteExportVideo {
  const RemoteExportVideo({required this.id, required this.name});

  final String id;
  final String name;

  factory RemoteExportVideo.fromJson(Map<String, Object?> json) =>
      RemoteExportVideo(id: _text(json['id']), name: _text(json['name']));
}

class RemoteExportScript {
  const RemoteExportScript({
    required this.id,
    required this.name,
    required this.timelineAvailable,
  });

  final String id;
  final String name;
  final bool timelineAvailable;

  factory RemoteExportScript.fromJson(Map<String, Object?> json) =>
      RemoteExportScript(
        id: _text(json['id']),
        name: _text(json['name']),
        timelineAvailable: json['timelineAvailable'] == true,
      );
}

class RemoteExportDefaults {
  const RemoteExportDefaults({
    required this.storyboardFormat,
    required this.storyboardResolution,
    required this.includeSummaryPage,
    required this.analysisReportFormat,
    required this.includeMultiDimensionAnalysis,
    required this.includeShotDetails,
  });

  final String storyboardFormat;
  final String storyboardResolution;
  final bool includeSummaryPage;
  final String analysisReportFormat;
  final bool includeMultiDimensionAnalysis;
  final bool includeShotDetails;

  factory RemoteExportDefaults.fromJson(Map<String, Object?> json) =>
      RemoteExportDefaults(
        storyboardFormat: _text(json['storyboardFormat']),
        storyboardResolution: _text(json['storyboardResolution']),
        includeSummaryPage: json['includeSummaryPage'] == true,
        analysisReportFormat: _text(json['analysisReportFormat']),
        includeMultiDimensionAnalysis:
            json['includeMultiDimensionAnalysis'] == true,
        includeShotDetails: json['includeShotDetails'] == true,
      );
}

class RemoteExportOptions {
  const RemoteExportOptions({
    required this.storyboardFormats,
    required this.storyboardResolutions,
    required this.analysisReportFormats,
    required this.boards,
    required this.videos,
    required this.scripts,
    required this.defaults,
  });

  final List<String> storyboardFormats;
  final List<String> storyboardResolutions;
  final List<String> analysisReportFormats;
  final List<RemoteExportBoard> boards;
  final List<RemoteExportVideo> videos;
  final List<RemoteExportScript> scripts;
  final RemoteExportDefaults defaults;

  factory RemoteExportOptions.fromJson(Map<String, Object?> json) =>
      RemoteExportOptions(
        storyboardFormats: _stringList(json['storyboardFormats']),
        storyboardResolutions: _stringList(json['storyboardResolutions']),
        analysisReportFormats: _stringList(json['analysisReportFormats']),
        boards: _list(json['boards'])
            .map((item) => RemoteExportBoard.fromJson(_map(item)))
            .toList(growable: false),
        videos: _list(json['videos'])
            .map((item) => RemoteExportVideo.fromJson(_map(item)))
            .toList(growable: false),
        scripts: _list(json['scripts'])
            .map((item) => RemoteExportScript.fromJson(_map(item)))
            .toList(growable: false),
        defaults: RemoteExportDefaults.fromJson(_map(json['defaults'])),
      );
}

class RemoteExportRequest {
  const RemoteExportRequest({
    required this.kind,
    this.boardIds = const [],
    this.videoId = '',
    this.scriptId = '',
    this.format = '',
    this.resolution = '',
    this.includeSummaryPage,
    this.includeMultiDimensionAnalysis,
    this.includeShotDetails,
  });

  final String kind;
  final List<String> boardIds;
  final String videoId;
  final String scriptId;
  final String format;
  final String resolution;
  final bool? includeSummaryPage;
  final bool? includeMultiDimensionAnalysis;
  final bool? includeShotDetails;

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (boardIds.isNotEmpty) 'boardIds': boardIds,
    if (videoId.isNotEmpty) 'videoId': videoId,
    if (scriptId.isNotEmpty) 'scriptId': scriptId,
    if (format.isNotEmpty) 'format': format,
    if (resolution.isNotEmpty) 'resolution': resolution,
    'includeSummaryPage': ?includeSummaryPage,
    'includeMultiDimensionAnalysis': ?includeMultiDimensionAnalysis,
    'includeShotDetails': ?includeShotDetails,
  };
}

class RemoteExportArtifact {
  const RemoteExportArtifact({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.size,
    required this.previewable,
    required this.contentUrl,
    required this.downloadUrl,
  });

  final String id;
  final String fileName;
  final String contentType;
  final int size;
  final bool previewable;
  final String contentUrl;
  final String downloadUrl;

  factory RemoteExportArtifact.fromJson(Map<String, Object?> json) =>
      RemoteExportArtifact(
        id: _text(json['id']),
        fileName: _text(json['fileName']),
        contentType: _text(json['contentType']),
        size: _integer(json['size']),
        previewable: json['previewable'] == true,
        contentUrl: _safeApiPath(json['contentUrl']),
        downloadUrl: _safeApiPath(json['downloadUrl']),
      );
}

class RemoteVideoSummary {
  const RemoteVideoSummary({
    required this.id,
    required this.fileName,
    required this.durationMs,
    required this.frameRate,
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.rotationDegrees,
    required this.hasAudio,
    required this.frameCount,
    required this.successfulFrames,
    required this.failedFrames,
    required this.status,
    required this.errorMessage,
    required this.mediaId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String fileName;
  final int durationMs;
  final double frameRate;
  final int width;
  final int height;
  final int displayWidth;
  final int displayHeight;
  final int rotationDegrees;
  final bool hasAudio;
  final int frameCount;
  final int successfulFrames;
  final int failedFrames;
  final String status;
  final String errorMessage;
  final String? mediaId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isPortrait => displayHeight > displayWidth;

  factory RemoteVideoSummary.fromJson(Map<String, Object?> json) =>
      RemoteVideoSummary(
        id: _text(json['id']),
        fileName: _text(json['fileName']),
        durationMs: _integer(json['durationMs']),
        frameRate: _number(json['frameRate']),
        width: _integer(json['width']),
        height: _integer(json['height']),
        displayWidth: _integer(json['displayWidth']),
        displayHeight: _integer(json['displayHeight']),
        rotationDegrees: _integer(json['rotationDegrees']),
        hasAudio: json['hasAudio'] == true,
        frameCount: _integer(json['frameCount']),
        successfulFrames: _integer(json['successfulFrames']),
        failedFrames: _integer(json['failedFrames']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
        mediaId: _mediaId(json['mediaUrl']),
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
        updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
      );
}

class RemoteVideoDetail {
  const RemoteVideoDetail({
    required this.video,
    required this.analysisState,
    required this.frames,
    required this.shots,
    required this.marketingAnalyses,
    required this.summary,
  });

  final RemoteVideoSummary video;
  final RemoteVideoAnalysisState analysisState;
  final List<RemoteVideoFrame> frames;
  final List<RemoteVideoShot> shots;
  final List<RemoteVideoDimensionAnalysis> marketingAnalyses;
  final RemoteVideoReportSummary? summary;

  factory RemoteVideoDetail.fromJson(Map<String, Object?> json) =>
      RemoteVideoDetail(
        video: RemoteVideoSummary.fromJson(json),
        analysisState: RemoteVideoAnalysisState.fromJson(
          _map(json['analysisState']),
        ),
        frames: _list(json['frames'])
            .map((item) => RemoteVideoFrame.fromJson(_map(item)))
            .toList(growable: false),
        shots: _list(json['shots'])
            .map((item) => RemoteVideoShot.fromJson(_map(item)))
            .toList(growable: false),
        marketingAnalyses: _list(json['marketingAnalyses'])
            .map((item) => RemoteVideoDimensionAnalysis.fromJson(_map(item)))
            .toList(growable: false),
        summary: json['summary'] is Map
            ? RemoteVideoReportSummary.fromJson(_map(json['summary']))
            : null,
      );
}

class RemoteVideoAnalysisState {
  const RemoteVideoAnalysisState({
    required this.isAnalyzing,
    required this.isPaused,
    required this.current,
    required this.total,
    required this.message,
    required this.errorMessage,
    this.canUndoFrameRemoval = false,
    this.canRedoFrameRemoval = false,
  });

  final bool isAnalyzing;
  final bool isPaused;
  final int current;
  final int total;
  final String message;
  final String errorMessage;
  final bool canUndoFrameRemoval;
  final bool canRedoFrameRemoval;

  factory RemoteVideoAnalysisState.fromJson(Map<String, Object?> json) {
    final progress = _map(json['progress']);
    return RemoteVideoAnalysisState(
      isAnalyzing: json['isAnalyzing'] == true,
      isPaused: json['isPaused'] == true,
      current: _integer(progress['current']),
      total: _integer(progress['total']),
      message: _text(json['message']),
      errorMessage: _text(json['errorMessage']),
      canUndoFrameRemoval: json['canUndoFrameRemoval'] == true,
      canRedoFrameRemoval: json['canRedoFrameRemoval'] == true,
    );
  }
}

class RemoteVideoFrame {
  const RemoteVideoFrame({
    required this.id,
    required this.index,
    required this.timestampMs,
    required this.width,
    required this.height,
    required this.sharpness,
    required this.brightness,
    required this.motionScore,
    required this.isFocus,
    required this.status,
    required this.errorMessage,
    required this.mediaId,
    required this.analysis,
  });

  final String id;
  final int index;
  final int timestampMs;
  final int width;
  final int height;
  final double sharpness;
  final double brightness;
  final double motionScore;
  final bool isFocus;
  final String status;
  final String errorMessage;
  final String? mediaId;
  final RemoteVideoFrameAnalysis? analysis;

  factory RemoteVideoFrame.fromJson(Map<String, Object?> json) =>
      RemoteVideoFrame(
        id: _text(json['id']),
        index: _integer(json['index']),
        timestampMs: _integer(json['timestampMs']),
        width: _integer(json['width']),
        height: _integer(json['height']),
        sharpness: _number(json['sharpness']),
        brightness: _number(json['brightness']),
        motionScore: _number(json['motionScore']),
        isFocus: json['isFocus'] == true,
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
        mediaId: _mediaId(json['mediaUrl']),
        analysis: json['analysis'] is Map
            ? RemoteVideoFrameAnalysis.fromJson(_map(json['analysis']))
            : null,
      );
}

class RemoteVideoFrameAnalysis {
  const RemoteVideoFrameAnalysis({
    required this.id,
    required this.sequenceNo,
    required this.dimensions,
    required this.status,
    required this.errorMessage,
  });

  final String id;
  final int sequenceNo;
  final Map<String, String> dimensions;
  final String status;
  final String errorMessage;

  factory RemoteVideoFrameAnalysis.fromJson(Map<String, Object?> json) =>
      RemoteVideoFrameAnalysis(
        id: _text(json['id']),
        sequenceNo: _integer(json['sequenceNo']),
        dimensions: _stringMap(json['dimensions']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
      );
}

class RemoteVideoShot {
  const RemoteVideoShot({
    required this.id,
    required this.shotNumber,
    required this.startMs,
    required this.endMs,
    required this.primaryFrameId,
    required this.frameIds,
    required this.description,
    required this.storyFlow,
    required this.status,
  });

  final String id;
  final int shotNumber;
  final int startMs;
  final int endMs;
  final String? primaryFrameId;
  final List<String> frameIds;
  final String description;
  final String storyFlow;
  final String status;

  factory RemoteVideoShot.fromJson(Map<String, Object?> json) =>
      RemoteVideoShot(
        id: _text(json['id']),
        shotNumber: _integer(json['shotNumber']),
        startMs: _integer(json['startMs']),
        endMs: _integer(json['endMs']),
        primaryFrameId: _nullableText(json['primaryFrameId']),
        frameIds: _list(json['frameIds']).map(_text).toList(growable: false),
        description: _text(json['description']),
        storyFlow: _text(json['storyFlow']),
        status: _text(json['status']),
      );
}

class RemoteVideoDimensionAnalysis {
  const RemoteVideoDimensionAnalysis({
    required this.id,
    required this.scope,
    required this.dimensions,
    required this.status,
    required this.errorMessage,
  });

  final String id;
  final String scope;
  final Map<String, String> dimensions;
  final String status;
  final String errorMessage;

  factory RemoteVideoDimensionAnalysis.fromJson(Map<String, Object?> json) =>
      RemoteVideoDimensionAnalysis(
        id: _text(json['id']),
        scope: _text(json['scope']),
        dimensions: _stringMap(json['dimensions']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
      );
}

class RemoteVideoReportSummary {
  const RemoteVideoReportSummary({
    required this.id,
    required this.fields,
    required this.status,
    required this.errorMessage,
  });

  final String id;
  final Map<String, String> fields;
  final String status;
  final String errorMessage;

  factory RemoteVideoReportSummary.fromJson(Map<String, Object?> json) =>
      RemoteVideoReportSummary(
        id: _text(json['id']),
        fields: _stringMap(json['fields']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
      );
}

class RemoteMediaBytes {
  const RemoteMediaBytes({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String? contentType;
}

class RemoteVideoGenerationScript {
  const RemoteVideoGenerationScript({
    required this.id,
    required this.name,
    required this.status,
    required this.version,
    required this.isSelected,
  });

  final String id;
  final String name;
  final String status;
  final int version;
  final bool isSelected;

  factory RemoteVideoGenerationScript.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationScript(
        id: _text(json['id']),
        name: _text(json['name']),
        status: _text(json['status']),
        version: _integer(json['version']),
        isSelected: json['isSelected'] == true,
      );
}

class RemoteVideoGenerationBackend {
  const RemoteVideoGenerationBackend({
    required this.kind,
    required this.name,
    required this.ready,
    required this.message,
  });

  final String kind;
  final String name;
  final bool ready;
  final String message;

  factory RemoteVideoGenerationBackend.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationBackend(
        kind: _text(json['kind']),
        name: _text(json['name']),
        ready: json['ready'] == true,
        message: _text(json['message']),
      );
}

class RemoteVideoGenerationModel {
  const RemoteVideoGenerationModel({required this.id, required this.name});

  final String id;
  final String name;

  factory RemoteVideoGenerationModel.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationModel(
        id: _text(json['id']),
        name: _text(json['name']),
      );
}

class RemoteVideoGenerationParameterOption {
  const RemoteVideoGenerationParameterOption({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;

  factory RemoteVideoGenerationParameterOption.fromJson(
    Map<String, Object?> json,
  ) => RemoteVideoGenerationParameterOption(
    value: _text(json['value']),
    label: _text(json['label']),
  );
}

class RemoteVideoGenerationParameter {
  const RemoteVideoGenerationParameter({
    required this.key,
    required this.label,
    required this.component,
    required this.group,
    required this.value,
    required this.options,
    required this.min,
    required this.max,
    required this.step,
  });

  final String key;
  final String label;
  final String component;
  final String group;
  final String value;
  final List<RemoteVideoGenerationParameterOption> options;
  final num? min;
  final num? max;
  final num? step;

  factory RemoteVideoGenerationParameter.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationParameter(
        key: _text(json['key']),
        label: _text(json['label']),
        component: _text(json['component']),
        group: _text(json['group']),
        value: _text(json['value']),
        options: _list(json['options'])
            .map(
              (item) =>
                  RemoteVideoGenerationParameterOption.fromJson(_map(item)),
            )
            .toList(growable: false),
        min: json['min'] is num ? json['min']! as num : null,
        max: json['max'] is num ? json['max']! as num : null,
        step: json['step'] is num ? json['step']! as num : null,
      );
}

class RemoteVideoGenerationOptions {
  const RemoteVideoGenerationOptions({
    required this.scripts,
    required this.selectedScriptId,
    required this.backend,
    required this.projectAspectRatio,
    required this.models,
    required this.selectedModelId,
    required this.parameters,
  });

  final List<RemoteVideoGenerationScript> scripts;
  final String selectedScriptId;
  final RemoteVideoGenerationBackend backend;
  final String projectAspectRatio;
  final List<RemoteVideoGenerationModel> models;
  final String selectedModelId;
  final List<RemoteVideoGenerationParameter> parameters;

  factory RemoteVideoGenerationOptions.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationOptions(
        scripts: _list(json['scripts'])
            .map((item) => RemoteVideoGenerationScript.fromJson(_map(item)))
            .toList(growable: false),
        selectedScriptId: _text(json['selectedScriptId']),
        backend: RemoteVideoGenerationBackend.fromJson(_map(json['backend'])),
        projectAspectRatio: _text(json['projectAspectRatio']),
        models: _list(json['models'])
            .map((item) => RemoteVideoGenerationModel.fromJson(_map(item)))
            .toList(growable: false),
        selectedModelId: _text(json['selectedModelId']),
        parameters: _list(json['parameters'])
            .map((item) => RemoteVideoGenerationParameter.fromJson(_map(item)))
            .toList(growable: false),
      );
}

class RemoteVideoGenerationGroup {
  const RemoteVideoGenerationGroup({
    required this.id,
    required this.scriptId,
    required this.shotIds,
    required this.shotNumbers,
    required this.title,
    required this.durationSeconds,
    required this.prompt,
    required this.promptMode,
    required this.canGenerate,
    required this.isActive,
    required this.referenceImageMediaId,
  });

  final String id;
  final String scriptId;
  final List<String> shotIds;
  final List<int> shotNumbers;
  final String title;
  final double durationSeconds;
  final String prompt;
  final String promptMode;
  final bool canGenerate;
  final bool isActive;
  final String? referenceImageMediaId;

  factory RemoteVideoGenerationGroup.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationGroup(
        id: _text(json['id']),
        scriptId: _text(json['scriptId']),
        shotIds: _list(json['shotIds']).map(_text).toList(growable: false),
        shotNumbers: _list(
          json['shotNumbers'],
        ).map(_integer).toList(growable: false),
        title: _text(json['title']),
        durationSeconds: _number(json['durationSeconds']),
        prompt: _text(json['prompt']),
        promptMode: _text(json['promptMode']),
        canGenerate: json['canGenerate'] == true,
        isActive: json['isActive'] == true,
        referenceImageMediaId: _mediaId(json['referenceImageUrl']),
      );
}

class RemoteVideoGenerationTask {
  const RemoteVideoGenerationTask({
    required this.id,
    required this.scriptId,
    required this.shotId,
    required this.shotNumber,
    required this.model,
    required this.parameters,
    required this.durationSeconds,
    required this.promptMode,
    required this.prompt,
    required this.status,
    required this.errorMessage,
    required this.hasLocalResult,
    required this.mediaId,
    required this.createdAt,
    required this.updatedAt,
    required this.completedAt,
  });

  final String id;
  final String scriptId;
  final String shotId;
  final int shotNumber;
  final String model;
  final Map<String, String> parameters;
  final int durationSeconds;
  final String promptMode;
  final String prompt;
  final String status;
  final String errorMessage;
  final bool hasLocalResult;
  final String? mediaId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? completedAt;

  bool get running =>
      const {'draft', 'submitting', 'queued', 'running'}.contains(status);
  bool get retryable =>
      const {'failed', 'canceled', 'timedOut'}.contains(status);

  factory RemoteVideoGenerationTask.fromJson(Map<String, Object?> json) =>
      RemoteVideoGenerationTask(
        id: _text(json['id']),
        scriptId: _text(json['scriptId']),
        shotId: _text(json['shotId']),
        shotNumber: _integer(json['shotNumber']),
        model: _text(json['model']),
        parameters: _stringMap(json['parameters']),
        durationSeconds: _integer(json['durationSeconds']),
        promptMode: _text(json['promptMode']),
        prompt: _text(json['prompt']),
        status: _text(json['status']),
        errorMessage: _text(json['errorMessage']),
        hasLocalResult: json['hasLocalResult'] == true,
        mediaId: _mediaId(json['mediaUrl']),
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
        updatedAt: DateTime.tryParse(_text(json['updatedAt'])),
        completedAt: DateTime.tryParse(_text(json['completedAt'])),
      );
}

class RemoteVideoGenerationShotOverride {
  const RemoteVideoGenerationShotOverride({
    required this.prompt,
    required this.promptMode,
    required this.durationSeconds,
  });

  final String prompt;
  final String promptMode;
  final double durationSeconds;

  Map<String, Object?> toJson() => {
    'prompt': prompt,
    'promptMode': promptMode,
    'durationSeconds': durationSeconds,
  };
}

class RemoteSettingsOption {
  const RemoteSettingsOption({
    required this.id,
    required this.name,
    required this.detail,
  });

  final String id;
  final String name;
  final String detail;

  factory RemoteSettingsOption.fromJson(Map<String, Object?> json) =>
      RemoteSettingsOption(
        id: _text(json['id']),
        name: _text(json['name']),
        detail: _text(json['detail']),
      );
}

class RemoteSettingsSelection {
  const RemoteSettingsSelection({
    required this.extractionStrategies,
    required this.selectedExtractionStrategy,
    required this.visionModels,
    required this.selectedVisionModelId,
    required this.imageGenerationModels,
    required this.selectedImageGenerationModelId,
    required this.videoGenerationModels,
    required this.selectedVideoGenerationModelId,
  });

  final List<RemoteSettingsOption> extractionStrategies;
  final String selectedExtractionStrategy;
  final List<RemoteSettingsOption> visionModels;
  final String selectedVisionModelId;
  final List<RemoteSettingsOption> imageGenerationModels;
  final String selectedImageGenerationModelId;
  final List<RemoteSettingsOption> videoGenerationModels;
  final String selectedVideoGenerationModelId;

  factory RemoteSettingsSelection.fromJson(Map<String, Object?> json) =>
      RemoteSettingsSelection(
        extractionStrategies: _list(json['extractionStrategies'])
            .map((item) => RemoteSettingsOption.fromJson(_map(item)))
            .where((item) => item.id.isNotEmpty)
            .toList(growable: false),
        selectedExtractionStrategy: _text(json['selectedExtractionStrategy']),
        visionModels: _list(json['visionModels'])
            .map((item) => RemoteSettingsOption.fromJson(_map(item)))
            .where((item) => item.id.isNotEmpty)
            .toList(growable: false),
        selectedVisionModelId: _text(json['selectedVisionModelId']),
        imageGenerationModels: _list(json['imageGenerationModels'])
            .map((item) => RemoteSettingsOption.fromJson(_map(item)))
            .where((item) => item.id.isNotEmpty)
            .toList(growable: false),
        selectedImageGenerationModelId: _text(
          json['selectedImageGenerationModelId'],
        ),
        videoGenerationModels: _list(json['videoGenerationModels'])
            .map((item) => RemoteSettingsOption.fromJson(_map(item)))
            .where((item) => item.id.isNotEmpty)
            .toList(growable: false),
        selectedVideoGenerationModelId: _text(
          json['selectedVideoGenerationModelId'],
        ),
      );
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

List<String> _stringList(Object? value) => _list(
  value,
).map(_text).where((item) => item.isNotEmpty).toList(growable: false);

String _text(Object? value) => value is String ? value : '';

String? _nullableText(Object? value) {
  final text = _text(value).trim();
  return text.isEmpty ? null : text;
}

int _integer(Object? value) => value is num ? value.toInt() : 0;

double _number(Object? value) => value is num ? value.toDouble() : 0;

Map<String, String> _stringMap(Object? value) =>
    _map(value).map((key, value) => MapEntry(key, _text(value)));

String? _mediaId(Object? value) {
  final path = _text(value);
  final match = RegExp(r'/api/v1/media/([^/]+)/content$').firstMatch(path);
  return match?.group(1);
}

String _safeApiPath(Object? value) {
  final text = _text(value);
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      !RegExp(
        r'^/api/v1/exports/artifacts/[^/]+/content$',
      ).hasMatch(uri.path)) {
    return '';
  }
  if (uri.queryParameters.isNotEmpty &&
      (uri.queryParameters.length != 1 ||
          uri.queryParameters['download'] != '1')) {
    return '';
  }
  return uri.toString();
}
