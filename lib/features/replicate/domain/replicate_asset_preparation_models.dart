enum ReplicateOutfitViewRole { front, side, back, other }

class ReplicateFullOutfitView {
  const ReplicateFullOutfitView({
    required this.id,
    required this.scriptAssetId,
    required this.role,
    this.order = 0,
  });

  final String id;
  final String scriptAssetId;
  final ReplicateOutfitViewRole role;
  final int order;

  ReplicateFullOutfitView copyWith({
    String? scriptAssetId,
    ReplicateOutfitViewRole? role,
    int? order,
  }) => ReplicateFullOutfitView(
    id: id,
    scriptAssetId: scriptAssetId ?? this.scriptAssetId,
    role: role ?? this.role,
    order: order ?? this.order,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'scriptAssetId': scriptAssetId,
    'role': role.name,
    'order': order,
  };

  factory ReplicateFullOutfitView.fromJson(Map<String, Object?> json) =>
      ReplicateFullOutfitView(
        id: _string(json['id']),
        scriptAssetId: _string(
          json['scriptAssetId'] ?? json['script_asset_id'],
        ),
        role: _enumValue(
          ReplicateOutfitViewRole.values,
          json['role'],
          ReplicateOutfitViewRole.other,
        ),
        order: _int(json['order']),
      );
}

/// A shot-scoped grouping of independently stored character views.
///
/// Each view references an existing [ScriptAsset] by id. Keeping file paths out
/// of this record preserves the existing project path migration behaviour.
class ReplicateFullOutfitAsset {
  const ReplicateFullOutfitAsset({
    required this.id,
    required this.personSlotIndex,
    required this.name,
    this.views = const [],
    this.primaryViewId = '',
    this.primaryViewManuallySelected = false,
    this.enabled = true,
  });

  final String id;
  final int personSlotIndex;
  final String name;
  final List<ReplicateFullOutfitView> views;
  final String primaryViewId;
  final bool primaryViewManuallySelected;
  final bool enabled;

  ReplicateFullOutfitView? get primaryView {
    for (final view in views) {
      if (view.id == primaryViewId) return view;
    }
    return null;
  }

  bool get hasCompleteThreeViewSet {
    final roles = views.map((view) => view.role).toSet();
    return roles.contains(ReplicateOutfitViewRole.front) &&
        roles.contains(ReplicateOutfitViewRole.side) &&
        roles.contains(ReplicateOutfitViewRole.back);
  }

  bool get hasIndependentThreeViewSet =>
      hasCompleteThreeViewSet &&
      views.map((view) => view.scriptAssetId).toSet().length >= 3;

  ReplicateFullOutfitAsset copyWith({
    int? personSlotIndex,
    String? name,
    List<ReplicateFullOutfitView>? views,
    String? primaryViewId,
    bool? primaryViewManuallySelected,
    bool? enabled,
  }) => ReplicateFullOutfitAsset(
    id: id,
    personSlotIndex: personSlotIndex ?? this.personSlotIndex,
    name: name ?? this.name,
    views: views ?? this.views,
    primaryViewId: primaryViewId ?? this.primaryViewId,
    primaryViewManuallySelected:
        primaryViewManuallySelected ?? this.primaryViewManuallySelected,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'personSlotIndex': personSlotIndex,
    'name': name,
    'views': [for (final view in views) view.toJson()],
    'primaryViewId': primaryViewId,
    'primaryViewManuallySelected': primaryViewManuallySelected,
    'enabled': enabled,
  };

  factory ReplicateFullOutfitAsset.fromJson(
    Map<String, Object?> json,
  ) => ReplicateFullOutfitAsset(
    id: _string(json['id']),
    personSlotIndex: _int(json['personSlotIndex'] ?? json['person_slot_index']),
    name: _string(json['name']),
    views: _objectList(json['views'], ReplicateFullOutfitView.fromJson),
    primaryViewId: _string(json['primaryViewId'] ?? json['primary_view_id']),
    primaryViewManuallySelected: _bool(
      json['primaryViewManuallySelected'] ??
          json['primary_view_manually_selected'],
    ),
    enabled: _bool(json['enabled'], fallback: true),
  );
}

/// Deterministically couples one wearable product slot to one model slot.
class ReplicateWearableProductLink {
  const ReplicateWearableProductLink({
    required this.personSlotIndex,
    required this.productSlotIndex,
    required this.fullOutfitAssetId,
    this.linked = true,
  });

  final int personSlotIndex;
  final int productSlotIndex;
  final String fullOutfitAssetId;
  final bool linked;

  ReplicateWearableProductLink copyWith({
    int? personSlotIndex,
    int? productSlotIndex,
    String? fullOutfitAssetId,
    bool? linked,
  }) => ReplicateWearableProductLink(
    personSlotIndex: personSlotIndex ?? this.personSlotIndex,
    productSlotIndex: productSlotIndex ?? this.productSlotIndex,
    fullOutfitAssetId: fullOutfitAssetId ?? this.fullOutfitAssetId,
    linked: linked ?? this.linked,
  );

