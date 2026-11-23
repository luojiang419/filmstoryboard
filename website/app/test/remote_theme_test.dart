import 'dart:io';

import 'package:filmstoryboard_remote_web/core/theme/remote_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('远程 Web 主题使用随包分发的中文字体和许可证', () async {
    final font = await rootBundle.load('assets/fonts/NotoSansSC-Regular.otf');
    final license = await rootBundle.loadString('assets/fonts/OFL.txt');
    final robotoLicense = await rootBundle.loadString(
      'assets/fonts/fallback/Roboto-OFL.txt',
    );
    final theme = RemoteTheme.dark();

    expect(font.lengthInBytes, greaterThan(7 * 1024 * 1024));
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(
      robotoLicense,
      contains('Copyright 2011 The Roboto Project Authors'),
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, 'NotoSansSC');
    expect(theme.textTheme.titleLarge?.fontFamily, 'NotoSansSC');
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, isNull);
  });

  test('引擎回退字体子集全部随包分发', () async {
    const fallbackAssets = [
      'assets/fonts/fallback/roboto/v32/'
          'KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2',
      'assets/fonts/fallback/notosanssc/v37/'
          'k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.115.woff2',
      'assets/fonts/fallback/notosanssc/v37/'
          'k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.117.woff2',
      'assets/fonts/fallback/notosanssc/v37/'
          'k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.118.woff2',
    ];

    for (final asset in fallbackAssets) {
      expect((await rootBundle.load(asset)).lengthInBytes, greaterThan(1000));
    }
  });

  test('CanvasKit 强制使用随包分发的本地资源', () async {
    final bootstrap = await File('web/flutter_bootstrap.js').readAsString();
    final index = await File('web/index.html').readAsString();
    final pubspec = await File('pubspec.yaml').readAsString();
    final buildNumber = RegExp(
      r'^version:\s*[^+\r\n]+\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1)!;

    expect(bootstrap, contains("canvasKitBaseUrl: 'canvaskit'"));
    expect(
      bootstrap,
      contains("fontFallbackBaseUrl: 'assets/assets/fonts/fallback/'"),
    );
    expect(bootstrap, isNot(contains('www.gstatic.com')));
    expect(index, contains('flutter_bootstrap.js?v=$buildNumber'));
  });
}
