# 视觉模型本机配置说明

请在应用“设置 → 视觉模型 API”中新增一张配置卡片。每张卡片独立保存名称、API 地址、API Key、模型和请求协议，点击卡片可切换当前视觉模型。

默认协议是 `Chat Completions`，请求地址会自动归一化为 `/v1/chat/completions`。需要使用原生 Responses 的服务时，选择 `Responses（原生）`，端点默认填写 `/v1/responses`；也可以填写服务商提供的相对路径或完整 `http(s)` 地址。

本地 Responses 服务示例：

- API 地址：`http://127.0.0.1:8000`
- 请求协议：`Responses（原生）`
- Responses 端点：`/v1/responses`
- 模型：填写本地服务实际注册的模型名称

程序会把视觉图片转换为 Responses 的 `input_image`，文本转换为 `input_text`，并按 `output_text`、`output[].content[]` 顺序解析结果。旧版只保存 API 地址、Key 和模型的配置会自动继续按 Chat Completions 使用。

安全要求：

- API Key 只能保存在本机设置数据库或系统环境变量中。
- 不要把真实 API Key 写入本文档、源代码、测试夹具、日志或 Git 历史。
- 示例、截图和错误报告必须使用脱敏值。
