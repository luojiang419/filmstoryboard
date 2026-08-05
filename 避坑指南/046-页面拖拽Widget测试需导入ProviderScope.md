# 046-页面拖拽Widget测试需导入ProviderScope

## 问题
新增视频解析页拖拽导入 widget 测试时，测试通过 `ProviderScope` 覆盖 Riverpod provider，但测试文件只导入了业务 provider 和 Flutter 测试包，导致编译失败：

```text
Error: Method not found: 'ProviderScope'.
```

## 原因
`ProviderScope` 来自 `package:flutter_riverpod/flutter_riverpod.dart`，不会被业务 provider 文件间接导出。

## 解决方式
页面 widget 测试只要使用 `ProviderScope`，必须显式导入：

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
```

## 后续避开
- 新增 Flutter + Riverpod 页面测试时，先检查测试文件是否同时包含：
  - `package:flutter_test/flutter_test.dart`
  - `package:flutter_riverpod/flutter_riverpod.dart`
- 如果测试需要模拟拖放，还要导入：
  - `package:desktop_drop/desktop_drop.dart`
