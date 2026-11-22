# 044-Flutter测试下载engine_stamp失败时使用no-version-check

## 问题
运行：
```powershell
D:\flutter\bin\flutter.bat test test\features\video_generation\kling_cli_service_test.dart
```

曾在进入测试前失败：
```text
Failed to download https://storage.googleapis.com/flutter_infra_release/flutter//engine_stamp.json
Exception: 404
```

## 原因
这是 Flutter 工具链自身的版本/引擎信息下载检查失败，不是业务测试失败。日志里还没出现具体测试用例名称时，优先判断为工具链下载检查问题。

## 解决方法
改用：
```powershell
D:\flutter\bin\flutter.bat --no-version-check test test\features\video_generation\kling_cli_service_test.dart
```

构建也可使用：
```powershell
D:\flutter\bin\flutter.bat --no-version-check build windows --release
```

## 后续注意
- 不要因为该 404 去修改业务代码或测试断言。
- 如果使用 `--no-version-check` 后测试进入用例并失败，再按真实测试失败处理。
