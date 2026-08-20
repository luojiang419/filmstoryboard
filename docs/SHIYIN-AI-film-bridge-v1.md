# SHIYIN-AI → filmstoryboard 桥接契约 v1

本文件与 `E:\APP\SHIYIN-AI\开发文档\SHIYIN-AI-filmstoryboard-桥接方案-v1.md` 配套。

## 导入目标

filmstoryboard 不直接读取 SHIYIN-AI 的数据库。导入器读取 `.shiyinbridge.zip`，解压到当前工程的桥接缓存目录，将每帧转换为 `StoryboardExternalImage`，再调用现有：

```dart
StoryboardController.createOrReplaceBoardFromExternalImages(
  sourceId: manifest.bridgeId,
  boardName: manifest.storyboard.boardName,
  images: selectedVariantImages,
  preserveExistingCaptions: true,
);
```

拍摄脚本同步复用：

```dart
ShootingScriptController.createFromStoryboard(board);
ShootingScriptController.syncFromStoryboard(board, previousBoard: oldBoard);
```

## 包格式

```text
manifest.json
images/original/001.png
images/expanded-16x9/001.png
images/line-art/001.png
preview/contact-sheet.png
checksums.json
```

manifest 必须包含：

- `schema: "shiyin-film-bridge"`
- `schema_version: 1`
- 固定的 `bridge_id`
- `source`（SHIYIN 画布、GROUP、抽帧运行信息）
- `storyboard.frames[]`（stable_id、slot_index、相对路径、宽高、时间戳、变体）
- 可选 `script_seed.shots[]`

## 幂等规则

- `bridge_id` 映射到 `external-board:<sourceId>`，重复导入更新同一故事板。
- `stable_id` 不因变体切换改变，保证脚本关联稳定。
- 默认保留已有 caption 和脚本手工字段。
- 文件导入前校验 SHA-256、路径穿越和支持的图片格式。

## 实施阶段

1. 标准包文件选择导入（离线、可回滚）。
2. 变体选择与拍摄脚本同步。
3. 仅监听 `127.0.0.1` 的一次性 token Loopback 自动导入；失败自动回退标准包。
