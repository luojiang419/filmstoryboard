# 111 - 版本递增需同步 Pubspec 与 AppUpdateConfig

记录时间：2026-08-21

## 问题

应用版本从 `1.0.0+336` 升到 `1.0.0+337` 后，第一次全量测试发现 `AppUpdateConfig.currentVersion` 仍为 `1.0.0.336`。只修改 `pubspec.yaml` 会导致安装包版本、应用内更新版本和测试契约不一致。

## 原因

本项目的版本号同时存在于以下位置：

- `pubspec.yaml`
- `lib/features/updater/domain/app_update_config.dart`
- `installer/filmstoryboard.iss`

## 解决办法

版本递增时同步修改以上三处，并运行：

```powershell
rg -n "旧版本号" lib installer pubspec.yaml test
D:\flutter\bin\flutter.bat test --no-version-check
```

## 后续规避

- 版本调整后先全局搜索旧版本号。
- 以全量测试中的版本契约为最终校验，不只依赖单模块测试。
