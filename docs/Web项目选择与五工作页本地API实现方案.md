# FilmStoryboard Web 项目选择与五工作页本地 API 实现方案

## 1. 任务目标

将当前“导演远程工作台”调整为桌面软件的多平台 Web 客户端。配对成功后先进入工程项目选择页面，选择本机已有工程，再进入以下五个核心工作页：

1. 视频解析：浏览器上传视频，本机接收并落入当前工程，由本机 FFmpeg、视觉模型和现有控制器完成抽帧、解析、故事板及拍摄脚本联动，Web 实时显示进度与结果。
2. 故事板：显示本机当前工程的画板、分镜图、说明和批注，编辑结果实时回写桌面工程。
3. 拍摄脚本：显示并编辑本机脚本与镜头字段，通过版本号避免 Web 与桌面互相覆盖。
4. 生成视频：显示本机当前工程的视频模型、生成参数、镜头组、素材、排队/运行状态和作品版本；提交、取消、恢复及导出时间线继续由本机现有生成控制器和任务服务执行。
5. 导出：由本机现有导出服务生成画板、画板原图、拍摄脚本、视频解析报告和时间线文件，浏览器只下载本机服务生成的产物。

Web 端不直接访问 SQLite、工程目录、FFmpeg 或第三方模型密钥。桌面应用是唯一业务主机和事实来源。

## 2. 核心体验

```text
浏览器完成配对
  -> 读取本机可用工程列表
  -> 选择工程并请求本机桌面安全打开/切换
  -> 浏览器选择视频
  -> 流式上传到本机工程隔离目录
  -> 本机创建后台任务
  -> 现有 VideoAnalysisController 导入/抽帧/解析
  -> WebSocket 推送进度，页面也可轮询恢复
  -> 故事板、脚本数据随桌面工程实时更新
  -> Web 发起导出
  -> 本机现有 ExportService 生成文件
  -> 浏览器从一次性受控下载接口获取产物
```

刷新页面、设备休眠或 WebSocket 暂时中断后，任务不会终止；客户端重新读取任务列表即可恢复进度。

桌面端仍保持单一活动工程。Web 选择工程会请求桌面同步切换；当当前工程存在不能安全中断的保存或运行任务时，服务返回冲突状态，由 Web 明确提示用户，不进行静默强切。

## 3. 边界与安全约束

- 默认只监听 `127.0.0.1`，局域网访问继续由桌面设置显式开启。
- 所有业务接口均要求配对会话；修改、上传、执行与导出要求 `director` 角色。
- 视频上传采用二进制流，不把整段视频载入服务器内存；文件名会净化并写入当前工程的隔离暂存目录。
- 上传文件限制为现有视频格式白名单，并校验声明大小、实际大小和当前工程归属。
- 媒体预览及导出下载只暴露不透明 ID，不返回本机绝对路径。
- 导出产物只允许下载由当前会话、本次任务、本机导出服务实际生成的文件。
- 长任务同时提供 WebSocket 事件与 `GET /tasks` 状态查询，断线不丢任务。
- 继续使用 revision/version 做乐观并发控制；冲突返回 `409` 并附最新版本。

## 4. API 契约

统一前缀为 `/api/v1`，成功响应为 JSON（媒体和下载除外），错误继续使用现有 `error.code/message/details/requestId` 结构。

### 4.1 能力与任务

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/capabilities` | 返回项目选择、五工作页能力与上传限制 |
| GET | `/tasks` | 当前工程可恢复任务列表 |
| GET | `/tasks/{id}` | 单任务状态、进度、消息和结果 |
| POST | `/tasks/{id}/cancel` | 取消支持取消的本机任务 |

任务状态统一为 `queued/running/succeeded/failed/cancelled`，包含 `progress.current/total`、`message`、`createdAt/updatedAt` 和领域结果。

### 4.2 工程项目选择

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/projects` | 返回允许远程访问的本机工程摘要、当前活动工程与状态 |
| POST | `/projects/{id}/open` | 请求桌面打开/切换工程，返回切换任务或冲突 |
| GET | `/projects/{id}/overview` | 工程统计、最近访问和五模块可用状态 |
| POST | `/workspace/close` | 安全关闭当前 Web 工作区并返回工程选择页 |

