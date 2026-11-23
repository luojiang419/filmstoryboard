# Flutter 测试与 Windows 原生资源缓存冲突

## 现象

在刚完成 Windows Release 构建后继续执行 `flutter test`，Flutter 可能报：

```text
PathExistsException: Cannot copy file to build\\native_assets\\windows\\sqlite3.dll
OS Error: errno = 183
```

## 原因

Flutter 的 native assets 在构建产物与测试运行间重复复制同一份 `sqlite3.dll`，目标文件已存在时工具没有覆盖处理。该错误发生在测试启动阶段，不代表业务断言失败。

## 处理方式

1. 先执行 `flutter analyze` 与必要的定向测试，避免把回归验证完全依赖于构建后的全量测试。
2. 若具备删除生成缓存的权限，可仅清理工程内的 `build/native_assets`，再重跑测试；不要删除用户数据、工程数据库或整个工作区。
3. 本项目的 Flutter SDK 固定使用 `D:\\flutter\\bin\\flutter.bat`，不要依赖未配置的系统 `dart` 命令。

## 本次验证补充

当删除构建缓存的权限不可用时，可先将唯一冲突文件 `build\\native_assets\\windows\\sqlite3.dll` 重命名为临时文件，运行测试后再恢复原文件。该方式只处理可再生的单个构建缓存，不触及工程数据或源码；测试结束后应清理临时副本。
