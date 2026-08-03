# Flutter 测试时 sqlite3 原生资产缓存冲突

## 现象

执行 `flutter test` 或 `flutter test --no-pub` 前，Flutter 在测试编译阶段崩溃：

```text
PathExistsException: Cannot copy file to
build/native_assets/windows/sqlite3.dll
```

## 原因

Windows 原生资产安装步骤尝试复制 `sqlite3.dll`，但同路径已存在文件。失败发生在 Flutter 工具链，尚未运行任何测试用例或应用代码。

## 处理建议

1. 先确认没有正在运行的应用、Flutter 测试或 Dart 进程占用该 DLL。
2. 删除可再生缓存文件 `build/native_assets/windows/sqlite3.dll`，或清理对应 `build/native_assets` 目录。
3. 再运行 `flutter test --no-pub <测试文件>`。

## 本次影响

2026-08-03 的复刻分镜功能改动已通过 `flutter analyze`，但组件测试被该工具链错误阻断，未进入断言阶段。
