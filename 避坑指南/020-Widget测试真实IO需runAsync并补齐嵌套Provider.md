# 020 - Widget 测试真实 IO 需 runAsync 并补齐嵌套 Provider

## 问题

新增 `ShootingScriptPage` widget 测试时，直接在 `testWidgets` fake async 环境里创建临时目录、初始化 SQLite 和项目目录，测试会卡住直到外层命令超时。

## 表现

- `flutter test test/features/shooting_script_page_test.dart` 长时间无输出。
- 将异常放到 IO 之后不会触发，将异常放到 IO 前才会快速失败。
- 改成 `tester.runAsync()` 后测试能继续执行。

## 处理方式

- 在 `testWidgets` 中执行真实文件系统或数据库 IO 时，用 `await tester.runAsync(() async { ... })` 包住 fixture 创建。
- 如果页面内部嵌套其他 Consumer 页面，例如 `ShootingScriptPage` 内嵌 `ReplicatePage`，必须把嵌套页面读取的 provider 也完整 override。
- 本次缺失 `scriptAssetBindingControllerProvider`，导致嵌套页回落到全局数据库 provider，并报 `全局数据库尚未初始化`。

## 后续注意

遇到 widget 测试无输出超时，先排查真实 IO 是否在 fake async 内执行，再排查嵌套 Consumer 是否有遗漏 provider override。
