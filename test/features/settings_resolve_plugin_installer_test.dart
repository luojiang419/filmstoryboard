import 'dart:io';

import 'package:filmstoryboard/features/settings/data/resolve_plugin_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'resolve-plugin-installer-test-',
    );
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('从软件 data 内置包调用 PowerShell 并请求脚本自提权', () async {
    final bundleRoot = await _createBundle(root);
    late String executable;
    late List<String> arguments;
    late bool capturedRunInShell;
    final installer = ResolvePluginInstaller(
      bundleRoot: bundleRoot.path,
      platformIsWindows: true,
      processRunner: (command, args, {required bool runInShell}) async {
        executable = command;
        arguments = args;
        capturedRunInShell = runInShell;
        return ProcessResult(1, 0, '', '');
      },
    );

    final result = await installer.install();

    expect(executable, 'powershell.exe');
    expect(capturedRunInShell, isFalse);
    expect(
      arguments,
      containsAllInOrder([
        '-File',
        p.join(
          bundleRoot.path,
          'windows',
          ResolvePluginInstaller.installScriptName,
        ),
        '-PluginSource',
        p.join(bundleRoot.path, ResolvePluginInstaller.pluginDirectoryName),
        '-ElevateIfNeeded',
      ]),
    );
    expect(result.bundleRoot, p.normalize(bundleRoot.path));
    expect(result.message, contains('文件已复制'));
  });

  test('data 内置插件包缺失时不启动任何外部进程', () async {
    var called = false;
    final installer = ResolvePluginInstaller(
      bundleRoot: p.join(root.path, 'missing'),
      platformIsWindows: true,
      processRunner: (command, args, {required bool runInShell}) async {
        called = true;
        return ProcessResult(1, 0, '', '');
      },
    );

    await expectLater(
      installer.install(),
      throwsA(
        isA<ResolvePluginInstallException>().having(
          (error) => error.message,
          'message',
          contains('插件包不完整'),
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('PowerShell 失败时保留退出码和可读错误', () async {
    final bundleRoot = await _createBundle(root);
    late String errorLogPath;
    final installer = ResolvePluginInstaller(
      bundleRoot: bundleRoot.path,
      platformIsWindows: true,
      processRunner: (command, args, {required bool runInShell}) async {
        final errorLogIndex = args.indexOf('-ErrorLogPath');
        errorLogPath = args[errorLogIndex + 1];
        await File(errorLogPath).writeAsString('\uFEFF清单 XML 实际错误');
        return ProcessResult(1, 7, '', 'generic failure');
      },
    );

    await expectLater(
      installer.install(),
      throwsA(
        isA<ResolvePluginInstallException>()
            .having((error) => error.exitCode, 'exitCode', 7)
            .having(
              (error) => error.message,
              'message',
              contains('清单 XML 实际错误'),
            ),
      ),
    );
    expect(File(errorLogPath).existsSync(), isFalse);
  });
}

Future<Directory> _createBundle(Directory root) async {
  final bundleRoot = Directory(p.join(root.path, 'data', 'resolve_plugin'));
  final windows = Directory(p.join(bundleRoot.path, 'windows'));
  final plugin = Directory(
    p.join(bundleRoot.path, ResolvePluginInstaller.pluginDirectoryName),
  );
  await windows.create(recursive: true);
  await plugin.create(recursive: true);
  await File(
    p.join(windows.path, ResolvePluginInstaller.installScriptName),
  ).writeAsString('# test installer');
  await File(p.join(plugin.path, 'manifest.xml')).writeAsString('<Plugin/>');
  await File(p.join(plugin.path, 'package.json')).writeAsString('{}');
  await File(p.join(plugin.path, 'main.js')).writeAsString('');
  return bundleRoot;
}
