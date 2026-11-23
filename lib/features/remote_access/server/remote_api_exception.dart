class RemoteApiException implements Exception {
  const RemoteApiException(
    this.statusCode,
    this.code,
    this.message, [
    this.details = const {},
  ]);

  final int statusCode;
  final String code;
  final String message;
  final Map<String, Object?> details;
}
