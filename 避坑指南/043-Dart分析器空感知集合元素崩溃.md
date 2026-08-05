# 043-Dart分析器空感知集合元素崩溃

## 问题
运行 `dart analyze` 时，Dart analyzer 在 `use_build_context_synchronously` lint 内部崩溃，堆栈指向 `NullAwareElementImpl`。

触发点是集合中使用空感知元素：
```dart
?replicationStatus,
```

## 表现
- `dart analyze` 不是报普通 lint，而是 Analysis Server internal error。
- 堆栈中包含：
```text
Bad state: Missing a visit method for a node of type NullAwareElementImpl
```

## 处理方式
把空感知集合元素改成普通 if，并加局部 ignore，避免 linter 又建议改回会崩溃的写法：
```dart
// ignore: use_null_aware_elements
if (replicationStatus != null) replicationStatus,
```

## 后续注意
- 在当前 Dart/Flutter 版本下，涉及复杂 Widget 树和 `BuildContext` 的列表 children 中，优先避免 `?widget` 空感知集合元素。
- 如果 analyzer 升级后不再崩溃，可以再考虑移除局部 ignore。
