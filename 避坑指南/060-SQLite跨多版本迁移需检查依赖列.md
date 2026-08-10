# SQLite 跨多版本迁移需检查依赖列

## 问题

v19 迁移需要读取 `replicate_runs.script_id` 和 `start_end_pairs_json`，初版只检查了 `replicate_runs` 表是否存在。从 schema 12 等更早版本直接升级时，表可能已存在，但依赖列尚未创建，导致 `no such column: script_id` 并中断启动。

## 原因

数据库迁移是按历史 schema 的真实形状执行，“表存在”不等于“当前迁移使用的所有列都存在”。尤其是旧版本中同名表曾逐步扩展时，仅检查 `sqlite_master` 不足以保证 SQL 可执行。

## 解决

- 对一次性数据转换使用的每个必需列通过 `PRAGMA table_info(...)` 检查。
- 只在所有来源列、关联列和目标列都存在时执行数据转换。
- 保留从较早 schema 直升当前版本的回归测试，不只测“上一版 → 当前版”。

## 验证

`test/features/video_generation/video_generation_database_test.dart` 中 schema 12 直升当前版本的用例通过，v18 首尾配对迁移用例仍通过。
