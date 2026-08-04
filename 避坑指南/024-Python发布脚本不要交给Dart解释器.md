# 024 - Python 发布脚本不要交给 Dart 解释器

## 现象

对 `scripts/next_release_version.py` 误用 `dart run` 后，终端出现大量 Dart 语法解析错误。

## 根因

文件扩展名和内容均为 Python，但命令沿用了 Flutter/Dart 工具习惯。

## 规避

- `.py` 发布脚本统一使用 `python scripts/<name>.py`。
- Flutter/Dart 命令仅用于 `.dart` 入口。
- 版本写入后立即同时核对 `pubspec.yaml`、Inno Setup 和 `AppUpdateConfig` 三处版本。
