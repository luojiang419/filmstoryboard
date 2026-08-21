import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../domain/line_art_color_style_preset.dart';

class ImportedColorStyleThumbnail {
  const ImportedColorStyleThumbnail({
    required this.reference,
    required this.file,
  });

  final ColorStyleThumbnailReference reference;
  final File file;
}

class LineArtColorStyleThumbnailService {
  LineArtColorStyleThumbnailService({
    required Directory projectRoot,
    required Directory projectAssetsRoot,
    DateTime Function()? now,
  }) : _projectRoot = projectRoot,
       _managedDirectory = Directory(
         p.join(projectAssetsRoot.path, 'color_style_thumbnails'),
       ),
       _now = now ?? DateTime.now;

  static const maxSourceBytes = 10 * 1024 * 1024;
  static const thumbnailWidth = 960;
  static const thumbnailHeight = 540;
  static const _allowedExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

  final Directory _projectRoot;
  final Directory _managedDirectory;
  final DateTime Function() _now;

  Directory get managedDirectory => _managedDirectory;

  Future<ImportedColorStyleThumbnail> importThumbnail({
    required String presetId,
    required File source,
  }) async {
    if (!await source.exists()) {
      throw const FileSystemException('缩略图文件不存在');
    }
    final extension = p.extension(source.path).toLowerCase();
    if (!_allowedExtensions.contains(extension)) {
      throw const FormatException('仅支持 JPG、PNG 或 WEBP 缩略图');
    }
    final sourceLength = await source.length();
    if (sourceLength <= 0 || sourceLength > maxSourceBytes) {
      throw const FormatException('缩略图必须大于 0 且不超过 10 MB');
    }

    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width < 16 || decoded.height < 9) {
      throw const FormatException('无法解析缩略图，或图片尺寸过小');
    }

    final outputBytes = _renderThumbnail(decoded);
    await _managedDirectory.create(recursive: true);
    final safeId = _safePresetId(presetId);
    final digest = sha256.convert(bytes).toString().substring(0, 12);
    final stamp = _now().toUtc().microsecondsSinceEpoch;
    final file = _nextAvailableFile('${safeId}_${stamp}_$digest');
    await file.writeAsBytes(outputBytes, flush: true);

    final relativePath = p.normalize(
      p.relative(file.path, from: _projectRoot.path),
    );
    return ImportedColorStyleThumbnail(
      reference: ColorStyleThumbnailReference.projectFile(relativePath),
      file: file,
    );
  }

  File resolveProjectFile(ColorStyleThumbnailReference reference) {
    if (reference.type != ColorStyleThumbnailType.projectFile) {
      throw ArgumentError('内置资源缩略图不能解析为项目文件');
    }
    final file = File(p.normalize(p.join(_projectRoot.path, reference.path)));
    if (!_isInsideManagedDirectory(file.path)) {
      throw const FileSystemException('缩略图路径不在项目托管目录中');
    }
    return file;
  }

  Future<void> removeManagedThumbnail(
    ColorStyleThumbnailReference reference,
  ) async {
    final file = resolveProjectFile(reference);
    if (await file.exists()) await file.delete();
  }

  Uint8List _renderThumbnail(img.Image source) {
    const targetAspect = thumbnailWidth / thumbnailHeight;
    final sourceAspect = source.width / source.height;
    late final int cropX;
    late final int cropY;
    late final int cropWidth;
    late final int cropHeight;
    if (sourceAspect > targetAspect) {
      cropHeight = source.height;
      cropWidth = (source.height * targetAspect).round().clamp(1, source.width);
      cropX = ((source.width - cropWidth) / 2).round();
      cropY = 0;
    } else {
      cropWidth = source.width;
      cropHeight = (source.width / targetAspect).round().clamp(
        1,
        source.height,
      );
      cropX = 0;
      cropY = ((source.height - cropHeight) / 2).round();
    }
    final cropped = img.copyCrop(
      source,
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );
    final resized = img.copyResize(
      cropped,
      width: thumbnailWidth,
      height: thumbnailHeight,
      interpolation: img.Interpolation.cubic,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
  }

  File _nextAvailableFile(String stem) {
    var candidate = File(p.join(_managedDirectory.path, '$stem.jpg'));
    var suffix = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(_managedDirectory.path, '${stem}_$suffix.jpg'));
      suffix += 1;
    }
    return candidate;
  }

  bool _isInsideManagedDirectory(String candidatePath) {
    final managed = p.normalize(p.absolute(_managedDirectory.path));
    final candidate = p.normalize(p.absolute(candidatePath));
    if (Platform.isWindows) {
      return p.isWithin(managed.toLowerCase(), candidate.toLowerCase());
    }
    return p.isWithin(managed, candidate);
  }

  static String _safePresetId(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9_-]+'),
      '_',
    );
    final collapsed = normalized.replaceAll(RegExp('_+'), '_');
    final safe = collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty
        ? 'custom_style'
        : safe.substring(0, safe.length.clamp(0, 48));
  }
}
