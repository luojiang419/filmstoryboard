# 108 - Widget 测试切换模式后点击前需滚动到可视区

## 现象

Flutter Widget 测试能够找到“自动匹配此镜头”按钮，但 `tester.tap` 提示命中位置不在目标组件上，后续绑定列表为空并触发 `No element`。

## 原因

测试先在快速模式向下滚动并操作资产卡，再切换到精确模式。模式切换只重建内容，不会自动把外层滚动位置恢复到顶部，因此 Finder 能匹配已构建组件，但按钮实际位于当前视口上方。

## 解决方法

```dart
final autoMatchButton = find.byTooltip('自动匹配此镜头');
await tester.scrollUntilVisible(
  autoMatchButton,
  -420,
  scrollable: find
      .descendant(
        of: find.byKey(const ValueKey('replicate-asset-library-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);
await tester.pump();
await tester.tap(autoMatchButton);
```

## 后续规避

- Finder 命中只说明组件存在，不代表其中心点在可点击视口内。
- 长列表、折叠面板或模式切换后的点击测试，应先滚动目标组件到可视区。
- 修复测试布局定位时不要更改业务控制器状态，以免掩盖真实回归。
