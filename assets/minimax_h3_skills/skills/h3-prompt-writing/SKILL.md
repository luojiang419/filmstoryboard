---
name: h3-prompt-writing
description: 为 T2VA、I2VA、FL2VA、L2VA 和 Ref2VA 编写 MiniMax H3 视频生成提示词。适用于将多模态请求改写为 H3 提示词结构、编排 integrated_multimodal_description、overall_soundscape 和 non_diegetic_music，对齐关键帧，或定义图片、视频及音频的引用标签。
---

# H3 提示词编写

## 工作流程

1. 识别输入模式：T2VA、I2VA、FL2VA、L2VA 或全参考 Ref2VA。
2. 对于基础文本/关键帧模式（T2VA/I2VA/FL2VA/L2VA），阅读 `references/base-cn.txt`，并遵循其中最终提示词的结构（三个核心字段：integrated_multimodal_description、overall_soundscape、non_diegetic_music）。
3. 对于全参考模式（Ref2VA），阅读 `references/ref-cn.txt`，并遵循其中的六段改写格式（subject_definitions、summary、retention_analysis、detailed_description、overall_soundscape、non_diegetic_music）。
4. 严格保留所选指南中的字段名、章节顺序、引用标签（`<Subject N>`、`<Picture N>`、`<Video N>`、`<Audio N>`）和时间标记法。
5. 写完后，对照指南中的完整示例校验结构与内容详尽度。

## 基础模式（T2VA / I2VA / FL2VA / L2VA）

- **T2VA**：根据文本构建完整的视听时间线。无图片对齐指令，直接以三个核心字段开始。
- **I2VA**：T2VA 主体 + 首帧指令 + 从首帧向前发展的视觉路径。指令行：`For the target video, at 0.00 seconds into the target video, <Picture 1> (from [Shot 1]) is fully referenced.`
- **FL2VA**：T2VA 主体 + 首尾帧指令 + 首帧到尾帧的连续路径。指令行：`How the reference pictures align with the target video — <Picture 1> (from [Shot 1]) aligns with the 0.00-second mark; <Picture 2> (from [Shot N]) aligns with the S.SS-second mark.`
- **L2VA**：T2VA 主体 + 尾帧指令 + 从合理的前置状态收束到尾帧的路径。指令行：`How the reference pictures align with the target video — <Picture 1> (from [Shot N]) aligns with the S.SS-second mark.`

按 `references/base-cn.txt` 所示顺序使用 `integrated_multimodal_description`、`overall_soundscape` 和 `non_diegetic_music`。

`integrated_multimodal_description` 是主体段：按时间线描述每个镜头的画面、动作、镜头运动、声音、对话（用 `<d>[Language] ...</d>` 包裹）、歌词和场景内可见文字。`[Shot 1]` 标记开镜且无时间戳；后续镜头用 `[Shot N] At MM:SS.mmm, ...` 标记剪辑点。镜头运动用自然英文表述，包含运动类型、幅度和速度（若需表达）。

`overall_soundscape` 总结全片的环境音、动作物理音和非语言人声。

`non_diegetic_music` 描述观众可听到但剧中人物听不到的背景音乐。说明乐器、节奏与动态展开（如有），无音乐时写 `N/A`。

## 全参考模式（Ref2VA）

Ref2VA 改写按以下顺序使用六段：

