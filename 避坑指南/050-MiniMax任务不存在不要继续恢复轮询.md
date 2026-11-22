# 050-MiniMax任务不存在不要继续恢复轮询

## 问题

重启软件后，视频生成页进入“恢复查询”状态。如果本地 MiniMax 服务返回：

```text
HTTP 404 {"detail":"任务不存在"}
```

旧逻辑会把它当作普通查询异常，只更新 `errorMessage`，然后继续等待下一轮轮询，最长可能拖到 15 分钟，页面表现为一直卡在恢复查询。

## 原因

`VideoGenerationTaskService._pollExistingVideoApi()` 的通用 catch 会吞掉查询异常：

```dart
} catch (error) {
  current = current.copyWith(errorMessage: '$error');
  _upsertTask(current);
}
await _delay(pollInterval);
```

对“任务不存在”这种不可恢复的旧 generation id，继续轮询没有意义，应立即终止旧任务并重新提交对应镜头。

## 修复方式

- `MiniMaxVideoApiService.queryTask()` 对 404 抛出 `MiniMaxVideoApiTaskNotFoundException`。
- 任务服务捕获该异常后，立即把旧任务标记为 failed，不进入下一轮 delay。
- 通用 catch 增加文本兜底：同时识别 `MiniMax 视频任务不存在` 和 `任务不存在`，避免旧包装异常继续漏过。
- 控制器恢复查询后收集这类任务，调用现有 `_generate()` 自动重新提交对应镜头。

## 后续注意

不要把 404 任务不存在和临时网络错误放在同一类恢复轮询里处理：

- 网络错误：可以继续等待下一轮。
- 任务不存在：旧 generation id 已无效，应结束旧任务并重新提交。
