# FilmStoryboard Web 远程协作与 API 架构方案

## 1. 结论

当前项目可以开发 API，并能在 Windows 软件安装后同时提供桌面端与 Web 端操作。

不建议把现有主工程直接编译为 Flutter Web。主工程大量依赖 `dart:io`、SQLite 本地文件、FFmpeg、Windows 窗口控制、系统文件选择器、媒体播放和可灵 CLI；直接改造成跨平台会造成大范围条件编译，并容易让桌面端出现回归。

推荐采用“Windows 桌面应用作为本地业务主机 + 进程内 API 服务 + 独立 Flutter Web 客户端”的结构：

```text
远端导演浏览器
    │ HTTPS / WebSocket（由内网穿透服务提供公网 TLS）
    ▼
内网穿透客户端（与 FilmStoryboard 安装在同一台 Windows 电脑）
    │ 127.0.0.1:端口
    ▼
FilmStoryboard 内置 HTTP/WebSocket 服务
    ├── 认证、权限、限流、审计
    ├── RemoteAccessFacade（远程业务门面）
    ├── 现有 Controller / Repository / TaskService
    ├── 当前工程 SQLite
    └── 工程图片、视频、导出文件与 FFmpeg/CLI
```

这样桌面端和 Web 端不会维护两套数据库，远端操作仍由安装软件所在电脑执行，也不需要把第三方 API Key 发送到浏览器。

## 2. 当前项目评估

| 项目现状 | 对 Web 的影响 | 处理方式 |
| --- | --- | --- |
| Windows Flutter 桌面应用 | UI 本身可以参考，但不能原样编译 | Web 客户端保持同一视觉语言，独立构建 |
| SQLite 工程数据库 | 浏览器不能直接安全访问本机数据库 | API 通过当前 `ProjectSession` 访问同一数据库 |
| 大量 `dart:io` 文件操作 | Flutter Web 不支持 | 留在桌面主机，由 API 代理 |
| FFmpeg、文件浏览器、可灵 CLI | 只能在 Windows 主机执行 | Web 仅提交任务、查看状态和结果 |
| 本地图片和视频路径 | 远端浏览器无法读取 Windows 路径 | 使用不暴露真实路径的媒体资源 ID 和流式接口 |
| 已有 `website/demo` | 只有静态演示，无真实 API/数据库 | 保留为官网 Demo；真实客户端放在 `website/app` |
| Riverpod Controller 与 Repository | 已具备业务分层基础 | 增加远程门面，避免路由直接写 SQL |
| 当前工程使用排他文件锁 | 可阻止多个桌面进程同时写入 | API 与桌面同进程共享会话，不另开数据库进程 |

## 3. 目标和非目标

### 3.1 目标

1. 软件安装后可在设置中开启或关闭远程访问。
2. 默认只监听 `127.0.0.1`，供同机内网穿透客户端连接；需要局域网直连时可显式改为局域网监听。
3. Web 客户端与桌面端操作同一个当前工程，并通过事件通道同步变化。
4. 浏览器不保存第三方模型 API Key，不接触任意本机绝对路径。
5. 图片、音频和视频通过受认证的资源接口访问，视频支持 HTTP Range。
6. 长耗时生成任务由 Windows 主机执行，浏览器可断线重连并恢复状态。
7. Web 静态文件随安装包部署，不要求用户另装 Node.js、Python 或数据库服务。

### 3.2 非目标

1. 第一阶段不提供多人同时编辑同一个文本字段的 CRDT 协作。
2. 第一阶段不允许远端浏览任意 Windows 文件夹，只能访问已登记工程及其受控素材。
3. 不在 Web 端直接运行 FFmpeg、SQLite、可灵 CLI 或系统更新器。
4. 官网交互 Demo 与真实远程工作台保持独立，避免公开 Demo 获得本机权限。

## 4. 安全模型

### 4.1 默认安全策略

- 服务默认关闭，开启后默认绑定 `127.0.0.1`。
- 首次连接使用短时配对码，换取有过期时间的随机会话令牌。
- 令牌只保存摘要；支持在桌面端撤销单个客户端或全部客户端。
- API 仅接受允许的 `Origin`，非浏览器客户端仍必须携带认证。
- 所有状态修改接口校验 `Content-Type`、请求体大小和字段白名单。
- 登录、失败认证、设置修改、文件下载、生成任务和删除类操作写入审计日志。
- 第三方 API Key、Authorization 请求头、配对码和本机绝对路径永不写入普通响应或日志。
- 媒体 ID 由服务端解析，规范化后必须仍位于当前工程允许目录内，阻断 `..`、符号链接和路径穿越。
- 内网穿透必须启用 HTTPS；应用本身在回环地址提供 HTTP，由穿透服务终止 TLS。

