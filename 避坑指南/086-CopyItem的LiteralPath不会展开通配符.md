# 086：Copy-Item 的 LiteralPath 不会展开通配符

## 问题现象

使用 `Copy-Item -LiteralPath "源目录\*"` 复制 LibTV Skill 时，PowerShell 报源路径不存在；目标目录为空，而后续可灵和 H3 的显式文件复制正常。

## 原因

`-LiteralPath` 会把 `*` 当作普通文件名，不进行通配符展开。

## 解决方式

先使用 `Get-ChildItem -LiteralPath <源目录>` 精确枚举目录项，再将枚举结果传给 `Copy-Item -Recurse`。复制后必须核对文件数与总字节数；本次 LibTV Skill 应为 44 个文件、229889 字节。
