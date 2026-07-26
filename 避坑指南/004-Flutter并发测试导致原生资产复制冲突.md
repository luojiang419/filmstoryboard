# Flutter 并发测试导致原生资产复制冲突

## 现象

一个 `flutter test` 进程被外层工具终止后，后台 `dart`、`dartvm`、`dartaotruntime` 和 `flutter_tester` 子进程仍可能存活。此时再次运行测试，会出现：

```text
PathExistsException: Cannot copy file to build/native_assets/windows/sqlite3.dll
OS Error: 当文件已存在时，无法创建该文件。errno = 183
```

## 原因

两个 Flutter 测试/构建进程同时写入同一个 `build/native_assets/windows` 目录，sqlite3 原生资产复制发生竞争。该报错不是业务代码或 sqlite 数据库迁移错误。

## 处理方式

1. 先按命令行中的工程绝对路径筛选进程，只结束本次卡住测试遗留的
   `flutter_tester`/Flutter/Dart 子进程，避免影响其他工程。
2. 串行重新运行测试。多数情况下停止残留进程后即可恢复，不需要删除
   `build/native_assets`，也不需要默认执行 `flutter clean`。
3. 只有在确认没有同工程残留进程、串行重试仍复现时，才在确认当前工程路径后
   执行 `flutter clean`，清理生成的 `build` 和 `.dart_tool` 缓存后再试。

## 后续规避

- 外层命令超时可能只结束父进程，子 `flutter_tester` 仍会继续存活；终止或超时后
  必须检查带有当前工程绝对路径的相关子进程是否已退出，再重试。
- 同一工作区内 Flutter 测试、Windows 构建和 Inno Setup 打包保持串行。
- Widget 测试等待异步控制器时，应交替 `tester.pump` 与短暂真实事件循环等待，并设置有界次数，避免无限轮询掩盖真实卡点。
