# 053-本地H3资产图需贯穿控制器任务服务和multipart

## 问题

本地 H3/MiniMax 视频 API 修复资产图提交时，不能只改 `MiniMaxVideoApiService` 支持多张 `reference_images`。如果 `VideoGenerationTaskService` 的本地 API 分支没有把 `VideoGenerationSubmission.referenceImagePaths` 继续传下去，最终 multipart 仍然只有首帧/复刻帧 1 张图。

## 正确做法

- 控制器负责收集当前镜头已确认资产图，并写入 `VideoGenerationSubmission.referenceImagePaths`。
- 任务编排层两个分支都要核对：
  - 可灵 CLI 分支：传给 `KlingCliService.submitImageToVideo(referenceImagePaths: ...)`。
  - 本地 API 分支：传给 `MiniMaxVideoApiService.submitImageToVideo(referenceImagePaths: ...)`。
- 服务层在 `mode=references` 下要重复添加 multipart 字段 `reference_images`，第一张是首帧/复刻帧，后续是资产图。
- 测试 multipart 中文提示词时，原始请求体要用 `utf8.decode(..., allowMalformed: true)`；用 `latin1.decode` 会把 `@图片2` 等中文断言变成乱码。

## 避免再次踩坑

- 增加控制器集成测试，不只测服务层：必须断言本地 API 请求体里 `reference_images` 出现 2 次以上，并且 prompt 包含 `@图片2` 资产说明。
- 首尾帧模式不要直接切到 `references`，否则会丢失 H3 关键帧锁定能力。当前本地后端 `mode=keyframes` 只消费 `first_frame` 和 `last_frame`；如要支持首尾帧加资产图，需要同步改后端 H3 workflow。
- 异步初始化测试切换 API 时，控制器 dispose 后后台初始化可能回写状态；长异步 await 后必须检查 `_disposed`。
