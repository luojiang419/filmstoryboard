# Flutter 全量测试不得使用 120 秒命令上限

## 现象

项目全量执行 `flutter test --concurrency=1` 时，测试数量接近 700 项，正常耗时约 143 秒。如果外层命令工具只给 120 秒，工具会先关闭输出管道并终止子进程，随后 Dart reporter 报：

```text
FileSystemException: writeFrom failed, path = ''
(OS Error: 管道正在被关闭。, errno = 232)
```

这不是测试用例失败，也不是 Flutter 代码异常。

## 正确做法

使用至少 10 分钟的外层命令时限，并用 compact reporter 降低过程输出量：

```powershell
D:\flutter\bin\flutter.bat test --no-pub --concurrency=1 --reporter compact
```

本次重跑结果为 695 项通过、2 项按既有标记跳过，用时约 143 秒。

## 恢复步骤

1. 先确认没有残留 `dart`、`dartaotruntime` 或 `flutter` 测试进程。
2. 不要把“管道正在被关闭”记录为代码回归。
3. 使用更长外层时限完整重跑，以最终 `All tests passed!` 和退出码 0 为准。
