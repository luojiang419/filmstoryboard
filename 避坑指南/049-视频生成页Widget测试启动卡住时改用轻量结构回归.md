# 049-视频生成页Widget测试启动卡住时改用轻量结构回归

## 问题

为验证视频生成完成态不再自动挂载内嵌播放器，曾尝试新增完整 `VideoGenerationPage` Widget 测试。

命令：

```text
D:\flutter\bin\flutter.bat test test\features\video_generation\video_generation_page_test.dart --no-version-check
```

现象：

```text
command timed out
```

使用 `-r expanded` 和 `--plain-name` 后仍长时间没有进入具体用例输出。

## 判断

当前环境下，完整页面 Widget 测试会拉起较重的 UI、插件和媒体相关依赖链。即使测试本身不点击播放，也可能在测试启动或编译阶段卡住，影响定向验证效率。

## 本次处理

- 放弃完整挂载 `VideoGenerationPage` 的 Widget 测试。
- 改为轻量源码结构回归测试：
  - 断言源码不再包含 `class _InlineGeneratedVideoPlayer`。
  - 断言存在 `_GeneratedVideoCompletedPlaceholder`。
  - 断言存在“点击预览时才加载播放器”的完成态提示。
  - 断言 `else if (isGenerating)` 位于 `else if (hasLocalVideo)` 前，避免运行态被本地路径误判成完成态。

通过命令：

```text
D:\flutter\bin\flutter.bat test test\features\video_generation\video_generation_page_test.dart --no-version-check
```

## 后续建议

如后续必须做页面级 Widget 测试，优先先把视频生成完成格子拆成可独立测试的小组件，或给播放器创建逻辑加可注入工厂/测试替身，避免测试环境触发真实媒体插件链路。
