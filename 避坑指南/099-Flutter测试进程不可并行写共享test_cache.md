# 099：Flutter 测试进程不可并行写共享 test_cache

日期：2026-08-17

## 问题现象

在同一 Flutter 工程目录并行启动两条 `flutter test` 命令时，其中一个进程在编译测试快照阶段失败：

```text
PathExistsException: Cannot copy file to
build/test_cache/...cache.dill.track.dill
OS Error: 当文件已存在时，无法创建该文件。 errno = 183
```

失败后该测试进程还可能保持会话不退出，需要显式终止。

## 根因

多个 `flutter test` 进程会共享工程内的 `build/test_cache`。Windows 上两个编译器同时创建或替换相同的 `.dill` 跟踪文件时存在竞争，Flutter 测试缓存没有为独立进程提供可靠隔离。

## 解决方式

- 同一工程中的 `flutter test` 命令必须串行执行。
- 需要覆盖多组测试时，优先把多个测试文件放入同一条 `flutter test fileA fileB ...` 命令。
- 页面测试与其他测试必须拆开时，等待前一条进程完全退出后再启动下一条。
- 若失败进程仍有会话，先发送中断并确认退出；不要在残留进程存在时重试。
- 本次无需删除 `build/test_cache`，串行重试即可恢复；不要把可复用的整个 `build` 目录当作临时垃圾删除。

## 验证

- 串行定向测试 36 项通过。
- 随后串行完整测试 727 项通过、2 项跳过、0 失败。
