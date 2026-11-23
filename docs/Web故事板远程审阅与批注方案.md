# Web 故事板远程审阅与批注方案

## 1. 模块目标

在不复制桌面业务状态、不绕过现有 `StoryboardController` 的前提下，为已配对的远程客户端提供故事板审阅闭环：

1. 浏览当前工程的画板列表、编组、布局、故事概述、格位图片和描述。
2. 使用现有媒体白名单读取工程目录内允许远程展示的故事板图片。
3. 导演角色可添加、修改和解决画板级或镜头级批注。
4. 导演角色可执行必要编辑：画板名称、故事概述、镜头描述、逐行描述。
5. 所有写入均校验画板修订号；冲突时返回最新修订号，不覆盖桌面端或其他导演的更新。
6. 桌面故事板变化和 Web 写入通过现有事件总线通知客户端刷新。

本模块不包含图片上传/替换、格位拖拽排序、画板增删、布局调整、锁定切换、视觉分析、高清重绘、视频生成或导出；这些功能仍属于后续 Web 化范围。

## 2. 现状与业务边界

### 2.1 数据模型

- `StoryboardState` 保存画板、画板编组、资源组、打开页签和运行态。
- `StoryboardBoard` 保存名称、网格、样式、锁定状态、概述、逐行描述和 `StoryboardItem`。
- `StoryboardItem` 以资源 ID、图片路径、格位、描述和翻转状态构成。
- 图片路径属于本地实现细节，对 Web 只能转换为 `RemoteMediaRegistry` 生成的临时媒体 ID。

### 2.2 Controller 与持久化

- 故事板没有独立 Repository；约束、撤回历史、自适应高度和保存调度集中在 `StoryboardController`。
- 持久化内容位于工程数据库设置项 `storyboardWorkspaceSnapshot`，由 `WorkspaceSnapshotSaveQueue` 延迟写入。
- 远程接口若直接写设置项，会绕过内存状态、锁定校验、撤回历史和拍摄脚本同步，因此禁止这种实现。
- 新增的定向审阅编辑入口必须由 Controller 执行，并且不得切换桌面端当前选中画板。

### 2.3 远程基础设施

- `RemoteWorkspaceRegistry` 负责当前工程数据库和目录的生命周期。
- `RemoteAccessFacade` 当前只投影拍摄脚本 Repository。
- `EmbeddedWebServer` 已具备配对会话、viewer/director 权限、JSON 限额、审计、WebSocket 事件和媒体字节范围响应。
- Flutter Web 客户端已具备配对、角色信息、REST、实时重连、媒体缓存和脚本工作区。

### 2.4 新边界

- 在远程域定义只读 DTO 与 `RemoteStoryboardSource` 接口，不让远程模块依赖桌面 Controller。
- 在故事板 application 层实现适配器，监听 Controller 的真实画板变化并提供定向编辑。
- `RemoteStoryboardRegistry` 绑定当前工程的实时源、维护画板修订号并发布 `storyboard.changed`。
- 批注由项目数据库中的专用 Repository 保存，不混入桌面画板快照；删除画板后的孤立批注在读取/写入时清理。

## 3. 权限与操作矩阵

| 操作 | viewer | director | 锁定画板 |
| --- | --- | --- | --- |
| 列表、详情、图片、批注读取 | 允许 | 允许 | 允许 |
| 新增/修改/解决批注 | 禁止 | 允许 | 允许 |
| 修改名称、概述、镜头描述、逐行描述 | 禁止 | 允许 | 禁止 |
| 图片替换、排序、增删画板、布局/样式调整 | 未开放 | 未开放 | 未开放 |

## 4. API 草案

- `GET /api/v1/storyboards`：画板摘要与编组。
- `GET /api/v1/storyboards/{boardId}`：完整审阅投影、修订号和批注。
- `PATCH /api/v1/storyboards/{boardId}`：`expectedRevision` + 必要编辑 `changes`。
- `POST /api/v1/storyboards/{boardId}/annotations`：新增批注。
- `PATCH /api/v1/storyboards/{boardId}/annotations/{annotationId}`：修改正文或解决状态。

