# 009-工程图片生成日志与 Gemini 代理兼容

## 坑 1：工程模式下图片生成日志不在安装目录

现象：

- 安装目录 `D:\Program Files\故事板\data\logs` 里没有 `image-generation-*.log`。
- 误以为点击高清重绘后没有进入图片生成链路。

原因：

- 当前应用已支持独立工程。
- 进入工程后，`projectDirectoriesProvider` 会让故事板控制器使用工程自己的目录。
- 图片生成诊断日志写入当前工程的 `logs`，不是全局安装目录。

正确排查路径：

```text
当前工程根目录/logs/image-generation-YYYY-MM-DD.log
当前工程根目录/database/project.sqlite
```

示例：

```text
D:\Program Files\故事板\data\project\SS27\logs\image-generation-2026-07-26.log
D:\Program Files\故事板\data\project\SS27\database\project.sqlite
```

后续原则：

- 用户反馈“无法生成图片”时，先从全局库 `project_catalog` 找最近打开工程。
- 优先查看工程内 `logs/image-generation-YYYY-MM-DD.log` 和 `database/project.sqlite`。
- 不要只查安装目录 `data/logs`，那里可能只保留旧版全局日志。

## 坑 2：第三方 Gemini 代理可能不支持 Interactions API

现象：

- 高清重绘批量任务全部失败。
- 日志中所有失败行类似：

```text
provider: gemini
endpoint: https://www.shiying-api.com
model: gemini-3-pro-image
error: Invalid URL (POST /v1beta/interactions)
```

原因：

- 高清重绘固定使用 stable `gemini-3-pro-image`。
- 之前实现让 stable Gemini 图像模型走 `/v1beta/interactions`。
- Google 官方 `generativelanguage.googleapis.com` 可继续使用该路由。
- 诗影等第三方代理仍兼容旧 preview `generateContent`，但不一定支持 `/v1beta/interactions`。

处理方式：

- 模型目录为 stable Gemini 图像模型声明 preview generateContent 兼容模型：

```dart
geminiGenerateContentFallbackApiModel: 'gemini-3-pro-image-preview',
geminiGenerateContentFallbackApiModel: 'gemini-3.1-flash-image-preview',
```

- 生成服务按 Base URL 分流：

```dart
if (!_isGoogleGeminiEndpoint(request.apiBaseUrl) &&
    fallbackApiModel != null) {
  return _generateGeminiGenerateContentImage(
    request,
    descriptor,
    apiModelOverride: fallbackApiModel,
  );
}
```

后续原则：

- 新增 Gemini stable 图像模型时，同时确认第三方代理的兼容路由。
- 官方 Google 地址优先保留官方新路由；第三方代理优先兼容已有可用路由。
- 回归测试必须同时覆盖官方 `x-goog-api-key` 和第三方 `Authorization: Bearer` 两种请求头。

