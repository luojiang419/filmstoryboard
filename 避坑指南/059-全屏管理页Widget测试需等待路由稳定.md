# 059-全屏管理页 Widget 测试需等待路由稳定

## 问题

Widget 测试点击通过 `Navigator.push(MaterialPageRoute(fullscreenDialog: true))` 打开的管理页面后，如果只固定 `pump` 约 200～300ms，可能在路由尚未完成构建或动画时断言，表现为找不到新页面标题。

## 错误方式

```dart
await tester.tap(find.byKey(const ValueKey('manage-prepare-assets-library')));
await tester.pump(const Duration(milliseconds: 260));
expect(find.text('资产管理'), findsOneWidget);
```

## 正确方式

对于没有持续动画的全屏管理路由，点击打开和关闭后使用：

```dart
await tester.tap(find.byKey(const ValueKey('manage-prepare-assets-library')));
await tester.pumpAndSettle();
expect(find.text('资产管理'), findsOneWidget);
```

如果页面包含持续动画，则不能使用 `pumpAndSettle`，应改用可控的有限 `pump` 并直接等待目标路由首帧；先确认页面动画类型再选择策略。

## 额外注意

- 新增枚举断言时要导入枚举实际声明文件，避免 Widget 测试在加载阶段因未定义符号失败。
- Windows Flutter 测试继续使用 `--concurrency=1`，避免原生测试资产缓存竞争。

