# GitHub 云端 Windows 发布流程修复

状态：发布验证中
当前阶段：4/5
最后更新：2026-09-06

## 当前状态

已从功能分支 `feat/paired-wardrobe-storyboard-depth` 触发 GitHub Actions 云端发布。
主发布工作流已修复为只分析桌面 package、兼容 Windows 文档换行，并在 runner 中恢复 person-depth runtime 与构建远程 Web 工作台。
当前第 4 次云端作业正在执行，尚未在本机编译。

## 下一步

1. 等待 GitHub Actions 完成 Windows/Web 构建、安装器校验和发布。
2. 核对 Release 仓库的版本、安装包和 SHA-256 资产。
3. 更新本任务文档的最终验证状态并检查 Git 工作区。

## 当前 TODO

- [x] 限定桌面 package 静态分析范围
- [x] 统一确定性提示词文档测试的 Windows 换行
- [x] 从公开 `SHIYIN-AI-source` Release 恢复 person-depth runtime
- [x] 在云端构建 `website/app` Web 产物
- [ ] 云端安装器校验通过
- [ ] 发布 Release 并核对资产

## 最近验证状态

- 静态检查：云端通过（第 4 次作业）
- 单元测试：云端通过（861 项通过，4 项跳过）
- Windows Release：云端通过（第 4 次作业）
- 安装器：进行中
- 最近 Git commit：`4f89490`

---

## 任务目标

使用 GitHub Actions 的 Windows runner 完成 filmstoryboard 发布，不在本机执行正式编译或安装器构建，并发布可下载的 Windows 安装包。

## 技术方案

- 发布工作流使用 `windows-latest`，执行分析、测试、Windows/Web Release 构建和 Inno Setup。
- person-depth runtime 从公开 `luojiang419/SHIYIN-AI-source` 的 `person-depth-v1.0.0` 三个 runtime 分卷下载，逐卷解压并删除临时压缩包；模型权重不进入安装包。
- 发布目标仍为 `luojiang419/storyboard-grid-app-releases`，由现有发布脚本创建草稿、上传安装包与校验文件并发布 Latest Release。

## 当前关键修改

- `.github/workflows/release.yml`：主 package 分析范围、person-depth runtime 恢复、远程 Web 构建。
- `test/features/deterministic_replacement_prompt_catalog_test.dart`：读取文档时统一 `CRLF` 为 `LF`。
- 对应 commits：`1c3fe58`、`c689adf`、`1a78219`、`4f89490`。

## 已知问题

- GitHub API 轮询触发当前账号速率限制，暂时通过 Actions 网页查看作业状态。

## 接力信息

[CODEX_LONG_TASK_CONTINUE_V3]

新会话启动：阅读本任务文档，检查 Git branch/status，然后从“下一步”继续；不要在本机运行正式 Flutter Windows 编译。
