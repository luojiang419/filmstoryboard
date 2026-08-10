# 058-Windows 可灵 CLI 长提示词需绕过 cmd

## 现象

选择可灵 CLI 生成时立即失败，界面显示：

```text
FormatException: Missing extension byte (at offset 1)
```

可灵 HTTP 日志只有令牌刷新，没有图片上传或生成请求。

## 根因

应用原来通过 `kling.cmd` 和 `runInShell: true` 执行，完整提示词作为命令行参数传入。Windows `cmd.exe` 的命令行长度约为 8191 字符；本次真实任务提示词为 8207 字符，加上模型、图片路径和其他参数后必然超限。

`cmd.exe` 返回的本地编码错误又被 Dart 强制按 UTF-8 解码，导致真实的“命令行过长”被二次异常 `Missing extension byte` 覆盖。

## 正确处理

1. 从 npm 全局目录的 `kling.cmd` 同级位置解析实际 `cli.js`。
2. 用 `node.exe cli.js ...` 且 `runInShell: false` 直接调用，绕过 `cmd.exe`。
3. `Process.run` 对 stdout/stderr 使用 `Encoding? = null` 获取字节。
4. 按 UTF-8、系统编码、Latin-1 顺序容错解码，以便始终展示真实错误。

## 验证清单

- 使用至少 9000 个中文字符构造提示词。
- 断言执行文件为 `node.exe`。
- 断言第一个参数为 `cli.js`。
- 断言 `runInShell == false`。
- 用非 UTF-8 字节验证解码函数不抛 `FormatException`。
- 复跑可灵 CLI 服务、登录和视频生成控制器测试。

## 后续避免

- 不要为了调用 npm 的 `.cmd` 包装器长期依赖 `runInShell: true` 传递大段用户文本。
- 不要直接为外部进程固定 `stdoutEncoding: utf8`，除非协议明确保证所有成功和失败输出均为 UTF-8。
- `SystemEncoding.decode` 不支持 `allowMalformed` 命名参数；需要保底时再回退到 `latin1.decode(..., allowInvalid: true)`。
