# 052-可灵CLI提交前过滤本地API私有参数

## 问题

可灵 CLI 登录授权、账号读取都正常，但视频生成任务在应用里显示 `failed`。失败日志看起来停在：

```text
[kling] Uploading local file: ...
```

容易误判为图片上传失败或授权失败。

## 实际原因

这类日志需要继续看完整错误尾部。本次完整错误显示：

```text
未知参数 --minimax_api_aspect_ratio。模型 kling-video-v3_0_omni 声明的生成参数：prompt, duration, aspect_ratio, resolution, imageCount, prefer_multi_shots, enable_audio
```

说明可灵 CLI 已经成功上传本地图片，但应用把本地 MiniMax/H3 的私有参数一起传给了可灵 CLI：

```text
--minimax_api_aspect_ratio
--minimax_api_resolution
--minimax_api_steps
```

可灵模型不认识这些参数，所以拒绝提交，未返回 `generationId`。

## 避免方式

- 可灵 CLI 提交前必须按 `kling who_am_i --quiet` 返回的当前模型 `arguments` 做白名单过滤。
- `prompt` 与 `duration` 可由提交服务独立处理，不应从配置参数中透传。
- `minimax_api_*` 只能用于本地视频 API UI/提交，不允许进入可灵 CLI 命令行。

## 排查顺序

1. 先跑 `kling who_am_i --quiet` 和 `kling account --quiet`，确认授权与账号正常。
2. 查 `video_generation_tasks.error_message` 的完整内容，不要只看 UI 红条截断文本。
3. 如果看到 `Uploaded -> https://...`，代表上传阶段已过，继续看最后一行提交错误。
4. 如果最后是 `未知参数 --xxx`，优先检查应用参数过滤，而不是重登账号或重装 CLI。

## 本次修复位置

- `G:\data\app\film\filmstoryboard\lib\features\video_generation\application\video_generation_controller.dart`
- `G:\data\app\film\filmstoryboard\test\features\video_generation\video_generation_controller_test.dart`
