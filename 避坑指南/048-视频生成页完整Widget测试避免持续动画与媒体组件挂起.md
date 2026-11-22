# 048-视频生成页完整Widget测试避免持续动画与媒体组件挂起

## 问题
新增完整 `VideoGenerationPage` widget 测试时，页面包含持续动画、计时器、图片预览和媒体相关依赖，测试进程在启动阶段无输出超时，并留下 `flutter_tester` / `dart` 残留进程。

## 处理方式
- 放弃新增完整页面级测试，改用：
  - controller 测试验证点击生成后立即出现 `submitting` 活动任务；
  - 现有 `replicate_page_test.dart` 验证视频生成四列页面仍可渲染。
- 超时后清理本次残留测试进程：
```powershell
Get-Process | Where-Object { $_.ProcessName -match 'dart|flutter_tester|dartvm|dartaotruntime' } | Stop-Process -Force
```

## 后续避开
- 不要为视频生成完整页面新增轻量 widget 测试来断言单个小组件。
- 优先测试 controller 状态和已有上层页面集成路径。
- 如果必须测生成中组件，先把组件抽成可公开测试的独立 widget，避免整页媒体依赖。
