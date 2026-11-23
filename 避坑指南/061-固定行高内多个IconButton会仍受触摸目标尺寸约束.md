# 固定行高内多个 IconButton 会仍受触摸目标尺寸约束

## 问题

自由创作提示词单元格高度固定为 112px，右侧竖排“保存、复制、重新生成”三个 `IconButton`。即使给定 32px 约束和紧凑视觉密度，实际布局仍可受 Material 触摸目标最小尺寸影响，三个按钮累计高度超过单元格可用高度，产生 `RenderFlex overflowed by 18 pixels` 。

## 解决

- 不只依赖 `visualDensity` 和 `constraints` 压缩 `IconButton`。
- 将操作按钮组放入明确宽高的 `SizedBox`，再用 `FittedBox(fit: BoxFit.scaleDown)` 保证整组在可用高度内缩放。
- Widget 测试中不应仅检查按钮存在，还要保留渲染异常检查，以捕获固定高度下的溢出。
