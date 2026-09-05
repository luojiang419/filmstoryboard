# 高精度人物深度组件

精确分镜复刻使用从 `E:\APP\SHIYIN-AI` 复用的 person-depth candidate.3：

- Depth Anything V2 Large：`depth-anything/Depth-Anything-V2-Large-hf`，revision `7581137eff8d4e94f6e796d3baea0e9fa79b22d2`，`CC-BY-NC-4.0`
- BiRefNet：`ZhengPeng7/BiRefNet`，revision `e2bf8e4460fc8fa32bba5ea4d94b3233d367b0e4`，`MIT`
- worker protocol：NDJSON stdio v1，Windows x64

模型和重型运行时保存在仓库根目录的 `local_components/person-depth/`，不进入 Git。执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/copy_person_depth_component.ps1
```

脚本从参考项目的已激活组件复制全部文件，逐文件做 SHA-256 校验，并生成本地 `copy-manifest.json`。Windows Release 和安装包只包含运行时与模型配置，排除 `.safetensors` 权重、下载断点和本地复制清单。

首次提取时自动将两个模型（共 1,785,796,464 bytes）下载到安装目录 `data/person-depth/models/`，不会迁移到用户缓存。使用官方固定 revision URL、断点续传和 SHA-256 校验；两份模型均校验通过才显示 100%，随后继续推理。已有完整模型可离线复用。

诊断日志：`data/logs/person_depth.jsonl`。冻结 Python worker 使用 Windows 本地编码，请求必须用 ASCII JSON 转义中文路径，响应按 `systemEncoding` 解码。预览转换通过独立函数作用域启动 isolate，避免捕获推理队列中的 Completer。

当前复刻链路保留原尺寸 16-bit 深度母版，在同目录生成无损 8-bit 灰度 PNG 作为预览和生成模型的结构控制输入。深度控制 PNG 禁止转为 JPEG。
