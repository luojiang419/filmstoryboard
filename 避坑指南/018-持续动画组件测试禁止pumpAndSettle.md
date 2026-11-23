# 持续动画组件测试禁止无条件使用 pumpAndSettle

## 问题现象

Widget 测试在展示 `CircularProgressIndicator` 后调用 `pumpAndSettle()`，即使界面逻辑正确也会在默认超时时间后失败：

```text
pumpAndSettle timed out
```

## 根因

`CircularProgressIndicator` 等持续动画会不断安排新帧，测试框架永远无法达到“没有待处理帧”的 settled 状态。

## 正确做法

只等待界面进入目标状态所需的固定动画时长：

```dart
await tester.pump();
await tester.pump(const Duration(milliseconds: 220));
```

完成断言后，应关闭持续运行状态或移除对应 Widget，再对后续确实会静止的交互使用 `pumpAndSettle()`。

## 适用范围

- 圆形或线性不定进度指示器
- 无限旋转、呼吸、闪烁动画
- 周期性计时器驱动的 Widget
- 持续播放的动画控制器
