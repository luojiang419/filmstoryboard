# 089：Flutter 构建会对中文 Asset 物理文件名做 URI 编码

## 问题现象

Release 目录实际包含 45 个 LibTV 资源文件，但使用中文物理路径检查 `prompt-guides/SD2提示词规则.md` 返回不存在。

## 原因

Flutter 构建会把非 ASCII asset 文件名按 URI 百分号编码写入物理目录，例如 `SD2提示词规则.md` 会落为 `SD2%E6%8F%90...md`。应用通过 AssetManifest 和 `rootBundle` 使用声明时的逻辑路径加载，不受影响。

## 解决方式

- 运行时测试使用 AssetManifest / `rootBundle.loadString` 验证逻辑路径。
- 检查 Release 物理文件时，枚举目录或对文件名做 URI 编码后再匹配，不要只用原中文物理路径判断资源是否缺失。
