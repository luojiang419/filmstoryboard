import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../core/services/workspace_directories.dart';
import '../domain/story_design_models.dart';

class StoryDesignResultRepository {
  StoryDesignResultRepository._fromPath(String path)
    : _directory = Directory(path);
  StoryDesignResultRepository(WorkspaceDirectories directories)
    : _directory = Directory(
        p.join(directories.generatedImages.path, 'design'),
      );

  static const indexFileName = 'results.json';
  static const _supportedExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
  };

  final Directory _directory;

  File get _indexFile => File(p.join(_directory.path, indexFileName));

  List<StoryDesignResult> load({required String fallbackModel}) {
    try {
      if (_indexFile.existsSync()) {
        final restored = _loadIndex();
        return restored;
      }
      final migrated = _scanExistingImages(fallbackModel: fallbackModel);
      if (migrated.isNotEmpty) {
        save(migrated);
      }
      return migrated;
    } catch (_) {
      final recovered = _scanExistingImages(fallbackModel: fallbackModel);
      save(recovered);
      return recovered;
    }
  }

  Future<List<StoryDesignResult>> loadAsync({required String fallbackModel}) {
    final directoryPath = _directory.path;
    return Isolate.run(
      () => StoryDesignResultRepository._fromPath(
        directoryPath,
      ).load(fallbackModel: fallbackModel),
    );
  }

  void save(Iterable<StoryDesignResult> results) {
    try {
      if (!_directory.existsSync()) {
        _directory.createSync(recursive: true);
      }
      final payload = <String, Object?>{
        'version': 1,
        'results': [for (final result in results) _encodeResult(result)],
      };
      final temporary = File('${_indexFile.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(payload), flush: true);
      if (_indexFile.existsSync()) {
        _indexFile.deleteSync();
      }
      temporary.renameSync(_indexFile.path);
    } catch (_) {
      // 结果索引写入失败不应阻断图片生成或界面操作。
    }
  }

  List<StoryDesignResult> _loadIndex() {
    final decoded = jsonDecode(_indexFile.readAsStringSync());
    if (decoded is! Map || decoded['results'] is! List) {
      throw const FormatException('设计分镜图结果索引格式无效');
    }
    final results = <StoryDesignResult>[];
    for (final item in decoded['results'] as List) {
      if (item is! Map) {
        continue;
      }
      final result = _decodeResult(Map<String, dynamic>.from(item));
      if (result != null) {
        results.add(result);
      }
    }
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  StoryDesignResult? _decodeResult(Map<String, dynamic> json) {
    final rawFile = json['file']?.toString().trim() ?? '';
    if (rawFile.isEmpty) {
      return null;
    }
    final path = p.isAbsolute(rawFile)
        ? p.normalize(rawFile)
        : p.normalize(p.join(_directory.path, rawFile));
    if (!_isInsideResultDirectory(path) || !File(path).existsSync()) {
      return null;
    }
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final durationMs = _readInt(json['generationDurationMs']);
    return StoryDesignResult(
      id: json['id']?.toString().trim().isNotEmpty == true
          ? json['id'].toString().trim()
          : _legacyId(path),
      path: path,
      remoteUrl: json['remoteUrl']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      aspectRatio: json['aspectRatio']?.toString() ?? 'auto',
      imageSize: json['imageSize']?.toString() ?? '1K',
      quality: json['quality']?.toString() ?? 'auto',
      createdAt: createdAt ?? File(path).lastModifiedSync(),
      generationDuration: Duration(milliseconds: durationMs.clamp(0, 86400000)),
      selected: json['selected'] != false,
    );
  }

  List<StoryDesignResult> _scanExistingImages({required String fallbackModel}) {
    if (!_directory.existsSync()) {
      return const [];
    }
    final results = <StoryDesignResult>[];
    for (final entity in _directory.listSync(followLinks: false)) {
      if (entity is! File ||
          !_supportedExtensions.contains(
            p.extension(entity.path).toLowerCase(),
          )) {
        continue;
      }
      final metadata = _readMetadata(entity);
      final timestamp = _readInt(metadata['timestamp']);
      final createdAt = timestamp > 0
          ? DateTime.fromMillisecondsSinceEpoch(timestamp)
          : entity.lastModifiedSync();
      results.add(
        StoryDesignResult(
          id: _legacyId(entity.path),
          path: p.normalize(entity.path),
          remoteUrl: metadata['remoteUrl']?.toString() ?? '',
          prompt: metadata['prompt']?.toString() ?? '',
          model: metadata['model']?.toString().trim().isNotEmpty == true
              ? metadata['model'].toString().trim()
              : fallbackModel,
          aspectRatio: metadata['aspectRatio']?.toString() ?? 'auto',
          imageSize: metadata['imageSize']?.toString() ?? '1K',
          quality: metadata['quality']?.toString() ?? 'auto',
          createdAt: createdAt,
        ),
      );
    }
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  Map<String, dynamic> _readMetadata(File image) {
    final metadataFile = File('${image.path}.json');
    if (!metadataFile.existsSync()) {
      return const {};
    }
    try {
      final decoded = jsonDecode(metadataFile.readAsStringSync());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  Map<String, Object?> _encodeResult(StoryDesignResult result) {
    return {
      'id': result.id,
      'file': p.relative(result.path, from: _directory.path),
      'remoteUrl': result.remoteUrl,
      'prompt': result.prompt,
      'model': result.model,
      'aspectRatio': result.aspectRatio,
      'imageSize': result.imageSize,
      'quality': result.quality,
      'createdAt': result.createdAt.toIso8601String(),
      'generationDurationMs': result.generationDuration.inMilliseconds,
      'selected': result.selected,
    };
  }

  bool _isInsideResultDirectory(String path) {
    final directoryPath = p.normalize(p.absolute(_directory.path));
    final candidate = p.normalize(p.absolute(path));
    return p.equals(directoryPath, p.dirname(candidate)) ||
        p.isWithin(directoryPath, candidate);
  }

  String _legacyId(String path) {
    final normalized = p
        .basename(path)
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return 'restored-$normalized';
  }

  int _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
