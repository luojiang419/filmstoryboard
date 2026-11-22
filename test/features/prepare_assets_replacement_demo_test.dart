import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('八组合 HTML 演示包含完整路由、零视觉调用和本地图片资源', () {
    final file = File('docs/准备资产一键替换八组合演示.html');
    expect(file.existsSync(), isTrue);
    final html = file.readAsStringSync();

    for (final route in const [
      'm: false, p: false, s: false',
      'm: true,  p: false, s: false',
      'm: false, p: true,  s: false',
      'm: false, p: false, s: true',
      'm: true,  p: true,  s: false',
      'm: true,  p: false, s: true',
      'm: false, p: true,  s: true',
      'm: true,  p: true,  s: true',
    ]) {
      expect(html, contains(route));
    }
    expect(html, contains('视觉模型 0 次'));
    expect(html, contains('图片生成 1 次'));
    expect(html, contains('任何没有绑定资产的对应格子都完整保留图片1内容'));
    expect(html, contains('完整组合提示词'));
    expect(html, isNot(contains('fetch(')));
    expect(html, isNot(contains('http://')));
    expect(html, isNot(contains('https://')));

    for (final asset in const [
      'natural_cinema.jpg',
      'forest_warmth.jpg',
      'blue_gold_twilight.jpg',
      'tungsten_night.jpg',
    ]) {
      expect(File('assets/color_style_thumbnails/$asset').existsSync(), isTrue);
      expect(html, contains('../assets/color_style_thumbnails/$asset'));
    }
  });
}