工程列表只返回项目 ID、名称、画幅、更新时间和统计，不返回本机目录。项目打开操作经桌面 `ProjectService/ProjectPortal` 完成，禁止 Web 自行打开数据库文件。

### 4.3 视频解析

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/uploads/videos` | 二进制流上传视频，返回上传 ID |
| POST | `/video-analysis/imports` | 将上传 ID 交给本机导入/抽帧，返回任务 ID |
| GET | `/video-analysis/videos` | 视频摘要、导入和解析状态 |
| GET | `/video-analysis/videos/{id}` | 帧、镜头、维度结果、总结和媒体 ID |
| POST | `/video-analysis/videos/{id}/analyze` | 本机开始/继续/重试解析 |
| POST | `/video-analysis/videos/{id}/pause` | 暂停当前视频解析 |
| POST | `/video-analysis/videos/{id}/cancel` | 取消当前视频解析 |
| POST | `/video-analysis/videos/{id}/storyboard` | 从结果创建/刷新故事板与脚本 |

### 4.4 故事板

保留已有 `/storyboards`、`/storyboards/{id}`、批注和版本化编辑接口，并补齐 Web 五工作页导航、空态、加载态、窄屏及实时刷新。生成型操作通过任务接口接入，不在 Web 复制桌面生成逻辑。

### 4.5 拍摄脚本

保留已有 `/scripts`、`/scripts/{id}`、`PATCH /scripts/{id}/shots/{shotId}`，新增脚本构建任务入口，并保持所有提示词、镜头参数和生成反馈字段由本机仓库读写。

### 4.6 生成视频

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/video-generation/options` | 本机可用模型、分辨率、比例、时长和动态 Schema 参数 |
| GET | `/video-generation/groups` | 镜头组、最终提示词、参考资产和可生成状态 |
| GET | `/video-generation/tasks` | 当前工程排队、运行、失败、完成和恢复中的任务 |
| POST | `/video-generation/tasks` | 按镜头组调用本机真实生成流程 |
| POST | `/video-generation/tasks/{id}/cancel` | 取消本机生成任务并保护状态回写 |
| POST | `/video-generation/tasks/{id}/retry` | 以当前镜头组配置重试失败任务 |
| GET | `/video-generation/works` | 按镜头折叠显示本机作品与历史版本 |

Web 不持有模型 API Key，也不重新实现 H3/可灵/LibTV 参数和提示词逻辑；所有可用选项、校验、提交与恢复均从本机 `VideoGenerationController` 及任务服务投影。

