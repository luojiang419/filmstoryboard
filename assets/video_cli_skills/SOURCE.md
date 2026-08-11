# 视频 CLI Skills 来源

## LibTV CLI

- 下载地址：`https://liblibai-web-static.liblib.cloud/cli/1.1.3/libtv-cli-skill.zip`
- Skill / CLI 版本：`1.1.3`
- 收录日期：`2026-08-11`
- 收录范围：ZIP 中完整 44 个文件，包含 `SKILL.md`、命令、节点类型、模型 schema、案例和安装脚本。
- `SKILL.md` SHA-256：`12EA7FA0C4AC0B4724664EA7E2D0A709EF44F4D58127A72D6C01802679147261`
- 额外提示词指南：火山引擎《Doubao Seedance 2.0 系列提示词指南》的本地只读副本 `prompt-guides/SD2提示词规则.md`，SHA-256 `3B8B1D4A8F82A1251C9264E8554BCE99EF81125DFF35E1EB841AD5A2A5BE57BC`。
- 官方教程：`https://www.volcengine.com/docs/82379/2222480?lang=zh`

## 可灵 CLI

- 上游仓库：`https://github.com/klingai-tech/skills`
- 固定提交：`43237a7bc8f500652c4de97462931182e9a125e0`
- Skill 版本：`0.1.3`
- 收录日期：`2026-08-11`
- 收录范围：`SKILL.md`、`reference.md`、`api-examples.md`。
- `SKILL.md` SHA-256：`1FA3B0393B9533701D420D54F3B1A20EBDB6EA306424983BD072154767307190`

这些文件作为只读 Flutter assets 随 Windows 软件发布。应用只会把当前任务真正需要的正文与引用文档发送给用户配置的视觉模型，不读取安装脚本执行，也不会把全部 Skill 无差别拼入单次请求。
