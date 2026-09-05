import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import 'person_depth_models.dart';

class PersonDepthResult {
  const PersonDepthResult({
    required this.depthFile,
    required this.masterFile,
    required this.width,
    required this.height,
  });
  final File depthFile;
  final File masterFile;
  final int width;
  final int height;
}

/// SHIYIN-AI candidate.3 NDJSON protocol. One shared, serialized GPU worker.
class PersonDepthService {
  PersonDepthService({
    this.componentRoot,
    this.timeout = const Duration(minutes: 10),
    PersonDepthModels? models,
  }) : _models = models ?? PersonDepthModels();
  static final shared = PersonDepthService();
  final Directory? componentRoot;
  final Duration timeout;
  final PersonDepthModels _models;
  final modelProgress = ValueNotifier<DepthModelProgress?>(null);
  File? _logFile;
  Future<void> _logQueue = Future<void>.value();
  Process? _process;
  Future<void> _queue = Future<void>.value();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _errors = <String>[];
  Timer? _idleTimer;
  int _sequence = 0;

  Future<Directory> resolveComponent() async {
    final candidates = componentRoot != null
        ? [componentRoot!]
        : [
            Directory(
              p.join(
                p.dirname(Platform.resolvedExecutable),
                'data',
                'person-depth',
              ),
            ),
            Directory(
              p.join(
                Directory.current.path,
                'local_components',
                'person-depth',
              ),
            ),
          ];
    for (final root in candidates) {
      if (await File(
        p.join(root.path, 'runtime', 'person-depth-worker.exe'),
      ).exists()) {
        return root.absolute;
      }
    }
    throw StateError('未找到深度运行组件，请重新安装当前版本软件');
  }

  Future<void> _start() async {
    if (_process != null) return;
    final root = await resolveComponent();
    _logFile = File(p.join(root.parent.path, 'logs', 'person_depth.jsonl'));
    _log('prepare', {'componentRoot': root.path});
    await _models.ensure(root, (progress) => modelProgress.value = progress);
    final process = await Process.start(
      p.join(root.path, 'runtime', 'person-depth-worker.exe'),
      ['--component-root', root.path, '--stdio'],
      workingDirectory: root.path,
      environment: {'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'},
      mode: ProcessStartMode.normal,
    );
    _process = process;
    _errors.clear();
    process.stdout
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final response = jsonDecode(line);
            if (response is Map<String, dynamic>) {
              _pending.remove('${response['id']}')?.complete(response);
            }
          } on FormatException {
            /* Runtime diagnostics are not protocol responses. */
          }
        }, onError: (Object error) => _failPending(error));
    process.stderr
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _errors.add(line);
            _log('stderr', {'message': line});
            if (_errors.length > 8) {
              _errors.removeAt(0);
            }
          },
          onError: (Object error) => _log('stderr_error', {'error': '$error'}),
        );
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _failPending(StateError('深度推理进程退出 ($code)：${_errors.join(' | ')}'));
        }
      }),
    );
    final hello = await _request({'op': 'hello'});
    _log('hello', hello);
    if (hello['protocol_version'] != 1) {
      close();
      throw StateError('深度组件协议版本不兼容');
    }
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> payload) async {
    final id = '${++_sequence}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _log('request', {'id': id, ...payload});
      _process!.stdin.writeln(encodeRequest({...payload, 'id': id}));
      await _process!.stdin.flush();
      final response = await completer.future.timeout(timeout);
      _log('response', response);
      if (response['ok'] != true) {
        throw StateError('${response['error'] ?? '深度推理失败'}');
      }
      return response;
    } on TimeoutException {
      close();
      throw TimeoutException('高精度深度推理超时，可重试', timeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<PersonDepthResult> extract({
    required File imageFile,
    required File outputFile,
  }) {
    final result = Completer<PersonDepthResult>();
    _queue = _queue.then((_) async {
      _idleTimer?.cancel();
      try {
        if (!await imageFile.exists()) {
          throw FileSystemException('原帧不存在', imageFile.path);
        }
        await outputFile.parent.create(recursive: true);
        await _start();
        final ready = modelProgress.value;
        if (ready != null) {
          modelProgress.value = DepthModelProgress(
            '模型已就绪，正在生成深度图',
            ready.total,
            ready.total,
          );
        }
        final master = File(
          p.join(
            outputFile.parent.path,
            '${p.basenameWithoutExtension(outputFile.path)}-16bit.png',
          ),
        );
        final response = await _request({
          'op': 'estimate',
          'input': imageFile.absolute.path,
          'output': master.absolute.path,
          'bit_depth': 16,
        });
        final width = response['width'] as int;
        final height = response['height'] as int;
        await createPreviewAsync(master.path, outputFile.path, width, height);
        result.complete(
          PersonDepthResult(
            depthFile: outputFile,
            masterFile: master,
            width: width,
            height: height,
          ),
        );
        _log('completed', {
          'output': outputFile.path,
          'width': width,
          'height': height,
        });
        final prepared = modelProgress.value;
        if (prepared != null) {
          modelProgress.value = DepthModelProgress(
            '模型已就绪，深度图生成完成',
            prepared.total,
            prepared.total,
          );
        }
      } catch (error, stack) {
        _log('failed', {'error': '$error', 'stack': '$stack'});
        modelProgress.value = null;
        result.completeError(error, stack);
      } finally {
        _idleTimer = Timer(const Duration(minutes: 2), close);
      }
    });
    return result.future;
  }

  /// Frozen Python uses the Windows code page even with PYTHONUTF8 set.
  /// ASCII JSON preserves every Unicode path across either code page.
  static String encodeRequest(Map<String, Object?> payload) =>
      jsonEncode(payload).split('').map((character) {
        final unit = character.codeUnitAt(0);
        return unit > 127
            ? '\\u${unit.toRadixString(16).padLeft(4, '0')}'
            : character;
      }).join();

  void _log(String phase, Map<String, Object?> details) {
    final file = _logFile;
    if (file == null) return;
    _logQueue = _logQueue
        .then((_) async {
          await file.parent.create(recursive: true);
          if (await file.exists() && await file.length() > 4 * 1024 * 1024) {
            await file.rename('${file.path}.previous');
          }
          await file.writeAsString(
            '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'phase': phase, ...details})}\n',
            mode: FileMode.append,
          );
        })
        .catchError((Object _) {
          /* Logging cannot interrupt inference. */
        });
  }

  // Keep the closure in its own scope so the extraction queue's Completer
  // and live Process are never captured and sent to the isolate.
  static Future<void> createPreviewAsync(
    String masterPath,
    String outputPath,
    int width,
    int height,
  ) => Isolate.run(() => createPreview(masterPath, outputPath, width, height));

  static void createPreview(
    String masterPath,
    String outputPath,
    int width,
    int height,
  ) {
    final decoded = img.decodePng(File(masterPath).readAsBytesSync());
    if (decoded == null ||
        decoded.width != width ||
        decoded.height != height ||
        decoded.format != img.Format.uint16 ||
        width <= 0 ||
        height <= 0) {
      throw const FormatException('深度组件输出无效，必须为原尺寸 16-bit PNG');
    }
    File(outputPath).writeAsBytesSync(
      img.encodePng(decoded.convert(format: img.Format.uint8, numChannels: 1)),
    );
  }

  void _failPending(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(error);
      }
    }
    _pending.clear();
  }

  void close() {
    _idleTimer?.cancel();
    final process = _process;
    _process = null;
    process?.kill();
    _failPending(StateError('深度推理进程已关闭'));
  }
}
