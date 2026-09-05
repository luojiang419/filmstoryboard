# 冻结 Python 深度 worker 中文编码与 Dart 隔离域

## 问题表现

安装版深度提取报 `FormatException: Missing extension byte`；修正编码后又报 isolate 消息含不可发送的 `_AsyncCompleter`。

## 触发条件

原帧或输出路径含中文；Flutter 调用冻结 Python worker，随后在同一队列闭包作用域启动 Isolate.run。

## 根本原因

1. candidate.3 冻结运行时使用 Windows 本地编码，PYTHONUTF8/PYTHONIOENCODING 环境变量没有改变标准输入输出编码。UTF-8 中文请求被解析成错误路径，本地编码错误响应再被 Flutter 严格 UTF-8 解码而失败。
2. Isolate.run 闭包共享外部队列作用域，捕获 Completer 等不可发送对象，worker 推理成功也不能生成预览。

## 无效尝试

仅跑 worker --smoke-test 无法覆盖中文路径通信与 Dart 预览流程。主数据库无失败记录也不能排除独立工程数据库中的错误。

## 正确解决方案

请求用 ASCII JSON（非 ASCII UTF-16 code unit 转为 `\uXXXX`，支持代理对），响应按 systemEncoding 解码。预览在仅接收 String/int 的独立静态方法中启动 Isolate.run。

## 验证方法

使用真实安装目录 worker 与失败工程中文路径原帧调用 PersonDepthService.extract，确认 16-bit 母版与 8-bit 预览均可解码。常规测试覆盖中文/emoji JSON 往返与异步预览。

## 如何避免

用完整应用调用链验收外部组件；诊断读取 project_catalog 指向的实际工程数据库。保留 data/logs/person_depth.jsonl。

## 影响模块

PersonDepthService、模型组件通信、深度预览。