  Map<String, Object?> toJson() => {
    'personSlotIndex': personSlotIndex,
    'productSlotIndex': productSlotIndex,
    'fullOutfitAssetId': fullOutfitAssetId,
    'linked': linked,
  };

  factory ReplicateWearableProductLink.fromJson(Map<String, Object?> json) =>
      ReplicateWearableProductLink(
        personSlotIndex: _int(
          json['personSlotIndex'] ?? json['person_slot_index'],
        ),
        productSlotIndex: _int(
          json['productSlotIndex'] ?? json['product_slot_index'],
        ),
        fullOutfitAssetId: _string(
          json['fullOutfitAssetId'] ?? json['full_outfit_asset_id'],
        ),
        linked: _bool(json['linked'], fallback: true),
      );
}

enum ReplicateAuthorizedMarkType { logo, productName, model, packagingText }

enum ReplicateAuthorizationStatus { unconfirmed, confirmed, revoked }

class ReplicateProductMarkAuthorization {
  const ReplicateProductMarkAuthorization({
    required this.productSlotIndex,
    this.enabled = false,
    this.referenceAssetId = '',
    this.exactText = '',
    this.allowedTypes = const [],
    this.status = ReplicateAuthorizationStatus.unconfirmed,
    this.confirmedAt,
    this.location = '',
  });

  final int productSlotIndex;
  final bool enabled;
  final String referenceAssetId;
  final String exactText;
  final List<ReplicateAuthorizedMarkType> allowedTypes;
  final ReplicateAuthorizationStatus status;
  final DateTime? confirmedAt;
  final String location;

  bool get isAuthorized =>
      enabled && status == ReplicateAuthorizationStatus.confirmed;

  ReplicateProductMarkAuthorization copyWith({
    bool? enabled,
    String? referenceAssetId,
    String? exactText,
    List<ReplicateAuthorizedMarkType>? allowedTypes,
    ReplicateAuthorizationStatus? status,
    DateTime? confirmedAt,
    bool clearConfirmedAt = false,
    String? location,
  }) => ReplicateProductMarkAuthorization(
    productSlotIndex: productSlotIndex,
    enabled: enabled ?? this.enabled,
    referenceAssetId: referenceAssetId ?? this.referenceAssetId,
    exactText: exactText ?? this.exactText,
    allowedTypes: allowedTypes ?? this.allowedTypes,
    status: status ?? this.status,
    confirmedAt: clearConfirmedAt ? null : confirmedAt ?? this.confirmedAt,
    location: location ?? this.location,
  );

  Map<String, Object?> toJson() => {
    'productSlotIndex': productSlotIndex,
    'enabled': enabled,
    'referenceAssetId': referenceAssetId,
    'exactText': exactText,
    'allowedTypes': [for (final type in allowedTypes) type.name],
    'status': status.name,
    if (confirmedAt != null)
      'confirmedAt': confirmedAt!.toUtc().toIso8601String(),
    'location': location,
  };

  factory ReplicateProductMarkAuthorization.fromJson(
    Map<String, Object?> json,
  ) => ReplicateProductMarkAuthorization(
    productSlotIndex: _int(
      json['productSlotIndex'] ?? json['product_slot_index'],
    ),
    enabled: _bool(json['enabled']),
    referenceAssetId: _string(
      json['referenceAssetId'] ?? json['reference_asset_id'],
    ),
    exactText: _string(json['exactText'] ?? json['exact_text']),
    allowedTypes: _enumList(
      ReplicateAuthorizedMarkType.values,
      json['allowedTypes'] ?? json['allowed_types'],
    ),
    status: _enumValue(
      ReplicateAuthorizationStatus.values,
      json['status'],
      ReplicateAuthorizationStatus.unconfirmed,
    ),
    confirmedAt: DateTime.tryParse(
      _string(json['confirmedAt'] ?? json['confirmed_at']),
    ),
    location: _string(json['location']),
  );
}

class ReplicatePoseBounds {
  const ReplicatePoseBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  static const zero = ReplicatePoseBounds(x: 0, y: 0, width: 0, height: 0);

  final double x;
  final double y;
  final double width;
  final double height;

  double get centerX => x + width / 2;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory ReplicatePoseBounds.fromJson(Map<String, Object?> json) =>
      ReplicatePoseBounds(
        x: _double(json['x']),
        y: _double(json['y']),
        width: _double(json['width']),
        height: _double(json['height']),
      );
}

class ReplicatePoseKeypoint {
  const ReplicatePoseKeypoint({
    required this.index,
    required this.x,
    required this.y,
    required this.confidence,
    this.manuallyAdjusted = false,
  });

  final int index;
  final double x;
  final double y;
  final double confidence;
  final bool manuallyAdjusted;

  ReplicatePoseKeypoint copyWith({
    double? x,
    double? y,
    double? confidence,
    bool? manuallyAdjusted,
  }) => ReplicatePoseKeypoint(
    index: index,
    x: x ?? this.x,
    y: y ?? this.y,
    confidence: confidence ?? this.confidence,
    manuallyAdjusted: manuallyAdjusted ?? this.manuallyAdjusted,
  );

