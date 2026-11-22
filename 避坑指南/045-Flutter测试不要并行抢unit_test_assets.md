# 045-Flutter测试不要并行抢unit_test_assets

## 问题
并行执行多条 `flutter test` 时，多个 Flutter 进程会同时访问或清理 `build\unit_test_assets`，可能出现：

```text
Waiting for another flutter command to release the startup lock...
Flutter failed to delete a directory at "build\unit_test_assets".
```

## 原因
Flutter 测试启动阶段会准备测试资产目录。多个 `flutter test` 进程并发运行时，startup lock 和测试资产清理容易互相抢占。

## 处理方式
- Flutter 测试串行运行。
- `dart analyze`、`rg`、普通文件读取可以并行。
- 如果已经出现锁冲突，等待当前 Flutter 进程结束后重新串行执行测试。
- 不要在 PowerShell 中直接递归删除项目目录，除非已确认绝对路径在工作区内且操作符合安全策略；优先让 Flutter 工具自行处理。

## 本次验证
改为串行运行后通过：

```powershell
D:\flutter\bin\flutter.bat --no-version-check test test\features\video_generation\video_generation_controller_test.dart
D:\flutter\bin\flutter.bat --no-version-check test test\features\replicate_page_test.dart
D:\flutter\bin\flutter.bat --no-version-check test test\features\replicate_controller_test.dart
```