### 4.2 权限角色

第一版保留两个角色，避免不必要的权限系统复杂度：

- `director`：查看工程、修改分镜与拍摄脚本、提交/取消生成任务、导出受控结果。
- `viewer`：只读查看和下载允许的结果。

删除工程、改 API Key、软件更新、选择任意本机目录等高风险操作仅允许桌面端执行。

## 5. 并发和一致性

远程 API 不直接持有第二个 SQLite 连接去绕过现有 Controller。所有写操作进入 `RemoteAccessFacade`，由门面调用现有应用服务或新增的共享命令服务，并在成功后发布领域事件。

首版一致性规则：

1. 单个工程写操作串行执行，读操作可以并发。
2. 可编辑资源响应包含 `revision` 或 `updatedAt`。
3. 更新请求必须携带客户端看到的版本；版本落后时返回 `409 conflict` 和服务器最新数据，防止静默覆盖。
4. 桌面 Controller 与远程门面共享 `RemoteChangeBus`。远端写入后桌面刷新，桌面写入后 WebSocket 推送。
5. 生成任务以数据库任务记录为事实来源，WebSocket 只做加速；断线后仍可通过 REST 重新拉取。

## 6. API 设计草案

统一前缀：`/api/v1`。所有错误使用稳定结构：

```json
{
  "error": {
    "code": "revision_conflict",
    "message": "数据已在其他位置更新",
    "requestId": "...",
    "details": {}
  }
}
```

### 6.1 系统和认证

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/v1/health` | 无敏感信息的健康检查 |
| GET | `/api/v1/capabilities` | 版本、功能能力和当前服务状态 |
| POST | `/api/v1/auth/pair` | 配对码换取会话令牌 |
| POST | `/api/v1/auth/refresh` | 刷新会话 |
| DELETE | `/api/v1/auth/session` | 注销当前客户端 |
| GET | `/api/v1/events` | WebSocket 实时事件入口 |

### 6.2 工程与工作台

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/v1/workspace` | 当前打开工程、模块状态、活动任务摘要 |
| GET | `/api/v1/projects` | 允许远程查看的工程列表 |
| POST | `/api/v1/projects/{id}/open` | 请求桌面主机打开工程 |
| GET | `/api/v1/projects/{id}/overview` | 工程统计与最近内容 |

远程创建工程、删除工程和选择本机目录不在第一版开放。

### 6.3 故事板、拍摄脚本和生成任务

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/v1/storyboards` | 故事板与分组摘要 |
| GET | `/api/v1/storyboards/{id}` | 故事板、分镜、批注与当前版本 |
| PATCH | `/api/v1/storyboards/{id}` | 按版本更新名称、摘要、分镜说明或行说明 |
| POST | `/api/v1/storyboards/{id}/annotations` | 新增整板或单分镜批注 |
| PATCH | `/api/v1/storyboards/{id}/annotations/{annotationId}` | 更新批注内容或解决状态 |
| GET | `/api/v1/scripts` | 拍摄脚本列表 |
| GET | `/api/v1/scripts/{id}` | 拍摄脚本和镜头组 |
| PATCH | `/api/v1/scripts/{id}/shots/{shotId}` | 更新镜头内容、时长、提示词和反馈 |
| POST（规划） | `/api/v1/scripts/{id}/build` | 触发构建脚本 |
| GET（规划） | `/api/v1/video-tasks` | 查询生成任务 |
| POST（规划） | `/api/v1/video-tasks` | 提交受支持的视频生成任务 |
| POST（规划） | `/api/v1/video-tasks/{id}/cancel` | 取消任务 |

### 6.4 媒体

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/v1/media/{id}/thumbnail` | 缩略图 |
| GET | `/api/v1/media/{id}/content` | 原图、音频或支持 Range 的视频流 |
| POST | `/api/v1/uploads` | 上传到当前工程的隔离暂存区 |
| POST | `/api/v1/uploads/{id}/commit` | 通过业务命令确认导入 |

## 7. Web 客户端页面

真实 Web 客户端放在 `website/app/`，与现有 `website/demo/` 分开。

页面规划与当前状态：

1. 配对登录页：显示主机名称、版本、连接安全提示和配对输入。
2. 工作台：当前工程、处理进度、最近任务和可用模块。
3. 故事板（已实现审阅闭环）：响应式缩略图网格、分镜详情、批注、必要文字编辑和冲突恢复；自由布局、媒体替换仍在桌面端。
4. 拍摄脚本：镜头组表格/卡片双布局、字段编辑、冲突提示和保存状态。
5. 视频生成（规划）：提示词、模型参数摘要、排队状态、结果预览和取消。
6. 只读预览模式：适合导演在手机或平板快速审阅。

