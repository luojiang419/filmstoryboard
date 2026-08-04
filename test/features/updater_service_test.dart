import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/services/app_directories.dart';
import 'package:filmstoryboard/features/updater/data/updater_service.dart';
import 'package:filmstoryboard/features/updater/domain/app_update_config.dart';
import 'package:filmstoryboard/features/updater/domain/update_models.dart';
import 'package:test/test.dart';

void main() {
  group('AppUpdateConfig', () {
    test('current version matches pubspec build and installer version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final pubspecVersion = RegExp(
        r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(pubspecVersion, isNotNull);
      final expectedVersion =
          '${pubspecVersion!.group(1)}.${pubspecVersion.group(2)}';

      final installerScript = File(
        p.join('installer', 'filmstoryboard.iss'),
      ).readAsStringSync();
      final installerVersion = RegExp(
        r'#define\s+MyAppVersion\s+"([^"]+)"',
      ).firstMatch(installerScript);
      expect(installerVersion, isNotNull);

      expect(AppUpdateConfig.currentVersion, expectedVersion);
      expect(AppUpdateConfig.currentVersionTag, 'v$expectedVersion');
      expect(installerVersion!.group(1), expectedVersion);
    });
  });

  group('UpdaterService version helpers', () {
    test('normalizeVersionTag handles v prefix and build suffix', () {
      expect(UpdaterService.normalizeVersionTag('v1.2.3'), 'v1.2.3');
      expect(UpdaterService.normalizeVersionTag('v1.2.3.4'), 'v1.2.3.4');
      expect(UpdaterService.normalizeVersionTag('1.2.3+4'), 'v1.2.3');
      expect(UpdaterService.normalizeVersionTag('1.2'), 'v1.2.0');
      expect(UpdaterService.normalizeVersionTag('broken'), isEmpty);
    });

    test('compareVersionTags orders semantic versions', () {
      expect(UpdaterService.compareVersionTags('v1.0.1', 'v1.0.0'), 1);
      expect(UpdaterService.compareVersionTags('v1.0.0.1', 'v1.0.0.0'), 1);
      expect(UpdaterService.compareVersionTags('v1.0.0', 'v1.0.0.0'), 0);
      expect(UpdaterService.compareVersionTags('1.0.0+1', 'v1.0.0'), 0);
      expect(UpdaterService.compareVersionTags('v1.0.0', 'v1.1.0'), -1);
      expect(UpdaterService.compareVersionTags('bad', 'broken'), 0);
    });

    test('expectedInstallerNames supports current and v-tag names', () {
      expect(
        UpdaterService.expectedInstallerNames('v1.2.3', platformKey: 'windows'),
        ['filmstoryboard-Setup-v1.2.3.exe', 'filmstoryboard-Setup-1.2.3.exe'],
      );
      expect(
        UpdaterService.expectedInstallerNames(
          'v1.2.3.4',
          platformKey: 'windows',
        ),
        [
          'filmstoryboard-Setup-v1.2.3.4.exe',
          'filmstoryboard-Setup-1.2.3.4.exe',
        ],
      );
    });

    test('latestReleaseApiUrlForSource accepts public repository sources', () {
      expect(
        UpdaterService.latestReleaseApiUrlForSource('owner/storyboard'),
        'https://api.github.com/repos/owner/storyboard/releases/latest',
      );
      expect(
        UpdaterService.latestReleaseApiUrlForSource(
          'https://github.com/owner/storyboard',
        ),
        'https://api.github.com/repos/owner/storyboard/releases/latest',
      );
      expect(
        UpdaterService.latestReleaseApiUrlForSource(
          'https://github.com/owner/storyboard/releases/latest',
        ),
        'https://api.github.com/repos/owner/storyboard/releases/latest',
      );
      expect(
        UpdaterService.latestReleaseApiUrlForSource(
          'https://api.github.com/repos/owner/storyboard/releases/latest',
        ),
        'https://api.github.com/repos/owner/storyboard/releases/latest',
      );
      expect(
        UpdaterService.latestReleaseApiUrlForSource('https://example.com/repo'),
        isEmpty,
      );
    });
  });

  group('UpdaterService release parser', () {
    test('parseLatestRelease returns v-tag installer asset', () {
      const payload = '''
      {
        "tag_name": "v1.2.3",
        "assets": [
          {
            "name": "filmstoryboard-Setup-v1.2.3.exe",
            "browser_download_url": "https://example.com/setup.exe",
            "size": 123456
          }
        ]
      }
      ''';

      final release = UpdaterService.parseLatestRelease(
        payload,
        platformKey: 'windows',
      );

      expect(release.versionTag, 'v1.2.3');
      expect(release.installerName, 'filmstoryboard-Setup-v1.2.3.exe');
      expect(release.installerUrl, 'https://example.com/setup.exe');
      expect(release.installerSize, 123456);
    });

    test('parseLatestRelease accepts existing no-v installer naming', () {
      const payload = '''
      {
        "tag_name": "v1.2.3",
        "assets": [
          {
            "name": "filmstoryboard-Setup-1.2.3.exe",
            "browser_download_url": "https://example.com/setup.exe",
            "size": 456
          }
        ]
      }
      ''';

      final release = UpdaterService.parseLatestRelease(
        payload,
        platformKey: 'windows',
      );

      expect(release.installerName, 'filmstoryboard-Setup-1.2.3.exe');
      expect(release.installerSize, 456);
    });

    test('parseLatestRelease accepts four-part installer naming', () {
      const payload = '''
      {
        "tag_name": "v1.2.3.4",
        "assets": [
          {
            "name": "filmstoryboard-Setup-1.2.3.4.exe",
            "browser_download_url": "https://example.com/setup.exe",
            "size": 789
          }
        ]
      }
      ''';

      final release = UpdaterService.parseLatestRelease(
        payload,
        platformKey: 'windows',
      );

      expect(release.versionTag, 'v1.2.3.4');
      expect(release.installerName, 'filmstoryboard-Setup-1.2.3.4.exe');
      expect(release.installerSize, 789);
    });

    test('parseLatestRelease rejects missing installer asset', () {
      const payload = '''
      {
        "tag_name": "v1.2.3",
        "assets": [
          {
            "name": "README.txt",
            "browser_download_url": "https://example.com/readme.txt",
            "size": 1
          }
        ]
      }
      ''';

      expect(
        () =>
            UpdaterService.parseLatestRelease(payload, platformKey: 'windows'),
        throwsA(isA<UpdateException>()),
      );
    });

    test('parseLatestRelease rejects invalid payload', () {
      expect(
        () => UpdaterService.parseLatestRelease('not-json'),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('UpdaterService proxy helpers', () {
    test('normalizedProxyUrl adds http scheme and rejects invalid values', () {
      expect(
        UpdaterService.normalizedProxyUrl('127.0.0.1:7890'),
        'http://127.0.0.1:7890',
      );
      expect(
        UpdaterService.normalizedProxyUrl('socks5://localhost:1080'),
        'socks5://localhost:1080',
      );
      expect(UpdaterService.normalizedProxyUrl('127.0.0.1'), isEmpty);
      expect(UpdaterService.normalizedProxyUrl('ftp://127.0.0.1:21'), isEmpty);
    });

    test('proxyUrlsForEnvironment reads common variables', () {
      final urls = UpdaterService.proxyUrlsForEnvironment({
        'HTTPS_PROXY': '127.0.0.1:7890',
        'ALL_PROXY': 'socks5://localhost:1080',
      });

      expect(urls, contains('http://127.0.0.1:7890'));
      expect(urls, contains('socks5://localhost:1080'));
    });

    test('localProxyCandidates contains common ports', () {
      final urls = UpdaterService.localProxyCandidates(hosts: ['127.0.0.1']);

      expect(urls, contains('http://127.0.0.1:7890'));
      expect(urls, contains('http://127.0.0.1:10809'));
      expect(urls, contains('socks5://127.0.0.1:1080'));
    });

    test('latestReleaseStatusMessage handles no release', () {
      expect(
        UpdaterService.latestReleaseStatusMessage(404, 'Not Found'),
        '当前仓库还没有可用的发布版本。',
      );
      expect(
        UpdaterService.latestReleaseStatusMessage(500, 'Server Error'),
        '检查更新失败：Server Error',
      );
    });
  });

  group('UpdaterService update session arguments', () {
    test(
      'parseInstallSessionArgs returns install session from launcher args',
      () {
        final session = UpdaterService.parseInstallSessionArgs([
          '${AppUpdateConfig.updaterSessionArg}session-1',
          '${AppUpdateConfig.updaterVersionArg}1.2.3.4',
          '${AppUpdateConfig.updaterInstallerArg}C:\\Temp\\setup.exe',
          '${AppUpdateConfig.updaterInstallRootArg}C:\\Program Files\\Storyboard',
          '${AppUpdateConfig.updaterOldPidArg}42',
        ]);

        expect(session, isNotNull);
        expect(session!.sessionId, 'session-1');
        expect(session.versionTag, 'v1.2.3.4');
        expect(session.installerPath, 'C:\\Temp\\setup.exe');
        expect(session.installRoot, 'C:\\Program Files\\Storyboard');
        expect(session.oldProcessId, 42);
      },
    );

    test('parseInstallSessionArgs ignores normal app startup args', () {
      expect(UpdaterService.parseInstallSessionArgs(const []), isNull);
      expect(
        UpdaterService.parseInstallSessionArgs([
          '${AppUpdateConfig.updaterSessionArg}session-1',
        ]),
        isNull,
      );
    });
  });

  group('UpdaterService installer launcher', () {
    test('launchInstaller stages and starts visual updater window', () async {
      if (!Platform.isWindows) {
        return;
      }

      final root = await Directory.systemTemp.createTemp(
        'storyboard_update_launcher_',
      );
      addTearDown(() => root.delete(recursive: true));

      final directories = await AppDirectories.create(
        executableDirectory: Directory(p.join(root.path, 'app')),
      );
      final installerFile = File(
        p.join(root.path, 'filmstoryboard-Setup-1.2.3.exe'),
      );
      await installerFile.writeAsString('installer');

      String? launchedExecutable;
      List<String>? launchedArguments;
      ProcessStartMode? launchedMode;
      bool? launchedRunInShell;

      final service = UpdaterService(
        directories: directories,
        scriptRootDirectory: root,
        processLauncher:
            (
              executable,
              arguments, {
              mode = ProcessStartMode.normal,
              runInShell = false,
            }) async {
              launchedExecutable = executable;
              launchedArguments = List<String>.from(arguments);
              launchedMode = mode;
              launchedRunInShell = runInShell;
              return 12345;
            },
      );

      final launched = await service.launchInstaller(
        versionTag: 'v1.2.3',
        installerPath: installerFile.path,
      );

      expect(launched, isTrue);
      expect(launchedExecutable, isNotNull);
      expect(
        p.basename(launchedExecutable!),
        p.basename(Platform.resolvedExecutable),
      );
      expect(
        launchedExecutable,
        contains('${p.separator}staging${p.separator}'),
      );
      expect(File(launchedExecutable!).existsSync(), isTrue);
      expect(launchedMode, ProcessStartMode.detached);
      expect(launchedRunInShell, isFalse);
      expect(launchedArguments, isNotNull);

      final session = UpdaterService.parseInstallSessionArgs(
        launchedArguments!,
      );
      expect(session, isNotNull);
      expect(session!.versionTag, 'v1.2.3');
      expect(session.installerPath, installerFile.path);
      expect(
        session.installRoot,
        File(Platform.resolvedExecutable).parent.path,
      );
      expect(session.oldProcessId, pid);
    });
  });

  group('UpdaterState', () {
    test('copyWith accepts integer download progress values', () {
      final checking = const UpdaterState.initial().copyWith(
        downloadProgress: 0,
      );

      expect(checking.downloadProgress, 0.0);
      expect(checking.downloadProgress, isA<double>());

      final ready = checking.copyWith(downloadProgress: 1);

      expect(ready.downloadProgress, 1.0);
      expect(ready.downloadProgress, isA<double>());
      expect(ready.copyWith(downloadProgress: null).downloadProgress, isNull);
    });
  });
}
