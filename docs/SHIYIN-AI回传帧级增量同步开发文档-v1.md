# SHIYIN-AI 回传 filmstoryboard 帧级增量同步开发文档 v1

## 任务目标

同一 `bridge_id` 的 SHIYIN-AI 故事板再次回传时，filmstoryboard 只更新变化的分镜资源，不再先删除该外部故事板的全部 `cut_results` 后整批重建。故事板 ID、资源 ID、用户编辑的拍摄脚本字段及未变化资源路径保持稳定。

## 模块拆分

1. 桥接图片内容寻址：导入文件名由序号改为 `frame stable_id hash + SHA-256`；相同内容复用同一文件，变化内容产生新路径。
2. 数据库局部写入：增加 cut result 的选择性更新能力；只插入新增资源、更新路径/序号/尺寸发生变化的资源、删除缺失资源。
3. 故事板合并：`createOrReplaceBoardFromExternalImages` 保留同一 asset ID 与既有板参数，只重组新增/删除/重排后的 items。
4. 安全清理：故事板成功同步后删除当前 bridge/variant 目录中不再引用的旧内容寻址文件；失败时保留旧文件以便回滚。
5. 脚本合并：继续复用 `applyBridgeShots` 的“传入非空字段更新、未传字段保留”语义。

## 文件清单

- `lib/features/bridge/data/bridge_package_service.dart`
- `lib/core/database/app_database.dart`
- `lib/features/storyboard/application/storyboard_controller.dart`
- `lib/features/storyboard/presentation/storyboard_page.dart`
- `test/features/bridge/bridge_package_service_test.dart`
- `test/features/video_storyboard_bridge_test.dart`
- 版本、快照、备份和避坑文档

## 验收标准

- 同一回传包连续接收两次：同一 board/asset ID，未变化图片路径与数据库 `created_at` 不变。
- 只修改第 N 帧：仅第 N 帧资源路径改变，其他帧路径与 `created_at` 不变。
- 新增/删除帧：只增删对应 `cut_result`；故事板其余资源仍可访问。
- 已修改的拍摄脚本人工字段不会因桥接包省略字段而清空。
- Flutter 全量测试、`flutter analyze` 和 Windows release 构建通过。

## 待办清单

- [x] 内容寻址落盘与旧文件候选列表。
- [x] cut result 选择性数据库合并。
- [x] 页面成功后安全清理与同步结果提示。
- [x] 增量回归测试。
- [ ] 版本 +330、快照、备份、全量验收与 GitHub 推送。
