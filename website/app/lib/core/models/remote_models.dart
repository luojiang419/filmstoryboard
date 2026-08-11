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

class RemoteMediaBytes {
  const RemoteMediaBytes({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String? contentType;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

String _text(Object? value) => value is String ? value : '';

String? _nullableText(Object? value) {
  final text = _text(value).trim();
  return text.isEmpty ? null : text;
}

int _integer(Object? value) => value is num ? value.toInt() : 0;

double _number(Object? value) => value is num ? value.toDouble() : 0;
