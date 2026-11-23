import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/remote_storyboard_models.dart';

typedef RemoteAnnotationIdFactory = String Function();
typedef RemoteAnnotationClock = DateTime Function();

class RemoteStoryboardReviewRepository {
  RemoteStoryboardReviewRepository(
    this._database, {
    RemoteAnnotationIdFactory? idFactory,
    RemoteAnnotationClock? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  static const storageKey = 'remoteStoryboardReviewAnnotations';
  static const storageVersion = 1;
  static const maxBodyLength = 4000;
  static const maxAuthorNameLength = 120;

  final AppDatabase _database;
  final RemoteAnnotationIdFactory _idFactory;
  final RemoteAnnotationClock _clock;

  List<RemoteStoryboardAnnotation> listForBoard(String boardId) {
    final normalizedBoardId = boardId.trim();
    if (normalizedBoardId.isEmpty) return const [];
    final items =
        _load()
            .where((annotation) => annotation.boardId == normalizedBoardId)
            .toList()
          ..sort((first, second) {
            final resolvedOrder = first.resolved == second.resolved
                ? 0
                : first.resolved
                ? 1
                : -1;
            return resolvedOrder != 0
                ? resolvedOrder
                : first.createdAt.compareTo(second.createdAt);
          });
    return List.unmodifiable(items);
  }

  RemoteStoryboardAnnotation? getById(String annotationId) {
    final normalizedId = annotationId.trim();
    if (normalizedId.isEmpty) return null;
    for (final annotation in _load()) {
      if (annotation.id == normalizedId) return annotation;
    }
    return null;
  }

  RemoteStoryboardAnnotation create({
    required String boardId,
    required String body,
    required String authorSessionId,
    required String authorName,
    String? assetId,
  }) {
    final normalizedBoardId = _requiredId(boardId, 'boardId');
    final normalizedBody = _validatedBody(body);
    final normalizedSessionId = _requiredId(authorSessionId, 'authorSessionId');
    final normalizedAuthorName = authorName.trim();
    if (normalizedAuthorName.isEmpty ||
        normalizedAuthorName.length > maxAuthorNameLength) {
      throw ArgumentError.value(authorName, 'authorName', '作者名称无效');
    }
    final normalizedAssetId = _optionalId(assetId);
    final now = _clock().toUtc();
    final annotation = RemoteStoryboardAnnotation(
      id: _requiredId(_idFactory(), 'id'),
      boardId: normalizedBoardId,
      assetId: normalizedAssetId,
      body: normalizedBody,
      authorSessionId: normalizedSessionId,
      authorName: normalizedAuthorName,
      createdAt: now,
      updatedAt: now,
      resolved: false,
    );
    _save([..._load(), annotation]);
    return annotation;
  }

  RemoteStoryboardAnnotation? update({
    required String annotationId,
    String? body,
    bool? resolved,
  }) {
    final normalizedId = _requiredId(annotationId, 'annotationId');
    if (body == null && resolved == null) {
      throw ArgumentError('至少提供一个批注修改字段');
    }
    final items = _load();
    final index = items.indexWhere(
      (annotation) => annotation.id == normalizedId,
    );
    if (index < 0) return null;
    final current = items[index];
    final nextBody = body == null ? current.body : _validatedBody(body);
    final nextResolved = resolved ?? current.resolved;
    if (nextBody == current.body && nextResolved == current.resolved) {
      return current;
    }
    final updated = current.copyWith(
      body: nextBody,
      resolved: nextResolved,
      updatedAt: _clock().toUtc(),
    );
    items[index] = updated;
    _save(items);
    return updated;
  }

  bool prune({
    required Set<String> boardIds,
    required Map<String, Set<String>> assetIdsByBoard,
  }) {
    final items = _load();
    final retained = [
      for (final annotation in items)
        if (boardIds.contains(annotation.boardId) &&
            (annotation.assetId == null ||
                (assetIdsByBoard[annotation.boardId] ?? const <String>{})
                    .contains(annotation.assetId)))
          annotation,
    ];
    if (retained.length == items.length) return false;
    _save(retained);
    return true;
  }

  List<RemoteStoryboardAnnotation> _load() {
    final raw = _database.getSetting(storageKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != storageVersion ||
          decoded['items'] is! List) {
        return [];
      }
      final annotations = <RemoteStoryboardAnnotation>[];
      for (final value in decoded['items']! as List<Object?>) {
        final annotation = _annotationFromJson(value);
        if (annotation != null) annotations.add(annotation);
      }
      return annotations;
    } catch (_) {
      return [];
    }
  }

  void _save(List<RemoteStoryboardAnnotation> annotations) {
    _database.setSetting(
      storageKey,
      jsonEncode({
        'version': storageVersion,
        'items': [for (final annotation in annotations) _toJson(annotation)],
      }),
    );
  }

  static Map<String, Object?> _toJson(RemoteStoryboardAnnotation annotation) =>
      {
        'id': annotation.id,
        'boardId': annotation.boardId,
        if (annotation.assetId != null) 'assetId': annotation.assetId,
        'body': annotation.body,
        'authorSessionId': annotation.authorSessionId,
        'authorName': annotation.authorName,
        'createdAt': annotation.createdAt.toUtc().toIso8601String(),
        'updatedAt': annotation.updatedAt.toUtc().toIso8601String(),
        'resolved': annotation.resolved,
      };

  static RemoteStoryboardAnnotation? _annotationFromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.map((key, value) => MapEntry('$key', value));
    final id = '${json['id'] ?? ''}'.trim();
    final boardId = '${json['boardId'] ?? ''}'.trim();
    final body = '${json['body'] ?? ''}'.trim();
    final authorSessionId = '${json['authorSessionId'] ?? ''}'.trim();
    final authorName = '${json['authorName'] ?? ''}'.trim();
    final createdAt = DateTime.tryParse('${json['createdAt'] ?? ''}');
    final updatedAt = DateTime.tryParse('${json['updatedAt'] ?? ''}');
    final assetId = '${json['assetId'] ?? ''}'.trim();
    if (id.isEmpty ||
        boardId.isEmpty ||
        body.isEmpty ||
        body.length > maxBodyLength ||
        authorSessionId.isEmpty ||
        authorName.isEmpty ||
        authorName.length > maxAuthorNameLength ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    return RemoteStoryboardAnnotation(
      id: id,
      boardId: boardId,
      assetId: assetId.isEmpty ? null : assetId,
      body: body,
      authorSessionId: authorSessionId,
      authorName: authorName,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      resolved: json['resolved'] == true,
    );
  }

  static String _validatedBody(String body) {
    final normalized = body.trim();
    if (normalized.isEmpty || normalized.length > maxBodyLength) {
      throw ArgumentError.value(body, 'body', '批注正文必须为 1 到 $maxBodyLength 个字符');
    }
    return normalized;
  }

  static String _requiredId(String value, String name) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 200) {
      throw ArgumentError.value(value, name, '标识无效');
    }
    return normalized;
  }

  static String? _optionalId(String? value) {
    if (value == null) return null;
    return _requiredId(value, 'assetId');
  }
}
