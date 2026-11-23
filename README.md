# filmstoryboard

面向 Windows 的 Flutter 桌面故事板工具，包含多宫格裁切、故事板编排、画板管理、视觉解析、分镜设计与导出功能。

## 开发环境

- Flutter `3.38.8`（stable）
- Dart `3.10.7`
- Windows x64
- Inno Setup `6.7.1`

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release
```

## 自动发布

推送到 `main` 后，GitHub Actions 会自动：

1. 从公开 Release 仓库读取最新四段版本号并递增末段；
2. 注入 Flutter、更新器与 Inno Setup 版本；
3. 执行静态分析和完整自动化测试；
4. 构建 Windows Release 与安装包；
5. 校验产品版本、资产名、大小、SHA-256 与签名状态；
6. 先创建草稿并上传资产，复核通过后发布为正式 Latest Release。

安装包与更新源：[storyboard-grid-app-releases](https://github.com/luojiang419/storyboard-grid-app-releases/releases/latest)

## 安全说明

仓库不包含 API Key、访问令牌、构建缓存或历史安装包。请通过软件设置页或本地环境配置个人服务凭据，不要把密钥提交到 Git。

当前仓库公开可读，但暂未附加开源许可证；除非另有书面授权，版权仍由项目所有者保留。