所有写接口仅接收显式白名单字段，文本设置长度上限；修订冲突统一返回 `409 revision_conflict` 和 `currentRevision`。

## 5. 文件/模块清单

### 桌面与服务端

- `lib/features/remote_access/domain/remote_storyboard_models.dart`：远程故事板 DTO、编辑命令、源接口、批注模型。
- `lib/features/remote_access/data/remote_storyboard_review_repository.dart`：批注 JSON 持久化与校验。
- `lib/features/remote_access/application/remote_storyboard_registry.dart`：实时源绑定、修订号、事件发布。
- `lib/features/storyboard/application/storyboard_remote_source.dart`：Controller 适配器与变更差异检测。
- `lib/features/storyboard/application/storyboard_controller.dart`：不改变桌面选择的定向审阅编辑入口。
- `lib/core/providers/app_providers.dart`、`lib/app/app_shell.dart`：全局 registry 注入及项目生命周期绑定。
- `lib/features/remote_access/application/remote_access_facade.dart`：故事板投影、冲突、批注业务。
- `lib/features/remote_access/server/embedded_web_server.dart`：路由、角色、审计。
- `lib/features/remote_access/application/remote_access_controller.dart`：能力标记改为真实可用。

### Flutter Web

- `website/app/lib/core/models/remote_models.dart`：故事板与批注模型。
- `website/app/lib/core/api/remote_api.dart`：故事板 REST 方法。
- `website/app/lib/features/workspace/remote_app_controller.dart`：选择、刷新、保存、冲突恢复和事件处理。
- `website/app/lib/features/storyboard/storyboard_review_page.dart`：响应式画板列表、画布审阅、批注与必要编辑。
- `website/app/lib/features/workspace/workspace_page.dart`：新增故事板导航入口与工作台统计。

### 测试与交付

- `test/features/remote_access/remote_storyboard_*_test.dart`：Repository、Facade、HTTP、权限、冲突、事件和媒体白名单。
- `website/app/test/remote_api_test.dart`、`website/app/test/widget_test.dart`：Web API 与响应式交互。
- 版本文件、安装脚本、发布文档与递增快照/backup 差异文档。

## 6. 待办清单

- [ ] 建立远程故事板源接口、实时 Registry 与 Controller 适配器。
- [ ] 建立批注 Repository 和模型。
- [ ] 完成故事板列表、详情、编辑、批注 API。
- [ ] 完成 viewer/director、锁定画板、修订冲突、审计、事件与媒体专项测试。
- [ ] 完成 Flutter Web 故事板审阅页和控制器。
- [ ] 完成 Web API、组件和冲突恢复测试。
- [ ] 版本从 `1.0.0.241` 递增并完成静态分析、专项/全量测试。
- [ ] 完成 Web、Windows、Inno Setup 构建与安装包回归。
- [ ] 写大模块 backup 差异文档、最终快照并检查缓存。

## 7. 验收标准

1. viewer 能审阅但所有故事板写接口返回 403；director 可写。
2. Web 不返回绝对路径；非工程目录文件和非白名单媒体无法注册或读取。
3. 远程编辑通过桌面 Controller 生效、进入撤回历史、保存到工程，并且不切换桌面当前画板。
4. 锁定画板拒绝内容编辑，但仍允许添加审阅批注。
5. 使用旧修订号写入返回 409，响应包含当前修订号，Web 自动加载最新数据并提示冲突。
6. 桌面修改、远程编辑和批注变化都会产生 `storyboard.changed`，Web 能定向刷新。
7. 画板级和镜头级批注在工程重开后仍存在，可修改正文和解决状态。
8. Web 在桌面与窄屏下均能完成画板选择、图片查看、描述编辑和批注操作。
9. 主工程/Web 静态分析无问题；专项测试、全量测试、Web/Windows/安装包构建全部通过。
10. 文档只声明本模块真实交付范围，未开放能力保持明确标注。
