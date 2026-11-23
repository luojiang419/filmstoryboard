# 可灵 CLI 代理、原视频 I/O 与 Flutter 原生资产缓存

记录时间：2026-08-04

## 1. npm 代理不要沿用失效的局域网地址

### 现象

`npx skills add klingai-tech/skills` 或 `npm install -g @klingai/cli-cn` 无法连接，npm 配置中残留了不可达的 `192.168.0.211:7890`。

### 处理

不要修改用户的全局 npm 配置，给当前 PowerShell 进程临时设置：

```powershell
$env:npm_config_proxy='http://127.0.0.1:7890'
$env:npm_config_https_proxy='http://127.0.0.1:7890'
```

然后再执行安装命令。这样不会污染其他项目或用户全局配置。

## 2. “原视频 3 秒”是 I/O 点播放，不是生成三秒文件

### 错误理解

用 FFmpeg 从每个镜头截出一个三秒视频文件。镜头数较多时会复制大量视频数据，造成明显磁盘浪费。

### 正确实现

- 始终复用同一个原视频文件。
- 根据焦点帧时间计算最长三秒的 `inPoint` / `outPoint`。
- 播放器打开原文件后 seek 到 I 点。
- 播放到 O 点时暂停并回到 I 点。
- 原视频不足三秒时直接使用全长。
- 只持久化时间范围和来源关联，不创建任何原视频片段目录或临时视频文件。

## 3. 新增外键后旧测试夹具必须写入父记录

`script_shots.source_video_frame_id` 引用 `video_frames(id)` 后，旧测试不能只构造内存中的 `VideoFrame`。测试必须先通过 `VideoAnalysisRepository` 写入 `source_videos`，再写入 `video_frames`，最后保存脚本镜头。不要为了兼容不完整测试而放宽生产数据库外键。

## 4. Flutter 3.38.8 测试被强制中断后会留下原生资产冲突

### 现象

测试尚未进入用例执行即崩溃：

```text
PathExistsException: Cannot copy file to build\native_assets\windows\sqlite3.dll
```

### 原因

工具超时关闭父进程后可能遗留指向本项目的 `flutter_tester.exe`，同时目标 DLL 已存在。下一次 native-assets 安装阶段使用不覆盖复制，因而报错。

### 排查与处理

1. 用 `Win32_Process.CommandLine` 核实 `flutter_tester.exe` 的 `--packages` 确实指向当前项目。
2. 只终止已核实属于当前项目的孤儿测试进程。
3. 只清理 `build\native_assets\windows` 下已确认的过期 DLL 副本，让 Flutter 重新生成。
4. 长测试命令使用可续接的长任务句柄，不要给 shell 本身设置一秒超时，否则会再次制造孤儿进程。

不要结束其他 Flutter 项目的测试进程，也不要递归删除工作区或用户目录。