视觉原则：沿用桌面端 Material 3 色彩、圆角、密度与导航命名；宽屏使用左侧导航和多栏工作台，窄屏使用底部导航与抽屉；不机械复制 Windows 标题栏。

## 8. 代码模块清单

计划新增：

```text
lib/features/remote_access/
  application/
    remote_access_controller.dart
    remote_access_facade.dart
    remote_change_bus.dart
  data/
    remote_access_repository.dart
    remote_audit_logger.dart
  domain/
    remote_access_config.dart
    remote_auth_models.dart
    remote_events.dart
  server/
    embedded_web_server.dart
    api_router.dart
    auth_middleware.dart
    error_middleware.dart
    media_handler.dart
    static_web_handler.dart
  presentation/
    remote_access_settings_section.dart

website/app/
  lib/
    core/api/
    core/theme/
    features/auth/
    features/workspace/
    features/storyboard/
    features/shooting_script/
    features/video_generation/
  test/
```

预计最小修改现有文件：

- `pubspec.yaml`：服务端依赖与版本号。
- `lib/core/bootstrap/app_bootstrap.dart`：启动/释放内置服务。
- `lib/core/providers/app_providers.dart`：远程访问依赖注入。
- `lib/features/settings/presentation/settings_page.dart`：远程访问入口。
- `installer/filmstoryboard.iss`：携带 Web 静态资源。
- 需要参与远程同步的现有 Controller：只增加事件接入，不重构相邻逻辑。

## 9. 分阶段待办

### 阶段 A：服务基座

- [ ] 配置模型与安全默认值。
- [ ] 服务生命周期、健康检查、统一 JSON 和请求 ID。
- [ ] 配对码、会话令牌、角色和撤销。
- [ ] CORS、请求体上限、基础限流与审计。
- [ ] API 核心自动化测试。

### 阶段 B：首个业务闭环

- [x] 当前工作区与工程概览接口。
- [x] 拍摄脚本读取、单镜头安全编辑和版本冲突检测。
- [x] 受控图片缩略图/内容接口。
- [x] WebSocket 连接与脚本变更事件。
- [x] 桌面端收到远程变更后刷新。

### 阶段 C：Web 首版

- [x] 配对登录与令牌生命周期。
- [x] 响应式工作台。
- [x] 拍摄脚本查看编辑。
- [x] 故事板图片预览、批注与必要文字编辑。
- [x] 断线重连、冲突提示和错误恢复。

### 阶段 D：功能扩展

- [ ] 视频解析上传与任务进度。
- [ ] 复刻工作流、资产库和构建脚本。
- [ ] 视频生成提交、取消、恢复与结果播放。
- [ ] 导出结果下载。
- [ ] Viewer 只读分享模式。

### 阶段 E：安装交付

- [ ] 设置页管理服务、端口、配对码与客户端。
- [ ] Web Release 构建与资源嵌入。
- [ ] 安装包离线 Smoke 测试。
- [ ] 桌面端完整回归、版本递增和发布说明。

## 10. 验收标准

1. 关闭远程访问时没有监听端口；开启后健康检查可用。
2. 未认证、过期、撤销或角色不匹配的请求返回正确状态码。
3. API 响应和日志不包含 API Key、配对码、本机绝对路径或敏感请求头。
4. 远端能读取当前工程、查看分镜图、修改允许的脚本字段；桌面端无需重启即可看到变化。
5. 桌面和 Web 同时修改时不会静默覆盖，旧版本写入得到 `409`。
6. 视频支持拖动播放所需的 Range 响应；非法媒体 ID 和路径穿越被拒绝。
7. 生成任务由桌面主机执行，Web 刷新或重连后仍能恢复状态。
8. Web 在 1440px、1024px、768px 和手机宽度下无关键溢出。
9. Windows 安装后不依赖开发环境即可启动 Web；静态资源缺失时桌面端仍可启动并给出明确诊断。
10. `flutter analyze`、相关测试、Web Release、Windows Release 和安装包验证全部通过。

## 11. 实施顺序说明

服务基座、“拍摄脚本单镜头编辑”与“故事板远程审阅、批注和必要文字编辑”闭环已经完成。后续按阶段 D 逐模块扩展；视频生成、导出等规划项在实际实现与验证前不计入 Web 已完成功能。