### 4.7 导出

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/exports/options` | 可导出内容、格式、清晰度及默认文件名 |
| POST | `/exports` | 本机创建导出任务 |
| GET | `/exports/{id}` | 导出任务与产物摘要 |
| GET | `/exports/{id}/files/{fileId}` | 下载本机生成的单个产物 |

首批导出类型与桌面导出页一致：`storyboard`、`boardImages`、`shootingScript`、`videoAnalysisReport`、`timelineXml`。多文件结果由本机打包为 ZIP 或以文件列表下载，不暴露目录路径。

## 5. 文件与模块清单

### 桌面本地服务

- `lib/features/remote_access/application/remote_project_registry.dart`：项目目录投影、单活动工程安全切换与冲突状态。
- `lib/features/remote_access/application/remote_task_registry.dart`：后台任务、进度、恢复、取消与事件。
- `lib/features/remote_access/application/remote_upload_registry.dart`：视频流式暂存、格式/大小/工程边界校验。
- `lib/features/remote_access/application/remote_video_analysis_registry.dart`：当前工程视频解析业务源注册。
- `lib/features/video_analysis/application/video_analysis_remote_source.dart`：现有控制器到远程 DTO/命令的适配器。
- `lib/features/remote_access/application/remote_video_generation_registry.dart`：当前工程生成视频业务源注册。
- `lib/features/video_generation/application/video_generation_remote_source.dart`：生成控制器、模型参数、任务和作品的远程适配器。
- `lib/features/remote_access/application/remote_export_service.dart`：调用现有导出服务并注册下载产物。
- `lib/features/remote_access/server/embedded_web_server.dart`：新增上传、视频、任务、导出路由。
- `lib/features/remote_access/application/remote_access_facade.dart`：项目选择与五工作页统一业务门面。
- `lib/core/providers/app_providers.dart`、`lib/app/app_shell.dart`：注册真实桌面控制器源并维护生命周期。

### Web 客户端

- `website/app/lib/features/projects/`：配对后的工程项目选择、打开状态和冲突提示。
- `website/app/lib/core/models/remote_models.dart`：视频、任务、导出 DTO。
- `website/app/lib/core/api/remote_api.dart`：上传、视频、任务、导出 API。
- `website/app/lib/features/video_analysis/`：上传、视频列表、进度和解析结果页。
- `website/app/lib/features/storyboard/`：复用并完善现有故事板页。
- `website/app/lib/features/shooting_script/`：从现有工作区拆出独立拍摄脚本页。
- `website/app/lib/features/video_generation/`：模型参数、镜头组、任务队列与作品页。
- `website/app/lib/features/exporter/`：导出配置、任务状态和下载页。
- `website/app/lib/features/workspace/`：五页导航、工程切换、全局事件和状态恢复。

### 测试

- 本地服务：上传越界/超限、任务恢复、视频命令、导出产物权限、Range/下载、角色与审计。
- Web：项目选择、五页导航、上传请求、断线恢复、任务进度、解析结果、脚本冲突、生成队列、导出下载和窄屏布局。
- 端到端：选择工程 -> 真实小视频上传 -> 本机抽帧 -> Web 读结果 -> 故事板/脚本可见 -> 本机生成任务可见 -> 本机导出 -> 浏览器下载。

## 6. 拆分步骤与待办

- [x] 模块 0：盘点现有远程服务、Web 客户端和桌面业务页面，确定复用边界。
- [x] 模块 1：冻结目标架构、API 契约、文件清单和验收标准。
- [x] 模块 2：实现本机项目目录投影、安全打开/切换 API 和 Web 工程选择页。
- [x] 模块 3：实现任务注册表、视频上传与安全暂存。
- [ ] 模块 4：接入视频解析真实控制器、查询 DTO 和长任务事件。
- [ ] 模块 5：补齐故事板 Web 页面到五页工作台标准。
- [ ] 模块 6：拆分并完善拍摄脚本 Web 页面及构建入口。
- [ ] 模块 7：接入真实生成视频控制器、任务/作品 API 和 Web 页面。
- [ ] 模块 8：接入本机导出服务、受控产物下载和 Web 导出页。
- [ ] 模块 9：统一五页导航、响应式体验、断线恢复和错误提示。
- [ ] 模块 10：全量联调、版本递增、Web/Windows 构建、安装包与缓存清理。

## 7. 验收标准

1. 配对成功后先显示本机工程项目选择页，不直接进入旧导演概览页。
2. 选择工程后桌面安全打开/切换到同一工程；忙碌冲突不会静默强切，成功后 Web 再进入工作区。
3. 工作区首层导航为“视频解析、故事板、拍摄脚本、生成视频、导出”五个业务页。
4. Web 上传受支持视频后，本机工程出现该视频，浏览器无需本机路径权限。
5. 抽帧、解析、建板/脚本均由本机现有控制器执行；桌面和 Web 显示同一结果。
6. 上传、解析或生成超过页面生命周期仍继续，刷新后能恢复任务、进度和结果。
7. 故事板图像可预览、字段与批注可按权限修改，并继续通过 revision 防冲突。
8. 拍摄脚本镜头和提示词可查看/编辑，桌面修改能实时刷新到 Web。
9. Web 显示本机真实视频模型和动态参数，可提交、取消、重试并查看作品历史；API Key 不进入浏览器。
10. Web 可发起桌面导出页的五类导出，产物由本机生成并可下载。
11. API 不返回工程绝对路径、模型密钥或长期 WebSocket Token；非导演会话不能切换工程、上传、执行、修改或导出。
12. 桌面全量测试、Web 全量测试、Flutter analyze、Web Release 和 Windows Release 全部通过。

## 8. 实施原则

先打通“工程选择 -> 桌面安全切换”入口，再完成“上传 -> 本机任务 -> 解析结果”纵向闭环，随后分别完成故事板、拍摄脚本、生成视频和导出页面；每完成一个功能模块立即补测试、写进度快照，大模块完成后写差异备份。任何 Web 侧业务判断都只用于展示和输入校验，最终校验与执行始终由本机 API 完成。
