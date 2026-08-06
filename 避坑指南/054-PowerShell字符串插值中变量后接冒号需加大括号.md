# PowerShell 字符串插值中变量后接冒号需加大括号

## 触发场景

在编写本地 H3 多参考图批量提交脚本时，错误字符串里使用了：

```powershell
throw "Submit failed for task $i: HTTP ..."
```

PowerShell 会把 `$i:` 解析成带作用域或特殊语法的变量引用，导致解析错误：

```text
Variable reference is not valid. ':' was not followed by a valid variable name character.
```

## 解决方式

变量后面紧跟冒号、点号或其他容易混淆的字符时，用 `${变量名}` 明确边界：

```powershell
throw "Submit failed for task ${i}: HTTP ..."
```

## 后续规避

批量任务脚本里只要字符串插值后面紧跟标点，优先写成 `${name}`，尤其是错误信息、日志前缀、URL 片段和带冒号的说明文本。
