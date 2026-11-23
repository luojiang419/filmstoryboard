# Flutter Windows 测试缓存与 FFmpeg 构建下载

日期：2026-08-25

## 问题一：全量测试并发导致 sqlite3.dll 冲突

### 现象

第一次全量 `flutter test --no-pub` 启动的 Dart 测试进程未及时退出，第二次测试在复制原生资源时失败：

`PathExistsException: Cannot copy file to build/native_assets/windows/sqlite3.dll (errno = 183)`。

### 处理

- 确认残留进程命令行属于 Flutter test。
- 使用 `flutter clean` 清理可再生成的 `build`、`.dart_tool` 和 ephemeral 缓存。
- 使用 `flutter pub get` 恢复依赖缓存。
- 单次重新执行测试，避免同时启动多个 Flutter 测试进程。

### 预防

测试长时间无输出时先检查 `dart`/`dartvm` 进程，不要直接并发重跑；必要时先执行 `flutter clean`。

## 问题二：Release 构建直连下载 FFmpeg 卡住

### 现象

`flutter build windows --release --no-pub` 停在 `scripts/ensure_ffmpeg_windows.ps1` 的 FFmpeg 下载步骤，临时 ZIP 长时间保持 0 字节。脚本虽配置了 `127.0.0.1:7890` 备用代理，但只有直连抛错后才切换。

### 处理

- 在本机发现 Chocolatey 已安装：`C:\ProgramData\chocolatey\lib\ffmpeg\tools\ffmpeg\bin`。
- 将其中的 `ffmpeg.exe` 和 `ffprobe.exe` 放入 `build/windows/x64/bundled_ffmpeg/bin`。
- 重新执行 Release 构建并成功生成 Windows 可执行文件。

### 预防

构建卡在下载步骤时，先检查本机是否已有 `ffmpeg.exe` 与 `ffprobe.exe`；优先复用本地工具或显式使用代理，避免重复下载大文件。

