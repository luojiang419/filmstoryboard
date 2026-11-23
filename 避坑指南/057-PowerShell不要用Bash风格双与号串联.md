# 057-PowerShell不要用Bash风格双与号串联

## 问题现象

在 PowerShell 中执行类似命令时会解析失败：

```powershell
rg -n "pattern" file.dart && $p='G:\data\app\film\...'
```

错误表现为 `Unexpected token`，因为当前 PowerShell 环境没有按 Bash 语义处理 `&&` 后面的赋值语句。

## 原因

项目开发命令运行在 PowerShell 下。把 Bash 风格的命令串联、变量赋值和路径读取混在一行，容易被 PowerShell 按表达式解析，从而在 `$p='...'` 处报错。

## 处理方式

- 需要并行读取时，用 `multi_tool_use.parallel` 分开跑多条命令。
- 单条 PowerShell 命令里优先写完整 PowerShell 语法，不混用 Bash 串联。
- 如果确实要串联，先确认当前 PowerShell 版本和语义；本项目日常开发不依赖这种写法。

## 后续避坑

读取文件片段和 `rg` 搜索分开执行，例如：

```powershell
rg -n "pattern" lib\features\replicate\presentation\replicate_page.dart
```

```powershell
$p='G:\data\app\film\filmstoryboard\lib\features\replicate\presentation\replicate_page.dart'
$lines=Get-Content -LiteralPath $p
$lines[360..560]
```
