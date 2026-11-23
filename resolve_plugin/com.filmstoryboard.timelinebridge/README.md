# FilmStoryboard DaVinci Resolve 时间线桥接

这是 DaVinci Resolve 的 Workflow Integration 插件。当前已完成：

- Resolve Promise API 初始化与清理；
- 仅监听 `127.0.0.1:47861` 的本机 HTTP Bridge；
- 与 Flutter 客户端共用 `%LOCALAPPDATA%/FilmStoryboard/ResolveBridge/bridge-token.txt`；
- `GET /v1/health` 健康检查；
- 插件状态窗口、项目名称与版本显示；
- `POST /v1/timelines/sync` 的鉴权、大小限制和快照结构校验；
- 创建 `FilmStoryboard/拍摄脚本名` 媒体池文件夹并导入或复用素材；
- 按首个有效素材的分辨率和帧率创建时间线；
- 按软件端 I/O 点和时间线落点分别追加视频、音频并恢复链接；
- 用持久化的项目/脚本/时间线绑定与稳定修订号更新已有时间线；
- 更新时只清理 `FilmStoryboard ... [Managed]` 受管轨道，保留用户其他轨道；
- 同名未绑定时间线、受管轨道被改名、素材指纹变化时安全停止。

若相同修订的素材、I/O 点和受管轨道内容均未变化，同步会直接返回 `unchanged`，不会重复导入或重建。

## 开发验证

```powershell
npm test
& ..\windows\Test-FilmStoryboardResolvePluginScripts.ps1
```

## Windows 安装与卸载

开发目录、软件 data 载荷和安装包均不提交机器相关二进制 `WorkflowIntegration.node`。安装脚本始终先把内置插件包直接复制到官方流程整合插件目录：

```text
%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins\com.filmstoryboard.timelinebridge
```

若目标机恰好存在 Resolve SDK 的官方 Promise API 示例，脚本会额外复制其中的原生模块；未安装 SDK 或模块不存在不会导致插件文件复制失败：

```text
%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Developer\Workflow Integrations\Examples\SamplePromisePlugin\WorkflowIntegration.node
```

以管理员 PowerShell 执行：

```powershell
& .\resolve_plugin\windows\Install-FilmStoryboardResolvePlugin.ps1
& .\resolve_plugin\windows\Uninstall-FilmStoryboardResolvePlugin.ps1
```

安装与卸载可重复执行，不检查 Resolve 版本、版本类型、运行状态或插件能否被宿主加载。安装成功仅表示内置插件文件已经复制到官方目录；能否加载由用户目标机的 Resolve 环境决定。

`windows` 目录下的部署脚本必须保持 UTF-8 BOM 编码，因为安装包和软件内补安装均调用 Windows PowerShell 5.1；脚本测试会校验 BOM，并应直接用 Windows PowerShell 5.1 执行一次完整安装/卸载回归。

插件载荷中的 `manifest.xml` 保持标准 UTF-8 即可，安装脚本必须通过 .NET API 显式按 UTF-8 读取，不能使用 Windows PowerShell 5.1 会按系统 ANSI 解释无 BOM 文件的 `Get-Content` 默认行为。

Inno Setup 会先显示“是否安装达芬奇插件？”选择页。无论是否立即安装，插件源码与脚本都会保存在 FilmStoryboard 安装目录的 `data/resolve_plugin`；选择暂不安装后，仍可在软件“设置 → 插件”中点击“安装达芬奇插件”随时补安装。应用内安装会请求 Windows 管理员权限，插件部署失败不会阻止仍可使用 XML 时间线导出的 FilmStoryboard 主程序。

## Resolve 宿主实机验收

当前开发机的 DaVinci Resolve 21.0.0.47 未能加载 Workflow Integration。以下项目必须在能显示“工作区 → 流程整合”菜单的目标机上完成后，才能判定宿主 E2E 通过：

- 安装后重启 Resolve，确认“工作区 → 流程整合”出现并能打开 FilmStoryboard 时间线桥接；
- 分别在无项目、已打开项目状态检查插件健康状态、项目名与版本；
- 首次同步确认媒体池目录、时间线分辨率/帧率、素材 I/O、时间线落点、音视频轨道与链接正确；
- 相同修订再次同步返回 `unchanged`，不重复导入或重建；
- 修订变化只重建受管轨道，保留用户轨道；同名未绑定时间线、受管轨道改名和素材指纹变化均安全停止；
- 验证混合音频格式、删除后追加失败、项目保存失败等错误路径，不把部分结果误报为成功；
- 重复安装、卸载、再次卸载，确认目录覆盖与清理符合预期。

如果目标机没有显示“流程整合”菜单，可继续使用软件内的 XML 时间线导出。