  Map<String, Object?> toJson() => {
    'index': index,
    'x': x,
    'y': y,
    'confidence': confidence,
    'manuallyAdjusted': manuallyAdjusted,
  };

  factory ReplicatePoseKeypoint.fromJson(Map<String, Object?> json) =>
      ReplicatePoseKeypoint(
        index: _int(json['index']),
        x: _double(json['x']),
        y: _double(json['y']),
        confidence: _double(json['confidence']),
        manuallyAdjusted: _bool(
          json['manuallyAdjusted'] ?? json['manually_adjusted'],
        ),
      );
}

class ReplicatePosePerson {
  const ReplicatePosePerson({
    required this.id,
    required this.leftToRightOrder,
    required this.modelSlotIndex,
    required this.bounds,
    this.keypoints = const [],
    this.confidence = 0,
  });

  final String id;
  final int leftToRightOrder;
  final int modelSlotIndex;
  final ReplicatePoseBounds bounds;
  final List<ReplicatePoseKeypoint> keypoints;
  final double confidence;

  ReplicatePosePerson copyWith({
    int? leftToRightOrder,
    int? modelSlotIndex,
    ReplicatePoseBounds? bounds,
    List<ReplicatePoseKeypoint>? keypoints,
    double? confidence,
  }) => ReplicatePosePerson(
    id: id,
    leftToRightOrder: leftToRightOrder ?? this.leftToRightOrder,
    modelSlotIndex: modelSlotIndex ?? this.modelSlotIndex,
    bounds: bounds ?? this.bounds,
    keypoints: keypoints ?? this.keypoints,
    confidence: confidence ?? this.confidence,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'leftToRightOrder': leftToRightOrder,
    'modelSlotIndex': modelSlotIndex,
    'bounds': bounds.toJson(),
    'keypoints': [for (final keypoint in keypoints) keypoint.toJson()],
    'confidence': confidence,
  };

  factory ReplicatePosePerson.fromJson(
    Map<String, Object?> json,
  ) => ReplicatePosePerson(
    id: _string(json['id']),
    leftToRightOrder: _int(
      json['leftToRightOrder'] ?? json['left_to_right_order'],
    ),
    modelSlotIndex: _int(json['modelSlotIndex'] ?? json['model_slot_index']),
    bounds: _object(
      json['bounds'],
      ReplicatePoseBounds.fromJson,
      ReplicatePoseBounds.zero,
    ),
    keypoints: _objectList(json['keypoints'], ReplicatePoseKeypoint.fromJson),
    confidence: _double(json['confidence']),
  );
}

class ReplicateEditablePoseData {
  const ReplicateEditablePoseData({
    this.sourceWidth = 0,
    this.sourceHeight = 0,
    this.people = const [],
  });

  static const schemaVersion = 1;
  static const empty = ReplicateEditablePoseData();

  final int sourceWidth;
  final int sourceHeight;
  final List<ReplicatePosePerson> people;

  bool get isEmpty => people.isEmpty;

  List<ReplicatePosePerson> get peopleFromLeftToRight {
    final ordered = [...people]
      ..sort((a, b) => a.leftToRightOrder.compareTo(b.leftToRightOrder));
    return List.unmodifiable(ordered);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
    'people': [for (final person in people) person.toJson()],
  };

  factory ReplicateEditablePoseData.fromJson(Map<String, Object?> json) {
    final version = _int(json['schemaVersion'] ?? json['schema_version']);
    if (version != schemaVersion) return empty;
    return ReplicateEditablePoseData(
      sourceWidth: _int(json['sourceWidth'] ?? json['source_width']),
      sourceHeight: _int(json['sourceHeight'] ?? json['source_height']),
      people: _objectList(json['people'], ReplicatePosePerson.fromJson),
    );
  }
}

String _string(Object? value) => value?.toString().trim() ?? '';

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

double _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

bool _bool(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value.toString().trim().toLowerCase()) {
    'true' || '1' => true,
    'false' || '0' => false,
    _ => fallback,
  };
}

T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final name = _string(raw);
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

List<T> _enumList<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! List) return const [];
  final result = <T>[];
  for (final item in raw) {
    final name = _string(item);
    for (final value in values) {
      if (value.name == name && !result.contains(value)) result.add(value);
    }
  }
  return List.unmodifiable(result);
}

T _object<T>(Object? raw, T Function(Map<String, Object?>) decode, T fallback) {
  if (raw is! Map) return fallback;
  return decode(raw.map((key, value) => MapEntry('$key', value)));
}

List<T> _objectList<T>(Object? raw, T Function(Map<String, Object?>) decode) {
  if (raw is! List) return const [];
  return List.unmodifiable([
    for (final item in raw)
      if (item is Map)
        decode(item.map((key, value) => MapEntry('$key', value))),
  ]);
}
