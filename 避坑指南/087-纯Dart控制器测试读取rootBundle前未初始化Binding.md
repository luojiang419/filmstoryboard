# 087：纯 Dart 控制器测试读取 rootBundle 前未初始化 Binding

## 问题现象

给构建脚本流程接入内置 Skill assets 后，使用 `package:test` 的控制器测试报 `Binding has not yet been initialized`，导致构建提前终止并引发多项业务断言连锁失败。

## 原因

纯 Dart 测试不会像 Flutter 应用和 Widget 测试一样自动初始化 `ServicesBinding`，直接调用 `rootBundle.loadString` 会失败。

## 解决方式

- Release 构建继续强制从 Flutter assets 读取，确保分发后的资源来自安装包。
- 未显式传入 `AssetBundle` 且处于 Debug/测试构建时，允许从仓库同名相对路径读取源文件。
- 显式测试 Bundle、Profile 和 Release 均不启用该回退，资源缺失必须立即报错，不能静默降级成摘要。
