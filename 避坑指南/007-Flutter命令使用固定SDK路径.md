# 007-Flutter命令使用固定SDK路径

## 问题

在本项目执行 `dart format ...` 时，PowerShell 报错：

```text
dart: The term 'dart' is not recognized as a name of a cmdlet, function, script file, or executable program.
```

原因是当前终端环境没有把 Dart/Flutter SDK 加入 PATH。

## 解决方式

项目约定 Flutter 位于 `D:\flutter`，后续执行格式化、测试、分析时优先使用固定路径：

```powershell
& 'D:\flutter\bin\dart.bat' format <files>
& 'D:\flutter\bin\flutter.bat' test <test-file>
& 'D:\flutter\bin\flutter.bat' analyze <files>
```

## 后续避免方式

- 不要假设全局 `dart` 或 `flutter` 命令可用。
- 需要运行 Flutter/Dart 命令时，直接使用 `D:\flutter\bin\dart.bat` 或 `D:\flutter\bin\flutter.bat`。
- 网络依赖解析异常时，再按项目约定检查本机代理 `本机ip:7890`，本次未遇到代理问题。
