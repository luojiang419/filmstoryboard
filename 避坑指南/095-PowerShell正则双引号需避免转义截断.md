# PowerShell 正则双引号需避免转义截断

## 现象

在 PowerShell 命令参数中用双引号包裹包含多个双引号字面量的 `rg` 正则时，内层引号可能先被 PowerShell 解析，导致传给 `rg` 的表达式残缺，并报 `regex parse error: unclosed group`。

## 原因

PowerShell 的参数解析发生在 `rg` 正则解析之前。为正则准备的反斜杠不一定能保护 PowerShell 字符串中的双引号，因此终端实际收到的表达式与源码里看到的内容不同。

## 处理方式

- 校验少量固定版本文本时，优先使用 `Select-String -SimpleMatch` 并逐项匹配。
- 必须使用正则时，优先使用 PowerShell 单引号包裹完整表达式，并避免在同一表达式中混入需要 PowerShell 再次解释的引号。
- 正则失败后不要据此判断版本不一致，应先改用纯文本匹配重新核验。

## 本次结果

改用逐文件 `Select-String -SimpleMatch` 后，`pubspec.yaml`、安装器配置和应用更新器中的 304 版本均可正常匹配；Windows Release 主程序文件版本与产品版本也均为 `1.0.0+304`。
