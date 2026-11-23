// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

void openExportArtifact(
  Uri uri, {
  required bool download,
  required String fileName,
}) {
  if (download) {
    final anchor = html.AnchorElement(href: uri.toString())
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return;
  }
  html.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
}
