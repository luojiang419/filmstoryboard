import 'dart:async';

import 'package:filmstoryboard/core/services/file_availability_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('未知路径立即返回 false 并在后台检查完成后通知', () async {
    final checked = Completer<bool>();
    final cache = FileAvailabilityCache(fileExists: (_) => checked.future);
    addTearDown(cache.dispose);
    var notifications = 0;
    cache.addListener(() => notifications += 1);

    expect(cache.exists('image.png'), isFalse);
    checked.complete(true);
    await Future<void>.delayed(Duration.zero);

    expect(cache.exists('image.png'), isTrue);
    expect(notifications, 1);
  });

  test('同一路径检查进行中不会重复请求文件系统', () async {
    final checked = Completer<bool>();
    var calls = 0;
    final cache = FileAvailabilityCache(
      fileExists: (_) {
        calls += 1;
        return checked.future;
      },
    );
    addTearDown(cache.dispose);

    expect(cache.exists('video.mp4'), isFalse);
    expect(cache.exists('video.mp4'), isFalse);
    expect(calls, 1);

    checked.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });

  test('缓存过期后异步刷新但先返回上次可用状态', () async {
    final results = <Completer<bool>>[Completer<bool>(), Completer<bool>()];
    var calls = 0;
    final cache = FileAvailabilityCache(
      staleAfter: Duration.zero,
      fileExists: (_) => results[calls++].future,
    );
    addTearDown(cache.dispose);

    expect(cache.exists('frame.jpg'), isFalse);
    results[0].complete(true);
    await Future<void>.delayed(Duration.zero);

    expect(cache.exists('frame.jpg'), isTrue);
    expect(calls, 2);
    results[1].complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(cache.exists('frame.jpg'), isFalse);
  });

  test('checkNow 等待已有检查并复用结果', () async {
    final checked = Completer<bool>();
    var calls = 0;
    final cache = FileAvailabilityCache(
      fileExists: (_) {
        calls += 1;
        return checked.future;
      },
    );
    addTearDown(cache.dispose);

    cache.exists('asset.webp');
    final result = cache.checkNow('asset.webp');
    checked.complete(true);

    expect(await result, isTrue);
    expect(calls, 1);
  });

  test('可为已有业务路径提供乐观首帧并在后台纠正', () async {
    final checked = Completer<bool>();
    final cache = FileAvailabilityCache(fileExists: (_) => checked.future);
    addTearDown(cache.dispose);
    var notifications = 0;
    cache.addListener(() => notifications += 1);

    expect(cache.exists('generated.mp4', defaultValue: true), isTrue);
    checked.complete(false);
    await Future<void>.delayed(Duration.zero);

    expect(cache.exists('generated.mp4', defaultValue: true), isFalse);
    expect(notifications, 1);
  });
}
