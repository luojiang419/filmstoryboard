# Dart 列表筛选首项不要直接使用 firstWhereOrNull

## 触发场景

在视频生成格子里想从任务列表中取第一个可展示任务时，最初写成：

```dart
final latest = tasks.firstWhereOrNull(_shouldKeepVideoTaskInCell);
```

当前项目可用的 Dart/Flutter 环境没有给 `List` 提供 `firstWhereOrNull`，静态分析报错：

```text
The method 'firstWhereOrNull' isn't defined for the type 'List'.
```

## 解决方式

项目里已有 `firstOrNull` 可用，可以先 `where` 再取首项：

```dart
final latest = tasks.where(_shouldKeepVideoTaskInCell).firstOrNull;
```

## 后续规避

需要“按条件取第一个或 null”时，优先使用 `items.where(predicate).firstOrNull`，除非当前文件已经明确引入并验证了可用的集合扩展。
