# Windows 文件操作概率性卡死诊断报告

## 1. 结论摘要

本次现象不是一个单一故障，应拆成两类：

1. **上传/选择文件时的概率性“卡死”**：高置信度根因是 Windows 公共文件对话框在 Flutter 平台线程内同步执行；当资源管理器命名空间、历史目录、网络盘、云盘、缩略图处理或 Shell 扩展阻塞时，应用主窗口因模态关系无法操作，用户看到的就是整窗不动。
2. **独立的低频原生崩溃**：WER 还记录过 `flutter_windows.dll` 的 `0xc0000005` 访问冲突。匹配当前 Flutter 3.38.8 发布引擎 PDB 后，故障地址位于底层 `memmove/memcpy` 区域，但 WER 没有调用栈和转储，现阶段不能确认调用者，也不能把它归因于文件上传。

当前证据足以确定第一类问题的故障层级，但还不足以仅靠 Dart 层局部防抖彻底修复。建议按“先止血、再原生隔离、同时补观测”的顺序实施。

## 2. 分析目标与边界

- 覆盖任意页面的打开文件、批量上传和保存路径入口。
- 区分业务异步未完成、Dart UI isolate 阻塞、Flutter Windows 平台线程阻塞和原生崩溃。
- 保留现有 294 版本未提交开发内容；本轮只诊断，不修改业务代码、不构建发布包、不递增版本号。
- 自动化控制窗口曾因 Windows 控制接口失败而停止，用户看到“控制窗口一直不动”。该次操作没有形成有效复现，因此不作为应用卡死证据。

## 3. 关键证据

### 3.1 系统事件

Windows WER 在 2026-08-13 对 v1.0.0.290 记录了：

| 时间 | 类型 | 关键模块 | 判定 |
| --- | --- | --- | --- |
| 11:11:36 | `AppHangB1` | `comdlg32.dll`、`explorerframe.dll`、`file_selector_windows_plugin.dll` | 文件对话框阶段挂起 |
| 13:18:38 | `APPCRASH` | `flutter_windows.dll`，异常 `0xc0000005` | 独立原生崩溃 |
| 16:05:58 | `AppHangB1` | `comdlg32.dll`、`explorerframe.dll`、`file_selector_windows_plugin.dll` | 文件对话框阶段挂起 |

两份挂起报告均属于 `AppHangB1`，并同时加载 Windows 公共文件对话框、Explorer Frame 和 file selector 插件。至少一份报告还出现网络/云端命名空间及第三方 Shell 扩展模块；另一份没有相同第三方扩展仍然挂起，因此这些扩展是放大因素，不是必要条件。

该问题已经存在于 290，早于 294 的 DWPose/ONNX 改动，所以不能把新模型模块作为主因。

### 3.2 插件调用模型

当前依赖为 `file_selector 1.1.0`、`file_selector_windows 0.9.3+5`。Windows 插件在平台消息处理链路内同步调用：

```cpp
dialog_controller_->Show(parent_window);
```

