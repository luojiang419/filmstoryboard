# 104 - PowerShell发布产物枚举需复查真实文件

## 问题现象

发布校验脚本 `scripts/verify_release_artifact.ps1` 已返回成功，并给出 `.exe.sha256` 路径；但随后使用一条 `Get-ChildItem` 同时枚举 `.exe` 与 `.exe.sha256` 时，命令一度报出校验文件不存在，容易误判为发布失败。

## 原因

单条 PowerShell 枚举命令在混合多个字面路径时，如果其中一个路径解析或时序出现问题，会直接抛错，不能代表发布脚本生成产物失败。实际应以：

1. 校验脚本退出码；
2. 脚本输出的 `checksum_path`；
3. 再次单独目录复查；

这三者综合判断。

## 正确做法

- 优先信任 `verify_release_artifact.ps1` 的成功退出和 JSON 输出。
- 复查时使用目录列表或 `Test-Path` 分开确认，不要只依赖一条混合枚举命令。
- 若需要展示产物信息，优先执行：

```powershell
Get-ChildItem dist\installer -Force | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name,Length,LastWriteTime
```

## 适用场景

Windows 本地发布、校验脚本收尾、安装包和校验文件复查。
