class RemoteSelectedVideoFile {
  const RemoteSelectedVideoFile({
    required this.name,
    required this.size,
    required this.openRead,
  });

  final String name;
  final int size;
  final Stream<List<int>> Function() openRead;
}
