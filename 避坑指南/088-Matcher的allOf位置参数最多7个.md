# 088：Matcher 的 allOf 位置参数最多 7 个

## 问题现象

给现有 Skill 上下文断言增加两项后，测试编译报 `Too many positional arguments: 7 allowed, but 9 found`。

## 原因

当前 `matcher 0.12.17` 的 `allOf` 位置参数重载最多接收 7 项，不是可无限追加的变长参数。

## 解决方式

把语义相关的断言放入一层嵌套 `allOf`，外层继续组合各断言组。不要为了绕过上限删除已有契约检查。
