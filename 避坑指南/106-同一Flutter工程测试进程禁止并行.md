# 同一 Flutter 工程测试进程禁止并行

同一工程并行执行两个 `flutter test` 会争用 `build/test_cache`，Windows 可能抛出 `PathExistsException ... track.dill (errno = 183)`。处理方式是等待已有进程结束后串行复跑；不要先修改业务代码，也不要无依据清空整个构建目录。本次串行复跑已通过。
