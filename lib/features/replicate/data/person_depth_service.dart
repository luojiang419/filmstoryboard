import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

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
  });
  static final shared = PersonDepthService();
  final Directory? componentRoot;
  final Duration timeout;
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
          ).exists() &&
          await File(
            p.join(
              root.path,
              'models',
              'depth-anything-v2-large',
              'model.safetensors',
            ),
          ).exists() &&
          await File(
            p.join(root.path, 'models', 'birefnet', 'model.safetensors'),
          ).exists()) {
        return root.absolute;
      }
    }
    throw StateError(
      '高精度深度组件不完整，请运行 scripts/copy_person_depth_component.ps1 或安装完整深度组件',
    );
  }

  Future<void> _start() async {
    if (_process != null) return;
    final root = await resolveComponent();
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
        .transform(utf8.decoder)
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
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          _errors.add(line);
          if (_errors.length > 8) {
            _errors.removeAt(0);
          }
        });
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _failPending(StateError('深度推理进程退出 ($code)：${_errors.join(' | ')}'));
        }
      }),
    );
    final hello = await _request({'op': 'hello'});
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
      _process!.stdin.writeln(jsonEncode({...payload, 'id': id}));
      final response = await completer.future.timeout(timeout);
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
        await Isolate.run(
          () => createPreview(master.path, outputFile.path, width, height),
        );
        result.complete(
          PersonDepthResult(
            depthFile: outputFile,
            masterFile: master,
            width: width,
            height: height,
          ),
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _idleTimer = Timer(const Duration(minutes: 2), close);
      }
    });
    return result.future;
  }

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
