# FilmStoryboard 官网交互 Demo

这是一个可独立运行、无后端依赖的 Flutter Web 官网。页面首屏在标题下直接提供可操作 Demo，内置项目 A 的压缩视频帧、故事板和拍摄脚本数据。

## 构建

```powershell
D:\flutter\bin\flutter.bat clean
D:\flutter\bin\flutter.bat pub get
D:\flutter\bin\flutter.bat build web --release --no-wasm-dry-run --no-web-resources-cdn
.\scripts\optimize_web_build.ps1
```

最终静态站点位于 `build/web`，将其中**全部文件**复制到本地服务器的网站根目录即可。服务器应为 `.wasm` 返回 `application/wasm`，并建议为 `.js`、`.wasm`、图片资源开启 Brotli 或 gzip 压缩和长期缓存。

Demo 不会调用 API、上传素材或写入数据库；刷新浏览器会恢复内置样例数据。
