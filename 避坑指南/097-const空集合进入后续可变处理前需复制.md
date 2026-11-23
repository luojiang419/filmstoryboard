# const 空集合进入后续可变处理前需复制

## 问题现象

解析方法在没有数据时返回 `const []`，调用方随后对列表执行 `add` 或 `sort`，运行时报错：

`Unsupported operation: Cannot modify an unmodifiable list`

## 原因

`const []` 是不可变列表。即使方法声明的返回类型是 `List<T>`，调用方也不能假设它一定可修改。

## 解决方式

需要继续补项或排序时，先显式复制为可变列表：

```dart
final mutableItems = List<Item>.of(parseItems(source));
```

## 后续检查

- 测试输入不包含对应数组的情况。
- 测试返回空集合后的 `add`、`sort`、`remove` 路径。
- 对跨方法传递的 `List<T>` 不默认其可变性。
