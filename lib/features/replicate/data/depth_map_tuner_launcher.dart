import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/app_directories.dart';
import '../../settings/domain/app_settings.dart';
import 'depth_map_configuration.dart';

class DepthMapTunerLauncher {
  const DepthMapTunerLauncher();

  Future<void> launch({
    required AppDirectories directories,
    required DepthProcessingMode mode,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('深度图调参插件仅支持 Windows 桌面端');
    }
    final executable = await _resolveExecutable(directories);
    final componentRoot = await _resolveComponentRoot(directories);
    final configFile = File(
      p.join(directories.data.path, 'depth-map', 'depth-map-config.json'),
    );
    await configFile.parent.create(recursive: true);
    final process = await Process.start(
      executable.path,
      [
        '--mode',
        mode.name,
        '--config-path',
        configFile.path,
        '--component-root',
        componentRoot.path,
      ],
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.detached,
    );
    if (process.pid <= 0) {
      throw StateError('深度图调参插件启动失败');
    }
  }

  Future<File> _resolveExecutable(AppDirectories directories) async {
    final name = 'SHIYIN-Depth-Tuner.exe';
    final candidates = [
      File(
        p.join(
          directories.executableDirectory.path,
          'data',
          'plugins',
          'depth-map-tuner',
          name,
        ),
      ),
      File(
        p.join(
          directories.executableDirectory.path,
          'data',
          'flutter_assets',
          'plugins',
          'depth-map-tuner',
          'bin',
          name,
        ),
      ),
      File(
        p.join(
          Directory.current.path,
          'plugins',
          'depth-map-tuner',
          'bin',
          name,
        ),
      ),
      File(
        p.join(
          Directory.current.path,
          'tools',
          'depth-map-tuner',
          'src-tauri',
          'target',
          'release',
          name,
        ),
      ),
    ];
    for (final candidate in candidates) {
      if (await candidate.exists()) return candidate.absolute;
    }
    throw StateError('未找到深度图调参插件，请重新安装当前版本软件');
  }

  Future<Directory> _resolveComponentRoot(AppDirectories directories) async {
    final candidates = [
      Directory(
        p.join(directories.executableDirectory.path, 'data', 'person-depth'),
      ),
      Directory(
        p.join(Directory.current.path, 'local_components', 'person-depth'),
      ),
    ];
    for (final candidate in candidates) {
      if (await File(
        p.join(candidate.path, 'runtime', 'person-depth-worker.exe'),
      ).exists()) {
        return candidate.absolute;
      }
    }
    throw StateError('未找到深度运行组件，请先在主软件中提取一次深度图');
  }

  File configurationFile(AppDirectories directories) =>
      File(p.join(directories.data.path, 'depth-map', 'depth-map-config.json'));

  DepthMapConfigurationStore configurationStore(AppDirectories directories) =>
      DepthMapConfigurationStore(configurationFile(directories));
}
