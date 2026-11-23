# 026 嵌入页新增 Provider 依赖需补齐宿主测试覆盖

## 问题现象

`ReplicatePage` 新增 `settingsControllerProvider` 依赖后，其自身页面测试已覆盖该 Provider，但通过 `ShootingScriptPage` 嵌入该页面的宿主测试报错：

`Bad state: SettingsController 尚未初始化`

## 原因

Widget 测试使用独立 `ProviderScope`。子页面增加的新 Provider 不会自动继承应用启动阶段的真实初始化；所有直接或间接渲染该子页面的测试宿主都必须显式提供一致的测试实例。

## 解决方法

在 `shooting_script_page_test.dart` 的同一个 `ProviderScope.overrides` 中增加：

```dart
settingsControllerProvider.overrideWithValue(settingsController)
```

必须复用构建其他控制器时使用的同一个 `SettingsController`，不能临时创建第二份实例，否则设置状态与业务控制器可能不一致。

## 后续规避

页面新增 `ref.watch` / `ref.read` 时，除更新页面自身测试外，还应搜索该页面的所有嵌入宿主和测试入口，并为独立 `ProviderScope` 补齐覆盖。定向测试通过后仍需运行全量测试，才能发现间接渲染链路缺失依赖的问题。
