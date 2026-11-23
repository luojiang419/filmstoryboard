import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class FfmpegToolPaths {
  const FfmpegToolPaths({required this.ffmpeg, required this.ffprobe});

  final File ffmpeg;
  final File ffprobe;
}

typedef FfmpegArchiveDownload =
    Future<void> Function(Uri url, File destination);

class FfmpegToolResolver {
  const FfmpegToolResolver({
    this.cacheDirectory,
    this.downloadUrl =
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
    this.download,
    this.isWindows,
    this.checkSystemPath = true,
    this.versionCheckTimeout = const Duration(seconds: 3),
  });

  final Directory? cacheDirectory;
  final String downloadUrl;
  final FfmpegArchiveDownload? download;
  final bool? isWindows;
  final bool checkSystemPath;
  final Duration versionCheckTimeout;

  static final Map<String, Future<FfmpegToolPaths>> _installations = {};

  Future<String> resolveFfmpeg(String configuredExecutable) async {
    return (await _resolve(
      configuredExecutable: configuredExecutable,
      fileName: 'ffmpeg.exe',
    )).path;
  }

  Future<String> resolveFfprobe(String configuredExecutable) async {
    return (await _resolve(
      configuredExecutable: configuredExecutable,
      fileName: 'ffprobe.exe',
    )).path;
  }

  Future<File> _resolve({
    required String configuredExecutable,
    required String fileName,
  }) async {
    final configured = _existingConfiguredFile(configuredExecutable);
    if (configured != null) {
      return configured;
    }

    final local = _findLocalTool(fileName);
    if (local != null) {
      return local;
    }

    if (checkSystemPath && await _canRun(configuredExecutable)) {
      return File(configuredExecutable);
    }

    if (!(isWindows ?? Platform.isWindows)) {
      throw StateError(
        '找不到 ${_displayName(fileName)}。请安装 FFmpeg 并确保命令可在 PATH 中执行。',
      );
    }

    final tools = await _ensureWindowsTools();
    return fileName == 'ffprobe.exe' ? tools.ffprobe : tools.ffmpeg;
  }

  File? _existingConfiguredFile(String executable) {
    final hasDirectory =
        p.isAbsolute(executable) ||
        executable.contains('/') ||
        executable.contains('\\');
    if (!hasDirectory) {
      return null;
    }
    final direct = File(executable);
    if (direct.existsSync()) {
      return direct.absolute;
    }
    if ((isWindows ?? Platform.isWindows) &&
        !executable.toLowerCase().endsWith('.exe')) {
      final withExtension = File('$executable.exe');
      if (withExtension.existsSync()) {
        return withExtension.absolute;
      }
    }
    return null;
  }