只有调用者传入 `initialDirectory` 时，插件才执行 `SetFolder`。项目中的多数打开文件入口没有传入安全初始目录，会继承 Windows 文件对话框上次使用位置。微软文档说明 `IFileDialog::SetFolder` 可覆盖此前保存的文件夹状态：[IFileDialog::SetFolder](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifiledialog-setfolder)。当前 pub.dev 最新页面仍是上述插件版本：[file_selector](https://pub.dev/packages/file_selector)、[file_selector_windows](https://pub.dev/packages/file_selector_windows)。

当 `Show` 内部等待不可达目录、网络提供程序、云占位文件、缩略图或 Shell 扩展时，Flutter 主窗口作为对话框 owner 会被模态禁用。如果对话框又被遮挡、出现在屏幕外或尚未完成创建，用户只会看到主窗口完全不响应。

### 3.3 项目入口分布

当前共有 **14 个**直接文件对话框调用，分散在 9 个功能域：

- 网格裁切：1 个 `openFiles`
- 工程入口：2 个 `openFile`、1 个 `getSaveLocation`
- 导出：1 个 `getSaveLocation`
- 一键复刻：1 个 `openFile`、1 个 `openFiles`
- 拍摄脚本：1 个 `openFiles`
- 视频生成：2 个 `getSaveLocation`
- 视频解析：1 个 `openFiles`
- 故事板：1 个 `openFile`、1 个 `openFiles`
- 故事设计：1 个 `openFiles`

当前没有统一文件对话框服务、全局 in-flight 锁、标准初始目录或统一耗时日志。一键复刻、拍摄脚本等少数入口的局部 `_isOpening...` 只可防止重复点击，不能解除已经阻塞在原生 `Show` 内的调用。

### 3.4 次要卡顿风险

- `lib/features/**/presentation` 中共有 **41 处** `existsSync()`；其中一键复刻 15 处、视频生成 13 处。这些同步文件系统调用出现在界面构建或交互附近，如果路径位于慢盘、离线盘或被安全软件拦截，会造成 UI isolate 短暂停顿。
- `lib/core/database/app_database.dart` 直接使用 `sqlite3.open` 及同步查询/执行。长事务或存储抖动也可能让普通点击看起来“没反应”。
- 页面保活和媒体资源会增加常驻资源量，但当前 WER 的文件对话框证据不支持把它列为上传挂起主因。

这些风险能解释“等操作”中的普通顿卡，但不能替代两份 `AppHangB1` 的文件对话框根因。

## 4. 根因分级

| 级别 | 原因 | 置信度 | 影响 |
| --- | --- | --- | --- |
| P0 | `IFileDialog::Show` 在 Flutter Windows 平台线程同步等待 | 高 | 主窗口模态失去交互，表现为整窗卡死 |
| P0 放大项 | 未指定安全初始目录，继承不可达/缓慢的 MRU 目录 | 高 | 增加网络盘、云盘或无效目录触发概率 |
| P1 | 各页面各自调用，无全局互斥、耗时埋点和恢复机制 | 高 | 难定位、无法统一降级，局部防抖覆盖不全 |
| P1 | 构建路径内同步 `existsSync()` 与同步 SQLite | 中 | 普通点击或页面刷新出现短时无响应 |
| 独立待查 | Flutter 引擎 `0xc0000005`，故障点在内存复制例程 | 中（确有崩溃）/低（根因未知） | 直接退出，需完整 dump 才能定责 |

## 5. 建议修复顺序

### 第一阶段：低风险止血与可观测性

1. 新建单一 `DesktopFileDialogService`，替换 14 个直接调用。
2. 使用应用内全局互斥锁；任何页面已有对话框请求时拒绝再次打开。
3. 打开前先提交一帧，让按钮禁用/加载状态可见。
4. 每次传入已存在、可访问的本地项目目录作为 `initialDirectory`；目录失效时回退到用户本地文档目录。这里需要确认产品取舍：强制 `SetFolder` 会降低“记住上次目录”的便利性，但能显著规避坏 MRU 路径。
5. 记录请求来源、开始/返回时间、取消/异常、初始目录、超过 3/10/30 秒阈值等结构化日志。

此阶段能降低触发率并让后续问题可证实，但**不能保证**第三方 Shell 扩展或 Explorer 自身卡住时应用仍可响应。

### 第二阶段：根治平台线程阻塞

分叉或替换 Windows file selector 实现：在独立 STA 线程初始化 COM、创建并显示 `IFileDialog`，通过异步结果回传 Flutter。需要同时处理 owner HWND、模态行为、线程消息泵、取消、应用退出和重复请求。

建议增加原生 watchdog：超过阈值时记录对话框 HWND、可见性、位置和当前目录；若对话框隐藏或屏幕外则恢复到前台。不要用 Dart `Future.timeout` 假装取消，因为超时不会终止已经阻塞的原生 `Show`。

### 第三阶段：治理普通点击卡顿

1. 把界面构建路径内的 `existsSync()` 改为异步预取并缓存文件可用状态。
2. 将 SQLite 连接与查询迁移到后台 isolate，或采用后台数据库执行器。
3. 用 Flutter DevTools timeline 和自定义交互计时，定位超过 100 ms 的同步任务。

### 第四阶段：抓取独立崩溃

为下一次 `flutter_windows.dll` 崩溃启用 LocalDumps 或 ProcDump，保留与发布版本完全匹配的 EXE、DLL、PDB 和版本号。只有拿到调用栈后，才能判断是否与无障碍语义、输入法/触控、媒体、图像解码或插件有关。Flutter 官方曾记录 Windows 无障碍/触控相关的类似随机引擎崩溃，但不能据此认定本项目同源：[Flutter #131480](https://github.com/flutter/flutter/issues/131480)。

## 6. 验收与回归矩阵

修复后至少完成以下 Windows 实机回归：

- 14 个入口逐一执行打开、取消、选择成功，各循环 20 次。
- 同一按钮快速双击、不同页面连续点击、对话框存在时切换页面。
- 上次目录为已断开的 UNC/映射盘、已卸载移动盘、云盘占位目录。
- 含大量图片/视频及损坏媒体的目录，开启缩略图与安全软件扫描。
- 单屏、双屏、拔掉副屏、缩放比例混合、窗口最小化/恢复。
- Explorer/Shell 扩展启用与干净启动 A/B 测试；只作为诊断，不要求用户永久禁用扩展。
- 对话框超过阈值时主窗口仍能显示明确状态，日志能定位入口与耗时阶段。
- 连续压力测试期间无重复原生对话框、无未捕获异常、无新增 WER AppHang/APPCRASH。

## 7. 本轮验证结果

- `flutter analyze --no-pub`：通过，0 个问题。
- 窗口、复刻、视频解析控制器、视频生成页面相关测试：25 项全部通过。
- `git diff --check`：没有补丁格式错误，仅显示现有文件的行尾转换警告。
- 未修改业务代码，未编译发布版本，版本保持 `1.0.0+294`。

## 8. 待决策项

进入修复前需要选择实施范围：

1. **先做第一阶段止血（推荐）**：改动小、可快速覆盖全部入口，同时补足日志；观察后再决定是否分叉原生插件。
2. **第一、二阶段一起做**：更接近根治，但 Windows 原生线程、COM 和模态窗口改造风险更高，需更完整的实机回归。
3. **只做取证**：先部署 dump 与耗时日志，不改变文件选择体验；挂起概率不会立即下降。
