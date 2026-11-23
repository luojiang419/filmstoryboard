# SQLite 新增迁移必须同步 Schema 版本常量

## 现象

为 `shooting_asset_library_items` 新增 `aliases_json` 列并加入 `version < 10` 迁移后，全量测试中的旧数据库迁移用例失败：实际 `PRAGMA user_version` 为 `10`，但 `AppDatabase.currentSchemaVersion` 仍为 `9`。

## 原因

数据库迁移链按 `PRAGMA user_version` 正常执行，但测试和其他调用方以 `AppDatabase.currentSchemaVersion` 作为迁移完成的唯一版本标识。新增迁移时若只改迁移代码，不更新该常量，就会造成版本契约不一致。

## 处理

同步把 `AppDatabase.currentSchemaVersion` 更新为 `10`，再执行全量 `flutter analyze` 与 `flutter test`。

## 后续规则

每新增一个 SQLite 迁移步骤，必须同时检查：迁移分支、`PRAGMA user_version` 写入值、`currentSchemaVersion` 常量，以及旧库打开迁移测试。
