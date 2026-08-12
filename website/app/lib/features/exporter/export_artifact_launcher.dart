import 'export_artifact_launcher_stub.dart'
    if (dart.library.html) 'export_artifact_launcher_web.dart'
    as platform;

void openExportArtifact(
  Uri uri, {
  required bool download,
  required String fileName,
}) => platform.openExportArtifact(uri, download: download, fileName: fileName);
