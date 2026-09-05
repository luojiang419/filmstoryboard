# 高精度人物深度组件

精确分镜复刻使用从 `E:\APP\SHIYIN-AI` 复用的 person-depth candidate.3：

- Depth Anything V2 Large：`depth-anything/Depth-Anything-V2-Large-hf`，revision `7581137eff8d4e94f6e796d3baea0e9fa79b22d2`，`CC-BY-NC-4.0`
- BiRefNet：`ZhengPeng7/BiRefNet`，revision `e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4`，`MIT`
- worker protocol：NDJSON stdio v1，Windows x64

模型和重型运行时保存在仓库根目录的 `local_components/person-depth/`，不进入 Git。执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/copy_person_depth_component.ps1
```

脚本从参考项目的已激活组件复制全部文件，逐文件做 SHA-256 校验，并生成本地 `copy-manifest.json`。Windows Release 构建会将该目录安装到 `data/person-depth/`；发布构建前必须先复制完整组件。

当前复刻链路保留原尺寸 16-bit 深度母版，在同目录生成无损 8-bit 灰度 PNG 作为预览和生成模型的结构控制输入。深度控制 PNG 禁止转为 JPEG。
