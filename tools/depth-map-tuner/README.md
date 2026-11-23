# filmstoryboard 深度图参数调整插件

这是从 SHIYIN AI 独立调参器复制并适配的 Tauri 2 桌面插件。它保持独立进程架构，直接复用 filmstoryboard 已安装的 `person-depth` 组件，不会复制、下载或重新部署模型。

主应用使用 `--mode person|professional`、`--config-path <path>` 和 `--component-root <path>` 启动插件。人物模式保持人物蒙版深度，专业模式输出完整场景深度；“保存配置”会写入共享配置文件，主应用中的所有深度提取入口在下一次运行时重新读取。

## 启动

在仓库根目录执行：

```powershell
Set-Location tools/depth-map-tuner
npm run dev
```

构建独立可执行文件：

```powershell
npm run build
```

产物位于 `tools/depth-map-tuner/src-tauri/target/release/SHIYIN-Depth-Tuner.exe`。

## 使用

1. 主应用会传入当前安装的 `data/person-depth`；独立调试时也可重新定位组件。
2. 若未自动找到，点击顶部“重新定位”，选择 `person-depth` 目录或其当前安装目录。
3. 在左上区域点击或拖入图片。首次处理会加载共享模型，耗时取决于显卡和图片尺寸。
4. 在底部调整参数，右上预览会即时更新；调参不会重复执行模型推理。
5. 点击右下“导出深度图”保存完整分辨率 PNG，或“导出参数配置”保存 JSON。

## 隔离边界

- 只读取共享组件目录与输入图片。
- 只向本工具自己的应用配置目录写入“共享组件位置”偏好。
- 只在用户通过保存对话框选定的位置写入 PNG/JSON。
- 不修改 `main.py`、`canvas_core/`、`static/`、主 `src-tauri/` 或模型文件。

Depth Anything V2 Large 使用 `CC-BY-NC-4.0`，当前共享候选组件仅限个人非商业用途；BiRefNet 使用 MIT。
