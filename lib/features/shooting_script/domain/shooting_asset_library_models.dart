import '../../replicate/domain/replicate_models.dart';

class ShootingAssetLibraryItem {
  const ShootingAssetLibraryItem({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    this.aliases = const [],
    required this.path,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final ReplicateAssetType type;
  final String name;
  final String description;

  /// Additional controlled names that may appear in a storyboard field.
  final List<String> aliases;
  final String path;
  final DateTime createdAt;
  final DateTime updatedAt;

  ShootingAssetLibraryItem copyWith({
    ReplicateAssetType? type,
    String? name,
    String? description,
    List<String>? aliases,
    String? path,
    DateTime? updatedAt,
  }) => ShootingAssetLibraryItem(
    id: id,
    type: type ?? this.type,
    name: name ?? this.name,
    description: description ?? this.description,
    aliases: aliases ?? this.aliases,
    path: path ?? this.path,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
