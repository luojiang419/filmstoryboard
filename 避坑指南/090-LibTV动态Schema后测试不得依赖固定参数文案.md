# LibTV 动态 Schema 后测试不得依赖固定参数文案

## 问题

LibTV 参数由固定 Seedance 控件改为读取模型 schema 后，旧测试仍断言“生成比例：adaptive”和固定的 `4–15` 秒代码文本，导致功能正确但测试失败。

## 原因

- schema 的 `displayName` 可能是“比例”而不是旧界面写死的“生成比例”。
- 时长不再通过 `seconds.round().clamp(4, 15)` 固定处理，而由 `_normalizedLibTvDuration` 根据当前模型 enum 或 min/max 计算。
- switch 的底层值可能是 `on/off`、`1/0` 或 `true/false`，界面摘要应转换为“开启/关闭”，测试不应绑定底层编码。

## 解决

- 测试改为断言动态模型、动态模式和动态参数控件存在。
- 时长测试断言调用 schema 驱动的标准化函数。
- 摘要层统一把 switch 值显示为“开启/关闭”。

## 后续约束

LibTV 模型和参数在线可变。测试应使用模拟 schema 验证解析、选择、默认值、持久化和命令参数，禁止重新写死某个模型的完整参数清单。
