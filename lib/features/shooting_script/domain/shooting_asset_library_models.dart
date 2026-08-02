import '../../replicate/domain/replicate_models.dart';

class ShootingAssetLibraryItem {
  const ShootingAssetLibraryItem({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final ReplicateAssetType type;
  final String name;
  final String description;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;

  ShootingAssetLibraryItem copyWith({
    ReplicateAssetType? type,
    String? name,
    String? description,
    String? path,
    DateTime? updatedAt,
  }) => ShootingAssetLibraryItem(
    id: id,
    type: type ?? this.type,
    name: name ?? this.name,
    description: description ?? this.description,
    path: path ?? this.path,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
