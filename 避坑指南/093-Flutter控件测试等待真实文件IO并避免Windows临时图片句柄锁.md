# 093 - Flutter 控件测试等待真实文件 IO 并避免 Windows 临时图片句柄锁

## 问题一：pumpAndSettle 不等待真实文件系统 Future

将生产代码从 `existsSync()` 改为 `await File.exists()` 后，测试点击按钮并立即 `pumpAndSettle()`，可能仍找不到后续弹窗。

原因是 `pumpAndSettle()` 主要推进 Flutter 帧和测试假时钟，不保证真实 OS 文件 IO Future 已完成。

处理方式：

```dart
await tester.tap(button);
await tester.pump();
await tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 10)),
);
await tester.pumpAndSettle();
```

不要为了让旧测试通过而把生产代码改回同步 IO。

## 问题二：Windows 图像解码器可能持有临时 PNG

控件树通过 `Image.file` / `FileImage` 解码测试临时目录中的 PNG 后，Windows 下文件句柄可能持续到测试进程结束；即使清空 Flutter image cache，立刻递归删除临时目录仍可能报 `PathAccessException errno 32`。

处理方式：

- 若测试目标不是验证临时图片创建/删除，优先复用仓库内稳定图片夹具，不在 teardown 删除该图片。
- 若必须验证临时文件生命周期，应显式卸载控件、驱逐 ImageProvider，并为 Windows 句柄释放设计独立的可重试清理策略。
- 不要吞掉所有目录删除异常后留下大量临时文件。

## 关联生命周期风险

`showDialog` 返回的 Future 可能在反向关闭动画尚未彻底销毁路由时完成。弹窗外创建的 `TextEditingController` 若在 Future 返回后立即 dispose，路由残余帧仍可能使用它。

正确做法是让弹窗 StatefulWidget 自己持有并在 State.dispose 中释放控制器，使生命周期与路由元素一致。