  Future<bool> _canRun(String executable) async {
    try {
      final result = await Process.run(executable, const [
        '-version',
      ]).timeout(versionCheckTimeout);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  File? _findLocalTool(String fileName) {
    for (final directory in _candidateBinDirectories()) {
      final file = File(p.join(directory.path, fileName));
      if (file.existsSync()) {
        return file.absolute;
      }
    }
    return null;
  }

  List<Directory> _candidateBinDirectories() {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final currentDirectory = Directory.current;
    return [
      Directory(p.join(_toolsDirectory().path, 'bin')),
      Directory(p.join(executableDirectory.path, 'ffmpeg', 'bin')),
      Directory(p.join(executableDirectory.path, 'tools', 'ffmpeg', 'bin')),
      Directory(p.join(currentDirectory.path, 'tools', 'ffmpeg', 'bin')),
    ];
  }

  Future<FfmpegToolPaths> _ensureWindowsTools() {
    final directory = _toolsDirectory();
    final key = directory.absolute.path;
    final existing = _installations[key];
    if (existing != null) {
      return existing;
    }
    final installation = _ensureWindowsToolsUnlocked(directory);
    _installations[key] = installation;
    return installation.whenComplete(() => _installations.remove(key));
  }

  Future<FfmpegToolPaths> _ensureWindowsToolsUnlocked(Directory root) async {
    final bin = Directory(p.join(root.path, 'bin'));
    final ffmpeg = File(p.join(bin.path, 'ffmpeg.exe'));
    final ffprobe = File(p.join(bin.path, 'ffprobe.exe'));
    if (ffmpeg.existsSync() && ffprobe.existsSync()) {
      return FfmpegToolPaths(
        ffmpeg: ffmpeg.absolute,
        ffprobe: ffprobe.absolute,
      );
    }

    await root.create(recursive: true);
    final archiveFile = File(
      p.join(root.path, 'ffmpeg-release-essentials.zip'),
    );
    try {
      await (download ?? _downloadArchive)(Uri.parse(downloadUrl), archiveFile);
      await _extractExecutables(archiveFile, bin);
    } on Object catch (error) {
      throw StateError(
        '自动下载 FFmpeg 失败：$error。'
        '请检查网络，或手动安装 FFmpeg 后重试。',
      );
    } finally {
      if (archiveFile.existsSync()) {
        await archiveFile.delete();
      }
    }

    if (!ffmpeg.existsSync() || !ffprobe.existsSync()) {
      throw StateError('FFmpeg 压缩包内缺少 ffmpeg.exe 或 ffprobe.exe。');
    }
    return FfmpegToolPaths(ffmpeg: ffmpeg.absolute, ffprobe: ffprobe.absolute);
  }

  Future<void> _extractExecutables(File archiveFile, Directory bin) async {
    await bin.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
    var foundFfmpeg = false;
    var foundFfprobe = false;

    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }
      final normalizedName = entry.name.replaceAll(r'\', '/').toLowerCase();
      final targetName = switch (p.url.basename(normalizedName)) {
        'ffmpeg.exe' => 'ffmpeg.exe',
        'ffprobe.exe' => 'ffprobe.exe',
        _ => null,
      };
      if (targetName == null || !normalizedName.contains('/bin/')) {
        continue;
      }
      final bytes = entry.readBytes();
      if (bytes == null) {
        continue;
      }
      await File(p.join(bin.path, targetName)).writeAsBytes(bytes);
      foundFfmpeg = foundFfmpeg || targetName == 'ffmpeg.exe';
      foundFfprobe = foundFfprobe || targetName == 'ffprobe.exe';
    }

    if (!foundFfmpeg || !foundFfprobe) {
      throw StateError('未能从压缩包中提取 ffmpeg.exe 和 ffprobe.exe。');
    }
  }

  Directory _toolsDirectory() {
    if (cacheDirectory != null) {
      return cacheDirectory!;
    }
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory(p.join(base, 'FilmStoryboard', 'tools', 'ffmpeg'));
  }

  static String _displayName(String fileName) =>
      fileName == 'ffprobe.exe' ? 'ffprobe' : 'ffmpeg';

  static Future<void> _downloadArchive(Uri url, File destination) async {
    Object? directError;
    try {
      await _downloadArchiveWithProxy(url, destination);
      return;
    } on Object catch (error) {
      directError = error;
    }

    try {
      await _downloadArchiveWithProxy(
        url,
        destination,
        proxy: '127.0.0.1:7890',
      );
      return;
    } on Object catch (proxyError) {
      throw StateError('直连失败：$directError；代理 127.0.0.1:7890 失败：$proxyError');
    }
  }

  static Future<void> _downloadArchiveWithProxy(
    Uri url,
    File destination, {
    String? proxy,
  }) async {
    final client = HttpClient();
    if (proxy != null) {
      client.findProxy = (_) => 'PROXY $proxy; DIRECT';
    }
    IOSink? sink;
    try {
      await destination.parent.create(recursive: true);
      final request = await client.getUrl(url);
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} ${response.reasonPhrase}',
          uri: url,
        );
      }
      sink = destination.openWrite();
      await response.pipe(sink);
    } finally {
      client.close(force: true);
      await sink?.close();
      if (destination.existsSync() && destination.lengthSync() == 0) {
        await destination.delete();
      }
    }
  }
}
