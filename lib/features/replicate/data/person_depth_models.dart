import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class DepthModelProgress {
  const DepthModelProgress(this.message, this.received, this.total);
  final String message;
  final int received;
  final int total;
  double get fraction => total == 0 ? 0 : (received / total).clamp(0, 1);
  int get percent => (fraction * 100).floor();
}

class DepthModelFile {
  const DepthModelFile(this.path, this.url, this.size, this.checksum);
  final String path;
  final String url;
  final int size;
  final String checksum;
}

/// Locked upstream revisions. Only validated files become active weights.
class PersonDepthModels {
  PersonDepthModels({
    this.files = defaults,
    this.clientFactory = HttpClient.new,
  });
  final List<DepthModelFile> files;
  final HttpClient Function() clientFactory;
  static const defaults = [
    DepthModelFile(
      'depth-anything-v2-large/model.safetensors',
      'https://huggingface.co/depth-anything/Depth-Anything-V2-Large-hf/resolve/7581137eff8d4e94f6e796d3baea0e9fa79b22d2/model.safetensors',
      1341322868,
      '4e01e34ed5549b529b70b92d53226bc370f03041977b390d3dde45d47f516cf9',
    ),
    DepthModelFile(
      'birefnet/model.safetensors',
      'https://huggingface.co/ZhengPeng7/BiRefNet/resolve/e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4/model.safetensors',
      444473596,
      '9ab37426bf4de0567af6b5d21b16151357149139362e6e8992021b8ce356a154',
    ),
  ];

  Future<bool> _valid(File file, DepthModelFile spec) async =>
      await file.exists() &&
      await file.length() == spec.size &&
      (await sha256.bind(file.openRead()).first).toString() == spec.checksum;

  Future<void> ensure(
    Directory componentRoot,
    void Function(DepthModelProgress) onProgress,
  ) async {
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    var completed = 0;
    for (final spec in files) {
      final target = File(p.join(componentRoot.path, 'models', spec.path));
      onProgress(DepthModelProgress('正在检查深度模型', completed, total));
      if (!await _valid(target, spec)) {
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        Object? failure;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await _download(spec, part, (received) {
              // 100% means both weights have passed integrity checks.
              final overall = (completed + received).clamp(0, total - 1);
              onProgress(
                DepthModelProgress(
                  '正在下载深度模型（首次使用需下载约 1.79 GB）',
                  overall,
                  total,
                ),
              );
            });
            onProgress(
              DepthModelProgress(
                '正在校验模型完整性',
                (completed + spec.size).clamp(0, total - 1),
                total,
              ),
            );
            if (!await _valid(part, spec)) {
              await part.delete();
              throw const FormatException('模型校验失败，正在重新下载');
            }
            // Existing invalid weights are replaced only after a valid download.
            if (await target.exists()) await target.delete();
            await part.rename(target.path);
            failure = null;
            break;
          } catch (error) {
            failure = error;
            onProgress(
              DepthModelProgress(
                '下载中断，正在重试（${attempt + 1}/3）',
                completed,
                total,
              ),
            );
          }
        }
        if (failure != null) {
          throw StateError('深度模型下载失败，已保留下载断点，请检查网络后重新提取：$failure');
        }
      }
      completed += spec.size;
    }
    onProgress(DepthModelProgress('模型已就绪，正在生成深度图', total, total));
  }

  Future<void> _download(
    DepthModelFile spec,
    File part,
    void Function(int) onBytes,
  ) async {
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > spec.size) {
      await part.delete();
      offset = 0;
    }
    if (offset == spec.size) return;
    final client = clientFactory()
      ..connectionTimeout = const Duration(seconds: 30)
      ..autoUncompress = false;
    RandomAccessFile? sink;
    try {
      final request = await client
          .getUrl(Uri.parse(spec.url))
          .timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      if (response.statusCode == HttpStatus.partialContent) {
        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        if (range != 'bytes $offset-${spec.size - 1}/${spec.size}') {
          throw const HttpException('模型服务器返回了不正确的续传范围');
        }
      } else if (response.statusCode == HttpStatus.ok) {
        offset = 0;
      } else {
        throw HttpException('HTTP ${response.statusCode}');
      }
      sink = await part.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      final throttle = Stopwatch()..start();
      onBytes(received);
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        received += chunk.length;
        if (received > spec.size) throw const FormatException('下载超过预期模型大小');
        await sink.writeFrom(chunk);
        if (throttle.elapsedMilliseconds >= 150) {
          onBytes(received);
          throttle.reset();
        }
      }
      await sink.flush();
      if (received != spec.size) throw const HttpException('模型下载尚未完整');
      onBytes(received);
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}
