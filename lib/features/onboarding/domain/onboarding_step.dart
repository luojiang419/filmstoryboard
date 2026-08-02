enum OnboardingSection {
  overview,
  design,
  videoAnalysis,
  storyboard,
  shootingScript,
  replicate,
  exporter,
  settings,
}

class OnboardingStep {
  const OnboardingStep({
    required this.id,
    required this.section,
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.tabIndex,
  });

  final String id;
  final OnboardingSection section;
  final String eyebrow;
  final String title;
  final String body;
  final int tabIndex;
}

const onboardingSteps = <OnboardingStep>[
  OnboardingStep(
    id: 'welcome',
    section: OnboardingSection.overview,
    eyebrow: '欢迎使用爆款复刻工作台',
    title: '从参考视频，到可执行的复刻方案',
    body: '这段快速导览会带你认识视频解析、故事板、拍摄脚本、一键复刻、导出和设置。你可以随时跳过，也能通过标题栏的帮助按钮重新查看。',
    tabIndex: 0,
  ),
  OnboardingStep(
    id: 'design',
    section: OnboardingSection.design,
    eyebrow: '第 1 步 · 设计分镜图',
    title: '先把创意变成连贯镜头',
    body: '输入画面需求、选择比例和宫格，生成用于创作或复刻的新分镜素材。图片多宫格裁切作为兼容工具保留在本页。',
    tabIndex: 0,
  ),
  OnboardingStep(
    id: 'video-analysis',
    section: OnboardingSection.videoAnalysis,
    eyebrow: '第 2 步 · 视频解析',
    title: '把参考视频拆成可追溯镜头',
    body: '导入参考视频后提取候选帧，过滤模糊和重复画面，再完成帧级、镜头级和视频级分析。',
    tabIndex: 1,
  ),
  OnboardingStep(
    id: 'storyboard',
    section: OnboardingSection.storyboard,
    eyebrow: '第 3 步 · 故事板拼图',
    title: '拖拽排序并补充拍摄说明',
    body: '把视频焦点帧编排进画板，自由调整顺序、列数、间距和编号，并编辑每个镜头的剧情脉络。',
    tabIndex: 2,
  ),
  OnboardingStep(
    id: 'shooting-script',
    section: OnboardingSection.shootingScript,
    eyebrow: '第 4 步 · 拍摄脚本',
    title: '把镜头整理成正式脚本',
    body: '使用官方十列表格编辑镜号、内容、景别、运镜、场景和产品搭配，并导出脚本与镜头原图。',
    tabIndex: 3,
  ),
  OnboardingStep(
    id: 'replicate',
    section: OnboardingSection.replicate,
    eyebrow: '第 5 步 · 一键复刻',
    title: '匹配新资产并合成提示词',
    body: '依次确认镜头、准备角色与产品资产，再按 Seedance 2.0 规则合成可复制的最终提示词。',
    tabIndex: 4,
  ),
  OnboardingStep(
    id: 'export',
    section: OnboardingSection.exporter,
    eyebrow: '第 6 步 · 导出故事板',
    title: '预览并交付最终成果',
    body: '选择需要交付的画板，预览最终排版，然后导出 PNG、JPG、PDF、画板图片或拍摄脚本。',
    tabIndex: 5,
  ),
  OnboardingStep(
    id: 'settings',
    section: OnboardingSection.settings,
    eyebrow: '第 7 步 · 设置',
    title: '配置 AI、视频工具与菜单布局',
    body: '在这里配置视觉模型、图片生成、视频解析工具和导出目录，也可按习惯把功能菜单放在底部或左侧。',
    tabIndex: 6,
  ),
];
