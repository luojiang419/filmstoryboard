import 'dart:io';

import 'package:filmstoryboard/features/video_generation/data/cli_dependency_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('可灵中国区和海外区只执行各自官方 npm 安装命令', () async {
    final calls = <(String, List<String>, bool)>[];
    final installer = CliDependencyInstaller(
      processRunner: (executable, arguments, {required runInShell}) async {
        calls.add((executable, arguments, runInShell));
        return ProcessResult(1, 0, 'installed', '');
      },
    );

    await installer.installKling(
      region: KlingCliInstallRegion.china,
      npmPath: r'C:\Program Files\nodejs\npm.cmd',
    );
    await installer.installKling(
      region: KlingCliInstallRegion.global,
      npmPath: r'C:\Program Files\nodejs\npm.cmd',
    );

    expect(calls, hasLength(2));
    expect(calls.first.$2, [
      'install',
      '--global',
      '@klingai/cli-cn',
      '--registry=https://registry.npmjs.org',
    ]);
    expect(calls.last.$2, contains('@klingai/cli-global'));
    expect(calls.last.$2, isNot(contains('@klingai/cli-cn')));
  });

  test('Node.js 自动安装使用固定 winget LTS 包且关闭交互', () async {
    if (!Platform.isWindows) return;
    late String executable;
    late List<String> arguments;
    final installer = CliDependencyInstaller(
      processRunner: (command, args, {required runInShell}) async {
        executable = command;
        arguments = args;
        return ProcessResult(1, 0, '', '');
      },
    );

    await installer.installNodeJsLts();

    expect(executable, 'winget.exe');
    expect(arguments, containsAll(['--id', 'OpenJS.NodeJS.LTS', '--silent']));
    expect(arguments, contains('--disable-interactivity'));
  });

  test('LibTV 自动安装只执行随包内置的官方 PowerShell 脚本', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('libtv-installer-test-');
    addTearDown(() => root.delete(recursive: true));
    final script = await File(
      '${root.path}${Platform.pathSeparator}install-libtv-cli.ps1',
    ).writeAsString('# official bundled installer');
    late String executable;
    late List<String> arguments;
    final installer = CliDependencyInstaller(
      libTvInstallerPath: script.path,
      processRunner: (command, args, {required runInShell}) async {
        executable = command;
        arguments = args;
        return ProcessResult(1, 0, '', '');
      },
    );

    await installer.installLibTv();

    expect(executable, 'powershell.exe');
    expect(arguments, containsAllInOrder(['-ExecutionPolicy', 'Bypass']));
    expect(arguments, containsAllInOrder(['-File', script.path]));
  });

  test('安装命令失败时保留可读错误且不会报告成功', () async {
    final installer = CliDependencyInstaller(
      processRunner: (command, args, {required runInShell}) async =>
          ProcessResult(1, 7, '', 'registry unavailable'),
    );

    await expectLater(
      installer.installKling(
        region: KlingCliInstallRegion.china,
        npmPath: 'npm',
      ),
      throwsA(
        isA<CliDependencyInstallException>()
            .having((error) => error.exitCode, 'exitCode', 7)
            .having(
              (error) => error.message,
              'message',
              contains('registry unavailable'),
            ),
      ),
    );
  });
}
