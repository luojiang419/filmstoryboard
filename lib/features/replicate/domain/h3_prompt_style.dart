class H3PromptStyle {
  const H3PromptStyle({
    required this.id,
    required this.label,
    required this.description,
    required this.officialSkillPath,
    required this.narrativeStructure,
    required this.visualMaterial,
    required this.cameraAndRhythm,
    required this.motionAndContinuity,
    required this.soundStrategy,
    required this.hardConstraints,
    required this.videoPromptInstruction,
  });

  static const generalId = 'general';

  /// MiniMax-H3 官方 skills 仓库中本轮规则所对应的固定版本。
  static const officialSourceRevision =
      'b7227fa6a6206e9fb30562383d39e53cf3866a48';

  final String id;
  final String label;
  final String description;
  final String officialSkillPath;
  final String narrativeStructure;
  final String visualMaterial;
  final String cameraAndRhythm;
  final String motionAndContinuity;
  final String soundStrategy;
  final String hardConstraints;

  /// 最终本地 H3 提示词仍需携带的精炼风格锁，避免视觉分析结果在拼接时丢失风格。
  final String videoPromptInstruction;

  bool get isGeneral => id == generalId;

  /// 提供给视觉模型构建脚本的逐维度执行契约。
  ///
  /// 这里保留旧属性名，避免已存在的调用链和项目数据迁移；语义已从一段
  /// 风格简介升级为可检查的完整分析约束。
  String get visualPromptInstruction {
    if (isGeneral) return '';
    return '''
官方技能：$officialSkillPath（版本 $officialSourceRevision）
叙事结构：$narrativeStructure
画面材质：$visualMaterial
镜头与节奏：$cameraAndRhythm
动作与连续性：$motionAndContinuity
声音策略：$soundStrategy
硬性禁区：$hardConstraints
逐字段落实：不要只复述风格名或堆砌形容词。必须把上述规则分别落实到画面内容、景别、构图、机位、运镜、动作阶段、空间关系、视觉焦点、光线、色彩、声音、叙事功能和转场承接中；每个镜头至少出现两个该类型独有且可见或可听的执行特征。
''';
  }

  static const general = H3PromptStyle(
    id: generalId,
    label: '自动匹配（通用 H3）',
    description: '按每个镜头剧情自动匹配一个专项 Skill；没有明确特征时使用通用 H3',
    officialSkillPath: 'skills/h3-prompt-writing',
    narrativeStructure: '',
    visualMaterial: '',
    cameraAndRhythm: '',
    motionAndContinuity: '',
    soundStrategy: '',
    hardConstraints: '',
    videoPromptInstruction: '',
  );

  static const values = <H3PromptStyle>[
    general,
    H3PromptStyle(
      id: '3d-animation-short',
      label: '3D 动画短片',
      description: '角色一致、场景连续、动作清楚的风格化 3D 叙事',
      officialSkillPath: 'skills/3d-animation-short-generator',
      narrativeStructure:
          '故事优先，以角色主动目标、缺陷放大危机、因果推进和情绪锚点回收组织镜头；每镜明确 setup、reveal、reversal、callback、tender、chase 或 expression-beat 等 hook，并让结尾状态为下一镜铺垫。',
      visualMaterial:
          '皮克斯感风格化 3D 卡通、C4D + Octane 高级动画电影质感；角色使用强剪影和高概括几何形体，可爱角色采用 2.5–3 头身，发丝或毛发兼具块面与边缘细节，皮肤使用温润 SSS 透光而非塑料表面。',
      cameraAndRhythm:
          '景别在特写/大特写与环境景别之间有目的地交替；镜头写清起势、路径、幅度、速度和落点。追逐、失衡、惊吓或闹剧节拍才使用荷兰角；镜头不超过 15 秒并按动作信息量形成清楚节拍。',
      motionAndContinuity:
          '表演必须有 squash-and-stretch、anticipation、overshoot、follow-through、overlap、弧线和可读姿态；锁定角色身份、服装、比例、签名道具、固定地标、人物画面位置和光位基线，形成跨镜空间锚点与动作交接链。',
      soundStrategy:
          '对白、呼吸、表情反应和动作音效逐次对齐表演；离屏旁白期间画面人物嘴部保持闭合。单镜只写本镜同步声音，不擅自为每镜生成独立 BGM；全片配乐应作为连续音乐轨统一设计。',
      hardConstraints:
          '不要真人写实、扁平二次元、塑料玩具皮肤、僵硬解剖、木偶式姿势或无生命表情；最终画面不得出现分镜边框、铅笔线、箭头、镜头号、双绑定标签、姿态残影、水印或无关文字。',
      videoPromptInstruction:
          '皮克斯感风格化 3D 卡通，C4D + Octane 高级动画电影质感，强剪影与 2.5–3 头身比例，温润 SSS 皮肤，块面化且有边缘细节的毛发。表演使用 squash-and-stretch、预备动作、过冲和跟随动作；镜头锁定角色身份、服装、道具、固定地标、人物位置和光位，动作与音效同步。只输出干净全彩成片，不出现任何分镜线稿、标签、箭头或水印。',
    ),
    H3PromptStyle(
      id: 'brand-promo',
      label: '品牌宣传短片',
      description: '突出产品功能、使用场景与行动引导的品牌叙事',
      officialSkillPath: 'skills/brand-promo-video-generator',
      narrativeStructure:
          '先依据可核验素材建立品牌事实表，再按产品类型组织专属故事脊柱：用户意图/场景建立→真实机制或流程→功能/场景→可见输出或证明→回报→LOGO 与行动号召；15 秒通常安排 5–8 个主要节拍。',
      visualMaterial:
          'LOGO、产品结构、包装、界面、字体行为、品牌色和摄影资产均以用户提供或官方来源为身份锚点；构图保留文案、产品和 LOGO 安全空间，使用 2–5 个有意义且相互联动的色彩状态。',
      cameraAndRhythm:
          '每个节拍只有一个视觉主导动作，次级层稍延迟；设置 2–3 个高能峰值和安静制动点。镜头必须展示产品证据或真实使用因果，转场由产品动作、光标路径、界面流、物体边缘、滚动内容或匹配几何驱动。',
      motionAndContinuity:
          '前一动作通过 6–12 帧的自然重叠、匹配运动或产品状态变化带出下一镜；始终保持产品、界面和品牌资产结构一致，让“用户动作→产品响应→具体成果”的因果链可见。',
      soundStrategy:
          '声音服务品牌安全的纯音乐、UI 音效、产品物理音或经确认的旁白；避免原生音频与独立音轨重复同一内容。文案、旁白和 CTA 的语言服从品牌受众与素材，而不是机械跟随聊天语言。',
      hardConstraints:
          '不得虚构功能、指标、价格、背书、口号或品牌事实；不得近似重绘未授权 LOGO、字标、界面、包装、人物或吉祥物；避免虚假 HUD、随意玻璃卡片、装饰文字墙、全片同一种缓动和抽象特效掩盖产品叙事。',
      videoPromptInstruction:
          '采用可核验的品牌宣传片语言：以真实品牌和产品资产为硬锚点，按“场景/意图→真实机制→功能或应用→可见输出/证明→回报→LOGO 与行动号召”推进。每个节拍一个主动作，转场由产品、界面或匹配几何驱动，保持品牌色、字体、LOGO、包装和 UI 结构一致；不虚构任何功能、数据、价格、背书或品牌事实。',
    ),
    H3PromptStyle(
      id: 'co-op-game-intro',
      label: '双人游戏开场',
      description: '双角色与主菜单 UI 深度融合的合作游戏开场',
      officialSkillPath: 'skills/co-op-game-intro-generator',
      narrativeStructure:
          '采用固定合作游戏开场框架：双人主菜单→PLAYER 1 轻量装备配置→PLAYER 2 重型装备配置→共享确认→加载到 100%→双人进入游戏世界；当前镜头根据全片位置承担其中一个连续阶段。',
      visualMaterial:
          '确认图锁定 UI 布局、层级、配色、字体尺度和角色融合方式；PLAYER 1 始终在左且高挑敏捷，PLAYER 2 始终在右且矮壮有力量。全局最多五种主色，所有菜单、玩家卡、按钮、HUD、图标和文字使用同一材质与色彩系统。',
      cameraAndRhythm:
          '开场用高角度大全景轻推，装备阶段分别用中景推近与横移环绕，确认后拉回双人构图，加载阶段保持全景连续转化，最后摄影机下降并绕到背后成为稳定第三人称合作视角；UI 事件清楚、可读且不被角色遮挡。',
      motionAndContinuity:
          '保持 PLAYER 1/2 的左右位置、昵称、脸、发型、体型和装备色不交换；轻量机械爪与厚重机械拳在结构、速度和重量反馈上形成对比。菜单收缩、面板滑入、确认脉冲、加载条和世界转化必须连续，不用硬切或烟雾遮挡。',
      soundStrategy:
          '使用菜单环境音、UI hover/点击、精密机械展开、重型扣合、确认脉冲、加载上升音、城市氛围、脚步和 HUD 提示音，并逐事件同步；无明确音乐需求时不额外添加抢占 UI 信息的配乐。',
      hardConstraints:
          'CONTINUE 必须是主高亮且菜单标题单行可读；不得角色复制、身份/昵称交换、体型趋同、第三名玩家、分屏、随机文字、拼错用户名、额外菜单项、品牌游戏 Logo、难读 UI、随机抖动、漂浮肢体或无依据的霓虹赛博风。',
      videoPromptInstruction:
          '双人合作游戏主菜单开场：PLAYER 1 始终在左、高挑敏捷、轻量机械爪；PLAYER 2 始终在右、矮壮有力、重型机械拳。保持确认图的 UI 布局和最多五种主色，CONTINUE 为主高亮，菜单/玩家卡/HUD 单行清晰可读；装备配置、CONFIRM、LOADING 0–100% 和进入第三人称游戏世界连续衔接，身份、昵称、体型和装备不得交换。',
    ),
    H3PromptStyle(
      id: 'handdrawn-live',
      label: '手绘实拍融合',
      description: '粗糙发光手绘线条与真实空间接触的追拍变形',
      officialSkillPath: 'skills/handdrawn-live-video-generator',
      narrativeStructure:
          '15 秒单一实拍空间连续展开：0–3 秒建立实拍手/物体与手绘实体的明确接触；3–6、6–10、10–13 秒让同一个实体保留前态痕迹并连续变形、移动和恶作剧；13–15 秒扩散为覆盖墙面、地面、窗户或通道的空间级变形并以温柔笑点收束。非 15 秒镜头按相同比例保留五段因果。',
      visualMaterial:
          '真实生活空间使用手持手机实拍质感；手绘实体是贴附真实表面的平面发光笔触，具有蜡笔、粉笔、彩色铅笔、粉彩或粗糙笔刷的抖动线条、涂抹不均、毛边和逐帧重画感。',
      cameraAndRhythm:
          '尽量保持单镜头或相邻空间连续追拍。摄影机不把实体稳定居中，而是在实体离开画面边缘后慢半拍才平移、俯仰或前进；每个时间段都有新的接触、发现、变形或惊喜。',
      motionAndContinuity:
          '真实手或物体必须产生清楚接触点、受力、遮挡和反应；同一个实体在形态变化时保留线条尾巴、色彩拖痕、身体曲线或图案母题，不得瞬移或突然替换为新角色；拍摄者要伸手、抓、追、打开、接住或后退并参与事件。',
      soundStrategy:
          '环境音保持真实空间距离，并为触碰、刮擦、落地、打开容器和手持追逐逐次同步轻巧物理音；不因柔和氛围自动添加慢速铺底音乐。',
      hardConstraints:
          '保持可爱、生活感、怀旧、温柔和非恐怖调性；禁止 3DCG、毛绒玩具、均匀矢量线、平滑霓虹、脱离表面漂浮、恐怖怪物、巨大眼睛、裂口、牙齿、威吓、扑咬、血腥、突然黑屏和跳吓。',
      videoPromptInstruction:
          '实拍生活空间与粗糙发光手绘动画融合。0–3 秒必须出现真实手/物体与平面手绘实体的接触、受力和遮挡；之后同一个实体保留线条尾巴或色彩拖痕连续变形逃跑，摄影机始终慢半拍手持追随；结尾扩散成空间级图案并留下温柔笑点。保持蜡笔/粉笔毛边与逐帧重画感，禁止精致 CG、平滑霓虹、瞬移和任何恐怖跳吓。',
    ),
    H3PromptStyle(
      id: 'minimalist-product-ad',
      label: '极简产品广告',
      description: '干净、克制、强调材质与结构的高级产品展示',
      officialSkillPath: 'skills/minimalist-product-ad-generator',
      narrativeStructure:
          '依据产品品类选择“产品发布型、功能触感型或色彩家族型”脊柱；开场立即用产品真实动作或刁钻视角建立主推款，随后展示材质/结构、功能动作、款式关系或使用感受，最后以单一全画幅产品和完整单行文案稳定收束。',
      visualMaterial:
          '产品本体颜色、点缀色、材质色相、轮廓、比例、包装文字和关键结构是硬保真约束；Apple 感来自大面积留白、克制配色、精确轮廓光、微距材质、高级背景和清楚层级，不把商品改成白色/银灰，也不使用廉价镜面白底。',
      cameraAndRhythm:
          '每个节拍只保留一个主要动作，先产品动作再文字；转场由边缘高光、开合、旋转、吸附、滑入、结构变化、款式几何或轮廓匹配驱动。10 秒通常 5–7 个节拍、1–2 个峰值和 1–2 个制动点，避免空镜拖延。',
      motionAndContinuity:
          '所有动作必须具体可见，例如开启角度、按钮位移、接口露出或高光路径；主推款先稳定，辅助款稍后有秩序进入。文案为 3–5 个英文词、同一时间仅一条且始终同一行，前半先淡入/轻滑，后半随后出现并让前半轻移让位。',
      soundStrategy:
          '默认可采用约 100 BPM 的克制科技产品音乐：清脆 pluck、空气底噪、受控 kick/sub-bass、sine sweep 与木质 percussion，并让卡点对齐产品动作；无人声、不轰头、不廉价 EDM。用户未要求音乐时遵循脚本原有音频意图。',
      hardConstraints:
          '禁止产品变形、重染产品本体颜色、错误包装文字、假品牌标识、未经素材支持的卖点；禁止四宫格、分屏、拼贴、产品墙、假 HUD、玻璃卡片、随机粒子、无意义闪白、双行文案、字幕位文字和结尾小窗合集。',
      videoPromptInstruction:
          '高级极简产品片：严格锁定产品本体颜色、轮廓、比例、材质、包装文字和结构，以大留白、精确轮廓光、微距细节和克制运镜呈现。开场立即由产品真实动作或特殊视角抓住注意，转场只由产品边缘/结构/高光驱动；同一时间最多一条 3–5 个英文词的单行文案，以两段轻淡入/轻滑入完成。结尾为单一全画幅产品与稳定文案，禁止分屏、网格、镜面白底和产品变形。',
    ),
    H3PromptStyle(
      id: 'music-video-subtitle',
      label: '音乐美学 MV',
      description: '随节拍变化的音乐视觉与空间歌词贴字',
      officialSkillPath: 'skills/music-video-subtitle-generator',
      narrativeStructure:
          '以锁定歌词和唯一主音乐轨为全片权威，把目标时长拆成对应歌词、呼吸、snare、drop、808 或重音的短镜头；超过 15 秒时采用多镜头时间轴、首尾帧续接、匹配切和全局音轨拼接，而不是用单镜硬撑。',
      visualMaterial:
          '人物卡、场景卡和文字包装卡职责严格隔离；全片保持同一画幅、角色身份、服装、颗粒、调色、光向和文字运动语言。屏幕歌词是具有透视、遮挡和景深关系的空间图形层，不是底部字幕条。',
      cameraAndRhythm:
          '剪辑点落在 1/4 或 1/8 Beat Grid、歌词停顿、呼吸或强鼓点；使用硬切、跳切、动作匹配切、同向运镜或首尾帧 continuation。人物点头、手势、眨眼、镜头微震和文字砸入/扫出要与具体节拍对齐。',
      motionAndContinuity:
          '人物口型、下颌、呼吸、表情和身体重音逐字跟随正在演唱/说唱的歌词；每镜只保留一个主要文字事件，文字不得遮挡眼睛、主要表情或对嘴时的嘴部；跨镜保持动能方向与美学连续。',
      soundStrategy:
          '用户上传的歌曲或 beat 是唯一主音乐轨，所有分段使用其对应时间窗，不拉伸、不补写、不生成互相断裂的独立音乐。画面文字和可见表演必须逐字匹配锁定歌词，原词不翻译、不改写。',
      hardConstraints:
          '不得把空间歌词退化成普通底部字幕，不得错字、乱码、遮脸、随意添加歌词或复制未授权 IP 风格；避免在元音或词语中途切断口型、淡入淡出掩盖节奏、人物/场景/文字参考相互污染，以及跨镜颜色和光位漂移。',
      videoPromptInstruction:
          '音乐美学 MV 以唯一主音乐轨和锁定歌词为时间轴；镜头、人物重音、灯光和空间歌词在 1/4 或 1/8 Beat Grid、呼吸、snare、drop 或 808 上响应。歌词逐字使用原文，每镜一个主要文字事件，文字作为有透视和遮挡的空间图形层但不遮眼睛或嘴部；人物口型、下颌、呼吸和手势与歌词同步，跨镜用硬切、匹配切、同向运动或首尾帧接续保持统一角色、调色与颗粒。',
    ),
    H3PromptStyle(
      id: 'paper-collage-explainer',
      label: '纸拼贴讲解',
      description: '半调撕纸、视觉隐喻与触感停格动作的讲解画面',
      officialSkillPath: 'skills/paper-collage-explainer-generator',
      narrativeStructure:
          '每个镜头只讲一个知识点或观点，以无需文字也能理解的具体视觉隐喻表达；使用 3–6 个大而易读的纸片物件组，按前景→中景→背景或因果顺序逐片组装，最后锁定为完整编辑拼贴构图。',
      visualMaterial:
          '大色块纸面、黑白半调照片剪影、选择性彩色卡纸、暖白描边、精致撕边、细纤维、层叠接缝和柔和实体纸影；色板受控且干净，不自动使用偏棕牛皮纸、发黄做旧或过重皱纹。',
      cameraAndRhythm:
          '默认稳定机位、无镜头移动和无缩放，让纸片动作承担节奏。每个物件遵循“出现→回弹→压平→暂停→锁定”，避免整体淡入、平滑数字平移、泛泛漂浮、快速旋转或混乱飞散。',
      motionAndContinuity:
          '从与最终构图一致的干净纸色场开始，纸片逐件滑入、弹入、轻敲、压平并落定；保留前景/中景/背景层次，结束短暂停留在完成构图。镜头之间延续同一纸材、半调密度、描边、阴影、色板和音效节奏。',
      soundStrategy:
          '默认只保留与纸片动作同步的纸张滑动、弹入、压平轻敲、摩擦、轻响和小纸片脆响；默认不添加 BGM、旁白口播或字幕，只有用户明确要求时才加入。',
      hardConstraints:
          '禁止可读字母、数字、UI、字幕、Logo、水印、人物口播广告、光滑矢量层、普通二维动画、失去纸材的数字移动、场景切换、镜头缩放、形态融化、新增无关物件和不匹配的牛皮纸开场。',
      videoPromptInstruction:
          '高级编辑感半调纸拼贴：大色块纸面、黑白半调剪影、选择性彩色卡纸、暖白描边、纤维撕边、层叠接缝和柔和纸影。每镜用 3–6 个大物件表达一个视觉隐喻，从匹配色场开始，按“出现→回弹→压平→暂停→锁定”逐片组装，稳定机位并停在完成构图。默认只有同步纸张滑动/轻敲/摩擦音，不加 BGM、旁白或字幕；禁止文字、UI、平滑数字运动和牛皮纸做旧。',
    ),
    H3PromptStyle(
      id: 'papercraft-stop-motion',
      label: '纸艺定格科普',
      description: '分层纸雕布景与逐帧纸机关动作的科普视觉',
      officialSkillPath: 'skills/papercraft-stop-motion-explainer',
      narrativeStructure:
          '围绕一个清楚学习目标按“钩子→解释→例子/文化连接→记忆句”推进，每镜只解释一个知识节拍；抽象概念转化为纸偶、剖面模型、立体书、机关板、层级、路径或可操作纸质道具。',
      visualMaterial:
          '微缩纸雕舞台使用 4–7 层，清楚区分前景、中景、背景和远景；所有物体可见多层卡纸厚度、纤维、折痕、拼贴缝、剪裁边缘、标签片、铆钉、关节、拉片、滑轨、转盘和真实层间投影。',
      cameraAndRhythm:
          '摄影像拍摄真实微缩舞台：缓慢推近、横向平移展示 2.5D 视差、固定中景讲解、微距纸材特写、轻微俯视剖面或克制层间穿梭；标签卡出现时短暂停顿，避免高速飞行和无布景支持的 360 度环绕。',
      motionAndContinuity:
          '纸偶和背景机关都采用逐帧小幅分段移动、短暂停顿、轻微回弹、铰链、滑轨、转盘、翻页、拉片揭示和纸片落定；转场只使用翻页、立体书展开、纸牌遮挡、纸云滑过、圆形纸遮罩、剪纸门、剖面分层或胶带揭示等纸艺物理逻辑。',
      soundStrategy:
          '同步翻纸、剪纸、卡纸滑动、摩擦、木质卡扣、轻微弹出、胶带撕拉、纸偶关节和纸盒开合声；需要 BGM 时按知识主题和文化语境选择并为旁白 duck，不自动套用厚重电影低频或未来电子音。',
      hardConstraints:
          '避免丝滑 CG、塑料 3D、真人写实、普通平面矢量、无纸张纹理的卡通、金属玻璃、霓虹故障、液体融化、没有层间投影、过度平滑边缘、静态背景和破坏微缩感的大幅角色运动。',
      videoPromptInstruction:
          '手工纸艺定格科普：4–7 层微缩纸雕布景，清楚的前景、中景、背景和远景；可见卡纸厚度、纤维、折痕、剪裁边缘、铆钉、关节、拉片、滑轨、转盘和真实层间投影。角色与背景机关采用逐帧分段移动、短暂停顿、轻回弹和纸片落定；运镜只用缓推、横移视差、固定中景、微距或轻俯视，转场遵循翻页/纸门/拉片等纸艺物理逻辑，禁止丝滑 CG、塑料表面和液体变形。',
    ),
  ];

  static H3PromptStyle resolve(String? id) {
    final normalized = id?.trim();
    for (final style in values) {
      if (style.id == normalized) return style;
    }
    return general;
  }
}