1. **`subject_definitions`**：每个被引用内容（主体、图片、视频、音频）一行，明确定义其标签含义、参考角色和主要特征。当同一主体由多张图片提供时，合并来源并说明每张图提供什么。
2. **`summary`**：以方括号任务类型前缀开头（`[reference generation]`、`[keyframe completion]`、`[video editing]`、`[video continuation]`、`[audio reuse]`、`[audio reference]`，可加号组合），概述目标视频和参考关系。任务类型由参考资产在目标视频中的实际角色决定——单纯提供风格/构图/氛围指引属 `reference generation`；作为具体帧锚点属 `keyframe completion`；直接编辑源视频属 `video editing`；从源视频末尾接续属 `video continuation`。
3. **`retention_analysis`**：每个 `<Subject N>`、`<Picture N>`、`<Video N>`、`<Audio N>` 一行，说明其在目标视频中如何保留/转移/引用。可见内容用关系标记 `fully_preserved` / `partially_preserved` / `attribute_transfer` / `weak_reference`；音频用 `fully_copy` / `partially_copy` / `reference` / `weak_reference`。这些是固定英文值，不要替换为同义词。
4. **`detailed_description`**：按目标视频播放顺序逐镜头描述画面、动作、声音、对话。生成任务下长度通常 350–500 英文词；对话密集内容优先容纳完整台词时间线，而非机械凑词。镜头跨切、跨镜连续音频、台词被截断等情况使用 `<scenetrans>`、`<cutoff>` 等标记。在第一次出现重要 `<Subject N>` 时描述其引用特征、画框位置和当前动作，后续镜头继续用同一标签不要重新定义。
5. **`overall_soundscape`**：总结全片环境音与物理声音，对话/歌声/与具体镜头同步的音效保留在 `detailed_description`。
6. **`non_diegetic_music`**：描述观众可听到但剧中人物听不到的音乐，说明乐器、节奏、动态展开；无音乐时写 `N/A`。

完整示例（咖啡店+萨摩耶）见 `references/ref-cn.txt` 第 7 节。

## 引用标签规则

- 一旦给某内容分配 `<Subject N>`、`<Picture N>`、`<Video N>` 或 `<Audio N>` 标签，其含义在 `subject_definitions`、`summary`、`retention_analysis`、`detailed_description` 与音频段中保持一致。
- `<Subject N>` 用于可复用的可见内容（人/物/场景/服装/道具/特效/风格/动作/表情/姿态），不是源文件本身。一个主体可由多张参考图定义，一张参考图也可提供多个主体。
- `<Picture N>` 当参考图本身充当某镜头的首帧/关键帧/尾帧/构图锚点时使用；若图片仅用于定义人物/场景/服装/风格，则不创建独立 Picture 条目，而是在对应 `<Subject N>` 定义中引用该图片源。
- `<Video N>` 仅用于整段视频级关系（编辑源视频、从源视频末尾接续、引用源视频的镜头/剪辑/节奏/时间结构）。若从参考视频中取具体可见内容（人物/物/动作/特效），仍归入 `<Subject N>`。
- `<Audio N>` 用于独立音频资产或参考视频中启用的同步音轨。若音频对应目标说话人，定义为 `<Subject N> (Sx)`（其中 `(Sx)` 是目标视频全局说话人编号）；否则用稳定音色描述后接 `(Sx)`。当音频仅作为 BGM/完整原声中嵌入的台词/歌词被直接复用，引用方为 `<Audio N>`，不要额外分配 `(Sx)`。

`<Video N>` 与 `<Audio N>` 的编号各自独立，序号不暗示配对关系。同一参考视频可同时对应 `<Video 1>` 与 `<Audio 2>`，不同编号不阻碍它们来自同一源资产。

## 输出规则

- 使用英文编写结构化段落；对话、歌词、画面内可见文字保留其原始语言。
- 描述每个镜头的构图、主体、环境、动作、摄影机运动、声音，以及被引用内容出现的准确时间点。
- 避免只写剧情总结、留下未解析的引用标签，或使用与要求时长不匹配的时间安排。
- Ref2VA 模式避免把新加入的动作、背景或剧情事件当作"参考保真度损失"来写。
- 完成 Ref2VA 改写后，参照 `references/ref-cn.txt` 第 7 节的咖啡店完整示例自检：`subject_definitions` 每行是否真正定义了引用内容；`retention_analysis` 是否每个标签都给了关系标记；`detailed_description` 是否按播放顺序逐镜头写明引用出现位置。
