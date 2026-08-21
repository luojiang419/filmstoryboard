import 'line_art_color_style_preset.dart';

const _repositoryName = 'YouMind-OpenLab/awesome-nano-banana-pro-prompts';
const _repositoryUrl =
    'https://github.com/YouMind-OpenLab/awesome-nano-banana-pro-prompts';
const _licenseName = 'CC BY 4.0';
const _licenseUrl = '$_repositoryUrl/blob/main/LICENSE';

class LineArtColorStyleCatalog {
  const LineArtColorStyleCatalog._();

  static const defaultPresetId = 'natural_cinema';

  static const builtInPresets = <LineArtColorStylePreset>[
    LineArtColorStylePreset(
      id: 'natural_cinema',
      name: '自然电影',
      description: '中性肤色、真实面料与克制的电影反差，适合大多数服装广告。',
      prompt:
          'Apply a refined natural cinematic color grade with neutral, believable skin tones, clean whites, controlled highlight roll-off, gently open shadows, and restrained saturation. Preserve the authorized product, wardrobe, skin, fabric, metal, leather, and material colors exactly enough for commercial continuity. Keep the image photorealistic and premium, with subtle tonal depth and very fine organic grain. Let lighting direction and scene content remain unchanged; adjust only the global color response, contrast, highlight softness, shadow density, and finishing texture.',
      swatches: ['#D8C2AC', '#8E7968', '#53616A', '#22272B'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/natural_cinema.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Picts by AI',
          authorUrl: 'https://x.com/pictsbyai',
          sourcePostUrl: 'https://x.com/pictsbyai/status/2089627862232166456',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'warm_analog',
      name: '暖调胶片',
      description: '金色高光、温暖肤色与柔和颗粒，适合生活方式和户外时装。',
      prompt:
          'Apply an elegant warm analog film grade with honeyed highlights, softly warmed skin, muted olive greens, and gently amber midtones. Preserve every authorized garment, product, logo, textile, skin, and material color as the factual base, allowing only a coherent warm photographic bias. Use soft highlight bloom, smooth shadow transitions, moderate contrast, restrained saturation, and delicate natural grain. Maintain premium fashion realism without vintage damage, heavy color casts, or faded blacks; change only the global grade and finishing texture.',
      swatches: ['#E6B56B', '#B7744A', '#6F7152', '#352D2A'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/warm_analog.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Picts by AI',
          authorUrl: 'https://x.com/pictsbyai',
          sourcePostUrl: 'https://x.com/pictsbyai/status/2089265474370781219',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'blue_gold_twilight',
      name: '暮色蓝金',
      description: '冷蓝环境与暖金肤色分离，适合奢华男装、城市黄昏和电影海报。',
      prompt:
          'Create a sophisticated blue-and-gold twilight grade: cool steel-blue ambience in the environment, warm but natural skin and practical lights, and a precise separation between subject and background. Preserve all authorized wardrobe, product, complexion, fabric, jewelry, and material colors; the palette must remain commercially recognizable. Shape the image with deep clean blues, restrained amber highlights, smooth highlight roll-off, rich but readable shadows, and fine cinematic grain. Keep the result photorealistic, luxurious, and consistent across every storyboard frame.',
      swatches: ['#D8A765', '#6E8192', '#314B64', '#182531'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/blue_gold_twilight.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Aatif J',
          authorUrl: 'https://x.com/aatif_j',
          sourcePostUrl: 'https://x.com/aatif_j/status/2088931467048915165',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'tungsten_night',
      name: '钨丝夜色',
      description: '暖钨灯与深夜冷影并置，适合街拍、夜景时装与动态广告。',
      prompt:
          'Apply a polished tungsten-night color grade with warm practical-light highlights, neutral-to-warm skin, cool charcoal shadows, and small controlled pockets of saturated city color. Preserve the authorized clothing, product, skin, fabric, reflective surface, and material colors as identifiable facts. Keep blacks deep yet detailed, protect bright signs and lamps from clipping, and use subtle halation with fine photographic grain. Maintain a premium live-action fashion finish and coherent exposure across frames, changing only color, contrast, highlight behavior, shadow density, and texture.',
      swatches: ['#E1A35E', '#9A5B39', '#334451', '#121A21'],
      useCase: LineArtColorStyleUseCase.cinema,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/tungsten_night.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'H A J R A',
          authorUrl: 'https://x.com/codewithhajra',
          sourcePostUrl:
              'https://x.com/codewithhajra/status/2089296806156914995',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'cyan_amber_epic',
      name: '史诗青金',
      description: '深青阴影与琥珀光源形成宏大层次，适合奇观电影和高概念广告。',
      prompt:
          'Build an epic cyan-and-amber cinematic grade with deep blue-green shadow atmosphere, focused amber illumination, strong dimensional separation, and controlled monumental contrast. Preserve every authorized product, costume, skin, prop, metal, fabric, and material color as the factual foundation. Keep faces and hero products readable, highlights smoothly contained, and dark areas richly detailed. Add only restrained cinematic grain and subtle atmospheric color density. The result should feel premium and live-action, with one stable palette across all storyboard frames rather than an illustrative repaint.',
      swatches: ['#D99749', '#8A6A3A', '#17606A', '#102D35'],
      useCase: LineArtColorStyleUseCase.cinema,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/cyan_amber_epic.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'mini singh',
          authorUrl: 'https://x.com/KaminiKamini222',
          sourcePostUrl:
              'https://x.com/KaminiKamini222/status/2088132331458695315',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'desaturated_prestige',
      name: '低饱和奢华',
      description: '克制彩度、冷静中性色与细腻肤色，适合高级成衣和杂志大片。',
      prompt:
          'Apply a restrained prestige-fashion grade with reduced global saturation, nuanced neutral tones, refined skin color, soft mineral shadows, and precise tonal separation in dark garments. Preserve all authorized clothing, product, complexion, textile, leather, metal, and material colors so merchandise remains accurate and recognizable. Use elegant medium contrast, smooth highlight roll-off, dense but open blacks, and extremely fine grain. Keep the result photorealistic, modern, and expensive, avoiding gray lifeless skin or crushed fabric detail while maintaining one coherent grade across the sequence.',
      swatches: ['#C7BDB2', '#958D87', '#62696B', '#282D30'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/desaturated_prestige.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Omer DEDO',
          authorUrl: 'https://x.com/0m3RDED0',
          sourcePostUrl: 'https://x.com/0m3RDED0/status/2089413194087297318',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'pastel_dream',
      name: '柔彩梦境',
      description: '粉雾高光与柔和冷暖层次，适合香氛、美妆和概念时装。',
      prompt:
          'Create a sophisticated pastel dream grade with luminous blush, powder blue, pale lavender, and creamy neutral transitions. Preserve all authorized garment, product, skin, cosmetic, fabric, glass, and material colors as recognizable commercial truth, then unify them through a gentle pastel atmosphere. Keep skin dimensional and natural, highlights pearlescent rather than clipped, shadows soft but readable, and saturation carefully controlled. Add a clean premium finish with minimal fine grain, maintaining photorealistic fashion imagery and the same palette balance across every frame.',
      swatches: ['#E7B9C5', '#C7C7E4', '#A7C9D2', '#F0E2D3'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/pastel_dream.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'timedoctor.eth',
          authorUrl: 'https://x.com/timedoctor_nft',
          sourcePostUrl:
              'https://x.com/timedoctor_nft/status/2089721749562683708',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'forest_warmth',
      name: '森林暖意',
      description: '自然绿、土色与温暖肤色平衡，适合户外奢侈品和自然叙事。',
      prompt:
          'Apply a cinematic forest-warmth grade with layered natural greens, warm earth neutrals, softly sunlit skin, and quiet golden highlights. Preserve the authorized wardrobe, product, complexion, textile, wood, leather, foliage, and material colors as factual references. Keep greens varied and believable rather than uniformly teal, with open shadow detail, gentle contrast, smooth highlight roll-off, and subtle organic grain. The finish should remain photorealistic, intimate, and premium, carrying the same green-to-warm balance through every storyboard image without changing scene content or lighting direction.',
      swatches: ['#D6A96B', '#8C7650', '#4E674F', '#263C31'],
      useCase: LineArtColorStyleUseCase.cinema,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/forest_warmth.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Ayla | AI & Tech',
          authorUrl: 'https://x.com/AylaTechAI',
          sourcePostUrl: 'https://x.com/AylaTechAI/status/2090270630377910286',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'cool_commercial',
      name: '冷感商业',
      description: '洁净冷白、高透明度和精准产品色，适合美妆、珠宝与电商广告。',
      prompt:
          'Apply a clean cool-commercial grade with crisp neutral whites, a subtle blue-silver atmosphere, luminous natural skin, and precise separation of glossy and matte surfaces. Preserve all authorized product, packaging, wardrobe, complexion, cosmetic, jewelry, fabric, and material colors with high commercial accuracy. Keep highlights bright but controlled, shadows clean and low in contamination, contrast polished, and saturation selective rather than excessive. Use an immaculate photorealistic finish with nearly invisible grain, maintaining identical white balance and product-color response across the complete storyboard sequence.',
      swatches: ['#E8EEF0', '#B8CED5', '#7894A0', '#314853'],
      useCase: LineArtColorStyleUseCase.commercial,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/cool_commercial.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Maddox',
          authorUrl: 'https://x.com/Maddox_Digital',
          sourcePostUrl:
              'https://x.com/Maddox_Digital/status/2088836197498143054',
        ),
      ),
    ),
    LineArtColorStylePreset(
      id: 'silver_noir',
      name: '银幕黑白',
      description: '唯一的艺术化代表卡：银灰层次、深黑与雕塑感高光，适合黑白时装电影。',
      prompt:
          'Render the sequence in an elegant silver-noir monochrome grade with luminous skin, sculptural highlights, deep velvet blacks, and a broad range of clean silver-gray midtones. Preserve authorized garment, product, complexion, fabric, metal, and material distinctions by translating their colors into stable relative luminance, so logos, silhouettes, textures, and merchandise remain readable. Use controlled high contrast, soft highlight roll-off, detailed shadows, and fine cinematic grain. Keep the result photorealistic and suitable for a luxury fashion film, with consistent tonal mapping across every storyboard frame.',
      swatches: ['#E7E7E4', '#AAA9A5', '#61615F', '#171817'],
      useCase: LineArtColorStyleUseCase.stylized,
      isBuiltIn: true,
      version: 1,
      thumbnail: ColorStyleThumbnailReference.bundled(
        'assets/color_style_thumbnails/silver_noir.jpg',
        attribution: ColorStyleThumbnailAttribution(
          repositoryName: _repositoryName,
          repositoryUrl: _repositoryUrl,
          licenseName: _licenseName,
          licenseUrl: _licenseUrl,
          author: 'Heather Green',
          authorUrl: 'https://x.com/heathergreen',
          sourcePostUrl:
              'https://x.com/heathergreen/status/2089532739124887591',
        ),
      ),
    ),
  ];

  static LineArtColorStylePreset byId(String id) => builtInPresets.firstWhere(
    (preset) => preset.id == id,
    orElse: () => builtInPresets.first,
  );
}
